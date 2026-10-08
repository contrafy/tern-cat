--!strict
local t = require("../../lib/test")
local factories = require("../../lib/factories")
local behavior = require("../../../cat/core/behavior")
local events = require("../../../cat/core/events")
local rng = require("../../../cat/core/rng")
local animations = require("../../../cat/render/animations")

local describe, it, expect = t.describe, t.it, t.expect

local MIN = 60 * 1000

type CtxOpts = {
	now_ms: number?,
	seed: number?,
	rng: any?,
	config: any?,
	profile: any?,
	env: { [string]: boolean }?,
}

local function makeCtx(o: CtxOpts?): any
	local opts: CtxOpts = o or {}
	local env = { reduced_motion = false, quiet_hours = false, snoozed = false, busy = false }
	for k, v in opts.env or {} do
		env[k] = v
	end
	return {
		now_ms = opts.now_ms or 0,
		rng = opts.rng or rng.new(opts.seed or 1),
		config = opts.config or factories.config(),
		profile = opts.profile or factories.profile(),
		env = env,
	}
end

-- Config where every eligible command event reacts (cooldown floor still applies).
local function eagerConfig(behaviorOverrides: { [string]: any }?): any
	local b: { [string]: any } = { reaction_sample_rate = 1, reaction_cooldown_s = 0 }
	for k, v in behaviorOverrides or {} do
		b[k] = v
	end
	return factories.config({ behavior = b })
end

local seq = 0
local function nextId(): string
	seq += 1
	return `ev-{seq}`
end

local function finished(category: string, status: number): any
	return events.commandFinished({
		id = nextId(),
		time = factories.WALL_S,
		pane = 1,
		category = category :: any,
		status = status,
		took_ms = 1500,
	})
end

local function started(category: string): any
	return events.commandStarted({ id = nextId(), time = factories.WALL_S, pane = 1, category = category :: any })
end

local function paneEv(kind: string): any
	return events.paneEvent({ id = nextId(), time = factories.WALL_S, pane = 2, kind = kind })
end

local function focusEv(): any
	return events.focus({ id = nextId(), time = factories.WALL_S, pane = 1, scope = "window" })
end

local function gestureEv(gesture: string, animation: string?): any
	return events.gesture({
		id = nextId(),
		time = factories.WALL_S,
		gesture = gesture :: any,
		animation = animation,
		source = "block",
	})
end

-- Runs ambient ticks back to back while the user stays active, returning animation counts.
local function ambient(n: number, opts: CtxOpts?): ({ [string]: number }, { any })
	local o: CtxOpts = opts or {}
	local r = rng.new(o.seed or 7)
	local config = o.config or factories.config()
	local profile = o.profile or factories.profile()
	local state = behavior.newState(0)
	local counts: { [string]: number } = {}
	local decisions = {}
	for _ = 1, n do
		local now = state.until_ms
		local active = table.clone(state)
		active.last_activity_ms = now
		local d
		state, d =
			behavior.tick(active, makeCtx({ now_ms = now, rng = r, config = config, profile = profile, env = o.env }))
		if d then
			counts[d.animation] = (counts[d.animation] or 0) + 1
			table.insert(decisions, d)
		end
	end
	return counts, decisions
end

local function asleepState(now: number, seed: number?): any
	local state = behavior.newState(now)
	local d
	state, d = behavior.react(state, gestureEv("perform", "sleep"), makeCtx({ now_ms = now, seed = seed }))
	expect(d.animation).toBe("sleep")
	expect(state.posture).toBe("asleep")
	return state
end

