--!strict
-- Config defaults, activity presets, validation with per-field fallback, migration and the
-- precedence merge: defaults < preset(behavior.activity) < explicit user fields.
--
-- ai.provider "carly_schedule" is a recognized value, but no verified Carly scheduling API
-- exists; cat/integrations/ai.luau reports it as unavailable. ai.share_command_output is
-- always resolved to false in v1 because there is no consent flow.

local T = require("../types")
local util = require("../core/util")

local CURRENT_VERSION = 1

local ACTIVITIES = { "quiet_office", "menace", "chaos", "zen" }
-- Old activity names still accepted silently; they resolve to the current name.
local ACTIVITY_ALIASES: { [string]: string } = { orange_menace = "menace" }
local REDUCED_MOTION = { "follow_tern", "on", "off" }
local BLOCK_PLACEMENTS = { "float", "split" }
local PANE_TRANSITIONS = { "portal", "vent", "box", "off" }
local OVERLAY_POSITIONS = { "top-right", "top-left", "bottom-right", "bottom-left" }
local AI_PROVIDERS = { "none", "mock", "carly_schedule" }
local SOUND_IDS = { "meow", "purr", "surprise", "happy", "swat" }

local PACK_ID_PATTERN = "^[a-z][a-z0-9-]*$"
local PACK_ID_MAX = 32
-- cat.name length in UTF-8 characters (rename intents use the same check).
local NAME_MAX = 32

type FieldKind = "boolean" | "number" | "enum" | "name" | "pack_id" | "hm" | "flags"

type FieldSpec = {
	key: string,
	kind: FieldKind,
	min: number?,
	max: number?,
	integer: boolean?,
	values: { string }?,
}

type SectionSpec = { key: string, fields: { FieldSpec } }

local function bool(key: string): FieldSpec
	return { key = key, kind = "boolean" }
end

local function num(key: string, min: number, max: number, integer: boolean?): FieldSpec
	return { key = key, kind = "number", min = min, max = max, integer = integer }
end

local function enum(key: string, values: { string }): FieldSpec
	return { key = key, kind = "enum", values = values }
end

local SECTIONS: { SectionSpec } = {
	{
		key = "cat",
		fields = {
			{ key = "name", kind = "name", min = 1, max = NAME_MAX },
			{ key = "appearance", kind = "pack_id" },
		},
	},
	{
		key = "personality",
		fields = {
			num("curiosity", 0, 1),
			num("affection", 0, 1),
			num("mischief", 0, 1),
			num("energy", 0, 1),
			num("talkativeness", 0, 1),
		},
	},
	{
		key = "needs",
		fields = {
			bool("enabled"),
			bool("offline_progress"),
			num("offline_hours_cap", 0, 168),
		},
	},
	{
		key = "rendering",
		fields = {
			bool("overlay"),
			enum("overlay_position", OVERLAY_POSITIONS),
			num("overlay_offset_px", 0, 200, true),
			num("overlay_scale", 1, 8, true),
			num("block_scale", 1, 12, true),
			enum("reduced_motion", REDUCED_MOTION),
			enum("block_placement", BLOCK_PLACEMENTS),
			enum("pane_transition", PANE_TRANSITIONS),
		},
	},
	{
		key = "behavior",
		fields = {
			enum("activity", ACTIVITIES),
			bool("allow_visual_obscuring"),
			bool("allow_swats"),
			bool("allow_command_reactions"),
			bool("allow_development_reactions"),
			bool("allow_pane_reactions"),
			bool("allow_idle_sleep"),
			bool("allow_pacing"),
			bool("allow_pointer_reactions"),
			bool("focus_mode"),
			num("reaction_sample_rate", 0, 1),
			num("reaction_cooldown_s", 0, 3600, true),
		},
	},
	{
		key = "quiet",
		fields = {
			bool("hours_enabled"),
			{ key = "start", kind = "hm" },
			{ key = "stop", kind = "hm" },
		},
	},
	{
		key = "ai",
		fields = {
			bool("enabled"),
			enum("provider", AI_PROVIDERS),
			num("max_turns_per_hour", 0, 10, true),
			num("max_turns_per_day", 0, 100, true),
			num("cooldown_s", 60, 86400, true),
			bool("share_command_output"),
		},
	},
	{
		key = "sound",
		fields = {
			bool("enabled"),
			num("volume", 0, 1),
			{ key = "pack", kind = "pack_id" },
			{ key = "events", kind = "flags", values = SOUND_IDS },
			bool("respect_quiet_hours"),
		},
	},
	{
		key = "controls",
		fields = {
			bool("keyboard_enabled"),
		},
	},
}

