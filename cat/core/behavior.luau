--!strict
-- Behavior decision policy: a weighted FSM over EngineState. Pure: callers inject time,
-- rng, config, profile and environment through DecideContext.
--
-- Precedence (highest first): snooze, quiet hours, reduced motion, allow_* toggles,
-- activity preset and personality. A sleeping cat only leaves sleep through `wake`.

local T = require("../types")
local animations = require("../render/animations")

local MAX_FAIL_STREAK = 20
local FLOP_STREAK = 3
local MIN_REACTION_GAP_MS = 1000
local LOW_ENERGY = 0.25
local RESTED_ENERGY = 0.8
local NATURAL_WAKE_CHANCE = 0.25
local MIN_INACTIVE_MS = 2 * 60 * 1000
local MAX_INACTIVE_MS = 10 * 60 * 1000
local MAX_REASON = 80

local LOOP_RANGES_MS: { [string]: { number } } = {
	idle = { 4000, 10000 },
	sit = { 6000, 15000 },
	sleep = { 30000, 90000 },
	walk = { 3000, 6000 },
}

local AMBIENT_REASONS: { [string]: string } = {
	idle = "Just hanging out.",
	sit = "Taking a seat.",
	groom = "Grooming.",
	blink = "Slow blink.",
	stretch = "Stretching.",
	look = "Something caught its eye.",
	walk = "Pacing around.",
	sleep = "Feeling drowsy; taking a nap.",
	swat = "Feeling mischievous.",
	hop = "Burst of energy.",
}

local QUIET_REASONS: { [string]: string } = {
	sleep = "Quiet hours; sleeping.",
	blink = "Quiet hours; a slow blink.",
	groom = "Quiet hours; grooming quietly.",
}

local ACTIVITY_MULTIPLIERS: { [string]: { [string]: number } } = {
	quiet_office = { swat = 0.2, hop = 0.2, walk = 0.3, look = 0.7 },
	orange_menace = {},
	chaos = { swat = 3, hop = 3, walk = 2, look = 1.5 },
	zen = { sleep = 3, sit = 2, swat = 0.2, hop = 0.2, walk = 0.3 },
}

local MOOD_MULTIPLIERS: { [string]: { [string]: number } } = {
	calm = { idle = 1.3, sit = 1.2 },
	playful = { swat = 1.6, hop = 1.6, walk = 1.6 },
	sleepy = { sleep = 3, sit = 1.5 },
	annoyed = { groom = 2, look = 1.2 },
	curious = { look = 2, walk = 1.3 },
	happy = { blink = 1.5, stretch = 1.3 },
}

-- Animations that read as large motion; replaced under reduced motion.
local HIGH_MOTION: { [string]: boolean } = { walk = true, hop = true, startled = true }

local ACTIVITY_TYPES: { [string]: boolean } = {
	command_start = true,
	command_finish = true,
	focus = true,
	gesture = true,
	pane = true,
	cwd = true,
	pointer = true,
}

type Ctx = T.DecideContext
type Decision = T.BehaviorDecision
type Extra = { sound: T.SoundId? }

local function clamp01(x: number): number
	if x ~= x then
		return 0
	end
	return math.clamp(x, 0, 1)
end

local function capReason(reason: string): string
	return if #reason <= MAX_REASON then reason else string.sub(reason, 1, MAX_REASON)
end

local function isGestureRelated(id: string): boolean
	return string.find(id, "gesture.", 1, true) ~= nil
end

local function durationFor(anim: string, ctx: Ctx): number
	local range = LOOP_RANGES_MS[anim]
	if range then
		return ctx.rng:int(range[1], range[2])
	end
	return animations.defaultDurationMs(anim)
end

local function baseIntensity(ctx: Ctx): number
	local energy = clamp01(ctx.config.personality.energy)
	local needs_energy = clamp01(ctx.profile.needs.energy)
	return clamp01(0.35 + 0.65 * energy * (0.5 + 0.5 * needs_energy))
