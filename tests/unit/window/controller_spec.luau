--!strict
local serde = require("@lune/serde")
local t = require("../../lib/test")
local f = require("../../lib/factories")
local support = require("../sprite/support")
local clock = require("../../../cat/core/clock")
local fsAdapter = require("../../../cat/adapters/fs")
local jsonAdapter = require("../../../cat/adapters/json")
local kvAdapter = require("../../../cat/adapters/kv")
local paths = require("../../../cat/adapters/paths")
local commands = require("../../../cat/core/commands")
local controller = require("../../../cat/window/controller")
local presenter = require("../../../cat/window/presenter")

local describe, it, expect = t.describe, t.it, t.expect

local DIR = "/plugin"
local DATA = "/data"
local HIDDEN = "/* tern-cat overlay hidden */\n"

type World = {
	files: { [string]: string },
	kv: { [string]: any },
	css: { { name: string, source: string } },
	timers: { { ms: number, fn: (any) -> (), cancelled: boolean } },
	logs: { string },
	reads: { string },
	clock: clock.FakeClock,
	ports: controller.Ports,
}

local function encodeJson(value: any): string
	return serde.encode("json", value)
end

local function addPack(files: { [string]: string }, dir: string, id: string)
	local anims: { [string]: any } = {}
	for _, anim in { "idle", "pet", "sleep", "happy", "stare", "look", "wake" } do
		anims[anim] = {
			frames = { anim .. "_0.png", anim .. "_1.png" },
			durations_ms = { 200, 200 },
			loop = anim == "idle" or anim == "sleep",
			sheet = anim .. "_sheet.png",
		}
		files[dir .. "/" .. anim .. "_0.png"] = support.makePng({ width = 16, height = 16 })
		files[dir .. "/" .. anim .. "_1.png"] = support.makePng({ width = 16, height = 16 })
		files[dir .. "/" .. anim .. "_sheet.png"] = support.makePng({ width = 32, height = 16 })
	end
	files[dir .. "/pack.json"] = encodeJson({
		schema_version = 1,
		id = id,
		name = id,
		license = "CC0-1.0",
		canvas = { width = 16, height = 16 },
		animations = anims,
	})
end

local function rawFs(files: { [string]: string }, dirs: { [string]: boolean }, reads: { string }): fsAdapter.RawFs
	local mem = support.memoryFs(files)
	return {
		read = function(path: string, max: number?): string
			table.insert(reads, path)
			-- Like tern.fs.read with max_bytes: oversize files raise instead of being truncated.
			local whole = files[path]
			if whole and max and #whole > max then
				error("file exceeds max_bytes: " .. path)
			end
			local data = mem.read(path, max)
			if data == nil then
				error("not found: " .. path)
			end
			return data
		end,
		write = function(path: string, text: string)
			files[path] = text
		end,
		list = function(path: string): { string }
			local out = mem.list(path)
			if out == nil then
				error("not a dir: " .. path)
			end
			return out
		end,
		exists = function(path: string): boolean
			return mem.exists(path) or dirs[path] == true
		end,
		mkdir = function(path: string)
			dirs[path] = true
		end,
		remove = function(path: string)
			files[path] = nil
		end,
	}
end

