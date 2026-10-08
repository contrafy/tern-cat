--!strict
-- Commands running per pane, for focus mode (`behavior.focus_mode`). A pane is busy from its
-- command start until the command finishes or the pane goes away. An entry older than
-- STALE_MS is dropped, so a missed finish event (a plugin reload, a tab closed while a command
-- ran) cannot hold the cat in focus mode for good. Only pane ids and engine times are kept.

local STALE_MS = 6 * 60 * 60 * 1000
-- Key for events without a pane id; such starts and finishes pair with each other.
local NO_PANE = -1

-- Pane id -> engine ms its running command started.
export type Running = { [number]: number }

local function new(): Running
	return {}
end

local function started(r: Running, pane: number?, now_ms: number)
	r[pane or NO_PANE] = now_ms
end

local function stopped(r: Running, pane: number?)
	r[pane or NO_PANE] = nil
end

-- True while any pane runs a command that started less than STALE_MS ago; drops stale entries.
local function busy(r: Running, now_ms: number): boolean
	local any = false
	for pane, at in r do
		if now_ms - at >= STALE_MS then
			r[pane] = nil
		else
			any = true
		end
	end
	return any
end

return {
	STALE_MS = STALE_MS,
	new = new,
	started = started,
	stopped = stopped,
	busy = busy,
}