end

local function decide(id: string, anim: T.Animation, reason: string, ctx: Ctx, extra: Extra?): Decision
	return {
		id = id,
		animation = anim,
		intensity = baseIntensity(ctx),
		duration_ms = durationFor(anim, ctx),
		overlay_only = if anim == "walk" then true else nil,
		sound = if extra then extra.sound else nil,
		reason = capReason(reason),
	}
end

-- Applies environment and toggle constraints that hold for every decision, whenever it plays.
local function finalize(d: Decision, ctx: Ctx): Decision
	local env = ctx.env
	local b = ctx.config.behavior
	local anim: T.Animation = d.animation
	if env.reduced_motion and HIGH_MOTION[anim] then
		anim = "look"
	end
	if anim == "walk" and not b.allow_pacing then
		anim = "look"
	end
	if anim == "swat" and not b.allow_swats then
		anim = "play"
	end
	local out = table.clone(d)
	if anim ~= d.animation then
		out.animation = anim
		out.duration_ms = animations.defaultDurationMs(anim)
		if out.sound == "swat" or out.sound == "surprise" then
			out.sound = nil
		end
	end
	out.overlay_only = if anim == "walk" then true else nil
	if env.reduced_motion then
		out.intensity = 0
	end
	if env.quiet_hours then
		out.sound = nil
	end
	return out
end

local function familyAllowed(id: string, b: any): boolean
	if string.find(id, "react.pane", 1, true) then
		return b.allow_pane_reactions
	end
	if string.find(id, "react.fail_streak", 1, true) then
		return b.allow_command_reactions and b.allow_development_reactions
	end
	if string.find(id, "react.ls_swat", 1, true) then
		return b.allow_command_reactions and b.allow_development_reactions and b.allow_swats
	end
	if string.find(id, "react.command", 1, true) or string.find(id, "react.sudo", 1, true) then
		return b.allow_command_reactions
	end
	return true
end

local function apply(state: T.EngineState, d: Decision, ctx: Ctx): (T.EngineState, Decision)
	local final = finalize(d, ctx)
	local s = table.clone(state)
	if state.posture == "asleep" and final.animation ~= "sleep" and final.animation ~= "wake" then
		local reason = if isGestureRelated(final.id) then "Woke up to respond to you." else `Woke up: {final.reason}`
		s.pending = final
		final = finalize(decide(`wake.{final.id}`, "wake", reason, ctx), ctx)
	else
		s.pending = nil
	end
	s.posture = if final.animation == "sleep" then "asleep" else "awake"
	s.current = final
	s.started_ms = ctx.now_ms
	s.until_ms = ctx.now_ms + final.duration_ms
	return s, final
end

local function markTrigger(state: T.EngineState, trigger: string, now_ms: number): T.EngineState
	local s = table.clone(state)
	local triggers = table.clone(state.last_by_trigger)
	triggers[trigger] = now_ms
	s.last_by_trigger = triggers
	return s
end

local function ready(state: T.EngineState, trigger: string, ctx: Ctx): boolean
	local last = state.last_by_trigger[trigger]
	if last == nil then
		return true
	end
	local gap = math.max(ctx.config.behavior.reaction_cooldown_s * 1000, MIN_REACTION_GAP_MS)
	return ctx.now_ms - last >= gap
end

local function inactivityThresholdMs(ctx: Ctx): number
	local energy = clamp01(ctx.config.personality.energy) * 0.6 + clamp01(ctx.profile.needs.energy) * 0.4
	return MIN_INACTIVE_MS + (MAX_INACTIVE_MS - MIN_INACTIVE_MS) * energy
end

-- Ambient ---------------------------------------------------------------------------------

