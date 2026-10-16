--!strict
-- Per-window orchestration: config and shared-state polling, overlay sheet installs, window
-- events, intents and the reset confirmation. All Tern access goes through injected ports so the
-- whole loop runs under Lune with fakes. Windows only read tern.kv; every change is an intent.

local T = require("../types")
local store = require("../core/store")
local commands = require("../core/commands")
local rngMod = require("../core/rng")
local overlay = require("../render/overlay")
local travel = require("../render/travel")
local configAdapter = require("../adapters/config")
local kvAdapter = require("../adapters/kv")
local fsAdapter = require("../adapters/fs")
local jsonAdapter = require("../adapters/json")
local pathsAdapter = require("../adapters/paths")
local carly = require("../integrations/carly")
local presenterMod = require("./presenter")
local packsMod = require("./packs")
local portalsMod = require("./portals")
local intents = require("./intents")
local mirror = require("./mirror")

export type Handle = { cancel: (self: any) -> () }

-- Extra signals the Tern glue can read from a timer's fresh cx.
export type TickInfo = { reduce_motion: boolean?, covered: boolean?, focus: presenterMod.FocusInfo? }

-- What the Tern glue reads for a pane walk on a focus event: the new pane's tab layout
-- (`cx.session:layout`) and Tern's settings that place the in-pane cat (see travel.insets).
export type Scene = { layout: any, settings: travel.InsetSettings }
export type SceneReader = () -> Scene?

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
	-- Focus events handled with a pane transition (walk, auto) and their cost.
	switches: number,
	last_switch_ms: number,
	max_switch_ms: number,
	travel_installs: number,
}

export type Controller = {
	ports: Ports,
	rng: T.Rng,
	presenter: presenterMod.Presenter,
	packs: packsMod.Cache,
	pack: T.LoadedPack?,
	pack_warning: string?,
	portals: portalsMod.Cache,
	-- Last pane-transition problem logged (once until it changes).
	portal_warning: string?,
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
	-- Pane travel (`walk`, `auto`): the pane focused last, the main sheet's facts for the travel
	-- sheet, the selected style while the overlay shows, and the installed trip or entrance.
	focus_pane: number?,
	overlay_info: overlay.Info?,
	travel_style: T.PaneTransition?,
	trip: travel.Trip?,
	entrance: boolean,
	trip_id: number,
	trip_at_ms: number,
	travel_css: string?,
	travel_timer: Handle?,
}

type Bucket = { tokens: number, at_ms: number }
export type RateLimit = { burst: number, per_s: number }

local SHEET = "overlay"
local TRAVEL_SHEET = "travel"
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
		portals = portalsMod.new({
			fs = ports.fs,
			decode = ports.json.decodeOrError,
			base64 = ports.base64,
			dir = ports.paths.bundled_portals,
		}),
		portal_warning = nil,
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
		metrics = {
			load_ms = 0,
			ticks = 0,
			last_tick_ms = 0,
			max_tick_ms = 0,
			css_installs = 0,
			switches = 0,
			last_switch_ms = 0,
			max_switch_ms = 0,
			travel_installs = 0,
		},
		focus_pane = nil,
		overlay_info = nil,
		travel_style = nil,
		trip = nil,
		entrance = false,
		trip_id = 0,
		trip_at_ms = 0,
		travel_css = nil,
		travel_timer = nil,
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

-- The pack's own sheet for a transition animation, without falling back to another animation
-- (the overlay clips the decision sheet instead).
local function exact(c: Controller, pack: T.LoadedPack, anim: T.Animation): overlay.Reaction?
	if pack.manifest.animations[anim] == nil then
		return nil
	end
	local a = packsMod.asset(c.packs, pack, anim)
	return if a then { sheet_url = a.sheet_url, durations_ms = a.durations_ms } else nil
end

-- `walk` and `auto` use the portal's prop for the entrance of a switch the cat cannot walk.
local function propStyle(style: T.PaneTransition): string
	return if style == "walk" or style == "auto" then "portal" else style
end

-- Prop plus dive/emerge for the selected style; nil (and one warning) when the props cannot load.
local function transition(c: Controller, pack: T.LoadedPack, style: T.PaneTransition): overlay.Transition?
	if style == "off" then
		return nil
	end
	local prop, problem = portalsMod.prop(c.portals, propStyle(style))
	if prop == nil then
		if problem ~= c.portal_warning then
			c.ports.log("warn", `tern-cat overlay: pane transition off: {problem or "props unavailable"}`)
			c.portal_warning = problem
		end
		return nil
	end
	return { prop = prop, dive = exact(c, pack, "dive"), emerge = exact(c, pack, "emerge") }
