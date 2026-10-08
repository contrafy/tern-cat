--!strict
-- Event construction and the command-line classifier. A command line is reduced to a
-- CommandCategory here and never stored, returned or copied into an event.

local T = require("../types")

local CATEGORIES: { [string]: boolean } = {
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

local GESTURES: { [string]: boolean } = { pet = true, poke = true, feed = true, play = true, perform = true }
local PANE_KINDS: { [string]: boolean } = { created = true, closed = true, exited = true }

local MAX_TOKENS = 32
local MAX_STRING = 32
local MAX_TOOK_MS = 7 * 24 * 3600 * 1000
local MAX_IDLE_S = 7 * 24 * 3600

-- Classifier ------------------------------------------------------------------------------

local SUDO = { sudo = true, doas = true, run0 = true, pkexec = true }
local WRAPPERS = { time = true, command = true, env = true, nohup = true, exec = true, nice = true, builtin = true }
local RUNNERS = { npx = true, bunx = true, pnpx = true }

local LIST = { ls = true, ll = true, la = true, l = true, eza = true, exa = true, lsd = true, tree = true, dir = true }
local EDITOR = {
	vi = true,
	vim = true,
	nvim = true,
	nano = true,
	emacs = true,
	hx = true,
	helix = true,
	code = true,
	micro = true,
	kak = true,
	subl = true,
	zed = true,
}
local NETWORK = {
	ssh = true,
	curl = true,
	wget = true,
	scp = true,
	sftp = true,
	rsync = true,
	ping = true,
	mosh = true,
	nc = true,
	telnet = true,
	http = true,
	dig = true,
	nslookup = true,
	traceroute = true,
}
local VCS = { git = true, jj = true, hg = true, svn = true, tig = true, lazygit = true, gh = true }
local TEST = {
	pytest = true,
	jest = true,
	vitest = true,
	mocha = true,
	rspec = true,
	phpunit = true,
	ctest = true,
	tox = true,
	nox = true,
	ava = true,
	playwright = true,
}
local BUILD = {
	cmake = true,
	ninja = true,
	meson = true,
	bazel = true,
	gcc = true,
	["g++"] = true,
	cc = true,
	["c++"] = true,
	clang = true,
	["clang++"] = true,
	tsc = true,
	xcodebuild = true,
	esbuild = true,
	webpack = true,
	rollup = true,
	rustc = true,
	javac = true,
}
local PACKAGE = {
	brew = true,
	apt = true,
	["apt-get"] = true,
	dnf = true,
	yum = true,
	pacman = true,
	pip = true,
	pip3 = true,
	pipx = true,
	uv = true,
	gem = true,
	port = true,
	["nix-env"] = true,
	apk = true,
	poetry = true,
}
local PKG_SUBCOMMANDS = {
	install = true,
	i = true,
	ci = true,
	add = true,
	uninstall = true,
	remove = true,
	rm = true,
	un = true,
	update = true,
	upgrade = true,
}
local TEST_BUILD_TOOLS = {
	mix = true,
	swift = true,
	dotnet = true,
	gradle = true,
	gradlew = true,
	mvn = true,
	zig = true,
	sbt = true,
}

local function basename(token: string): string
	return string.lower(string.match(token, "([^/]*)$") or token)
end

local function isAssignment(token: string): boolean
	return string.match(token, "^[A-Za-z_][A-Za-z0-9_]*=") ~= nil
end

local function isFlag(token: string): boolean
	return string.sub(token, 1, 1) == "-"
end

local function nextWord(tokens: { string }, i: number): (string?, number)
	local j = i
	while tokens[j] and isFlag(tokens[j]) do
		j += 1
	end
	local tok = tokens[j]
	if tok == nil then
		return nil, j
	end
	return string.lower(tok), j
end

local function scriptCategory(name: string?): T.CommandCategory
	if name == nil then
		return "other"
	end
	if string.sub(name, 1, 4) == "test" then
		return "test"
	end
	if string.sub(name, 1, 5) == "build" then
		return "build"
	end
	return "other"
end

local classifyFrom: (tokens: { string }, i: number) -> T.CommandCategory

local function jsPackageManager(cmd: string, tokens: { string }, i: number): T.CommandCategory
	local sub, j = nextWord(tokens, i)
	if sub == nil then
		return if cmd == "yarn" or cmd == "bun" then "package" else "other"
	end
	if sub == "test" or sub == "t" then
		return "test"
	end
	if sub == "build" then
		return "build"
	end
	if sub == "run" or sub == "run-script" then
		local script = nextWord(tokens, j + 1)
		return scriptCategory(script)
	end
	if sub == "exec" or sub == "dlx" or sub == "x" then
		return classifyFrom(tokens, j + 1)
	end
	if PKG_SUBCOMMANDS[sub] then
		return "package"
	end
	if cmd == "yarn" then
		return scriptCategory(sub)
	end
	return "other"
end

local function classifyCommand(cmd: string, tokens: { string }, i: number): T.CommandCategory
	if LIST[cmd] then
		return "list"
	end
	if EDITOR[cmd] then
		return "editor"
	end
	if NETWORK[cmd] then
		return "network"
	end
	if VCS[cmd] then
		return "vcs"
	end
	if TEST[cmd] then
		return "test"
	end
	if BUILD[cmd] then
		return "build"
	end
	if RUNNERS[cmd] then
		return classifyFrom(tokens, i)
	end
	if cmd == "npm" or cmd == "pnpm" or cmd == "yarn" or cmd == "bun" then
		return jsPackageManager(cmd, tokens, i)
	end
	if cmd == "make" or cmd == "gmake" then
		for j = i, #tokens do
			local a = string.lower(tokens[j])
			if a == "test" or a == "tests" or a == "check" then
				return "test"
			end
		end
		return "build"
	end
	if cmd == "cargo" then
		local sub = nextWord(tokens, i)
		if sub == "test" or sub == "nextest" or sub == "t" then
			return "test"
		end
		if sub == "build" or sub == "b" or sub == "check" or sub == "c" or sub == "clippy" then
			return "build"
		end
		if sub == "install" or sub == "add" or sub == "remove" or sub == "update" then
			return "package"
		end
		return "other"
	end
	if cmd == "go" then
		local sub = nextWord(tokens, i)
		if sub == "test" then
			return "test"
		end
		if sub == "build" or sub == "vet" then
			return "build"
		end
		if sub == "install" or sub == "get" then
			return "package"
		end
		return "other"
	end
	if cmd == "deno" then
		local sub = nextWord(tokens, i)
		return if sub == "test" then "test" else "other"
	end
	if cmd == "lune" then
		local sub, j = nextWord(tokens, i)
		if sub == "run" then
			local script = nextWord(tokens, j + 1)
			if script and string.sub(script, 1, 4) == "test" then
				return "test"
			end
		end
		return "other"
	end
	if TEST_BUILD_TOOLS[cmd] then
		local sub = nextWord(tokens, i)
		if sub == "test" then
			return "test"
		end
		if sub == "build" or cmd == "gradle" or cmd == "gradlew" or cmd == "mvn" then
			return "build"
		end
		return "other"
	end
	if cmd == "python" or cmd == "python3" then
		for j = i, #tokens - 1 do
			if tokens[j] == "-m" then
				local mod = string.lower(tokens[j + 1])
				if mod == "pytest" or mod == "unittest" then
					return "test"
				end
				if mod == "pip" then
					return "package"
				end
				return "other"
			end
		end
		return "other"
	end
	if cmd == "uv" or cmd == "poetry" or cmd == "bundle" then
		local sub, j = nextWord(tokens, i)
		if sub == "run" or sub == "exec" then
			return classifyFrom(tokens, j + 1)
		end
		return if PACKAGE[cmd] then "package" else "other"
	end
	if PACKAGE[cmd] then
		return "package"
	end
	return "other"
end

classifyFrom = function(tokens: { string }, i: number): T.CommandCategory
	local j = i
	local afterWrapper = false
	while tokens[j] do
		local tok = tokens[j]
		local name = basename(tok)
		if SUDO[name] then
			return "sudo"
		end
		local skippable = isAssignment(tok) or (afterWrapper and (isFlag(tok) or tonumber(tok) ~= nil))
		if WRAPPERS[name] then
			afterWrapper = true
		elseif not skippable then
			return classifyCommand(name, tokens, j + 1)
		end
		j += 1
	end
	return "other"
end

local function classify(line: string): T.CommandCategory
	if type(line) ~= "string" then
		return "other"
	end
	local tokens = {}
	for tok in string.gmatch(line, "%S+") do
		table.insert(tokens, tok)
		if #tokens >= MAX_TOKENS then
			break
		end
	end
	return classifyFrom(tokens, 1)
end

-- Attributes ------------------------------------------------------------------------------

type Kind = "category" | "bool" | "number" | "word"

local ALLOWED: { [string]: { [string]: Kind } } = {
	command_start = { category = "category" },
	command_finish = { category = "category", ok = "bool", status = "number", took_ms = "number", reacted = "bool" },
	focus = {},
	pane = { kind = "word" },
	cwd = { kind = "word" },
	idle = { seconds = "number" },
	timer = { kind = "word" },
	gesture = { gesture = "word", item = "word", toy = "word", animation = "word", source = "word" },
	pointer = { kind = "word" },
	resize = { kind = "word" },
	ai = { animation = "word", source = "word" },
}

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

local function sanitizeValue(kind: Kind, value: any): (string | number | boolean)?
	if kind == "bool" then
		return if type(value) == "boolean" then value else nil
	end
	if kind == "number" then
		return if type(value) == "number" and isFinite(value) then value else nil
	end
	if type(value) ~= "string" or #value == 0 or #value > MAX_STRING then
		return nil
	end
	if kind == "category" then
		return if CATEGORIES[value] then value else "other"
	end
	if string.match(value, "^[%w_%-]+$") == nil then
		return nil
	end
	return value
end

local function sanitizeAttributes(event_type: string, attrs: { [string]: any }): T.EventAttributes
	local allowed = ALLOWED[event_type]
	local out: T.EventAttributes = {}
	if allowed == nil or type(attrs) ~= "table" then
		return out
	end
	for key, kind in allowed do
		local v = sanitizeValue(kind :: Kind, attrs[key])
		if v ~= nil then
			out[key] = v
		end
	end
	return out
end

-- Constructors ----------------------------------------------------------------------------

export type BaseArgs = {
	id: string,
	time: number,
	scope: T.EventScope?,
	pane: number?,
}

local function build(event_type: T.EventType, args: { [string]: any }, attrs: { [string]: any }): T.CatEvent
	local pane = args.pane
	return {
		event_id = tostring(args.id),
		time = if type(args.time) == "number" then args.time else 0,
		type = event_type,
		scope = args.scope or "host",
		pane_id = if type(pane) == "number" then pane else nil,
		attributes = sanitizeAttributes(event_type, attrs),
	}
end

local function clampInt(value: any, lo: number, hi: number, fallback: number): number
	if type(value) ~= "number" or value ~= value then
		return fallback
	end
	return math.clamp(math.floor(value), lo, hi)
end

local function commandStarted(args: BaseArgs & { category: T.CommandCategory }): T.CatEvent
	return build("command_start", args, { category = args.category })
end

local function commandFinished(
	args: BaseArgs & { category: T.CommandCategory, status: number, took_ms: number }
): T.CatEvent
	local status = clampInt(args.status, -1, 255, -1)
	return build("command_finish", args, {
		category = args.category,
		ok = status == 0,
		status = status,
		took_ms = clampInt(args.took_ms, 0, MAX_TOOK_MS, 0),
	})
end

local function focus(args: BaseArgs): T.CatEvent
	return build("focus", args, {})
end

local function paneEvent(args: BaseArgs & { kind: string }): T.CatEvent
	if not PANE_KINDS[args.kind] then
		error(`events.paneEvent: unknown pane kind`)
	end
	return build("pane", args, { kind = args.kind })
end

local function cwdChanged(args: BaseArgs): T.CatEvent
	return build("cwd", args, { kind = "cwd" })
end

local function idle(args: BaseArgs & { seconds: number }): T.CatEvent
	return build("idle", args, { seconds = clampInt(args.seconds, 0, MAX_IDLE_S, 0) })
end

local function timer(args: BaseArgs & { name: string? }): T.CatEvent
	return build("timer", args, { kind = args.name })
end

local function gesture(
	args: BaseArgs & { gesture: T.Gesture, item: string?, toy: string?, animation: string?, source: string? }
): T.CatEvent
	if not GESTURES[args.gesture] then
		error(`events.gesture: unknown gesture`)
	end
	return build("gesture", args, {
		gesture = args.gesture,
		item = args.item,
		toy = args.toy,
		animation = args.animation,
		source = args.source,
	})
end

local function newId(rng: T.Rng, prefix: string): string
	return string.format("%s-%08x%08x", prefix, rng:int(0, 0xFFFFFFFF), rng:int(0, 0xFFFFFFFF))
end

return {
	classify = classify,
	sanitizeAttributes = sanitizeAttributes,
	newId = newId,
	commandStarted = commandStarted,
	commandFinished = commandFinished,
	focus = focus,
	paneEvent = paneEvent,
	cwdChanged = cwdChanged,
	idle = idle,
	timer = timer,
	gesture = gesture,
}
