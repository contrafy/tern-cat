--!strict
local t = require("../../lib/test")
local rng = require("../../../cat/core/rng")

local describe, it, expect = t.describe, t.it, t.expect

local function draws(r: any, n: number): { number }
	local out = {}
	for _ = 1, n do
		table.insert(out, r:next())
	end
	return out
end

describe("core.rng", function()
	it("replays the same sequence for the same seed so behavior is reproducible", function()
		expect(draws(rng.new(42), 20)).toEqual(draws(rng.new(42), 20))
	end)

	it("produces different sequences for different seeds", function()
		expect(draws(rng.new(1), 10)).notToEqual(draws(rng.new(2), 10))
	end)

	it("handles seed 0 without degenerating into a constant stream", function()
		local values = draws(rng.new(0), 50)
		local distinct = {}
		local count = 0
		for _, v in values do
			if not distinct[v] then
				distinct[v] = true
				count += 1
			end
		end
		expect(count).toBe(50)
	end)

	it("accepts negative, fractional and huge seeds deterministically", function()
		for _, seed in { -7, 3.75, 2 ^ 40 + 11, math.huge } do
			expect(draws(rng.new(seed), 5)).toEqual(draws(rng.new(seed), 5))
		end
	end)

	it("keeps next() in [0, 1)", function()
		local r = rng.new(123)
		for _ = 1, 5000 do
			local v = r:next()
			expect(v).toBeGreaterThanOrEqual(0)
			expect(v).toBeLessThan(1)
		end
	end)

	it("keeps int(lo, hi) inclusive and reaches both ends", function()
		local r = rng.new(9)
		local seenLo, seenHi = false, false
		for _ = 1, 2000 do
			local v = r:int(3, 6)
			expect(v).toBeGreaterThanOrEqual(3)
			expect(v).toBeLessThanOrEqual(6)
			expect(v % 1).toBe(0)
			seenLo = seenLo or v == 3
			seenHi = seenHi or v == 6
		end
		expect(seenLo).toBeTruthy()
		expect(seenHi).toBeTruthy()
	end)

	it("returns lo when the int range is empty or a single value", function()
		local r = rng.new(5)
		expect(r:int(4, 4)).toBe(4)
		expect(r:int(8, 2)).toBe(8)
	end)

	it("treats chance(0) as never and chance(1) as always", function()
		local r = rng.new(77)
		for _ = 1, 500 do
			expect(r:chance(0)).toBeFalsy()
			expect(r:chance(1)).toBeTruthy()
			expect(r:chance(-1)).toBeFalsy()
			expect(r:chance(2)).toBeTruthy()
		end
	end)

	it("roughly honors chance probabilities", function()
		local r = rng.new(2024)
		local hits = 0
		for _ = 1, 10000 do
			if r:chance(0.25) then
				hits += 1
			end
		end
		expect(hits).toBeGreaterThan(2200)
		expect(hits).toBeLessThan(2800)
	end)

	it("never picks a zero-weight entry and returns nil when nothing is eligible", function()
		local r = rng.new(31)
		for _ = 1, 500 do
			local pick = r:weighted({ a = 1, b = 0, c = 3, d = -2 })
			expect(pick == "a" or pick == "c").toBeTruthy()
		end
		expect(r:weighted({ a = 0, b = -1 })).toBeNil()
		expect(r:weighted({})).toBeNil()
	end)

	it("weights picks proportionally", function()
		local r = rng.new(8)
		local counts = { a = 0, b = 0 }
		for _ = 1, 10000 do
			local k = r:weighted({ a = 1, b = 3 }) :: string
			counts[k] += 1
		end
		expect(counts.b / 10000).toBeCloseTo(0.75, 0.03)
	end)

	it("is deterministic for weighted picks regardless of table construction order", function()
		local a = rng.new(99)
		local b = rng.new(99)
		local w1 = { x = 1, y = 2, z = 3 }
		local w2 = {}
		w2.z = 3
		w2.y = 2
		w2.x = 1
		for _ = 1, 100 do
			expect(a:weighted(w1)).toBe(b:weighted(w2))
		end
	end)

	it("can be snapshotted via state() and resumed with fromState()", function()
		local r = rng.new(4242)
		draws(r, 7)
		local resumed = rng.fromState(r:state())
		expect(draws(resumed, 10)).toEqual(draws(r, 10))
	end)
end)
