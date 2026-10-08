--!strict
-- Per-window overlay presentation: one behavior engine per window VM, driven by this window's
-- events, the shared profile (read-only) and mirrored host reactions. Produces overlay views and
-- params; never writes shared state.

local T = require("../types")
local behavior = require("../core/behavior")
local events = require("../core/events")
local rngMod = require("../core/rng")
local clockMod = require("../core/clock")
local running = require("../core/running")
local overlay = require("../render/overlay")

export type Facing = "left" | "right"

export type View = {
	hidden: boolean,
	animation: T.Animation,
	still: boolean,
	pace: boolean,
	-- CSS-only pointer reactions (look while near, swat when pressed).
	reactions: boolean,
	facing: Facing,
	seq: number,
}

export type Asset = {
	sheet_url: string,
	frame_w: number,
	frame_h: number,
	durations_ms: { number },
	loop: boolean,
}

-- Sheets for the pointer reactions, already resolved through the pack's fallbacks.
export type ReactionAssets = {
	hover: Asset?,
	press: Asset?,
}

-- Animations the overlay plays while the pointer is near the cat and while it is pressed.
local HOVER_ANIMATION: T.Animation = "look"
local PRESS_ANIMATION: T.Animation = "swat"

export type Presenter = {
	clock: T.Clock,
	rng: T.Rng,
	config: T.Config,
	profile: T.Profile,
	engine: T.EngineState,
	snooze_until: number?,
	-- Commands running in this window's panes (focus mode).
	running: running.Running,
	tern_reduce_motion: boolean,
	-- The interactive cat block floats over the focused pane's corner: the overlay steps aside.
	covered: boolean,
	-- Local, immediate overlay visibility (toggle command) until config.json agrees.
	overlay_override: boolean?,
	facing: Facing,
	seq: number,
}

export type Options = {
	clock: T.Clock,
	seed: number,
	config: T.Config,
	profile: T.Profile,
}

local MIN_DELAY_MS = 1000
local MAX_DELAY_MS = 5000
local ID_PREFIX = "wev"

-- The facing that looks into the pane from the overlay's corner (sprites face right unmirrored).
local function inward(config: T.Config): Facing
	return if string.sub(config.rendering.overlay_position, -5) == "-left" then "right" else "left"
end

local function new(opts: Options): Presenter
	return {
		clock = opts.clock,
		rng = rngMod.new(opts.seed),
		config = opts.config,
		profile = opts.profile,
		engine = behavior.newState(opts.clock.now_ms()),
		snooze_until = nil,
		running = running.new(),
		tern_reduce_motion = false,
		covered = false,
		overlay_override = nil,
		facing = inward(opts.config),
		seq = 0,
	}
end

local function still(p: Presenter): boolean
	return p.config.rendering.reduced_motion == "on" or p.tern_reduce_motion
end

local function visible(p: Presenter): boolean
	if p.overlay_override ~= nil then
		return p.overlay_override
	end
	return p.config.rendering.overlay
end

local function environment(p: Presenter): T.Environment
	local quiet = p.config.quiet
	local untilS = p.snooze_until
	return {
		reduced_motion = still(p),
		quiet_hours = quiet.hours_enabled and clockMod.inQuietHours(p.clock.local_hm(), quiet.start, quiet.stop),
		snoozed = untilS ~= nil and p.clock.wall_s() < untilS,
		busy = p.config.behavior.focus_mode and running.busy(p.running, p.clock.now_ms()),
	}
end

local function context(p: Presenter): T.DecideContext
	return {
		now_ms = p.clock.now_ms(),
		rng = p.rng,
		config = p.config,
		profile = p.profile,
		env = environment(p),
	}
end

local function adopt(p: Presenter, state: T.EngineState, decision: T.BehaviorDecision?): boolean
	local previous = if p.engine.current then p.engine.current.animation else nil
	p.engine = state
	if decision == nil then
		return false
	end
	p.seq += 1
	if decision.animation ~= previous then
		p.facing = if p.facing == "right" then "left" else "right"
	end
	return true
end

-- Advances the engine; true when a new decision started.
local function tick(p: Presenter): boolean
	local state, decision = behavior.tick(p.engine, context(p))
	return adopt(p, state, decision)
end

local function react(p: Presenter, event: T.CatEvent): boolean
	local state, decision = behavior.react(p.engine, event, context(p))
	return adopt(p, state, decision)
end

-- Tracks which of this window's panes run a command, from raw window events (before eventFor, so
-- it also runs while the overlay is hidden). Call before reacting: a command's own start counts
-- as busy, its finish does not.
local function observe(p: Presenter, name: string, payload: any)
	if type(payload) ~= "table" then
		return
	end
	local pane = if type(payload.pane) == "number" then payload.pane else nil
	if name == "command_started" then
		running.started(p.running, pane, p.clock.now_ms())
	elseif name == "command_finished" or name == "pane_closed" then
		running.stopped(p.running, pane)
	end
end

local function newEventId(p: Presenter): string
	return events.newId(p.rng, ID_PREFIX)
end

local function gesture(p: Presenter, kind: T.Gesture, extra: { [string]: any }?): boolean
	local x: { [string]: any } = extra or {}
	local scope: T.EventScope = "window"
	local ev = events.gesture({
		id = newEventId(p),
		time = p.clock.wall_s(),
		scope = scope,
		gesture = kind,
		item = x.item,
		toy = x.toy,
		animation = x.animation,
		source = "window",
	})
	return react(p, ev)
