--!strict
-- Optional sound effects: play policy, sound pack validation and local player selection.
-- Tern has no audio API, so the host half runs a platform player with a fixed argv whose only
-- variable part is a file path from a validated sound pack. Muted by default.

local T = require("../types")
local util = require("../core/util")
local manifest = require("../sprite/manifest")

local MIN_GAP_MS = 2000
local MANIFEST_FILE = "sounds.json"
local MANIFEST_MAX_BYTES = 16 * 1024
local SOUND_IDS: { T.SoundId } = { "meow", "purr", "surprise", "happy", "swat" }
local EXTENSIONS = { "wav", "aiff", "aif", "mp3", "ogg" }
local LINUX_PLAYERS = { "pw-play", "paplay", "aplay" }
local PROBE_ARGV = { "sh", "-c", "command -v pw-play paplay aplay" }
local AFPLAY = "/usr/bin/afplay"
local PLAY_TIMEOUT_MS = 10000

export type PlayerKind = "afplay" | "pw-play" | "paplay" | "aplay"
export type Player = { kind: PlayerKind, bin: string }

export type SoundPack = {
	id: string,
	root: string,
	-- Absolute (or root-relative) paths of the usable sounds.
	files: { [string]: string },
	warnings: { string },
}

export type State = { last_ms: number? }

export type ProcessResult = { status: number, stdout: string, stderr: string, timed_out: boolean }
export type Run = (argv: { string }, opts: { timeout_ms: number? }, cb: (result: ProcessResult) -> ()) -> ()

local function newState(): State
	return { last_ms = nil }
end

-- Returns (true, "ok") when `id` should play now, else (false, reason).
local function policy(
	config: T.Config,
	id: T.SoundId?,
	env: T.Environment,
	now_ms: number,
	state: State
): (boolean, string)
	local s = config.sound
	if not s.enabled then
		return false, "sound disabled"
	end
	if id == nil then
		return false, "no sound"
	end
	if s.events[id] == false then
		return false, "event muted"
	end
	if s.volume <= 0 then
		return false, "volume zero"
	end
	if env.snoozed then
		return false, "snoozed"
	end
	if env.quiet_hours and s.respect_quiet_hours then
		return false, "quiet hours"
	end
	local last = state.last_ms
	if last ~= nil and now_ms - last < MIN_GAP_MS then
		return false, "rate limited"
	end
	return true, "ok"
end

local function markPlayed(state: State, now_ms: number)
	state.last_ms = now_ms
end

-- Pack-relative sound path: manifest.checkPath segment rules plus an audio extension.
local function checkSoundPath(rel: any): (boolean, string?)
	if type(rel) ~= "string" then
		return false, "must be a string path"
	end
	local stem, ext = string.match(rel, "^(.+)%.([a-z0-9]+)$")
	if not stem or not util.contains(EXTENSIONS, ext :: string) then
		return false, `must end in .{table.concat(EXTENSIONS, ", .")}`
	end
	return manifest.checkPath((stem :: string) .. ".png")
end

