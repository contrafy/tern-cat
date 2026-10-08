--!strict
-- Test-only fakes for host modules: writable in-memory fs, serde-backed json and kv.

local serde = require("@lune/serde")
local lfs = require("@lune/fs")
local fsAdapter = require("../../../cat/adapters/fs")
local jsonAdapter = require("../../../cat/adapters/json")
local kvAdapter = require("../../../cat/adapters/kv")

export type MemFs = {
	files: { [string]: string },
	dirs: { [string]: boolean },
	fs: fsAdapter.Fs,
	failWrites: boolean,
	-- Relative paths not present in `files` are read from the repo (read-only).
	real: boolean,
}

local function parentOf(path: string): string?
	return string.match(path, "^(.*)/[^/]+$")
end

local function memFs(files: { [string]: string }?, real: boolean?): MemFs
	local m: MemFs = { files = files or {}, dirs = {}, fs = nil :: any, failWrites = false, real = real == true }
	local function onDisk(path: string): boolean
		return m.real and string.sub(path, 1, 1) ~= "/"
	end
	local raw: fsAdapter.RawFs = {
		read = function(path: string, max_bytes: number?): string
			local data = m.files[path]
			if data == nil and onDisk(path) and lfs.isFile(path) then
				data = lfs.readFile(path)
			end
			if data == nil then
				error("no such file " .. path)
			end
			if max_bytes and #data > max_bytes then
				error("file too large")
			end
			return data
		end,
		write = function(path: string, text: string)
			if m.failWrites then
				error("disk full")
			end
			local parent = parentOf(path)
			if parent and not m.dirs[parent] then
				local implied = false
				for p in m.files do
					if parentOf(p) == parent then
						implied = true
						break
					end
				end
				if not implied then
					error("no such directory " .. parent)
				end
			end
			m.files[path] = text
		end,
		list = function(path: string): { string }
			if onDisk(path) and lfs.isDir(path) then
				local entries = lfs.readDir(path)
				table.sort(entries)
				return entries
			end
			local seen: { [string]: boolean } = {}
			local out: { string } = {}
			local prefix = path .. "/"
			for p in m.files do
				if string.sub(p, 1, #prefix) == prefix then
					local name = string.match(string.sub(p, #prefix + 1), "^[^/]+")
					if name and not seen[name] then
						seen[name] = true
						table.insert(out, name)
					end
				end
			end
			if #out == 0 and not m.dirs[path] then
				error("no such directory " .. path)
			end
			table.sort(out)
			return out
		end,
		exists = function(path: string): boolean
			if onDisk(path) and (lfs.isFile(path) or lfs.isDir(path)) then
				return true
			end
			if m.files[path] or m.dirs[path] then
				return true
			end
			for p in m.files do
				if string.sub(p, 1, #path + 1) == path .. "/" then
					return true
				end
			end
			return false
		end,
		mkdir = function(path: string)
			local cur: string? = path
			while cur and cur ~= "" do
				m.dirs[cur] = true
				cur = parentOf(cur)
			end
		end,
		remove = function(path: string)
			if m.files[path] == nil then
				error("no such file " .. path)
			end
			m.files[path] = nil
		end,
	}
	m.fs = fsAdapter.new(raw)
	return m
end

local function json(): jsonAdapter.Json
	return jsonAdapter.new({
		encode = function(value: any, pretty: boolean?): string
			return serde.encode("json", value, pretty == true)
		end,
		decode = function(text: string): any
			return serde.decode("json", text)
		end,
	})
end

export type MemKv = {
	data: { [string]: any },
	sets: number,
	failGet: boolean,
	-- When it returns true, set raises (like tern.kv over an unparsable kv.json).
	blocked: (() -> boolean)?,
	kv: kvAdapter.Kv,
}

local function memKv(initial: { [string]: any }?): MemKv
	local m: MemKv = { data = initial or {}, sets = 0, failGet = false, blocked = nil, kv = nil :: any }
	m.kv = kvAdapter.new({
		get = function(key: string): any
			if m.failGet then
				error("kv.json: invalid JSON")
			end
			return m.data[key]
		end,
		set = function(key: string, value: any)
			local blocked = m.blocked
			if blocked and blocked() then
				error("EOF while parsing a value")
			end
			m.sets += 1
			-- Round-trip through JSON like tern.kv does.
			m.data[key] = serde.decode("json", serde.encode("json", value))
		end,
	})
	return m
end

return {
	memFs = memFs,
	json = json,
	memKv = memKv,
}
