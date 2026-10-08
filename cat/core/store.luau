--!strict
-- StoreEnvelope lifecycle for the single host-side writer: decode/recover, offline catch-up,
-- apply events and intents exactly once (dedupe by id), bounded journal, rev bumps.
-- Every function returns a new envelope; inputs are never mutated.

local T = require("../types")
local util = require("./util")
local model = require("./model")
local needsMod = require("./needs")
local commands = require("./commands")
local animations = require("../render/animations")

local SCHEMA_VERSION = 1
local MAX_JOURNAL = 50
local MAX_SEEN = 256
local MAX_SUMMARY = 120
local MAX_REASON = 120

local STAT_BY_GESTURE: { [string]: string } = {
	pet = "pets",
	poke = "pokes",
	feed = "feeds",
	play = "plays",
}
local FOODS = { "treat", "kibble", "fish" }
local TOYS = { "ball", "string", "feather" }

-- Side effects the host must carry out after applyIntent (config writes, toasts, exports).
export type Effect = { kind: string, [string]: any }

local function empty(cat_id: string, wall_s: number): T.StoreEnvelope
	return {
		schema_version = SCHEMA_VERSION,
		rev = 0,
		profile = model.newProfile(cat_id, wall_s),
		journal = {},
		seen = {},
		last_reaction = nil,
		snooze_until = nil,
	}
end

local function shortText(value: string, max: number): string
	local s = util.stripControl(value)
	if #s > max then
		s = string.sub(s, 1, max)
		-- Drop a trailing partial UTF-8 sequence.
		while #s > 0 and utf8.len(s) == nil do
			s = string.sub(s, 1, -2)
		end
	end
	return s
end

local function journalPush(env: T.StoreEnvelope, at: number, event_id: string, kind: string, summary: string)
	local entry: T.JournalEntry = {
		at = at,
		event_id = event_id,
		kind = kind,
		summary = shortText(summary, MAX_SUMMARY),
	}
	env.journal = util.ringPush(env.journal, entry, MAX_JOURNAL)
end

local function hasSeen(env: T.StoreEnvelope, id: string): boolean
	return util.contains(env.seen, id)
end

local function markSeen(env: T.StoreEnvelope, id: string)
	env.seen = util.ringPush(env.seen, id, MAX_SEEN)
end

local function isSnoozed(env: T.StoreEnvelope, wall_s: number): boolean
	local untilS = env.snooze_until
	return untilS ~= nil and wall_s < untilS
end

-- Decoding ---------------------------------------------------------------------------------

local function decodeJournal(raw: any): { T.JournalEntry }
	local out: { T.JournalEntry } = {}
	if not util.isArray(raw) then
		return out
	end
	for _, e in raw do
		if
			util.isDict(e)
			and util.isFiniteNumber(e.at)
			and type(e.event_id) == "string"
			and type(e.kind) == "string"
			and type(e.summary) == "string"
		then
			out = util.ringPush(out, {
				at = e.at,
				event_id = shortText(e.event_id, 64),
				kind = shortText(e.kind, 32),
				summary = shortText(e.summary, MAX_SUMMARY),
			}, MAX_JOURNAL)
		end
	end
	return out
end

local function decodeSeen(raw: any): { string }
	local out: { string } = {}
	if not util.isArray(raw) then
		return out
	end
	for _, id in raw do
		if type(id) == "string" then
			out = util.ringPush(out, id, MAX_SEEN)
		end
	end
	return out
end

local function decodeReaction(raw: any): T.ReactionRecord?
	if
		util.isDict(raw)
		and util.isFiniteNumber(raw.at)
		and type(raw.id) == "string"
		and animations.isCanonical(raw.animation)
		and type(raw.reason) == "string"
	then
		return {
			at = raw.at,
			id = shortText(raw.id, 64),
			animation = raw.animation,
			reason = shortText(raw.reason, MAX_REASON),
		}
	end
	return nil
end

local function fresh(raw: any, wall_s: number, new_cat_id: () -> string): T.StoreEnvelope
	local env = empty(new_cat_id(), wall_s)
	local oldRev = if util.isDict(raw) then raw.rev else nil
	env.rev = if util.isFiniteNumber(oldRev) and oldRev >= 0 then math.floor(oldRev) + 1 else 1
	journalPush(
		env,
		wall_s,
		"recovery-" .. tostring(wall_s),
		"recovery",
		"Saved state was unreadable; started a fresh cat"
	)
	return env
end

