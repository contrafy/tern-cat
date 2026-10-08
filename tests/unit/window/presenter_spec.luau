--!strict
local t = require("../../lib/test")
local f = require("../../lib/factories")
local clock = require("../../../cat/core/clock")
local presenter = require("../../../cat/window/presenter")
local running = require("../../../cat/core/running")

local describe, it, expect = t.describe, t.it, t.expect

local function make(overrides: { [string]: any }?, clockOpts: clock.FakeOptions?)
	local c = clock.fake(clockOpts or { now_ms = 1000, wall_s = f.WALL_S })
	local p = presenter.new({
		clock = c,
		seed = 42,
		config = f.config(overrides),
		profile = f.profile(),
	})
	return p, c
end

local function runUntilChange(p: presenter.Presenter, c: clock.FakeClock, limit: number?): boolean
	for _ = 1, limit or 200 do
		c.advance(presenter.nextDelayMs(p))
		if presenter.tick(p) then
			return true
		end
	end
	return false
end

local ASSET = {
	sheet_url = "data:image/png;base64,iVBORw0KGgo=",
	frame_w = 32,
	frame_h = 32,
	durations_ms = { 100, 100, 100 },
	loop = false,
}

describe("window/presenter view", function()
	it("starts idle, visible and facing into the pane from its corner", function()
		local p = make()
		local v = presenter.view(p)
		expect(v.animation).toBe("idle")
		expect(v.hidden).toBe(false)
		expect(v.still).toBe(false)
		expect(v.facing).toBe("left")
		for corner, facing in
			{ ["top-right"] = "left", ["bottom-right"] = "left", ["top-left"] = "right", ["bottom-left"] = "right" }
		do
			expect(presenter.view((make({ rendering = { overlay_position = corner } }))).facing).toBe(facing)
		end
	end)

	it("turns into the pane when the corner changes", function()
		local p = make()
		presenter.setConfig(p, f.config({ rendering = { overlay_position = "bottom-left" } }))
		expect(presenter.view(p).facing).toBe("right")
	end)

	it("is hidden when the overlay is disabled in config", function()
		local p = make({ rendering = { overlay = false } })
		expect(presenter.view(p).hidden).toBe(true)
	end)

	it("lets a local override hide or show it immediately", function()
		local p = make()
		presenter.setOverlayOverride(p, false)
		expect(presenter.view(p).hidden).toBe(true)
		expect(presenter.visible(p)).toBe(false)
		presenter.setOverlayOverride(p, nil)
		expect(presenter.view(p).hidden).toBe(false)
		local q = make({ rendering = { overlay = false } })
		presenter.setOverlayOverride(q, true)
		expect(presenter.view(q).hidden).toBe(false)
	end)

	it("steps aside while the cat block floats over the focused pane", function()
		local p = make()
		presenter.setCovered(p, true)
		expect(presenter.view(p).hidden).toBe(true)
		expect(presenter.visible(p)).toBe(true)
		presenter.setCovered(p, false)
		expect(presenter.view(p).hidden).toBe(false)
	end)

	-- The overlay is drawn over terminal panes; users who forbid covering text get no overlay.
	it("is hidden when the cat may not cover terminal text, and shown again when allowed", function()
		local p = make({ behavior = { allow_visual_obscuring = false } })
		expect(presenter.view(p).hidden).toBe(true)
		local allowed = table.clone(p.config)
		allowed.behavior = table.clone(p.config.behavior)
		allowed.behavior.allow_visual_obscuring = true
		presenter.setConfig(p, allowed)
		expect(presenter.view(p).hidden).toBe(false)
	end)

	it("drops the override once config agrees with it", function()
		local p = make()
		presenter.setOverlayOverride(p, false)
		presenter.setConfig(p, f.config({ rendering = { overlay = false } }))
		expect(p.overlay_override).toBeNil()
		expect(presenter.view(p).hidden).toBe(true)
	end)

	it("shows a still frame for reduced motion from config or from Tern", function()
		local p = make({ rendering = { reduced_motion = "on" } })
		expect(presenter.view(p).still).toBe(true)
		expect(presenter.environment(p).reduced_motion).toBe(true)
		local q = make()
		presenter.setTernReducedMotion(q, true)
		expect(presenter.view(q).still).toBe(true)
		local r = make({ rendering = { reduced_motion = "off" } })
		presenter.setTernReducedMotion(r, true)
		expect(presenter.view(r).still).toBe(true)
	end)

	it("enables pointer reactions only while shown and allowed, and passes the look/swat sheets", function()
		expect(presenter.HOVER_ANIMATION).toBe("look")
		expect(presenter.PRESS_ANIMATION).toBe("swat")
		local p = make()
		local v = presenter.view(p)
		expect(v.reactions).toBe(true)
		local params = presenter.params(p, v, ASSET, { hover = ASSET, press = nil })
		local reactions = params.reactions
		assert(reactions, "missing reactions")
		expect(reactions.hover and reactions.hover.sheet_url).toBe(ASSET.sheet_url)
		expect(reactions.hover and reactions.hover.durations_ms).toEqual({ 100, 100, 100 })
		expect(reactions.press).toBeNil()
		presenter.setCovered(p, true)
		expect(presenter.view(p).reactions).toBe(false)
		local off = make({ behavior = { allow_pointer_reactions = false } })
		local offView = presenter.view(off)
		expect(offView.reactions).toBe(false)
		expect(presenter.params(off, offView, ASSET, { hover = ASSET, press = ASSET }).reactions).toBeNil()
	end)
end)

