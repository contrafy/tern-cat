--!strict
local t = require("../../lib/test")
local clock = require("../../../cat/core/clock")

local describe, it, expect = t.describe, t.it, t.expect

describe("core.clock", function()
	describe("fromPrimitives", function()
		it("delegates to the injected primitives so Tern and tests share one interface", function()
			local c = clock.fromPrimitives(function()
				return 1500
			end, function()
				return 1700000000
			end, function()
				return { hour = 9, min = 30 }
			end)
			expect(c.now_ms()).toBe(1500)
			expect(c.wall_s()).toBe(1700000000)
			expect(c.local_hm()).toEqual({ hour = 9, min = 30 })
		end)
	end)

	describe("fake", function()
		it("starts at the given time", function()
			local c = clock.fake({ now_ms = 10, wall_s = 1000, hour = 22, min = 15 })
			expect(c.now_ms()).toBe(10)
			expect(c.wall_s()).toBe(1000)
			expect(c.local_hm()).toEqual({ hour = 22, min = 15 })
		end)

		it("defaults to a fixed, deterministic origin", function()
			local a = clock.fake({})
			local b = clock.fake({})
			expect(a.now_ms()).toBe(b.now_ms())
			expect(a.wall_s()).toBe(b.wall_s())
			expect(a.local_hm()).toEqual(b.local_hm())
		end)

		it("advances monotonic and wall time together", function()
			local c = clock.fake({ now_ms = 0, wall_s = 100 })
			c.advance(2500)
			expect(c.now_ms()).toBe(2500)
			expect(c.wall_s()).toBe(102)
			c.advance(500)
			expect(c.wall_s()).toBe(103)
		end)

		it("rolls local time over midnight when advanced", function()
			local c = clock.fake({ hour = 23, min = 50 })
			c.advance(20 * 60 * 1000)
			expect(c.local_hm()).toEqual({ hour = 0, min = 10 })
		end)

		it("rejects negative advances to keep monotonic time monotonic", function()
			local c = clock.fake({})
			expect(function()
				c.advance(-1)
			end).toThrow("monotonic")
		end)
	end)

	describe("inQuietHours", function()
		it("matches a same-day range inclusive of start, exclusive of stop", function()
			expect(clock.inQuietHours({ hour = 13, min = 0 }, "13:00", "14:00")).toBeTruthy()
			expect(clock.inQuietHours({ hour = 13, min = 59 }, "13:00", "14:00")).toBeTruthy()
			expect(clock.inQuietHours({ hour = 14, min = 0 }, "13:00", "14:00")).toBeFalsy()
			expect(clock.inQuietHours({ hour = 12, min = 59 }, "13:00", "14:00")).toBeFalsy()
		end)

		it("handles overnight ranges that wrap midnight", function()
			expect(clock.inQuietHours({ hour = 23, min = 30 }, "22:00", "07:00")).toBeTruthy()
			expect(clock.inQuietHours({ hour = 0, min = 0 }, "22:00", "07:00")).toBeTruthy()
			expect(clock.inQuietHours({ hour = 6, min = 59 }, "22:00", "07:00")).toBeTruthy()
			expect(clock.inQuietHours({ hour = 7, min = 0 }, "22:00", "07:00")).toBeFalsy()
			expect(clock.inQuietHours({ hour = 12, min = 0 }, "22:00", "07:00")).toBeFalsy()
		end)

		it("treats an empty range (start == stop) as never quiet", function()
			expect(clock.inQuietHours({ hour = 3, min = 0 }, "03:00", "03:00")).toBeFalsy()
		end)

		it("fails closed (not quiet) on malformed times instead of crashing", function()
			for _, bad in { "", "7", "25:00", "12:60", "ab:cd", "12:5", "-1:00" } do
				expect(clock.inQuietHours({ hour = 12, min = 0 }, bad, "13:00")).toBeFalsy()
				expect(clock.inQuietHours({ hour = 12, min = 0 }, "11:00", bad)).toBeFalsy()
			end
		end)
	end)

	describe("parseHm", function()
		it("returns minutes since midnight for valid HH:MM", function()
			expect(clock.parseHm("00:00")).toBe(0)
			expect(clock.parseHm("23:59")).toBe(23 * 60 + 59)
			expect(clock.parseHm("7:05")).toBe(7 * 60 + 5)
			expect(clock.parseHm("24:00")).toBeNil()
		end)
	end)
end)
