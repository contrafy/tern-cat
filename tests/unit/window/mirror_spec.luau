--!strict
local t = require("../../lib/test")
local mirror = require("../../../cat/window/mirror")

local describe, it, expect = t.describe, t.it, t.expect

local function record(at: number, id: string, animation: string?): any
	return { at = at, id = id, animation = animation or "pet", reason = "You petted the cat." }
end

describe("window/mirror.check", function()
	it("plays a new, recent reaction and remembers it", function()
		local play, key = mirror.check(record(100.25, "gesture.pet"), nil, 102, nil)
		expect(play).toBe(true)
		expect(key).toBe(mirror.key(record(100.25, "gesture.pet")))
	end)

	it("does not replay a reaction it has already seen", function()
		local r = record(100, "gesture.pet")
		local _, key = mirror.check(r, nil, 101, nil)
		local play = mirror.check(r, key, 102, nil)
		expect(play).toBe(false)
	end)

	it("treats a different id at the same time as new", function()
		local _, key = mirror.check(record(100, "gesture.pet"), nil, 101, nil)
		local play = mirror.check(record(100, "react.command_ok", "blink"), key, 101, nil)
		expect(play).toBe(true)
	end)

	it("ignores reactions five seconds old or older (e.g. after a reload)", function()
		expect((mirror.check(record(100, "gesture.pet"), nil, 105, nil))).toBe(false)
		expect((mirror.check(record(100, "gesture.pet"), nil, 104.9, nil))).toBe(true)
	end)

	it("ignores reactions from the future beyond clock skew", function()
		expect((mirror.check(record(200, "gesture.pet"), nil, 100, nil))).toBe(false)
	end)

	it("handles a missing or malformed record", function()
		local play, key = mirror.check(nil, "k", 100, nil)
		expect(play).toBe(false)
		expect(key).toBe("k")
		local bad = mirror.check({ at = "soon", id = 3 } :: any, nil, 100, nil)
		expect(bad).toBe(false)
	end)

	it("skips the host echo of a gesture this window already played optimistically", function()
		local optimistic = { gesture = "poke", gesture_at = 100 }
		local play, key = mirror.check(record(100.4, "gesture.poke", "startled"), nil, 101, optimistic)
		expect(play).toBe(false)
		expect(key).toBe(mirror.key(record(100.4, "gesture.poke", "startled")))
		local woke = mirror.check(record(100.4, "wake.gesture.poke", "wake"), nil, 101, optimistic)
		expect(woke).toBe(false)
	end)

	it("still mirrors other gestures and gestures from elsewhere", function()
		local optimistic = { gesture = "poke", gesture_at = 100 }
		expect((mirror.check(record(100.4, "gesture.pet"), nil, 101, optimistic))).toBe(true)
		expect((mirror.check(record(90, "gesture.poke", "poke"), nil, 91, optimistic))).toBe(true)
	end)

	it("skips the host's command reaction when this window reacted to its own command event", function()
		local recent = { command_at = 100 }
		for _, id in { "react.command_ok", "react.command_failed", "react.fail_streak", "react.ls_swat", "react.sudo" } do
			expect((mirror.check(record(100.2, id, "happy"), nil, 101, recent))).toBe(false)
		end
		expect((mirror.check(record(100.2, "gesture.pet"), nil, 101, recent))).toBe(true)
		expect((mirror.check(record(90, "react.command_ok", "happy"), nil, 91, recent))).toBe(true)
	end)
end)