describe("window/presenter scheduling", function()
	it("does nothing before the current decision ends", function()
		local p = make()
		expect(presenter.tick(p)).toBe(false)
	end)

	it("waits between one and five seconds", function()
		local p = make()
		local d = presenter.nextDelayMs(p)
		expect(d).toBeGreaterThanOrEqual(1000)
		expect(d).toBeLessThanOrEqual(5000)
		p.engine.until_ms = p.clock.now_ms() + 100
		expect(presenter.nextDelayMs(p)).toBe(1000)
		p.engine.until_ms = p.clock.now_ms() + 60000
		expect(presenter.nextDelayMs(p)).toBe(5000)
	end)

	it("makes a new decision once the current one ends and bumps the sequence", function()
		local p, c = make()
		local before = p.seq
		expect(runUntilChange(p, c)).toBe(true)
		expect(p.seq).toBe(before + 1)
	end)

	it("alternates facing when the animation changes", function()
		local p, c = make()
		local flips, changes = 0, 0
		local facing = presenter.view(p).facing
		local anim = presenter.view(p).animation
		for _ = 1, 40 do
			if runUntilChange(p, c) then
				local v = presenter.view(p)
				if v.animation ~= anim then
					changes += 1
					if v.facing ~= facing then
						flips += 1
					end
				end
				facing, anim = v.facing, v.animation
			end
		end
		expect(changes).toBeGreaterThan(0)
		expect(flips).toBe(changes)
	end)

	it("paces only while walking with pacing allowed and motion not reduced", function()
		local p, c = make({ behavior = { allow_pacing = true }, personality = { energy = 1 } })
		local sawWalk = false
		for _ = 1, 300 do
			runUntilChange(p, c)
			local v = presenter.view(p)
			if v.animation == "walk" then
				sawWalk = true
				expect(v.pace).toBe(true)
			else
				expect(v.pace).toBe(false)
			end
		end
		expect(sawWalk).toBe(true)
		local q, qc = make({ behavior = { allow_pacing = false } })
		for _ = 1, 100 do
			runUntilChange(q, qc)
			expect(presenter.view(q).pace).toBe(false)
		end
	end)

	it("sleeps while snoozed", function()
		local p, c = make()
		presenter.setProfile(p, p.profile, f.WALL_S + 600)
		expect(presenter.environment(p).snoozed).toBe(true)
		presenter.tick(p)
		c.advance(1000)
		presenter.tick(p)
		expect(presenter.view(p).animation).toBe("sleep")
	end)

	it("respects quiet hours from config and local time", function()
		local p = make(
			{ quiet = { hours_enabled = true, start = "22:00", stop = "08:00" } },
			{ now_ms = 0, wall_s = f.WALL_S, hour = 23, min = 0 }
		)
		expect(presenter.environment(p).quiet_hours).toBe(true)
		local q = make(
			{ quiet = { hours_enabled = false, start = "22:00", stop = "08:00" } },
			{ now_ms = 0, wall_s = f.WALL_S, hour = 23, min = 0 }
		)
		expect(presenter.environment(q).quiet_hours).toBe(false)
	end)

	it("is busy in focus mode while any of this window's panes runs a command", function()
		local p, c = make({ behavior = { focus_mode = true } })
		expect(presenter.environment(p).busy).toBe(false)
		presenter.observe(p, "command_started", { pane = 1 })
		presenter.observe(p, "command_started", { pane = 2 })
		presenter.observe(p, "command_finished", { pane = 1, status = 0 })
		expect(presenter.environment(p).busy).toBe(true)
		presenter.observe(p, "pane_closed", { pane = 2 })
		expect(presenter.environment(p).busy).toBe(false)
		presenter.observe(p, "command_started", { pane = 3 })
		c.advance(running.STALE_MS)
		expect(presenter.environment(p).busy).toBe(false)
		local off = make()
		presenter.observe(off, "command_started", { pane = 1 })
		expect(presenter.environment(off).busy).toBe(false)
	end)

	it("never paces while a command runs in focus mode, and paces again once it finishes", function()
		local p, c = make({ behavior = { allow_pacing = true, focus_mode = true }, personality = { energy = 1 } })
		presenter.observe(p, "command_started", { pane = 1 })
		for _ = 1, 200 do
			runUntilChange(p, c)
			local v = presenter.view(p)
			expect(v.pace).toBe(false)
			local a = v.animation
			expect(a == "idle" or a == "sit" or a == "blink" or a == "groom" or a == "sleep").toBe(true)
		end
		presenter.observe(p, "command_finished", { pane = 1, status = 0 })
		presenter.react(p, presenter.eventFor(p, "command_finished", { pane = 1, status = 0 }) :: any)
		local sawWalk = false
		for _ = 1, 300 do
			runUntilChange(p, c)
			sawWalk = sawWalk or presenter.view(p).pace
		end
		expect(sawWalk).toBe(true)
	end)
end)

