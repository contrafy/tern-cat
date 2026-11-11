--!strict
-- The sprite pack catalog: what the host half publishes under tern.kv "packs" after validating
-- every pack folder, so windows never validate packs themselves. One entry per pack folder of the
-- bundled and user roots. An entry names its folder, never a path: a window joins the folder to
-- its own root for that source, so a tampered catalog cannot point anywhere else.

local T = require("../types")
local loader = require("./loader")
local manifest = require("./manifest")

local KEY = "packs"
local SCHEMA_VERSION = 1
-- Same bound as the loader: 64 folders per root.
local MAX_ENTRIES = 128
local PROBLEM_MAX = 200

export type Entry = {
	folder: string,
	source: T.PackSource,
	valid: boolean,
	-- From pack.json; missing for a folder whose pack.json could not be read.
	id: string?,
	name: string?,
	author: string?,
	-- Why the pack is not valid (no paths).
	problem: string?,
}

-- `complete` is false while folders remain to be validated (the host continues on its next poll).
export type Catalog = { schema_version: number, rev: number, complete: boolean, packs: { Entry } }

-- One validated pack folder: the pack, or why it is not valid; neither when it has no pack.json.
export type DirResult = { source: T.PackSource, folder: string, pack: T.LoadedPack?, problem: string? }

local function sourceRank(source: string): number
	return if source == "bundled" then 1 else 2
end

local function clip(s: string, max: number): string
	return if #s > max then string.sub(s, 1, max - 3) .. "..." else s
end

-- Catalog entries in loader order (bundled first, then folder names), and the winning pack per
-- id: like loader.loadAll, the first valid folder with an id wins and later ones are reported.
local function build(dirs: { DirResult }): ({ Entry }, { [string]: T.LoadedPack })
	local ordered = table.clone(dirs)
	table.sort(ordered, function(a, b)
		local ra, rb = sourceRank(a.source), sourceRank(b.source)
		if ra ~= rb then
			return ra < rb
		end
		return a.folder < b.folder
	end)
	local entries: { Entry } = {}
	local winners: { [string]: T.LoadedPack } = {}
	local owners: { [string]: DirResult } = {}
	for _, d in ordered do
		local pack = d.pack
		if pack then
			local m = pack.manifest
			local entry: Entry = {
				folder = d.folder,
				source = d.source,
				valid = true,
				id = m.id,
				name = m.name,
				author = m.author,
			}
			local owner = owners[m.id]
			if owner then
				entry.valid = false
				entry.problem = `id "{m.id}" is already provided by the {owner.source} pack in folder "{owner.folder}"`
			else
				owners[m.id] = d
				winners[m.id] = pack
			end
			table.insert(entries, entry)
		elseif d.problem then
			table.insert(entries, {
				folder = d.folder,
				source = d.source,
				valid = false,
				problem = clip(d.problem, PROBLEM_MAX),
			})
		end
	end
	return entries, winners
end

local function sameEntry(a: Entry, b: Entry): boolean
	return a.folder == b.folder
		and a.source == b.source
		and a.valid == b.valid
		and a.id == b.id
		and a.name == b.name
		and a.author == b.author
		and a.problem == b.problem
end

local function equal(a: { Entry }, b: { Entry }): boolean
	if #a ~= #b then
		return false
	end
	for i, entry in a do
		if not sameEntry(entry, b[i]) then
			return false
		end
	end
	return true
end

local function rootFor(source: any, roots: { loader.Root }): loader.Root?
	for _, root in roots do
		if root.source == source then
			return root
		end
	end
	return nil
end

-- The pack folder of `entry` under this side's own root for its source; nil when the folder name
-- is not one the loader would scan (no separators, no `.`/`..`) or the source is unknown.
local function dirOf(entry: Entry, roots: { loader.Root }): string?
	local root = rootFor(entry.source, roots)
	if root == nil or not loader.isPackDirName(entry.folder) then
		return nil
	end
	return manifest.joinPath(root.dir, entry.folder)
end

local function optionalText(value: any, max: number): (boolean, string?)
	if value == nil then
		return true, nil
	end
	if type(value) ~= "string" or #value > max or utf8.len(value) == nil then
		return false, nil
	end
	return true, value
end

-- A catalog read from tern.kv, keeping only well-formed valid entries a window can use; nil when
-- it is absent or not a catalog of this schema.
local function decode(raw: any, roots: { loader.Root }): Catalog?
	if type(raw) ~= "table" or raw.schema_version ~= SCHEMA_VERSION then
		return nil
	end
	local rev = raw.rev
	if type(rev) ~= "number" or rev ~= rev or rev == math.huge or rev == -math.huge then
		return nil
	end
	if type(raw.packs) ~= "table" then
		return nil
	end
	local packs: { Entry } = {}
	for i, e in raw.packs do
		if type(i) ~= "number" or i > MAX_ENTRIES then
			break
		end
		if type(e) ~= "table" or e.valid ~= true or not manifest.isPackId(e.id) then
			continue
		end
		local okName, name = optionalText(e.name, manifest.LIMITS.name_max)
		local okAuthor, author = optionalText(e.author, manifest.LIMITS.author_max)
		if not okName or name == nil or name == "" or not okAuthor then
			continue
		end
		local entry: Entry = {
			folder = if type(e.folder) == "string" then e.folder else "",
			source = e.source,
			valid = true,
			id = e.id,
			name = name,
			author = author,
		}
		if dirOf(entry, roots) == nil then
			continue
		end
		table.insert(packs, entry)
	end
	return { schema_version = SCHEMA_VERSION, rev = rev, complete = raw.complete == true, packs = packs }
end

-- The value the host writes under KEY.
local function encode(rev: number, entries: { Entry }, complete: boolean): Catalog
	return { schema_version = SCHEMA_VERSION, rev = rev, complete = complete, packs = entries }
end

return {
	KEY = KEY,
	SCHEMA_VERSION = SCHEMA_VERSION,
	MAX_ENTRIES = MAX_ENTRIES,
	build = build,
	equal = equal,
	dirOf = dirOf,
	decode = decode,
	encode = encode,
}
