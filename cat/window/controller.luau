--!strict
-- Per-window orchestration: config and shared-state polling, overlay sheet installs, window
-- events, intents and the reset confirmation. All Tern access goes through injected ports so the
-- whole loop runs under Lune with fakes. Windows only read tern.kv; every change is an intent.

local T = require("../types")
local store = require("../core/store")
local commands = require("../core/commands")
local rngMod = require("../core/rng")
local overlay = require("../render/overlay")
local configAdapter = require("../adapters/config")
local kvAdapter = require("../adapters/kv")
local fsAdapter = require("../adapters/fs")
local jsonAdapter = require("../adapters/json")
local pathsAdapter = require("../adapters/paths")
local carly = require("../integrations/carly")
local presenterMod = require("./presenter")
local packsMod = require("./packs")
local intents = require("./intents")
local mirror = require("./mirror")

export type Handle = { cancel: (self: any) -> () }

-- Extra signals the Tern glue can read from a timer's fresh cx.
export type TickInfo = { reduce_motion: boolean?, covered: boolean? }

export type Ports = {
	clock: T.Clock,
	-- Unix time in milliseconds (fractional allowed); orders inbox files and reaction ages.
	wall_ms: () -> number,
	fs: fsAdapter.Fs,
	json: jsonAdapter.Json,
	kv: kvAdapter.Kv,
	paths: pathsAdapter.Paths,
	css: (name: string, source: string) -> (),
	timer: (ms: number, fn: (info: TickInfo?) -> ()) -> Handle,
	base64: (bytes: string) -> string,
	log: (level: "debug" | "info" | "warn", message: string) -> (),
	seed: number,
}

export type Result = { ok: boolean, error: string? }

export type Metrics = {
	load_ms: number,
	ticks: number,
	last_tick_ms: number,
	max_tick_ms: number,
	css_installs: number,
}

export type Controller = {
	ports: Ports,
	rng: T.Rng,
	presenter: presenterMod.Presenter,
	packs: packsMod.Cache,
	pack: T.LoadedPack?,
	pack_warning: string?,
	config: T.Config,
	config_text: string?,
	-- config.json exists but could not be read; reported once until it reads again.
	config_unreadable: boolean,
	envelope: T.StoreEnvelope,
	rev: number?,
	mirror_key: string?,
	-- Local reactions whose host echoes must not replay (see mirror.luau).
	recent: mirror.Recent,
	context_text: string,
	css_last: string?,
	timer: Handle?,
	next_kv_ms: number,
	next_cfg_ms: number,
	reset_armed_ms: number?,
	-- Request token buckets per intent source (see RATE_LIMITS).
	buckets: { [string]: Bucket },
	metrics: Metrics,
}

type Bucket = { tokens: number, at_ms: number }
export type RateLimit = { burst: number, per_s: number }

local SHEET = "overlay"
local DEFAULT_PACK = "orange-menace"
local KV_POLL_MS = 2000
local CONFIG_POLL_MS = 3000
local MIN_TIMER_MS = 100
local RESET_CONFIRM_MS = 10000
local SLOW_MS = 20
local PENDING_CAT_ID = "cat-pending"
-- Producer cap: the host drains 32 files per poll, so more than this means it is not consuming.
local MAX_INBOX_FILES = 64
-- Token buckets per source: Carly gets a small burst then about ten requests a minute; people at
-- the keyboard get a generous five a second.
local RATE_LIMITS: { [T.IntentSource]: RateLimit } = table.freeze({
	carly = table.freeze({ burst = 3, per_s = 10 / 60 }),
	keyboard = table.freeze({ burst = 10, per_s = 5 }),
	window = table.freeze({ burst = 10, per_s = 5 }),
	block = table.freeze({ burst = 10, per_s = 5 }),
})

local function pendingId(): string
	return PENDING_CAT_ID
end