end

-- Pane travel ------------------------------------------------------------------------------------

local function installTravelCss(c: Controller, css: string)
	if css ~= c.travel_css then
		c.ports.css(TRAVEL_SHEET, css)
		c.travel_css = css
		c.metrics.travel_installs += 1
	end
end

-- Removes the traveler or the entrance: the empty travel sheet, once one was installed.
local function clearTravel(c: Controller)
	if c.travel_timer then
		c.travel_timer:cancel()
		c.travel_timer = nil
	end
	c.trip = nil
	c.entrance = false
	if c.travel_css ~= nil and c.travel_css ~= travel.EMPTY then
		installTravelCss(c, travel.EMPTY)
	end
end

local function armClear(c: Controller, ms: number)
	if c.travel_timer then
		c.travel_timer:cancel()
	end
	c.travel_timer = c.ports.timer(math.max(0, math.ceil(ms)), function(_info: TickInfo?)
		c.travel_timer = nil
		clearTravel(c)
	end)
end

local function sumMs(durations: { number }): number
	local total = 0
	for _, d in durations do
		total += d
	end
	return total
end

-- The pack's sheet for a leg, resolved through its fallbacks (the resolved name decides the
-- climb's orientation and whether the strip loops).
local function legSheet(c: Controller, pack: T.LoadedPack, anim: T.Animation): travel.Sheet?
	local a, resolved = packsMod.asset(c.packs, pack, anim)
	return if a then { sheet_url = a.sheet_url, durations_ms = a.durations_ms, animation = resolved } else nil
end

-- Installs the current trip's sheet. The trip keeps its id, so a reinstall (the main sheet
-- changed mid-trip and the hold must repeat its new animations) keeps every animation running.
-- False when the pack's walk sheet is unusable.
local function installTrip(c: Controller): boolean
	local trip, info, pack = c.trip, c.overlay_info, c.pack
	if trip == nil or info == nil or pack == nil then
		return false
	end
	local walk = legSheet(c, pack, "walk")
	if walk == nil then
		return false
	end
	local css = travel.css({
		trip = trip,
		id = c.trip_id,
		art = {
			walk = walk,
			run = legSheet(c, pack, "run"),
			climb = legSheet(c, pack, "climb"),
			leap = legSheet(c, pack, "leap"),
		},
		hold = info.hold,
		z = info.z,
	})
	if css == nil then
		return false
	end
	installTravelCss(c, css)
	return true
end

-- Keeps an installed trip or entrance in step with a new main sheet, or removes it once the
-- overlay hides or stops travelling (style changed, reduced motion).
local function refreshTravel(c: Controller)
	if c.trip == nil and not c.entrance then
		return
	end
	local info = c.overlay_info
	local entrance = if info and not c.trip then info.entrance else nil
	if c.travel_style ~= nil and info ~= nil and c.trip ~= nil and installTrip(c) then
		return
	elseif c.travel_style ~= nil and entrance ~= nil then
		installTravelCss(c, entrance)
	else
		clearTravel(c)
	end
end

