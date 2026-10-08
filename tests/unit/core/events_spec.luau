--!strict
local t = require("../../lib/test")
local events = require("../../../cat/core/events")
local rng = require("../../../cat/core/rng")

local describe, it, expect = t.describe, t.it, t.expect

local CATEGORIES = {
	test = true,
	build = true,
	vcs = true,
	list = true,
	sudo = true,
	editor = true,
	network = true,
	package = true,
	other = true,
}

local function expectAll(category: string, lines: { string })
	for _, line in lines do
		local got = events.classify(line)
		if got ~= category then
			error(`classify({string.format("%q", line)}) = {got}, expected {category}`, 2)
		end
	end
end

local function base(overrides: { [string]: any }?): any
	local args: { [string]: any } = { pane = 3, time = 1700000000, scope = "host", id = "ev-1" }
	for k, v in overrides or {} do
		args[k] = v
	end
	return args
end

local function serialize(value: any): string
	return t.render(value)
end

describe("core.events", function()
	describe("classify", function()
		it("recognizes test runners so failing tests can drive the flop reaction", function()
			expectAll("test", {
				"pytest -q",
				"jest --watch",
				"vitest run",
				"cargo test --release",
				"cargo nextest run",
				"go test ./...",
				"bun test",
				"npm test",
				"npm run test",
				"pnpm test",
				"yarn test",
				"lune run tests/run.luau",
				"make test",
				"rspec spec/",
				"python -m pytest",
				"uv run pytest",
				"npx vitest",
				"deno test",
			})
		end)

		it("recognizes build tools", function()
			expectAll("build", {
				"make",
				"make -j8",
				"cargo build",
				"go build ./cmd/x",
				"tsc -p .",
				"gcc main.c",
				"clang++ a.cpp",
				"bun build ./index.ts",
				"ninja",
				"cmake ..",
				"npm run build",
			})
		end)

		it("recognizes version control", function()
			expectAll("vcs", { "git status", "jj log", "hg commit -m x" })
		end)

		it("recognizes directory listings for the ls swat parody", function()
			expectAll("list", { "ls", "ls -la", "ll", "la", "eza --icons", "exa", "lsd", "tree -L 2" })
		end)

		it("recognizes editors", function()
			expectAll("editor", { "vim x", "nvim .", "nano f", "emacs", "hx .", "code ." })
		end)

		it("recognizes network tools", function()
			expectAll(
				"network",
				{ "ssh host", "curl -s https://x", "wget u", "scp a b:", "rsync -a a b", "ping 1.1.1.1" }
			)
		end)

		it("recognizes package managers but not their test/build subcommands", function()
			expectAll("package", {
				"brew install jq",
				"apt install x",
				"npm install",
				"npm i left-pad",
				"pip install requests",
				"uv add httpx",
				"cargo install ripgrep",
				"pnpm add x",
				"bun install",
			})
		end)

		it("flags sudo before stripping wrappers so the cat can stare", function()
			expectAll(
				"sudo",
				{ "sudo rm -rf /tmp/x", "FOO=1 sudo ls", "time sudo make", "/usr/bin/sudo -s", "doas pkg_add x" }
			)
		end)

		it("strips env assignments, wrappers and path prefixes", function()
			expectAll("test", { "CI=1 NODE_ENV=test jest", "time pytest", "command go test", "env -i FOO=bar pytest" })
			expectAll("list", { "/bin/ls -l", "nohup ls", "  ls  " })
			expectAll("build", { "nice -n 10 make" })
		end)

		it("falls back to other for unknown or empty input", function()
			expectAll("other", { "", "   ", "echo hi", "FOO=bar", "cd ~/projects", "my-script.sh" })
		end)

		it("only ever returns a known category, never part of the line", function()
			local r = rng.new(17)
			local alphabet = "abcdefghijklmnopqrstuvwxyz/=-_. |;&$'\"\\0123456789"
			for _ = 1, 2000 do
				local n = r:int(0, 40)
				local chars = {}
				for i = 1, n do
					local idx = r:int(1, #alphabet)
					chars[i] = string.sub(alphabet, idx, idx)
				end
				local got = events.classify(table.concat(chars))
				expect(CATEGORIES[got]).toBe(true)
			end
		end)
	end)

	describe("newId", function()
		it("generates deterministic, prefixed ids from the injected rng", function()
			local a = events.newId(rng.new(1), "ev")
			local b = events.newId(rng.new(1), "ev")
			expect(a).toBe(b)
			expect(string.match(a, "^ev%-%x+$")).notToBeNil()
		end)

		it("produces distinct ids across draws", function()
			local r = rng.new(2)
			local seen = {}
			for _ = 1, 1000 do
				local id = events.newId(r, "x")
				expect(seen[id]).toBeNil()
				seen[id] = true
			end
		end)
	end)

	describe("constructors", function()
		it("builds command_start with only the category", function()
			local ev = events.commandStarted(base({ category = "sudo" }))
			expect(ev.type).toBe("command_start")
			expect(ev.event_id).toBe("ev-1")
			expect(ev.pane_id).toBe(3)
			expect(ev.scope).toBe("host")
			expect(ev.time).toBe(1700000000)
			expect(ev.attributes).toEqual({ category = "sudo" })
		end)

		it("builds command_finish with ok derived from the exit status", function()
			local ok = events.commandFinished(base({ category = "test", status = 0, took_ms = 1234.7 }))
			expect(ok.type).toBe("command_finish")
			expect(ok.attributes).toEqual({ category = "test", ok = true, status = 0, took_ms = 1234 })
			local bad = events.commandFinished(base({ category = "test", status = 2, took_ms = 5 }))
			expect(bad.attributes.ok).toBe(false)
			expect(bad.attributes.status).toBe(2)
		end)

		it("clamps hostile status and duration values", function()
			local ev = events.commandFinished(base({ category = "build", status = 1e12, took_ms = -50 }))
			expect(ev.attributes.status).toBe(255)
			expect(ev.attributes.took_ms).toBe(0)
			local killed = events.commandFinished(base({ category = "build", status = -9, took_ms = 0 / 0 }))
			expect(killed.attributes.status).toBe(-1)
			expect(killed.attributes.ok).toBe(false)
			expect(killed.attributes.took_ms).toBe(0)
		end)

		it("coerces unknown categories to other", function()
			local ev = events.commandStarted(base({ category = "rm -rf /" }))
			expect(ev.attributes.category).toBe("other")
		end)

		it("never carries a command line or path even if a caller passes one", function()
			local args = base({ category = "list", status = 0, took_ms = 1 })
			args.line = "ls /Users/me/secret"
			args.path = "/Users/me/secret"
			args.cwd = "/Users/me/secret"
			local ev = events.commandFinished(args)
			expect(serialize(ev)).notToContain("secret")
			local cwd = events.cwdChanged(args)
			expect(cwd.type).toBe("cwd")
			expect(cwd.attributes).toEqual({ kind = "cwd" })
			expect(serialize(cwd)).notToContain("secret")
		end)

		it("builds focus, pane, idle, timer and gesture events", function()
			expect(events.focus(base()).type).toBe("focus")
			local pane = events.paneEvent(base({ kind = "created" }))
			expect(pane.type).toBe("pane")
			expect(pane.attributes).toEqual({ kind = "created" })
			expect(events.paneEvent(base({ kind = "closed" })).attributes.kind).toBe("closed")
			expect(events.paneEvent(base({ kind = "exited" })).attributes.kind).toBe("exited")
			local idle = events.idle(base({ seconds = 125.9 }))
			expect(idle.type).toBe("idle")
			expect(idle.attributes).toEqual({ seconds = 125 })
			local timer = events.timer(base({ name = "tick" }))
			expect(timer.type).toBe("timer")
			expect(timer.attributes).toEqual({ kind = "tick" })
			local g = events.gesture(base({ gesture = "perform", animation = "stretch", source = "block" }))
			expect(g.type).toBe("gesture")
			expect(g.attributes).toEqual({ gesture = "perform", animation = "stretch", source = "block" })
			local fed = events.gesture(base({ gesture = "feed", item = "fish", source = "carly" }))
			expect(fed.attributes).toEqual({ gesture = "feed", item = "fish", source = "carly" })
			local played = events.gesture(base({ gesture = "play", toy = "feather" }))
			expect(played.attributes).toEqual({ gesture = "play", toy = "feather" })
		end)

		it("rejects unknown pane kinds and gestures", function()
			expect(function()
				events.paneEvent(base({ kind = "exploded" }))
			end).toThrow("pane kind")
			expect(function()
				events.gesture(base({ gesture = "kick" }))
			end).toThrow("gesture")
		end)

		it("omits pane_id when no pane is given", function()
			local ev = events.focus(base({ pane = false }))
			expect(ev.pane_id).toBeNil()
		end)
	end)

	describe("sanitizeAttributes", function()
		it("keeps only allowlisted keys for the event type", function()
			local out = events.sanitizeAttributes("command_finish", {
				category = "test",
				ok = true,
				status = 1,
				took_ms = 10,
				reacted = true,
				line = "pytest",
				output = "boom",
			})
			expect(out).toEqual({ category = "test", ok = true, status = 1, took_ms = 10, reacted = true })
		end)

		it("drops non-primitive, non-finite and oversized values", function()
			local out = events.sanitizeAttributes("gesture", {
				gesture = { "pet" },
				animation = string.rep("a", 33),
				source = "block",
			})
			expect(out).toEqual({ source = "block" })
			local nums = events.sanitizeAttributes("idle", { seconds = math.huge })
			expect(nums).toEqual({})
		end)

		it("drops strings that look like paths or command text", function()
			local out = events.sanitizeAttributes("timer", { kind = "/etc/passwd" })
			expect(out).toEqual({})
			local spaced = events.sanitizeAttributes("timer", { kind = "rm -rf" })
			expect(spaced).toEqual({})
		end)

		it("returns an empty table for unknown event types", function()
			expect(events.sanitizeAttributes("nope", { a = 1 })).toEqual({})
		end)
	end)
end)