local function new(ports: Ports): Controller
	local config = configAdapter.parse(nil, ports.json).config
	local wall_s = ports.clock.wall_s()
	local envelope = store.empty(PENDING_CAT_ID, wall_s)
	local now = ports.clock.now_ms()
	local c: Controller = {
		ports = ports,
		rng = rngMod.new(ports.seed + 1),
		presenter = presenterMod.new({
			clock = ports.clock,
			seed = ports.seed,
			config = config,
			profile = envelope.profile,
		}),
		packs = packsMod.new({
			fs = ports.fs,
			decode = ports.json.decodeOrError,
			base64 = ports.base64,
			roots = {
				{ dir = ports.paths.bundled_packs, source = "bundled" },
				{ dir = ports.paths.user_packs, source = "user" },
			},
			default_id = DEFAULT_PACK,
		}),
		pack = nil,
		pack_warning = nil,
		config = config,
		config_text = nil,
		config_unreadable = false,
		envelope = envelope,
		rev = nil,
		mirror_key = nil,
		recent = {},
		context_text = "",
		css_last = nil,
		timer = nil,
		next_kv_ms = now,
		next_cfg_ms = now,
		reset_armed_ms = nil,
		buckets = {},
		metrics = { load_ms = 0, ticks = 0, last_tick_ms = 0, max_tick_ms = 0, css_installs = 0 },
	}
	return c
end

local function snapshot(c: Controller): carly.Snapshot
	return {
		envelope = c.envelope,
		config = c.config,
		overlay_visible = presenterMod.visible(c.presenter),
		now_s = c.ports.wall_ms() / 1000,
		current = c.presenter.engine.current,
	}
end

local function refreshContext(c: Controller)
	c.context_text = carly.context(snapshot(c))
end

local function selectPack(c: Controller)
	local pack, warning = packsMod.select(c.packs, c.config.cat.appearance)
	c.pack = pack
	if warning and warning ~= c.pack_warning then
		c.ports.log("warn", `tern-cat overlay: {warning}`)
	end
	c.pack_warning = warning
end

local function render(c: Controller)
	local p = c.presenter
	local v = presenterMod.view(p)
	local asset: packsMod.Asset? = nil
	if not v.hidden and c.pack then
		asset = packsMod.asset(c.packs, c.pack :: T.LoadedPack, v.animation)
	end
	local css = overlay.css(presenterMod.params(p, v, asset))
	if css ~= c.css_last then
		c.ports.css(SHEET, css)
		c.css_last = css
		c.metrics.css_installs += 1
	end
end

-- Re-reads config.json when its text changed (or always when forced). True when applied. A file
-- that exists but cannot be read keeps the last good config (defaults on first load) and is
-- reported once instead of silently resetting settings such as a disabled overlay.
local function loadConfig(c: Controller, force: boolean): boolean
	local path = c.ports.paths.config
	local text = c.ports.fs.read(path, configAdapter.MAX_BYTES)
	local missing: configAdapter.Loaded? = nil
	if text == nil then
		local loaded = configAdapter.read(c.ports.fs, c.ports.json, path)
		if loaded.unreadable then
			if not c.config_unreadable then
				c.config_unreadable = true
				c.ports.log("warn", `tern-cat: {loaded.error}`)
			end
			if force or c.pack == nil then
				selectPack(c)
				refreshContext(c)
			end
			return false
		end
		missing = loaded
	end
	c.config_unreadable = false
	if not force and text == c.config_text then
		return false
	end
	local loaded = missing or configAdapter.parse(text, c.ports.json)
	if loaded.error then
		c.ports.log("warn", `tern-cat: {loaded.error}`)
	end
	local appearance = c.config.cat.appearance
	c.config_text = text
	c.config = loaded.config
	presenterMod.setConfig(c.presenter, loaded.config)
	if force or c.pack == nil or loaded.config.cat.appearance ~= appearance then
		selectPack(c)
	end
	refreshContext(c)
	return true
end

-- Reads the shared envelope when its rev changed; mirrors a new host reaction. True when the
-- overlay should re-render.
local function pollKv(c: Controller): boolean
	local raw, err = c.ports.kv.get(kvAdapter.STATE_KEY)
	if err then
		c.ports.log("debug", `tern-cat: kv read failed: {err}`)
		return false
	end
	if type(raw) ~= "table" then
		return false
	end
	if raw.rev ~= nil and raw.rev == c.rev then
		return false
	end
	local env = store.decode(raw, c.ports.clock.wall_s(), pendingId)
	c.rev = raw.rev
	c.envelope = env
	presenterMod.setProfile(c.presenter, env.profile, env.snooze_until)
	local play, key = mirror.check(env.last_reaction, c.mirror_key, c.ports.wall_ms() / 1000, c.recent)
	c.mirror_key = key
	local changed = false
	if play and env.last_reaction and presenterMod.visible(c.presenter) then
		changed = presenterMod.mirror(c.presenter, env.last_reaction.animation)
	end
	refreshContext(c)
	return changed
