--!strict
-- JSON over tern.json without raising: decode returns (value, nil) or (nil, reason).

export type RawJson = {
	encode: (value: any, pretty: boolean?) -> string,
	decode: (text: string) -> any,
}

export type Json = {
	decode: (text: string) -> (any, string?),
	encode: (value: any, pretty: boolean?) -> string?,
	-- Raising decoder, for APIs that pcall it themselves (sprite/loader).
	decodeOrError: (text: string) -> any,
}

local function new(raw: RawJson?): Json
	local r: RawJson = raw or (tern.json :: any)
	return {
		decode = function(text: string): (any, string?)
			if type(text) ~= "string" then
				return nil, "not text"
			end
			local ok, value = pcall(r.decode, text)
			if not ok then
				return nil, "invalid JSON"
			end
			return value, nil
		end,
		encode = function(value: any, pretty: boolean?): string?
			local ok, text = pcall(r.encode, value, pretty)
			return if ok and type(text) == "string" then text else nil
		end,
		decodeOrError = function(text: string): any
			return r.decode(text)
		end,
	}
end

return {
	new = new,
}
