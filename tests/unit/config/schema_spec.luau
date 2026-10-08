--!strict
local t = require("../../lib/test")
local schema = require("../../../cat/config/schema")

local describe, it, expect = t.describe, t.it, t.expect

local function hasWarning(warnings: { string }, fragment: string): boolean
	for _, w in warnings do
		if string.find(w, fragment, 1, true) then
			return true
		end
	end
	return false
end

describe("config schema", function()
	describe("defaults", function()
		it("ships the Orange Menace persona with every opt-in feature off", function()
			local d = schema.defaults()
			expect(d.schema_version).toBe(1)
			expect(d.behavior.activity).toBe("orange_menace")
			expect(d.personality).toEqual({
				curiosity = 0.9,
				affection = 0.65,
				mischief = 0.85,
				energy = 0.75,
				talkativeness = 0.15,
			})
			expect(d.ai.enabled).toBe(false)
			expect(d.ai.provider).toBe("none")
			expect(d.ai.share_command_output).toBe(false)
			expect(d.sound.enabled).toBe(false)
			expect(d.quiet.hours_enabled).toBe(false)
			expect(d.rendering.overlay).toBe(true)
			expect(d.rendering.reduced_motion).toBe("follow_tern")
		end)

		it("drops keys that never had an effect; old config files only get an unknown-key warning", function()
			local d = schema.defaults() :: any
			expect(d.rendering.animation_fps).toBeNil()
			expect(d.behavior.obscure_max_ms).toBeNil()
			local cfg, warnings =
				schema.resolve({ rendering = { animation_fps = 8 }, behavior = { obscure_max_ms = 1500 } })
			expect((cfg :: any).rendering.animation_fps).toBeNil()
			expect(hasWarning(warnings, "rendering.animation_fps")).toBe(true)
			expect(hasWarning(warnings, "behavior.obscure_max_ms")).toBe(true)
			expect(schema.preset("quiet_office").rendering).toBeNil()
		end)

		it("returns a fresh table each call so callers cannot corrupt defaults", function()
			local a = schema.defaults()
			a.personality.mischief = 0
			expect(schema.defaults().personality.mischief).toBe(0.85)
		end)

		it("config/example.json mirrors the defaults exactly with no warnings", function()
			local fs = require("@lune/fs")
			local serde = require("@lune/serde")
			local raw = serde.decode("json", fs.readFile("config/example.json"))
			local cfg, warnings = schema.resolve(raw)
			expect(warnings).toEqual({})
			expect(cfg).toEqual(schema.defaults())
			expect(raw).toEqual(schema.defaults())
		end)
	end)

	describe("presets", function()
		it("Orange Menace is exactly the defaults", function()
			expect(schema.preset("orange_menace")).toEqual({})
		end)

		it("Quiet Office never obscures, paces or swats and rarely reacts", function()
			local cfg = schema.resolve({ behavior = { activity = "quiet_office" } })
			expect(cfg.behavior.allow_visual_obscuring).toBe(false)
			expect(cfg.behavior.allow_pacing).toBe(false)
			expect(cfg.behavior.allow_swats).toBe(false)
			expect(cfg.behavior.reaction_sample_rate).toBeLessThan(schema.defaults().behavior.reaction_sample_rate)
		end)

		it("Chaos turns every antic on and reacts more often", function()
			local cfg = schema.resolve({ behavior = { activity = "chaos" } })
			for key, value in cfg.behavior do
				if string.sub(key, 1, 6) == "allow_" then
					expect(value).toBe(true)
				end
			end
			expect(cfg.personality.mischief).toBeGreaterThan(schema.defaults().personality.mischief)
			expect(cfg.behavior.reaction_sample_rate).toBeGreaterThan(schema.defaults().behavior.reaction_sample_rate)
		end)

		it("Zen is low energy and rarely reacts", function()
			local cfg = schema.resolve({ behavior = { activity = "zen" } })
			expect(cfg.personality.energy).toBeLessThan(0.3)
			expect(cfg.behavior.allow_idle_sleep).toBe(true)
			expect(cfg.behavior.reaction_sample_rate).toBeLessThan(0.1)
		end)

		it("unknown activities have no overrides", function()
			expect(schema.preset("disco")).toEqual({})
		end)
	end)

	describe("resolve precedence", function()
		it("an explicit user toggle overrides the preset", function()
			local cfg, warnings = schema.resolve({
				behavior = { activity = "quiet_office", allow_swats = true },
			})
			expect(cfg.behavior.allow_swats).toBe(true)
			expect(cfg.behavior.allow_pacing).toBe(false)
			expect(#warnings).toBe(0)
		end)

		it("an explicit personality value overrides the preset personality", function()
			local cfg = schema.resolve({
				behavior = { activity = "zen" },
				personality = { energy = 0.9 },
			})
			expect(cfg.personality.energy).toBe(0.9)
			expect(cfg.personality.mischief).toBe(
				schema.resolve({ behavior = { activity = "zen" } }).personality.mischief
			)
		end)

		it("missing fields come from the defaults", function()
			local cfg, warnings = schema.resolve({})
			expect(cfg).toEqual(schema.defaults())
			expect(#warnings).toBe(0)
		end)
	end)

	describe("resolve recovery", function()
		it("never throws and falls back to defaults on non-table input", function()
			for _, raw in { nil :: any, "garbage", 42, true, { 1, 2, 3 } } do
				local ok, cfg = pcall(schema.resolve, raw)
				expect(ok).toBe(true)
				expect(cfg.behavior.activity).toBe("orange_menace")
			end
		end)

		it("warns when the whole document is not an object", function()
			local _, warnings = schema.resolve("garbage")
			expect(#warnings).toBeGreaterThan(0)
		end)

		it("falls back per field with a warning on wrong types", function()
			local cfg, warnings = schema.resolve({
				personality = { curiosity = "very" },
				rendering = { overlay = "yes" },
				sound = "loud",
			})
			expect(cfg.personality.curiosity).toBe(0.9)
			expect(cfg.rendering.overlay).toBe(true)
			expect(cfg.sound).toEqual(schema.defaults().sound)
			expect(hasWarning(warnings, "personality.curiosity")).toBe(true)
			expect(hasWarning(warnings, "rendering.overlay")).toBe(true)
			expect(hasWarning(warnings, "sound")).toBe(true)
		end)

		it("clamps out-of-range numbers with a warning", function()
			local cfg, warnings = schema.resolve({
				personality = { mischief = 7 },
				sound = { volume = -1 },
			})
			expect(cfg.personality.mischief).toBe(1)
			expect(cfg.sound.volume).toBe(0)
			expect(hasWarning(warnings, "personality.mischief")).toBe(true)
			expect(hasWarning(warnings, "sound.volume")).toBe(true)
		end)

		it("rejects NaN and infinity as wrong types", function()
			local cfg = schema.resolve({ personality = { energy = 0 / 0, affection = math.huge } })
			expect(cfg.personality.energy).toBe(0.75)
			expect(cfg.personality.affection).toBe(0.65)
		end)

		it("falls back on unknown enums and keeps the preset value", function()
			local cfg, warnings = schema.resolve({
				behavior = { activity = "disco" },
				rendering = { reduced_motion = "sometimes" },
				ai = { provider = "openai" },
			})
			expect(cfg.behavior.activity).toBe("orange_menace")
			expect(cfg.rendering.reduced_motion).toBe("follow_tern")
			expect(cfg.ai.provider).toBe("none")
			expect(hasWarning(warnings, "behavior.activity")).toBe(true)
			expect(hasWarning(warnings, "rendering.reduced_motion")).toBe(true)
			expect(hasWarning(warnings, "ai.provider")).toBe(true)
		end)

		it("resolves block placement with float as the default", function()
			expect(schema.defaults().rendering.block_placement).toBe("float")
			expect(schema.resolve({ rendering = { block_placement = "split" } }).rendering.block_placement).toBe(
				"split"
			)
			local cfg, warnings = schema.resolve({ rendering = { block_placement = "tab" } })
			expect(cfg.rendering.block_placement).toBe("float")
			expect(hasWarning(warnings, "rendering.block_placement")).toBe(true)
		end)

		it("rejects malformed quiet hours", function()
			local cfg, warnings = schema.resolve({ quiet = { hours_enabled = true, start = "25:00", stop = "7am" } })
			expect(cfg.quiet.hours_enabled).toBe(true)
			expect(cfg.quiet.start).toBe("22:00")
			expect(cfg.quiet.stop).toBe("08:00")
			expect(hasWarning(warnings, "quiet.start")).toBe(true)
			expect(hasWarning(warnings, "quiet.stop")).toBe(true)
		end)

		it("ignores unknown keys with a warning", function()
			local cfg, warnings = schema.resolve({
				wat = 1,
				behavior = { allow_pointer_chase = true },
				sound = { events = { bark = true, meow = false } },
			})
			expect((cfg :: any).wat).toBeNil()
			expect((cfg.behavior :: any).allow_pointer_chase).toBeNil()
			expect(cfg.sound.events.bark).toBeNil()
			expect(cfg.sound.events.meow).toBe(false)
			expect(hasWarning(warnings, "wat")).toBe(true)
			expect(hasWarning(warnings, "behavior.allow_pointer_chase")).toBe(true)
			expect(hasWarning(warnings, "sound.events.bark")).toBe(true)
		end)

		it("sanitizes the cat name and pack ids", function()
			local cfg, warnings = schema.resolve({
				cat = { name = "Mo\27[31mchi", appearance = "../evil" },
				sound = { pack = "/etc" },
			})
			expect(cfg.cat.name).toBe("Mo[31mchi")
			expect(cfg.cat.appearance).toBe("orange-menace")
			expect(cfg.sound.pack).toBe("default")
			expect(hasWarning(warnings, "cat.appearance")).toBe(true)
		end)

		it("accepts the Carly schedule provider as a known value", function()
			local cfg, warnings = schema.resolve({ ai = { provider = "carly_schedule" } })
			expect(cfg.ai.provider).toBe("carly_schedule")
			expect(#warnings).toBe(0)
		end)

		it("forces share_command_output off because v1 has no consent path", function()
			local cfg, warnings = schema.resolve({ ai = { share_command_output = true } })
			expect(cfg.ai.share_command_output).toBe(false)
			expect(hasWarning(warnings, "ai.share_command_output")).toBe(true)
		end)

		it("survives deeply nested garbage", function()
			local raw =
				{ personality = { curiosity = { a = { b = { c = {} } } } }, needs = { 1, 2 }, quiet = { start = {} } }
			local ok, cfg = pcall(schema.resolve, raw)
			expect(ok).toBe(true)
			expect(cfg.personality.curiosity).toBe(0.9)
			expect(cfg.needs).toEqual(schema.defaults().needs)
		end)

		it("rounds integer settings", function()
			local cfg, warnings = schema.resolve({ rendering = { block_scale = 3.6 } })
			expect(cfg.rendering.block_scale).toBe(4)
			expect(hasWarning(warnings, "rendering.block_scale")).toBe(true)
		end)

		it("measures cat.name in characters, like rename intents", function()
			local name = string.rep("猫", 32)
			expect(schema.resolve({ cat = { name = name } }).cat.name).toBe(name)
			local _, warnings = schema.resolve({ cat = { name = string.rep("猫", 33) } })
			expect(hasWarning(warnings, "cat.name")).toBe(true)
		end)
	end)

	describe("migrate", function()
		it("treats a missing schema_version as version 1", function()
			local migrated, warnings = schema.migrate({ cat = { name = "Tom" } })
			expect(migrated.schema_version).toBe(1)
			expect(migrated.cat.name).toBe("Tom")
			expect(#warnings).toBe(0)
		end)

		it("reads a newer schema best-effort with a warning", function()
			local cfg, warnings = schema.resolve({ schema_version = 3, cat = { name = "Future" } })
			expect(cfg.schema_version).toBe(1)
			expect(cfg.cat.name).toBe("Future")
			expect(hasWarning(warnings, "schema_version")).toBe(true)
		end)

		it("warns on a non-numeric schema_version", function()
			local _, warnings = schema.migrate({ schema_version = "one" })
			expect(hasWarning(warnings, "schema_version")).toBe(true)
		end)
	end)

	describe("checkField", function()
		it("normalizes a valid value for a known path", function()
			local value, err = schema.checkField("sound.volume", 0.5)
			expect(value).toBe(0.5)
			expect(err).toBeNil()
		end)

		it("rejects unknown paths and wrong types", function()
			expect((schema.checkField("ai.provider_key", "x"))).toBeNil()
			expect((schema.checkField("sound.enabled", "yes"))).toBeNil()
			expect((schema.checkField("quiet.start", "9:00"))).toBeNil()
		end)
	end)

	describe("serialize", function()
		it("writes only values that differ from the activity baseline", function()
			local cfg =
				schema.resolve({ behavior = { activity = "zen", allow_swats = true }, sound = { volume = 0.5 } })
			local sparse = schema.serialize(cfg)
			expect(sparse).toEqual({
				schema_version = 1,
				behavior = { activity = "zen", allow_swats = true },
				sound = { volume = 0.5 },
			})
		end)

		it("round-trips through resolve", function()
			local cfg =
				schema.resolve({ behavior = { activity = "chaos", reaction_cooldown_s = 99 }, cat = { name = "Rex" } })
			local again, warnings = schema.resolve(schema.serialize(cfg))
			expect(again).toEqual(cfg)
			expect(#warnings).toBe(0)
		end)
	end)
end)
