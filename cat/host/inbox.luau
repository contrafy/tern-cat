--!strict
-- Intent inbox: windows drop one JSON file per intent into <data>/inbox; the host drains it.
-- Undecodable files (a write may still be in progress) are retried for GRACE_MS, then deleted.

local util = require("../core/util")
local fsMod = require("../adapters/fs")
local jsonMod = require("../adapters/json")

local GRACE_MS = 5000
local MAX_BYTES = 16 * 1024
local MAX_PER_POLL = 32
local NAME_PATTERN = "^%d+%-%x%x%x%x%x%x%x%x%.json$"

export type State = {
	-- File name -> engine ms when it was first seen unusable.
	first_seen: { [string]: number },
}

export type Item = { name: string, intent: { [string]: any } }
export type Discard = { name: string, reason: string }
export type PollResult = { items: { Item }, discarded: { Discard } }

local function newState(): State
	return { first_seen = {} }
end

local function isIntentName(name: string): boolean
	return string.match(name, NAME_PATTERN) ~= nil
end

local function poll(state: State, fs: fsMod.Fs, json: jsonMod.Json, dir: string, now_ms: number): PollResult
	local result: PollResult = { items = {}, discarded = {} }
	local names = fs.list(dir)
	if names == nil then
		state.first_seen = {}
		return result
	end
	local sorted = table.clone(names)
	table.sort(sorted)

	local present: { [string]: boolean } = {}
	local handled = 0
	for _, name in sorted do
		present[name] = true
		if handled >= MAX_PER_POLL then
			continue
		end
		local path = dir .. "/" .. name
		local reason: string? = nil
		if isIntentName(name) then
			local text = fs.read(path, MAX_BYTES + 1)
			if text ~= nil and #text > MAX_BYTES then
				handled += 1
				fs.remove(path)
				state.first_seen[name] = nil
				table.insert(result.discarded, { name = name, reason = "file too large" })
				continue
			end
			local value = if text then json.decode(text) else nil
			if util.isDict(value) then
				handled += 1
				fs.remove(path)
				state.first_seen[name] = nil
				table.insert(result.items, { name = name, intent = value })
				continue
			end
			reason = if text == nil then "unreadable" else "not a JSON object"
		else
			reason = "unexpected file name"
		end
		local first = state.first_seen[name]
		if first == nil then
			state.first_seen[name] = now_ms
		elseif now_ms - first >= GRACE_MS then
			handled += 1
			fs.remove(path)
			state.first_seen[name] = nil
			table.insert(result.discarded, { name = name, reason = reason :: string })
		end
	end
	for name in state.first_seen do
		if not present[name] then
			state.first_seen[name] = nil
		end
	end
	return result
end

return {
	GRACE_MS = GRACE_MS,
	MAX_BYTES = MAX_BYTES,
	MAX_PER_POLL = MAX_PER_POLL,
	NAME_PATTERN = NAME_PATTERN,
	newState = newState,
	isIntentName = isIntentName,
	poll = poll,
}