local FIELD_BY_PATH: { [string]: FieldSpec } = {}
for _, section in SECTIONS do
	for _, field in section.fields do
		FIELD_BY_PATH[section.key .. "." .. field.key] = field
	end
end

local function defaults(): T.Config
	return {
		schema_version = CURRENT_VERSION,
		cat = {
			name = "Menace",
			appearance = "orange-menace",
		},
		personality = {
			curiosity = 0.9,
			affection = 0.65,
			mischief = 0.85,
			energy = 0.75,
			talkativeness = 0.15,
		},
		needs = {
			enabled = true,
			offline_progress = true,
			offline_hours_cap = 12,
		},
		rendering = {
			overlay = true,
			overlay_position = "top-right",
			overlay_offset_px = 12,
			overlay_scale = 2,
			block_scale = 4,
			reduced_motion = "follow_tern",
			block_placement = "float",
			pane_transition = "portal",
		},
		behavior = {
			activity = "menace",
			allow_visual_obscuring = true,
			allow_swats = true,
			allow_command_reactions = true,
			allow_development_reactions = true,
			allow_pane_reactions = true,
			allow_idle_sleep = true,
			allow_pacing = true,
			allow_pointer_reactions = true,
			focus_mode = false,
			reaction_sample_rate = 0.35,
			reaction_cooldown_s = 45,
		},
		quiet = {
			hours_enabled = false,
			start = "22:00",
			stop = "08:00",
		},
		ai = {
			enabled = false,
			provider = "none",
			max_turns_per_hour = 2,
			max_turns_per_day = 10,
			cooldown_s = 300,
			share_command_output = false,
		},
		sound = {
			enabled = false,
			volume = 0.25,
			pack = "default",
			events = {
				meow = true,
				purr = true,
				surprise = true,
				happy = true,
				swat = true,
			},
			respect_quiet_hours = true,
		},
		controls = {
			keyboard_enabled = true,
		},
	}
end

local PRESETS: { [string]: { [string]: any } } = {
	quiet_office = {
		personality = { mischief = 0.3, energy = 0.4, talkativeness = 0.05 },
		behavior = {
			allow_visual_obscuring = false,
			allow_swats = false,
			allow_pacing = false,
			allow_pointer_reactions = false,
			focus_mode = true,
			reaction_sample_rate = 0.1,
			reaction_cooldown_s = 180,
		},
	},
	menace = {},
	chaos = {
		personality = { curiosity = 1, mischief = 1, energy = 0.95, talkativeness = 0.4 },
		behavior = {
			allow_visual_obscuring = true,
			allow_swats = true,
			allow_command_reactions = true,
			allow_development_reactions = true,
			allow_pane_reactions = true,
			allow_idle_sleep = true,
			allow_pacing = true,
			allow_pointer_reactions = true,
			reaction_sample_rate = 0.8,
			reaction_cooldown_s = 10,
		},
	},
	zen = {
		personality = { curiosity = 0.4, mischief = 0.1, energy = 0.15, talkativeness = 0.05 },
		behavior = {
			allow_visual_obscuring = false,
			allow_swats = false,
			allow_pacing = false,
			allow_idle_sleep = true,
			reaction_sample_rate = 0.05,
			reaction_cooldown_s = 600,
		},
	},
}

-- Sparse overrides applied on top of defaults(); unknown activities have none.
local function preset(activity: string): { [string]: any }
	return util.deepCopy(PRESETS[activity] or {})
end

