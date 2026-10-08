--!strict
local t = require("../../lib/test")
local animations = require("../../../cat/render/animations")

local describe, it, expect = t.describe, t.it, t.expect

local ALL = {
	"idle",
	"walk",
	"sit",
	"sleep",
	"wake",
	"stretch",
	"groom",
	"blink",
	"look",
	"pet",
	"poke",
	"eat",
	"play",
	"happy",
	"disappointed",
	"swat",
	"startled",
	"flop",
	"stare",
	"hop",
	"dive",
	"emerge",
}

local function only(...: string): { [string]: boolean }
	local set = {}
	for _, name in { ... } do
		set[name] = true
	end
	return set
end

describe("render.animations", function()
	it("lists every canonical animation exactly once", function()
		expect(#animations.CANONICAL).toBe(#ALL)
		for _, name in ALL do
			expect(animations.CANONICAL).toContain(name)
			expect(animations.isCanonical(name)).toBeTruthy()
		end
		expect(animations.isCanonical("moonwalk")).toBeFalsy()
	end)

	it("gives every animation a fallback chain that ends in idle and never revisits itself", function()
		for _, name in ALL do
			local chain = animations.FALLBACKS[name]
			expect(chain).notToBeNil()
			if name ~= "idle" then
				expect(chain[#chain]).toBe("idle")
			end
			local seen = { [name] = true }
			for _, step in chain do
				expect(animations.isCanonical(step)).toBeTruthy()
				expect(seen[step]).toBeNil()
				seen[step] = true
			end
		end
	end)

	it("returns the wanted animation when the pack has it", function()
		expect(animations.resolve(only("idle", "stare"), "stare")).toBe("stare")
	end)

	it("walks the documented chains when a pack lacks an animation", function()
		expect(animations.resolve(only("idle", "look", "sit"), "stare")).toBe("look")
		expect(animations.resolve(only("idle", "sit"), "stare")).toBe("sit")
		expect(animations.resolve(only("idle", "play"), "swat")).toBe("play")
		expect(animations.resolve(only("idle", "happy"), "swat")).toBe("happy")
		expect(animations.resolve(only("idle", "disappointed"), "flop")).toBe("disappointed")
		expect(animations.resolve(only("idle", "hop"), "startled")).toBe("hop")
		expect(animations.resolve(only("idle", "happy"), "eat")).toBe("happy")
		expect(animations.resolve(only("idle", "blink"), "wake")).toBe("blink")
		expect(animations.resolve(only("idle", "hop"), "dive")).toBe("hop")
		expect(animations.resolve(only("idle", "blink"), "emerge")).toBe("blink")
	end)

	it("always lands on idle for minimal packs and unknown names", function()
		for _, name in ALL do
			local got = animations.resolve(only("idle"), name)
			expect(got).toBe("idle")
		end
		expect(animations.resolve(only("idle", "sit"), "moonwalk")).toBe("idle")
		expect(animations.resolve({}, "stare")).toBe("idle")
	end)

	it("accepts any truthy value in the availability map (e.g. AnimationSpec tables)", function()
		expect(animations.resolve({ idle = {}, look = { frames = {} } }, "stare")).toBe("look")
		expect(animations.resolve({ idle = {}, look = false }, "stare")).toBe("idle")
	end)

	it("loops resting states and plays reactions once", function()
		for _, name in { "idle", "walk", "sit", "sleep" } do
			expect(animations.isLoop(name)).toBeTruthy()
		end
		for _, name in { "happy", "swat", "flop", "wake", "poke", "hop", "blink", "dive", "emerge" } do
			expect(animations.isLoop(name)).toBeFalsy()
		end
	end)

	it("provides a positive default duration for every animation", function()
		for _, name in ALL do
			expect(animations.defaultDurationMs(name)).toBeGreaterThan(0)
		end
		expect(animations.defaultDurationMs("blink")).toBeLessThan(animations.defaultDurationMs("sleep"))
	end)

	it("times the pane-switch animations for the overlay transition", function()
		expect(animations.defaultDurationMs("dive")).toBe(480)
		expect(animations.defaultDurationMs("emerge")).toBe(640)
	end)

	it("keeps the pane-switch animations out of performances", function()
		for _, name in ALL do
			local transition = name == "dive" or name == "emerge"
			expect(animations.isPerformable(name)).toBe(not transition)
		end
		expect(animations.isPerformable("moonwalk")).toBe(false)
		expect(animations.isPerformable(nil)).toBe(false)
	end)
end)
