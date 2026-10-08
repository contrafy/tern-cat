--!strict
-- Carly integration (window half): export definitions, argument-to-intent mapping and the small,
-- private views Carly may see (status, explain, AI status, request context). Pure; the window
-- entry registers the exports and routes intents through cat/window/intents.luau.
--
-- Nothing here ever returns command text, terminal output, paths or journal summaries.

local T = require("../types")
local util = require("../core/util")
local ai = require("./ai")

-- `arity` is the number of positional arguments before the trailing (cx, call).
export type ExportDef = { name: string, sig: string, doc: string, arity: number? }

export type Snapshot = {
	envelope: T.StoreEnvelope,
	config: T.Config,
	overlay_visible: boolean,
	now_s: number,
	-- This window's current overlay decision, if any.
	current: T.BehaviorDecision?,
}

export type ReactionView = { animation: T.Animation, reason: string, ago_s: number }

local CONTEXT_MAX = 160
local NAME_MAX = 32
local RESULT = "{ok: boolean, error: string?}"

local EXPORTS: { ExportDef } = {
	{
		name = "status",
		sig = "function(cx, call): {ok: boolean, name: string, mood: string, needs: {hunger: number, energy: number, affection: number, boredom: number}, stats: {pets: number, pokes: number, feeds: number, plays: number, command_reactions: number}, appearance: string, overlay: boolean, snoozed: boolean, last_reaction: {animation: string, reason: string, ago_s: number}?}",
		doc = "The Tern Cat's current state: name, mood, needs (0..1; hunger 1 = very hungry, energy 1 = rested), lifetime gesture stats, appearance, whether this window's overlay cat is visible, snooze state and the most recent reaction with its reason. Never includes command text or paths.",
	},
	{
		name = "pet",
		sig = `function(cx, call): {RESULT}`,
		doc = "Pet the cat (raises affection). Applied by the cat's host within about a second.",
	},
	{
		name = "poke",
		sig = `function(cx, call): {RESULT}`,
		doc = "Poke the cat. It may be startled.",
	},
	{
		name = "feed",
		sig = `function(item: ("treat" | "kibble" | "fish")?, cx, call): {RESULT}`,
		doc = 'Feed the cat. item is "treat", "kibble" (default) or "fish".',
	},
	{
		name = "play",
		sig = `function(toy: ("ball" | "string" | "feather")?, cx, call): {RESULT}`,
		doc = 'Play with the cat. toy is "ball" (default), "string" or "feather".',
	},
	{
		name = "perform",
		sig = `function(animation: string, cx, call): {RESULT}`,
		doc = "Ask the cat to play one animation: idle, walk, sit, sleep, wake, stretch, groom, blink, look, pet, poke, eat, play, happy, disappointed, swat, startled, flop, stare or hop.",
	},
	{
		name = "set_personality",
		sig = `function(values: \{curiosity: number?, affection: number?, mischief: number?, energy: number?, talkativeness: number?}, cx, call): {RESULT}`,
		doc = "Adjust personality traits (each 0..1, clamped). Written to the user's config.json.",
	},
	{
		name = "configure",
		sig = `function(key: string, value: any, cx, call): {RESULT}`,
		doc = "Change one safe setting. Allowed keys: behavior.activity (quiet_office, orange_menace, chaos, zen), behavior.allow_visual_obscuring, behavior.allow_swats, behavior.allow_command_reactions, behavior.allow_development_reactions, behavior.allow_pane_reactions, behavior.allow_idle_sleep, behavior.allow_pacing, behavior.allow_pointer_reactions (false only: you can stop the overlay cat reacting to the pointer, never turn it back on), behavior.focus_mode (true only: the cat keeps still while commands run), rendering.overlay, rendering.reduced_motion (follow_tern, on, off), needs.enabled, sound.enabled (false only: you can mute the cat, never unmute it), quiet.hours_enabled (true only). Sound volume and the quiet-hours times can only be changed by the user. Requests are rate limited.",
	},
	{
		name = "snooze",
		sig = `function(minutes: number?, cx, call): {RESULT}`,
		doc = "Snooze the cat (it sleeps and stops reacting) for 1..480 whole minutes; default 30.",
	},
	{
		name = "wake",
		sig = `function(cx, call): {RESULT}`,
		doc = "End a snooze early.",
	},
	{
		name = "explain",
		sig = "function(cx, call): {ok: boolean, last_reaction: {animation: string, reason: string, ago_s: number}?, overlay: {animation: string, reason: string}?, note: string?}",
		doc = "Why the cat is doing what it does: the most recent reaction and its reason, plus what this window's overlay cat is doing now.",
	},
	{
		name = "ai_status",
		sig = "function(cx, call): {ok: boolean, enabled: boolean, provider: string, unavailable_reason: string?}",
		doc = "Whether the cat's optional autonomous AI is enabled. In this version it is always off; ordinary behavior never needs AI.",
	},
}

