--!strict
-- Red-team guard over the shipped plugin sources. Tern has no permission system, so the
-- promises in docs/security-privacy.md hold only if no shipped file reaches for these APIs.

local fs = require("@lune/fs")
local t = require("../lib/test")

local function luauFiles(dir: string, out: { string })
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			luauFiles(path, out)
		elseif string.match(entry, "%.luau$") then
			table.insert(out, path)
		end
	end
end

local function shipped(): { [string]: string }
	local paths = { "host.luau", "window.luau" }
	luauFiles("cat", paths)
	local out = {}
	for _, path in paths do
		out[path] = fs.readFile(path)
	end
	return out
end

local function offenders(sources: { [string]: string }, pattern: string, allowed: { string }?): { string }
	local hits = {}
	for path, text in sources do
		if string.find(text, pattern) and not (allowed and table.find(allowed, path)) then
			table.insert(hits, path)
		end
	end
	table.sort(hits)
	return hits
end

local FORBIDDEN = {
	{ "types into panes", "pane%.write" },
	{ "types into panes", "cx:run%s*%(" },
	{ "runs actions that can type text", "cx:action%s*%(" },
	{ "reads terminal output", "session:read%s*%(" },
	{ "waits for terminal output", "session:settle%s*%(" },
	{ "reads terminal output", "tern%.lens" },
	{ "sends data off the machine", "tern%.fetch" },
	{ "touches the clipboard", ":copy%s*%(" },
	{ "rewrites Tern settings", "settings:set" },
	{ "rewrites Tern settings", "settings:set_many" },
	{ "rewrites user keybinds", "settings:bind" },
	{ "rewrites user keybinds", "settings:unbind" },
	{ "replaces built-in commands", "tern%.override" },
	{ "intercepts shell spawns", 'on%(%s*"spawn"' },
	{ "starts visible Carly turns", "ask_carly" },
	{ "schedules full-power Carly turns", "carly%.schedule" },
	{ "starts agent panes", "cx%.agents" },
}

t.describe("safety: shipped sources", function()
	t.it("include the plugin entries and core modules", function()
		local sources = shipped()
		t.expect(sources["host.luau"]).notToBeNil()
		t.expect(sources["window.luau"]).notToBeNil()
		t.expect(sources["cat/core/behavior.luau"]).notToBeNil()
	end)

	for _, rule in FORBIDDEN do
		local why, pattern = rule[1], rule[2]
		t.it(`never call {pattern} ({why})`, function()
			t.expect(offenders(shipped(), pattern)).toEqual({})
		end)
	end

	t.it("spawn processes only from the host sound player", function()
		t.expect(offenders(shipped(), "process%.run", { "host.luau" })).toEqual({})
	end)

	t.it("send UI events only from the window half, to the cat's own block", function()
		t.expect(offenders(shipped(), "session:event", { "window.luau" })).toEqual({})
	end)

	t.it("keep the window half read-only on shared state (host is the single kv writer)", function()
		local sources = shipped()
		local windowSide = {}
		for path, text in sources do
			if path == "window.luau" or string.find(path, "^cat/window/") or path == "cat/integrations/carly.luau" then
				windowSide[path] = text
			end
		end
		t.expect(offenders(windowSide, "kv%.set")).toEqual({})
		t.expect(offenders(windowSide, "kv:set")).toEqual({})
	end)

	t.it("never write tern.kv except through the kv adapter", function()
		t.expect(offenders(shipped(), "tern%.kv%.set", { "cat/adapters/kv.luau" })).toEqual({})
	end)
end)
