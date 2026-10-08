--!strict
-- Validates intents from every source (block, window, Carly, keyboard) against an allowlist of
-- kinds and per-kind arguments, and turns gesture intents into gesture events.

local T = require("../types")
local util = require("./util")
local schema = require("../config/schema")
local events = require("./events")
local animations = require("../render/animations")

local KINDS = {
	"pet",
	"poke",
	"feed",
	"play",
	"perform",
	"set_personality",
	"set_config",
	"snooze",
	"unsnooze",
	"set_overlay",
	"rename",
	"reset_identity",
	"export_identity",
	"clear_ai_state",
}
local SOURCES = { "block", "window", "carly", "keyboard" }
local GESTURE_KINDS = { "pet", "poke", "feed", "play", "perform" }
local FOODS = { "treat", "kibble", "fish" }
local TOYS = { "ball", "string", "feather" }
local PERSONALITY_KEYS = { "curiosity", "affection", "mischief", "energy", "talkativeness" }

-- Config paths an intent may change. Everything else (AI, appearance, personality via
-- set_config, sharing) is reachable only by editing config.json or dedicated intents.
local SET_CONFIG_KEYS = {
	"behavior.activity",
	"behavior.allow_visual_obscuring",
	"behavior.allow_swats",
	"behavior.allow_command_reactions",
	"behavior.allow_development_reactions",
	"behavior.allow_pane_reactions",
	"behavior.allow_idle_sleep",
	"behavior.allow_pacing",
	"behavior.allow_pointer_reactions",
	"behavior.focus_mode",
	"sound.enabled",
	"sound.volume",
	"rendering.overlay",
	"rendering.reduced_motion",
	"quiet.hours_enabled",
	"quiet.start",
	"quiet.stop",
	"needs.enabled",
}
local MAX_SET_CONFIG_ENTRIES = #SET_CONFIG_KEYS

-- Carly calls exports without asking the user, so it may not opt into sound (the only feature
-- that starts a process), loosen quiet hours, end focus mode or turn pointer reactions on. For
-- these keys Carly may only set the listed less-intrusive value; keys mapped to nil are refused
-- outright.
local CARLY_RESTRICTED: { [string]: { value: any? } } = {
	["sound.enabled"] = { value = false },
	["sound.volume"] = {},
	["quiet.hours_enabled"] = { value = true },
	["quiet.start"] = {},
	["quiet.stop"] = {},
	["behavior.focus_mode"] = { value = true },
	["behavior.allow_pointer_reactions"] = { value = false },
}

local SCOPE_BY_SOURCE: { [string]: T.EventScope } = {
	block = "block",
	keyboard = "block",
	window = "window",
	carly = "window",
}

local ID_MAX = 64
local NAME_MAX = schema.NAME_MAX
local NAME_INPUT_MAX = 256
local SNOOZE_DEFAULT_MIN = 30
local SNOOZE_MAX_MIN = 480

type Args = { [string]: any }

local function describeValue(value: any): string
	if type(value) == "string" then
		local s = util.stripControl(value)
		if #s > 32 then
			s = string.sub(s, 1, 32) .. "..."
		end
		return string.format("%q", s)
	end
	return type(value)
end

-- Rejects any arg key not listed in `allowed`.
local function onlyKeys(args: Args, allowed: { string }): string?
	for _, key in util.sortedKeys(args) do
		if not util.contains(allowed, key) then
			return `unexpected argument {describeValue(key)}`
		end
	end
	return nil
end

local function optionalChoice(args: Args, key: string, choices: { string }, default: string): (Args?, string?)
	local err = onlyKeys(args, { key })
	if err then
		return nil, err
	end
	local value = args[key]
	if value == nil then
		return { [key] = default }, nil
	end
	if not util.contains(choices, value) then
		return nil, `{key} must be one of {table.concat(choices, ", ")}`
	end
	return { [key] = value }, nil
end

-- Same unit and limit as the cat.name config field, so an accepted rename is never reverted
-- when config.json is resolved.
local function cleanName(value: any): (string?, string?)
	if type(value) ~= "string" then
		return nil, "name must be a string"
	end
	if #value > NAME_INPUT_MAX or utf8.len(value) == nil then
		return nil, "name must be valid text"
	end
	local s = schema.checkField("cat.name", value)
	if s == nil then
		return nil, `name must be 1..{NAME_MAX} printable characters`
	end
	return s, nil
end

local function validateSetConfig(args: Args, source: string): (Args?, string?)
	local err = onlyKeys(args, { "key", "value", "values" })
	if err then
		return nil, err
	end
	local entries: Args
	if args.values ~= nil then
		if args.key ~= nil or args.value ~= nil then
			return nil, "use either key/value or values, not both"
		end
		if not util.isDict(args.values) or next(args.values) == nil then
			return nil, "values must be a non-empty object"
		end
		entries = args.values
	elseif args.key ~= nil then
		if args.value == nil then
			return nil, "value is required"
		end
		if type(args.key) ~= "string" then
			return nil, "key must be a string"
		end
		entries = { [args.key] = args.value }
	else
		return nil, "key/value or values is required"
	end

	local out: Args = {}
	local count = 0
	for _, key in util.sortedKeys(entries) do
		count += 1
		if count > MAX_SET_CONFIG_ENTRIES then
			return nil, "too many settings"
		end
		if not util.contains(SET_CONFIG_KEYS, key) then
			return nil, `setting {describeValue(key)} cannot be changed by an intent`
		end
		local restricted = if source == "carly" then CARLY_RESTRICTED[key] else nil
		if restricted then
			if restricted.value == nil then
				return nil, `setting {key} cannot be changed by Carly`
			elseif entries[key] ~= restricted.value then
				return nil, `{key}: Carly may only set this to {tostring(restricted.value)}`
			end
		end
		local value, problem = schema.checkField(key, entries[key])
		if value == nil then
			return nil, `{key}: {problem or "invalid value"}`
		end
		out[key] = value
	end
	return { values = out }, nil