local function render(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

-- Returns (normalized value, nil) when valid, (normalized value, warning) when the value was
-- repaired (clamped, rounded, sanitized), and (nil, reason) when it cannot be used.
local function checkSpec(field: FieldSpec, value: any): (any, string?)
	local kind = field.kind
	if kind == "boolean" then
		if type(value) ~= "boolean" then
			return nil, "expected true or false"
		end
		return value, nil
	elseif kind == "number" then
		if not util.isFiniteNumber(value) then
			return nil, "expected a number"
		end
		local lo, hi = field.min :: number, field.max :: number
		local out: number = value
		local note: string? = nil
		if field.integer and out ~= math.floor(out) then
			out = math.floor(out + 0.5)
			note = `rounded to {out}`
		end
		if out < lo or out > hi then
			out = util.clamp(out, lo, hi)
			note = `out of range {lo}..{hi}, clamped to {out}`
		end
		return out, note
	elseif kind == "enum" then
		if type(value) ~= "string" or not util.contains(field.values :: { string }, value) then
			return nil, `expected one of {table.concat(field.values :: { string }, ", ")}`
		end
		return value, nil
	elseif kind == "name" then
		-- Shared with rename intents (commands.cleanName): UTF-8 characters, controls removed.
		if type(value) ~= "string" or utf8.len(value) == nil then
			return nil, "expected text"
		end
		local cleaned = util.stripControl(value)
		cleaned = string.gsub(cleaned, "\194[\128-\159]", "")
		cleaned = string.match(cleaned, "^%s*(.-)%s*$") or ""
		local len = utf8.len(cleaned) or 0
		if len < (field.min :: number) or len > (field.max :: number) then
			return nil, `expected {field.min}..{field.max} characters`
		end
		if cleaned ~= value then
			return cleaned, "removed control characters or surrounding spaces"
		end
		return cleaned, nil
	elseif kind == "pack_id" then
		if type(value) ~= "string" or #value > PACK_ID_MAX or not string.match(value, PACK_ID_PATTERN) then
			return nil, "expected a pack id (lowercase letters, digits, dashes)"
		end
		return value, nil
	elseif kind == "hm" then
		if not util.parseHm(value) then
			return nil, "expected HH:MM (24-hour)"
		end
		return value, nil
	elseif kind == "flags" then
		if not util.isDict(value) then
			return nil, "expected an object of true/false values"
		end
		return value, nil
	end
	return nil, "unsupported field"
end

-- Validates a single dotted config path (e.g. "sound.volume") for writers such as intents.
local function checkField(path: string, value: any): (any, string?)
	local field = FIELD_BY_PATH[path]
	if not field then
		return nil, `unknown setting {path}`
	end
	if field.kind == "flags" then
		if not util.isDict(value) then
			return nil, "expected an object of true/false values"
		end
		local out = {}
		for k, v in value do
			if type(k) ~= "string" or not util.contains(field.values :: { string }, k) or type(v) ~= "boolean" then
				return nil, `invalid entry {render(k)}`
			end
			out[k] = v
		end
		return out, nil
	end
	if path == "behavior.activity" and type(value) == "string" and ACTIVITY_ALIASES[value] then
		value = ACTIVITY_ALIASES[value]
	end
	return checkSpec(field, value)
end

local function migrate(raw: any): ({ [string]: any }, { string })
	local warnings: { string } = {}
	if raw == nil then
		return { schema_version = CURRENT_VERSION }, warnings
	end
	if not util.isDict(raw) then
		table.insert(warnings, "config: expected a JSON object; using defaults")
		return { schema_version = CURRENT_VERSION }, warnings
	end
	local out = util.deepCopy(raw)
	local version = out.schema_version
	if version == nil then
		version = CURRENT_VERSION
	elseif not util.isFiniteNumber(version) or version < 1 or version ~= math.floor(version) then
		table.insert(warnings, `config: schema_version: invalid value {render(version)}; treating as {CURRENT_VERSION}`)
		version = CURRENT_VERSION
	elseif version > CURRENT_VERSION then
		table.insert(
			warnings,
			`config: schema_version: {version} is newer than supported {CURRENT_VERSION}; reading known fields only`
		)
	end
	out.schema_version = CURRENT_VERSION
	local behavior = out.behavior
	if util.isDict(behavior) and type(behavior.activity) == "string" and ACTIVITY_ALIASES[behavior.activity] then
		behavior.activity = ACTIVITY_ALIASES[behavior.activity]
	end
	return out, warnings
end

local function resolveActivity(raw: { [string]: any }): string
	local behavior = raw.behavior
	if util.isDict(behavior) and util.contains(ACTIVITIES, behavior.activity) then
		return behavior.activity
	end
	return "menace"
end

local function resolveUnsafe(input: any): (T.Config, { string })
	local raw, warnings = migrate(input)
	local base = util.deepMerge(defaults(), preset(resolveActivity(raw)))
	local out = util.deepCopy(base)

	local known: { [string]: boolean } = { schema_version = true }
	for _, section in SECTIONS do
		known[section.key] = true
		local rawSection = raw[section.key]
		if rawSection == nil then
			continue
		end
		if not util.isDict(rawSection) then
			table.insert(warnings, `config: {section.key}: expected an object; using defaults`)
			continue
		end
		local knownFields: { [string]: boolean } = {}
		for _, field in section.fields do
			knownFields[field.key] = true
			local path = section.key .. "." .. field.key
			local value = rawSection[field.key]
			if value == nil then
				continue
			end
			local fallback = base[section.key][field.key]
			if field.kind == "flags" then
				if not util.isDict(value) then
					table.insert(warnings, `config: {path}: expected an object of true/false values; using defaults`)
					continue
				end
				local allowed = field.values :: { string }
				local flags = util.deepCopy(fallback)
				for _, k in util.sortedKeys(value) do
					local v = value[k]
					if not util.contains(allowed, k) then
						table.insert(warnings, `config: {path}.{k}: unknown key ignored`)
					elseif type(v) ~= "boolean" then
						table.insert(warnings, `config: {path}.{k}: expected true or false; using {render(flags[k])}`)
					else
						flags[k] = v
					end
				end
				out[section.key][field.key] = flags
				continue
			end
			local normalized, note = checkSpec(field, value)
			if normalized == nil then
				table.insert(warnings, `config: {path}: {note}; using {render(fallback)}`)
			else
				if note then
					table.insert(warnings, `config: {path}: {note}`)
				end
				out[section.key][field.key] = normalized
			end
		end
		for _, k in util.sortedKeys(rawSection) do
			if not knownFields[k] then
				table.insert(warnings, `config: {section.key}.{k}: unknown key ignored`)
			end
		end
	end
	for _, k in util.sortedKeys(raw) do
		if not known[k] then
			table.insert(warnings, `config: {k}: unknown key ignored`)
		end
	end

	if out.ai.share_command_output then
		out.ai.share_command_output = false
		table.insert(warnings, "config: ai.share_command_output: not supported in this version; forced to false")
	end
	out.schema_version = CURRENT_VERSION
	return out :: T.Config, warnings
end

-- Never throws: any input yields a complete Config plus human-readable warnings.
local function resolve(raw: any): (T.Config, { string })
	local ok, config, warnings = pcall(resolveUnsafe, raw)
	if ok then
		return config, warnings
	end
	return defaults(), { `config: unreadable ({tostring(config)}); using defaults` }
end

-- Sparse user view: only fields that differ from defaults + the activity preset, plus the
-- activity and schema_version. Writing this keeps presets effective for untouched fields.
local function serialize(config: T.Config): { [string]: any }
	local activity = (config.behavior and config.behavior.activity) or "menace"
	local base = util.deepMerge(defaults(), preset(activity))
	local out: { [string]: any } = { schema_version = CURRENT_VERSION }
	local cfg = config :: any
	for _, section in SECTIONS do
		local current = cfg[section.key]
		if type(current) ~= "table" then
			continue
		end
		local diff: { [string]: any } = {}
		for _, field in section.fields do
			local value = current[field.key]
			local baseline = base[section.key][field.key]
			if field.kind == "flags" and type(value) == "table" then
				local flags = {}
				for _, k in util.sortedKeys(value) do
					if value[k] ~= baseline[k] then
						flags[k] = value[k]
					end
				end
				if next(flags) ~= nil then
					diff[field.key] = flags
				end
			elseif value ~= nil and value ~= baseline then
				diff[field.key] = value
			end
		end
		if next(diff) ~= nil then
			out[section.key] = diff
		end
	end
	if activity ~= "menace" then
		out.behavior = out.behavior or {}
		out.behavior.activity = activity
	end
	return out
end

local function fieldPaths(): { string }
	return util.sortedKeys(FIELD_BY_PATH)
end

return {
	CURRENT_VERSION = CURRENT_VERSION,
	NAME_MAX = NAME_MAX,
	ACTIVITIES = ACTIVITIES,
	SOUND_IDS = SOUND_IDS,
	PANE_TRANSITIONS = PANE_TRANSITIONS,
	OVERLAY_POSITIONS = OVERLAY_POSITIONS,
	defaults = defaults,
	preset = preset,
	migrate = migrate,
	resolve = resolve,
	checkField = checkField,
	serialize = serialize,
	fieldPaths = fieldPaths,
}
