--!strict
-- Profile defaults, identity generation, validation with field-level repair and migration.

local T = require("../types")
local util = require("./util")
local needsMod = require("./needs")

local SCHEMA_VERSION = 1
local MAX_FAIL_STREAK = 20

local MOODS = { "calm", "playful", "sleepy", "annoyed", "curious", "happy" }
local NEED_KEYS = { "hunger", "energy", "affection", "boredom" }
local STAT_KEYS = { "pets", "pokes", "feeds", "plays", "command_reactions" }

local HEX = "0123456789abcdef"

local function isCatId(value: any): boolean
	return type(value) == "string" and #value == 16 and string.match(value, "^cat%-[0-9a-f]+$") ~= nil
end

-- `random` is a function returning [0, 1) or an Rng (uses `rng:next()`).
local function newCatId(random: (() -> number) | T.Rng): string
	local nextValue: () -> number
	if type(random) == "function" then
		nextValue = random
	else
		local rng = random :: T.Rng
		nextValue = function()
			return rng:next()
		end
	end
	local digits = table.create(12)
	for i = 1, 12 do
		local r = nextValue()
		local d = if util.isFiniteNumber(r) then util.clamp(math.floor(r * 16), 0, 15) else 0
		digits[i] = string.sub(HEX, d + 1, d + 1)
	end
	return "cat-" .. table.concat(digits)
end

local function newStats(): T.Stats
	return { pets = 0, pokes = 0, feeds = 0, plays = 0, command_reactions = 0 }
end

local function newProfile(cat_id: string, wall_s: number): T.Profile
	return {
		schema_version = SCHEMA_VERSION,
		cat_id = cat_id,
		needs = needsMod.neutral(),
		mood = "calm",
		stats = newStats(),
		fail_streak = 0,
		created_at = wall_s,
		last_updated_at = wall_s,
	}
end

local function nonNegativeInt(value: any): number?
	if not util.isFiniteNumber(value) then
		return nil
	end
	return math.max(0, math.floor(value))
end

-- Returns (profile, note) where note lists repaired fields, or (nil, reason) when the data
-- cannot represent this cat (not an object, unknown version, missing identity).
local function migrate(raw: any, wall_s: number?): (T.Profile?, string?)
	if not util.isDict(raw) then
		return nil, "profile is not an object"
	end
	local version = raw.schema_version
	if version ~= nil and version ~= SCHEMA_VERSION then
		return nil, `unsupported profile schema_version {tostring(version)}`
	end
	if not isCatId(raw.cat_id) then
		return nil, "profile has no valid cat_id"
	end

	local repaired: { string } = {}
	local neutral = needsMod.neutral()
	local rawNeeds = if util.isDict(raw.needs) then raw.needs else {}
	local outNeeds = table.clone(neutral) :: any
	for _, key in NEED_KEYS do
		local v = rawNeeds[key]
		if util.isFiniteNumber(v) then
			outNeeds[key] = util.clamp01(v)
			if v ~= outNeeds[key] then
				table.insert(repaired, "needs." .. key)
			end
		else
			table.insert(repaired, "needs." .. key)
		end
	end

	local mood = raw.mood
	if not util.contains(MOODS, mood) then
		mood = "calm"
		table.insert(repaired, "mood")
	end

	local rawStats = if util.isDict(raw.stats) then raw.stats else {}
	local stats = newStats() :: any
	for _, key in STAT_KEYS do
		local v = rawStats[key]
		local n = nonNegativeInt(v)
		if n ~= nil then
			stats[key] = n
		end
		if n == nil or n ~= v then
			table.insert(repaired, "stats." .. key)
		end
	end

	local streak = nonNegativeInt(raw.fail_streak)
	local failStreak = math.min(streak or 0, MAX_FAIL_STREAK)
	if failStreak ~= raw.fail_streak then
		table.insert(repaired, "fail_streak")
	end

	local fallbackTime = if util.isFiniteNumber(wall_s) then wall_s :: number else 0
	local createdAt = raw.created_at
	if not util.isFiniteNumber(createdAt) then
		createdAt = fallbackTime
		table.insert(repaired, "created_at")
	end
	local updatedAt = raw.last_updated_at
	if not util.isFiniteNumber(updatedAt) then
		updatedAt = createdAt
		table.insert(repaired, "last_updated_at")
	end

	local profile: T.Profile = {
		schema_version = SCHEMA_VERSION,
		cat_id = raw.cat_id,
		needs = outNeeds,
		mood = mood,
		stats = stats,
		fail_streak = failStreak,
		created_at = createdAt,
		last_updated_at = updatedAt,
	}
	if #repaired > 0 then
		return profile, "repaired " .. table.concat(repaired, ", ")
	end
	return profile, nil
end

return {
	SCHEMA_VERSION = SCHEMA_VERSION,
	MAX_FAIL_STREAK = MAX_FAIL_STREAK,
	MOODS = MOODS,
	isCatId = isCatId,
	newCatId = newCatId,
	newProfile = newProfile,
	migrate = migrate,
}
