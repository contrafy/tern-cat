--!strict
local t = require("../../lib/test")
local support = require("./support")
local png = require("../../../cat/sprite/png")

local describe, it, expect = t.describe, t.it, t.expect

describe("sprite/png.inspect", function()
	describe("real fixture files", function()
		it("reads dimensions, depth and alpha of a plain PNG frame", function()
			local info, err = png.inspect(support.readFixture("good-minimal/idle_0.png"))
			expect(err).toBeNil()
			assert(info, "expected info")
			expect(info.width).toBe(16)
			expect(info.height).toBe(16)
			expect(info.frames).toBe(1)
			expect(info.animated).toBe(false)
			expect(info.has_alpha).toBe(true)
		end)

		it("counts APNG frames from acTL so packs can be checked against their frame list", function()
			local info = png.inspect(support.readFixture("good-minimal/idle.apng"))
			assert(info, "expected info")
			expect(info.animated).toBe(true)
			expect(info.frames).toBe(2)
			expect(info.width).toBe(16)
		end)

		it("reports sprite sheet strip dimensions", function()
			local info = png.inspect(support.readFixture("good-minimal/idle_sheet.png"))
			assert(info, "expected info")
			expect(info.width).toBe(32)
			expect(info.height).toBe(16)
		end)

		it("rejects a text file disguised with a .png extension", function()
			local info, err = png.inspect(support.readFixture("bad-not-png/idle_0.png"))
			expect(info).toBeNil()
			expect(err).toContain("signature")
		end)
	end)

	describe("synthetic headers", function()
		it("derives alpha from color type or a tRNS chunk", function()
			local rgb = png.inspect(support.makePng({ color_type = 2 }))
			local rgbTrns = png.inspect(support.makePng({ color_type = 2, trns = true }))
			local gray = png.inspect(support.makePng({ color_type = 4 }))
			assert(rgb and rgbTrns and gray, "expected info")
			expect(rgb.has_alpha).toBe(false)
			expect(rgbTrns.has_alpha).toBe(true)
			expect(gray.has_alpha).toBe(true)
		end)

		it("rejects zero dimensions", function()
			local info, err = png.inspect(support.makePng({ width = 0 }))
			expect(info).toBeNil()
			expect(err).toContain("dimensions")
		end)

		it("rejects invalid bit depth / color type combinations", function()
			local info, err = png.inspect(support.makePng({ color_type = 6, bit_depth = 4 }))
			expect(info).toBeNil()
			expect(err).toContain("bit depth")
		end)

		it("rejects an APNG that declares zero frames", function()
			local info, err = png.inspect(support.makePng({ frames = 0 }))
			expect(info).toBeNil()
			expect(err).toContain("acTL")
		end)

		it("ignores acTL appearing after image data (not an APNG)", function()
			local bytes = support.makePng()
			local iend = string.find(bytes, "IEND", 1, true)
			assert(iend, "IEND chunk missing")
			local actl = string.pack(">I4", 8) .. "acTL" .. string.pack(">I4I4", 9, 0) .. "\0\0\0\0"
			local late = string.sub(bytes, 1, iend - 5) .. actl .. string.sub(bytes, iend - 4)
			local info = png.inspect(late)
			assert(info, "expected info")
			expect(info.frames).toBe(1)
			expect(info.animated).toBe(false)
		end)
	end)

	describe("hostile input never throws", function()
		it("returns an error for non-string input", function()
			local info, err = png.inspect(nil :: any)
			expect(info).toBeNil()
			expect(err).notToBeNil()
		end)

		it("returns an error for every truncation of a valid file", function()
			local bytes = support.makePng({ frames = 2 })
			for len = 0, #bytes - 13 do
				local ok, info = pcall(png.inspect, string.sub(bytes, 1, len))
				expect(ok).toBe(true)
				expect(info).toBeNil()
			end
		end)

		it("rejects a chunk length that runs past the end of the data", function()
			local bytes = support.makePng()
			local idat = string.find(bytes, "IDAT", 1, true)
			assert(idat, "IDAT chunk missing")
			local corrupt = string.sub(bytes, 1, idat - 5) .. string.pack(">I4", 0x7fffffff) .. string.sub(bytes, idat)
			local info, err = png.inspect(corrupt)
			expect(info).toBeNil()
			expect(err).toContain("truncated")
		end)

		it("rejects a missing IHDR", function()
			local bytes = "\137PNG\r\n\26\n" .. string.pack(">I4", 13) .. "IDAT" .. string.rep("\0", 17)
			local info, err = png.inspect(bytes)
			expect(info).toBeNil()
			expect(err).toContain("IHDR")
		end)

		it("survives random garbage after a valid signature", function()
			local seed = 12345
			for _ = 1, 200 do
				local parts = { "\137PNG\r\n\26\n" }
				for _ = 1, 64 do
					seed = (seed * 1103515245 + 12345) % 2147483648
					table.insert(parts, string.char(seed % 256))
				end
				local ok = pcall(png.inspect, table.concat(parts))
				expect(ok).toBe(true)
			end
		end)
	end)
end)