local function ambientWeights(ctx: Ctx): { [string]: number }
	local p = ctx.config.personality
	local needs = ctx.profile.needs
	local b = ctx.config.behavior
	local env = ctx.env
	local boredom = clamp01(needs.boredom)
	local w: { [string]: number } = {
		idle = 3,
		sit = 2,
		groom = 1.2,
		blink = 1.5,
		stretch = 0.6 + 0.6 * clamp01(p.energy),
		look = 0.8 + 2 * clamp01(p.curiosity),
	}
	if b.allow_pacing and not env.reduced_motion then
		w.walk = 0.3 + 1.5 * clamp01(p.energy) * (0.5 + boredom)
	end
	if b.allow_idle_sleep then
		w.sleep = math.max(0, 0.9 - clamp01(needs.energy)) * 4
	end
	if b.allow_swats then
		local m = clamp01(p.mischief) * (0.5 + boredom)
		w.swat = 1.2 * m
		if not env.reduced_motion then
			w.hop = 0.8 * m
		end
	end
	local multiplier_sets: { { [string]: number } } =
		{ ACTIVITY_MULTIPLIERS[b.activity] or {}, MOOD_MULTIPLIERS[ctx.profile.mood] or {} }
	for _, multipliers in multiplier_sets do
		for name, factor in multipliers do
			if w[name] then
				w[name] *= factor
			end
		end
	end
	return w
end

local function chooseAmbient(state: T.EngineState, ctx: Ctx): (Decision, string?)
	local env = ctx.env
	local b = ctx.config.behavior
	local needs = ctx.profile.needs
	local rng = ctx.rng
	local idle_ms = ctx.now_ms - state.last_activity_ms
	local away = idle_ms >= inactivityThresholdMs(ctx)

	if env.snoozed then
		return decide("ambient.snoozed", "sleep", "Snoozed.", ctx)
	end
	if state.posture == "asleep" then
		if env.quiet_hours then
			return decide("ambient.quiet", "sleep", QUIET_REASONS.sleep, ctx)
		end
		if not b.allow_idle_sleep then
			return decide("ambient.wake", "wake", "Idle naps are turned off.", ctx)
		end
		if not away and needs.energy >= RESTED_ENERGY and rng:chance(NATURAL_WAKE_CHANCE) then
			return decide("ambient.wake", "wake", "Done napping.", ctx)
		end
		return decide("ambient.sleep", "sleep", if away then "You've been away; still napping." else "Napping.", ctx)
	end
	if env.quiet_hours then
		local pick: T.Animation = (rng:weighted({ sleep = 4, blink = 1, groom = 1 }) or "sleep") :: any
		return decide("ambient.quiet", pick, QUIET_REASONS[pick], ctx)
	end
	if b.allow_idle_sleep and needs.energy < LOW_ENERGY then
		return decide("ambient.tired", "sleep", "Low on energy; taking a nap.", ctx)
	end
	if b.allow_idle_sleep and away then
		local settled = state.last_by_trigger["ambient.settle"]
		if settled ~= nil and settled >= state.last_activity_ms then
			return decide("ambient.inactive_sleep", "sleep", "You've been away a while; napping.", ctx)
		end
		local pick: T.Animation = (rng:weighted({ groom = 1, stretch = 1 }) or "groom") :: any
		return decide("ambient.settle", pick, "You've been away a while; settling down.", ctx), "ambient.settle"
	end

	local pick: T.Animation = (rng:weighted(ambientWeights(ctx)) or "idle") :: any
	if pick == "look" and needs.hunger >= 0.6 and rng:chance(clamp01(ctx.config.personality.talkativeness)) then
		return decide("ambient.look", "look", "Getting peckish.", ctx, { sound = "meow" })
	end
	return decide(`ambient.{pick}`, pick, AMBIENT_REASONS[pick], ctx)
end

-- Reactions -------------------------------------------------------------------------------

