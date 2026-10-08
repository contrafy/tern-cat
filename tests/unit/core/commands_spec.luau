--!strict
local t = require("../../lib/test")
local factories = require("../../lib/factories")
local commands = require("../../../cat/core/commands")
local schema = require("../../../cat/config/schema")

local describe, it, expect = t.describe, t.it, t.expect

local function accepts(kind: string, args: { [string]: any }?, overrides: { [string]: any }?): any
	local intent, err = commands.validate(factories.intent(kind, args, overrides))
	if intent == nil then
		error(`expected {kind} to be accepted, got {tostring(err)}`, 2)
	end
	return intent
end

local function rejects(raw: any): string
	local intent, err = commands.validate(raw)
	expect(intent).toBeNil()
	expect(type(err)).toBe("string")
	return err :: string
end

describe("commands", function()
	describe("validate envelope", function()
		it("accepts a well-formed gesture intent", function()
			local intent = accepts("pet")
			expect(intent.kind).toBe("pet")
			expect(intent.source).toBe("block")
			expect(intent.intent_id).toBe("int-1")
			expect(intent.args).toEqual({})
		end)

		it("rejects non-objects", function()
			rejects(nil)
			rejects("pet")
			rejects(42)
			rejects({ 1, 2 })
		end)

		it("rejects unknown kinds, including dangerous-looking ones", function()
			expect(rejects(factories.intent("run_command", { line = "rm -rf ~" }))).toContain("kind")
			rejects(factories.intent("PET"))
			rejects(factories.intent(string.rep("p", 1000)))
		end)

		it("rejects unknown sources", function()
			expect(rejects(factories.intent("pet", nil, { source = "network" }))).toContain("source")
		end)

		it("requires a short, safe intent_id", function()
			rejects(factories.intent("pet", nil, { intent_id = "" }))
			rejects(factories.intent("pet", nil, { intent_id = string.rep("a", 65) }))
			rejects(factories.intent("pet", nil, { intent_id = "../../x" }))
			rejects(factories.intent("pet", nil, { intent_id = "id\n2" }))
			rejects(factories.intent("pet", nil, { intent_id = 7 }))
			accepts("pet", nil, { intent_id = string.rep("a", 64) })
		end)

		it("requires a finite numeric timestamp", function()
			rejects(factories.intent("pet", nil, { at = "now" }))
			rejects(factories.intent("pet", nil, { at = 0 / 0 }))
			rejects(factories.intent("pet", nil, { at = math.huge }))
		end)

		it("rejects args that are not an object and unexpected arg keys", function()
			rejects(factories.intent("pet", nil, { args = "x" }))
			expect(rejects(factories.intent("pet", { line = "ls" }))).toContain("line")
		end)

		it("returns a fresh normalized table rather than the caller's", function()
			local raw = factories.intent("feed", { item = "fish" })
			local intent = accepts("feed", { item = "fish" })
			expect(intent).toEqual(raw)
			intent.args.item = "treat"
			expect(raw.args.item).toBe("fish")
		end)
	end)

	describe("validate args", function()
		it("feed accepts known items and defaults to kibble", function()
			expect(accepts("feed", { item = "treat" }).args.item).toBe("treat")
			expect(accepts("feed").args.item).toBe("kibble")
			rejects(factories.intent("feed", { item = "chocolate" }))
		end)

		it("play accepts known toys and defaults to ball", function()
			expect(accepts("play", { toy = "feather" }).args.toy).toBe("feather")
			expect(accepts("play").args.toy).toBe("ball")
			rejects(factories.intent("play", { toy = "laser" }))
		end)

		it("perform requires a canonical animation name", function()
			expect(accepts("perform", { animation = "stretch" }).args.animation).toBe("stretch")
			rejects(factories.intent("perform", {}))
			rejects(factories.intent("perform", { animation = "explode" }))
			rejects(factories.intent("perform", { animation = 3 }))
		end)

		it("set_personality clamps values and rejects unknown traits", function()
			local intent = accepts("set_personality", { mischief = 4, energy = -1, curiosity = 0.5 })
			expect(intent.args).toEqual({ mischief = 1, energy = 0, curiosity = 0.5 })
			rejects(factories.intent("set_personality", {}))
			rejects(factories.intent("set_personality", { evil = 1 }))
			rejects(factories.intent("set_personality", { mischief = "max" }))
			rejects(factories.intent("set_personality", { mischief = 0 / 0 }))
		end)

		it("snooze accepts 1..480 whole minutes", function()
			expect(accepts("snooze", { minutes = 30 }).args.minutes).toBe(30)
			expect(accepts("snooze", { minutes = 480 }).args.minutes).toBe(480)
			rejects(factories.intent("snooze", { minutes = 0 }))
			rejects(factories.intent("snooze", { minutes = 481 }))
			rejects(factories.intent("snooze", { minutes = 1.5 }))
			rejects(factories.intent("snooze", { minutes = "30" }))
		end)

		it("set_overlay requires a boolean", function()
			expect(accepts("set_overlay", { enabled = false }).args.enabled).toBe(false)
			rejects(factories.intent("set_overlay", { enabled = "off" }))
			rejects(factories.intent("set_overlay", {}))
		end)

		it("rename strips control characters and enforces 1..32 characters", function()
			expect(accepts("rename", { name = "Mo\27chi\n" }).args.name).toBe("Mochi")
			expect(accepts("rename", { name = "  Señor Whiskers  " }).args.name).toBe("Señor Whiskers")
			rejects(factories.intent("rename", { name = "" }))
			rejects(factories.intent("rename", { name = "\n\t\27" }))
			rejects(factories.intent("rename", { name = string.rep("x", 33) }))
			rejects(factories.intent("rename", { name = "\255\254" }))
			rejects(factories.intent("rename", { name = 5 }))
		end)

		it("rename accepts only names the config schema keeps, so a rename never silently reverts", function()
			local cjk = string.rep("猫", 30)
			local renamed = accepts("rename", { name = cjk }).args.name
			local cfg, warnings = schema.resolve({ cat = { name = renamed } })
			expect(cfg.cat.name).toBe(cjk)
			expect(#warnings).toBe(0)
			rejects(factories.intent("rename", { name = string.rep("猫", 33) }))
			expect(accepts("rename", { name = "Mo\194\133chi" }).args.name).toBe("Mochi")
		end)

		it("argument-free intents accept no args", function()
			for _, kind in { "pet", "poke", "unsnooze", "reset_identity", "export_identity", "clear_ai_state" } do
				accepts(kind)
				rejects(factories.intent(kind, { extra = true }))
			end
		end)
	end)

	describe("set_config allowlist", function()
		it("accepts allowlisted safe keys with valid values", function()
			local intent = accepts("set_config", {
				values = {
					["behavior.allow_swats"] = false,
					["behavior.activity"] = "zen",
					["sound.enabled"] = true,
					["sound.volume"] = 0.5,
					["rendering.overlay"] = false,
					["rendering.reduced_motion"] = "on",
					["quiet.hours_enabled"] = true,
					["quiet.start"] = "21:30",
					["needs.enabled"] = false,
				},
			})
			expect(intent.args.values["behavior.activity"]).toBe("zen")
			expect(intent.args.values["quiet.start"]).toBe("21:30")
		end)

		it("normalizes the single key/value form", function()
			local intent = accepts("set_config", { key = "behavior.allow_pacing", value = false })
			expect(intent.args).toEqual({ values = { ["behavior.allow_pacing"] = false } })
		end)

		it("rejects keys outside the allowlist, even valid config paths", function()
			expect(rejects(factories.intent("set_config", { key = "ai.enabled", value = true }))).toContain(
				"ai.enabled"
			)
			rejects(factories.intent("set_config", { key = "ai.share_command_output", value = true }))
			rejects(factories.intent("set_config", { key = "cat.appearance", value = "void" }))
			rejects(factories.intent("set_config", { key = "personality.mischief", value = 1 }))
			rejects(factories.intent("set_config", { key = "__proto__", value = 1 }))
		end)

		it("rejects invalid values for allowlisted keys", function()
			rejects(factories.intent("set_config", { key = "sound.enabled", value = "yes" }))
			rejects(factories.intent("set_config", { key = "behavior.activity", value = "disco" }))
			rejects(factories.intent("set_config", { key = "quiet.start", value = "9pm" }))
		end)

		it("rejects empty or mixed forms", function()
			rejects(factories.intent("set_config", {}))
			rejects(factories.intent("set_config", { values = {} }))
			rejects(factories.intent("set_config", { key = "sound.enabled" }))
			rejects(factories.intent("set_config", { key = "sound.enabled", value = true, values = {} }))
		end)

		it("never lets Carly turn sound on or loosen quiet hours (no user consent on that surface)", function()
			local carly = { source = "carly" }
			expect(rejects(factories.intent("set_config", { key = "sound.enabled", value = true }, carly))).toContain(
				"Carly"
			)
			rejects(factories.intent("set_config", { key = "sound.volume", value = 1 }, carly))
			rejects(factories.intent("set_config", { key = "quiet.hours_enabled", value = false }, carly))
			-- Focus mode keeps the cat still during commands; only the user may turn it back off.
			rejects(factories.intent("set_config", { key = "behavior.focus_mode", value = false }, carly))
			rejects(factories.intent("set_config", { key = "quiet.start", value = "23:00" }, carly))
			rejects(factories.intent("set_config", { key = "quiet.stop", value = "06:00" }, carly))
			rejects(
				factories.intent(
					"set_config",
					{ values = { ["rendering.overlay"] = false, ["sound.enabled"] = true } },
					carly
				)
			)
		end)

		it("lets Carly make privacy-reducing changes and other safe settings", function()
			local carly = { source = "carly" }
			expect(accepts("set_config", { key = "sound.enabled", value = false }, carly).args.values["sound.enabled"]).toBe(
				false
			)
			expect(
				accepts("set_config", { key = "quiet.hours_enabled", value = true }, carly).args.values["quiet.hours_enabled"]
			).toBe(true)
			accepts("set_config", { key = "behavior.allow_swats", value = false }, carly)
			expect(
				accepts("set_config", { key = "behavior.focus_mode", value = true }, carly).args.values["behavior.focus_mode"]
			).toBe(true)
		end)

		it("keeps sound and quiet settings available to the user's own surfaces", function()
			for _, source in { "block", "window", "keyboard" } do
				accepts("set_config", { key = "sound.enabled", value = true }, { source = source })
				accepts("set_config", { key = "quiet.start", value = "23:00" }, { source = source })
				accepts("set_config", { key = "behavior.focus_mode", value = false }, { source = source })
			end
		end)
	end)

	describe("toEvent", function()
		it("turns gesture intents into gesture events keyed by intent_id", function()
			local ev =
				commands.toEvent(accepts("feed", { item = "fish" }, { source = "window", intent_id = "abc" })) :: any
			expect(ev.event_id).toBe("abc")
			expect(ev.time).toBe(factories.WALL_S)
			expect(ev.type).toBe("gesture")
			expect(ev.scope).toBe("window")
			expect(ev.attributes.gesture).toBe("feed")
			expect(ev.attributes.item).toBe("fish")
		end)

		it("maps sources to scopes", function()
			expect((commands.toEvent(accepts("pet", nil, { source = "keyboard" })) :: any).scope).toBe("block")
			expect((commands.toEvent(accepts("pet", nil, { source = "carly" })) :: any).scope).toBe("window")
			expect((commands.toEvent(accepts("pet", nil, { source = "block" })) :: any).scope).toBe("block")
		end)

		it("carries the requested animation for perform", function()
			local ev = commands.toEvent(accepts("perform", { animation = "hop" })) :: any
			expect(ev.attributes.animation).toBe("hop")
		end)

		it("returns nil for non-gesture intents", function()
			expect(commands.toEvent(accepts("snooze", { minutes = 5 }))).toBeNil()
			expect(commands.toEvent(accepts("rename", { name = "Rex" }))).toBeNil()
		end)
	end)
end)