end

local armTimer: (c: Controller, ms: number?) -> ()

local function onTimer(c: Controller, info: TickInfo?)
	local clock = c.ports.clock
	local t0 = clock.now_ms()
	local ok, err = pcall(function()
		local p = c.presenter
		if info and info.reduce_motion ~= nil then
			presenterMod.setTernReducedMotion(p, info.reduce_motion == true)
		end
		if info and info.covered ~= nil then
			presenterMod.setCovered(p, info.covered == true)
		end
		local now = clock.now_ms()
		local reloaded = false
		if now >= c.next_cfg_ms then
			c.next_cfg_ms = now + CONFIG_POLL_MS
			reloaded = loadConfig(c, false)
		end
		-- One pack per tick keeps the fallback full scan inside the timer budget.
		if not reloaded and packsMod.scanning(c.packs) then
			packsMod.step(c.packs)
			selectPack(c)
		end
		if now >= c.next_kv_ms then
			c.next_kv_ms = now + KV_POLL_MS
			pollKv(c)
		end
		if presenterMod.visible(p) then
			presenterMod.tick(p)
		end
		render(c)
	end)
	if not ok then
		c.ports.log("warn", `tern-cat overlay tick failed: {err}`)
	end
	local dt = clock.now_ms() - t0
	local m = c.metrics
	m.ticks += 1
	m.last_tick_ms = dt
	m.max_tick_ms = math.max(m.max_tick_ms, dt)
	if dt > SLOW_MS then
		c.ports.log("warn", string.format("tern-cat overlay tick took %.1f ms", dt))
	end
	armTimer(c, nil)
end

local function delayMs(c: Controller): number
	local now = c.ports.clock.now_ms()
	local d = presenterMod.nextDelayMs(c.presenter)
	d = math.min(d, c.next_kv_ms - now, c.next_cfg_ms - now)
	if packsMod.scanning(c.packs) then
		d = 0
	end
	return math.max(MIN_TIMER_MS, math.ceil(d))
end

armTimer = function(c: Controller, ms: number?)
	if c.timer then
		c.timer:cancel()
	end
	c.timer = c.ports.timer(ms or delayMs(c), function(info: TickInfo?)
		onTimer(c, info)
	end)
end

-- Entry-load setup; returns the measured duration in ms.
local function start(c: Controller): number
	local clock = c.ports.clock
	local t0 = clock.now_ms()
	c.ports.fs.mkdir(c.ports.paths.inbox)
	loadConfig(c, true)
	pollKv(c)
	render(c)
	local now = clock.now_ms()
	c.next_cfg_ms = now + CONFIG_POLL_MS
	c.next_kv_ms = now + KV_POLL_MS
	armTimer(c, 0)
	local dt = clock.now_ms() - t0
	c.metrics.load_ms = dt
	c.ports.log(
		if dt > SLOW_MS then "warn" else "info",
		string.format(
			"tern-cat overlay setup took %.1f ms (pack %s)",
			dt,
			if c.pack then c.pack.manifest.id else "none"
		)
	)
	return dt
end

local function rerender(c: Controller)
	render(c)
	armTimer(c, nil)
end

local function onWindowEvent(c: Controller, name: string, payload: any)
	local p = c.presenter
	if not presenterMod.visible(p) then
		return
	end
	local ev = presenterMod.eventFor(p, name, payload)
	if ev and presenterMod.react(p, ev) then
		if ev.type == "command_start" or ev.type == "command_finish" then
			c.recent.command_at = c.ports.wall_ms() / 1000
		end
		rerender(c)
	end
end