local function decodeUnsafe(raw: any, wall_s: number, new_cat_id: () -> string): (T.StoreEnvelope, boolean, string?)
	if raw == nil then
		return empty(new_cat_id(), wall_s), false, nil
	end
	if not util.isDict(raw) then
		local reason = "saved state is not an object"
		return fresh(raw, wall_s, new_cat_id), true, reason
	end
	if raw.schema_version ~= SCHEMA_VERSION then
		local reason = `unknown saved state version {tostring(raw.schema_version)}`
		return fresh(raw, wall_s, new_cat_id), true, reason
	end
	local profile, note = model.migrate(raw.profile, wall_s)
	if not profile then
		local reason = note or "saved profile is invalid"
		return fresh(raw, wall_s, new_cat_id), true, reason
	end
	local snooze = raw.snooze_until
	return {
		schema_version = SCHEMA_VERSION,
		rev = if util.isFiniteNumber(raw.rev) and raw.rev >= 0 then math.floor(raw.rev) else 0,
		profile = profile,
		journal = decodeJournal(raw.journal),
		seen = decodeSeen(raw.seen),
		last_reaction = decodeReaction(raw.last_reaction),
		snooze_until = if util.isFiniteNumber(snooze) then snooze else nil,
	},
		false,
		note
end

-- Never throws. Corrupt or unknown-version data yields a fresh cat with recovered = true;
-- `note` explains the recovery or lists repaired fields.
local function decode(raw: any, wall_s: number, new_cat_id: () -> string): (T.StoreEnvelope, boolean, string?)
	local ok, env, recovered, note = pcall(decodeUnsafe, raw, wall_s, new_cat_id)
	if ok then
		return env, recovered, note
	end
	local reason = "saved state could not be read"
	return fresh(nil, wall_s, new_cat_id), true, reason
end

-- Time -------------------------------------------------------------------------------------

local function catchUp(env: T.StoreEnvelope, wall_s: number, config: T.Config): T.StoreEnvelope
	if not util.isFiniteNumber(wall_s) then
		return env
	end
	local profile = env.profile
	local nextNeeds = needsMod.catchUp(
		profile.needs,
		profile.last_updated_at,
		wall_s,
		config.needs.offline_hours_cap,
		config.needs.enabled,
		config.needs.offline_progress,
		config.personality
	)
	local mood: T.Mood = needsMod.deriveMood(nextNeeds, config.personality, { fail_streak = profile.fail_streak })
	local snooze = env.snooze_until
	local snoozeExpired = snooze ~= nil and wall_s >= snooze
	local changed = not util.deepEqual(nextNeeds, profile.needs) or mood ~= profile.mood or snoozeExpired
	if not changed and wall_s == profile.last_updated_at then
		return env
	end
	local out = util.deepCopy(env)
	out.profile.needs = nextNeeds
	out.profile.mood = mood
	out.profile.last_updated_at = wall_s
	if snoozeExpired then
		out.snooze_until = nil
	end
	if changed then
		out.rev += 1
	end
	return out
end

-- Events -----------------------------------------------------------------------------------

local function gestureSummary(attrs: T.EventAttributes): string
	local g = attrs.gesture
	if g == "pet" then
		return "Was petted"
	elseif g == "poke" then
		return "Got poked"
	elseif g == "feed" then
		local item: any = attrs.item
		return if util.contains(FOODS, item) then `Ate some {item}` else "Ate a snack"
	elseif g == "play" then
		local toy: any = attrs.toy
		return if util.contains(TOYS, toy) then `Played with the {toy}` else "Played"
	elseif g == "perform" then
		local anim = attrs.animation
		return if animations.isCanonical(anim) then `Performed {anim}` else "Performed a trick"
	end
	return "Gesture"
end

local function validEvent(event: any): boolean
	return util.isDict(event)
		and type(event.event_id) == "string"
		and #event.event_id > 0
		and type(event.type) == "string"
		and util.isDict(event.attributes)
end

-- Applies `event` once. Returns the unchanged envelope and false for duplicates or malformed
-- events. Command statistics must only be fed from host hooks (see docs/architecture.md).
local function applyEvent(env: T.StoreEnvelope, event: T.CatEvent, config: T.Config): (T.StoreEnvelope, boolean)
	if not validEvent(event) or hasSeen(env, event.event_id) then
		return env, false
	end
	local out = util.deepCopy(env)
	local profile = out.profile
	local attrs = event.attributes
	local at = if util.isFiniteNumber(event.time) then event.time else profile.last_updated_at
	local recentGesture: string? = nil

	if event.type == "command_finish" then
		local status = attrs.status
		if util.isFiniteNumber(status) then
			if status ~= 0 then
				profile.fail_streak = math.min(profile.fail_streak + 1, model.MAX_FAIL_STREAK)
			else
				profile.fail_streak = 0
			end
		end
		if attrs.reacted == true then
			profile.stats.command_reactions += 1
		end
	elseif event.type == "gesture" then
		local g = attrs.gesture
		if type(g) == "string" and commands.isGesture(g) then
			recentGesture = g
			if config.needs.enabled then
				local item = if type(attrs.item) == "string" then attrs.item :: string else nil
				profile.needs = needsMod.applyGesture(profile.needs, g :: T.Gesture, item)
			end
			local stat = STAT_BY_GESTURE[g]
			if stat then
				local stats = profile.stats :: any
				stats[stat] += 1
			end
			journalPush(out, at, event.event_id, "gesture", gestureSummary(attrs))
		end
	end

	if not config.needs.enabled then
		profile.needs = needsMod.neutral()
	end
	profile.mood = needsMod.deriveMood(profile.needs, config.personality, {
		gesture = recentGesture,
		fail_streak = profile.fail_streak,
	})
	markSeen(out, event.event_id)
	out.rev += 1
	return out, true
