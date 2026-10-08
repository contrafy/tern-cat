--!strict
local t = require("../../lib/test")
local running = require("../../../cat/core/running")

local describe, it, expect = t.describe, t.it, t.expect

describe("core.running", function()
	it("is busy only between a command's start and finish", function()
		local r = running.new()
		expect(running.busy(r, 0)).toBe(false)
		running.started(r, 3, 100)
		expect(running.busy(r, 200)).toBe(true)
		running.stopped(r, 3)
		expect(running.busy(r, 300)).toBe(false)
	end)

	it("tracks panes separately: one pane finishing leaves another busy", function()
		local r = running.new()
		running.started(r, 1, 100)
		running.started(r, 2, 150)
		running.stopped(r, 1)
		expect(running.busy(r, 200)).toBe(true)
		running.stopped(r, 2)
		expect(running.busy(r, 250)).toBe(false)
	end)

	it("forgets a pane that went away without a finish event", function()
		local r = running.new()
		running.started(r, 4, 100)
		-- pane_exited / pane_closed carry the pane id; they clear it like a finish.
		running.stopped(r, 4)
		expect(running.busy(r, 200)).toBe(false)
	end)

	it("times out a command whose finish was missed, so focus mode cannot stick", function()
		local r = running.new()
		running.started(r, 1, 1000)
		expect(running.busy(r, 1000 + running.STALE_MS - 1)).toBe(true)
		expect(running.busy(r, 1000 + running.STALE_MS)).toBe(false)
		-- The stale entry is gone: a later check at an earlier-looking time stays idle.
		expect(running.busy(r, 1000)).toBe(false)
	end)

	it("a restart in the same pane refreshes its start time", function()
		local r = running.new()
		running.started(r, 1, 0)
		running.started(r, 1, running.STALE_MS - 10)
		expect(running.busy(r, running.STALE_MS + 10)).toBe(true)
	end)

	it("pairs events that carry no pane id with each other", function()
		local r = running.new()
		running.started(r, nil, 0)
		running.stopped(r, 1)
		expect(running.busy(r, 10)).toBe(true)
		running.stopped(r, nil)
		expect(running.busy(r, 20)).toBe(false)
	end)
end)
