--!strict
-- Window-side sprite pack access for the overlay: validates only the packs it needs (the wanted
-- and the default directory first, a full scan only when those miss) and turns each animation's
-- sheet into a cached data URL. Keeps window loads inside the 50 ms budget.

local T = require("../types")
local loader = require("../sprite/loader")
local manifest = require("../sprite/manifest")
local animations = require("../render/animations")
local overlay = require("../render/overlay")

export type Asset = {
	sheet_url: string,
	frame_w: number,
	frame_h: number,
	durations_ms: { number },
	loop: boolean,
}

export type Deps = {
	fs: T.FsAdapter,
	decode: (text: string) -> any,
	base64: (bytes: string) -> string,
	roots: { loader.Root },
	default_id: string,
}

export type Cache = {
	deps: Deps,
	packs: { [string]: T.LoadedPack },
	scanned: { [string]: boolean },
	full: boolean,
	assets: { [string]: Asset | false },
	problems: { string },
}

local function new(deps: Deps): Cache
	return { deps = deps, packs = {}, scanned = {}, full = false, assets = {}, problems = {} }
end

local function invalidate(c: Cache)
	c.packs = {}
	c.scanned = {}
	c.full = false
	c.assets = {}
	c.problems = {}
end

-- Bundled packs win over user packs that reuse their id (same rule as loader.loadAll).
local function merge(c: Cache, found: { [string]: T.LoadedPack })
	for id, pack in found do
		local existing = c.packs[id]
		if existing == nil or (existing.source == "user" and pack.source == "bundled") then
			c.packs[id] = pack
		end
	end
end

local function filteredFs(fs: T.FsAdapter, roots: { loader.Root }, names: { [string]: boolean }): T.FsAdapter
	local rootDirs: { [string]: boolean } = {}
	for _, root in roots do
		rootDirs[root.dir] = true
	end
	return {
		read = fs.read,
		exists = fs.exists,
		list = function(path: string): { string }?
			local entries = fs.list(path)
			if entries == nil or not rootDirs[path] then
				return entries
			end
			local out: { string } = {}
			for _, name in entries do
				if names[name] then
					table.insert(out, name)
				end
			end
			return out
		end,
	}
end

local function loadNamed(c: Cache, ids: { string })
	local names: { [string]: boolean } = {}
	local any = false
	for _, id in ids do
		if not c.scanned[id] then
			names[id] = true
			c.scanned[id] = true
			any = true
		end
	end
	if not any then
		return
	end
	local result = loader.loadAll(filteredFs(c.deps.fs, c.deps.roots, names), c.deps.decode, c.deps.roots)
	merge(c, result.packs)
	for _, p in result.problems do
		table.insert(c.problems, p)
	end
end

local function loadEverything(c: Cache)
	if c.full then
		return
	end
	c.full = true
	local result = loader.loadAll(c.deps.fs, c.deps.decode, c.deps.roots)
	merge(c, result.packs)
	for _, p in result.problems do
		if not table.find(c.problems, p) then
			table.insert(c.problems, p)
		end
	end
end

local function select(c: Cache, wanted: string?): (T.LoadedPack?, string?)
	local id = if wanted and wanted ~= "" then wanted else c.deps.default_id
	if c.packs[id] then
		return c.packs[id], nil
	end
	loadNamed(c, { id, c.deps.default_id })
	if c.packs[id] == nil then
		loadEverything(c)
	end
	return loader.select(c.packs, id, c.deps.default_id)
end

local function build(c: Cache, pack: T.LoadedPack, anim: T.Animation): Asset?
	local spec = pack.manifest.animations[anim]
	if spec == nil then
		return nil
	end
	local rel = spec.sheet
	local durations = spec.durations_ms
	if rel == nil then
		rel = spec.frames[1]
		durations = { spec.durations_ms[1] }
	end
	local path = if rel then loader.assetPath(pack, rel) else nil
	if path == nil then
		return nil
	end
	local ok, bytes = pcall(c.deps.fs.read, path, manifest.LIMITS.file_max_bytes)
	if not ok or type(bytes) ~= "string" or #bytes == 0 then
		return nil
	end
	local okUrl, url = pcall(overlay.dataUrl, bytes, c.deps.base64)
	if not okUrl then
		return nil
	end
	return {
		sheet_url = url,
		frame_w = pack.manifest.canvas.width,
		frame_h = pack.manifest.canvas.height,
		durations_ms = table.clone(durations),
		loop = spec.loop,
	}
end

-- Returns the overlay asset for `wanted` (after fallback resolution) and the animation used.
local function asset(c: Cache, pack: T.LoadedPack, wanted: string): (Asset?, T.Animation)
	local anim: T.Animation = animations.resolve(pack.manifest.animations, wanted)
	local key = `{pack.source}:{pack.root}:{anim}`
	local cached = c.assets[key]
	if cached == nil then
		local built = build(c, pack, anim)
		c.assets[key] = if built then built else false
		return built, anim
	end
	if cached == false then
		return nil, anim
	end
	return cached :: Asset, anim
end

return {
	new = new,
	invalidate = invalidate,
	select = select,
	asset = asset,
}
