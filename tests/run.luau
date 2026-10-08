--!strict
-- Runs every tests/unit/**/*_spec.luau with Lune.
-- Usage (from the repo root): lune run tests/run.luau [name-filter]

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local test = require("./lib/test")

local ROOT = "tests/unit"

local function findSpecs(dir: string, out: { string })
	local entries = fs.readDir(dir)
	table.sort(entries)
	for _, entry in entries do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			findSpecs(path, out)
		elseif string.match(entry, "_spec%.luau$") then
			table.insert(out, path)
		end
	end
end

if not fs.isDir(ROOT) then
	stdio.ewrite("tests/run.luau must be run from the repository root\n")
	process.exit(2)
end

local specs: { string } = {}
findSpecs(ROOT, specs)

for _, path in specs do
	local modulePath = "./" .. string.sub(path, #"tests/" + 1, -#".luau" - 1)
	require(modulePath)
end

local filter = process.args[1]
local passed, failed, skipped = 0, 0, 0
local failures: { string } = {}

for _, case in test.collected() do
	if filter and not string.find(case.name, filter, 1, true) then
		skipped += 1
		continue
	end
	local ok, err = pcall(case.fn)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, `FAIL {case.name}\n     {tostring(err)}`)
	end
end

for _, line in failures do
	stdio.ewrite(line .. "\n")
end

local summary = `{passed} passed, {failed} failed`
if skipped > 0 then
	summary ..= `, {skipped} filtered out`
end
print(`{#specs} spec files: {summary}`)

if failed > 0 or passed == 0 then
	process.exit(1)
end
