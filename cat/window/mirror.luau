--!strict
-- Decides whether the host's most recent reaction (envelope.last_reaction) should play in this
-- window's overlay: only when it is new (by at + id), recent, and not the echo of something this
-- window already reacted to itself (an optimistic gesture, or its own command event).

local T = require("../types")
local util = require("../core/util")

-- What this window reacted to locally; times are wall-clock seconds.
export type Recent = { gesture: string?, gesture_at: number?, command_at: number? }

local MAX_AGE_S = 5
local MAX_SKEW_S = 2
local ECHO_GRACE_S = 1
local COMMAND_FAMILIES = { "react.command", "react.fail_streak", "react.ls_swat", "react.sudo" }

local function key(record: T.ReactionRecord): string
	return `{record.at}|{record.id}`
end

local function after(record: T.ReactionRecord, at: number?): boolean
	return at ~= nil and record.at >= at - ECHO_GRACE_S
end

local function isEcho(record: T.ReactionRecord, recent: Recent?): boolean
	if recent == nil then
		return false
	end
	local g = recent.gesture
	if g and after(record, recent.gesture_at) and string.find(record.id, "gesture." .. g, 1, true) then
		return true
	end
	if after(record, recent.command_at) then
		for _, family in COMMAND_FAMILIES do
			if string.find(record.id, family, 1, true) then
				return true
			end
		end
	end
	return false
end

-- Returns (play, key_to_remember).
local function check(record: T.ReactionRecord?, seen: string?, now_s: number, recent: Recent?): (boolean, string?)
	if
		record == nil
		or not util.isFiniteNumber(record.at)
		or type(record.id) ~= "string"
		or type(record.animation) ~= "string"
	then
		return false, seen
	end
	local k = key(record)
	if k == seen then
		return false, seen
	end
	local age = now_s - record.at
	if age >= MAX_AGE_S or age < -MAX_SKEW_S then
		return false, k
	end
	if isEcho(record, recent) then
		return false, k
	end
	return true, k
end

return {
	MAX_AGE_S = MAX_AGE_S,
	key = key,
	check = check,
}
