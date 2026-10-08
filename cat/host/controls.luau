--!strict
-- Block input mapping: action names (buttons, sprite clicks, context menu), focused-block keys
-- and settings-page changes. Pure; the host block glue carries out the results.

local T = require("../types")
local util = require("../core/util")
local schema = require("../config/schema")
local configFile = require("../adapters/config")

local SNOOZE_MINUTES = 30

export type Command = { kind: "intent", intent: string, args: { [string]: any } } | { kind: "settings", open: boolean }

local INTENT_ACTIONS: { [string]: { intent: string, args: { [string]: any } } } = {
	pet = { intent = "pet", args = {} },
	poke = { intent = "poke", args = {} },
	feed = { intent = "feed", args = { item = "kibble" } },
	["feed-treat"] = { intent = "feed", args = { item = "treat" } },
	["feed-kibble"] = { intent = "feed", args = { item = "kibble" } },
	["feed-fish"] = { intent = "feed", args = { item = "fish" } },
	play = { intent = "play", args = { toy = "ball" } },
	["play-ball"] = { intent = "play", args = { toy = "ball" } },
	["play-string"] = { intent = "play", args = { toy = "string" } },
	["play-feather"] = { intent = "play", args = { toy = "feather" } },
	["snooze-30m"] = { intent = "snooze", args = { minutes = SNOOZE_MINUTES } },
	wake = { intent = "unsnooze", args = {} },
	["overlay-on"] = { intent = "set_overlay", args = { enabled = true } },
	["overlay-off"] = { intent = "set_overlay", args = { enabled = false } },
}

local function resolveAction(act: any): Command?
	if type(act) ~= "string" then
		return nil
	end
	local spec = INTENT_ACTIONS[act]
	if spec then
		return { kind = "intent", intent = spec.intent, args = util.deepCopy(spec.args) }
	end
	if act == "settings" then
		return { kind = "settings", open = true }
	end
	return nil
end

-- The sprite's right-click menu and the dock share these action names.
local function menuActions(snoozed: boolean, overlay_on: boolean): { string }
	return {
		"pet",
		"poke",
		"feed-treat",
		"feed-kibble",
		"feed-fish",
		"play-ball",
		"play-string",
		"play-feather",
		if snoozed then "wake" else "snooze-30m",
		if overlay_on then "overlay-off" else "overlay-on",
		"settings",
	}
end

export type KeyInput = { name: string, ctrl: boolean?, alt: boolean?, meta: boolean?, shift: boolean? }

-- Returns the action for a key pressed while the block has focus, or nil to let it pass.
local function keyAction(
	key: KeyInput,
	page: string,
	keyboard_enabled: boolean,
	snoozed: boolean,
	overlay_on: boolean
): string?
	if key.ctrl or key.alt or key.meta then
		return nil
	end
	local name = key.name
	if page == "settings" then
		return if name == "escape" then "close-settings" else nil
	end
	if not keyboard_enabled then
		return nil
	end
	if name == "p" then
		return "pet"
	elseif name == "o" then
		return "poke"
	elseif name == "f" then
		return "feed"
	elseif name == "space" then
		return "play"
	elseif name == "s" then
		return "settings"
	elseif name == "h" then
		return if overlay_on then "overlay-off" else "overlay-on"
	elseif name == "z" then
		return if snoozed then "wake" else "snooze-30m"
	end
	return nil
end

-- Settings rows ------------------------------------------------------------------------------

-- Rows edited as whole percentages in the UI and stored as fractions.
local PERCENT: { [string]: boolean } = {
	["personality.curiosity"] = true,
	["personality.affection"] = true,
	["personality.mischief"] = true,
	["personality.energy"] = true,
	["personality.talkativeness"] = true,
	["sound.volume"] = true,
	["behavior.reaction_sample_rate"] = true,
}

-- Rows the settings page can change (others are display-only).
local EDITABLE: { [string]: boolean } = {
	["behavior.activity"] = true,
	["cat.appearance"] = true,
	["needs.enabled"] = true,
	["rendering.overlay"] = true,
	["rendering.block_placement"] = true,
	["rendering.reduced_motion"] = true,
	["rendering.block_scale"] = true,
	["controls.keyboard_enabled"] = true,
	["behavior.allow_visual_obscuring"] = true,
	["behavior.allow_swats"] = true,
	["behavior.allow_command_reactions"] = true,
	["behavior.allow_development_reactions"] = true,
	["behavior.allow_pane_reactions"] = true,
	["behavior.allow_idle_sleep"] = true,
	["behavior.allow_pacing"] = true,
	["behavior.focus_mode"] = true,
	["behavior.reaction_cooldown_s"] = true,
	["quiet.hours_enabled"] = true,
	["quiet.start"] = true,
	["quiet.stop"] = true,
	["sound.enabled"] = true,
	["sound.respect_quiet_hours"] = true,
	["sound.events"] = true,
}
for path in PERCENT do
	EDITABLE[path] = true
end

local function isPercent(path: string): boolean
	return PERCENT[path] == true
end

-- Maps a prefs `change {item, value}` to config.json changes. A nil value is the row's Reset.
local function settingsChange(item: any, value: any): ({ [string]: any }?, string?)
	if type(item) ~= "string" or not EDITABLE[item] then
		return nil, `setting {tostring(item)} cannot be changed here`
	end
	if value == nil then
		return { [item] = configFile.REMOVE }, nil
	end
	local v = value
	if PERCENT[item] then
		if not util.isFiniteNumber(v) then
			return nil, `{item}: expected a number`
		end
		v = math.floor(v + 0.5) / 100
	elseif item == "sound.events" then
		if type(v) ~= "table" then
			return nil, `{item}: expected a list`
		end
		local flags = {}
		for _, id in schema.SOUND_IDS do
			flags[id] = util.contains(v, id)
		end
		v = flags
	end
	local normalized, problem = schema.checkField(item, v)
	if normalized == nil then
		return nil, `{item}: {problem or "invalid value"}`
	end
	return { [item] = normalized }, nil
end

-- The value a row shows for `config` (percent rows as whole numbers).
local function displayValue(config: T.Config, path: string): any
	local v = util.getPath(config, path)
	if PERCENT[path] and type(v) == "number" then
		return math.floor(v * 100 + 0.5)
	end
	return v
end

-- Test mode for goldens: block args or TERN_CAT_TEST items "test", "frozen", "seed=<n>".
-- Returns nil when none of them is present.
export type TestMode = { seed: number, frozen: boolean }

local function parseTestMode(items: any): TestMode?
	if type(items) == "string" then
		items = string.split(items, ",")
	end
	if type(items) ~= "table" then
		return nil
	end
	local found = false
	local mode: TestMode = { seed = 1, frozen = false }
	for _, raw in items do
		if type(raw) ~= "string" then
			continue
		end
		local item = string.lower(string.match(raw, "^%s*(.-)%s*$") or "")
		local seed = string.match(item, "^seed=(%d+)$")
		if item == "test" then
			found = true
		elseif item == "frozen" then
			found = true
			mode.frozen = true
		elseif seed then
			found = true
			mode.seed = math.clamp(tonumber(seed) or 1, 1, 0x7FFFFFFF)
		end
	end
	return if found then mode else nil
end

return {
	SNOOZE_MINUTES = SNOOZE_MINUTES,
	resolveAction = resolveAction,
	menuActions = menuActions,
	keyAction = keyAction,
	settingsChange = settingsChange,
	displayValue = displayValue,
	isPercent = isPercent,
	parseTestMode = parseTestMode,
}
