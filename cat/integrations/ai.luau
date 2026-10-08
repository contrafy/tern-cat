--!strict
-- Opt-in AI reactions: provider interface, turn budget, redaction and response allowlist.
-- Providers only ever see a redacted summary; their output is validated before use.

local T = require("../types")
local animations = require("../render/animations")

local HOUR_S = 3600
local DAY_S = 24 * HOUR_S
local MAX_HISTORY = 128
local MAX_SUMMARY = 160
local MAX_TEXT = 80
local MAX_WORD = 16
local MAX_ERROR = 80

local CATEGORIES: { [string]: boolean } = {
	test = true,
	build = true,
	vcs = true,
	list = true,
	sudo = true,
	editor = true,
	network = true,
	package = true,
	other = true,
}
local GESTURES: { [string]: boolean } = { pet = true, poke = true, feed = true, play = true, perform = true }
local PANE_KINDS: { [string]: boolean } = { created = true, closed = true, exited = true }
local ELIGIBLE: { [string]: boolean } = {
	command_start = true,
	command_finish = true,
	gesture = true,
	pane = true,
	idle = true,
	focus = true,
	cwd = true,
}
local URL_TLDS: { [string]: boolean } = {
	com = true,
	net = true,
	org = true,
	io = true,
	dev = true,
	ai = true,
	co = true,
	sh = true,
	app = true,
	xyz = true,
	me = true,
	ly = true,
	gg = true,
	info = true,
	biz = true,
	us = true,
	uk = true,
	de = true,
	ru = true,
	cn = true,
	link = true,
	site = true,
	online = true,
	top = true,
}

local DEFAULT_ALLOWED: { T.Animation } = {
	"happy",
	"blink",
	"look",
	"stretch",
	"groom",
	"sit",
	"stare",
	"play",
	"disappointed",
	"hop",
}

local CARLY_UNAVAILABLE = "Disabled: Tern 0.6.2 offers no constrained or hidden completion route. "
	.. "Scheduled Carly turns run with full tool access (commands, input), so tern-cat will not start them."

export type Budget = { history: { number } }

export type LastAiReaction = {
	at: number,
	summary: string,
	outcome: "applied" | "rejected" | "error",
	animation: T.Animation?,
	text: string?,
	reason: string,
}

export type AiState = {
	budget: Budget,
	pending: boolean,
	last: LastAiReaction?,
}

export type AiContext = {
	now_s: number,
	config: T.Config,
	mood: T.Mood,
	allowed: { T.Animation }?,
}

export type MockResponse = { suggestion: any?, err: string? }
export type MockProvider = T.AiProviderImpl & { requests: { T.AiRequest } }

-- Budget ----------------------------------------------------------------------------------

local function newBudget(): Budget
	return { history = {} }
end

local function countWithin(history: { number }, now_s: number, window_s: number): number
	local n = 0
	for _, at in history do
		if now_s - at < window_s then
			n += 1
		end
	end
	return n
end

