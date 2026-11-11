--!strict
-- Window-side sprite pack access for the overlay: picks the pack to show and turns each
-- animation's sheet into a cached data URL.
--
-- With the host's pack catalog (tern.kv "packs", see cat/sprite/catalog.luau) the window never
-- validates packs: it reads only the selected pack's pack.json from the catalog folder under its
-- own root, checks fields and paths but not the images, and lists the catalog's valid packs.
-- Without a catalog (before the host wrote one) it validates only the packs it needs (the wanted
-- and the default directory first); when those miss, the full scan runs one pack directory per
-- `step` call (one per timer tick) so a window timer callback never validates every pack at once:
-- a tripped 50 ms budget pauses every timer of that window (Tern 0.9.6 and later; earlier versions
-- disabled them until reload).

local T = require("../types")
local loader = require("../sprite/loader")
local manifest = require("../sprite/manifest")
local catalogMod = require("../sprite/catalog")
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

-- One pack directory still to validate in the full scan.
type Pending = { root: loader.Root, name: string }

-- A pack the Cat menu can offer.
export type Info = { id: string, name: string, author: string?, source: T.PackSource }

export type Cache = {
	deps: Deps,
	packs: { [string]: T.LoadedPack },
	scanned: { [string]: boolean },
	-- Full scan queue; nil when no scan was started since the last invalidate.
	queue: { Pending }?,
	full: boolean,
	assets: { [string]: Asset | false },
	problems: { string },
	-- The host's catalog (decoded); nil until the host has written one.
	catalog: catalogMod.Catalog?,
}

-- Same per-root bound as the loader.
local MAX_PACKS_PER_ROOT = 64

local function new(deps: Deps): Cache
	return {
		deps = deps,
		packs = {},
		scanned = {},
		queue = nil,
		full = false,
		assets = {},
		problems = {},
		catalog = nil,
	}
end

