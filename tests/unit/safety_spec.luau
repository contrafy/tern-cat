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

-- Like `offenders`, but first removes the exact `allowed` snippets from each file, so a reviewed
-- use stays allowed while any other match in the same file still fails.
local function offendersExcept(
	sources: { [string]: string },
	pattern: string,
	allowed: { [string]: { string } }
): { string }
	local hits = {}
	for path, text in sources do
		local rest = text .. "\n"
		for _, snippet in allowed[path] or {} do
			local at = string.find(rest, snippet, 1, true)
			assert(at, `allowed snippet no longer in {path}: {snippet}`)
			while at do
				rest = string.sub(rest, 1, at - 1) .. string.sub(rest, at + #snippet)
				at = string.find(rest, snippet, 1, true)
			end
		end
		if string.find(rest, pattern) then
			table.insert(hits, path)
		end
	end
	table.sort(hits)
	return hits
end

local function occurrences(text: string, pattern: string): number
	local n = 0
	for _ in string.gmatch(text, pattern) do
		n += 1
	end
	return n
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
	{ "reads stored secrets", "%f[%w_]secrets%f[^%w_]" },
	{ "runs arbitrary actions", "actions%s*[%.:]%s*run%f[^%w_]" },
	{ "drives the command palette", "%.palette%f[^%w_]" },
	{ "drives the command palette", "palette%s*:" },
}

-- Aliasing a dangerous API to a local defeats the literal guards above (`local p = tern.process;
-- p.run(...)`), so these may only be used through a direct field or method access.
local ALIASED = {
	"tern%.process",
	"tern%.fs",
	"tern%.kv",
	"tern%.fetch",
	"tern%.secrets",
	"tern%.lens",
	"cx%.session",
}

-- Reviewed dynamic accesses of the Tern SDK table. Each entry is an exact snippet.
local SDK_INDIRECTION: { [string]: { string } } = {
	-- Log helper: picks tern.log.<level> by name. host.luau also hands the UI builder to the
	-- pure block renderer, which types it structurally.
	["host.luau"] = { "(tern.log :: any)[level]", "tern.ui :: any" },
	["window.luau"] = { "tern.log[level](message)" },
	-- Adapters cast the SDK table once to their narrow Raw* port type.
	["cat/adapters/fs.luau"] = { "(tern.fs :: any)" },
	["cat/adapters/json.luau"] = { "(tern.json :: any)" },
	["cat/adapters/kv.luau"] = { "(tern.kv :: any)" },
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

	t.it("spawn processes only from the single host sound player call", function()
		local sources = shipped()
		t.expect(offenders(sources, "process%.run", { "host.luau" })).toEqual({})
		t.expect(occurrences(sources["host.luau"], "process%.run")).toBe(1)
	end)

	t.it("never index or cast the tern SDK table dynamically (defeats the literal guards)", function()
		local sources = shipped()
		t.expect(offendersExcept(sources, "%f[%w_]tern[%w_%.]*%s*%[", SDK_INDIRECTION)).toEqual({})
		t.expect(offendersExcept(sources, "%f[%w_]tern[%w_%.]*%s*::", SDK_INDIRECTION)).toEqual({})
	end)

	for _, api in ALIASED do
		t.it(`never alias {api} to a local`, function()
			t.expect(offenders(shipped(), "=%s*" .. api .. "%f[^%w_]%s*[^%.:%s]")).toEqual({})
		end)
	end

	t.it("touch the file system only through cat/adapters", function()
		local outside = {}
		for path, text in shipped() do
			if string.find(path, "^cat/adapters/") == nil then
				outside[path] = text
			end
		end
		t.expect(offenders(outside, "%f[%w_]tern%.fs%f[^%w_]")).toEqual({})
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
