--!strict
-- Needs decay, capped offline catch-up, gesture effects and mood derivation.
-- Needs never punish: decay stops at soft caps and nothing ever reduces stats.

local T = require("../types")
local util = require("./util")

local HOUR = 3600

local SOFT = {
	hunger_max = 0.85,
	energy_min = 0.1,
	affection_min = 0.15,
	boredom_max = 0.9,
}

-- Per-hour rates.
local AWAKE = { hunger = 0.06, energy = -0.05, affection = -0.03, boredom = 0.07 }
local ASLEEP = { hunger = 0.05, energy = 0.12, affection = -0.015, boredom = 0.02 }

-- Time away is spent awake for at most this long; the cat naps through the rest.
local AWAKE_BEFORE_NAP_S = HOUR
-- Longest gap simulated as regular in-session ticks (also the only time that counts with
-- offline_progress off). Longer in-session gaps (the computer slept) count as time away.
local ONLINE_GAP_S = 300
local MAX_CAP_HOURS = 168

local function neutral(): T.Needs
	return { hunger = 0.2, energy = 0.8, affection = 0.6, boredom = 0.2 }
end

-- Moves `value` by `delta` without crossing `limit`; values already past the limit stay put.
local function towardLimit(value: number, delta: number, limit: number): number
	if delta > 0 then
		return util.clamp01(math.max(value, math.min(value + delta, limit)))
	end
	return util.clamp01(math.min(value, math.max(value + delta, limit)))
end

local function decay(needs: T.Needs, elapsed_s: number, personality: T.Personality, asleep: boolean?): T.Needs
	if not util.isFiniteNumber(elapsed_s) or elapsed_s <= 0 then
		return table.clone(needs)
	end
	local hours = elapsed_s / HOUR
	local rates = if asleep then ASLEEP else AWAKE
	local boredomScale = 0.75 + 0.5 * util.clamp01(personality.curiosity)
	local affectionScale = 0.75 + 0.5 * util.clamp01(personality.affection)
	local energyLimit = if rates.energy > 0 then 1 else SOFT.energy_min
	return {
		hunger = towardLimit(needs.hunger, rates.hunger * hours, SOFT.hunger_max),
		energy = towardLimit(needs.energy, rates.energy * hours, energyLimit),
		affection = towardLimit(needs.affection, rates.affection * affectionScale * hours, SOFT.affection_min),
		boredom = towardLimit(needs.boredom, rates.boredom * boredomScale * hours, SOFT.boredom_max),
	}
end

local DEFAULT_PERSONALITY: T.Personality =
	{ curiosity = 0.5, affection = 0.5, mischief = 0.5, energy = 0.5, talkativeness = 0.5 }

-- Simulates the time between `last_s` and `now_s` (unix seconds). Clock skew counts as no
-- time. `session_asleep` marks an in-session catch-up while the host runs: up to ONLINE_GAP_S
-- of it uses the engine posture (asleep restores energy) and ignores `cap_hours`; anything
-- beyond that, and every offline catch-up (`session_asleep` nil), is time away: capped by
-- `cap_hours`, spent awake for an hour then napping. With `offline_progress` off only a short
-- gap counts. Disabled needs are pinned to neutral().
local function catchUp(
	needs: T.Needs,
	last_s: number,
	now_s: number,
	cap_hours: number,
	enabled: boolean,
	offline_progress: boolean,
	personality: T.Personality?,
	session_asleep: boolean?
): T.Needs
	if not enabled then
		return neutral()
	end
	local elapsed = if util.isFiniteNumber(last_s) and util.isFiniteNumber(now_s) then now_s - last_s else 0
	if elapsed <= 0 then
		return table.clone(needs)
	end
	local p = personality or DEFAULT_PERSONALITY
	local out = needs
	if session_asleep ~= nil then
		local session = math.min(elapsed, ONLINE_GAP_S)
		out = decay(out, session, p, session_asleep)
		elapsed -= session
		if elapsed <= 0 or not offline_progress then
			return out
		end
	end
	local cap = if util.isFiniteNumber(cap_hours) then util.clamp(cap_hours, 0, MAX_CAP_HOURS) else 0
	elapsed = math.min(elapsed, cap * HOUR)
	if not offline_progress then
		elapsed = math.min(elapsed, ONLINE_GAP_S)
	end
	local awake = math.min(elapsed, AWAKE_BEFORE_NAP_S)
	out = decay(out, awake, p, false)
	return decay(out, elapsed - awake, p, true)
end

type Delta = { hunger: number?, energy: number?, affection: number?, boredom: number? }

local FEED: { [string]: Delta } = {
	treat = { hunger = -0.15, affection = 0.05 },
	kibble = { hunger = -0.35 },
	fish = { hunger = -0.45, affection = 0.03 },
}

local function gestureDelta(gesture: string, item: string?): Delta?
	if gesture == "pet" then
		return { affection = 0.15, boredom = -0.03 }
	elseif gesture == "feed" then
		return FEED[item or "kibble"] or FEED.kibble
	elseif gesture == "play" then
		return { boredom = -0.3, energy = -0.05, affection = 0.05 }
	elseif gesture == "poke" then
		return { boredom = -0.05, affection = -0.02 }
	elseif gesture == "perform" then
		return { boredom = -0.05 }
	end
	return nil
end

local FLOORS = { hunger = 0, energy = SOFT.energy_min, affection = SOFT.affection_min, boredom = 0 }

local function applyGesture(needs: T.Needs, gesture: T.Gesture, item: string?): T.Needs
	local delta = gestureDelta(gesture, item)
	local out = table.clone(needs)
	if not delta then
		return out
	end
	for key, d in delta :: { [string]: number } do
		local value = (out :: any)[key] :: number
		if d >= 0 then
			value = util.clamp01(value + d)
		else
			value = towardLimit(value, d, (FLOORS :: any)[key])
		end
		(out :: any)[key] = value
	end
	return out
end

export type Recent = { gesture: string?, fail_streak: number? }

local function deriveMood(needs: T.Needs, personality: T.Personality, recent: Recent?): T.Mood
	local r: Recent = recent or {}
	if r.gesture == "poke" then
		return if needs.affection < 0.4 then "annoyed" else "playful"
	elseif r.gesture == "play" then
		return "playful"
	elseif r.gesture == "pet" or r.gesture == "feed" then
		return "happy"
	end
	if needs.energy < 0.25 then
		return "sleepy"
	end
	if needs.hunger > 0.75 or (r.fail_streak or 0) >= 3 then
		return "annoyed"
	end
	if needs.boredom > 0.6 then
		return if personality.curiosity >= personality.mischief then "curious" else "playful"
	end
	if needs.affection >= 0.75 and needs.hunger < 0.5 then
		return "happy"
	end
	if needs.energy >= 0.7 and personality.energy >= 0.7 and needs.boredom >= 0.4 then
		return "playful"
	end
	return "calm"
end

return {
	SOFT_CAPS = table.freeze(table.clone(SOFT)),
	neutral = neutral,
	decay = decay,
	catchUp = catchUp,
	applyGesture = applyGesture,
	deriveMood = deriveMood,
}
