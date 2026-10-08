--!strict
local t = require("../../lib/test")
local model = require("../../../cat/core/model")
local needs = require("../../../cat/core/needs")

local describe, it, expect = t.describe, t.it, t.expect

local CAT_ID = "cat-0123456789ab"

local function sequence(values: { number }): () -> number
	local i = 0
	return function()
		i = i % #values + 1
		return values[i]
	end
end

local function rawProfile(overrides: { [string]: any }?): { [string]: any }
	local p = model.newProfile(CAT_ID, 1000) :: any
	for k, v in overrides or {} do
		p[k] = v
	end
	return p
end

describe("model", function()
	describe("newProfile", function()
		it("creates a calm, content cat with zeroed stats", function()
			local p = model.newProfile(CAT_ID, 1000)
			expect(p.schema_version).toBe(1)
			expect(p.cat_id).toBe(CAT_ID)
			expect(p.needs).toEqual(needs.neutral())
			expect(p.mood).toBe("calm")
			expect(p.stats).toEqual({ pets = 0, pokes = 0, feeds = 0, plays = 0, command_reactions = 0 })
			expect(p.fail_streak).toBe(0)
			expect(p.created_at).toBe(1000)
			expect(p.last_updated_at).toBe(1000)
		end)
	end)

	describe("newCatId", function()
		it("produces cat- plus 12 lowercase hex chars from the injected random source", function()
			local id = model.newCatId(sequence({ 0, 0.999, 0.5, 0.0625 }))
			expect(id).toBe("cat-0f810f810f81")
			expect(model.isCatId(id)).toBe(true)
		end)

		it("accepts an Rng-like object", function()
			local rng = {
				next = function(_self)
					return 0.75
				end,
			}
			expect(model.newCatId(rng :: any)).toBe("cat-cccccccccccc")
		end)

		it("is deterministic for the same random sequence", function()
			expect(model.newCatId(sequence({ 0.1, 0.2, 0.3 }))).toBe(model.newCatId(sequence({ 0.1, 0.2, 0.3 })))
		end)
	end)

	describe("migrate", function()
		it("accepts a valid profile unchanged", function()
			local p = model.newProfile(CAT_ID, 1000)
			local out, note = model.migrate(p)
			expect(out).toEqual(p)
			expect(note).toBeNil()
		end)

		it("treats a missing schema_version as version 1", function()
			local out = model.migrate(rawProfile({ schema_version = nil }))
			expect(out).notToBeNil()
			expect((out :: any).schema_version).toBe(1)
		end)

		it("rejects non-objects, unknown future versions and missing identity", function()
			expect((model.migrate("nope"))).toBeNil()
			expect((model.migrate(nil))).toBeNil()
			expect((model.migrate(rawProfile({ schema_version = 99 })))).toBeNil()
			expect((model.migrate(rawProfile({ cat_id = "../../etc" })))).toBeNil()
			local _, err = model.migrate(rawProfile({ cat_id = 5 }))
			expect(err).toContain("cat_id")
		end)

		it("repairs individual fields instead of discarding the cat", function()
			local out, note = model.migrate(rawProfile({
				needs = { hunger = "lots", energy = 2, affection = 0 / 0 },
				mood = "furious",
				stats = { pets = -3, pokes = 2.7, feeds = "x" },
				fail_streak = 500,
			}))
			local p = out :: any
			expect(p).notToBeNil()
			expect(p.cat_id).toBe(CAT_ID)
			expect(p.needs.hunger).toBe(needs.neutral().hunger)
			expect(p.needs.energy).toBe(1)
			expect(p.needs.affection).toBe(needs.neutral().affection)
			expect(p.needs.boredom).toBe(needs.neutral().boredom)
			expect(p.mood).toBe("calm")
			expect(p.stats).toEqual({ pets = 0, pokes = 2, feeds = 0, plays = 0, command_reactions = 0 })
			expect(p.fail_streak).toBe(20)
			expect(note).toContain("needs.hunger")
			expect(note).toContain("mood")
		end)

		it("repairs broken timestamps from the supplied wall clock", function()
			local raw = rawProfile({ created_at = "yesterday" })
			raw.last_updated_at = nil
			local out = model.migrate(raw, 5000) :: any
			expect(out.created_at).toBe(5000)
			expect(out.last_updated_at).toBe(5000)
		end)

		it("drops unknown fields", function()
			local out = model.migrate(rawProfile({ secret = "x" })) :: any
			expect(out.secret).toBeNil()
		end)
	end)
end)
