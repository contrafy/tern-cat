--!strict
-- Shared test factories built from the real module defaults. Every call returns fresh tables.

local T = require("../../cat/types")
local util = require("../../cat/core/util")
local schema = require("../../cat/config/schema")
local model = require("../../cat/core/model")
local store = require("../../cat/core/store")

local CAT_ID = "cat-0123456789ab"
local WALL_S = 1000000

-- Resolved Config from sparse user-style overrides (same precedence as config.json).
-- Errors when resolve warns, so typos in test overrides fail loudly.
local function config(overrides: { [string]: any }?): T.Config
	local cfg, warnings = schema.resolve(overrides or {})
	if #warnings > 0 then
		error("factories.config: " .. table.concat(warnings, "; "), 2)
	end
	return cfg
end

local function profile(overrides: { [string]: any }?): T.Profile
	return util.deepMerge(model.newProfile(CAT_ID, WALL_S), overrides or {})
end

local function envelope(overrides: { [string]: any }?): T.StoreEnvelope
	return util.deepMerge(store.empty(CAT_ID, WALL_S), overrides or {})
end

local function event(overrides: { [string]: any }?): T.CatEvent
	return util.deepMerge({
		event_id = "evt-1",
		time = WALL_S,
		type = "command_finish",
		scope = "host",
		attributes = { category = "other", status = 0, reacted = false },
	}, overrides or {})
end

local function intent(kind: string, args: { [string]: any }?, overrides: { [string]: any }?): { [string]: any }
	return util.deepMerge({
		intent_id = "int-1",
		at = WALL_S,
		kind = kind,
		source = "block",
		args = args or {},
	}, overrides or {})
end

-- Deterministic stand-in for math.random: cycles through `values` (default 0.5).
local function sequence(values: { number }?): () -> number
	local list = values or { 0.5 }
	local i = 0
	return function()
		i = i % #list + 1
		return list[i]
	end
end

-- Deterministic cat id generator: cat-000000000001, cat-000000000002, ...
local function catIds(): () -> string
	local n = 0
	return function()
		n += 1
		return string.format("cat-%012x", n)
	end
end

return {
	CAT_ID = CAT_ID,
	WALL_S = WALL_S,
	config = config,
	profile = profile,
	envelope = envelope,
	event = event,
	intent = intent,
	sequence = sequence,
	catIds = catIds,
}
