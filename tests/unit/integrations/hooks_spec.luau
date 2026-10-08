--!strict
local t = require("../../lib/test")
local hooks = require("../../../cat/integrations/hooks")

local describe, it, expect = t.describe, t.it, t.expect

local SECRET = "curl -H 'Authorization: hunter2' https://x"

local function harness(): ({ [string]: (...any) -> ...any }, { { any } }, { string })
	local handlers: { [string]: (...any) -> ...any } = {}
	local calls: { { any } } = {}
	local failures: { string } = {}
	hooks.register(function(name: string, fn: (...any) -> ...any)
		handlers[name] = fn
	end, {
		commandStarted = function(...)
			table.insert(calls, { "started", ... })
		end,
		commandFinished = function(...)
			table.insert(calls, { "finished", ... })
		end,
		pane = function(...)
			table.insert(calls, { "pane", ... })
		end,
		failed = function(hook: string, _err: string)
			table.insert(failures, hook)
		end,
	})
	return handlers, calls, failures
end

local function flatten(calls: { { any } }): string
	local parts = {}
	for _, c in calls do
		for _, v in c do
			table.insert(parts, tostring(v))
		end
	end
	return table.concat(parts, " ")
end

describe("hooks", function()
	it("registers exactly the host hooks it uses, never spawn or title", function()
		local handlers = harness()
		local names = {}
		for name in handlers do
			table.insert(names, name)
		end
		table.sort(names)
		expect(names).toEqual({ "command_finished", "command_started", "cwd", "pane_exited" })
	end)

	it("passes only the category, never the command line", function()
		local handlers, calls = harness()
		handlers.command_started({ pane = 4, line = SECRET, cwd = "/home/me/secret" }, {})
		handlers.command_finished({ pane = 4, line = SECRET, status = 0, took_ms = 12 }, {})
		handlers.command_finished({ pane = 4, line = "cargo test", status = 101, took_ms = 9000 }, {})
		expect(calls[1]).toEqual({ "started", 4, "network" })
		expect(calls[2]).toEqual({ "finished", 4, "network", 0, 12 })
		expect(calls[3]).toEqual({ "finished", 4, "test", 101, 9000 })
		local all = flatten(calls)
		expect(string.find(all, "hunter2", 1, true)).toBeNil()
		expect(string.find(all, "secret", 1, true)).toBeNil()
	end)

	it("reduces cwd and exits to pane events without paths", function()
		local handlers, calls = harness()
		handlers.cwd({ pane = 2, path = "/Users/me/private" }, {})
		handlers.pane_exited({ pane = 2, status = 0 }, {})
		expect(calls).toEqual({ { "pane", 2, "cwd" }, { "pane", 2, "exited" } })
	end)

	it("survives malformed payloads and sink failures", function()
		local handlers = {}
		local failures = {}
		hooks.register(function(name: string, fn: (...any) -> ...any)
			handlers[name] = fn
		end, {
			commandStarted = function()
				error("boom " .. SECRET)
			end,
			commandFinished = function() end,
			pane = function() end,
			failed = function(hook: string)
				table.insert(failures, hook)
			end,
		})
		handlers.command_started(nil, nil)
		handlers.command_finished({ pane = "x", status = 0 / 0 }, nil)
		expect(failures).toEqual({ "command_started" })
	end)
end)
