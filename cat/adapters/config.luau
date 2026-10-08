--!strict
-- config.json reading (both halves) and writing (host only). The user's decoded table is the
-- source of truth for writes: changes are applied with util.setPath so explicit keys survive.

local T = require("../types")
local util = require("../core/util")
local schema = require("../config/schema")
local fsMod = require("./fs")
local jsonMod = require("./json")

local MAX_BYTES = 256 * 1024

local UNREADABLE_ERROR =
	"config.json exists but could not be read (a symlink, over 256 KiB, or a read error); it is left untouched and settings changes are not saved"

-- Change value that deletes the key (reset to default).
local REMOVE = table.freeze({ remove = true })

export type Loaded = {
	-- Raw file text; nil when the file is missing or unreadable.
	text: string?,
	-- Decoded user table ({} when missing or unusable).
	raw: { [string]: any },
	config: T.Config,
	warnings: { string },
	-- Set when the file exists but cannot be used (shown as a recovery note).
	error: string?,
	-- The file exists but the bounded read failed (symlink, oversize, I/O error). Writers must
	-- never replace it; readers show `error` instead of silently using defaults.
	unreadable: boolean?,
}

local function parse(text: string?, json: jsonMod.Json): Loaded
	if text == nil then
		local config, warnings = schema.resolve(nil)
		return { text = nil, raw = {}, config = config, warnings = warnings, error = nil }
	end
	local decoded, err = json.decode(text)
	if err then
		local config, warnings = schema.resolve(nil)
		return {
			text = text,
			raw = {},
			config = config,
			warnings = warnings,
			error = "config.json is not valid JSON; using defaults",
		}
	end
	local config, warnings = schema.resolve(decoded)
	if not util.isDict(decoded) then
		return {
			text = text,
			raw = {},
			config = config,
			warnings = warnings,
			error = "config.json is not a JSON object; using defaults",
		}
	end
	return { text = text, raw = decoded, config = config, warnings = warnings, error = nil }
end

-- Reads and resolves config.json. A file that exists but cannot be read is reported as
-- `unreadable` (with `error`) rather than as missing.
local function read(fs: fsMod.Fs | T.FsAdapter, json: jsonMod.Json, path: string): Loaded
	local text = fs.read(path, MAX_BYTES)
	local loaded = parse(text, json)
	if text == nil and fs.exists(path) then
		loaded.unreadable = true
		loaded.error = UNREADABLE_ERROR
	end
	return loaded
end

-- Keys in order of first appearance in `template` (the example config), for stable output.
local function keyOrder(template: string): { [string]: number }
	local order: { [string]: number } = {}
	local n = 0
	for key in string.gmatch(template, '"([%w_]+)"%s*:') do
		if order[key] == nil then
			n += 1
			order[key] = n
		end
	end
	return order
end

local function sortKeys(tbl: { [any]: any }, order: { [string]: number }): { string }
	local keys = util.sortedKeys(tbl)
	table.sort(keys, function(a: string, b: string): boolean
		local ra, rb = order[a], order[b]
		if ra and rb then
			return ra < rb
		elseif ra or rb then
			return ra ~= nil
		end
		return a < b
	end)
	return keys
end

-- Pretty JSON with two-space indentation; scalars are escaped by `json.encode`.
local function pretty(value: any, json: jsonMod.Json, order: { [string]: number }, indent: string?): string
	local pad = indent or ""
	local inner = pad .. "  "
	if type(value) == "table" then
		if next(value) == nil then
			return "{}"
		end
		local parts: { string } = {}
		if util.isArray(value) then
			for _, v in value do
				table.insert(parts, inner .. pretty(v, json, order, inner))
			end
			return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
		end
		for _, k in sortKeys(value, order) do
			local v = (value :: any)[k]
			if v == nil then
				v = (value :: any)[tonumber(k)]
			end
			table.insert(parts, inner .. (json.encode(k) or '""') .. ": " .. pretty(v, json, order, inner))
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
	end
	return json.encode(value) or "null"
end

local function encode(raw: { [string]: any }, json: jsonMod.Json, template: string?): string
	return pretty(raw, json, keyOrder(template or "")) .. "\n"
end

-- Returns a copy of `raw` with every dotted-path change applied (sorted for determinism);
-- a REMOVE value deletes the key.
local function applyChanges(raw: { [string]: any }, changes: { [string]: any }): { [string]: any }
	local out = util.deepCopy(raw)
	for _, path in util.sortedKeys(changes) do
		local value = changes[path]
		out = util.setPath(out, path, if value == REMOVE then nil else value)
	end
	return out
end

-- Creates the file from the example text when missing. Returns true when it was created.
local function ensure(fs: fsMod.Fs, path: string, example_text: string?): (boolean, string?)
	if fs.exists(path) then
		return false, nil
	end
	local text = example_text
	if text == nil then
		return false, "example config unavailable"
	end
	local ok, err = fs.write(path, text)
	return ok, err
end

return {
	MAX_BYTES = MAX_BYTES,
	UNREADABLE_ERROR = UNREADABLE_ERROR,
	REMOVE = REMOVE,
	parse = parse,
	read = read,
	encode = encode,
	applyChanges = applyChanges,
	ensure = ensure,
}