local function expectWellFormed(d: any)
	expect(animations.isCanonical(d.animation)).toBeTruthy()
	expect(type(d.id)).toBe("string")
	expect(type(d.reason)).toBe("string")
	expect(#d.reason).toBeGreaterThan(0)
	expect(#d.reason).toBeLessThanOrEqual(80)
	expect(d.duration_ms).toBeGreaterThan(0)
	expect(d.intensity).toBeGreaterThanOrEqual(0)
	expect(d.intensity).toBeLessThanOrEqual(1)
end

describe("core.behavior", function()
	describe("newState", function()
		it("starts awake and idling with the user considered active", function()
			local s = behavior.newState(500)
			expect(s.posture).toBe("awake")
			expect(s.current.animation).toBe("idle")
			expect(s.started_ms).toBe(500)
			expect(s.until_ms).toBeGreaterThan(500)
			expect(s.last_activity_ms).toBe(500)
			expect(s.fail_streak).toBe(0)
			expect(s.pending).toBeNil()
		end)
	end)

	describe("tick", function()
		it("keeps the current behavior until it ends", function()
			local s = behavior.newState(0)
			local s2, d = behavior.tick(s, makeCtx({ now_ms = s.until_ms - 1 }))
			expect(d).toBeNil()
			expect(s2.current).toEqual(s.current)
		end)

		it("re-rolls when the current behavior (even looping idle) ends", function()
			local s = behavior.newState(0)
			local s2, d = behavior.tick(s, makeCtx({ now_ms = s.until_ms }))
			expect(d).notToBeNil()
			expectWellFormed(d)
			expect(s2.current).toEqual(d)
			expect(s2.started_ms).toBe(s.until_ms)
			expect(s2.until_ms).toBe(s.until_ms + d.duration_ms)
		end)

		it("does not mutate the state it is given", function()
			local s = behavior.newState(0)
			local before = t.render(s)
			behavior.tick(s, makeCtx({ now_ms = s.until_ms }))
			expect(t.render(s)).toBe(before)
		end)

		it("is deterministic for the same seed", function()
			local _, a = ambient(200, { seed = 5 })
			local _, b = ambient(200, { seed = 5 })
			expect(a).toEqual(b)
		end)

		it("produces a varied ambient repertoire for the default cat", function()
			local counts, decisions = ambient(2000)
			for _, name in { "idle", "sit", "groom", "blink", "stretch", "look", "walk", "swat" } do
				expect(counts[name] or 0).toBeGreaterThan(0)
			end
			for _, d in decisions do
				expectWellFormed(d)
			end
		end)

		it("marks pacing as overlay-only", function()
			local _, decisions = ambient(2000)
			for _, d in decisions do
				if d.animation == "walk" then
					expect(d.overlay_only).toBe(true)
				end
			end
		end)

		it("makes chaos noticeably more mischievous than quiet office", function()
			local chaos = ambient(3000, { config = factories.config({ behavior = { activity = "chaos" } }) })
			local office = ambient(3000, {
				config = factories.config({ behavior = { activity = "quiet_office", allow_swats = true } }),
			})
			local function mischief(c: { [string]: number }): number
				return (c.swat or 0) + (c.hop or 0)
			end
			expect(mischief(chaos)).toBeGreaterThan(mischief(office) * 2)
		end)

		it("naps when energy is low, unless idle sleep is disabled", function()
			local tired = factories.profile({ needs = { energy = 0.12 } })
			local counts = ambient(50, { profile = tired })
			expect(counts.sleep or 0).toBeGreaterThan(0)
			local none = ambient(500, {
				profile = tired,
				config = factories.config({ behavior = { allow_idle_sleep = false } }),
			})
			expect(none.sleep).toBeNil()
		end)

		it("settles (groom/stretch) and then sleeps after long inactivity", function()
			local r = rng.new(3)
			local s = behavior.newState(0)
			local now = 10 * MIN + 1
			local d
			s, d = behavior.tick(s, makeCtx({ now_ms = now, rng = r }))
			expect(d.animation == "groom" or d.animation == "stretch").toBeTruthy()
			expect(d.reason).toContain("away")
			s, d = behavior.tick(s, makeCtx({ now_ms = s.until_ms, rng = r }))
			expect(d.animation).toBe("sleep")
			expect(s.posture).toBe("asleep")
		end)

		it("never settles down before two minutes of inactivity", function()
			for seed = 1, 50 do
				local s = behavior.newState(0)
				s.until_ms = 0
				local _, d = behavior.tick(s, makeCtx({ now_ms = 2 * MIN - 1, seed = seed }))
				expect(d.id ~= "ambient.settle" and d.id ~= "ambient.inactive_sleep").toBeTruthy()
			end
		end)

		it("sleeps by ten minutes of inactivity even for the most energetic cat", function()
			local config = factories.config({ personality = { energy = 1 } })
			local profile = factories.profile({ needs = { energy = 1 } })
			local s = behavior.newState(0)
			s.until_ms = 0
			local _, d = behavior.tick(s, makeCtx({ now_ms = 10 * MIN, config = config, profile = profile }))
			expect(d.id).toBe("ambient.settle")
		end)

		it("does not sleep from inactivity when idle sleep is disabled", function()
			local config = factories.config({ behavior = { allow_idle_sleep = false } })
			local r = rng.new(4)
			local s = behavior.newState(0)
			local now = 30 * MIN
			for _ = 1, 50 do
				local d
				s, d = behavior.tick(s, makeCtx({ now_ms = now, rng = r, config = config }))
				expect(d.animation ~= "sleep").toBeTruthy()
				now = s.until_ms
			end
		end)

		it("stays asleep across ticks while the user is away", function()
			local s = asleepState(0)
			s.last_activity_ms = 0
			local r = rng.new(8)
			for _ = 1, 20 do
				local d
				s, d = behavior.tick(s, makeCtx({ now_ms = s.until_ms + 20 * MIN, rng = r }))
				expect(d.animation).toBe("sleep")
			end
		end)
	end)

	describe("precedence", function()
		it("snooze interrupts ambient behavior with sleep immediately", function()
			local s = behavior.newState(0)
			local s2, d = behavior.tick(s, makeCtx({ now_ms = 1, env = { snoozed = true } }))
			expect(d.animation).toBe("sleep")
			expect(d.reason).toContain("Snoozed")
			expect(s2.posture).toBe("asleep")
		end)

		it("snooze allows only sleep from ticks", function()
			local counts = ambient(500, { env = { snoozed = true } })
			for name in counts do
				expect(name).toBe("sleep")
			end
		end)

		it("snooze suppresses reactive behavior", function()
			local config = eagerConfig()
			local s = behavior.newState(0)
			for _, ev in { finished("test", 1), finished("list", 0), started("sudo"), paneEv("created") } do
				local _, d =
					behavior.react(s, ev, makeCtx({ now_ms = 5000, config = config, env = { snoozed = true } }))
				expect(d).toBeNil()
			end
		end)

		it("snooze beats quiet hours (sleep only, never blink/groom)", function()
			local counts = ambient(500, { env = { snoozed = true, quiet_hours = true } })
			for name in counts do
				expect(name).toBe("sleep")
			end
		end)

		it("explicit gestures still respond while snoozed, waking the cat first", function()
			local s = behavior.newState(0)
			local d
			s, d = behavior.tick(s, makeCtx({ now_ms = 1, env = { snoozed = true } }))
			expect(s.posture).toBe("asleep")
			s, d = behavior.react(s, gestureEv("pet"), makeCtx({ now_ms = 100, env = { snoozed = true } }))
			expect(d.animation).toBe("wake")
			s, d = behavior.tick(s, makeCtx({ now_ms = s.until_ms, env = { snoozed = true } }))
			expect(d.animation).toBe("pet")
			s, d = behavior.tick(s, makeCtx({ now_ms = s.until_ms, env = { snoozed = true } }))
			expect(d.animation).toBe("sleep")
		end)

		it("quiet hours restrict ambient behavior to sleep, blink and groom", function()
			local counts = ambient(
				1000,
				{ env = { quiet_hours = true }, config = factories.config({ behavior = { activity = "chaos" } }) }
			)
			for name in counts do
				expect(name == "sleep" or name == "blink" or name == "groom").toBeTruthy()
			end
			expect(counts.sleep or 0).toBeGreaterThan(0)
		end)

		it("quiet hours suppress reactive behavior", function()
			local config = eagerConfig()
			local s = behavior.newState(0)
			for _, ev in { finished("test", 1), finished("build", 0), started("sudo"), paneEv("closed") } do
				local _, d =
					behavior.react(s, ev, makeCtx({ now_ms = 5000, config = config, env = { quiet_hours = true } }))
				expect(d).toBeNil()
			end
		end)

		it("quiet hours silence every sound, even for gestures", function()
			local s = behavior.newState(0)
			for _, g in { "pet", "poke", "feed", "play" } do
				for seed = 1, 20 do
					local _, d = behavior.react(
						s,
						gestureEv(g),
						makeCtx({ now_ms = 10, seed = seed, env = { quiet_hours = true } })
					)
					expect(d).notToBeNil()
					expect(d.sound).toBeNil()
				end
			end
		end)

		it("reduced motion keeps decisions but drops intensity, pacing and hops", function()
			local counts, decisions = ambient(2000, {
				env = { reduced_motion = true },
				config = factories.config({ behavior = { activity = "chaos" } }),
			})
			expect(#decisions).toBe(2000)
			expect(counts.walk).toBeNil()
			expect(counts.hop).toBeNil()
			for _, d in decisions do
				expect(d.intensity).toBe(0)
			end
			local config = eagerConfig()
			for seed = 1, 30 do
				local _, d = behavior.react(
					behavior.newState(0),
					paneEv("created"),
					makeCtx({
						now_ms = 5000,
						seed = seed,
						config = config,
						env = { reduced_motion = true },
					})
				)
				expect(d.animation).toBe("look")
				expect(d.intensity).toBe(0)
			end
		end)

		it("reduced motion replaces airborne gestures with calm ones", function()
			for seed = 1, 30 do
				local ctx = makeCtx({ now_ms = 10, seed = seed, env = { reduced_motion = true } })
				local _, poke = behavior.react(behavior.newState(0), gestureEv("poke"), ctx)
				expect(poke.animation ~= "startled").toBeTruthy()
				local _, hop = behavior.react(behavior.newState(0), gestureEv("perform", "hop"), ctx)
				expect(hop.animation).toBe("look")
			end
		end)

		it("focus mode limits ambient behavior to idle, sit, blink, groom and sleep", function()
			local counts, decisions = ambient(2000, {
				env = { busy = true },
				config = factories.config({ behavior = { activity = "chaos" } }),
				profile = factories.profile({ needs = { boredom = 0.9 }, mood = "playful" }),
			})
			for name in counts do
				expect(name == "idle" or name == "sit" or name == "blink" or name == "groom" or name == "sleep").toBeTruthy()
			end
			expect(counts.idle or 0).toBeGreaterThan(0)
			for _, d in decisions do
				expect(d.sound).toBeNil()
				expect(d.reason).toContain("command is running")
			end
		end)

		it("focus mode cuts a moving or reactive decision short instead of letting it play out", function()
			for _, anim in { "walk", "hop", "swat", "stare", "happy" } do
				local s = behavior.newState(0)
				s.current = {
					id = `ambient.{anim}`,
					animation = anim :: any,
					intensity = 1,
					duration_ms = 6000,
					reason = "test",
				}
				s.until_ms = 6000
				local _, d = behavior.tick(s, makeCtx({ now_ms = 100, env = { busy = true } }))
				expect(d).notToBeNil()
				expect(d.id).toBe(`ambient.focus`)
				-- A command starting mid-walk settles the cat at once, without waiting for a tick.
				local _, r = behavior.react(s, started("build"), makeCtx({ now_ms = 100, env = { busy = true } }))
				expect(r).notToBeNil()
				expect(r.id).toBe("ambient.focus")
			end
			-- A calm decision is left alone.
			local calm = behavior.newState(0)
			local _, none = behavior.tick(calm, makeCtx({ now_ms = 100, env = { busy = true } }))
			expect(none).toBeNil()
		end)

		it("focus mode suppresses reactions and does not wake a napping cat", function()
			local config = eagerConfig()
			local s = behavior.newState(0)
			for _, ev in { finished("test", 1), finished("list", 0), started("sudo"), paneEv("created"), focusEv() } do
				local _, d = behavior.react(s, ev, makeCtx({ now_ms = 5000, config = config, env = { busy = true } }))
				expect(d).toBeNil()
			end
			for seed = 1, 30 do
				local asleep = asleepState(0, seed)
				local s2, d = behavior.react(
					asleep,
					started("build"),
					makeCtx({ now_ms = 5000, seed = seed, config = config, env = { busy = true } })
				)
				expect(d).toBeNil()
				expect(s2.posture).toBe("asleep")
			end
		end)

		it("explicit gestures still respond in focus mode, silently", function()
			for _, g in { "pet", "poke", "feed", "play" } do
				for seed = 1, 20 do
					local _, d = behavior.react(
						behavior.newState(0),
						gestureEv(g),
						makeCtx({ now_ms = 10, seed = seed, env = { busy = true } })
					)
					expect(d).notToBeNil()
					expect(d.sound).toBeNil()
				end
			end
			local _, hop = behavior.react(
				behavior.newState(0),
				gestureEv("perform", "hop"),
				makeCtx({ now_ms = 10, env = { busy = true } })
			)
			expect(hop.animation).toBe("hop")
			-- And the gesture is not cut short by the next tick.
			local s, d = behavior.react(
				behavior.newState(0),
				gestureEv("perform", "walk"),
				makeCtx({ now_ms = 10, env = { busy = true } })
			)
			expect(d.animation).toBe("walk")
			local _, cut = behavior.tick(s, makeCtx({ now_ms = 20, env = { busy = true } }))
			expect(cut).toBeNil()
		end)

		it("drops a reaction queued behind a wake when focus mode began meanwhile", function()
			local config = eagerConfig({ allow_pane_reactions = true })
			for seed = 1, 60 do
				local s = asleepState(0, seed)
				local d
				s, d = behavior.react(s, paneEv("created"), makeCtx({ now_ms = 5000, seed = seed, config = config }))
				if d and d.animation == "wake" and s.pending then
					local _, next =
						behavior.tick(s, makeCtx({ now_ms = s.until_ms, seed = seed, env = { busy = true } }))
					expect(next).notToBeNil()
					expect(next.id).toBe("ambient.focus")
					return
				end
			end
			error("no seed woke the cat for a pane reaction")
		end)

		it("quiet hours beat focus mode (no idle or sit)", function()
			local counts, decisions = ambient(1000, { env = { busy = true, quiet_hours = true } })
			for name in counts do
				expect(name == "sleep" or name == "blink" or name == "groom").toBeTruthy()
			end
			for _, d in decisions do
				expect(d.reason).toContain("Quiet hours")
			end
		end)

		it("focus mode beats reduced motion (no look, stretch or swat), which still zeroes intensity", function()
			local config = factories.config({ behavior = { activity = "chaos" } })
			local still = ambient(2000, { env = { reduced_motion = true }, config = config })
			expect((still.look or 0) + (still.swat or 0)).toBeGreaterThan(0)
			local counts, decisions = ambient(2000, { env = { reduced_motion = true, busy = true }, config = config })
			expect(counts.look).toBeNil()
			expect(counts.stretch).toBeNil()
			expect(counts.swat).toBeNil()
			for _, d in decisions do
				expect(d.intensity).toBe(0)
			end
		end)

		it("snooze beats focus mode", function()
			local counts = ambient(300, { env = { busy = true, snoozed = true } })
			for name in counts do
				expect(name).toBe("sleep")
			end
		end)

		it("a finished command reacts normally once nothing is running", function()
			local _, d = behavior.react(
				behavior.newState(0),
				finished("build", 0),
				makeCtx({ now_ms = 5000, config = eagerConfig() })
			)
			expect(d).notToBeNil()
			expect(string.sub(d.id, 1, 6)).toBe("react.")
		end)

		it("toggles remove whole families even when the preset favors them", function()
			local config = factories.config({
				behavior = { activity = "chaos", allow_swats = false, allow_pacing = false },
			})
			local counts = ambient(3000, { config = config })
			expect(counts.swat).toBeNil()
			expect(counts.hop).toBeNil()
			expect(counts.walk).toBeNil()
			for seed = 1, 30 do
				local ctx = makeCtx({ now_ms = 10, seed = seed, config = config })
				local _, play = behavior.react(behavior.newState(0), gestureEv("play"), ctx)
				expect(play.animation).toBe("play")
				local _, swat = behavior.react(behavior.newState(0), gestureEv("perform", "swat"), ctx)
				expect(swat.animation).toBe("play")
				local _, walk = behavior.react(behavior.newState(0), gestureEv("perform", "walk"), ctx)
				expect(walk.animation ~= "walk").toBeTruthy()
			end
		end)

		it("disabling command reactions silences every command rule", function()
			local config = eagerConfig({ allow_command_reactions = false })
			local s = behavior.newState(0)
			local now = 0
			for _, ev in { finished("other", 0), finished("other", 1), started("sudo"), finished("list", 0) } do
				now += 5000
				local d
				s, d = behavior.react(s, ev, makeCtx({ now_ms = now, config = config }))
				expect(d).toBeNil()
			end
			for _ = 1, 5 do
				now += 5000
				local d
				s, d = behavior.react(s, finished("test", 1), makeCtx({ now_ms = now, config = config }))
				expect(d).toBeNil()
			end
		end)

		it("disabling pane reactions silences pane events", function()
			local config = eagerConfig({ allow_pane_reactions = false })
			local _, d =
				behavior.react(behavior.newState(0), paneEv("created"), makeCtx({ now_ms = 10, config = config }))
			expect(d).toBeNil()
		end)
	end)

	describe("command reactions", function()
		it("reacts to success with a pleased happy or blink", function()
			for seed = 1, 20 do
				local _, d = behavior.react(
					behavior.newState(0),
					finished("build", 0),
					makeCtx({
						now_ms = 10,
						seed = seed,
						config = eagerConfig(),
					})
				)
				expect(d.animation == "happy" or d.animation == "blink").toBeTruthy()
				expect(d.id).toBe("react.command_ok")
				expect(d.reason).toContain("succeeded")
			end
		end)

		it("reacts to failure with a worried look", function()
			for seed = 1, 20 do
				local _, d = behavior.react(
					behavior.newState(0),
					finished("build", 1),
					makeCtx({
						now_ms = 10,
						seed = seed,
						config = eagerConfig(),
					})
				)
				expect(d.animation == "disappointed" or d.animation == "look").toBeTruthy()
				expect(d.id).toBe("react.command_failed")
			end
		end)

		it("samples reactions instead of reacting to every command", function()
			local _, d = behavior.react(
				behavior.newState(0),
				finished("build", 0),
				makeCtx({
					now_ms = 10,
					config = eagerConfig({ reaction_sample_rate = 0 }),
				})
			)
			expect(d).toBeNil()
			local reacted = 0
			local s = behavior.newState(0)
			local r = rng.new(11)
			local config = eagerConfig({ reaction_sample_rate = 0.3 })
			for i = 1, 1000 do
				local dd
				s, dd =
					behavior.react(s, finished("build", 0), makeCtx({ now_ms = i * 2000, rng = r, config = config }))
				if dd then
					reacted += 1
				end
			end
			expect(reacted).toBeGreaterThan(200)
			expect(reacted).toBeLessThan(400)
		end)

		it("rate-limits each trigger by the configured cooldown", function()
			local config = eagerConfig({ reaction_cooldown_s = 30 })
			local s = behavior.newState(0)
			local d
			s, d = behavior.react(s, finished("build", 0), makeCtx({ now_ms = 1000, config = config }))
			expect(d).notToBeNil()
			s, d = behavior.react(s, finished("build", 0), makeCtx({ now_ms = 30999, config = config }))
			expect(d).toBeNil()
			s, d = behavior.react(s, finished("build", 1), makeCtx({ now_ms = 31000, config = config }))
			expect(d).notToBeNil()
			s, d = behavior.react(s, finished("build", 0), makeCtx({ now_ms = 31000, config = config }))
			expect(d).notToBeNil()
		end)

		it("bounds reactions under an event storm of 1000 commands in one second", function()
			for _, config in { factories.config(), eagerConfig() } do
				local s = behavior.newState(0)
				local r = rng.new(21)
				local driver = rng.new(22)
				local cats = { "test", "build", "list", "other", "vcs" }
				local reactions = 0
				for i = 1, 1000 do
					local ev = finished(cats[driver:int(1, #cats)], if driver:chance(0.5) then 0 else 1)
					local d
					s, d = behavior.react(s, ev, makeCtx({ now_ms = 10000 + i, rng = r, config = config }))
					if d then
						reactions += 1
					end
				end
				expect(reactions).toBeLessThanOrEqual(4)
			end
		end)

		it("flops dramatically after three failing test runs in a row", function()
			local config = eagerConfig({ reaction_sample_rate = 0 })
			local s = behavior.newState(0)
			local d
			s, d = behavior.react(s, finished("test", 1), makeCtx({ now_ms = 1000, config = config }))
			expect(d).toBeNil()
			s, d = behavior.react(s, finished("test", 1), makeCtx({ now_ms = 2000, config = config }))
			expect(d).toBeNil()
			expect(s.fail_streak).toBe(2)
			s, d = behavior.react(s, finished("test", 1), makeCtx({ now_ms = 3000, config = config }))
			expect(d.animation).toBe("flop")
			expect(d.id).toBe("react.fail_streak")
			expect(d.reason).toContain("test")
			expect(s.fail_streak).toBe(0)
		end)

		it("only counts consecutive test failures toward the flop", function()
			local config = eagerConfig({ reaction_sample_rate = 0 })
			local s = behavior.newState(0)
			local d
			s = behavior.react(s, finished("test", 1), makeCtx({ now_ms = 1000, config = config }))
			s = behavior.react(s, finished("test", 1), makeCtx({ now_ms = 2000, config = config }))
			s = behavior.react(s, finished("build", 1), makeCtx({ now_ms = 3000, config = config }))
			expect(s.fail_streak).toBe(2)
			s = behavior.react(s, finished("test", 0), makeCtx({ now_ms = 4000, config = config }))
			expect(s.fail_streak).toBe(0)
			s, d = behavior.react(s, finished("test", 1), makeCtx({ now_ms = 5000, config = config }))
			expect(d).toBeNil()
		end)

		it("does not flop when development reactions are disabled", function()
			local config = eagerConfig({ reaction_sample_rate = 0, allow_development_reactions = false })
			local s = behavior.newState(0)
			local d
			for i = 1, 5 do
				s, d = behavior.react(s, finished("test", 1), makeCtx({ now_ms = i * 2000, config = config }))
				expect(d).toBeNil()
			end
		end)

		it("stares suspiciously when sudo starts", function()
			local _, d = behavior.react(behavior.newState(0), started("sudo"), makeCtx({ now_ms = 10 }))
			expect(d.animation).toBe("stare")
			expect(d.id).toBe("react.sudo")
			expect(d.reason).toContain("sudo")
			local _, other = behavior.react(behavior.newState(0), started("build"), makeCtx({ now_ms = 10 }))
			expect(other).toBeNil()
		end)

		it("swats an imaginary character after ls when swats and development reactions are on", function()
			local _, d = behavior.react(
				behavior.newState(0),
				finished("list", 0),
				makeCtx({ now_ms = 10, config = eagerConfig() })
			)
			expect(d.animation).toBe("swat")
			expect(d.id).toBe("react.ls_swat")
			expect(d.sound).toBe("swat")
			for _, off in { { allow_swats = false }, { allow_development_reactions = false } } do
				for seed = 1, 20 do
					local _, dd = behavior.react(
						behavior.newState(0),
						finished("list", 0),
						makeCtx({
							now_ms = 10,
							seed = seed,
							config = eagerConfig(off),
						})
					)
					expect(dd == nil or dd.animation ~= "swat").toBeTruthy()
				end
			end
		end)

		it("hops or looks when panes open or close", function()
			for _, kind in { "created", "closed" } do
				for seed = 1, 20 do
					local _, d =
						behavior.react(behavior.newState(0), paneEv(kind), makeCtx({ now_ms = 10, seed = seed }))
					expect(d.animation == "hop" or d.animation == "look").toBeTruthy()
					expect(d.id).toBe("react.pane")
				end
			end
		end)

		it("never puts command text in reasons", function()
			local config = eagerConfig()
			local s = behavior.newState(0)
			local now = 0
			for _, ev in { finished("test", 1), finished("list", 0), started("sudo"), finished("network", 0) } do
				now += 2000
				local d
				s, d = behavior.react(s, ev, makeCtx({ now_ms = now, config = config }))
				if d then
					expect(d.reason).notToContain("/")
					expect(d.reason).notToContain("ls ")
				end
			end
		end)
	end)

	describe("activity and waking", function()
		it("records user activity from focus and commands", function()
			local s = behavior.newState(0)
			s = behavior.react(s, focusEv(), makeCtx({ now_ms = 5000 }))
			expect(s.last_activity_ms).toBe(5000)
			s = behavior.react(s, started("build"), makeCtx({ now_ms = 9000 }))
			expect(s.last_activity_ms).toBe(9000)
		end)

		it("wakes a curious cat when input resumes, then looks around", function()
			local config = factories.config({ personality = { curiosity = 1, mischief = 1 } })
			local s = asleepState(0)
			local d
			s, d = behavior.react(s, focusEv(), makeCtx({ now_ms = 5000, config = config }))
			expect(d.animation).toBe("wake")
			expect(s.posture).toBe("awake")
			s, d = behavior.tick(s, makeCtx({ now_ms = s.until_ms, config = config }))
			expect(d.animation).toBe("look")
		end)

		it("lets an incurious cat sleep through input", function()
			local config = factories.config({ personality = { curiosity = 0, mischief = 0 } })
			for seed = 1, 30 do
				local s = asleepState(0)
				local s2, d = behavior.react(s, focusEv(), makeCtx({ now_ms = 5000, seed = seed, config = config }))
				expect(d).toBeNil()
				expect(s2.posture).toBe("asleep")
				expect(s2.last_activity_ms).toBe(5000)
			end
		end)

		it("routes reactions for a sleeping cat through wake, never straight to airborne", function()
			local config = factories.config({ personality = { curiosity = 1, mischief = 1 } })
			for seed = 1, 30 do
				local s = asleepState(0, seed)
				local _, d =
					behavior.react(s, paneEv("created"), makeCtx({ now_ms = 5000, seed = seed, config = config }))
				expect(d.animation).toBe("wake")
			end
		end)
	end)

	describe("gestures", function()
		it("purrs when petted", function()
			local _, d = behavior.react(behavior.newState(0), gestureEv("pet"), makeCtx({ now_ms = 10 }))
			expect(d.animation).toBe("pet")
			expect(d.sound).toBe("purr")
			expect(d.id).toBe("gesture.pet")
		end)

		it("reacts to pokes, food and play", function()
			for seed = 1, 30 do
				local ctx = makeCtx({ now_ms = 10, seed = seed })
				local _, poke = behavior.react(behavior.newState(0), gestureEv("poke"), ctx)
				expect(poke.animation == "poke" or poke.animation == "startled").toBeTruthy()
				local _, feed = behavior.react(behavior.newState(0), gestureEv("feed"), ctx)
				expect(feed.animation).toBe("eat")
				local _, play = behavior.react(behavior.newState(0), gestureEv("play"), ctx)
				expect(play.animation == "play" or play.animation == "swat").toBeTruthy()
			end
		end)

		it("performs requested canonical animations, including sleep", function()
			local s, d = behavior.react(behavior.newState(0), gestureEv("perform", "stretch"), makeCtx({ now_ms = 10 }))
			expect(d.animation).toBe("stretch")
			expect(d.reason).toContain("stretch")
			s, d = behavior.react(s, gestureEv("perform", "sleep"), makeCtx({ now_ms = 20 }))
			expect(d.animation).toBe("sleep")
			expect(s.posture).toBe("asleep")
		end)

		it("ignores perform requests for unknown animations", function()
			local _, d =
				behavior.react(behavior.newState(0), gestureEv("perform", "moonwalk"), makeCtx({ now_ms = 10 }))
			expect(d).toBeNil()
		end)

		it("counts gestures as activity and responds despite reaction cooldowns", function()
			local s = behavior.newState(0)
			local d
			for i = 1, 10 do
				s, d = behavior.react(s, gestureEv("pet"), makeCtx({ now_ms = i * 10 }))
				expect(d).notToBeNil()
			end
			expect(s.last_activity_ms).toBe(100)
		end)
	end)

	describe("state machine invariants", function()
		it("holds across 10,000 random ticks and events", function()
			local driver = rng.new(4242)
			local engineRng = rng.new(777)
			local configs = {
				eagerConfig(),
				factories.config(),
				factories.config({
					behavior = {
						activity = "chaos",
						allow_swats = false,
						allow_pacing = false,
						allow_command_reactions = false,
						allow_pane_reactions = false,
						allow_idle_sleep = false,
					},
				}),
				factories.config({ behavior = { activity = "zen" } }),
			}
			local profiles = {
				factories.profile(),
				factories.profile({ needs = { energy = 0.1 }, mood = "sleepy" }),
				factories.profile({ needs = { boredom = 0.9 }, mood = "playful" }),
			}
			local cats = { "test", "build", "vcs", "list", "sudo", "editor", "network", "package", "other" }
			local gestures = { "pet", "poke", "feed", "play", "perform" }
			local performs = { "stretch", "sleep", "hop", "walk", "swat", "wake", "moonwalk", "startled" }

			local state = behavior.newState(0)
			local now = 0
			for _ = 1, 10000 do
				now += driver:int(0, 15000)
				local env = {
					reduced_motion = driver:chance(0.2),
					quiet_hours = driver:chance(0.2),
					snoozed = driver:chance(0.15),
					busy = driver:chance(0.2),
				}
				local config = configs[driver:int(1, #configs)]
				local ctx = makeCtx({
					now_ms = now,
					rng = engineRng,
					config = config,
					profile = profiles[driver:int(1, #profiles)],
					env = env,
				})
				local before = state
				local d
				local roll = driver:int(1, 10)
				if roll <= 5 then
					state, d = behavior.tick(state, ctx)
				else
					local ev
					local kind = driver:int(1, 6)
					if kind == 1 then
						ev = finished(cats[driver:int(1, #cats)], driver:int(0, 2))
					elseif kind == 2 then
						ev = started(cats[driver:int(1, #cats)])
					elseif kind == 3 then
						ev = paneEv(if driver:chance(0.5) then "created" else "closed")
					elseif kind == 4 then
						ev = focusEv()
					else
						ev = gestureEv(gestures[driver:int(1, #gestures)], performs[driver:int(1, #performs)])
					end
					state, d = behavior.react(state, ev, ctx)
				end

				local cur = state.current
				expect(cur).notToBeNil()
				local expectedPosture = if cur.animation == "sleep" then "asleep" else "awake"
				if state.posture ~= expectedPosture then
					error(`posture {state.posture} with current {cur.animation}`)
				end
				expect(state.until_ms).toBeGreaterThanOrEqual(state.started_ms)
				expect(state.fail_streak).toBeLessThanOrEqual(behavior.MAX_FAIL_STREAK)

				if d then
					expectWellFormed(d)
					expect(cur).toEqual(d)
					if before.posture == "asleep" and d.animation ~= "sleep" and d.animation ~= "wake" then
						error(`asleep -> {d.animation} without wake ({d.id})`)
					end
					if env.snoozed and d.animation ~= "sleep" and not string.find(d.id, "gesture.", 1, true) then
						error(`snoozed but decided {d.animation} ({d.id})`)
					end
					if env.quiet_hours then
						expect(d.sound).toBeNil()
						expect(string.sub(d.id, 1, 6) ~= "react.").toBeTruthy()
						if string.sub(d.id, 1, 8) == "ambient." then
							local a = d.animation
							if a ~= "sleep" and a ~= "blink" and a ~= "groom" and a ~= "wake" then
								error(`quiet hours ambient {a}`)
							end
						end
					end
					if env.busy then
						expect(d.sound).toBeNil()
						expect(string.sub(d.id, 1, 6) ~= "react.").toBeTruthy()
						if string.sub(d.id, 1, 8) == "ambient." then
							local a = d.animation
							local calm = a == "idle" or a == "sit" or a == "blink" or a == "groom" or a == "sleep"
							if not calm and a ~= "wake" then
								error(`focus mode ambient {a}`)
							end
						end
					end
					if env.reduced_motion then
						expect(d.intensity).toBe(0)
						expect(d.animation ~= "walk" and d.animation ~= "hop" and d.animation ~= "startled").toBeTruthy()
					end
					local b = config.behavior
					if not b.allow_swats then
						expect(d.animation ~= "swat").toBeTruthy()
					end
					if not b.allow_pacing then
						expect(d.animation ~= "walk").toBeTruthy()
					end
					if not b.allow_command_reactions then
						for _, prefix in { "react.command", "react.sudo", "react.fail_streak", "react.ls_swat" } do
							expect(string.find(d.id, prefix, 1, true)).toBeNil()
						end
					end
					if not b.allow_pane_reactions then
						expect(string.find(d.id, "react.pane", 1, true)).toBeNil()
					end
				end
			end
		end)
	end)
end)