-- A focus change with `walk` or `auto`: the cat walks from the pane focused before when both are
-- tiled in the new pane's tab and it is not zoomed (`auto`: only when they share an edge);
-- otherwise the portal entrance plays (tab and session switches, zoom, floats, a closed pane).
-- A switch during a trip starts the new one where the traveler is.
local function switchPane(c: Controller, from: number?, to: number, scene: SceneReader?)
	local info, pack, style = c.overlay_info, c.pack, c.travel_style
	if style == nil or info == nil or pack == nil then
		clearTravel(c)
		return
	end
	local now = c.ports.clock.now_ms()
	local trip: travel.Trip? = nil
	local s = if from ~= nil and from ~= to and scene ~= nil then scene() else nil
	if s then
		local current = c.trip
		local elapsed = now - c.trip_at_ms
		local leap = packsMod.asset(c.packs, pack, "leap")
		trip = travel.plan({
			layout = s.layout,
			from = from :: number,
			to = to,
			position = c.config.rendering.overlay_position,
			offset_px = info.gap_h,
			offset_v_px = info.gap_v,
			box_w = info.box_w,
			box_h = info.box_h,
			insets = travel.insets(s.settings),
			leap_ms = if leap then sumMs(leap.durations_ms) else nil,
			interrupt = if current and elapsed < current.total_ms
				then { trip = current, elapsed_ms = elapsed }
				else nil,
		})
		if trip and (#trip.legs == 0 or (style == "auto" and not trip.adjacent)) then
			trip = nil
		end
	end
	c.trip_id += 1
	c.trip_at_ms = now
	c.trip = trip
	c.entrance = false
	if trip and installTrip(c) then
		armClear(c, travel.timing(trip).clear_ms)
		return
	end
	c.trip = nil
	local entrance = info.entrance
	if entrance then
		c.entrance = true
		installTravelCss(c, entrance)
		armClear(c, info.entrance_ms + travel.CLEAR_AFTER_MS)
	else
		clearTravel(c)
	end
end

local function render(c: Controller)
	local p = c.presenter
	local v = presenterMod.view(p)
	local asset: packsMod.Asset? = nil
	local reactions: presenterMod.ReactionAssets? = nil
	local switch: overlay.Transition? = nil
	if not v.hidden and c.pack then
		local pack = c.pack :: T.LoadedPack
		asset = packsMod.asset(c.packs, pack, v.animation)
		if v.reactions then
			reactions = {
				hover = packsMod.asset(c.packs, pack, presenterMod.HOVER_ANIMATION),
				press = packsMod.asset(c.packs, pack, presenterMod.PRESS_ANIMATION),
			}
		end
		switch = transition(c, pack, v.transition)
	end
	local css, info = overlay.css(presenterMod.params(p, v, asset, reactions, switch))
	if css ~= c.css_last then
		c.ports.css(SHEET, css)
		c.css_last = css
		c.metrics.css_installs += 1
	end
	c.overlay_info = info
	c.travel_style = if info and (v.transition == "walk" or v.transition == "auto") then v.transition else nil
	refreshTravel(c)
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
		changed = presenterMod.mirror(c.presenter, env.last_reaction.animation, env.last_reaction.id)
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
		if info and info.focus then
			presenterMod.setFocus(p, info.focus)
			if c.focus_pane == nil then
				c.focus_pane = info.focus.pane
			end
		end
		local now = clock.now_ms()
		local reloaded = false
		if now >= c.next_cfg_ms then
			c.next_cfg_ms = now + CONFIG_POLL_MS
			reloaded = loadConfig(c, false)
			if not reloaded and c.pack then
				-- Notices a selected pack whose folder was removed while config.json still names it
				-- (packs.select re-checks that a cached pack's manifest exists).
				selectPack(c)
			end
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

-- `scene` reads the new pane's tab layout and Tern's settings on a `focus` event, only when the
-- cat may walk (see switchPane).
local function onWindowEvent(c: Controller, name: string, payload: any, scene: SceneReader?)
	local p = c.presenter
	local t0 = c.ports.clock.now_ms()
	local wasFullscreen = presenterMod.fullscreen(p)
	presenterMod.observe(p, name, payload)
	local from = c.focus_pane
	local to = if name == "focus"
			and type(payload) == "table"
			and type(payload.pane) == "number"
		then payload.pane :: number
		else nil
	if to then
		c.focus_pane = to
	end
	if presenterMod.visible(p) then
		local ev = presenterMod.eventFor(p, name, payload)
		if ev and presenterMod.react(p, ev) then
			if ev.type == "command_start" or ev.type == "command_finish" then
				c.recent.command_at = c.ports.wall_ms() / 1000
			end
			rerender(c)
		elseif presenterMod.fullscreen(p) ~= wasFullscreen then
			render(c)
		end
	end
	if to and to ~= from and (c.travel_style ~= nil or c.trip ~= nil or c.entrance) then
		switchPane(c, from, to, scene)
		local dt = c.ports.clock.now_ms() - t0
		local m = c.metrics
		m.switches += 1
		m.last_switch_ms = dt
		m.max_switch_ms = math.max(m.max_switch_ms, dt)
		c.ports.log(
			if dt > SLOW_MS then "warn" else "debug",
			string.format(
				"tern-cat travel: %s %d -> %d in %.2f ms (%s)",
				c.travel_style or "off",
				from or -1,
				to,
				dt,
				if c.trip
					then string.format(
						"%d legs, %d ms",
						#(c.trip :: travel.Trip).legs,
						(c.trip :: travel.Trip).total_ms
					)
					elseif c.entrance then "entrance"
					else "none"
			)
		)
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
	portalsMod.invalidate(c.portals)
	c.portal_warning = nil
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

-- What the glue read about the focused pane (see presenter.setFocus); re-renders when the
-- focused pane starts or stops counting as running a full-screen program.
local function setFocus(c: Controller, info: presenterMod.FocusInfo)
	if c.focus_pane == nil then
		c.focus_pane = info.pane
	end
	local was = presenterMod.fullscreen(c.presenter)
	presenterMod.setFocus(c.presenter, info)
	if presenterMod.fullscreen(c.presenter) ~= was then
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
	setFocus = setFocus,
	snapshot = snapshot,
	context = context,
}