local function world(opts: { config: any?, kv: any? }?): World
	local o = opts or {}
	local files: { [string]: string } = {}
	local dirs: { [string]: boolean } = {}
	addPack(files, DIR .. "/assets/packs/orange-menace", "orange-menace")
	addPack(files, DIR .. "/assets/packs/void", "void")
	if o.config then
		files[DATA .. "/config.json"] = encodeJson(o.config)
	end
	local kvStore: { [string]: any } = { state = o.kv }
	local reads: { string } = {}
	local w: any = {
		files = files,
		kv = kvStore,
		css = {},
		timers = {},
		logs = {},
		reads = reads,
		clock = clock.fake({ now_ms = 10000, wall_s = f.WALL_S, hour = 12 }),
	}
	w.ports = {
		clock = w.clock,
		wall_ms = function()
			return w.clock.wall_s() * 1000
		end,
		fs = fsAdapter.new(rawFs(files, dirs, reads)),
		json = jsonAdapter.new({
			encode = function(value: any, _pretty: boolean?): string
				return serde.encode("json", value)
			end,
			decode = function(text: string): any
				return serde.decode("json", text)
			end,
		}),
		kv = kvAdapter.new({
			get = function(key: string): any
				return kvStore[key]
			end,
			set = function(_key: string, _value: any)
				kvStore.__writes = (kvStore.__writes or 0) + 1
			end,
		}),
		paths = paths.fromPlugin({ dir = DIR, data = DATA }),
		css = function(name: string, source: string)
			table.insert(w.css, { name = name, source = source })
		end,
		timer = function(ms: number, fn: (any) -> ())
			local entry = { ms = ms, fn = fn, cancelled = false }
			table.insert(w.timers, entry)
			return {
				cancel = function(_self: any)
					entry.cancelled = true
				end,
			}
		end,
		base64 = function(bytes: string): string
			return "QUJD" .. tostring(#bytes)
		end,
		log = function(level: string, message: string)
			table.insert(w.logs, level .. ": " .. message)
		end,
		seed = 1234,
	}
	return w
end

local function pending(w: World)
	local out = {}
	for _, timer in w.timers do
		if not timer.cancelled then
			table.insert(out, timer)
		end
	end
	return out
end

-- Fires the single live timer after advancing the clock by its delay.
local function fire(w: World, info: any?)
	local live = pending(w)
	assert(#live == 1, `expected exactly one live timer, got {#live}`)
	local timer = live[1]
	timer.cancelled = true
	w.clock.advance(timer.ms)
	timer.fn(info)
end

local function lastCss(w: World): string
	local entry = w.css[#w.css]
	assert(entry, "no css installed")
	expect(entry.name).toBe("overlay")
	return entry.source
end

local function inbox(w: World): { [string]: any }
	local out = {}
	for path, text in w.files do
		if string.sub(path, 1, #DATA + 7) == DATA .. "/inbox/" then
			out[path] = serde.decode("json", text)
		end
	end
	return out
end

local function count(tbl: { [any]: any }): number
	local n = 0
	for _ in tbl do
		n += 1
	end
	return n
end

describe("window/controller start", function()
	it("installs the overlay sheet at load and schedules one timer", function()
		local w = world()
		local c = controller.new(w.ports)
		local ms = controller.start(c)
		expect(ms).toBeGreaterThanOrEqual(0)
		expect(#w.css).toBe(1)
		local css = lastCss(w)
		expect(css).toContain("data:image/png;base64,QUJD")
		expect(css).toContain("tern-cat-idle")
		expect(#pending(w)).toBe(1)
		expect(w.ports.fs.exists(DATA .. "/inbox")).toBe(true)
		expect(c.pack and c.pack.manifest.id).toBe("orange-menace")
	end)

	it("installs the hidden sheet when the overlay is off in config", function()
		local w = world({ config = { rendering = { overlay = false } } })
		controller.start(controller.new(w.ports))
		expect(lastCss(w)).toBe(HIDDEN)
	end)

	it("uses the appearance from config", function()
		local w = world({ config = { cat = { appearance = "void" } } })
		local c = controller.new(w.ports)
		controller.start(c)
		expect(c.pack and c.pack.manifest.id).toBe("void")
	end)

	-- A full pack scan inside one timer callback can exceed the 50 ms window budget, which
	-- disables every timer of that window (overlay, polling) until reload.
	it("finds a pack in a differently named folder over several ticks, one pack per tick", function()
		local w = world({ config = { cat = { appearance = "fancy" } } })
		addPack(w.files, DATA .. "/packs/a-folder", "other")
		addPack(w.files, DATA .. "/packs/my-cat", "fancy")
		addPack(w.files, DATA .. "/packs/z-folder", "zed")
		local c = controller.new(w.ports)
		controller.start(c)
		expect(c.pack and c.pack.manifest.id).toBe("orange-menace")
		local ticks = 0
		while not (c.pack and c.pack.manifest.id == "fancy") do
			local live = pending(w)
			expect(live[1].ms).toBeLessThanOrEqual(100)
			local before = #w.reads
			fire(w)
			ticks += 1
			local manifests = 0
			for i = before + 1, #w.reads do
				if string.sub(w.reads[i], -#"/pack.json") == "/pack.json" then
					manifests += 1
				end
			end
			expect(manifests).toBeLessThanOrEqual(1)
			assert(ticks < 20, "pack never selected")
		end
		expect(ticks).toBeGreaterThan(1)
		for _, line in w.logs do
			expect(line).notToContain("not available")
		end
	end)
end)

describe("window/controller loop", function()
	it("reinstalls the sheet only when the overlay changes", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		local timer = pending(w)[1]
		expect(timer.ms).toBe(0)
		timer.cancelled = true
		timer.fn(nil)
		expect(#w.css).toBe(1)
	end)

	it("reschedules itself with bounded delays and never busy-polls", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		for _ = 1, 50 do
			fire(w)
			local live = pending(w)
			expect(#live).toBe(1)
			expect(live[1].ms).toBeGreaterThanOrEqual(100)
			expect(live[1].ms).toBeLessThanOrEqual(5000)
		end
		expect(c.metrics.ticks).toBe(50)
	end)

	it("freezes to a still frame when Tern reduces motion", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		fire(w, { reduce_motion = true })
		expect(lastCss(w)).notToContain("@keyframes")
		fire(w, { reduce_motion = false })
		expect(c.presenter.tern_reduce_motion).toBe(false)
	end)

	it("picks up config.json edits on the slow poll", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		w.files[DATA .. "/config.json"] = encodeJson({ cat = { appearance = "void" }, rendering = { overlay = false } })
		local before = c.config.rendering.overlay
		expect(before).toBe(true)
		for _ = 1, 10 do
			fire(w)
		end
		expect(c.config.rendering.overlay).toBe(false)
		expect(c.pack and c.pack.manifest.id).toBe("void")
		expect(lastCss(w)).toBe(HIDDEN)
	end)

	it("hides the overlay while allow_visual_obscuring is off and shows it when turned back on", function()
		local w = world({ config = { behavior = { allow_visual_obscuring = false } } })
		local c = controller.new(w.ports)
		controller.start(c)
		expect(lastCss(w)).toBe(HIDDEN)
		w.files[DATA .. "/config.json"] = encodeJson({ behavior = { allow_visual_obscuring = true } })
		for _ = 1, 10 do
			fire(w)
		end
		expect(lastCss(w)).toContain("tern-cat-")
	end)

	it("adds pointer reactions from the pack's look and swat fallbacks, and drops them when turned off", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		local css = lastCss(w)
		-- The fixture pack has `look`, and `swat` falls back to `happy`.
		expect(css).toContain(":hover::after")
		expect(css).toContain(":active::before")
		expect(css).toContain("pointer-events: auto")
		w.files[DATA .. "/config.json"] = encodeJson({ behavior = { allow_pointer_reactions = false } })
		for _ = 1, 10 do
			fire(w)
		end
		css = lastCss(w)
		expect(css).toContain("tern-cat-")
		expect(css).notToContain(":hover")
		expect(css).notToContain(":active")
		expect(css).toContain("pointer-events: none")
	end)

	-- A symlinked or oversize config.json is not "no config": silently falling back to defaults
	-- would re-enable an overlay the user turned off.
	it("keeps the last good config and warns once when config.json becomes unreadable", function()
		local w = world({ config = { rendering = { overlay = false } } })
		local c = controller.new(w.ports)
		controller.start(c)
		expect(lastCss(w)).toBe(HIDDEN)
		w.files[DATA .. "/config.json"] = string.rep(" ", 300 * 1024) .. "{}"
		for _ = 1, 20 do
			fire(w)
		end
		expect(c.config.rendering.overlay).toBe(false)
		expect(lastCss(w)).toBe(HIDDEN)
		local warnings = 0
		for _, line in w.logs do
			if string.find(line, "could not be read", 1, true) then
				warnings += 1
				expect(string.sub(line, 1, 5)).toBe("warn:")
			end
		end
		expect(warnings).toBe(1)
		w.files[DATA .. "/config.json"] = encodeJson({ cat = { appearance = "void" }, rendering = { overlay = false } })
		for _ = 1, 10 do
			fire(w)
		end
		expect(c.pack and c.pack.manifest.id).toBe("void")
	end)

	it("uses defaults and warns when config.json is unreadable on first load", function()
		local w = world()
		w.files[DATA .. "/config.json"] = string.rep(" ", 300 * 1024) .. "{}"
		local c = controller.new(w.ports)
		controller.start(c)
		expect(c.pack and c.pack.manifest.id).toBe("orange-menace")
		local found = false
		for _, line in w.logs do
			found = found or string.find(line, "could not be read", 1, true) ~= nil
		end
		expect(found).toBe(true)
	end)

	-- Removing a pack from the block deletes its folder; every window must stop drawing it, both
	-- when the host switched config.json back to the default and when it could not.
	describe("when the selected pack is removed", function()
		local function withCalico(): (World, controller.Controller)
			local w = world({ config = { cat = { appearance = "calico" } } })
			addPack(w.files, DATA .. "/packs/calico", "calico")
			local c = controller.new(w.ports)
			controller.start(c)
			expect(c.pack and c.pack.manifest.id).toBe("calico")
			return w, c
		end

		local function deleteCalico(w: World)
			for path in table.clone(w.files) do
				if string.sub(path, 1, #DATA + 14) == DATA .. "/packs/calico/" then
					w.files[path] = nil
				end
			end
		end

		it("follows the host back to the default pack", function()
			local w, c = withCalico()
			deleteCalico(w)
			w.files[DATA .. "/config.json"] = encodeJson({ cat = { appearance = "orange-menace" } })
			for _ = 1, 10 do
				fire(w)
			end
			expect(c.pack and c.pack.manifest.id).toBe("orange-menace")
		end)

		it("falls back to the default pack while config.json still names it", function()
			local w, c = withCalico()
			deleteCalico(w)
			for _ = 1, 20 do
				fire(w)
			end
			expect(c.pack and c.pack.manifest.id).toBe("orange-menace")
			expect(c.packs.packs.calico).toBeNil()
		end)
	end)
end)

describe("window/controller intents", function()
	it("writes a validated gesture intent and reacts at once", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		local result = controller.request(c, "pet", {}, "window")
		expect(result.ok).toBe(true)
		local files = inbox(w)
		expect(count(files)).toBe(1)
		for path, body in files do
			expect(string.match(path, "/inbox/%d+%-%x%x%x%x%x%x%x%x%.json$") ~= nil).toBe(true)
			local intent = commands.validate(body)
			assert(intent, "intent")
			expect(intent.kind).toBe("pet")
			expect(intent.source).toBe("window")
		end
		expect(lastCss(w)).toContain("tern-cat-pet")
	end)

	it("rejects invalid requests without writing anything", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		local result = controller.request(c, "feed", { item = "keyboard" }, "carly")
		expect(result.ok).toBe(false)
		expect(result.error).toContain("item")
		expect(count(inbox(w))).toBe(0)
	end)

	it("toggles the overlay locally at once and asks the host to persist it", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		local result, visible = controller.toggleOverlay(c, "keyboard")
		expect(result.ok).toBe(true)
		expect(visible).toBe(false)
		expect(lastCss(w)).toBe(HIDDEN)
		local files = inbox(w)
		expect(count(files)).toBe(1)
		for _, body in files do
			expect(body.kind).toBe("set_config")
			expect(body.args.values["rendering.overlay"]).toBe(false)
		end
		local _, again = controller.toggleOverlay(c, "keyboard")
		expect(again).toBe(true)
		expect(lastCss(w)).toContain("tern-cat-")
	end)

	it("keeps the local toggle when config later agrees", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		controller.toggleOverlay(c, "window")
		w.files[DATA .. "/config.json"] = encodeJson({ rendering = { overlay = false } })
		for _ = 1, 5 do
			fire(w)
		end
		expect(c.presenter.overlay_override).toBeNil()
		expect(lastCss(w)).toBe(HIDDEN)
	end)

	it("sleeps immediately when snoozed locally", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		expect(controller.request(c, "snooze", { minutes = 30 }, "window").ok).toBe(true)
		expect(lastCss(w)).toContain("tern-cat-sleep")
	end)

	-- A looping or prompt-injected Carly turn must not drive a config/kv write storm on the host.
	it("rate-limits Carly requests to a small burst, then about ten a minute", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		for _ = 1, controller.RATE_LIMITS.carly.burst do
			expect(controller.request(c, "pet", {}, "carly").ok).toBe(true)
		end
		local n = count(inbox(w))
		local limited = controller.request(c, "pet", {}, "carly")
		expect(limited.ok).toBe(false)
		expect(limited.error).toBe("rate limited")
		expect(count(inbox(w))).toBe(n)
		w.clock.advance(6000)
		expect(controller.request(c, "pet", {}, "carly").ok).toBe(true)
		expect(controller.request(c, "pet", {}, "carly").ok).toBe(false)
	end)

	it("keeps keyboard and window requests generous and separate from Carly's budget", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		for _ = 1, controller.RATE_LIMITS.carly.burst do
			controller.request(c, "pet", {}, "carly")
		end
		for _ = 1, 5 do
			expect(controller.request(c, "pet", {}, "window").ok).toBe(true)
			expect(controller.request(c, "pet", {}, "keyboard").ok).toBe(true)
		end
		while controller.request(c, "pet", {}, "window").ok do
			assert(count(inbox(w)) < 60, "window requests never limited")
		end
		w.clock.advance(200)
		expect(controller.request(c, "pet", {}, "window").ok).toBe(true)
	end)

	-- If the host is not draining the inbox, producers must stop instead of piling up files.
	it("refuses to write when the inbox already holds more than 64 files", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		for i = 1, 65 do
			w.files[string.format("%s/inbox/%d-0000abcd.json", DATA, i)] = "{}"
		end
		local result = controller.request(c, "pet", {}, "window")
		expect(result.ok).toBe(false)
		expect(result.error).toContain("inbox")
		expect(count(inbox(w))).toBe(65)
		w.files[DATA .. "/inbox/1-0000abcd.json"] = nil
		expect(controller.request(c, "pet", {}, "window").ok).toBe(true)
	end)
end)

describe("window/controller shared state", function()
	local function envWith(rev: number, reaction: any?): any
		return f.envelope({ rev = rev, last_reaction = reaction })
	end

	it("mirrors a new, recent host reaction once", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		w.kv.state = envWith(
			2,
			{ at = f.WALL_S + 2.5, id = "react.command_ok", animation = "happy", reason = "A command succeeded." }
		)
		local installs = #w.css
		fire(w)
		fire(w)
		expect(lastCss(w)).toContain("tern-cat-happy")
		expect(#w.css).toBeGreaterThan(installs)
		local key = c.mirror_key
		fire(w)
		expect(c.mirror_key).toBe(key)
	end)

	-- The host never sees remote panes, so it may react while this window still runs a command.
	it("in focus mode skips host command reactions while this window runs a command, not gestures", function()
		local w = world({ config = { behavior = { focus_mode = true } } })
		local c = controller.new(w.ports)
		controller.start(c)
		controller.onWindowEvent(c, "command_started", { pane = 9, line = "ssh build-box make" })
		w.kv.state = envWith(
			2,
			{ at = f.WALL_S + 2.5, id = "react.command_ok", animation = "happy", reason = "A command succeeded." }
		)
		fire(w)
		fire(w)
		expect(lastCss(w)).notToContain("tern-cat-happy")
		w.kv.state = envWith(3, { at = f.WALL_S + 6, id = "gesture.pet", animation = "pet", reason = "x" })
		fire(w)
		fire(w)
		expect(lastCss(w)).toContain("tern-cat-pet")
	end)

	it("does not replay stale reactions after a reload", function()
		local w =
			world({ kv = envWith(5, { at = f.WALL_S - 60, id = "gesture.pet", animation = "pet", reason = "x" }) })
		controller.start(controller.new(w.ports))
		expect(lastCss(w)).notToContain("tern-cat-pet")
	end)

	it("skips the host echo of its own optimistic gesture", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		controller.request(c, "pet", {}, "window")
		local seq = c.presenter.seq
		w.kv.state =
			envWith(3, { at = f.WALL_S + 0.4, id = "gesture.pet", animation = "pet", reason = "You petted the cat." })
		fire(w)
		fire(w)
		expect(c.presenter.seq).toBeLessThanOrEqual(seq + 2)
		expect(c.mirror_key).notToBeNil()
		expect(c.presenter.engine.current and c.presenter.engine.current.id ~= "gesture.perform").toBe(true)
	end)

	it("caches the Carly context and refreshes it from kv", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		expect(controller.context(c)).toContain('Tern Cat "Orange Menace"')
		w.kv.state = f.envelope({ rev = 9, profile = { stats = { pets = 41 } } })
		fire(w)
		fire(w)
		expect(controller.context(c)).toContain("41 pets")
	end)

	it("never writes kv", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		controller.request(c, "pet", {}, "window")
		controller.toggleOverlay(c, "window")
		for _ = 1, 5 do
			fire(w)
		end
		expect(w.kv.__writes).toBeNil()
	end)
end)

describe("window/controller window events", function()
	it("reacts to this window's events without keeping the command line", function()
		local w = world({ config = { behavior = { reaction_sample_rate = 1 } } })
		local c = controller.new(w.ports)
		controller.start(c)
		controller.onWindowEvent(c, "command_started", { pane = 1, line = "sudo cat /etc/top-secret" })
		expect(lastCss(w)).toContain("tern-cat-stare")
		expect(count(inbox(w))).toBe(0)
		for _, entry in w.css do
			expect(entry.source).notToContain("top-secret")
		end
		expect(t.render(c)).notToContain("top-secret")
	end)

	it("does not replay the host's reaction to a command this window already reacted to", function()
		local w = world({ config = { behavior = { reaction_sample_rate = 1 } } })
		local c = controller.new(w.ports)
		controller.start(c)
		controller.onWindowEvent(c, "command_started", { pane = 1, line = "sudo ls" })
		expect(c.recent.command_at).notToBeNil()
		w.kv.state = f.envelope({
			rev = 4,
			last_reaction = { at = f.WALL_S + 0.2, id = "react.sudo", animation = "stare", reason = "x" },
		})
		local seq = c.presenter.seq
		fire(w)
		local current = c.presenter.engine.current
		expect(current and current.id ~= "gesture.perform").toBe(true)
		expect(c.presenter.seq).toBeLessThanOrEqual(seq + 1)
	end)

	it("ignores events while the overlay is hidden", function()
		local w = world({ config = { rendering = { overlay = false }, behavior = { reaction_sample_rate = 1 } } })
		local c = controller.new(w.ports)
		controller.start(c)
		local seq = c.presenter.seq
		controller.onWindowEvent(c, "command_started", { pane = 1, line = "sudo ls" })
		expect(c.presenter.seq).toBe(seq)
	end)

	it("in focus mode a running command suppresses its own reaction; its finish reacts again", function()
		local w = world({ config = { behavior = { focus_mode = true, reaction_sample_rate = 1 } } })
		local c = controller.new(w.ports)
		controller.start(c)
		controller.onWindowEvent(c, "command_started", { pane = 1, line = "sudo ls" })
		expect(lastCss(w)).notToContain("tern-cat-stare")
		expect(presenter.environment(c.presenter).busy).toBe(true)
		controller.onWindowEvent(c, "command_finished", { pane = 1, line = "sudo ls", status = 0, took_ms = 20000 })
		expect(presenter.environment(c.presenter).busy).toBe(false)
		local current = c.presenter.engine.current
		expect(current and string.sub(current.id, 1, 6)).toBe("react.")
	end)

	it("tracks running commands while the overlay is hidden", function()
		local w = world({ config = { rendering = { overlay = false }, behavior = { focus_mode = true } } })
		local c = controller.new(w.ports)
		controller.start(c)
		controller.onWindowEvent(c, "command_started", { pane = 1, line = "make" })
		expect(presenter.environment(c.presenter).busy).toBe(true)
	end)
end)

describe("window/controller.setCovered", function()
	it("hides the overlay under a floating cat block and restores it", function()
		local w = world()
		local c = controller.new(w.ports)
		controller.start(c)
		controller.setCovered(c, true)
		expect(lastCss(w)).toBe(HIDDEN)
		local n = #w.css
		controller.setCovered(c, true)
		expect(#w.css).toBe(n)
		fire(w, { covered = false })
		expect(lastCss(w)).toContain("tern-cat-")
	end)
end)

describe("window/controller.confirmReset", function()
	it("requires a second run within ten seconds", function()
		local w = world()
		local c = controller.new(w.ports)
		expect(controller.confirmReset(c)).toBe(false)
		w.clock.advance(5000)
		expect(controller.confirmReset(c)).toBe(true)
		expect(controller.confirmReset(c)).toBe(false)
		w.clock.advance(10001)
		expect(controller.confirmReset(c)).toBe(false)
	end)
end)