local function canRequest(budget: Budget, now_s: number, config: T.Config): (boolean, string)
	local ai = config.ai
	if not ai.enabled then
		return false, "AI is disabled"
	end
	if ai.max_turns_per_hour <= 0 or ai.max_turns_per_day <= 0 then
		return false, "AI turn budget is zero"
	end
	local history = budget.history
	local last = history[#history]
	if last ~= nil and now_s - last < ai.cooldown_s then
		return false, `AI cooldown: {math.ceil(ai.cooldown_s - (now_s - last))}s left`
	end
	if countWithin(history, now_s, HOUR_S) >= ai.max_turns_per_hour then
		return false, "AI turns for this hour are used up"
	end
	if countWithin(history, now_s, DAY_S) >= ai.max_turns_per_day then
		return false, "AI turns for this day are used up"
	end
	return true, "ok"
end

local function record(budget: Budget, now_s: number): Budget
	local kept = {}
	for _, at in budget.history do
		if now_s - at < DAY_S then
			table.insert(kept, at)
		end
	end
	table.insert(kept, now_s)
	while #kept > MAX_HISTORY do
		table.remove(kept, 1)
	end
	return { history = kept }
end

-- Redaction -------------------------------------------------------------------------------

local function durationBucket(ms: any): string
	if type(ms) ~= "number" or ms ~= ms then
		return "an unknown time"
	end
	if ms < 1000 then
		return "under a second"
	elseif ms < 10000 then
		return "a few seconds"
	elseif ms < 60000 then
		return "under a minute"
	elseif ms < 600000 then
		return "a few minutes"
	end
	return "a long time"
end

local function idleBucket(seconds: any): string
	if type(seconds) ~= "number" or seconds ~= seconds then
		return "a while"
	end
	return durationBucket(seconds * 1000)
end

local function cap(s: string, limit: number): string
	if #s <= limit then
		return s
	end
	return string.sub(s, 1, limit)
end

local function redactText(text: string): string
	local kept = {}
	local len = 0
	for token in string.gmatch(text, "%S+") do
		local word = string.match(token, "^(%a+)[%.,!%?]?$") or string.match(token, "^(%d%d?%d?%d?)[%.,]?$")
		if word and #word <= MAX_WORD then
			if len + #token + 1 > MAX_SUMMARY then
				break
			end
			table.insert(kept, token)
			len += #token + 1
		end
	end
	return cap(table.concat(kept, " "), MAX_SUMMARY)
end

local function categoryOf(attrs: { [string]: any }): string
	local c = attrs.category
	return if type(c) == "string" and CATEGORIES[c] then c else "other"
end

local function redactEvent(ev: { [string]: any }): string
	local attrs = if type(ev.attributes) == "table" then ev.attributes else {}
	local kind = ev.type
	if kind == "command_finish" then
		local outcome = if attrs.ok == true then "succeeded" else "failed"
		return `A {categoryOf(attrs)} command {outcome} after {durationBucket(attrs.took_ms)}.`
	elseif kind == "command_start" then
		return `A {categoryOf(attrs)} command started.`
	elseif kind == "gesture" then
		local g = attrs.gesture
		return if type(g) == "string" and GESTURES[g] then `The user chose: {g}.` else "The user interacted."
	elseif kind == "pane" then
		local k = attrs.kind
		return if type(k) == "string" and PANE_KINDS[k] then `A pane was {k}.` else "A pane changed."
	elseif kind == "idle" then
		return `The user has been idle for {idleBucket(attrs.seconds)}.`
	elseif kind == "focus" then
		return "Focus changed."
	elseif kind == "cwd" then
		return "The working directory changed."
	end
	return "Something happened."
end

local function redact(input: T.CatEvent | string): string
	if type(input) == "string" then
		return redactText(input)
	end
	if type(input) == "table" then
		return redactEvent(input :: any)
	end
	return "Something happened."
end

-- Response allowlist ----------------------------------------------------------------------

local function containsUrl(text: string): boolean
	local lower = string.lower(text)
	if string.find(lower, "://", 1, true) or string.find(lower, "www.", 1, true) then
		return true
	end
	for tld in string.gmatch(lower, "[%w%-]%.(%a+)") do
		if URL_TLDS[tld] then
			return true
		end
	end
	return false
end

local function validateText(raw: any): (string?, string?)
	if raw == nil then
		return nil, nil
	end
	if type(raw) ~= "string" then
		return nil, "text must be a string"
	end
	local text = string.match(raw, "^%s*(.-)%s*$") or ""
	if #text > MAX_TEXT then
		return nil, "text is too long"
	end
	if string.find(text, "[^\32-\126]") then
		return nil, "text contains unprintable characters"
	end
	if containsUrl(text) then
		return nil, "text contains a link"
	end
	return text, nil
end

local function validateSuggestion(raw: any, allowed: { T.Animation }): (T.AiSuggestion?, string?)
	if type(raw) ~= "table" then
		return nil, "response is not an object"
	end
	for k in raw do
		if k ~= "animation" and k ~= "text" then
			return nil, "response has unexpected fields"
		end
	end
	local anim = raw.animation
	if not animations.isCanonical(anim) or not table.find(allowed, anim) then
		return nil, "animation is not allowed"
	end
	local text, err = validateText(raw.text)
	if err then
		return nil, err
	end
	local out: T.AiSuggestion = { animation = anim }
	if text and #text > 0 then
		out.text = text
	end
	return out, nil
end

-- Providers -------------------------------------------------------------------------------

local function mockProvider(responses: { MockResponse }): MockProvider
	local queue = table.clone(responses)
	local provider = {
		id = "mock" :: T.AiProvider,
		available = true,
		unavailable_reason = nil :: string?,
		requests = {} :: { T.AiRequest },
	}
	function provider.request(self: any, req: T.AiRequest, done: (any?, string?) -> ())
		table.insert(self.requests, req)
		local next = table.remove(queue, 1)
		if next == nil then
			done(nil, "mock provider has no responses left")
			return
		end
		done(next.suggestion, next.err)
	end
	return provider :: any
end

local function unavailable(id: T.AiProvider, reason: string): T.AiProviderImpl
	return {
		id = id,
		available = false,
		unavailable_reason = reason,
		request = function(_: T.AiProviderImpl, _req: T.AiRequest, done: (any?, string?) -> ())
			done(nil, reason)
		end,
	}
end

local function carlyScheduleProvider(): T.AiProviderImpl
	return unavailable("carly_schedule", CARLY_UNAVAILABLE)
end

local function noneProvider(): T.AiProviderImpl
	return unavailable("none", "AI provider is set to none.")
end

-- Orchestration ---------------------------------------------------------------------------

local function newState(): AiState
	return { budget = newBudget(), pending = false, last = nil }
end

local function lastAiReaction(state: AiState): LastAiReaction?
	return state.last
end

local function cleanError(err: any): string
	local s = if type(err) == "string" then err else "unknown error"
	return cap((string.gsub(s, "[^\32-\126]", "")), MAX_ERROR)
end

-- Calls `done(state, suggestion?, reason)` exactly once and returns the most recent state
-- (already final when the provider answered synchronously).
local function suggest(
	state: AiState,
	event: T.CatEvent,
	ctx: AiContext,
	provider: T.AiProviderImpl,
	done: (state: AiState, suggestion: T.AiSuggestion?, reason: string) -> ()
): AiState
	if type(event) ~= "table" or not ELIGIBLE[event.type] then
		done(state, nil, "event type is not eligible for AI")
		return state
	end
	if not ctx.config.ai.enabled then
		done(state, nil, "AI is disabled")
		return state
	end
	if not provider.available then
		done(state, nil, provider.unavailable_reason or "AI provider is unavailable")
		return state
	end
	if state.pending then
		done(state, nil, "an AI request is already in flight")
		return state
	end
	local ok, why = canRequest(state.budget, ctx.now_s, ctx.config)
	if not ok then
		done(state, nil, why)
		return state
	end

	local summary = redact(event)
	local allowed = ctx.allowed or DEFAULT_ALLOWED
	local pendingState: AiState = { budget = record(state.budget, ctx.now_s), pending = true, last = state.last }
	local latest = pendingState
	local finished = false

	local function finish(suggestion: T.AiSuggestion?, outcome: "applied" | "rejected" | "error", reason: string)
		if finished then
			return
		end
		finished = true
		latest = {
			budget = pendingState.budget,
			pending = false,
			last = {
				at = ctx.now_s,
				summary = summary,
				outcome = outcome,
				animation = if suggestion then suggestion.animation else nil,
				text = if suggestion then suggestion.text else nil,
				reason = reason,
			},
		}
		done(latest, suggestion, reason)
	end

	local request: T.AiRequest = {
		summary = summary,
		mood = ctx.mood,
		allowed_animations = table.clone(allowed),
	}
	local function onResponse(raw: any?, err: string?)
		if finished then
			return
		end
		if err ~= nil then
			finish(nil, "error", `AI provider error: {cleanError(err)}`)
			return
		end
		local suggestion, invalid = validateSuggestion(raw, allowed)
		if suggestion == nil then
			finish(nil, "rejected", `Rejected AI response: {invalid}`)
			return
		end
		finish(suggestion, "applied", `AI suggested {suggestion.animation} after: {summary}`)
	end
	local called, callErr = pcall(function()
		provider:request(request, onResponse)
	end)
	if not called then
		finish(nil, "error", `AI provider error: {cleanError(callErr)}`)
	end
	return latest
end

return {
	MAX_HISTORY = MAX_HISTORY,
	MAX_SUMMARY = MAX_SUMMARY,
	MAX_TEXT = MAX_TEXT,
	DEFAULT_ALLOWED = DEFAULT_ALLOWED,
	newBudget = newBudget,
	canRequest = canRequest,
	record = record,
	redact = redact,
	validateSuggestion = validateSuggestion,
	mockProvider = mockProvider,
	carlyScheduleProvider = carlyScheduleProvider,
	noneProvider = noneProvider,
	newState = newState,
	lastAiReaction = lastAiReaction,
	suggest = suggest,
}
