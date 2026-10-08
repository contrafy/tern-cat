--!strict
local t = require("../../lib/test")
local serde = require("@lune/serde")
local support = require("./support")
local loader = require("../../../cat/sprite/loader")
local T = require("../../../cat/types")

local describe, it, expect = t.describe, t.it, t.expect

local function decodeJson(text: string): any
	return serde.decode("json", text)
end

local function packJson(id: string, name: string?): string
	return serde.encode("json", {
		schema_version = 1,
		id = id,
		name = name or id,
		license = "CC0-1.0",
		canvas = { width = 16, height = 16 },
		animations = { idle = { frames = { "idle.png" }, durations_ms = { 100 }, loop = true } },
	})
end

local function addPack(files: { [string]: string }, dir: string, id: string, name: string?)
	files[`{dir}/{id}/pack.json`] = packJson(id, name)
	files[`{dir}/{id}/idle.png`] = support.makePng()
end

local function bundledAndUser(): { [string]: string }
	local files = {}
	addPack(files, "bundled", "orange-menace", "Orange Menace")
	addPack(files, "bundled", "void")
	addPack(files, "user", "calico")
	return files
end

local ROOTS: { { dir: string, source: T.PackSource } } = {
	{ dir = "user", source = "user" },
	{ dir = "bundled", source = "bundled" },
}

local function hasProblem(problems: { string }, needle: string): boolean
	for _, p in problems do
		if string.find(p, needle, 1, true) then
			return true
		end
	end
	return false
end

