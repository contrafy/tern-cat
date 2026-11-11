--!strict
local t = require("../../lib/test")
local budget = require("../../../cat/window/budget")

local describe, it, expect = t.describe, t.it, t.expect

type Timer = { ms: number, fn: (any) -> (), cancelled: boolean }

type World = {
	now: number,
	timers: { Timer },
	logs: { string },
	timer: budget.TimerPort,
}

local function world(): World
	local w: World = { now = 0, timers = {}, logs = {}, timer = nil :: any }
	w.timer = function(ms: number, fn: (any) -> ()): budget.Handle
		local entry = { ms = ms, fn = fn, cancelled = false }
		table.insert(w.timers, entry)
		return {
			cancel = function(_self: any)
				entry.cancelled = true
			end,
		}
	end
	return w
end

local function live(w: World): { Timer }
	local out = {}
	for _, timer in w.timers do
		if not timer.cancelled then
			table.insert(out, timer)
		end
	end
	return out
end

-- Fires the oldest live timer inside a coroutine. A callback that yields stands for one Tern stops
-- for running over its budget: nothing after the yield runs, and pcall cannot catch it.
local function fire(w: World): boolean
	local timer = live(w)[1]
	assert(timer, "no live timer")
	timer.cancelled = true
	local co = coroutine.create(timer.fn)
	local ok, err = coroutine.resume(co, {})
	assert(ok, tostring(err))
	return coroutine.status(co) == "dead"
end

local function stopped()
	coroutine.yield()
end

