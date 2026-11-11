--!strict
-- Surviving Tern's per-call time budget in the window half (pure; timers and clock injected).
--
-- A window callback that runs past 50 ms is stopped with `tern: <hook> exceeded <n> ms`. pcall
-- cannot catch that error, so code after the work (re-arming a timer, scheduling the next boot
-- slice) never runs. Tern 0.9.6 and later then pause the hook (every timer callback, 5 s and
-- longer) instead of disabling it until reload, and run the timers that came due once the pause
-- ends (on the window's next event). Measured on 0.9.16: a timer created before the callback was
-- stopped fires after the pause. So both helpers schedule their follow-up before the work:
--
-- - `guard` wraps a timer callback with a backup timer that reruns it unless it finished;
-- - `run` executes a list of idempotent steps in time-boxed slices, each slice scheduling the
--   next first, retrying a step that was cut off (alone in its slice) up to `max_attempts` times.

export type Handle = { cancel: (self: any) -> () }
export type TimerPort = (ms: number, fn: (cx: any) -> ()) -> Handle

export type Step = {
	name: string,
	-- Must be idempotent: a step stopped part-way is run again. May return steps to run next.
	run: () -> { Step }?,
}

export type Opts = {
	steps: { Step },
	timer: TimerPort,
	now: () -> number,
	log: (level: "info" | "warn" | "error", message: string) -> (),
	-- A slice starts another step only while its elapsed time plus the slowest step seen so far
	-- stays within this many ms (default SLICE_MS). The first step of a slice always runs.
	slice_ms: number?,
	max_attempts: number?,
	done: (b: Runner) -> (),
}

export type Runner = {
	steps: { Step },
	index: number,
	slices: number,
	max_slice_ms: number,
	-- Longest single step so far (ms), the slice planner's estimate for the next one.
	estimate_ms: number,
	attempts: { [number]: number },
	finished: boolean,
	failed: string?,
	opts: Opts,
}

local SLICE_MS = 20
local MAX_ATTEMPTS = 5
local BACKUP_MS = 1000

-- `timer(ms, fn)` whose callback reruns from a backup timer (after `backup_ms`, so a callback that
-- fails every time repeats at most that often) when Tern stopped it before it returned. Cancelling
-- the returned handle cancels both.
local function guard(timer: TimerPort, ms: number, fn: (cx: any) -> (), backup_ms: number?): Handle
	local live: { cancelled: boolean, backup: Handle? } = { cancelled = false, backup = nil }
	local function run(cx: any)
		if live.cancelled then
			return
		end
		live.backup = timer(backup_ms or BACKUP_MS, run)
		fn(cx)
		local backup = live.backup
		live.backup = nil
		if backup then
			backup:cancel()
		end
	end
	local main = timer(ms, run)
	return {
		cancel = function(_self: any)
			live.cancelled = true
			main:cancel()
			local backup = live.backup
			live.backup = nil
			if backup then
				backup:cancel()
			end
		end,
	}
end

local function slice(b: Runner)
	if b.finished or b.failed then
		return
	end
	local opts = b.opts
	local tried = b.attempts[b.index] or 0
	if tried >= (opts.max_attempts or MAX_ATTEMPTS) then
		local name = b.steps[b.index].name
		b.failed = name
		opts.log("error", `tern-cat: gave up starting at {name} after {tried} attempts`)
		return
	end
	local limit = opts.slice_ms or SLICE_MS
	if tried > 0 then
		-- This step was cut off or failed before: give it a slice of its own.
		b.estimate_ms = math.max(b.estimate_ms, limit)
	end
	-- The next slice, and the retry when Tern stops this one (see the header).
	local continuation = opts.timer(0, function(_cx: any)
		slice(b)
	end)
	local t0 = opts.now()
	local ok, err = pcall(function()
		local ran = 0
		while b.index <= #b.steps do
			if ran > 0 and opts.now() - t0 + b.estimate_ms > limit then
				break
			end
			b.attempts[b.index] = (b.attempts[b.index] or 0) + 1
			local s0 = opts.now()
			local more = b.steps[b.index].run()
			b.estimate_ms = math.max(b.estimate_ms, opts.now() - s0)
			if more then
				for i, s in more do
					table.insert(b.steps, b.index + i, s)
				end
			end
			b.index += 1
			ran += 1
		end
	end)
	b.slices += 1
	b.max_slice_ms = math.max(b.max_slice_ms, opts.now() - t0)
	if not ok then
		local name = if b.steps[b.index] then b.steps[b.index].name else "?"
		opts.log("warn", `tern-cat: start step {name} failed (attempt {b.attempts[b.index] or 1}): {err}`)
		return
	end
	if b.index > #b.steps then
		continuation:cancel()
		b.finished = true
		opts.done(b)
	end
end

-- Schedules the first slice; returns the runner (its counters feed the "ready" log line).
local function run(opts: Opts): Runner
	local b: Runner = {
		steps = table.clone(opts.steps),
		index = 1,
		slices = 0,
		max_slice_ms = 0,
		estimate_ms = 0,
		attempts = {},
		finished = false,
		failed = nil,
		opts = opts,
	}
	if #b.steps == 0 then
		b.finished = true
		opts.done(b)
		return b
	end
	opts.timer(0, function(_cx: any)
		slice(b)
	end)
	return b
end

return {
	SLICE_MS = SLICE_MS,
	MAX_ATTEMPTS = MAX_ATTEMPTS,
	BACKUP_MS = BACKUP_MS,
	guard = guard,
	run = run,
}
