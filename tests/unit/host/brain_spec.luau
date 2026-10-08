--!strict
local t = require("../../lib/test")
local support = require("./support")
local lfs = require("@lune/fs")
local serde = require("@lune/serde")
local clockMod = require("../../../cat/core/clock")
local paths = require("../../../cat/adapters/paths")
local configFile = require("../../../cat/adapters/config")
local brain = require("../../../cat/host/brain")
local running = require("../../../cat/core/running")

local describe, it, expect = t.describe, t.it, t.expect

local DATA = "/data"
local WALL = 1767225600

type Env = {
	m: support.MemFs,
	kv: support.MemKv,
	clock: any,
	logs: { string },
	runs: { { string } },
	deps: brain.Deps,
}

local function setup(opts: { files: { [string]: string }?, kv: { [string]: any }?, os: string? }?): Env
	local o = opts or {}
	local m = support.memFs(o.files, true)
	local kv = support.memKv(o.kv)
	local fake = clockMod.fake({ now_ms = 1000, wall_s = WALL, hour = 14 })
	local clock = {
		now_ms = fake.now_ms,
		wall_s = fake.wall_s,
		local_hm = fake.local_hm,
		wall_precise = function()
			return fake.now_ms() / 1000 + WALL
		end,
		advance = fake.advance,
	}
	local logs: { string } = {}
	local runs: { { string } } = {}
	local deps: brain.Deps = {
		fs = m.fs,
		json = support.json(),
		kv = kv.kv,
		clock = clock :: any,
		paths = paths.fromPlugin({ dir = "", data = DATA }),
		os = o.os or "macos",
		seed = 7,
		log = function(level: string, msg: string)
			table.insert(logs, level .. ": " .. msg)
		end,
		run = function(argv: { string }, _opts: any, cb: (any) -> ())
			table.insert(runs, argv)
			cb({ status = 0, stdout = "", stderr = "", timed_out = false })
		end,
	}
	return { m = m, kv = kv, clock = clock, logs = logs, runs = runs, deps = deps }
end

local function intent(id: string, kind: string, args: { [string]: any }?): { [string]: any }
	return { intent_id = id, at = WALL, kind = kind, source = "window", args = args or {} }
end

local function writeIntent(e: Env, name: string, text: string)
	e.m.files[DATA .. "/inbox/" .. name] = text
end

local function hasLog(e: Env, needle: string): boolean
	for _, line in e.logs do
		if string.find(line, needle, 1, true) then
			return true
		end
	end
	return false
end

local function cmdSeen(env: any): number
	local n = 0
	for _, id in env.seen do
		if string.sub(id, 1, 4) == "cmd-" then
			n += 1
		end
	end
	return n
end

local function countLogs(e: Env, needle: string): number
	local n = 0
	for _, line in e.logs do
		if string.find(line, needle, 1, true) then
			n += 1
		end
	end
	return n
end

-- Copies a bundled pack into the fake user packs folder under another folder name and id.
local function copyPack(files: { [string]: string }, from: string, folder: string, id: string)
	local function walk(rel: string)
		local dir = "assets/packs/" .. from .. (if rel == "" then "" else "/" .. rel)
		for _, entry in lfs.readDir(dir) do
			local sub = if rel == "" then entry else rel .. "/" .. entry
			local path = dir .. "/" .. entry
			if lfs.isDir(path) then
				walk(sub)
			else
				files[DATA .. "/packs/" .. folder .. "/" .. sub] = lfs.readFile(path)
			end
		end
	end
	walk("")
	local key = DATA .. "/packs/" .. folder .. "/pack.json"
	local manifest = serde.decode("json", files[key])
	manifest.id = id
	files[key] = serde.encode("json", manifest)
end

-- Saved state of a cat that was petted once (as written by a previous session).
local function savedCat(): ({ [string]: any }, string)
	local first = setup()
	local b1 = brain.load(first.deps)
	brain.localIntent(b1, "pet")
	return first.kv.data, first.m.files[DATA .. "/config.json"]