describe("window/budget guard", function()
	it("cancels the backup once the callback returns", function()
		local w = world()
		local runs = 0
		budget.guard(w.timer, 100, function(_cx: any)
			runs += 1
		end)
		expect(#live(w)).toBe(1)
		expect(fire(w)).toBe(true)
		expect(runs).toBe(1)
		expect(#live(w)).toBe(0)
	end)

	it("reruns a callback Tern stopped from its backup timer", function()
		local w = world()
		local runs = 0
		budget.guard(w.timer, 100, function(_cx: any)
			runs += 1
			if runs == 1 then
				stopped()
			end
		end)
		expect(fire(w)).toBe(false)
		local backup = live(w)
		expect(#backup).toBe(1)
		expect(backup[1].ms).toBe(budget.BACKUP_MS)
		expect(fire(w)).toBe(true)
		expect(runs).toBe(2)
		expect(#live(w)).toBe(0)
	end)

	it("cancels the timer and a pending backup together", function()
		local w = world()
		local runs = 0
		local handle = budget.guard(w.timer, 100, function(_cx: any)
			runs += 1
			stopped()
		end)
		fire(w)
		expect(#live(w)).toBe(1)
		handle:cancel()
		expect(#live(w)).toBe(0)
		-- A backup that fires anyway (already due) does nothing after the cancel.
		local h2 = budget.guard(w.timer, 100, function(_cx: any)
			runs += 1
		end)
		h2:cancel()
		w.timers[#w.timers].fn({})
		expect(runs).toBe(1)
	end)

	it("lets the callback cancel and re-arm its own handle", function()
		local w = world()
		local handle: budget.Handle? = nil
		local runs = 0
		local function arm()
			if handle then
				handle:cancel()
			end
			handle = budget.guard(w.timer, 100, function(_cx: any)
				runs += 1
				arm()
			end)
		end
		arm()
		for _ = 1, 3 do
			fire(w)
			expect(#live(w)).toBe(1)
		end
		expect(runs).toBe(3)
	end)
end)

describe("window/budget run", function()
	local function steps(w: World, costs: { number }, runs: { number }, hooks: { [number]: () -> () }?): { budget.Step }
		local out = {}
		for i, cost in costs do
			runs[i] = 0
			table.insert(out, {
				name = `step{i}`,
				run = function(): { budget.Step }?
					runs[i] += 1
					w.now += cost
					local hook = hooks and hooks[i]
					if hook then
						hook()
					end
					return nil
				end,
			})
		end
		return out
	end

	local function start(w: World, list: { budget.Step }, slice_ms: number?): (budget.Runner, { number })
		local done = { 0 }
		local b = budget.run({
			steps = list,
			timer = w.timer,
			now = function(): number
				return w.now
			end,
			log = function(level: string, message: string)
				table.insert(w.logs, `{level}: {message}`)
			end,
			slice_ms = slice_ms,
			done = function(_b: budget.Runner)
				done[1] += 1
			end,
		})
		return b, done
	end

	it("stops a slice before the next step would pass the threshold", function()
		local w = world()
		local runs = {}
		local b, done = start(w, steps(w, { 6, 6, 6, 6, 6, 6, 6 }, runs), 20)
		local per: { number } = {}
		while #live(w) > 0 do
			local before = b.index
			local t0 = w.now
			fire(w)
			table.insert(per, b.index - before)
			expect(w.now - t0).toBeLessThanOrEqual(20)
		end
		expect(per).toEqual({ 3, 3, 1 })
		expect(done[1]).toBe(1)
		expect(b.slices).toBe(3)
		expect(b.max_slice_ms).toBe(18)
	end)

	it("shrinks slices after a slow step and always runs at least one step", function()
		local w = world()
		local runs = {}
		local b = start(w, steps(w, { 2, 30, 2, 2, 2 }, runs), 20)
		local per: { number } = {}
		while #live(w) > 0 do
			local before = b.index
			fire(w)
			table.insert(per, b.index - before)
		end
		-- 2 + 30 ran together (the estimate was 2 ms), then one step per slice.
		expect(per).toEqual({ 2, 1, 1, 1 })
		expect(b.finished).toBe(true)
	end)

	it("resumes after Tern stops a slice, retrying the cut-off step in a slice of its own", function()
		local w = world()
		local runs = {}
		local cut = false
		local b, done = start(
			w,
			steps(w, { 1, 1, 1, 1, 1, 1 }, runs, {
				[3] = function()
					if not cut then
						cut = true
						stopped()
					end
				end,
			}),
			20
		)
		expect(fire(w)).toBe(false)
		-- The continuation scheduled before the work is the retry (Tern runs it after the pause).
		expect(#live(w)).toBe(1)
		expect(b.index).toBe(3)
		fire(w)
		expect(b.index).toBe(4)
		while #live(w) > 0 do
			fire(w)
		end
		expect(runs).toEqual({ 1, 1, 2, 1, 1, 1 })
		expect(done[1]).toBe(1)
		expect(b.finished).toBe(true)
	end)

	it("retries a step that raised, then gives up after max attempts", function()
		local w = world()
		local runs = {}
		local fails = 2
		local b, done = start(
			w,
			steps(w, { 1, 1 }, runs, {
				[1] = function()
					if fails > 0 then
						fails -= 1
						error("disk hiccup")
					end
				end,
			})
		)
		while #live(w) > 0 do
			fire(w)
		end
		expect(runs).toEqual({ 3, 1 })
		expect(done[1]).toBe(1)
		expect(#w.logs).toBe(2)
		expect(w.logs[1]).toContain("step1 failed (attempt 1)")

		local w2 = world()
		local runs2 = {}
		local b2, done2 = start(
			w2,
			steps(w2, { 1 }, runs2, {
				[1] = function()
					error("syntax error")
				end,
			})
		)
		while #live(w2) > 0 do
			fire(w2)
		end
		expect(runs2[1]).toBe(budget.MAX_ATTEMPTS)
		expect(b2.failed).toBe("step1")
		expect(done2[1]).toBe(0)
		expect(w2.logs[#w2.logs]).toContain("error: tern-cat: gave up starting at step1")
		expect(b.failed).toBeNil()
	end)

	it("runs steps a step returns right after it", function()
		local w = world()
		local order: { string } = {}
		local function step(name: string, more: { budget.Step }?): budget.Step
			return {
				name = name,
				run = function(): { budget.Step }?
					table.insert(order, name)
					return more
				end,
			}
		end
		local _, done = start(w, { step("a", { step("a1"), step("a2") }), step("b") })
		while #live(w) > 0 do
			fire(w)
		end
		expect(order).toEqual({ "a", "a1", "a2", "b" })
		expect(done[1]).toBe(1)
	end)
end)
