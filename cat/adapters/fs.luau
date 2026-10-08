--!strict
-- FsAdapter over tern.fs. Every call is pcall-wrapped: failures become nil/false, never errors.

local T = require("../types")

export type RawFs = {
	read: (path: string, max_bytes: number?) -> string,
	write: (path: string, text: string) -> (),
	list: (path: string) -> { string },
	exists: (path: string) -> boolean,
	mkdir: (path: string) -> (),
	remove: (path: string) -> (),
}

export type Fs = T.FsAdapter & {
	write: (path: string, text: string) -> (boolean, string?),
	mkdir: (path: string) -> boolean,
	remove: (path: string) -> boolean,
}

local function new(raw: RawFs?): Fs
	local r: RawFs = raw or (tern.fs :: any)
	return {
		read = function(path: string, max_bytes: number?): string?
			local ok, text = pcall(r.read, path, max_bytes)
			return if ok and type(text) == "string" then text else nil
		end,
		list = function(path: string): { string }?
			local ok, names = pcall(r.list, path)
			if not ok or type(names) ~= "table" then
				return nil
			end
			local out: { string } = {}
			for _, name in names do
				table.insert(out, name)
			end
			return out
		end,
		exists = function(path: string): boolean
			local ok, yes = pcall(r.exists, path)
			return ok and yes == true
		end,
		write = function(path: string, text: string): (boolean, string?)
			local ok, err = pcall(r.write :: any, path, text)
			return ok, if ok then nil else tostring(err)
		end,
		mkdir = function(path: string): boolean
			return (pcall(r.mkdir, path))
		end,
		remove = function(path: string): boolean
			return (pcall(r.remove, path))
		end,
	}
end

return {
	new = new,
}
