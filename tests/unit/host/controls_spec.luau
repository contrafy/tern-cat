--!strict
local t = require("../../lib/test")
local factories = require("../../lib/factories")
local controls = require("../../../cat/host/controls")
local configFile = require("../../../cat/adapters/config")
local commands = require("../../../cat/core/commands")

local describe, it, expect = t.describe, t.it, t.expect

local function key(name: string, mods: { [string]: boolean }?): any
	local k: { [string]: any } = { name = name, ctrl = false, alt = false, meta = false, shift = false }
	for m, v in mods or {} do
		k[m] = v
	end
	return k
end

describe("controls", function()
	describe("actions", function()
		it("maps every menu action to a valid intent or the settings page", function()
			for _, snoozed in { true, false } do
				for _, overlay in { true, false } do
					for _, act in controls.menuActions(snoozed, overlay) do
						local cmd = controls.resolveAction(act) :: any
						expect(cmd).notToBeNil()
						if cmd.kind == "intent" then
							local intent, err = commands.validate({
								intent_id = "b-1",
								at = 1,
								kind = cmd.intent,
								source = "block",
								args = cmd.args,
							})
							expect(err).toBeNil()
							expect(intent).notToBeNil()
						end
					end
				end
			end
		end)

		it("offers wake while snoozed and the opposite overlay state", function()
			local menu = controls.menuActions(true, true)
			expect(menu).toContain("wake")
			expect(menu).toContain("overlay-off")
			expect(controls.menuActions(false, false)).toContain("snooze-30m")
		end)

		it("feeds and plays with defaults and named items", function()
			expect((controls.resolveAction("feed-fish") :: any).args.item).toBe("fish")
			expect((controls.resolveAction("play") :: any).args.toy).toBe("ball")
			expect(controls.resolveAction("rm -rf")).toBeNil()
			expect(controls.resolveAction(nil)).toBeNil()
		end)
	end)

	describe("keys", function()
		it("maps the documented keys when the block has focus", function()
			local cases = { p = "pet", o = "poke", f = "feed", space = "play", s = "settings" }
			for name, act in cases do
				expect(controls.keyAction(key(name), "main", true, false, true)).toBe(act)
			end
			expect(controls.keyAction(key("h"), "main", true, false, true)).toBe("overlay-off")
			expect(controls.keyAction(key("h"), "main", true, false, false)).toBe("overlay-on")
			expect(controls.keyAction(key("z"), "main", true, false, true)).toBe("snooze-30m")
			expect(controls.keyAction(key("z"), "main", true, true, true)).toBe("wake")
		end)

		it("passes unrelated keys, chords and disabled keyboards through", function()
			expect(controls.keyAction(key("x"), "main", true, false, true)).toBeNil()
			expect(controls.keyAction(key("enter"), "main", true, false, true)).toBeNil()
			expect(controls.keyAction(key("p", { ctrl = true }), "main", true, false, true)).toBeNil()
			expect(controls.keyAction(key("p", { meta = true }), "main", true, false, true)).toBeNil()
			expect(controls.keyAction(key("p"), "main", false, false, true)).toBeNil()
		end)

		it("only closes the settings page with Escape", function()
			expect(controls.keyAction(key("escape"), "settings", true, false, true)).toBe("close-settings")
			expect(controls.keyAction(key("p"), "settings", true, false, true)).toBeNil()
		end)
	end)

	describe("settings", function()
		it("stores percentages as fractions", function()
			local changes = controls.settingsChange("personality.mischief", 40) :: any
			expect(changes["personality.mischief"]).toBe(0.4)
			expect((controls.settingsChange("sound.volume", 105) :: any)["sound.volume"]).toBe(1)
		end)

		it("validates enums, booleans and quiet hours", function()
			expect((controls.settingsChange("behavior.activity", "chaos") :: any)["behavior.activity"]).toBe("chaos")
			expect((controls.settingsChange("behavior.activity", "disco"))).toBeNil()
			expect((controls.settingsChange("needs.enabled", "yes"))).toBeNil()
			expect((controls.settingsChange("quiet.start", "23:00") :: any)["quiet.start"]).toBe("23:00")
			expect((controls.settingsChange("quiet.start", "25:00"))).toBeNil()
			expect((controls.settingsChange("rendering.block_placement", "split") :: any)["rendering.block_placement"]).toBe(
				"split"
			)
			expect((controls.settingsChange("behavior.focus_mode", true) :: any)["behavior.focus_mode"]).toBe(true)
		end)

		it("turns the sound event chips into flags", function()
			local changes = controls.settingsChange("sound.events", { "purr", "meow" }) :: any
			expect(changes["sound.events"]).toEqual({
				meow = true,
				purr = true,
				surprise = false,
				happy = false,
				swat = false,
			})
		end)

		it("resets a row by removing its key", function()
			local changes = controls.settingsChange("sound.volume", nil) :: any
			expect(changes["sound.volume"]).toBe(configFile.REMOVE)
		end)

		it("refuses rows that are not editable here", function()
			expect((controls.settingsChange("ai.enabled", true))).toBeNil()
			expect((controls.settingsChange("ai.share_command_output", true))).toBeNil()
			expect((controls.settingsChange("../../etc", true))).toBeNil()
		end)

		it("shows percentages as whole numbers", function()
			local cfg = factories.config()
			expect(controls.displayValue(cfg, "personality.mischief")).toBe(85)
			expect(controls.displayValue(cfg, "rendering.overlay")).toBe(true)
		end)
	end)

	describe("test mode", function()
		it("parses block args and the environment variable form", function()
			expect(controls.parseTestMode({ "test", "seed=42", "frozen" })).toEqual({ seed = 42, frozen = true })
			expect(controls.parseTestMode("frozen, seed=7")).toEqual({ seed = 7, frozen = true })
			expect(controls.parseTestMode({ "test" })).toEqual({ seed = 1, frozen = false })
		end)

		it("is off without test items", function()
			expect(controls.parseTestMode({})).toBeNil()
			expect(controls.parseTestMode({ "settings" })).toBeNil()
			expect(controls.parseTestMode(nil)).toBeNil()
			expect(controls.parseTestMode("")).toBeNil()
		end)
	end)
end)