describe("sprite/loader.loadAll", function()
	it("discovers bundled and user packs keyed by manifest id", function()
		local adapter = support.memoryFs(bundledAndUser())
		local result = loader.loadAll(adapter, decodeJson, ROOTS)
		expect(result.problems).toEqual({})
		local pack = result.packs["orange-menace"]
		assert(pack, "orange-menace should load")
		expect(pack.source).toBe("bundled")
		expect(pack.root).toBe("bundled/orange-menace")
		expect(pack.manifest.name).toBe("Orange Menace")
		local calico = result.packs.calico
		assert(calico, "calico should load")
		expect(calico.source).toBe("user")
	end)

	it("lets a bundled pack win over a user pack with the same id, and says so", function()
		local files = bundledAndUser()
		addPack(files, "user", "void", "Impostor")
		local result = loader.loadAll(support.memoryFs(files), decodeJson, ROOTS)
		local void = result.packs.void
		assert(void, "void should load")
		expect(void.source).toBe("bundled")
		expect(void.manifest.name).toBe("void")
		expect(#result.problems).toBe(1)
		expect(result.problems[1]).toContain("user/void")
		expect(result.problems[1]).toContain("already provided")
	end)

	it("reports invalid JSON without failing the other packs", function()
		local files = bundledAndUser()
		files["user/broken/pack.json"] = "{ not json"
		local result = loader.loadAll(support.memoryFs(files), decodeJson, ROOTS)
		expect(result.packs.calico).notToBeNil()
		expect(hasProblem(result.problems, "user/broken")).toBe(true)
		expect(hasProblem(result.problems, "JSON")).toBe(true)
	end)

	it("reports validation errors with the pack location", function()
		local files = bundledAndUser()
		addPack(files, "user", "giant")
		files["user/giant/pack.json"] = string.gsub(files["user/giant/pack.json"], "16", "4096")
		local result = loader.loadAll(support.memoryFs(files), decodeJson, ROOTS)
		expect(result.packs.giant).toBeNil()
		expect(hasProblem(result.problems, "user/giant")).toBe(true)
		expect(hasProblem(result.problems, "canvas")).toBe(true)
	end)

	it("treats a missing user directory as having no user packs", function()
		local files = {}
		addPack(files, "bundled", "orange-menace")
		local result = loader.loadAll(support.memoryFs(files), decodeJson, ROOTS)
		expect(result.problems).toEqual({})
		expect(result.packs["orange-menace"]).notToBeNil()
	end)

	it("skips entries without pack.json and directory names that are not safe", function()
		local files = bundledAndUser()
		files["user/README.md"] = "hello"
		files["user/.hidden/pack.json"] = packJson("hidden")
		local result = loader.loadAll(support.memoryFs(files), decodeJson, ROOTS)
		expect(result.problems).toEqual({})
		expect(result.packs.hidden).toBeNil()
	end)

	it("never throws when the adapter or decoder throws", function()
		local boom: T.FsAdapter = {
			read = function(_p, _m)
				error("io")
			end,
			list = function(_p)
				error("io")
			end,
			exists = function(_p)
				error("io")
			end,
		}
		local ok, result = pcall(loader.loadAll, boom, decodeJson, ROOTS)
		expect(ok).toBe(true)
		expect(next(result.packs)).toBeNil()

		local ok2, result2 = pcall(loader.loadAll, support.memoryFs(bundledAndUser()), function(_s: string): any
			error("decoder exploded")
		end, ROOTS)
		expect(ok2).toBe(true)
		expect(next(result2.packs)).toBeNil()
		expect(#result2.problems).toBe(3)
	end)

	it("loads the committed good fixtures and rejects every bad one", function()
		local result =
			loader.loadAll(support.luneFs(), decodeJson, { { dir = "tests/fixtures/packs", source = "user" } })
		expect(result.packs["good-minimal"]).notToBeNil()
		expect(result.packs["good-full"]).notToBeNil()
		local count = 0
		for _ in result.packs do
			count += 1
		end
		expect(count).toBe(2)
		for _, bad in { "bad-traversal", "bad-absolute", "bad-json", "bad-not-png", "bad-missing-idle" } do
			expect(hasProblem(result.problems, bad)).toBe(true)
		end
		local full = result.packs["good-full"]
		assert(full, "good-full should load")
		expect(full.warnings[1]).toContain("moonwalk")
	end)
end)

describe("sprite/loader.select", function()
	local function packs(): { [string]: T.LoadedPack }
		return loader.loadAll(support.memoryFs(bundledAndUser()), decodeJson, ROOTS).packs
	end

	it("returns the wanted pack without a note", function()
		local pack, note = loader.select(packs(), "calico", "orange-menace")
		assert(pack, "expected a pack")
		expect(pack.manifest.id).toBe("calico")
		expect(note).toBeNil()
	end)

	it("falls back to the default pack and explains why", function()
		local pack, note = loader.select(packs(), "removed-pack", "orange-menace")
		assert(pack, "expected a pack")
		expect(pack.manifest.id).toBe("orange-menace")
		expect(note).toContain("removed-pack")
	end)

	it("uses the default silently when nothing was requested", function()
		local pack, note = loader.select(packs(), nil, "orange-menace")
		assert(pack, "expected a pack")
		expect(pack.manifest.id).toBe("orange-menace")
		expect(note).toBeNil()
	end)

	it("falls back to any valid pack when even the default is missing", function()
		local all = packs()
		all["orange-menace"] = nil
		local pack, note = loader.select(all, "x", "orange-menace")
		assert(pack, "expected a pack")
		expect(pack.manifest.id).toBe("calico")
		expect(note).notToBeNil()
	end)

	it("returns nil with a note when there are no packs at all", function()
		local pack, note = loader.select({}, "x", "orange-menace")
		expect(pack).toBeNil()
		expect(note).toContain("no valid sprite packs")
	end)
end)

describe("sprite/loader paths", function()
	local function pack(): T.LoadedPack
		local result = loader.loadAll(support.memoryFs(bundledAndUser()), decodeJson, ROOTS)
		return assert(result.packs["orange-menace"], "orange-menace should load")
	end

	it("joins frame paths onto the pack root", function()
		expect(loader.framePath(pack(), "idle", 1)).toBe("bundled/orange-menace/idle.png")
	end)

	it("returns nil for unknown animations and out-of-range frames", function()
		expect(loader.framePath(pack(), "walk", 1)).toBeNil()
		expect(loader.framePath(pack(), "idle", 2)).toBeNil()
		expect(loader.framePath(pack(), "idle", 0)).toBeNil()
	end)

	it("refuses unsafe relative paths", function()
		expect(loader.assetPath(pack(), "idle.png")).toBe("bundled/orange-menace/idle.png")
		expect(loader.assetPath(pack(), "../../secret.png")).toBeNil()
		expect(loader.assetPath(pack(), "/etc/x.png")).toBeNil()
	end)
end)

-- Removing a pack deletes a directory recursively, so the folder must be provably one of the
-- user's own installed packs: a direct child of the user packs root, never a bundled pack.
describe("sprite/loader.removableDir", function()
	local USER_ROOT = "/data/packs"

	local function userPack(root: string): T.LoadedPack
		return {
			manifest = { id = "calico" } :: any,
			root = root,
			source = "user",
			warnings = {},
		}
	end

	it("returns the folder of a user pack directly inside the user packs root", function()
		expect(loader.removableDir(userPack("/data/packs/calico"), USER_ROOT)).toBe("/data/packs/calico")
		expect(loader.removableDir(userPack("/data/packs/Calico.v2"), "/data/packs/")).toBe("/data/packs/Calico.v2")
		expect(loader.removableDir(userPack("/data//packs/calico/"), USER_ROOT)).toBe("/data/packs/calico")
	end)

	it("refuses bundled packs even when their folder is inside the user root", function()
		local pack = userPack("/data/packs/calico")
		pack.source = "bundled"
		local dir, err = loader.removableDir(pack, USER_ROOT)
		expect(dir).toBeNil()
		expect(err).toContain("bundled")
	end)

	it("refuses folders outside or not directly inside the user packs root", function()
		for _, root in
			{
				"/data/packs",
				"/data/packs/",
				"/data",
				"/data/other/calico",
				"/data/packs-old/calico",
				"/data/packs/a/calico",
				"/data/packs/../config.json",
				"/data/packs/./calico",
				"/data/packs/..",
				"/data/packs/.hidden",
				"/data/packs/cal:ico",
				"/data/packs/cal\\ico",
				"/etc/calico",
				"calico",
				"",
			}
		do
			local dir, err = loader.removableDir(userPack(root), USER_ROOT)
			expect(dir).toBeNil()
			expect(err).notToBeNil()
		end
	end)

	it("refuses everything when the user packs root itself is not a plain path", function()
		for _, root in { "", "/", "/data/../packs", "/data/./packs" } do
			expect(loader.removableDir(userPack("/data/packs/calico"), root)).toBeNil()
		end
	end)
end)
