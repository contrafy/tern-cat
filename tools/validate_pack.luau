--!strict
-- Validates sprite packs with the same rules the plugin applies at load time.
-- Usage: lune run tools/validate_pack.luau <pack-dir> [<pack-dir> ...]
-- Exits 0 when every pack is valid, 1 when any pack is invalid, 2 on usage errors.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local T = require("../cat/types")
local manifest = require("../cat/sprite/manifest")

local adapter: T.FsAdapter = {
	read = function(path: string, max_bytes: number?): string?
		if not fs.isFile(path) then
			return nil
		end
		local data = fs.readFile(path)
		if max_bytes and #data > max_bytes then
			return string.sub(data, 1, max_bytes)
		end
		return data
	end,
	list = function(path: string): { string }?
		if not fs.isDir(path) then
			return nil
		end
		return fs.readDir(path)
	end,
	exists = function(path: string): boolean
		return fs.isFile(path) or fs.isDir(path)
	end,
}

local function check(arg: string): boolean
	local dir = string.gsub(arg, "/+$", "")
	local file = dir .. "/pack.json"
	if not fs.isFile(file) then
		stdio.ewrite(`FAIL {dir}: {file} not found\n`)
		return false
	end
	local okDecode, raw = pcall(serde.decode, "json", fs.readFile(file))
	if not okDecode then
		local reason = string.match(tostring(raw), "^[^\n]*") or "decode failed"
		stdio.ewrite(`FAIL {dir}: pack.json is not valid JSON: {reason}\n`)
		return false
	end
	local result = manifest.validate(raw, adapter, dir)
	for _, w in result.warnings do
		stdio.ewrite(`WARN {dir}: {w}\n`)
	end
	if not result.ok then
		for _, e in result.errors do
			stdio.ewrite(`FAIL {dir}: {e}\n`)
		end
		return false
	end
	print(`ok   {dir}`)
	return true
end

if #process.args == 0 then
	stdio.ewrite("usage: lune run tools/validate_pack.luau <pack-dir> [<pack-dir> ...]\n")
	process.exit(2)
end

local allOk = true
for _, dir in process.args do
	if not check(dir) then
		allOk = false
	end
end
process.exit(if allOk then 0 else 1)
