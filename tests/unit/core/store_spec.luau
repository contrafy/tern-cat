--!strict
local t = require("../../lib/test")
local factories = require("../../lib/factories")
local store = require("../../../cat/core/store")
local needs = require("../../../cat/core/needs")
local util = require("../../../cat/core/util")

local describe, it, expect = t.describe, t.it, t.expect

local HOUR = 3600
local WALL = factories.WALL_S

local function freshEnv(): any
	return factories.envelope()
end

local function finish(id: string, status: number, reacted: boolean?): any
	return factories.event({ event_id = id, attributes = { status = status, reacted = reacted or false } })
end

local function gesture(id: string, kind: string, extra: { [string]: any }?): any
	local attributes = util.deepMerge({ gesture = kind, source = "block" }, extra or {})
	return factories.event({ event_id = id, type = "gesture", scope = "block", attributes = attributes })
end

describe("store", function()
	describe("empty", function()
		it("creates a version 1 envelope around a new profile", function()
			local env = store.empty(factories.CAT_ID, WALL)
			expect(env.schema_version).toBe(1)
			expect(env.rev).toBe(0)
			expect(env.profile.cat_id).toBe(factories.CAT_ID)
			expect(env.journal).toEqual({})
			expect(env.seen).toEqual({})
			expect(env.last_reaction).toBeNil()
			expect(env.snooze_until).toBeNil()
		end)
	end)

	describe("decode", function()
		it("starts a fresh cat on first run without flagging recovery", function()
			local env, recovered, note = store.decode(nil, WALL, factories.catIds())
			expect(env.profile.cat_id).toBe("cat-000000000001")
			expect(recovered).toBe(false)
			expect(note).toBeNil()
		end)

		it("round-trips a valid envelope", function()
			local original = freshEnv()
			original.rev = 7
			original.seen = { "a", "b" }
			original.snooze_until = WALL + 60
			local env, recovered = store.decode(util.deepCopy(original), WALL, factories.catIds())
			expect(recovered).toBe(false)
			expect(env).toEqual(original)
		end)

		it("replaces corrupted or unknown-version state with a fresh cat and a journal note", function()
			local cases: { any } = {
				"{not json",
				42,
				{ 1, 2, 3 },
				{ schema_version = 99, profile = factories.profile() },
				{ schema_version = 1, profile = "nope" },
				{ schema_version = 1, profile = { cat_id = "../../etc/passwd" } },
			}
			for _, raw in cases do
				local ok, env, recovered, note = pcall(store.decode, raw, WALL, factories.catIds())
				expect(ok).toBe(true)
				expect(recovered).toBe(true)
				expect(type(note)).toBe("string")
				expect(env.profile.cat_id).toBe("cat-000000000001")
				expect(#env.journal).toBe(1)
				expect(env.journal[1].kind).toBe("recovery")
			end
		end)

		it("moves rev past the corrupted value so readers notice the replacement", function()
			local env = store.decode({ schema_version = 99, rev = 41 }, WALL, factories.catIds())
			expect(env.rev).toBe(42)
		end)

		it("repairs bad sub-fields without losing the cat", function()
			local raw = freshEnv()
			raw.rev = "x"
			raw.journal = { { at = 1, event_id = "e", kind = "gesture", summary = "ok" }, "junk", { at = "?" } }
			raw.seen = { "a", 5, "b" }
			raw.last_reaction = { at = 1, id = "r", animation = "explode", reason = "?" }
			raw.snooze_until = "later"
			raw.profile.needs.hunger = "very"
			local env, recovered, note = store.decode(raw, WALL, factories.catIds())
			expect(recovered).toBe(false)
			expect(env.profile.cat_id).toBe(factories.CAT_ID)
			expect(env.rev).toBe(0)
			expect(#env.journal).toBe(1)
			expect(env.seen).toEqual({ "a", "b" })
			expect(env.last_reaction).toBeNil()
			expect(env.snooze_until).toBeNil()
			expect(note).toContain("needs.hunger")
		end)

		it("enforces journal and seen bounds on load", function()
			local raw = freshEnv()
			for i = 1, 300 do
				table.insert(raw.seen, "id-" .. i)
				table.insert(raw.journal, { at = i, event_id = "e" .. i, kind = "gesture", summary = "x" })
			end
			local env = store.decode(raw, WALL, factories.catIds())
			expect(#env.seen).toBe(store.MAX_SEEN)
			expect(env.seen[#env.seen]).toBe("id-300")
			expect(#env.journal).toBe(store.MAX_JOURNAL)
			expect(env.journal[#env.journal].event_id).toBe("e300")
		end)
	end)

	describe("catchUp", function()
		it("simulates time away and stamps the new baseline", function()
			local env = freshEnv()
			local after = store.catchUp(env, WALL + 8 * HOUR, factories.config())
			expect(after.profile.needs.hunger).toBeGreaterThan(env.profile.needs.hunger)
			expect(after.profile.last_updated_at).toBe(WALL + 8 * HOUR)
			expect(after.rev).toBe(env.rev + 1)
			expect(env.profile.last_updated_at).toBe(WALL)
		end)

		it("does not bump rev when nothing changed", function()
			local env = freshEnv()
			local after = store.catchUp(env, WALL, factories.config())
			expect(after.rev).toBe(env.rev)
		end)

		it("survives the clock going backwards without rewinding needs", function()
			local env = freshEnv()
			local after = store.catchUp(env, WALL - 5 * HOUR, factories.config())
			expect(after.profile.needs).toEqual(env.profile.needs)
			expect(after.rev).toBe(env.rev)
			expect(after.profile.last_updated_at).toBe(WALL - 5 * HOUR)
		end)

		it("never pushes needs past soft bounds or reduces stats after extreme absence", function()
			local env = freshEnv()
			env.profile.stats.pets = 12
			local after = store.catchUp(
				env,
				WALL + 10 * 365 * 24 * HOUR,
				factories.config({ needs = { offline_hours_cap = 168 } })
			)
			local n = after.profile.needs
			expect(n.hunger).toBeLessThanOrEqual(0.85)
			expect(n.energy).toBeGreaterThanOrEqual(0.1)
			expect(n.affection).toBeGreaterThanOrEqual(0.15)
			expect(n.boredom).toBeLessThanOrEqual(0.9)
			expect(after.profile.stats.pets).toBe(12)
		end)

		it("pins needs to neutral while needs are disabled", function()
			local env = freshEnv()
			env.profile.needs = { hunger = 0.8, energy = 0.2, affection = 0.2, boredom = 0.8 }
			local after = store.catchUp(env, WALL + 8 * HOUR, factories.config({ needs = { enabled = false } }))
			expect(after.profile.needs).toEqual(needs.neutral())
		end)

		it("clears an expired snooze", function()
			local env = freshEnv()
			env.snooze_until = WALL + 60
			expect(store.catchUp(env, WALL + 30, factories.config()).snooze_until).toBe(WALL + 60)
			local after = store.catchUp(env, WALL + 61, factories.config())
			expect(after.snooze_until).toBeNil()
			expect(after.rev).toBe(env.rev + 1)
		end)
	end)

	describe("applyEvent", function()
		it("applies an event once: the same event twice changes nothing", function()
			local cfg = factories.config()
			local once, applied1 = store.applyEvent(freshEnv(), gesture("g1", "pet"), cfg)
			local twice, applied2 = store.applyEvent(once, gesture("g1", "pet"), cfg)
			expect(applied1).toBe(true)
			expect(applied2).toBe(false)
			expect(twice).toEqual(once)
			expect(twice.profile.stats.pets).toBe(1)
		end)

		it("bumps rev and records the id in seen", function()
			local env, applied = store.applyEvent(freshEnv(), finish("c1", 0), factories.config())
			expect(applied).toBe(true)
			expect(env.rev).toBe(1)
			expect(env.seen).toEqual({ "c1" })
		end)

		it("does not mutate the input envelope", function()
			local env = freshEnv()
			store.applyEvent(env, gesture("g1", "feed", { item = "fish" }), factories.config())
			expect(env).toEqual(freshEnv())
		end)

		it("counts a command reaction only when the cat visibly reacted", function()
			local cfg = factories.config()
			local env = store.applyEvent(freshEnv(), finish("c1", 0, false), cfg)
			expect(env.profile.stats.command_reactions).toBe(0)
			env = store.applyEvent(env, finish("c2", 0, true), cfg)
			expect(env.profile.stats.command_reactions).toBe(1)
		end)

		it("tracks a bounded failure streak that success resets", function()
			local cfg = factories.config()
			local env = freshEnv()
			for i = 1, 30 do
				env = store.applyEvent(env, finish("f" .. i, 1), cfg)
			end
			expect(env.profile.fail_streak).toBe(20)
			env = store.applyEvent(env, finish("ok", 0), cfg)
			expect(env.profile.fail_streak).toBe(0)
		end)

		it("gestures update needs, stats, mood and the journal", function()
			local env = store.applyEvent(freshEnv(), gesture("g1", "feed", { item = "treat" }), factories.config())
			expect(env.profile.needs.hunger).toBeLessThan(needs.neutral().hunger)
			expect(env.profile.stats.feeds).toBe(1)
			expect(env.profile.mood).toBe("happy")
			expect(#env.journal).toBe(1)
			expect(env.journal[1].kind).toBe("gesture")
			expect(env.journal[1].event_id).toBe("g1")
			expect(env.journal[1].summary).toContain("treat")
		end)

		it("keeps needs neutral while disabled but still counts gestures", function()
			local cfg = factories.config({ needs = { enabled = false } })
			local env = freshEnv()
			for i = 1, 5 do
				env = store.applyEvent(env, gesture("p" .. i, "play", { toy = "ball" }), cfg)
				env = store.applyEvent(env, gesture("f" .. i, "feed"), cfg)
			end
			expect(env.profile.needs).toEqual(needs.neutral())
			expect(env.profile.stats.plays).toBe(5)
			expect(env.profile.stats.feeds).toBe(5)
		end)

		it("bounds the journal and the seen ring", function()
			local cfg = factories.config()
			local env = freshEnv()
			for i = 1, 300 do
				env = store.applyEvent(env, gesture("g" .. i, "pet"), cfg)
			end
			expect(#env.journal).toBe(store.MAX_JOURNAL)
			expect(env.journal[store.MAX_JOURNAL].event_id).toBe("g300")
			expect(#env.seen).toBe(store.MAX_SEEN)
			expect(env.seen[store.MAX_SEEN]).toBe("g300")
			expect(env.profile.stats.pets).toBe(300)
		end)

		it("never writes command details or untrusted attribute text into the journal", function()
			local cfg = factories.config()
			local env = store.applyEvent(freshEnv(), finish("c1", 1, true), cfg)
			local poisoned = gesture("g1", "feed", { item = "rm -rf ~/secret" })
			env = store.applyEvent(env, poisoned, cfg)
			env = store.applyEvent(env, gesture("g2", "perform", { animation = "curl evil.sh" }), cfg)
			for _, entry in env.journal do
				expect(entry.summary).notToContain("rm -rf")
				expect(entry.summary).notToContain("secret")
				expect(entry.summary).notToContain("curl")
				expect(#entry.summary).toBeLessThanOrEqual(120)
			end
		end)

		it("ignores malformed events", function()
			local env = freshEnv()
			local out, applied = store.applyEvent(env, { type = "gesture" } :: any, factories.config())
			expect(applied).toBe(false)
			expect(out).toEqual(env)
		end)
	end)

	describe("applyIntent", function()
		local function opts()
			return { wall_s = WALL + 10, new_cat_id = factories.catIds() }
		end

		it("applies gesture intents through the event path", function()
			local intent = factories.intent("pet", nil, { intent_id = "i1" })
			local env, effects = store.applyIntent(freshEnv(), intent, factories.config(), opts())
			expect(env.profile.stats.pets).toBe(1)
			expect(env.seen).toEqual({ "i1" })
			expect(effects[1].kind).toBe("gesture")
			expect(effects[1].event.event_id).toBe("i1")
		end)

		it("ignores a duplicate intent", function()
			local cfg = factories.config()
			local intent = factories.intent("feed", { item = "fish" }, { intent_id = "i1" })
			local once = store.applyIntent(freshEnv(), intent, cfg, opts())
			local twice, effects = store.applyIntent(once, intent, cfg, opts())
			expect(twice).toEqual(once)
			expect(effects).toEqual({})
		end)

		it("rejects invalid intents without touching state", function()
			local env = freshEnv()
			local out, effects = store.applyIntent(env, factories.intent("run_command"), factories.config(), opts())
			expect(out).toEqual(env)
			expect(effects[1].kind).toBe("rejected")
		end)

		it("snoozes for the requested minutes and unsnoozes", function()
			local cfg = factories.config()
			local env, effects = store.applyIntent(
				freshEnv(),
				factories.intent("snooze", { minutes = 30 }, { intent_id = "s1" }),
				cfg,
				opts()
			)
			expect(env.snooze_until).toBe(WALL + 10 + 30 * 60)
			expect(effects[1].kind).toBe("snooze")
			expect(store.isSnoozed(env, WALL + 20)).toBe(true)
			expect(store.isSnoozed(env, WALL + 10 + 30 * 60)).toBe(false)
			env = store.applyIntent(env, factories.intent("unsnooze", nil, { intent_id = "s2" }), cfg, opts())
			expect(env.snooze_until).toBeNil()
		end)

		it("reset_identity adopts a new cat but keeps dedupe history", function()
			local cfg = factories.config()
			local env = store.applyIntent(freshEnv(), factories.intent("pet", nil, { intent_id = "i1" }), cfg, opts())
			local reset, effects =
				store.applyIntent(env, factories.intent("reset_identity", nil, { intent_id = "i2" }), cfg, opts())
			expect(reset.profile.cat_id).toBe("cat-000000000001")
			expect(reset.profile.stats.pets).toBe(0)
			expect(reset.seen).toEqual({ "i1", "i2" })
			expect(effects[1].kind).toBe("reset_identity")
			expect(effects[1].cat_id).toBe("cat-000000000001")
		end)

		it("reset_identity is rejected when no id generator is supplied", function()
			local env = freshEnv()
			local out, effects = store.applyIntent(env, factories.intent("reset_identity"), factories.config())
			expect(out).toEqual(env)
			expect(effects[1].kind).toBe("rejected")
		end)

		it("returns config changes as effects instead of storing them", function()
			local cfg = factories.config()
			local cases: { { any } } = {
				{
					factories.intent("set_personality", { mischief = 0.2 }, { intent_id = "a" }),
					{ ["personality.mischief"] = 0.2 },
				},
				{
					factories.intent(
						"set_config",
						{ key = "behavior.allow_swats", value = false },
						{ intent_id = "b" }
					),
					{ ["behavior.allow_swats"] = false },
				},
				{
					factories.intent("set_overlay", { enabled = false }, { intent_id = "c" }),
					{ ["rendering.overlay"] = false },
				},
				{ factories.intent("rename", { name = "Rex" }, { intent_id = "d" }), { ["cat.name"] = "Rex" } },
			}
			for _, case in cases do
				local env = freshEnv()
				local out, effects = store.applyIntent(env, case[1], cfg, opts())
				expect(effects).toEqual({ { kind = "config", changes = case[2] } })
				expect(out.profile).toEqual(env.profile)
				expect(out.seen).toEqual({ case[1].intent_id })
			end
		end)

		it("exports a copy of the profile", function()
			local env = freshEnv()
			local _, effects = store.applyIntent(env, factories.intent("export_identity"), factories.config(), opts())
			expect(effects[1].kind).toBe("export_identity")
			expect(effects[1].profile).toEqual(env.profile)
		end)

		it("clear_ai_state drops AI journal entries", function()
			local env = freshEnv()
			env.journal = {
				{ at = 1, event_id = "a1", kind = "ai", summary = "Carly suggested hop" },
				{ at = 2, event_id = "g1", kind = "gesture", summary = "Was petted" },
			}
			local out, effects = store.applyIntent(env, factories.intent("clear_ai_state"), factories.config(), opts())
			expect(effects[1].kind).toBe("clear_ai_state")
			expect(#out.journal).toBe(1)
			expect(out.journal[1].kind).toBe("gesture")
		end)
	end)

	describe("recordReaction", function()
		it("remembers the last reaction and journals it", function()
			local decision = {
				id = "react.command_failed",
				animation = "disappointed",
				intensity = 0.5,
				duration_ms = 1800,
				reason = "A command failed",
			}
			local env = store.recordReaction(freshEnv(), decision :: any, WALL + 5)
			expect(env.last_reaction).toEqual({
				at = WALL + 5,
				id = "react.command_failed",
				animation = "disappointed",
				reason = "A command failed",
			})
			expect(env.rev).toBe(1)
			expect(env.journal[1].kind).toBe("reaction")
			expect(#env.journal[1].summary).toBeLessThanOrEqual(120)
		end)
	end)
end)