local function loadPack(
	fs: T.FsAdapter,
	decodeJson: (string) -> any,
	roots: { string },
	id: string
): (SoundPack?, string?)
	if type(id) ~= "string" or #id > 32 or not string.match(id, "^[a-z][a-z0-9-]*$") then
		return nil, "invalid sound pack id"
	end
	for _, root in roots do
		local dir = manifest.joinPath(root, id)
		local okRead, text = pcall(fs.read, manifest.joinPath(dir, MANIFEST_FILE), MANIFEST_MAX_BYTES + 1)
		if not okRead or type(text) ~= "string" then
			continue
		end
		if #text > MANIFEST_MAX_BYTES then
			return nil, `sound pack {id}: {MANIFEST_FILE} is too large`
		end
		local okDecode, raw = pcall(decodeJson, text)
		if not okDecode or not util.isDict(raw) then
			return nil, `sound pack {id}: {MANIFEST_FILE} is not a JSON object`
		end
		if raw.id ~= id then
			return nil, `sound pack {id}: manifest id does not match its folder`
		end
		if not util.isDict(raw.sounds) then
			return nil, `sound pack {id}: sounds must be an object`
		end
		local files: { [string]: string } = {}
		local warnings: { string } = {}
		for _, key in util.sortedKeys(raw.sounds) do
			local rel = raw.sounds[key]
			if not util.contains(SOUND_IDS, key) then
				table.insert(warnings, `sounds.{key}: unknown sound id ignored`)
				continue
			end
			local ok, why = checkSoundPath(rel)
			if not ok then
				table.insert(warnings, `sounds.{key}: {why or "invalid path"}`)
				continue
			end
			local path = manifest.joinPath(dir, rel)
			if not fs.exists(path) then
				table.insert(warnings, `sounds.{key}: file missing`)
				continue
			end
			files[key] = path
		end
		return { id = id, root = dir, files = files, warnings = warnings }, nil
	end
	return nil, `sound pack {id} not found`
end

local function choosePlayer(os_name: string, found: { [string]: string }): Player?
	if os_name == "macos" then
		local bin = found.afplay
		return if bin then { kind = "afplay", bin = bin } else nil
	end
	if os_name == "linux" then
		for _, name in LINUX_PLAYERS do
			local bin = found[name]
			if bin then
				return { kind = name :: PlayerKind, bin = bin }
			end
		end
	end
	return nil
end

local function parseCommandV(stdout: string): { [string]: string }
	local found: { [string]: string } = {}
	for line in string.gmatch(stdout or "", "[^\n]+") do
		local path = string.match(line, "^%s*(/[%w%._/%-]+)%s*$")
		if path then
			local name = string.match(path, "([^/]+)$")
			if name and util.contains(LINUX_PLAYERS, name) and found[name] == nil then
				found[name] = path
			end
		end
	end
	return found
end

local function argv(player: Player, path: string, volume: number): { string }
	local v = util.clamp01(volume)
	if player.kind == "afplay" then
		return { player.bin, "-v", string.format("%.2f", v), path }
	elseif player.kind == "pw-play" then
		return { player.bin, "--volume", string.format("%.2f", v), path }
	elseif player.kind == "paplay" then
		return { player.bin, `--volume={math.floor(v * 65536 + 0.5)}`, path }
	end
	return { player.bin, "-q", path }
end

-- Finds a player once. macOS checks the fixed afplay path; Linux runs one fixed probe.
-- `done` receives nil when no player is available (silent fallback).
local function detect(os_name: string, exists: (string) -> boolean, run: Run, done: (Player?) -> ())
	if os_name == "macos" then
		local okExists, yes = pcall(exists, AFPLAY)
		done(if okExists and yes then { kind = "afplay", bin = AFPLAY } else nil)
		return
	end
	if os_name ~= "linux" then
		done(nil)
		return
	end
	local ok = pcall(run, PROBE_ARGV, { timeout_ms = 2000 }, function(result: ProcessResult)
		if type(result) ~= "table" or type(result.stdout) ~= "string" then
			done(nil)
			return
		end
		done(choosePlayer(os_name, parseCommandV(result.stdout)))
	end)
	if not ok then
		done(nil)
	end
end

-- Starts playback; returns false (and never raises) when the player could not be spawned.
local function play(player: Player, path: string, volume: number, run: Run): boolean
	return (pcall(run, argv(player, path, volume), { timeout_ms = PLAY_TIMEOUT_MS }, function() end))
end

return {
	MIN_GAP_MS = MIN_GAP_MS,
	SOUND_IDS = SOUND_IDS,
	newState = newState,
	policy = policy,
	markPlayed = markPlayed,
	checkSoundPath = checkSoundPath,
	loadPack = loadPack,
	choosePlayer = choosePlayer,
	parseCommandV = parseCommandV,
	argv = argv,
	detect = detect,
	play = play,
}
