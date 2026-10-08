--!strict
local t = require("../../lib/test")
local needs = require("../../../cat/core/needs")
local schema = require("../../../cat/config/schema")

local describe, it, expect = t.describe, t.it, t.expect

local HOUR = 3600

local function personality(overrides: { [string]: number }?)
	local p = schema.defaults().personality :: any
	for k, v in overrides or {} do
		p[k] = v
	end
	return p
end

local function expectWithinSoftBounds(n: any)
	expect(n.hunger).toBeLessThanOrEqual(0.85)
	expect(n.energy).toBeGreaterThanOrEqual(0.1)
	expect(n.affection).toBeGreaterThanOrEqual(0.15)
	expect(n.boredom).toBeLessThanOrEqual(0.9)
	for _, v in n do
		expect(v).toBeGreaterThanOrEqual(0)
		expect(v).toBeLessThanOrEqual(1)
	end
end

describe("needs", function()
	describe("neutral", function()
		it("starts content: fed, rested, loved, engaged", function()
			expect(needs.neutral()).toEqual({ hunger = 0.2, energy = 0.8, affection = 0.6, boredom = 0.2 })
		end)
	end)

	describe("decay", function()
		it("moves every need in its natural direction while awake", function()
			local start = needs.neutral()
			local after = needs.decay(start, 2 * HOUR, personality())
			expect(after.hunger).toBeGreaterThan(start.hunger)
			expect(after.energy).toBeLessThan(start.energy)
			expect(after.affection).toBeLessThan(start.affection)
			expect(after.boredom).toBeGreaterThan(start.boredom)
		end)

		it("recovers energy while asleep", function()
			local tired = { hunger = 0.2, energy = 0.3, affection = 0.6, boredom = 0.2 }
			expect(needs.decay(tired, HOUR, personality(), true).energy).toBeGreaterThan(0.3)
		end)

		it("never pushes needs past the non-punishing soft caps, however long", function()
			local after = needs.decay(needs.neutral(), 10000 * HOUR, personality())
			expectWithinSoftBounds(after)
		end)

		it("does not pull an already-high need back down to the cap", function()
			local fed = { hunger = 0.95, energy = 0.05, affection = 0.1, boredom = 0.95 }
			expect(needs.decay(fed, HOUR, personality())).toEqual(fed)
		end)

		it("treats zero, negative and non-finite elapsed time as no time", function()
			local start = needs.neutral()
			expect(needs.decay(start, 0, personality())).toEqual(start)
			expect(needs.decay(start, -HOUR, personality())).toEqual(start)
			expect(needs.decay(start, 0 / 0, personality())).toEqual(start)
		end)

		it("does not mutate its input", function()
			local start = needs.neutral()
			needs.decay(start, HOUR, personality())
			expect(start).toEqual(needs.neutral())
		end)
	end)

	describe("catchUp", function()
		it("an 8 hour absence moves needs noticeably but stays friendly", function()
			local start = needs.neutral()
			local after = needs.catchUp(start, 1000, 1000 + 8 * HOUR, 12, true, true, personality())
			expect(after.hunger - start.hunger).toBeGreaterThanOrEqual(0.1)
			expect(start.affection - after.affection).toBeGreaterThanOrEqual(0.1)
			expect(after.boredom - start.boredom).toBeGreaterThanOrEqual(0.1)
			expectWithinSoftBounds(after)
		end)

		it("caps offline time at offline_hours_cap", function()
			local start = needs.neutral()
			local capped = needs.catchUp(start, 0, 100 * HOUR, 12, true, true, personality())
			local exact = needs.catchUp(start, 0, 12 * HOUR, 12, true, true, personality())
			expect(capped).toEqual(exact)
		end)

		it("ignores clock skew (now before last) instead of rewinding needs", function()
			local start = { hunger = 0.5, energy = 0.5, affection = 0.5, boredom = 0.5 }
			expect(needs.catchUp(start, 5000, 1000, 12, true, true, personality())).toEqual(start)
		end)

		it("is never punishing even after a year away with the cap disabled", function()
			local after = needs.catchUp(needs.neutral(), 0, 365 * 24 * HOUR, 168, true, true, personality())
			expectWithinSoftBounds(after)
		end)

		it("does not simulate time away when offline_progress is off", function()
			local start = needs.neutral()
			local away = needs.catchUp(start, 0, 8 * HOUR, 12, true, false, personality())
			expect(away.hunger - start.hunger).toBeLessThan(0.05)
		end)

		it("returns neutral needs when needs are disabled", function()
			local start = { hunger = 0.7, energy = 0.2, affection = 0.3, boredom = 0.8 }
			expect(needs.catchUp(start, 0, 8 * HOUR, 12, false, true, personality())).toEqual(needs.neutral())
		end)
	end)

	describe("applyGesture", function()
		it("petting raises affection", function()
			local start = needs.neutral()
			expect(needs.applyGesture(start, "pet").affection).toBeGreaterThan(start.affection)
		end)

		it("feeding lowers hunger, and a treat less than a meal", function()
			local hungry = { hunger = 0.8, energy = 0.5, affection = 0.5, boredom = 0.5 }
			local treat = needs.applyGesture(hungry, "feed", "treat")
			local kibble = needs.applyGesture(hungry, "feed", "kibble")
			expect(treat.hunger).toBeLessThan(0.8)
			expect(kibble.hunger).toBeLessThan(treat.hunger)
		end)

		it("playing cures boredom and costs a little energy", function()
			local bored = { hunger = 0.3, energy = 0.7, affection = 0.5, boredom = 0.8 }
			local after = needs.applyGesture(bored, "play", "ball")
			expect(after.boredom).toBeLessThan(0.8)
			expect(after.energy).toBeLessThan(0.7)
			expect(0.7 - after.energy).toBeLessThan(0.1)
		end)

		it("poking is mildly interesting and never drives affection below the floor", function()
			local n = { hunger = 0.3, energy = 0.7, affection = 0.16, boredom = 0.5 }
			for _ = 1, 50 do
				n = needs.applyGesture(n, "poke")
			end
			expect(n.boredom).toBeLessThan(0.5)
			expect(n.affection).toBeGreaterThanOrEqual(0.15)
		end)

		it("keeps every need inside [0, 1] under repeated gestures", function()
			local n = needs.neutral()
			for _ = 1, 30 do
				n = needs.applyGesture(n, "pet")
				n = needs.applyGesture(n, "feed", "fish")
				n = needs.applyGesture(n, "play", "feather")
			end
			for _, v in n do
				expect(v).toBeGreaterThanOrEqual(0)
				expect(v).toBeLessThanOrEqual(1)
			end
			expect(n.energy).toBeGreaterThanOrEqual(0.1)
		end)

		it("leaves needs unchanged for unknown gestures", function()
			local start = needs.neutral()
			expect(needs.applyGesture(start, "dance" :: any)).toEqual(start)
		end)
	end)

	describe("deriveMood", function()
		it("a content cat is calm", function()
			expect(needs.deriveMood(needs.neutral(), personality())).toBe("calm")
		end)

		it("an exhausted cat is sleepy", function()
			expect(needs.deriveMood({ hunger = 0.2, energy = 0.15, affection = 0.6, boredom = 0.2 }, personality())).toBe(
				"sleepy"
			)
		end)

		it("a very hungry cat is annoyed", function()
			expect(needs.deriveMood({ hunger = 0.8, energy = 0.6, affection = 0.6, boredom = 0.2 }, personality())).toBe(
				"annoyed"
			)
		end)

		it("a bored cat is curious or playful depending on personality", function()
			local bored = { hunger = 0.2, energy = 0.6, affection = 0.6, boredom = 0.8 }
			expect(needs.deriveMood(bored, personality({ curiosity = 0.9, mischief = 0.2 }))).toBe("curious")
			expect(needs.deriveMood(bored, personality({ curiosity = 0.2, mischief = 0.9 }))).toBe("playful")
		end)

		it("a loved and fed cat is happy", function()
			expect(needs.deriveMood({ hunger = 0.2, energy = 0.6, affection = 0.9, boredom = 0.2 }, personality())).toBe(
				"happy"
			)
		end)

		it("reacts to the most recent gesture", function()
			local n = needs.neutral()
			expect(needs.deriveMood(n, personality(), { gesture = "pet" })).toBe("happy")
			expect(needs.deriveMood(n, personality(), { gesture = "play" })).toBe("playful")
			local unloved = { hunger = 0.2, energy = 0.6, affection = 0.2, boredom = 0.2 }
			expect(needs.deriveMood(unloved, personality(), { gesture = "poke" })).toBe("annoyed")
		end)

		it("is deterministic", function()
			local n = { hunger = 0.4, energy = 0.5, affection = 0.5, boredom = 0.5 }
			expect(needs.deriveMood(n, personality())).toBe(needs.deriveMood(n, personality()))
		end)
	end)
end)