end

local function validateArgs(kind: string, args: Args, source: string): (Args?, string?)
	if kind == "feed" then
		return optionalChoice(args, "item", FOODS, "kibble")
	elseif kind == "play" then
		return optionalChoice(args, "toy", TOYS, "ball")
	elseif kind == "perform" then
		local err = onlyKeys(args, { "animation" })
		if err then
			return nil, err
		end
		if not animations.isCanonical(args.animation) then
			return nil, "animation must be a canonical animation name"
		end
		return { animation = args.animation }, nil
	elseif kind == "set_personality" then
		local err = onlyKeys(args, PERSONALITY_KEYS)
		if err then
			return nil, err
		end
		if next(args) == nil then
			return nil, "at least one personality trait is required"
		end
		local out: Args = {}
		for key, value in args do
			if not util.isFiniteNumber(value) then
				return nil, `{key} must be a number`
			end
			out[key] = util.clamp01(value)
		end
		return out, nil
	elseif kind == "set_config" then
		return validateSetConfig(args, source)
	elseif kind == "snooze" then
		local err = onlyKeys(args, { "minutes" })
		if err then
			return nil, err
		end
		local minutes = args.minutes
		if minutes == nil then
			return { minutes = SNOOZE_DEFAULT_MIN }, nil
		end
		if
			not util.isFiniteNumber(minutes)
			or minutes ~= math.floor(minutes)
			or minutes < 1
			or minutes > SNOOZE_MAX_MIN
		then
			return nil, `minutes must be a whole number 1..{SNOOZE_MAX_MIN}`
		end
		return { minutes = minutes }, nil
	elseif kind == "set_overlay" then
		local err = onlyKeys(args, { "enabled" })
		if err then
			return nil, err
		end
		if type(args.enabled) ~= "boolean" then
			return nil, "enabled must be true or false"
		end
		return { enabled = args.enabled }, nil
	elseif kind == "rename" then
		local err = onlyKeys(args, { "name" })
		if err then
			return nil, err
		end
		local name, problem = cleanName(args.name)
		if not name then
			return nil, problem
		end
		return { name = name }, nil
	end
	local err = onlyKeys(args, {})
	if err then
		return nil, err
	end
	return {}, nil
end

-- Returns a fresh, normalized Intent, or nil plus a human-readable reason.
local function validate(raw: any): (T.Intent?, string?)
	if not util.isDict(raw) then
		return nil, "intent: expected an object"
	end
	local kind = raw.kind
	if not util.contains(KINDS, kind) then
		return nil, `intent: unknown kind {describeValue(kind)}`
	end
	if not util.contains(SOURCES, raw.source) then
		return nil, `intent: unknown source {describeValue(raw.source)}`
	end
	local id = raw.intent_id
	if type(id) ~= "string" or #id < 1 or #id > ID_MAX or not string.match(id, "^[A-Za-z0-9_%-]+$") then
		return nil, `intent: intent_id must be 1..{ID_MAX} characters of A-Z a-z 0-9 _ -`
	end
	if not util.isFiniteNumber(raw.at) then
		return nil, "intent: at must be a finite number"
	end
	local rawArgs = raw.args
	if rawArgs == nil then
		rawArgs = {}
	end
	if not util.isDict(rawArgs) then
		return nil, "intent: args must be an object"
	end
	local args, err = validateArgs(kind, rawArgs, raw.source)
	if not args then
		return nil, `intent {kind}: {err or "invalid arguments"}`
	end
	return {
		intent_id = id,
		at = raw.at,
		kind = kind,
		source = raw.source,
		args = args,
	}, nil
end

local function isGesture(kind: string): boolean
	return util.contains(GESTURE_KINDS, kind)
end

-- Gesture intents become gesture events (event_id = intent_id); other kinds return nil.
local function toEvent(intent: T.Intent): T.CatEvent?
	if not isGesture(intent.kind) then
		return nil
	end
	return events.gesture({
		id = intent.intent_id,
		time = intent.at,
		scope = SCOPE_BY_SOURCE[intent.source],
		gesture = intent.kind :: T.Gesture,
		item = intent.args.item,
		toy = intent.args.toy,
		animation = intent.args.animation,
		source = intent.source,
	})
end

return {
	KINDS = KINDS,
	SOURCES = SOURCES,
	SET_CONFIG_KEYS = SET_CONFIG_KEYS,
	validate = validate,
	isGesture = isGesture,
	toEvent = toEvent,
}
