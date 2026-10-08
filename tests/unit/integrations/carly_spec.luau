--!strict
local t = require("../../lib/test")
local f = require("../../lib/factories")
local commands = require("../../../cat/core/commands")
local carly = require("../../../cat/integrations/carly")

local describe, it, expect = t.describe, t.it, t.expect

local NAME_PATTERN = "^[a-z][a-z0-9_]*$"

local function input(overrides: { [string]: any }?): carly.Snapshot
	local base: carly.Snapshot = {
		envelope = f.envelope(),
		config = f.config(),
		overlay_visible = true,
		now_s = f.WALL_S + 100,
		current = nil,
	}
	for k, v in overrides or {} do
		(base :: any)[k] = v
	end
	return base
end

describe("integrations/carly exports", function()
	it("stays within Tern's export limits", function()
		expect(#carly.EXPORTS).toBeLessThanOrEqual(16)
		local seen: { [string]: boolean } = {}
		for _, def in carly.EXPORTS do
			expect(string.match(def.name, NAME_PATTERN) ~= nil).toBe(true)
			expect(#def.name).toBeLessThanOrEqual(24)
			expect(seen[def.name]).toBeNil()
			seen[def.name] = true
			expect(#def.sig).toBeGreaterThan(0)
			expect(#def.sig).toBeLessThanOrEqual(1024)
			expect(#def.doc).toBeGreaterThan(0)
			expect(#def.doc).toBeLessThanOrEqual(1024)
			expect(def.sig).toContain("cx")
			expect(def.sig).toContain("call")
			local params = string.match(def.sig, "^function(%b())") or "()"
			params = string.sub(params, 2, -2)
			params = string.gsub(string.gsub(params, "%b{}", "x"), "%b()", "x")
			local _, commas = string.gsub(params, ",", "")
			expect(def.arity).toBe(commas + 1 - 2)
		end
		for _, name in
			{
				"status",
				"pet",
				"poke",
				"feed",
				"play",
				"perform",
				"set_personality",
				"configure",
				"snooze",
				"wake",
				"explain",
				"ai_status",
			}
		do
			expect(seen[name]).toBe(true)
		end
	end)

	it("maps every state-changing export to an intent kind and args", function()
		local cases: { { any } } = {
			{ "pet", nil, nil, "pet", {} },
			{ "poke", nil, nil, "poke", {} },
			{ "feed", "treat", nil, "feed", { item = "treat" } },
			{ "feed", nil, nil, "feed", {} },
			{ "play", "feather", nil, "play", { toy = "feather" } },
			{ "perform", "stretch", nil, "perform", { animation = "stretch" } },
			{ "set_personality", { mischief = 0.5 }, nil, "set_personality", { mischief = 0.5 } },
			{ "configure", "sound.enabled", true, "set_config", { key = "sound.enabled", value = true } },
			{ "snooze", 10, nil, "snooze", { minutes = 10 } },
			{ "snooze", nil, nil, "snooze", {} },
			{ "wake", nil, nil, "unsnooze", {} },
		}
		for _, case in cases do
			local kind, args, err = carly.toIntent(case[1], case[2], case[3])
			expect(err).toBeNil()
			expect(kind).toBe(case[4])
			expect(args).toEqual(case[5])
		end
	end)

	it("lets commands.validate reject bad arguments with a readable error", function()
		local bad: { { any } } = {
			{ "feed", "rm -rf /" },
			{ "play", 42 },
			{ "perform", "dance_on_keyboard" },
			{ "set_personality", { evil = 1 } },
			{ "configure", "ai.enabled", true },
			{ "configure", "sound.volume", "loud" },
			{ "snooze", 100000 },
		}
		for _, case in bad do
			local kind, args = carly.toIntent(case[1], case[2], case[3])
			assert(kind and args, case[1])
			local intent, err = commands.validate({
				intent_id = "c-1",
				at = 1,
				kind = kind,
				source = "carly",
				args = args,
			})
			expect(intent).toBeNil()
			expect(type(err)).toBe("string")
		end
	end)

	it("rejects non-object personality values before validation", function()
		local kind, _, err = carly.toIntent("set_personality", "mischief=1", nil)
		expect(kind).toBeNil()
		expect(err).toContain("object")
	end)

	it("only allows configure keys from commands.SET_CONFIG_KEYS", function()
		for _, key in commands.SET_CONFIG_KEYS do
			local kind = carly.toIntent("configure", key, true)
			expect(kind).toBe("set_config")
		end
		local _, _, err = carly.toIntent("configure", 12, true)
		expect(err).toContain("key")
	end)

	-- The agent reads this doc string to decide what to call; it must not advertise opting into
	-- sound or loosening quiet hours, which the host refuses from Carly.
	it("documents that Carly may only mute sound and turn quiet hours and focus mode on", function()
		local doc: string? = nil
		for _, def in carly.EXPORTS do
			if def.name == "configure" then
				doc = def.doc
			end
		end
		assert(doc, "configure export")
		expect(doc).toContain("sound.enabled (false only")
		expect(doc).toContain("quiet.hours_enabled (true only")
		expect(doc).toContain("behavior.focus_mode (true only")
		expect(doc).toContain("behavior.allow_pointer_reactions (false only")
		for _, key in { "sound.volume", "quiet.start", "quiet.stop" } do
			expect(doc).notToContain(key)
		end
	end)

	it("reports read-only exports as not intents", function()
		for _, name in { "status", "explain", "ai_status" } do
			local kind, args, err = carly.toIntent(name, nil, nil)
			expect(kind).toBeNil()
			expect(args).toBeNil()
			expect(err).toBeNil()
		end
	end)
end)

describe("integrations/carly.status", function()
	it("shapes a small, private status", function()
		local env = f.envelope({
			profile = { needs = { hunger = 0.123456, energy = 0.98765 }, mood = "playful", stats = { pets = 12 } },
			last_reaction = {
				at = f.WALL_S + 90,
				id = "gesture.pet",
				animation = "pet",
				reason = "You petted the cat.",
			},
			journal = { { at = 1, event_id = "x", kind = "gesture", summary = "Was petted" } },
		})
		local s = carly.status(input({ envelope = env }))
		expect(s.ok).toBe(true)
		expect(s.name).toBe("Orange Menace")
		expect(s.mood).toBe("playful")
		expect(s.needs.hunger).toBe(0.12)
		expect(s.needs.energy).toBe(0.99)
		expect(s.stats.pets).toBe(12)
		expect(s.appearance).toBe("orange-menace")
		expect(s.overlay).toBe(true)
		expect(s.snoozed).toBe(false)
		assert(s.last_reaction, "last_reaction")
		expect(s.last_reaction.animation).toBe("pet")
		expect(s.last_reaction.ago_s).toBe(10)
		local keys = {}
		for k in s do
			table.insert(keys, k)
		end
		table.sort(keys)
		expect(keys).toEqual({
			"appearance",
			"last_reaction",
			"mood",
			"name",
			"needs",
			"ok",
			"overlay",
			"snoozed",
			"stats",
		})
	end)

	it("reports snooze and a hidden overlay", function()
		local s =
			carly.status(input({ envelope = f.envelope({ snooze_until = f.WALL_S + 1000 }), overlay_visible = false }))
		expect(s.snoozed).toBe(true)
		expect(s.overlay).toBe(false)
		expect(s.last_reaction).toBeNil()
	end)
end)

describe("integrations/carly.explain", function()
	it("explains the last host reaction and this window's current decision", function()
		local env = f.envelope({
			last_reaction = {
				at = f.WALL_S + 40,
				id = "react.command_failed",
				animation = "disappointed",
				reason = "A command failed.",
			},
		})
		local e = carly.explain(input({
			envelope = env,
			current = {
				id = "ambient.groom",
				animation = "groom",
				intensity = 1,
				duration_ms = 1,
				reason = "Grooming.",
			},
		}))
		expect(e.ok).toBe(true)
		assert(e.last_reaction and e.overlay, "explain")
		expect(e.last_reaction.reason).toBe("A command failed.")
		expect(e.last_reaction.ago_s).toBe(60)
		expect(e.overlay.animation).toBe("groom")
		expect(e.overlay.reason).toBe("Grooming.")
	end)

	it("says so when nothing happened yet", function()
		local e = carly.explain(input())
		expect(e.ok).toBe(true)
		expect(e.last_reaction).toBeNil()
		expect(e.note).toContain("No reactions")
	end)
end)

describe("integrations/carly.aiStatus", function()
	it("reports the disabled adapter", function()
		local a = carly.aiStatus(f.config())
		expect(a.ok).toBe(true)
		expect(a.enabled).toBe(false)
		expect(a.provider).toBe("none")
		expect(type(a.unavailable_reason)).toBe("string")
	end)

	it("never claims AI is enabled in v1", function()
		local a = carly.aiStatus(f.config({ ai = { enabled = true, provider = "carly_schedule" } }))
		expect(a.enabled).toBe(false)
		expect(a.provider).toBe("carly_schedule")
		expect(type(a.unavailable_reason)).toBe("string")
	end)
end)

describe("integrations/carly.context", function()
	it("summarizes the cat in one short line", function()
		local env = f.envelope({ profile = { mood = "playful", needs = { hunger = 0.4 }, stats = { pets = 12 } } })
		local s = carly.context(input({ envelope = env }))
		expect(s).toContain('Tern Cat "Orange Menace"')
		expect(s).toContain("playful")
		expect(s).toContain("hunger 0.4")
		expect(s).toContain("12 pets")
		expect(#s).toBeLessThanOrEqual(carly.CONTEXT_MAX)
	end)

	it("stays within 160 characters and strips quotes and control characters from the name", function()
		local cfg = f.config()
		cfg.cat.name = string.rep('W"\n', 40)
		local s = carly.context(input({
			config = cfg,
			envelope = f.envelope({ snooze_until = f.WALL_S + 999 }),
			overlay_visible = false,
		}))
		expect(#s).toBeLessThanOrEqual(160)
		expect(string.find(s, "\n", 1, true)).toBeNil()
		expect(select(2, string.gsub(s, '"', ""))).toBe(2)
		expect(s).toContain("snoozed")
		expect(s).toContain("overlay hidden")
	end)

	it("never includes journal text, reasons or paths", function()
		local env = f.envelope({
			journal = { { at = 1, event_id = "x", kind = "note", summary = "git push --force secret-token" } },
			last_reaction = { at = f.WALL_S + 99, id = "react.sudo", animation = "stare", reason = "/Users/me/secret" },
		})
		local s = carly.context(input({ envelope = env }))
		expect(s).notToContain("secret")
		expect(s).notToContain("git")
		expect(s).notToContain("/")
	end)
end)