local function gestureDecision(attrs: T.EventAttributes, ctx: Ctx): Decision?
	local g = attrs.gesture
	local p = ctx.config.personality
	local rng = ctx.rng
	if g == "pet" then
		return decide("gesture.pet", "pet", "You petted the cat.", ctx, { sound = "purr" })
	elseif g == "poke" then
		if rng:chance(0.25 + 0.5 * (1 - clamp01(p.affection))) then
			return decide("gesture.poke", "startled", "You poked the cat.", ctx, { sound = "surprise" })
		end
		return decide("gesture.poke", "poke", "You poked the cat.", ctx)
	elseif g == "feed" then
		return decide("gesture.feed", "eat", "You fed the cat.", ctx, { sound = "happy" })
	elseif g == "play" then
		if ctx.config.behavior.allow_swats and rng:chance(0.3 + 0.5 * clamp01(p.mischief)) then
			return decide("gesture.play", "swat", "You played with the cat.", ctx, { sound = "swat" })
		end
		return decide("gesture.play", "play", "You played with the cat.", ctx)
	elseif g == "perform" then
		local anim = attrs.animation
		if not animations.isCanonical(anim) then
			return nil
		end
		return decide("gesture.perform", anim :: any, `You asked for {anim}.`, ctx)
	end
	return nil
end

local function commandFinishDecision(state: T.EngineState, attrs: T.EventAttributes, ctx: Ctx): (Decision?, string?)
	local b = ctx.config.behavior
	if not b.allow_command_reactions then
		return nil
	end
	local rng = ctx.rng
	local p = ctx.config.personality
	local rate = clamp01(b.reaction_sample_rate)
	local category = attrs.category
	local ok = attrs.ok == true

	if
		category == "test"
		and not ok
		and b.allow_development_reactions
		and state.fail_streak >= FLOP_STREAK
		and ready(state, "react.fail_streak", ctx)
	then
		return decide("react.fail_streak", "flop", "Several test runs failed in a row.", ctx), "react.fail_streak"
	end
	if
		category == "list"
		and ok
		and b.allow_swats
		and b.allow_development_reactions
		and ready(state, "react.ls_swat", ctx)
		and rng:chance(rate * (0.5 + clamp01(p.mischief)))
	then
		return decide("react.ls_swat", "swat", "A listing finished; swatting a stray letter.", ctx, { sound = "swat" }),
			"react.ls_swat"
	end
	if ok then
		if ready(state, "react.command_ok", ctx) and rng:chance(rate) then
			local mood = ctx.profile.mood
			local took = attrs.took_ms
			local happy = 1
				+ (if mood == "happy" or mood == "playful" then 1 else 0)
				+ (if type(took) == "number" and took >= 10000 then 1 else 0)
			local pick: T.Animation = (rng:weighted({ happy = happy, blink = 1.5 }) or "blink") :: any
			return decide("react.command_ok", pick, "A command succeeded.", ctx), "react.command_ok"
		end
		return nil
	end
	if ready(state, "react.command_failed", ctx) and rng:chance(rate) then
		local pick: T.Animation = (rng:weighted({ disappointed = 1 + clamp01(p.affection), look = 1 }) or "look") :: any
		return decide("react.command_failed", pick, "A command failed.", ctx), "react.command_failed"
	end
	return nil
end

local function reactiveDecision(state: T.EngineState, event: T.CatEvent, ctx: Ctx): (Decision?, string?)
	local attrs = event.attributes
	local b = ctx.config.behavior
	local kind = event.type
	if kind == "command_start" then
		if attrs.category == "sudo" and b.allow_command_reactions and ready(state, "react.sudo", ctx) then
			return decide("react.sudo", "stare", "Someone used sudo; staring suspiciously.", ctx), "react.sudo"
		end
	elseif kind == "command_finish" then
		return commandFinishDecision(state, attrs, ctx)
	elseif kind == "pane" then
		local pane_kind = attrs.kind
		if
			b.allow_pane_reactions
			and (pane_kind == "created" or pane_kind == "closed")
			and ready(state, "react.pane", ctx)
		then
			local curiosity = clamp01(ctx.config.personality.curiosity)
			local pick: T.Animation = if ctx.rng:chance(0.3 + 0.5 * curiosity) then "hop" else "look"
			local reason = if pane_kind == "created" then "A pane opened." else "A pane closed."
			return decide("react.pane", pick, reason, ctx), "react.pane"
		end
	elseif kind == "ai" then
		local anim = attrs.animation
		if animations.isCanonical(anim) and anim ~= "sleep" and anim ~= "wake" and ready(state, "react.ai", ctx) then
			return decide("react.ai", anim :: any, "Suggested by the AI provider.", ctx), "react.ai"
		end
	end
	return nil
