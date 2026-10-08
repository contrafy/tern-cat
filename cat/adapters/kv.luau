--!strict
-- tern.kv without raising. Only the host half may call `set` (docs/architecture.md, rule 1).

local STATE_KEY = "state"

export type RawKv = {
	get: (key: string) -> any,
	set: (key: string, value: any) -> (),
}

export type Kv = {
	get: (key: string) -> (any, string?),
	set: (key: string, value: any) -> (boolean, string?),
}

local function new(raw: RawKv?): Kv
	local r: RawKv = raw or (tern.kv :: any)
	return {
		get = function(key: string): (any, string?)
			local ok, value = pcall(r.get, key)
			if not ok then
				return nil, tostring(value)
			end
			return value, nil
		end,
		set = function(key: string, value: any): (boolean, string?)
			local ok, err = pcall(r.set :: any, key, value)
			return ok, if ok then nil else tostring(err)
		end,
	}
end

return {
	STATE_KEY = STATE_KEY,
	new = new,
}
