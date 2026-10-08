--!strict
local t = require("../../lib/test")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local support = require("./support")
local manifest = require("../../../cat/sprite/manifest")
local T = require("../../../cat/types")

local describe, it, expect = t.describe, t.it, t.expect

local ROOT = "packs/p"
local MIB = 1024 * 1024

local function animation(frames: { string }, overrides: { [string]: any }?): { [string]: any }
	local durations = {}
	for i = 1, #frames do
		durations[i] = 100
	end
	local spec: { [string]: any } = { frames = frames, durations_ms = durations, loop = true }
	for k, v in overrides or {} do
		spec[k] = v
	end
	return spec
end

local function validManifest(): { [string]: any }
	return {
		schema_version = 1,
		id = "test-pack",
		name = "Test Pack",
		license = "CC0-1.0",
		canvas = { width = 16, height = 16 },
		animations = {
			idle = animation({ "idle_0.png", "idle_1.png" }),
		},
	}
end

local function validFiles(): { [string]: string }
	return {
		[ROOT .. "/idle_0.png"] = support.makePng(),
		[ROOT .. "/idle_1.png"] = support.makePng(),
	}
end

local function run(raw: any, files: { [string]: string }?): (T.ValidationResult, { string })
	local adapter, log = support.memoryFs(files or validFiles())
	return manifest.validate(raw, adapter, ROOT), log
end

local function hasError(result: T.ValidationResult, needle: string): boolean
	for _, e in result.errors do
		if string.find(e, needle, 1, true) then
			return true
		end
	end
	return false
end

local function expectError(result: T.ValidationResult, needle: string)
	expect(result.ok).toBe(false)
	expect(result.manifest).toBeNil()
	if not hasError(result, needle) then
		error(`expected an error containing {needle}, got: {table.concat(result.errors, " | ")}`, 2)
	end
end

local function fixture(name: string): T.ValidationResult
	local dir = "tests/fixtures/packs/" .. name
	local raw = serde.decode("json", fs.readFile(dir .. "/pack.json"))
	return manifest.validate(raw, support.luneFs(), dir)
end

