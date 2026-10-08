--!strict
-- Test-only factories shared by the sprite specs: synthetic PNG bytes and filesystem adapters.

local fs = require("@lune/fs")
local T = require("../../../cat/types")

local function chunk(kind: string, data: string): string
	return string.pack(">I4", #data) .. kind .. data .. "\0\0\0\0"
end

export type PngOpts = {
	width: number?,
	height: number?,
	bit_depth: number?,
	color_type: number?,
	frames: number?,
	trns: boolean?,
}

-- Structurally valid PNG/APNG header bytes (CRCs are zero; the parser does not verify them).
local function makePng(opts: PngOpts?): string
	local o: PngOpts = opts or {}
	local ihdr = string.pack(">I4I4BBBBB", o.width or 16, o.height or 16, o.bit_depth or 8, o.color_type or 6, 0, 0, 0)
	local parts = { "\137PNG\r\n\26\n", chunk("IHDR", ihdr) }
	if o.frames then
		table.insert(parts, chunk("acTL", string.pack(">I4I4", o.frames, 0)))
	end
	if o.trns then
		table.insert(parts, chunk("tRNS", "\0\0"))
	end
	table.insert(parts, chunk("IDAT", "x"))
	table.insert(parts, chunk("IEND", ""))
	return table.concat(parts)
end

-- In-memory filesystem. `files` maps full paths to contents; directories are implied.
-- `log` records every path touched so specs can assert no access happened.
local function memoryFs(files: { [string]: string }): (T.FsAdapter, { string })
	local log: { string } = {}
	local adapter: T.FsAdapter = {
		read = function(path: string, max_bytes: number?): string?
			table.insert(log, path)
			local data = files[path]
			if data and max_bytes and #data > max_bytes then
				return string.sub(data, 1, max_bytes)
			end
			return data
		end,
		list = function(path: string): { string }?
			table.insert(log, path)
			local seen: { [string]: boolean } = {}
			local out: { string } = {}
			local prefix = path .. "/"
			for p in files do
				if string.sub(p, 1, #prefix) == prefix then
					local name = string.match(string.sub(p, #prefix + 1), "^[^/]+")
					if name and not seen[name] then
						seen[name] = true
						table.insert(out, name)
					end
				end
			end
			if #out == 0 then
				return nil
			end
			table.sort(out)
			return out
		end,
		exists = function(path: string): boolean
			table.insert(log, path)
			if files[path] then
				return true
			end
			for p in files do
				if string.sub(p, 1, #path + 1) == path .. "/" then
					return true
				end
			end
			return false
		end,
	}
	return adapter, log
end

-- Adapter over the real filesystem (repo-relative paths), used with committed fixtures.
local function luneFs(): T.FsAdapter
	return {
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
			local entries = fs.readDir(path)
			table.sort(entries)
			return entries
		end,
		exists = function(path: string): boolean
			return fs.isFile(path) or fs.isDir(path)
		end,
	}
end

local function readFixture(rel: string): string
	return fs.readFile("tests/fixtures/packs/" .. rel)
end

return {
	makePng = makePng,
	memoryFs = memoryFs,
	luneFs = luneFs,
	readFixture = readFixture,
}