end

-- Intents ----------------------------------------------------------------------------------

export type IntentOptions = {
	-- Wall-clock seconds used for snooze and journal times; defaults to intent.at.
	wall_s: number?,
	-- Required for reset_identity.
	new_cat_id: (() -> string)?,
}

local function configChanges(intent: T.Intent): { [string]: any }?
	local args = intent.args
	if intent.kind == "set_personality" then
		local changes = {}
		for key, value in args do
			changes["personality." .. key] = value
		end
		return changes
	elseif intent.kind == "set_config" then
		return util.deepCopy(args.values)
	elseif intent.kind == "set_overlay" then
		return { ["rendering.overlay"] = args.enabled }
	elseif intent.kind == "rename" then
		return { ["cat.name"] = args.name }
	end
	return nil
end

-- Validates and applies a state-changing intent once. Config-changing intents are returned as
-- `{kind = "config", changes = {[dotted path] = value}}` effects for the host to write into
-- config.json; they never modify the envelope beyond dedupe bookkeeping.
local function applyIntent(
	env: T.StoreEnvelope,
	rawIntent: any,
	config: T.Config,
	opts: IntentOptions?
): (T.StoreEnvelope, { Effect })
	local intent, err = commands.validate(rawIntent)
	if not intent then
		return env, { { kind = "rejected", error = err or "invalid intent" } }
	end
	if hasSeen(env, intent.intent_id) then
		return env, {}
	end
	local o: IntentOptions = opts or {}
	local now = if o.wall_s ~= nil and util.isFiniteNumber(o.wall_s) then o.wall_s :: number else intent.at

	local gestureEvent = commands.toEvent(intent)
	if gestureEvent then
		local out, applied = applyEvent(env, gestureEvent, config)
		return out, if applied then { { kind = "gesture", event = gestureEvent } } else {}
	end

	local changes = configChanges(intent)
	if changes then
		local out = util.deepCopy(env)
		markSeen(out, intent.intent_id)
		out.rev += 1
		return out, { { kind = "config", changes = changes } }
	end

	local kind = intent.kind
	if kind == "reset_identity" and o.new_cat_id == nil then
		return env, { { kind = "rejected", error = "reset_identity requires a cat id generator" } }
	end

	local out = util.deepCopy(env)
	local effect: Effect
	if kind == "snooze" then
		local minutes = intent.args.minutes :: number
		out.snooze_until = now + minutes * 60
		journalPush(out, now, intent.intent_id, "snooze", `Snoozed for {minutes} minutes`)
		effect = { kind = "snooze", until_s = out.snooze_until }
	elseif kind == "unsnooze" then
		out.snooze_until = nil
		journalPush(out, now, intent.intent_id, "snooze", "Woke up from a snooze")
		effect = { kind = "unsnooze" }
	elseif kind == "reset_identity" then
		local previous = out.profile.cat_id
		local newId = (o.new_cat_id :: () -> string)()
		out.profile = model.newProfile(newId, now)
		out.journal = {}
		out.last_reaction = nil
		out.snooze_until = nil
		journalPush(out, now, intent.intent_id, "identity", "A new cat moved in")
		effect = { kind = "reset_identity", cat_id = newId, previous_cat_id = previous }
	elseif kind == "export_identity" then
		effect = { kind = "export_identity", profile = util.deepCopy(env.profile) }
	elseif kind == "clear_ai_state" then
		local kept: { T.JournalEntry } = {}
		for _, entry in out.journal do
			if entry.kind ~= "ai" then
				table.insert(kept, entry)
			end
		end
		out.journal = kept
		effect = { kind = "clear_ai_state" }
	else
		return env, { { kind = "rejected", error = `intent {kind} is not handled by the store` } }
	end
	markSeen(out, intent.intent_id)
	out.rev += 1
	return out, { effect }
end

-- Reactions --------------------------------------------------------------------------------

local function recordReaction(env: T.StoreEnvelope, decision: T.BehaviorDecision, wall_s: number): T.StoreEnvelope
	local out = util.deepCopy(env)
	local reason = shortText(if type(decision.reason) == "string" then decision.reason else "", MAX_REASON)
	out.last_reaction = {
		at = wall_s,
		id = shortText(decision.id, 64),
		animation = decision.animation,
		reason = reason,
	}
	local summary = if #reason > 0 then `{decision.animation}: {reason}` else decision.animation
	journalPush(out, wall_s, `reaction-{wall_s}`, "reaction", summary)
	out.rev += 1
	return out
end

return {
	SCHEMA_VERSION = SCHEMA_VERSION,
	MAX_JOURNAL = MAX_JOURNAL,
	MAX_SEEN = MAX_SEEN,
	empty = empty,
	decode = decode,
	catchUp = catchUp,
	applyEvent = applyEvent,
	applyIntent = applyIntent,
	recordReaction = recordReaction,
	isSnoozed = isSnoozed,
	hasSeen = hasSeen,
}