describe("sprite/manifest.validate", function()
	describe("a well-formed pack", function()
		it("is accepted and returns a normalized copy", function()
			local result = run(validManifest())
			expect(result.errors).toEqual({})
			expect(result.ok).toBe(true)
			assert(result.manifest, "expected a manifest")
			expect(result.manifest.id).toBe("test-pack")
			expect(result.manifest.canvas).toEqual({ width = 16, height = 16 })
			expect(result.manifest.animations.idle.frames).toEqual({ "idle_0.png", "idle_1.png" })
		end)

		it("drops unknown top-level and animation fields so they cannot leak into renderers", function()
			local raw = validManifest()
			raw.homepage = "https://example.invalid"
			raw.animations.idle.script = "evil()"
			local result = run(raw)
			assert(result.manifest, "expected a manifest")
			expect((result.manifest :: any).homepage).toBeNil()
			expect((result.manifest.animations.idle :: any).script).toBeNil()
		end)

		it("does not alias the caller's tables", function()
			local raw = validManifest()
			local result = run(raw)
			assert(result.manifest, "expected a manifest")
			table.insert(raw.animations.idle.frames, "later.png")
			expect(#result.manifest.animations.idle.frames).toBe(2)
		end)

		it("keeps optional author, description, anchor and hitbox", function()
			local raw = validManifest()
			raw.author = "someone"
			raw.description = "a cat"
			raw.animations.idle.anchor = { 8, 16 }
			raw.animations.idle.hitbox = { 0, 0, 16, 16 }
			local result = run(raw)
			assert(result.manifest, "expected a manifest")
			expect(result.manifest.author).toBe("someone")
			expect(result.manifest.animations.idle.anchor).toEqual({ 8, 16 })
			expect(result.manifest.animations.idle.hitbox).toEqual({ 0, 0, 16, 16 })
		end)

		it("reads the same frame file only once even when reused", function()
			local raw = validManifest()
			raw.animations.idle = animation({ "idle_0.png", "idle_0.png", "idle_0.png" })
			local _, log = run(raw)
			local reads = 0
			for _, p in log do
				if p == ROOT .. "/idle_0.png" then
					reads += 1
				end
			end
			expect(reads).toBeLessThanOrEqual(2)
		end)
	end)

	describe("top-level limits", function()
		it("rejects a non-object manifest", function()
			expectError(run("nope"), "manifest")
			expectError(run(nil), "manifest")
		end)

		it("requires schema_version 1", function()
			local raw = validManifest()
			raw.schema_version = 2
			expectError(run(raw), "schema_version")
		end)

		it("restricts ids to lowercase slugs of at most 32 characters", function()
			for _, bad in { "", "Upper", "1starts-digit", "has_underscore", "a" .. string.rep("b", 32), "x/../y" } do
				local raw = validManifest()
				raw.id = bad
				expectError(run(raw), "id")
			end
			local raw = validManifest()
			raw.id = "a" .. string.rep("b", 31)
			expect(run(raw).ok).toBe(true)
		end)

		it("requires a name of 1..64 characters", function()
			for _, bad: any in { "", string.rep("n", 65), 42 } do
				local raw = validManifest()
				raw.name = bad
				expectError(run(raw), "name")
			end
		end)

		it("requires a license of at most 64 characters", function()
			local raw = validManifest()
			raw.license = nil
			expectError(run(raw), "license")
			raw.license = string.rep("l", 65)
			expectError(run(raw), "license")
		end)

		it("rejects a non-string author", function()
			local raw = validManifest()
			raw.author = { "x" }
			expectError(run(raw), "author")
		end)

		it("bounds the canvas to integers in 8..256", function()
			for _, bad: any in { 7, 257, 16.5, "16", 4096 } do
				local raw = validManifest()
				raw.canvas.width = bad
				expectError(run(raw), "canvas.width")
			end
			local raw = validManifest()
			raw.canvas = nil
			expectError(run(raw), "canvas")
		end)

		it("rejects more than 32 animations", function()
			local raw = validManifest()
			for i = 1, 32 do
				raw.animations["custom" .. i] = animation({ "idle_0.png" })
			end
			expectError(run(raw), "at most 32")
		end)

		it("requires an object of animations", function()
			local raw = validManifest()
			raw.animations = { animation({ "idle_0.png" }) }
			expectError(run(raw), "animations")
		end)

		it("requires idle because every fallback chain ends there", function()
			local raw = validManifest()
			raw.animations = { walk = animation({ "idle_0.png" }) }
			expectError(run(raw), '"idle"')
		end)

		it("warns about and drops unknown animation names without validating them", function()
			local raw = validManifest()
			raw.animations.moonwalk = { frames = "garbage" }
			local result = run(raw)
			expect(result.ok).toBe(true)
			expect(#result.warnings).toBe(1)
			expect(result.warnings[1]).toContain("moonwalk")
			assert(result.manifest, "expected a manifest")
			expect(result.manifest.animations.moonwalk).toBeNil()
		end)
	end)

	describe("animation limits", function()
		it("requires 1..64 frames", function()
			local raw = validManifest()
			raw.animations.idle = animation({})
			expectError(run(raw), "animations.idle.frames")
			local many = {}
			for i = 1, 65 do
				many[i] = "idle_0.png"
			end
			raw.animations.idle = animation(many)
			expectError(run(raw), "animations.idle.frames")
		end)

		it("requires frames to be a list of strings", function()
			local raw = validManifest()
			raw.animations.idle.frames = { a = "idle_0.png" }
			expectError(run(raw), "animations.idle.frames")
			raw.animations.idle.frames = { 1 }
			expectError(run(raw), "animations.idle.frames[1]")
		end)

		it("requires one duration per frame", function()
			local raw = validManifest()
			raw.animations.idle.durations_ms = { 100 }
			expectError(run(raw), "animations.idle.durations_ms")
		end)

		it("bounds each duration to integers in 40..10000 ms", function()
			for _, bad: any in { 39, 10001, 100.5, "100" } do
				local raw = validManifest()
				raw.animations.idle.durations_ms = { 100, bad }
				expectError(run(raw), "animations.idle.durations_ms[2]")
			end
			local raw = validManifest()
			raw.animations.idle.durations_ms = { 40, 10000 }
			expect(run(raw).ok).toBe(true)
		end)

		it("requires a boolean loop flag", function()
			local raw = validManifest()
			raw.animations.idle.loop = "yes"
			expectError(run(raw), "animations.idle.loop")
		end)

		it("keeps the anchor inside the canvas", function()
			for _, bad: any in { { 17, 0 }, { -1, 0 }, { 1 }, { 1.5, 2 }, "0,0" } do
				local raw = validManifest()
				raw.animations.idle.anchor = bad
				expectError(run(raw), "animations.idle.anchor")
			end
		end)

		it("keeps the hitbox inside the canvas", function()
			for _, bad: any in { { 0, 0, 17, 16 }, { 8, 8, 9, 1 }, { 0, 0, 0, 4 }, { 0, 0, 4 } } do
				local raw = validManifest()
				raw.animations.idle.hitbox = bad
				expectError(run(raw), "animations.idle.hitbox")
			end
		end)
	end)

	describe("path safety", function()
		local unsafe = {
			"../x.png",
			"a/../b.png",
			"./a.png",
			"/abs.png",
			"a\\b.png",
			"http://evil.invalid/x.png",
			"data:image/png;base64,AAAA",
			"file:///etc/passwd.png",
			"C:/x.png",
			"a b.png",
			"a//b.png",
			"a/",
			"x.gif",
			"noext",
			"",
			"\0.png",
			string.rep("a", 197) .. ".png",
		}

		for _, path in unsafe do
			it(`rejects {string.format("%q", path)} before touching the filesystem`, function()
				local raw = validManifest()
				raw.animations.idle.frames = { "idle_0.png", path }
				local result, log = run(raw)
				expectError(result, "animations.idle.frames[2]")
				expect(#log).toBe(0)
			end)
		end

		it("applies the same rules to apng and sheet paths", function()
			local raw = validManifest()
			raw.animations.idle.apng = "../idle.apng"
			raw.animations.idle.sheet = "/sheet.png"
			local result, log = run(raw)
			expectError(result, "animations.idle.apng")
			expectError(result, "animations.idle.sheet")
			expect(#log).toBe(0)
		end)

		it("accepts nested relative paths and the .apng extension", function()
			local files = validFiles()
			files[ROOT .. "/frames/a-1_b.png"] = support.makePng()
			local raw = validManifest()
			raw.animations.idle.frames = { "idle_0.png", "frames/a-1_b.png" }
			expect(run(raw, files).ok).toBe(true)
			expect(manifest.isSafePath("anim/idle.apng")).toBe(true)
		end)

		it("rejects more than 512 referenced files without reading any", function()
			local raw = validManifest()
			local names = { "idle", "walk", "sit", "sleep", "wake", "stretch", "groom", "blink", "look" }
			for a, name in names do
				local frames = {}
				for i = 1, 64 do
					frames[i] = `{name}_{a}_{i}.png`
				end
				raw.animations[name] = animation(frames)
			end
			local result, log = run(raw)
			expectError(result, "512")
			expect(#log).toBe(0)
		end)
	end)

	describe("file checks", function()
		it("reports missing files", function()
			local files = validFiles()
			files[ROOT .. "/idle_1.png"] = nil
			expectError(run(validManifest(), files), 'animations.idle.frames[2] "idle_1.png": file not found')
		end)

		it("rejects files that are not PNG", function()
			local files = validFiles()
			files[ROOT .. "/idle_1.png"] = "GIF89a"
			expectError(run(validManifest(), files), "not a PNG")
		end)

		it("requires every frame to match the canvas", function()
			local files = validFiles()
			files[ROOT .. "/idle_1.png"] = support.makePng({ width = 17 })
			expectError(run(validManifest(), files), "17x16")
		end)

		it("never asks the adapter for more than 1 MiB + 1 byte per file", function()
			local caps = {}
			local adapter, _ = support.memoryFs(validFiles())
			local wrapped: T.FsAdapter = {
				read = function(path, max_bytes)
					table.insert(caps, max_bytes or math.huge)
					return adapter.read(path, max_bytes)
				end,
				list = adapter.list,
				exists = adapter.exists,
			}
			manifest.validate(validManifest(), wrapped, ROOT)
			expect(#caps).toBeGreaterThan(0)
			for _, cap in caps do
				expect(cap).toBeLessThanOrEqual(MIB + 1)
			end
		end)

		it("rejects an oversized file even when the adapter ignores the read cap", function()
			local adapter, _ = support.memoryFs(validFiles())
			local huge = support.makePng() .. string.rep("\0", 20 * MIB)
			local greedy: T.FsAdapter = {
				read = function(path, _max)
					if path == ROOT .. "/idle_1.png" then
						return huge
					end
					return adapter.read(path)
				end,
				list = adapter.list,
				exists = adapter.exists,
			}
			local ok, result = pcall(manifest.validate, validManifest(), greedy, ROOT)
			expect(ok).toBe(true)
			expectError(result, "exceeds 1048576 bytes")
		end)

		it("caps the pack total at 16 MiB", function()
			local raw = validManifest()
			local files = {}
			local frames = {}
			local padded = support.makePng()
			padded ..= string.rep("\0", MIB - #padded)
			for i = 1, 17 do
				frames[i] = `f{i}.png`
				files[ROOT .. `/f{i}.png`] = padded
			end
			raw.animations.idle = animation(frames)
			expectError(run(raw, files), "16777216")
		end)

		it("checks the apng frame count against the frame list", function()
			local files = validFiles()
			files[ROOT .. "/idle.apng"] = support.makePng({ frames = 3 })
			local raw = validManifest()
			raw.animations.idle.apng = "idle.apng"
			expectError(run(raw, files), 'animations.idle.apng "idle.apng": has 3 frames but the animation has 2')
		end)

		it("rejects a plain PNG where an apng is declared", function()
			local files = validFiles()
			files[ROOT .. "/idle.apng"] = support.makePng()
			local raw = validManifest()
			raw.animations.idle.apng = "idle.apng"
			expectError(run(raw, files), "not an animated PNG")
		end)

		it("checks the sheet is a horizontal strip of all frames", function()
			local files = validFiles()
			files[ROOT .. "/sheet.png"] = support.makePng({ width = 16 })
			local raw = validManifest()
			raw.animations.idle.sheet = "sheet.png"
			expectError(run(raw, files), "animations.idle.sheet")
			files[ROOT .. "/sheet.png"] = support.makePng({ width = 32 })
			expect(run(raw, files).ok).toBe(true)
		end)

		it("turns adapter exceptions into errors instead of crashing", function()
			local boom: T.FsAdapter = {
				read = function(_p, _m)
					error("disk on fire")
				end,
				list = function(_p)
					error("disk on fire")
				end,
				exists = function(_p)
					error("disk on fire")
				end,
			}
			local ok, result = pcall(manifest.validate, validManifest(), boom, ROOT)
			expect(ok).toBe(true)
			expect(result.ok).toBe(false)
		end)
	end)

	describe("committed fixtures", function()
		it("accepts good-minimal with its apng and sheet", function()
			local result = fixture("good-minimal")
			expect(result.errors).toEqual({})
			expect(result.ok).toBe(true)
		end)

		it("accepts good-full, warning about its unknown animation", function()
			local result = fixture("good-full")
			expect(result.errors).toEqual({})
			expect(result.warnings).toEqual({ "animations.moonwalk: unknown animation name, ignored" })
			assert(result.manifest, "expected a manifest")
			expect(result.manifest.animations.walk.durations_ms).toEqual({ 100, 250, 100 })
		end)

		local cases = {
			{ "bad-traversal", "animations.idle.frames[1]" },
			{ "bad-absolute", "animations.idle.frames[1]" },
			{ "bad-giant-canvas", "canvas.width" },
			{ "bad-wrong-dims", "17x16" },
			{ "bad-not-png", "not a PNG" },
			{ "bad-missing-idle", '"idle"' },
			{ "bad-too-many-frames", "animations.idle.frames" },
			{ "bad-apng-frames", "has 3 frames" },
			{ "bad-sheet-dims", "animations.idle.sheet" },
		}
		for _, case in cases do
			it(`rejects {case[1]}`, function()
				local ok, result = pcall(fixture, case[1])
				expect(ok).toBe(true)
				expectError(result, case[2])
			end)
		end
	end)
end)