end

describe("brain", function()
	describe("load", function()
		it("creates config.json from the example, the inbox and a fresh saved cat", function()
			local e = setup()
			local b = brain.load(e.deps)
			expect(e.m.files[DATA .. "/config.json"]).notToBeNil()
			expect(e.m.dirs[DATA .. "/inbox"]).toBe(true)
			expect(b.config.cat.appearance).toBe("orange-menace")
			expect(e.kv.sets).toBe(1)
			expect(e.kv.data.state.profile.cat_id).toBe(b.env.profile.cat_id)
			expect(#b.notes).toBe(0)
		end)

		it("validates only the selected and default packs at load", function()
			local e = setup()
			local b = brain.load(e.deps)
			expect((b.pack :: any).manifest.id).toBe("orange-menace")
			expect(b.packs.void).toBeNil()
			expect(b.packs.tuxedo).toBeNil()
			expect(#brain.availablePacks(b)).toBeGreaterThanOrEqual(3)
			expect(b.packs.void).notToBeNil()
		end)

		it("restores a saved cat without rewriting it", function()
			local first = setup()
			local b1 = brain.load(first.deps)
			b1.env.profile.stats.pets = 5
			local saved = first.kv.data
			saved.state.profile.stats.pets = 5
			local e =
				setup({ kv = saved, files = { [DATA .. "/config.json"] = first.m.files[DATA .. "/config.json"] } })
			local b = brain.load(e.deps)
			expect(b.env.profile.cat_id).toBe(b1.env.profile.cat_id)
			expect(b.env.profile.stats.pets).toBe(5)
			expect(e.kv.sets).toBe(0)
		end)

		it("recovers from corrupt saved state with a note", function()
			local e = setup({ kv = { state = "garbage" } })
			local b = brain.load(e.deps)
			expect(#b.notes).toBe(1)
			expect(e.kv.sets).toBe(1)
			expect(e.kv.data.state.profile.cat_id).toBe(b.env.profile.cat_id)
			expect(e.kv.data.state.journal[1].kind).toBe("recovery")
		end)

		it("moves an unparsable kv.json aside and starts fresh", function()
			local e = setup({ files = { [DATA .. "/kv.json"] = '{"state": {"rev": 3, ' } })
			e.kv.failGet = true
			e.kv.blocked = function()
				return e.m.files[DATA .. "/kv.json"] ~= nil
			end
			local b = brain.load(e.deps)
			expect(#b.notes).toBe(1)
			expect(e.kv.sets).toBe(1)
			expect(e.m.files[DATA .. "/kv.json"]).toBeNil()
			expect(e.m.files[DATA .. "/kv.json.corrupt-" .. WALL]).toBe('{"state": {"rev": 3, ')
		end)

		it("keeps a corrupt kv.json and claims no backup when the backup cannot be written", function()
			local e = setup({
				files = { [DATA .. "/kv.json"] = '{"state": {"rev": 3, ', [DATA .. "/config.json"] = "{}" },
			})
			e.kv.failGet = true
			e.kv.blocked = function()
				return e.m.files[DATA .. "/kv.json"] ~= nil
			end
			e.m.failWrites = true
			local b = brain.load(e.deps)
			expect(e.m.files[DATA .. "/kv.json"]).toBe('{"state": {"rev": 3, ')
			expect(e.m.files[DATA .. "/kv.json.corrupt-" .. WALL]).toBeNil()
			for _, note in b.notes do
				expect(string.find(note, "backup", 1, true)).toBeNil()
			end
		end)

		it("never overwrites a readable kv.json after a transient read error, and adopts it later", function()
			local saved, config = savedCat()
			local e = setup({ kv = saved, files = { [DATA .. "/config.json"] = config, [DATA .. "/kv.json"] = "{}" } })
			e.kv.failGet = true
			local b = brain.load(e.deps)
			brain.localIntent(b, "poke")
			e.clock.advance(10000)
			brain.tick(b)
			expect(e.kv.sets).toBe(0)
			expect(e.kv.data.state.profile.stats.pets).toBe(1)
			e.kv.failGet = false
			e.clock.advance(10000)
			brain.pollInbox(b)
			expect(b.env.profile.cat_id).toBe(saved.state.profile.cat_id)
			expect(b.env.profile.stats.pets).toBe(1)
			expect(#b.notes).toBe(0)
		end)

		it("finds user packs whose folder name differs from the id, like the window does", function()
			local files: { [string]: string } = { [DATA .. "/config.json"] = '{"cat":{"appearance":"calico"}}' }
			copyPack(files, "void", "Calico", "calico")
			local e = setup({ files = files })
			local b = brain.load(e.deps)
			expect((b.pack :: any).manifest.id).toBe("calico")
			expect(b.pack_note).toBeNil()
		end)

		it("shows a note and never overwrites a config.json it cannot read (symlink, oversize)", function()
			local user = '{"rendering":{"overlay":false},"cat":{"name":"Biscuit"}}'
			local e = setup({ files = { [DATA .. "/config.json"] = user } })
			e.m.unreadable[DATA .. "/config.json"] = true
			local b = brain.load(e.deps)
			expect(#b.notes).toBe(1)
			local ok, err = brain.setConfig(b, { ["rendering.overlay"] = true })
			expect(ok).toBe(false)
			expect(err).notToBeNil()
			local out = brain.applyIntent(b, intent("w-9", "set_overlay", { enabled = true }))
			expect(out.ok).toBe(false)
			expect(e.m.files[DATA .. "/config.json"]).toBe(user)
			expect(countLogs(e, "config.json exists but could not be read")).toBe(1)
			expect(brain.pollConfig(b)).toBe(false)
			expect(#b.notes).toBe(1)
		end)

		it("recovers when kv.json is corrupted while running", function()
			local e = setup()
			local b = brain.load(e.deps)
			e.m.files[DATA .. "/kv.json"] = "garbage"
			e.kv.blocked = function()
				return e.m.files[DATA .. "/kv.json"] ~= nil
			end
			brain.localIntent(b, "pet")
			expect(e.kv.data.state.profile.stats.pets).toBe(1)
			expect(e.m.files[DATA .. "/kv.json.corrupt-" .. WALL]).toBe("garbage")
			expect(#b.notes).toBe(1)
		end)

		it("logs a persistent save failure once", function()
			local e = setup()
			local b = brain.load(e.deps)
			e.kv.blocked = function()
				return true
			end
			brain.localIntent(b, "pet")
			brain.localIntent(b, "poke")
			local n = 0
			for _, line in e.logs do
				if string.find(line, "could not save state", 1, true) then
					n += 1
				end
			end
			expect(n).toBe(1)
		end)

		it("uses defaults with a note when config.json is not valid JSON", function()
			local e = setup({ files = { [DATA .. "/config.json"] = "{ nope" } })
			local b = brain.load(e.deps)
			expect(b.config.cat.appearance).toBe("orange-menace")
			expect(#b.notes).toBe(1)
			expect(e.m.files[DATA .. "/config.json"]).toBe("{ nope")
		end)

		it("falls back to the default pack when the chosen one is missing", function()
			local e = setup({ files = { [DATA .. "/config.json"] = '{"cat":{"appearance":"nope"}}' } })
			local b = brain.load(e.deps)
			expect((b.pack :: any).manifest.id).toBe("orange-menace")
			expect(b.pack_note).notToBeNil()
		end)
	end)

	describe("host hooks", function()
		it("counts each finished command once and never stores command text", function()
			local e = setup()
			local b = brain.load(e.deps)
			brain.onCommandFinished(b, { pane = 3, category = "build", status = 0, took_ms = 20 })
			brain.onCommandFinished(b, { pane = 3, category = "test", status = 1, took_ms = 20 })
			e.clock.advance(2000)
			brain.pollInbox(b)
			expect(cmdSeen(b.env)).toBe(2)
			expect(cmdSeen(e.kv.data.state)).toBe(2)
			expect(b.env.profile.fail_streak).toBe(1)
		end)

		it("coalesces a burst of finished commands into one save and no re-render", function()
			local e = setup({ files = { [DATA .. "/config.json"] = '{"behavior":{"allow_command_reactions":false}}' } })
			local b = brain.load(e.deps)
			local whys: { string } = {}
			brain.subscribe(b, function(why: string)
				table.insert(whys, why)
			end)
			local sets = e.kv.sets
			for _ = 1, 20 do
				e.clock.advance(50)
				brain.onCommandFinished(b, { pane = 1, category = "build", status = 0, took_ms = 5 })
				brain.pollInbox(b)
			end
			e.clock.advance(2000)
			brain.pollInbox(b)
			expect(e.kv.sets - sets).toBe(1)
			expect(cmdSeen(e.kv.data.state)).toBe(20)
			expect(#whys).toBe(0)
		end)

		it("marks reactions and records the last reaction", function()
			local e = setup({ files = { [DATA .. "/config.json"] = '{"behavior":{"activity":"chaos"}}' } })
			local b = brain.load(e.deps)
			local reactions = 0
			for i = 1, 20 do
				e.clock.advance(60000)
				brain.onCommandFinished(b, { pane = 1, category = "other", status = i % 2, took_ms = 5 })
			end
			reactions = b.env.profile.stats.command_reactions
			expect(reactions).toBeGreaterThan(0)
			expect((b.env.last_reaction :: any).id).notToBeNil()
			expect(string.sub((b.env.last_reaction :: any).id, 1, 6)).toBe("react.")
		end)

		it("reacts to pane events without touching stats", function()
			local e = setup()
			local b = brain.load(e.deps)
			local rev = b.env.rev
			brain.onPaneEvent(b, 2, "cwd")
			brain.onPaneEvent(b, 2, "exited")
			expect(b.env.profile.stats.command_reactions).toBe(0)
			expect(b.env.rev >= rev).toBe(true)
		end)

		describe("focus mode", function()
			local FOCUS = '{"behavior":{"focus_mode":true,"reaction_sample_rate":1,"reaction_cooldown_s":0}}'

			it("stays busy while any pane runs a command; the last finish still reacts", function()
				local e = setup({ files = { [DATA .. "/config.json"] = FOCUS } })
				local b = brain.load(e.deps)
				brain.onCommandStarted(b, { pane = 1, category = "build" })
				brain.onCommandStarted(b, { pane = 2, category = "build" })
				expect(brain.environment(b).busy).toBe(true)
				e.clock.advance(5000)
				brain.onCommandFinished(b, { pane = 1, category = "build", status = 0, took_ms = 5000 })
				expect(brain.environment(b).busy).toBe(true)
				expect(b.env.last_reaction).toBeNil()
				expect(cmdSeen(b.env)).toBe(1)
				e.clock.advance(5000)
				brain.onCommandFinished(b, { pane = 2, category = "build", status = 0, took_ms = 10000 })
				expect(brain.environment(b).busy).toBe(false)
				expect(string.sub((b.env.last_reaction :: any).id, 1, 6)).toBe("react.")
			end)

			it("a pane that exits mid-command stops counting as busy", function()
				local e = setup({ files = { [DATA .. "/config.json"] = FOCUS } })
				local b = brain.load(e.deps)
				brain.onCommandStarted(b, { pane = 5, category = "other" })
				brain.onPaneEvent(b, 5, "exited")
				expect(brain.environment(b).busy).toBe(false)
			end)

			it("a command whose finish was missed stops counting after the safety timeout", function()
				local e = setup({ files = { [DATA .. "/config.json"] = FOCUS } })
				local b = brain.load(e.deps)
				brain.onCommandStarted(b, { pane = 1, category = "other" })
				e.clock.advance(running.STALE_MS - 1)
				expect(brain.environment(b).busy).toBe(true)
				e.clock.advance(1)
				expect(brain.environment(b).busy).toBe(false)
			end)

			it("is never busy with focus mode off, even while commands run", function()
				local e = setup()
				local b = brain.load(e.deps)
				brain.onCommandStarted(b, { pane = 1, category = "other" })
				expect(brain.environment(b).busy).toBe(false)
			end)
		end)
	end)

	describe("intents", function()
		it("applies inbox gestures once, reacts and deletes the files", function()
			local e = setup()
			local b = brain.load(e.deps)
			local seq = b.decision_seq
			writeIntent(e, "100-0000000a.json", '{"intent_id":"w-1","at":1,"kind":"pet","source":"window","args":{}}')
			writeIntent(e, "101-0000000b.json", '{"intent_id":"w-1","at":1,"kind":"pet","source":"window","args":{}}')
			expect(brain.pollInbox(b)).toBe(2)
			expect(b.env.profile.stats.pets).toBe(1)
			expect(e.kv.data.state.profile.stats.pets).toBe(1)
			expect((b.engine.current :: any).id).toBe("gesture.pet")
			expect((b.env.last_reaction :: any).id).toBe("gesture.pet")
			expect(b.decision_seq).toBe(seq + 1)
			expect(e.m.files[DATA .. "/inbox/100-0000000a.json"]).toBeNil()
		end)

		it("discards malformed inbox files after the grace period without crashing", function()
			local e = setup()
			local b = brain.load(e.deps)
			writeIntent(e, "100-0000000a.json", "{broken")
			writeIntent(e, "101-0000000b.json", '{"intent_id":"x","at":1,"kind":"explode","source":"window"}')
			brain.pollInbox(b)
			expect(hasLog(e, "intent rejected")).toBe(true)
			e.clock.advance(6000)
			brain.pollInbox(b)
			expect(e.m.files[DATA .. "/inbox/100-0000000a.json"]).toBeNil()
			expect(hasLog(e, "discarded 100-0000000a.json")).toBe(true)
		end)

		it("writes config changes into the user's own config.json", function()
			local user = '{"cat":{"name":"Biscuit"},"zzz_custom":{"keep":true},"behavior":{"activity":"zen"}}'
			local e = setup({ files = { [DATA .. "/config.json"] = user } })
			local b = brain.load(e.deps)
			brain.applyIntent(b, intent("w-2", "set_overlay", { enabled = false }))
			local written = support.json().decode(e.m.files[DATA .. "/config.json"])
			expect(written.rendering.overlay).toBe(false)
			expect(written.cat.name).toBe("Biscuit")
			expect(written.zzz_custom.keep).toBe(true)
			expect(written.behavior.activity).toBe("zen")
			expect(written.personality).toBeNil()
			expect(b.config.rendering.overlay).toBe(false)
		end)

		it("removes a setting on REMOVE (reset to default)", function()
			local e = setup({ files = { [DATA .. "/config.json"] = '{"sound":{"volume":0.9}}' } })
			local b = brain.load(e.deps)
			brain.setConfig(b, { ["sound.volume"] = configFile.REMOVE, ["needs.enabled"] = false })
			local written = support.json().decode(e.m.files[DATA .. "/config.json"])
			expect(written.sound.volume).toBeNil()
			expect(written.needs.enabled).toBe(false)
			expect(b.config.sound.volume).toBe(0.25)
		end)

		it("backs up an unreadable config.json before writing settings", function()
			local e = setup({ files = { [DATA .. "/config.json"] = "{ nope" } })
			local b = brain.load(e.deps)
			brain.setConfig(b, { ["rendering.overlay"] = false })
			expect(e.m.files[DATA .. "/config.json.broken-" .. WALL]).toBe("{ nope")
			expect(b.config.rendering.overlay).toBe(false)
		end)

		it("snoozes into sleep and wakes on unsnooze", function()
			local e = setup()
			local b = brain.load(e.deps)
			brain.applyIntent(b, intent("w-3", "snooze", { minutes = 30 }))
			expect(brain.environment(b).snoozed).toBe(true)
			expect((b.engine.current :: any).animation).toBe("sleep")
			brain.applyIntent(b, intent("w-4", "unsnooze"))
			expect(brain.environment(b).snoozed).toBe(false)
		end)

		it("plays wake on unsnooze even when the cat is not rested, like the overlay does", function()
			for seed = 1, 10 do
				local e = setup()
				e.deps.seed = seed
				local b = brain.load(e.deps)
				b.env.profile.needs.energy = 0.6
				brain.applyIntent(b, intent("w-3", "snooze", { minutes = 30 }))
				e.clock.advance(60000)
				brain.tick(b)
				brain.applyIntent(b, intent("w-4", "unsnooze"))
				expect((b.engine.current :: any).animation).toBe("wake")
				expect(b.engine.posture).toBe("awake")
			end
		end)

		it("exports the identity to the exports folder", function()
			local e = setup()
			local b = brain.load(e.deps)
			local out = brain.applyIntent(b, intent("w-5", "export_identity"))
			expect(out.kind).toBe("export_identity")
			local text = e.m.files[out.path]
			expect(text).notToBeNil()
			local doc = support.json().decode(text)
			expect(doc.profile.cat_id).toBe(b.env.profile.cat_id)
		end)

		it("resets the identity to a new cat", function()
			local e = setup()
			local b = brain.load(e.deps)
			local old = b.env.profile.cat_id
			brain.localIntent(b, "pet")
			local out = brain.applyIntent(b, intent("w-6", "reset_identity"))
			expect(out.kind).toBe("reset_identity")
			expect(b.env.profile.cat_id ~= old).toBe(true)
			expect(b.env.profile.stats.pets).toBe(0)
		end)
	end)

	describe("engine", function()
		it("schedules the next tick at the decision end, clamped to 0.5..5 s", function()
			local e = setup()
			local b = brain.load(e.deps)
			local d = brain.nextDelay(b)
			expect(d >= brain.MIN_TICK_MS and d <= brain.MAX_TICK_MS).toBe(true)
			for _ = 1, 50 do
				e.clock.advance(brain.tick(b))
			end
			expect(brain.nextDelay(b) >= brain.MIN_TICK_MS).toBe(true)
		end)

		it("persists only when the envelope changed", function()
			local e = setup()
			local b = brain.load(e.deps)
			local sets = e.kv.sets
			for _ = 1, 5 do
				e.clock.advance(brain.tick(b))
			end
			expect(e.kv.sets).toBe(sets)
		end)

		it("lets a napping cat regain energy while Tern stays open", function()
			local e = setup()
			local b = brain.load(e.deps)
			b.env.profile.needs.energy = 0.3
			b.engine.posture = "asleep"
			local elapsed = 0
			while elapsed < 3600 * 1000 do
				local wait = brain.tick(b)
				e.clock.advance(wait)
				elapsed += wait
			end
			expect(b.engine.posture).toBe("asleep")
			expect(b.env.profile.needs.energy).toBeGreaterThan(0.38)
		end)

		it("keeps needs moving in session when offline simulation is capped to 0 hours", function()
			local e = setup({ files = { [DATA .. "/config.json"] = '{"needs":{"offline_hours_cap":0}}' } })
			local b = brain.load(e.deps)
			local hunger = b.env.profile.needs.hunger
			for _ = 1, 3 do
				e.clock.advance(61000)
				brain.tick(b)
			end
			expect(b.env.profile.needs.hunger).toBeGreaterThan(hunger)
		end)

		it("does nothing while frozen", function()
			local e = setup()
			local b = brain.load(e.deps)
			brain.setTestMode(b, 3, true)
			local current = b.engine.current
			e.clock.advance(60000)
			brain.tick(b)
			expect(b.engine.current).toBe(current)
		end)

		it("notifies subscribers on reactions", function()
			local e = setup()
			local b = brain.load(e.deps)
			local whys: { string } = {}
			brain.subscribe(b, function(why: string)
				table.insert(whys, why)
			end)
			brain.localIntent(b, "poke")
			expect(#whys).toBeGreaterThan(0)
		end)
	end)

	describe("config polling", function()
		it("reloads when config.json changes on disk", function()
			local e = setup()
			local b = brain.load(e.deps)
			expect(brain.pollConfig(b)).toBe(false)
			e.m.files[DATA .. "/config.json"] = '{"cat":{"appearance":"void"}}'
			expect(brain.pollConfig(b)).toBe(true)
			expect((b.pack :: any).manifest.id).toBe("void")
		end)

		it("recreates a deleted config.json", function()
			local e = setup()
			local b = brain.load(e.deps)
			e.m.files[DATA .. "/config.json"] = nil
			brain.pollConfig(b)
			expect(e.m.files[DATA .. "/config.json"]).notToBeNil()
		end)
	end)

	-- Removal deletes a folder recursively, so it must only ever touch a user-installed pack, and
	-- a cat whose pack disappears must fall back to the default instead of a missing appearance.
	describe("removing packs", function()
		local function withCalico(appearance: string?): (Env, brain.Brain)
			local files: { [string]: string } = {}
			if appearance then
				files[DATA .. "/config.json"] = `\{"cat":\{"appearance":"{appearance}"}}`
			end
			copyPack(files, "void", "calico", "calico")
			local e = setup({ files = files })
			return e, brain.load(e.deps)
		end

		local function ids(b: brain.Brain): { string }
			local out = {}
			for _, pack in brain.availablePacks(b) do
				table.insert(out, pack.manifest.id)
			end
			return out
		end

		local function packFiles(e: Env, folder: string): number
			local n = 0
			local prefix = DATA .. "/packs/" .. folder .. "/"
			for p in e.m.files do
				if string.sub(p, 1, #prefix) == prefix then
					n += 1
				end
			end
			return n
		end

		it("deletes a user pack's folder and stops offering it", function()
			local e, b = withCalico(nil)
			expect(ids(b)).toContain("calico")
			local out = brain.removePack(b, "calico")
			expect(out.ok).toBe(true)
			expect(out.name).toBe("Void")
			expect(out.switched).toBe(false)
			expect(e.m.removed).toEqual({ DATA .. "/packs/calico" })
			expect(packFiles(e, "calico")).toBe(0)
			expect(ids(b)).notToContain("calico")
			expect(b.config.cat.appearance).toBe("orange-menace")
		end)

		it("switches the cat back to the default pack when the selected pack is removed", function()
			local e, b = withCalico("calico")
			expect((b.pack :: any).manifest.id).toBe("calico")
			local out = brain.removePack(b, "calico")
			expect(out.ok).toBe(true)
			expect(out.switched).toBe(true)
			expect(b.config.cat.appearance).toBe("orange-menace")
			expect((b.pack :: any).manifest.id).toBe("orange-menace")
			expect(b.pack_note).toBeNil()
			local saved = serde.decode("json", e.m.files[DATA .. "/config.json"])
			expect(saved.cat.appearance).toBe("orange-menace")
		end)

		it("still removes the pack and shows the default when config.json cannot be written", function()
			local e, b = withCalico("calico")
			e.m.unreadable[DATA .. "/config.json"] = true
			local out = brain.removePack(b, "calico")
			expect(out.ok).toBe(true)
			expect(out.switched).toBe(false)
			expect(out.config_error).notToBeNil()
			expect(packFiles(e, "calico")).toBe(0)
			expect((b.pack :: any).manifest.id).toBe("orange-menace")
		end)

		it("never removes a bundled pack", function()
			local e, b = withCalico(nil)
			local out = brain.removePack(b, "void")
			expect(out.ok).toBe(false)
			expect(out.error).toContain("bundled")
			expect(#e.m.removed).toBe(0)
			expect(ids(b)).toContain("void")
		end)

		it("never removes a folder outside the user packs folder", function()
			local e, b = withCalico(nil)
			brain.availablePacks(b)
			for _, root in { DATA, DATA .. "/packs", DATA .. "/packs/../inbox", "/elsewhere/calico" } do
				b.packs.calico.root = root
				local out = brain.removePack(b, "calico")
				expect(out.ok).toBe(false)
				expect(out.error).notToBeNil()
			end
			expect(#e.m.removed).toBe(0)
			expect(packFiles(e, "calico")).toBeGreaterThan(0)
		end)

		it("counts a folder already deleted by hand as removed and refreshes the list", function()
			local e, b = withCalico("calico")
			brain.availablePacks(b)
			for path in table.clone(e.m.files) do
				if string.sub(path, 1, #DATA + 14) == DATA .. "/packs/calico/" then
					e.m.files[path] = nil
				end
			end
			local out = brain.removePack(b, "calico")
			expect(out.ok).toBe(true)
			expect(out.switched).toBe(true)
			expect(#e.m.removed).toBe(0)
			expect(ids(b)).notToContain("calico")
		end)

		it("reports unknown packs and failed deletes without changing anything", function()
			local e, b = withCalico("calico")
			expect(brain.removePack(b, "nope").ok).toBe(false)
			e.m.failRemoves = true
			local out = brain.removePack(b, "calico")
			expect(out.ok).toBe(false)
			expect(out.error).notToBeNil()
			expect(b.config.cat.appearance).toBe("calico")
			expect(ids(b)).toContain("calico")
		end)

		it("offers a same-id pack from another folder once the first one is removed", function()
			local files: { [string]: string } = {}
			copyPack(files, "void", "calico", "calico")
			copyPack(files, "tuxedo", "calico-copy", "calico")
			local e = setup({ files = files })
			local b = brain.load(e.deps)
			expect(ids(b)).toContain("calico")
			expect(b.packs.calico.root).toBe(DATA .. "/packs/calico")
			expect(brain.removePack(b, "calico").ok).toBe(true)
			expect(ids(b)).toContain("calico")
			expect(b.packs.calico.root).toBe(DATA .. "/packs/calico-copy")
		end)
	end)

	describe("sound", function()
		it("stays silent by default", function()
			local e = setup()
			local b = brain.load(e.deps)
			brain.localIntent(b, "pet")
			expect(#e.runs).toBe(0)
		end)

		it("plays the decision's sound through the detected player when enabled", function()
			local e = setup({
				files = { [DATA .. "/config.json"] = '{"sound":{"enabled":true}}', ["/usr/bin/afplay"] = "" },
			})
			local b = brain.load(e.deps)
			brain.localIntent(b, "pet")
			expect(#e.runs).toBe(1)
			expect(e.runs[1][1]).toBe("/usr/bin/afplay")
			expect(e.runs[1][4]).toBe("assets/sounds/default/purr.wav")
			brain.localIntent(b, "pet")
			expect(#e.runs).toBe(1)
		end)

		it("falls back to silence when no player exists", function()
			local e = setup({ os = "windows", files = { [DATA .. "/config.json"] = '{"sound":{"enabled":true}}' } })
			local b = brain.load(e.deps)
			brain.localIntent(b, "pet")
			expect(#e.runs).toBe(0)
			expect(hasLog(e, "no audio player")).toBe(true)
		end)
	end)
end)
