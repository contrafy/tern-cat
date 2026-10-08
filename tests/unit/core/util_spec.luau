--!strict
local t = require("../../lib/test")
local util = require("../../../cat/core/util")

local describe, it, expect = t.describe, t.it, t.expect

describe("util", function()
	describe("clamp", function()
		it("keeps normalized quantities inside their range", function()
			expect(util.clamp(5, 0, 1)).toBe(1)
			expect(util.clamp(-5, 0, 1)).toBe(0)
			expect(util.clamp(0.4, 0, 1)).toBe(0.4)
			expect(util.clamp01(1.5)).toBe(1)
			expect(util.clamp01(-0.1)).toBe(0)
		end)

		it("maps NaN to the lower bound so corrupted numbers cannot leak through", function()
			expect(util.clamp(0 / 0, 0.2, 1)).toBe(0.2)
		end)
	end)

	describe("isFiniteNumber", function()
		it("accepts only real, finite numbers", function()
			expect(util.isFiniteNumber(1.5)).toBe(true)
			expect(util.isFiniteNumber(0)).toBe(true)
			expect(util.isFiniteNumber(0 / 0)).toBe(false)
			expect(util.isFiniteNumber(math.huge)).toBe(false)
			expect(util.isFiniteNumber(-math.huge)).toBe(false)
			expect(util.isFiniteNumber("1")).toBe(false)
			expect(util.isFiniteNumber(nil)).toBe(false)
		end)
	end)

	describe("deepCopy", function()
		it("returns an independent copy so callers cannot mutate shared defaults", function()
			local original = { a = { b = { 1, 2 } }, c = "x" }
			local copy = util.deepCopy(original)
			expect(copy).toEqual(original)
			copy.a.b[1] = 99
			expect(original.a.b[1]).toBe(1)
		end)
	end)

	describe("deepEqual", function()
		it("compares nested structure, not identity", function()
			expect(util.deepEqual({ a = { 1, 2 } }, { a = { 1, 2 } })).toBe(true)
			expect(util.deepEqual({ a = { 1, 2 } }, { a = { 1 } })).toBe(false)
			expect(util.deepEqual({ a = 1 }, { a = 1, b = 2 })).toBe(false)
			expect(util.deepEqual(1, "1")).toBe(false)
		end)
	end)

	describe("deepMerge", function()
		it("overlays nested fields without mutating either input", function()
			local base = { a = { x = 1, y = 2 }, b = true }
			local over = { a = { y = 3 } }
			local merged = util.deepMerge(base, over)
			expect(merged).toEqual({ a = { x = 1, y = 3 }, b = true })
			expect(base.a.y).toBe(2)
			merged.a.x = 10
			expect(base.a.x).toBe(1)
		end)

		it("replaces arrays wholesale instead of merging by index", function()
			local merged = util.deepMerge({ list = { 1, 2, 3 } }, { list = { 9 } })
			expect(merged.list).toEqual({ 9 })
		end)

		it("treats a non-table base as empty", function()
			expect(util.deepMerge(nil :: any, { a = 1 })).toEqual({ a = 1 })
		end)
	end)

	describe("ringPush", function()
		it("keeps the newest items last and drops the oldest beyond max", function()
			local list = { "a", "b", "c" }
			local out = util.ringPush(list, "d", 3)
			expect(out).toEqual({ "b", "c", "d" })
			expect(list).toEqual({ "a", "b", "c" })
		end)

		it("grows until max is reached", function()
			expect(util.ringPush({}, 1, 3)).toEqual({ 1 })
		end)
	end)

	describe("paths", function()
		it("reads dotted paths and returns nil for missing or non-table segments", function()
			local tbl = { a = { b = { c = 3 } }, s = "x" }
			expect(util.getPath(tbl, "a.b.c")).toBe(3)
			expect(util.getPath(tbl, "a.z.c")).toBeNil()
			expect(util.getPath(tbl, "s.x")).toBeNil()
		end)

		it("sets dotted paths immutably, creating missing tables", function()
			local tbl = { a = { b = 1 } }
			local out = util.setPath(tbl, "a.c.d", true)
			expect(out).toEqual({ a = { b = 1, c = { d = true } } })
			expect(tbl).toEqual({ a = { b = 1 } })
		end)
	end)

	describe("strings", function()
		it("strips control characters", function()
			expect(util.stripControl("a\tb\nc\27[31m")).toBe("abc[31m")
		end)

		it("parses HH:MM and rejects malformed values", function()
			expect(util.parseHm("08:30")).toEqual({ hour = 8, min = 30 })
			expect(util.parseHm("23:59")).toEqual({ hour = 23, min = 59 })
			expect(util.parseHm("24:00")).toBeNil()
			expect(util.parseHm("7:00")).toBeNil()
			expect(util.parseHm("07:60")).toBeNil()
			expect(util.parseHm(7 :: any)).toBeNil()
		end)
	end)

	describe("collections", function()
		it("finds values in lists and reports array shape", function()
			expect(util.contains({ "a", "b" }, "b")).toBe(true)
			expect(util.contains({ "a" }, "z")).toBe(false)
			expect(util.isArray({ 1, 2 })).toBe(true)
			expect(util.isArray({})).toBe(true)
			expect(util.isArray({ a = 1 })).toBe(false)
			expect(util.sortedKeys({ b = 1, a = 2 })).toEqual({ "a", "b" })
		end)
	end)
end)
