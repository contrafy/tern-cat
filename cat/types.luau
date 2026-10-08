--!strict
-- Shared data contracts for tern-cat. Types only; no runtime behavior.
--
-- Conventions:
--   * Data fields are snake_case (they are persisted as JSON and mirror Tern's own payloads).
--   * Wall-clock times are unix seconds (`os.time()`); engine/animation times are monotonic
--     milliseconds (`tern.now()`), named `*_ms`.
--   * Normalized quantities are numbers in [0, 1].

-- Personality and needs ---------------------------------------------------------------

export type Personality = {
	curiosity: number,
	affection: number,
	mischief: number,
	energy: number,
	talkativeness: number,
}

-- hunger:    0 = full,      1 = very hungry
-- energy:    0 = exhausted, 1 = fully rested
-- affection: 0 = neglected, 1 = fully loved
-- boredom:   0 = engaged,   1 = very bored
-- Needs never cause death, punishment or loss; they only bias mood and behavior choice.
export type Needs = {
	hunger: number,
	energy: number,
	affection: number,
	boredom: number,
}

export type Mood = "calm" | "playful" | "sleepy" | "annoyed" | "curious" | "happy"

export type Stats = {
	pets: number,
	pokes: number,
	feeds: number,
	plays: number,
	command_reactions: number,
}

-- Runtime state owned by the host half (single writer). User intent lives in Config.
export type Profile = {
	schema_version: number,
	cat_id: string,
	needs: Needs,
	mood: Mood,
	stats: Stats,
	-- Bounded local counters; never derived from command output.
	fail_streak: number,
	created_at: number,
	last_updated_at: number,
}

-- Events -------------------------------------------------------------------------------

export type EventType =
	"idle"
	| "pointer"
	| "command_start"
	| "command_finish"
	| "cwd"
	| "pane"
	| "resize"
	| "gesture"
	| "timer"
	| "focus"
	| "ai"

export type EventScope = "host" | "window" | "block"

-- The only information ever derived from a command line. The line itself is never stored.
export type CommandCategory = "test" | "build" | "vcs" | "list" | "sudo" | "editor" | "network" | "package" | "other"

export type Gesture = "pet" | "poke" | "feed" | "play" | "perform"

export type EventAttributes = { [string]: string | number | boolean }

export type CatEvent = {
	event_id: string,
	time: number,
	type: EventType,
	scope: EventScope,
	pane_id: number?,
	attributes: EventAttributes,
}

-- Animations and behavior ---------------------------------------------------------------

-- Canonical animation names. Packs must provide `idle`; everything else falls back
-- through cat/render/animations.luau.
export type Animation =
	"idle"
	| "walk"
	| "sit"
	| "sleep"
	| "wake"
	| "stretch"
	| "groom"
	| "blink"
	| "look"
	| "pet"
	| "poke"
	| "eat"
	| "play"
	| "happy"
	| "disappointed"
	| "swat"
	| "startled"
	| "flop"
	| "stare"
	| "hop"

export type SoundId = "meow" | "purr" | "surprise" | "happy" | "swat"

export type Posture = "awake" | "asleep"

export type BehaviorDecision = {
	-- Behavior rule id, e.g. "react.command_failed".
	id: string,
	animation: Animation,
	intensity: number,
	duration_ms: number,
	-- True when the decision only makes sense for the window overlay (e.g. pacing).
	overlay_only: boolean?,
	text: string?,
	sound: SoundId?,
	-- Human-readable explanation, shown in the block ("why is the cat doing this?").
	reason: string,
}

export type EngineState = {
	posture: Posture,
	current: BehaviorDecision?,
	started_ms: number,
	until_ms: number,
	-- Last time (engine ms) each rate-limited trigger fired.
	last_by_trigger: { [string]: number },
	-- Last observed user activity (engine ms): commands, focus changes, gestures.
	last_activity_ms: number,
	fail_streak: number,
	-- Decision deferred behind a `wake` (a sleeping cat must wake before doing anything else).
	pending: BehaviorDecision?,
}

export type Rng = {
	-- Uniform float in [0, 1).
	next: (self: Rng) -> number,
	-- Uniform integer in [lo, hi].
	int: (self: Rng, lo: number, hi: number) -> number,
	-- True with probability p.
	chance: (self: Rng, p: number) -> boolean,
	-- Weighted pick; returns the key of the chosen entry, nil when all weights are <= 0.
	weighted: (self: Rng, weights: { [string]: number }) -> string?,
	-- Current internal state (for snapshotting/tests).
	state: (self: Rng) -> number,
}

export type Clock = {
	-- Monotonic milliseconds.
	now_ms: () -> number,
	-- Wall-clock unix seconds.
	wall_s: () -> number,
	-- Local wall-clock {hour, min} for quiet hours.
	local_hm: () -> { hour: number, min: number },
}

-- Configuration ------------------------------------------------------------------------

export type Activity = "quiet_office" | "orange_menace" | "chaos" | "zen"

export type ReducedMotion = "follow_tern" | "on" | "off"

export type BlockPlacement = "float" | "split"

export type AiProvider = "none" | "mock" | "carly_schedule"

export type Config = {
	schema_version: number,
	cat: {
		name: string,
		appearance: string,
	},
	personality: Personality,
	needs: {
		enabled: boolean,
		offline_progress: boolean,
		offline_hours_cap: number,
	},
	rendering: {
		overlay: boolean,
		overlay_scale: number,
		block_scale: number,
		reduced_motion: ReducedMotion,
		block_placement: BlockPlacement,
	},
	behavior: {
		activity: Activity,
		allow_visual_obscuring: boolean,
		allow_swats: boolean,
		allow_command_reactions: boolean,
		allow_development_reactions: boolean,
		allow_pane_reactions: boolean,
		allow_idle_sleep: boolean,
		allow_pacing: boolean,
		-- CSS-only hover/press reactions of the overlay cat (look near the pointer, swat on press).
		allow_pointer_reactions: boolean,
		-- While a command runs: no moving or reactive decisions and no sound (see Environment.busy).
		focus_mode: boolean,
		-- Probability that an eligible command event produces a visible reaction.
		reaction_sample_rate: number,
		-- Minimum seconds between two reactions to the same trigger.
		reaction_cooldown_s: number,
	},
	quiet: {
		hours_enabled: boolean,
		start: string,
		stop: string,
	},
	ai: {
		enabled: boolean,
		provider: AiProvider,
		max_turns_per_hour: number,
		max_turns_per_day: number,
		cooldown_s: number,
		share_command_output: boolean,
	},
	sound: {
		enabled: boolean,
		volume: number,
		pack: string,
		events: { [string]: boolean },
		respect_quiet_hours: boolean,
	},
	controls: {
		keyboard_enabled: boolean,
	},
}

-- Runtime signals that supersede personality (computed by the integrating half).
export type Environment = {
	reduced_motion: boolean,
	quiet_hours: boolean,
	snoozed: boolean,
	-- Focus mode is on and a command is running (in any local pane for the host, in this
	-- window's panes for a window).
	busy: boolean,
}

export type DecideContext = {
	now_ms: number,
	rng: Rng,
	config: Config,
	profile: Profile,
	env: Environment,
}

-- Intents (user / keyboard / Carly requests) ------------------------------------------------

export type IntentKind =
	"pet"
	| "poke"
	| "feed"
	| "play"
	| "perform"
	| "set_personality"
	| "set_config"
	| "snooze"
	| "unsnooze"
	| "set_overlay"
	| "rename"
	| "reset_identity"
	| "export_identity"
	| "clear_ai_state"

export type IntentSource = "block" | "window" | "carly" | "keyboard"

export type Intent = {
	intent_id: string,
	at: number,
	kind: IntentKind,
	source: IntentSource,
	args: { [string]: any },
}

-- Persistence --------------------------------------------------------------------------

export type JournalEntry = {
	at: number,
	event_id: string,
	kind: string,
	summary: string,
}

export type ReactionRecord = {
	at: number,
	id: string,
	animation: Animation,
	reason: string,
}

-- The single `tern.kv` value (key "state") owned by the host half.
export type StoreEnvelope = {
	schema_version: number,
	-- Bumped on every host write; readers skip work when unchanged.
	rev: number,
	profile: Profile,
	-- Newest last; bounded.
	journal: { JournalEntry },
	-- Ring of applied event/intent ids, newest last; bounded. Prevents double application.
	seen: { string },
	last_reaction: ReactionRecord?,
	-- Unix seconds; nil when not snoozed.
	snooze_until: number?,
}

-- Sprite packs -------------------------------------------------------------------------

export type AnimationSpec = {
	frames: { string },
	durations_ms: { number },
	loop: boolean,
	anchor: { number }?,
	hitbox: { number }?,
	-- Derived by tools/build_packs.py: one APNG of all frames (block renderer).
	apng: string?,
	-- Derived by tools/build_packs.py: horizontal strip of all frames (overlay renderer).
	sheet: string?,
}

export type PackManifest = {
	schema_version: number,
	id: string,
	name: string,
	author: string?,
	license: string,
	description: string?,
	canvas: { width: number, height: number },
	animations: { [string]: AnimationSpec },
}

export type PackSource = "bundled" | "user"

export type LoadedPack = {
	manifest: PackManifest,
	-- Directory containing pack.json (absolute in Tern, repo-relative in tests).
	root: string,
	source: PackSource,
	warnings: { string },
}

export type ValidationResult = {
	ok: boolean,
	errors: { string },
	warnings: { string },
	manifest: PackManifest?,
}

-- Filesystem access injected into loaders so they run under both Tern and Lune.
export type FsAdapter = {
	read: (path: string, max_bytes: number?) -> string?,
	list: (path: string) -> { string }?,
	exists: (path: string) -> boolean,
}

-- AI -----------------------------------------------------------------------------------

-- What a provider may return. Anything else is rejected by cat/integrations/ai.luau.
export type AiSuggestion = {
	animation: Animation,
	text: string?,
}

export type AiRequest = {
	-- Redacted, minimal summary; never command text, output, paths or env.
	summary: string,
	mood: Mood,
	allowed_animations: { Animation },
}

export type AiProviderImpl = {
	id: AiProvider,
	available: boolean,
	-- Human-readable reason shown in settings when unavailable.
	unavailable_reason: string?,
	request: (self: AiProviderImpl, req: AiRequest, done: (suggestion: any?, err: string?) -> ()) -> (),
}

return {}
