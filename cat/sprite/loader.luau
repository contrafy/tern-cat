--!strict
-- Discovers sprite packs under bundled and user roots, validates them and picks the active one.
-- Never throws: every failure becomes a human-readable problem string.

local T = require("../types")
local manifest = require("./manifest")

local MANIFEST_FILE = "pack.json"
local MANIFEST_MAX_BYTES = 64 * 1024
local MAX_PACKS_PER_ROOT = 64

export type LoadResult = {
	packs: { [string]: T.LoadedPack },
	problems: { string },
}

export type Root = { dir: string, source: T.PackSource }

local function loadPack(
	fs: T.FsAdapter,
	decodeJson: (string) -> any,
	dir: string,
	source: T.PackSource
): (T.LoadedPack?, string?)
	local okRead, text = pcall(fs.read, manifest.joinPath(dir, MANIFEST_FILE), MANIFEST_MAX_BYTES + 1)
	if not okRead then
		return nil, `{source} pack at {dir}: could not read {MANIFEST_FILE}`
	end
	if type(text) ~= "string" then
		return nil, nil
	end
	if #text > MANIFEST_MAX_BYTES then
		return nil, `{source} pack at {dir}: {MANIFEST_FILE} exceeds {MANIFEST_MAX_BYTES} bytes`
	end
	local okDecode, raw = pcall(decodeJson, text)
	if not okDecode then
		return nil, `{source} pack at {dir}: {MANIFEST_FILE} is not valid JSON`
	end
	local result = manifest.validate(raw, fs, dir)
	if not result.ok or not result.manifest then
		return nil, `{source} pack at {dir}: {table.concat(result.errors, "; ")}`
	end
	return {
		manifest = result.manifest,
		root = dir,
		source = source,
		warnings = result.warnings,
	}, nil
end

-- Pack folder names the loader considers (the folder name need not equal the pack id).
local function isPackDirName(name: any): boolean
	return type(name) == "string" and #name <= 64 and string.match(name, "^[A-Za-z0-9][A-Za-z0-9._%-]*$") ~= nil
end

local function loadAll(fs: T.FsAdapter, decodeJson: (string) -> any, roots: { Root }): LoadResult
	local packs: { [string]: T.LoadedPack } = {}
	local problems: { string } = {}

	local ordered: { Root } = {}
	for _, source in { "bundled", "user" } do
		for _, root in roots do
			if root.source == source then
				table.insert(ordered, root)
			end
		end
	end

	for _, root in ordered do
		local okList, names = pcall(fs.list, root.dir)
		if not okList then
			table.insert(problems, `{root.source} packs at {root.dir}: could not list directory`)
			continue
		end
		if type(names) ~= "table" then
			continue
		end
		local sorted: { string } = {}
		for _, name in names do
			if isPackDirName(name) then
				table.insert(sorted, name)
			end
		end
		table.sort(sorted)
		local seen = 0
		for _, name in sorted do
			if seen >= MAX_PACKS_PER_ROOT then
				table.insert(
					problems,
					`{root.source} packs at {root.dir}: more than {MAX_PACKS_PER_ROOT} entries, rest ignored`
				)
				break
			end
			local dir = manifest.joinPath(root.dir, name)
			local pack, problem = loadPack(fs, decodeJson, dir, root.source)
			if problem then
				seen += 1
				table.insert(problems, problem)
			elseif pack then
				seen += 1
				local id = pack.manifest.id
				local existing = packs[id]
				if existing then
					table.insert(
						problems,
						`{root.source} pack at {dir} ignored: id "{id}" is already provided by the {existing.source} pack at {existing.root}`
					)
				else
					packs[id] = pack
				end
			end
		end
	end

	return { packs = packs, problems = problems }
end

local function select(packs: { [string]: T.LoadedPack }, wanted: string?, defaultId: string): (T.LoadedPack?, string?)
	if wanted and wanted ~= "" and packs[wanted] then
		return packs[wanted], nil
	end
	local requested = wanted and wanted ~= "" and wanted ~= defaultId
	if packs[defaultId] then
		if requested then
			return packs[defaultId], `appearance "{wanted}" is not available; using "{defaultId}"`
		end
		return packs[defaultId], nil
	end
	local ids: { string } = {}
	for id in packs do
		table.insert(ids, id)
	end
	if #ids == 0 then
		return nil, "no valid sprite packs found"
	end
	table.sort(ids)
	local missing = if requested then `"{wanted}" and default "{defaultId}" are` else `default "{defaultId}" is`
	return packs[ids[1]], `appearance {missing} not available; using "{ids[1]}"`
end

local function assetPath(pack: T.LoadedPack, rel: string): string?
	if not manifest.isSafePath(rel) then
		return nil
	end
	return manifest.joinPath(pack.root, rel)
end

local function framePath(pack: T.LoadedPack, animation: string, index: number): string?
	local spec = pack.manifest.animations[animation]
	if not spec then
		return nil
	end
	local rel = spec.frames[index]
	if type(rel) ~= "string" then
		return nil
	end
	return assetPath(pack, rel)
end

return {
	loadAll = loadAll,
	isPackDirName = isPackDirName,
	select = select,
	assetPath = assetPath,
	framePath = framePath,
	MANIFEST_FILE = MANIFEST_FILE,
}