-- Forgets every pack and sheet (not the host's catalog).
local function invalidate(c: Cache)
	c.packs = {}
	c.scanned = {}
	c.queue = nil
	c.full = false
	c.assets = {}
	c.problems = {}
end

-- Adopts the host's catalog (nil: none yet). A window-side full scan in progress stops.
local function setCatalog(c: Cache, catalog: catalogMod.Catalog?)
	c.catalog = catalog
	if catalog then
		c.queue = nil
		c.full = false
	end
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

-- Lists the roots (cheap) and queues every directory the named loads did not cover.
local function startScan(c: Cache)
	local queue: { Pending } = {}
	for _, root in c.deps.roots do
		local entries = c.deps.fs.list(root.dir)
		if entries == nil then
			continue
		end
		local names = table.clone(entries)
		table.sort(names)
		local n = 0
		for _, name in names do
			if c.scanned[name] then
				continue
			end
			if n >= MAX_PACKS_PER_ROOT then
				local problem =
					`{root.source} packs at {root.dir}: more than {MAX_PACKS_PER_ROOT} entries, rest ignored`
				if not table.find(c.problems, problem) then
					table.insert(c.problems, problem)
				end
				break
			end
			n += 1
			table.insert(queue, { root = root, name = name })
		end
	end
	c.queue = queue
	c.full = #queue == 0
end

local function scanning(c: Cache): boolean
	return c.queue ~= nil and not c.full
end

-- Validates at most one queued pack directory. Returns true when the scan is complete.
local function step(c: Cache): boolean
	local queue = c.queue
	if queue == nil or c.full then
		return c.full
	end
	local item = table.remove(queue, 1)
	if item then
		c.scanned[item.name] = true
		local roots = { item.root }
		local result = loader.loadAll(filteredFs(c.deps.fs, roots, { [item.name] = true }), c.deps.decode, roots)
		merge(c, result.packs)
		for _, p in result.problems do
			if not table.find(c.problems, p) then
				table.insert(c.problems, p)
			end
		end
	end
	c.full = #queue == 0
	return c.full
end

-- Queues for `step` every pack folder not validated yet, including folders added since an earlier
-- scan finished (lists the roots only). True while some remain. Never scans with a catalog.
local function refresh(c: Cache): boolean
	if c.catalog then
		return false
	end
	if not scanning(c) then
		startScan(c)
	end
	return scanning(c)
end

-- Packs not known yet: the host's catalog is incomplete, or the window-side scan is running.
local function pending(c: Cache): boolean
	local catalog = c.catalog
	if catalog then
		return not catalog.complete
	end
	return scanning(c)
end

-- The packs the Cat menu offers: the catalog's valid packs, else every validated pack whose
-- pack.json is still there.
local function available(c: Cache): { Info }
	local out: { Info } = {}
	local catalog = c.catalog
	if catalog then
		for _, e in catalog.packs do
			table.insert(out, { id = e.id :: string, name = e.name :: string, author = e.author, source = e.source })
		end
		return out
	end
	for _, pack in c.packs do
		if c.deps.fs.exists(manifest.joinPath(pack.root, loader.MANIFEST_FILE)) then
			local m = pack.manifest
			table.insert(out, { id = m.id, name = m.name, author = m.author, source = pack.source })
		end
	end
	return out
end

-- The catalog entry's pack: cached, or read from pack.json without the image checks. Nil when the
-- folder is not a plain child of its root, its pack.json is gone or names another id.
local function catalogPack(c: Cache, entry: catalogMod.Entry): T.LoadedPack?
	local id = entry.id :: string
	local dir = catalogMod.dirOf(entry, c.deps.roots)
	if dir == nil then
		return nil
	end
	local fs = c.deps.fs
	local cached = c.packs[id]
	if cached and cached.root == dir then
		if fs.exists(manifest.joinPath(dir, loader.MANIFEST_FILE)) then
			return cached
		end
		c.packs[id] = nil
		return nil
	end
	for _, root in c.deps.roots do
		if root.source == entry.source then
			local pack = loader.loadDir(fs, c.deps.decode, root, entry.folder, { files = false })
			if pack and pack.manifest.id == id then
				c.packs[id] = pack
				return pack
			end
		end
	end
	return nil
end

-- Like loader.select over the catalog's valid packs; nil when none of them loads.
local function selectFromCatalog(c: Cache, catalog: catalogMod.Catalog, id: string): (T.LoadedPack?, string?)
	local function first(want: string): T.LoadedPack?
		for _, e in catalog.packs do
			if e.id == want then
				return catalogPack(c, e)
			end
		end
		return nil
	end
	local pack = first(id)
	if pack then
		return pack, nil
	end
	local default = c.deps.default_id
	local requested = id ~= default
	-- An incomplete catalog may list the pack later: no warning yet.
	local warn = catalog.complete
	local fallback = if requested then first(default) else nil
	if fallback then
		return fallback, if warn then `appearance "{id}" is not available; using "{default}"` else nil
	end
	local ids: { string } = {}
	for _, e in catalog.packs do
		table.insert(ids, e.id :: string)
	end
	table.sort(ids)
	for _, other in ids do
		local p = first(other)
		if p then
			local missing = if requested then `"{id}" and default "{default}" are` else `default "{default}" is`
			return p, if warn then `appearance {missing} not available; using "{other}"` else nil
		end
	end
	return nil, nil
end

-- Never runs the full scan itself: when the wanted pack is not in its own directory, it starts the
-- scan and returns the default pack (without a warning) until `step` has finished it. With a
-- catalog it uses the catalog, unless none of its packs loads (stale or tampered catalog).
local function select(c: Cache, wanted: string?): (T.LoadedPack?, string?)
	local id = if wanted and wanted ~= "" then wanted else c.deps.default_id
	local catalog = c.catalog
	if catalog then
		local pack, warning = selectFromCatalog(c, catalog, id)
		if pack then
			return pack, warning
		end
	end
	local cached = c.packs[id]
	if cached then
		if c.deps.fs.exists(manifest.joinPath(cached.root, loader.MANIFEST_FILE)) then
			return cached, nil
		end
		-- Removed since it was validated (Remove in the block, or deleted by hand): forget every
		-- pack and sheet so it is never shown again, then select as on a fresh load.
		invalidate(c)
	end
	loadNamed(c, { id, c.deps.default_id })
	if c.packs[id] == nil and c.queue == nil then
		startScan(c)
	end
	local pack, warning = loader.select(c.packs, id, c.deps.default_id)
	if scanning(c) then
		return pack, nil
	end
	return pack, warning
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
	setCatalog = setCatalog,
	select = select,
	scanning = scanning,
	step = step,
	refresh = refresh,
	pending = pending,
	available = available,
	asset = asset,
}
