--!strict
-- Host hook registration. A command line is reduced to its category inside the handler and
-- dropped there: sinks never receive, log, store or forward the line. The `title` hook is not
-- used (shells retitle on every prompt; it carries no user signal) and `spawn` is never used.

local T = require("../types")
local events = require("../core/events")

export type Sink = {
	commandStarted: (pane: number?, category: T.CommandCategory) -> (),
	commandFinished: (pane: number?, category: T.CommandCategory, status: number?, took_ms: number?) -> (),
	pane: (pane: number?, kind: "cwd" | "exited") -> (),
	-- Called with the hook name when a sink raised (never with event data).
	failed: (hook: string, err: string) -> (),
}

export type On = (name: string, fn: (...any) -> ...any) -> ()

local HOOKS = { "command_started", "command_finished", "cwd", "pane_exited" }

local function num(v: any): number?
	return if type(v) == "number" and v == v then v else nil
end

local function guard(sink: Sink, hook: string, fn: () -> ())
	local ok, err = pcall(fn :: any)
	if not ok then
		pcall(sink.failed, hook, tostring(err))
	end
end

local function register(on: On, sink: Sink)
	on("command_started", function(ev: any, _cx: any)
		local category: T.CommandCategory = events.classify(if type(ev) == "table" then ev.line else nil)
		local pane = if type(ev) == "table" then num(ev.pane) else nil
		guard(sink, "command_started", function()
			sink.commandStarted(pane, category)
		end)
	end)
	on("command_finished", function(ev: any, _cx: any)
		local category: T.CommandCategory = events.classify(if type(ev) == "table" then ev.line else nil)
		local pane, status, took = nil, nil, nil
		if type(ev) == "table" then
			pane, status, took = num(ev.pane), num(ev.status), num(ev.took_ms)
		end
		guard(sink, "command_finished", function()
			sink.commandFinished(pane, category, status, took)
		end)
	end)
	on("cwd", function(ev: any, _cx: any)
		local pane = if type(ev) == "table" then num(ev.pane) else nil
		guard(sink, "cwd", function()
			sink.pane(pane, "cwd")
		end)
	end)
	on("pane_exited", function(ev: any, _cx: any)
		local pane = if type(ev) == "table" then num(ev.pane) else nil
		guard(sink, "pane_exited", function()
			sink.pane(pane, "exited")
		end)
	end)
end

return {
	HOOKS = HOOKS,
	register = register,
}