local function applyLocal(c: Controller, intent: T.Intent)
	local p = c.presenter
	local kind = intent.kind
	local wall_s = c.ports.clock.wall_s()
	if commands.isGesture(kind) then
		c.recent.gesture = kind
		c.recent.gesture_at = wall_s
		if presenterMod.visible(p) then
			presenterMod.gesture(p, kind :: T.Gesture, intent.args)
		end
	elseif kind == "snooze" then
		presenterMod.setProfile(p, p.profile, wall_s + (intent.args.minutes :: number) * 60)
		presenterMod.tick(p)
	elseif kind == "unsnooze" then
		presenterMod.setProfile(p, p.profile, nil)
		presenterMod.mirror(p, "wake")
	elseif kind == "set_overlay" then
		presenterMod.setOverlayOverride(p, intent.args.enabled)
	elseif kind == "set_config" then
		local value = intent.args.values["rendering.overlay"]
		if type(value) == "boolean" then
			presenterMod.setOverlayOverride(p, value)
		end
	else
		return
	end
	refreshContext(c)
	rerender(c)
end

-- Takes one token from the source's bucket; false when it is empty.
local function takeToken(c: Controller, source: T.IntentSource): boolean
	local limit = RATE_LIMITS[source]
	if limit == nil then
		return false
	end
	local now = c.ports.clock.now_ms()
	local b = c.buckets[source]
	if b == nil then
		b = { tokens = limit.burst, at_ms = now }
		c.buckets[source] = b
	end
	b.tokens = math.min(limit.burst, b.tokens + math.max(0, now - b.at_ms) / 1000 * limit.per_s)
	b.at_ms = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

-- Validates and delivers one intent, then applies its optimistic local presentation.
local function request(c: Controller, kind: T.IntentKind, args: { [string]: any }?, source: T.IntentSource): Result
	local intent, err = intents.build(c.rng, c.ports.clock.wall_s(), kind, args, source)
	if not intent then
		return { ok = false, error = err or "invalid request" }
	end
	if not takeToken(c, source) then
		return { ok = false, error = "rate limited" }
	end
	local queued = c.ports.fs.list(c.ports.paths.inbox)
	if queued and #queued > MAX_INBOX_FILES then
		return {
			ok = false,
			error = `the inbox already holds {#queued} unprocessed requests; is the Tern Cat block running?`,
		}
	end
	local path, werr = intents.write(c.ports.fs, c.ports.json, c.ports.paths.inbox, intent, c.ports.wall_ms(), c.rng)
	if not path then
		c.ports.log("warn", `tern-cat: {werr}`)
		return { ok = false, error = werr or "could not deliver the request" }
	end
	applyLocal(c, intent)
	return { ok = true }
end

-- Flips overlay visibility in this window at once and persists it through the host.
local function toggleOverlay(c: Controller, source: T.IntentSource): (Result, boolean)
	local show = not presenterMod.visible(c.presenter)
	local result = request(c, "set_config", { key = "rendering.overlay", value = show }, source)
	if not result.ok then
		presenterMod.setOverlayOverride(c.presenter, show)
		refreshContext(c)
		rerender(c)
	end
	return result, show
end

local function reloadConfig(c: Controller)
	packsMod.invalidate(c.packs)
	c.pack = nil
	loadConfig(c, true)
	pollKv(c)
	rerender(c)
end

-- Destructive commands run only when repeated within RESET_CONFIRM_MS; true means confirmed.
local function confirmReset(c: Controller): boolean
	local now = c.ports.clock.now_ms()
	local armed = c.reset_armed_ms
	if armed ~= nil and now - armed <= RESET_CONFIRM_MS then
		c.reset_armed_ms = nil
		return true
	end
	c.reset_armed_ms = now
	return false
end

-- The cat block floats over the focused pane's corner (or stopped doing so).
local function setCovered(c: Controller, on: boolean)
	if c.presenter.covered ~= on then
		presenterMod.setCovered(c.presenter, on)
		render(c)
	end
end

local function context(c: Controller): string
	return c.context_text
end

return {
	SHEET = SHEET,
	KV_POLL_MS = KV_POLL_MS,
	CONFIG_POLL_MS = CONFIG_POLL_MS,
	RESET_CONFIRM_MS = RESET_CONFIRM_MS,
	RATE_LIMITS = RATE_LIMITS,
	MAX_INBOX_FILES = MAX_INBOX_FILES,
	new = new,
	start = start,
	onWindowEvent = onWindowEvent,
	request = request,
	toggleOverlay = toggleOverlay,
	reloadConfig = reloadConfig,
	confirmReset = confirmReset,
	setCovered = setCovered,
	snapshot = snapshot,
	context = context,
}
