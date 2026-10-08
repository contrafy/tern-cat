--!strict
local serde = require("@lune/serde")
local t = require("../../lib/test")
local support = require("../sprite/support")
local animations = require("../../../cat/render/animations")
local packs = require("../../../cat/window/packs")

local describe, it, expect = t.describe, t.it, t.expect

local BUNDLED = "/plugin/assets/packs"
local USER = "/data/packs"

local function decode(text: string): any
	return serde.decode("json", text)
end

local function base64(bytes: string): string
	return "B64" .. tostring(#bytes)
end

local function encodeJson(value: any): string
	return serde.encode("json", value)
end

-- Adds a valid pack with idle (2 frames + sheet) and, optionally, walk without a sheet.
local function addPack(files: { [string]: string }, dir: string, id: string, opts: { walk: boolean?, sheet: boolean? }?)
	local o = opts or {}
	local anims: { [string]: any } = {
		idle = {
			frames = { "idle_0.png", "idle_1.png" },
			durations_ms = { 300, 200 },
			loop = true,
			sheet = if o.sheet == false then nil else "idle_sheet.png",
		},
	}
	files[dir .. "/idle_0.png"] = support.makePng({ width = 16, height = 16 })
	files[dir .. "/idle_1.png"] = support.makePng({ width = 16, height = 16 })
	if o.sheet ~= false then
		files[dir .. "/idle_sheet.png"] = support.makePng({ width = 32, height = 16 })
	end
	if o.walk then
		anims.walk = { frames = { "walk_0.png" }, durations_ms = { 120 }, loop = false }
		files[dir .. "/walk_0.png"] = support.makePng({ width = 16, height = 16 })
	end
	files[dir .. "/pack.json"] = encodeJson({
		schema_version = 1,
		id = id,
		name = id,
		license = "CC0-1.0",
		canvas = { width = 16, height = 16 },
		animations = anims,
	})
end

local function make(files: { [string]: string })
	local fs, log = support.memoryFs(files)
	local cache = packs.new({
		fs = fs,
		decode = decode,
		base64 = base64,
		roots = { { dir = BUNDLED, source = "bundled" }, { dir = USER, source = "user" } },
		default_id = "orange-menace",
	})
	return cache, log
end

local function touched(log: { string }, needle: string): boolean
	for _, p in log do
		if string.find(p, needle, 1, true) then
			return true
		end
	end
	return false
end

describe("window/packs.select", function()
	it("loads only the wanted and default pack directories", function()
		local files = {}
		addPack(files, BUNDLED .. "/orange-menace", "orange-menace")
		addPack(files, BUNDLED .. "/void", "void")
		addPack(files, BUNDLED .. "/tuxedo", "tuxedo")
		local cache, log = make(files)
		local pack, warning = packs.select(cache, "void")
		assert(pack, "pack")
		expect(pack.manifest.id).toBe("void")
		expect(warning).toBeNil()
		expect(touched(log, "/tuxedo/")).toBe(false)
	end)

	it("falls back to the default pack with a warning", function()
		local files = {}
		addPack(files, BUNDLED .. "/orange-menace", "orange-menace")
		local cache = make(files)
		local pack, warning = packs.select(cache, "missing")
		assert(pack, "pack")
		expect(pack.manifest.id).toBe("orange-menace")
		expect(warning).toContain("missing")
	end)

	it("uses a user pack when no bundled pack has that id", function()
		local files = {}
		addPack(files, BUNDLED .. "/orange-menace", "orange-menace")
		addPack(files, USER .. "/calico", "calico")
		local cache = make(files)
		local pack = packs.select(cache, "calico")
		assert(pack, "pack")
		expect(pack.source).toBe("user")
	end)

	it("keeps the bundled pack when a user pack reuses its id", function()
		local files = {}
		addPack(files, BUNDLED .. "/orange-menace", "orange-menace")
		addPack(files, USER .. "/orange-menace", "orange-menace")
		local cache = make(files)
		local pack = packs.select(cache, "orange-menace")
		assert(pack, "pack")
		expect(pack.source).toBe("bundled")
	end)

	it("scans everything when a pack lives in a directory not named after its id", function()
		local files = {}
		addPack(files, BUNDLED .. "/orange-menace", "orange-menace")
		addPack(files, USER .. "/my-cat", "fancy")
		local cache = make(files)
		local pack = packs.select(cache, "fancy")
		assert(pack, "pack")
		expect(pack.manifest.id).toBe("fancy")
	end)

	it("caches selections until invalidated", function()
		local files = {}
		addPack(files, BUNDLED .. "/orange-menace", "orange-menace")
		local cache, log = make(files)
		packs.select(cache, "orange-menace")
		local n = #log
		packs.select(cache, "orange-menace")
		expect(#log).toBe(n)
		packs.invalidate(cache)
		packs.select(cache, "orange-menace")
		expect(#log).toBeGreaterThan(n)
	end)

	it("returns nil when no pack is usable", function()
		local cache = make({})
		local pack, warning = packs.select(cache, "orange-menace")
		expect(pack).toBeNil()
		expect(warning).toContain("no valid sprite packs")
	end)
end)

describe("window/packs.asset", function()
	it("builds a data URL sheet with frame timing", function()
		local files = {}
		addPack(files, BUNDLED .. "/orange-menace", "orange-menace")
		local cache = make(files)
		local pack = packs.select(cache, "orange-menace")
		assert(pack, "pack")
		local asset, resolved = packs.asset(cache, pack, "idle")
		assert(asset, "asset")
		expect(resolved).toBe("idle")
		expect(asset.sheet_url).toBe(
			"data:image/png;base64,B64" .. tostring(#files[BUNDLED .. "/orange-menace/idle_sheet.png"])
		)
		expect(asset.durations_ms).toEqual({ 300, 200 })
		expect(asset.loop).toBe(true)
		expect(asset.frame_w).toBe(16)
		expect(asset.frame_h).toBe(16)
	end)

	it("resolves missing animations through the fallback chain", function()
		local files = {}
		addPack(files, BUNDLED .. "/orange-menace", "orange-menace")
		local cache = make(files)
		local pack = packs.select(cache, "orange-menace")
		assert(pack, "pack")
		local asset, resolved = packs.asset(cache, pack, "swat")
		assert(asset, "asset")
		expect(resolved).toBe("idle")
	end)

	it("uses the first frame as a still sheet when no sheet was built", function()
		local files = {}
		addPack(files, BUNDLED .. "/orange-menace", "orange-menace", { walk = true })
		local cache = make(files)
		local pack = packs.select(cache, "orange-menace")
		assert(pack, "pack")
		local asset = packs.asset(cache, pack, "walk")
		assert(asset, "asset")
		expect(asset.durations_ms).toEqual({ 120 })
		expect(asset.sheet_url).toBe(
			"data:image/png;base64,B64" .. tostring(#files[BUNDLED .. "/orange-menace/walk_0.png"])
		)
	end)

	it("reads each sheet once", function()
		local files = {}
		addPack(files, BUNDLED .. "/orange-menace", "orange-menace")
		local cache, log = make(files)
		local pack = packs.select(cache, "orange-menace")
		assert(pack, "pack")
		packs.asset(cache, pack, "idle")
		local n = #log
		packs.asset(cache, pack, "idle")
		expect(#log).toBe(n)
	end)
end)

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function realBase64(bytes: string): string
	local out = {}
	for i = 1, #bytes, 3 do
		local a, b, c = string.byte(bytes, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local chars = {}
		for k = 3, 0, -1 do
			local idx = bit32.band(bit32.rshift(n, k * 6), 63) + 1
			table.insert(chars, string.sub(B64, idx, idx))
		end
		if c == nil then
			chars[4] = "="
		end
		if b == nil then
			chars[3] = "="
		end
		table.insert(out, table.concat(chars))
	end
	return table.concat(out)
end

describe("window/packs with the bundled art", function()
	local fs = require("@lune/fs")
	if not fs.isFile("assets/packs/orange-menace/pack.json") then
		return
	end
	it("produces an overlay asset for every canonical animation of every bundled pack", function()
		expect(realBase64("hi!?")).toBe("aGkhPw==")
		local cache = packs.new({
			fs = support.luneFs(),
			decode = decode,
			base64 = realBase64,
			roots = { { dir = "assets/packs", source = "bundled" } },
			default_id = "orange-menace",
		})
		for _, id in { "orange-menace", "void", "tuxedo" } do
			local pack = packs.select(cache, id)
			assert(pack, id)
			expect(pack.manifest.id).toBe(id)
			for _, anim in animations.CANONICAL do
				local asset = packs.asset(cache, pack, anim)
				assert(asset, `{id}/{anim}`)
				expect(string.sub(asset.sheet_url, 1, 22)).toBe("data:image/png;base64,")
				expect(#asset.durations_ms).toBeGreaterThan(0)
			end
		end
	end)
end)