local ARITY: { [string]: number } = {
	feed = 1,
	play = 1,
	perform = 1,
	set_personality = 1,
	snooze = 1,
	configure = 2,
}
for _, def in EXPORTS do
	def.arity = ARITY[def.name] or 0
end

local NO_ARGS: { [string]: T.IntentKind } = {
	pet = "pet",
	poke = "poke",
	wake = "unsnooze",
}

-- Maps an export call to (intent kind, raw args). Read-only exports return nothing; argument
-- shapes that cannot become an intent return an error. Values are validated by commands.validate.
local function toIntent(name: string, a: any, b: any): (T.IntentKind?, { [string]: any }?, string?)
	local simple = NO_ARGS[name]
	if simple then
		return simple :: T.IntentKind, {}, nil
	elseif name == "feed" then
		return "feed", { item = a }, nil
	elseif name == "play" then
		return "play", { toy = a }, nil
	elseif name == "perform" then
		return "perform", { animation = a }, nil
	elseif name == "snooze" then
		return "snooze", { minutes = a }, nil
	elseif name == "set_personality" then
		if not util.isDict(a) then
			return nil, nil, "values must be an object of personality traits"
		end
		return "set_personality", util.deepCopy(a), nil
	elseif name == "configure" then
		if type(a) ~= "string" then
			return nil, nil, "key must be a string"
		end
		return "set_config", { key = a, value = b }, nil
	end
	return nil, nil, nil
end

local function round2(x: number): number
	return math.floor(x * 100 + 0.5) / 100
end

local function cleanName(name: any): string
	local s = if type(name) == "string" then util.stripControl(name) else ""
	s = string.gsub(s, '["\\]', "")
	if utf8.len(s) == nil then
		s = string.gsub(s, "[\128-\255]", "")
	end
	if #s > NAME_MAX then
		s = string.sub(s, 1, NAME_MAX)
		while #s > 0 and utf8.len(s) == nil do
			s = string.sub(s, 1, -2)
		end
	end
	return if s == "" then "Cat" else s
end

local function snoozed(snap: Snapshot): boolean
	local untilS = snap.envelope.snooze_until
	return untilS ~= nil and snap.now_s < untilS
end

local function reactionView(snap: Snapshot): ReactionView?
	local r = snap.envelope.last_reaction
	if r == nil then
		return nil
	end
	return {
		animation = r.animation,
		reason = r.reason,
		ago_s = math.max(0, math.floor(snap.now_s - r.at)),
	}
end

local function status(snap: Snapshot): { [string]: any }
	local profile = snap.envelope.profile
	local needs = profile.needs
	local stats = profile.stats
	return {
		ok = true,
		name = cleanName(snap.config.cat.name),
		mood = profile.mood,
		needs = {
			hunger = round2(needs.hunger),
			energy = round2(needs.energy),
			affection = round2(needs.affection),
			boredom = round2(needs.boredom),
		},
		stats = {
			pets = stats.pets,
			pokes = stats.pokes,
			feeds = stats.feeds,
			plays = stats.plays,
			command_reactions = stats.command_reactions,
		},
		appearance = snap.config.cat.appearance,
		overlay = snap.overlay_visible,
		snoozed = snoozed(snap),
		last_reaction = reactionView(snap),
	}
end

local function explain(snap: Snapshot): { [string]: any }
	local last = reactionView(snap)
	local current = snap.current
	return {
		ok = true,
		last_reaction = last,
		overlay = if current then { animation = current.animation, reason = current.reason } else nil,
		note = if last == nil then "No reactions recorded yet." else nil,
	}
end

local function aiStatus(config: T.Config): { [string]: any }
	local provider = config.ai.provider
	local reason: string
	if not config.ai.enabled then
		reason = "AI is turned off (ai.enabled = false); the cat works fully offline."
	elseif provider == "carly_schedule" then
		reason = ai.carlyScheduleProvider().unavailable_reason or "Carly scheduling is unavailable."
	elseif provider == "none" then
		reason = ai.noneProvider().unavailable_reason or "AI provider is set to none."
	else
		reason = "The mock provider is only used by tests."
	end
	return { ok = true, enabled = false, provider = provider, unavailable_reason = reason }
end

local function context(snap: Snapshot): string
	local profile = snap.envelope.profile
	local parts = {
		`Tern Cat "{cleanName(snap.config.cat.name)}": {profile.mood}`,
		`hunger {round2(profile.needs.hunger)} energy {round2(profile.needs.energy)}`,
		`{profile.stats.pets} pets`,
	}
	if snoozed(snap) then
		table.insert(parts, "snoozed")
	end
	if not snap.overlay_visible then
		table.insert(parts, "overlay hidden")
	end
	local s = table.concat(parts, "; ")
	if #s > CONTEXT_MAX then
		s = string.sub(s, 1, CONTEXT_MAX)
	end
	return s
end

return {
	CONTEXT_MAX = CONTEXT_MAX,
	EXPORTS = EXPORTS,
	toIntent = toIntent,
	status = status,
	explain = explain,
	aiStatus = aiStatus,
	context = context,
}