end

-- Plays a reaction decided elsewhere (the host) as a performed animation. `id` is the host's
-- rule id: a host reaction (`react.*`) is skipped while focus mode holds this window busy, since
-- the host never sees remote panes and may react while this window still runs a command.
local function mirror(p: Presenter, animation: any, id: string?): boolean
	if type(animation) ~= "string" then
		return false
	end
	if id ~= nil and string.find(id, "react.", 1, true) ~= nil and environment(p).busy then
		return false
	end
	return gesture(p, "perform", { animation = animation })
end

local PANE_KIND: { [string]: string } = {
	pane_created = "created",
	pane_closed = "closed",
	tab_created = "created",
	tab_closed = "closed",
}

-- Builds a window-scoped CatEvent from a Tern window event payload. Command lines are reduced to
-- a category here and never retained.
local function eventFor(p: Presenter, name: string, payload: any): T.CatEvent?
	if type(payload) ~= "table" then
		return nil
	end
	local base = {
		id = newEventId(p),
		time = p.clock.wall_s(),
		scope = "window" :: T.EventScope,
		pane = if type(payload.pane) == "number" then payload.pane else nil,
	}
	if name == "focus" then
		return events.focus(base)
	elseif PANE_KIND[name] then
		local args: any = table.clone(base)
		args.kind = PANE_KIND[name]
		return events.paneEvent(args)
	elseif name == "command_started" then
		local args: any = table.clone(base)
		args.category = events.classify(payload.line)
		return events.commandStarted(args)
	elseif name == "command_finished" then
		local args: any = table.clone(base)
		args.category = events.classify(payload.line)
		args.status = payload.status
		args.took_ms = payload.took_ms
		return events.commandFinished(args)
	elseif name == "cwd" then
		return events.cwdChanged(base)
	end
	return nil
end

local function nextDelayMs(p: Presenter): number
	local remaining = p.engine.until_ms - p.clock.now_ms()
	return math.clamp(math.ceil(remaining), MIN_DELAY_MS, MAX_DELAY_MS)
end

local function setConfig(p: Presenter, config: T.Config)
	if config.rendering.overlay_position ~= p.config.rendering.overlay_position then
		p.facing = inward(config)
	end
	p.config = config
	if p.overlay_override ~= nil and p.overlay_override == config.rendering.overlay then
		p.overlay_override = nil
	end
end

local function setProfile(p: Presenter, profile: T.Profile, snooze_until: number?)
	p.profile = profile
	p.snooze_until = snooze_until
end

local function setTernReducedMotion(p: Presenter, on: boolean)
	p.tern_reduce_motion = on
end

local function setCovered(p: Presenter, on: boolean)
	p.covered = on
end

local function setOverlayOverride(p: Presenter, value: boolean?)
	p.overlay_override = value
end

local function view(p: Presenter): View
	local current = p.engine.current
	local animation: T.Animation = if current then current.animation else "idle"
	local isStill = still(p)
	-- The overlay is drawn over terminal panes, so it only shows while covering text is allowed.
	local hidden = not visible(p) or p.covered or not p.config.behavior.allow_visual_obscuring
	return {
		hidden = hidden,
		animation = animation,
		still = isStill,
		pace = animation == "walk" and p.config.behavior.allow_pacing and not isStill,
		reactions = not hidden and p.config.behavior.allow_pointer_reactions,
		facing = p.facing,
		seq = p.seq,
	}
end

local function reaction(a: Asset?): overlay.Reaction?
	if a == nil then
		return nil
	end
	return { sheet_url = a.sheet_url, durations_ms = a.durations_ms, loop = a.loop }
end

local function params(p: Presenter, v: View, asset: Asset?, reactions: ReactionAssets?): overlay.Params
	if asset == nil or v.hidden then
		return { hidden = true } :: any
	end
	local key = if asset.loop then v.animation else `{v.animation}-{v.seq}`
	return {
		sheet_url = asset.sheet_url,
		frame_w = asset.frame_w,
		frame_h = asset.frame_h,
		durations_ms = asset.durations_ms,
		loop = asset.loop,
		scale = p.config.rendering.overlay_scale,
		position = p.config.rendering.overlay_position,
		offset_px = p.config.rendering.overlay_offset_px,
		facing = v.facing,
		pace = v.pace,
		still = v.still,
		hidden = false,
		anim_key = key,
		reactions = if v.reactions and reactions
			then { hover = reaction(reactions.hover), press = reaction(reactions.press) }
			else nil,
	}
end

return {
	HOVER_ANIMATION = HOVER_ANIMATION,
	PRESS_ANIMATION = PRESS_ANIMATION,
	MIN_DELAY_MS = MIN_DELAY_MS,
	MAX_DELAY_MS = MAX_DELAY_MS,
	new = new,
	visible = visible,
	environment = environment,
	tick = tick,
	react = react,
	observe = observe,
	gesture = gesture,
	mirror = mirror,
	eventFor = eventFor,
	nextDelayMs = nextDelayMs,
	setConfig = setConfig,
	setProfile = setProfile,
	setTernReducedMotion = setTernReducedMotion,
	setCovered = setCovered,
	setOverlayOverride = setOverlayOverride,
	view = view,
	params = params,
}
