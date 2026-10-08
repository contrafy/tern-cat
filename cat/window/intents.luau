--!strict
-- Window-side intent construction and delivery. Windows never mutate shared state; each request
-- becomes one JSON file `<inbox>/<at_ms>-<8 hex>.json` that the host validates and applies.

local T = require("../types")
local commands = require("../core/commands")
local events = require("../core/events")

export type Writer = {
	write: (path: string, text: string) -> (boolean, string?),
}

export type Encoder = {
	encode: (value: any, pretty: boolean?) -> string?,
}

local ID_PREFIX = "w"

-- Returns a validated, normalized Intent (fresh id), or nil plus the validation error.
local function build(
	rng: T.Rng,
	wall_s: number,
	kind: T.IntentKind,
	args: { [string]: any }?,
	source: T.IntentSource
): (T.Intent?, string?)
	return commands.validate({
		intent_id = events.newId(rng, ID_PREFIX),
		at = wall_s,
		kind = kind,
		source = source,
		args = args or {},
	})
end

local function fileName(at_ms: number, rng: T.Rng): string
	local ms = math.max(0, math.floor(at_ms))
	return string.format("%d-%08x.json", ms, rng:int(0, 0xFFFFFFFF))
end

-- Writes `intent` to a fresh inbox file. Returns the path, or nil plus a reason.
local function write(
	fs: Writer,
	json: Encoder,
	inbox: string,
	intent: T.Intent,
	at_ms: number,
	rng: T.Rng
): (string?, string?)
	local text = json.encode(intent)
	if text == nil then
		return nil, "could not encode the intent"
	end
	local path = inbox .. "/" .. fileName(at_ms, rng)
	local ok, err = fs.write(path, text)
	if not ok then
		return nil, `could not write {path}: {err or "unknown error"}`
	end
	return path, nil
end

return {
	build = build,
	fileName = fileName,
	write = write,
}