describe("window/presenter reactions", function()
	it("plays a gesture immediately", function()
		local p = make()
		expect(presenter.gesture(p, "pet")).toBe(true)
		expect(presenter.view(p).animation).toBe("pet")
	end)

	it("plays a mirrored host reaction", function()
		local p = make()
		expect(presenter.mirror(p, "happy")).toBe(true)
		expect(presenter.view(p).animation).toBe("happy")
		expect(presenter.mirror(p, "not-an-animation")).toBe(false)
	end)

	it("turns window events into category-only events and reacts", function()
		local p = make({ behavior = { reaction_sample_rate = 1 } })
		local ev = presenter.eventFor(p, "command_started", { pane = 1, line = "sudo cat /etc/secret-token" })
		assert(ev, "event")
		expect(ev.type).toBe("command_start")
		expect(ev.scope).toBe("window")
		expect(ev.attributes.category).toBe("sudo")
		local text = t.render(ev)
		expect(text).notToContain("secret-token")
		expect(text).notToContain("/etc")
		expect(presenter.react(p, ev)).toBe(true)
		expect(presenter.view(p).animation).toBe("stare")
	end)

	it("maps every subscribed window event", function()
		local p = make()
		local cases: { { any } } = {
			{ "focus", { pane = 1, tab = 2 }, "focus" },
			{ "pane_created", { pane = 1 }, "pane" },
			{ "pane_closed", { pane = 1 }, "pane" },
			{ "tab_created", { tab = 1 }, "pane" },
			{ "tab_closed", { tab = 1 }, "pane" },
			{ "command_started", { pane = 1, line = "ls" }, "command_start" },
			{ "command_finished", { pane = 1, line = "false", status = 1, took_ms = 5 }, "command_finish" },
			{ "cwd", { pane = 1, path = "/Users/me/private" }, "cwd" },
		}
		for _, case in cases do
			local ev = presenter.eventFor(p, case[1], case[2])
			assert(ev, case[1])
			expect(ev.type).toBe(case[3])
			expect(t.render(ev)).notToContain("private")
		end
		local finished =
			presenter.eventFor(p, "command_finished", { pane = 1, line = "false", status = 1, took_ms = 5 })
		assert(finished, "event")
		expect(finished.attributes.ok).toBe(false)
		expect(presenter.eventFor(p, "title", { pane = 1, title = "x" })).toBeNil()
		expect(presenter.eventFor(p, "focus", "garbage")).toBeNil()
	end)
end)

describe("window/presenter.params", function()
	it("builds overlay params from the view, asset and scale", function()
		local p = make({ rendering = { overlay_scale = 3 } })
		presenter.gesture(p, "pet")
		local v = presenter.view(p)
		local params = presenter.params(p, v, ASSET)
		expect(params.hidden).toBe(false)
		expect(params.scale).toBe(3)
		expect(params.sheet_url).toBe(ASSET.sheet_url)
		expect(params.durations_ms).toEqual({ 100, 100, 100 })
		expect(params.loop).toBe(false)
		expect(params.facing).toBe(v.facing)
		expect(params.position).toBe("top-right")
		expect(params.offset_px).toBe(12)
		local q = make({ rendering = { overlay_position = "bottom-left", overlay_offset_px = 30 } })
		local qp = presenter.params(q, presenter.view(q), ASSET)
		expect(qp.position).toBe("bottom-left")
		expect(qp.offset_px).toBe(30)
	end)

	it("restarts non-looping animations with a fresh keyframe name", function()
		local p = make()
		presenter.gesture(p, "pet")
		local a = presenter.params(p, presenter.view(p), ASSET)
		presenter.gesture(p, "pet")
		local b = presenter.params(p, presenter.view(p), ASSET)
		expect(a.anim_key == b.anim_key).toBe(false)
		local looping = table.clone(ASSET)
		looping.loop = true
		local c = presenter.params(p, presenter.view(p), looping)
		local d = presenter.params(p, presenter.view(p), looping)
		expect(c.anim_key).toBe(d.anim_key)
	end)

	it("freezes a still frame to a single frame without pacing", function()
		local p = make({ rendering = { reduced_motion = "on" } })
		local params = presenter.params(p, presenter.view(p), ASSET)
		expect(#params.durations_ms).toBe(3)
		expect(params.still).toBe(true)
		expect(params.pace).toBe(false)
	end)

	it("hides without an asset", function()
		local p = make()
		expect(presenter.params(p, presenter.view(p), nil).hidden).toBe(true)
	end)
end)