end

-- Public API ------------------------------------------------------------------------------

local function newState(now_ms: number): T.EngineState
	local duration = animations.defaultDurationMs("idle")
	return {
		posture = "awake",
		current = {
			id = "ambient.idle",
			animation = "idle",
			intensity = 0.5,
			duration_ms = duration,
			reason = AMBIENT_REASONS.idle,
		},
		started_ms = now_ms,
		until_ms = now_ms + duration,
		last_by_trigger = {},
		last_activity_ms = now_ms,
		fail_streak = 0,
		pending = nil,
	}
end

local function tick(state: T.EngineState, ctx: Ctx): (T.EngineState, Decision?)
	local current = state.current
	if
		ctx.env.snoozed
		and state.posture == "awake"
		and current ~= nil
		and not isGestureRelated(current.id)
		and current.animation ~= "sleep"
	then
		return apply(state, decide("ambient.snoozed", "sleep", "Snoozed.", ctx), ctx)
	end
	if ctx.now_ms < state.until_ms then
		return state, nil
	end
	local s = state
	local pending = state.pending
	if pending ~= nil then
		s = table.clone(state)
		s.pending = nil
		local allowed = isGestureRelated(pending.id)
			or (not ctx.env.snoozed and not ctx.env.quiet_hours and familyAllowed(pending.id, ctx.config.behavior))
		if allowed then
			return apply(s, pending, ctx)
		end
	end
	local d, trigger = chooseAmbient(s, ctx)
	if trigger then
		s = markTrigger(s, trigger, ctx.now_ms)
	end
	return apply(s, d, ctx)
end

local function react(state: T.EngineState, event: T.CatEvent, ctx: Ctx): (T.EngineState, Decision?)
	local kind = event.type
	local attrs: T.EventAttributes = event.attributes or {}
	local s = table.clone(state)
	local is_activity = ACTIVITY_TYPES[kind] == true
	if is_activity then
		s.last_activity_ms = math.max(state.last_activity_ms, ctx.now_ms)
	end
	if kind == "command_finish" and attrs.category == "test" then
		s.fail_streak = if attrs.ok == true then 0 else math.min(state.fail_streak + 1, MAX_FAIL_STREAK)
	end

	if kind == "gesture" then
		local d = gestureDecision(attrs, ctx)
		if d == nil then
			return s, nil
		end
		return apply(s, d, ctx)
	end

	local env = ctx.env
	if env.snoozed or env.quiet_hours then
		return s, nil
	end

	if s.posture == "asleep" then
		if not is_activity then
			return s, nil
		end
		local p = ctx.config.personality
		local wake_chance = math.max(clamp01(p.curiosity), clamp01(p.mischief)) ^ 2
		if not ctx.rng:chance(wake_chance) then
			return s, nil
		end
	end

	local d, trigger = reactiveDecision(s, event, ctx)
	if d == nil and s.posture == "asleep" then
		d = decide("react.input_resumed", "look", "You're back; looking around.", ctx)
	end
	if d == nil then
		return s, nil
	end
	if trigger then
		s = markTrigger(s, trigger, ctx.now_ms)
		if trigger == "react.fail_streak" then
			s.fail_streak = 0
		end
	end
	return apply(s, d, ctx)
end

return {
	MAX_FAIL_STREAK = MAX_FAIL_STREAK,
	newState = newState,
	tick = tick,
	react = react,
}
