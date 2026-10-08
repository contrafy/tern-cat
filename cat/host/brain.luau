--!strict
-- The host half's single cat: config, packs, the shared StoreEnvelope (single tern.kv writer),
-- one behavior engine for every open block, intents from the inbox and blocks, and sound.
-- Tern-free: every side effect goes through injected adapters.

local T = require("../types")
local util = require("../core/util")
local rngMod = require("../core/rng")
local clockMod = require("../core/clock")
local events = require("../core/events")
local behavior = require("../core/behavior")
local store = require("../core/store")
local running = require("../core/running")
local model = require("../core/model")
local loader = require("../sprite/loader")
local manifest = require("../sprite/manifest")
local sound = require("../integrations/sound")
local configFile = require("../adapters/config")
local fsMod = require("../adapters/fs")
local jsonMod = require("../adapters/json")
local kvMod = require("../adapters/kv")
local pathsMod = require("../adapters/paths")
local inbox = require("./inbox")

local DEFAULT_PACK = "orange-menace"
local MIN_TICK_MS = 500
local MAX_TICK_MS = 5000
local CATCHUP_EVERY_S = 60
local MAX_NOTES = 5
local MAX_ASSET_BYTES = 1024 * 1024
-- Coalesced saves (command statistics, ticks) are written at most this often.
local PERSIST_GAP_MS = 1500
-- How often an unreadable kv.json is read again.
local KV_RETRY_MS = 5000
local KV_UNREADABLE_NOTE = "Saved state could not be read; showing a temporary cat and not saving until it can be read"

export type Clock = T.Clock & { wall_precise: () -> number }

export type Deps = {
	fs: fsMod.Fs,
	json: jsonMod.Json,
	kv: kvMod.Kv,
	clock: Clock,
	paths: pathsMod.Paths,
	os: string,
	seed: number,
	log: (level: string, msg: string) -> (),
	-- Process runner for the sound player; nil disables sound entirely.
	run: sound.Run?,
	frozen: boolean?,
}

export type Listener = (why: string) -> ()

export type Brain = {
	deps: Deps,
	config: T.Config,
	config_text: string?,
	example_text: string?,
	env: T.StoreEnvelope,
	written_rev: number,
	-- Engine ms of the last kv write attempt (coalesced saves wait PERSIST_GAP_MS after it).
	last_persist_ms: number,
	-- kv.json exists but could not be read: env is a temporary cat that is never written.
	kv_read_failed: boolean,
	kv_retry_ms: number,
	-- config.json exists but could not be read: it is never written.
	config_unreadable: boolean,
	config_write_logged: boolean,
	engine: T.EngineState,
	-- Commands running in any local pane (focus mode).
	running: running.Running,
	-- Bumped whenever the engine adopts a decision (renderers restart one-shot animations on it).
	decision_seq: number,
	rng: T.Rng,
	ids: T.Rng,
	frozen: boolean,
	notes: { string },
	packs: { [string]: T.LoadedPack },
	pack: T.LoadedPack?,
	pack_note: string?,
	all_packs_loaded: boolean,
	asset_cache: { [string]: string },
	inbox: inbox.State,
	last_catchup_s: number,
	sound_state: sound.State,
	sound_pack: sound.SoundPack?,
	sound_player: sound.Player?,
	sound_detect: "idle" | "pending" | "done",
	sound_warned: boolean,
	last_export: string?,
	persist_error: string?,
	listeners: { Listener },
	load_ms: number,
}

local function log(b: Brain, level: string, msg: string)
	pcall(b.deps.log, level, msg)
end

local function addNote(b: Brain, note: string)
	if util.contains(b.notes, note) then
		return
	end
	b.notes = util.ringPush(b.notes, note, MAX_NOTES)
end

local function removeNote(b: Brain, note: string)
	local i = table.find(b.notes, note)
	if i then
		b.notes = table.clone(b.notes)
		table.remove(b.notes, i)
	end
end

local function notify(b: Brain, why: string)
	for _, fn in table.clone(b.listeners) do
		local ok, err = pcall(fn :: any, why)
		if not ok then
			log(b, "error", `listener failed: {tostring(err)}`)
		end
	end
end

local function subscribe(b: Brain, fn: Listener): () -> ()
	table.insert(b.listeners, fn)
	return function()
		local i = table.find(b.listeners, fn)
		if i then
			table.remove(b.listeners, i)
		end
	end
end

local function environment(b: Brain): T.Environment
	local c = b.deps.clock
	local cfg = b.config
	return {
		reduced_motion = cfg.rendering.reduced_motion == "on",
		quiet_hours = cfg.quiet.hours_enabled and clockMod.inQuietHours(c.local_hm(), cfg.quiet.start, cfg.quiet.stop),
		snoozed = store.isSnoozed(b.env, c.wall_s()),
		busy = cfg.behavior.focus_mode and running.busy(b.running, c.now_ms()),
	}
end

local function ctx(b: Brain): T.DecideContext
	return {
		now_ms = b.deps.clock.now_ms(),
		rng = b.rng,
		config = b.config,
		profile = b.env.profile,
		env = environment(b),
	}
end

-- tern.kv refuses to read or write over an unparsable kv.json. Moves such a file aside so the
-- store starts empty again. Returns true only when a backup was written and the file removed.
local function recoverKvFile(b: Brain): boolean
	local d = b.deps
	local text = d.fs.read(d.paths.kv_file)
	if text == nil then
		return false
	end
	local _, err = d.json.decode(text)
	if err == nil then
		return false
	end
	local backup = `{d.paths.kv_file}.corrupt-{d.clock.wall_s()}`
	local okBackup, backupErr = d.fs.write(backup, text)
	if not okBackup then
		log(b, "error", `kv.json is unreadable and could not be backed up ({backupErr or "unknown error"}); leaving it`)
		return false
	end
	if not d.fs.remove(d.paths.kv_file) then
		return false
	end
	log(b, "warn", `kv.json was unreadable; moved it to {backup}`)
	return true
end

-- Writes the envelope when it changed. `coalesce` skips the write when the last attempt was
-- less than PERSIST_GAP_MS ago (a later tick or inbox poll writes it).
local function persist(b: Brain, coalesce: boolean?): boolean
	if b.env.rev == b.written_rev or b.kv_read_failed then
		return false
	end
	local now = b.deps.clock.now_ms()
	if coalesce and now - b.last_persist_ms < PERSIST_GAP_MS then
		return false
	end
	b.last_persist_ms = now
	local ok, err = b.deps.kv.set(kvMod.STATE_KEY, b.env)
	if not ok and recoverKvFile(b) then
		addNote(b, "Saved state file was corrupt; a backup was kept next to it")
		ok, err = b.deps.kv.set(kvMod.STATE_KEY, b.env)
	end
	if ok then
		b.written_rev = b.env.rev
		b.persist_error = nil
	elseif err ~= b.persist_error then
		b.persist_error = err
		log(b, "error", `could not save state: {err or "unknown error"}`)
	end
	return ok
end

-- Reads the saved envelope into b.env. When kv.json exists but cannot be read (and is not a
-- corrupt file that was moved aside), keeps a temporary in-memory cat that persist() never
-- writes, so a transient read error cannot overwrite the user's saved cat.
local function readState(b: Brain)
	local d = b.deps
	local wall = d.clock.wall_s()
	local newCatId = function()
		return model.newCatId(b.ids)
	end
	local raw, kvErr = d.kv.get(kvMod.STATE_KEY)
	local moved = false
	if kvErr then
		moved = recoverKvFile(b)
		if not moved then
			if not b.kv_read_failed then
				log(b, "warn", `kv read failed: {kvErr}; not saving until it can be read`)
				addNote(b, KV_UNREADABLE_NOTE)
			end
			b.kv_read_failed = true
			if b.env == nil then
				b.env = store.catchUp((store.decode(nil, wall, newCatId)), wall, b.config)
			end
			return
		end
		raw = nil
	end
	if b.kv_read_failed then
		b.kv_read_failed = false
		removeNote(b, KV_UNREADABLE_NOTE)
	end
	local env, recovered, note = store.decode(raw, wall, newCatId)
	if moved then
		recovered = true
		log(b, "warn", `kv read failed: {kvErr}`)
		addNote(b, "Saved state was unreadable; started a fresh cat (backup kept next to kv.json)")
	elseif recovered then
		addNote(b, `Saved state was unreadable ({note or "unknown"}); started a fresh cat`)
	elseif note then
		log(b, "info", `state repaired: {note}`)
	end
	b.written_rev = if raw ~= nil and not recovered then env.rev else -1
	b.env = store.catchUp(env, wall, b.config)
end

-- Retries an unreadable kv.json every KV_RETRY_MS. Returns true when the saved cat was adopted.
local function retryState(b: Brain): boolean
	if not b.kv_read_failed then
		return false
	end
	local now = b.deps.clock.now_ms()
	if now - b.kv_retry_ms < KV_RETRY_MS then
		return false
	end
	b.kv_retry_ms = now
	readState(b)
	return not b.kv_read_failed
end

-- Packs -------------------------------------------------------------------------------------

local function packRoots(b: Brain): { loader.Root }
	return {
		{ dir = b.deps.paths.bundled_packs, source = "bundled" },
		{ dir = b.deps.paths.user_packs, source = "user" },
	}
end

-- Every pack folder name under the bundled and user roots, by the loader's own folder rule
-- (so the host finds the same packs as the window, whatever the folder is called).
local function listPackDirs(b: Brain): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, root in packRoots(b) do
		local names: { string } = b.deps.fs.list(root.dir) or {}
		for _, name in names do
			if not seen[name] and loader.isPackDirName(name) then
				seen[name] = true
				table.insert(out, name)
			end
		end
	end
	table.sort(out)
	return out
end

-- Validates only the named pack folders (loader.loadAll over a filtered directory listing).
local function validatePacks(b: Brain, ids: { string })
	local wanted: { [string]: boolean } = {}
	local any = false
	for _, id in ids do
		if b.packs[id] == nil then
			wanted[id] = true
			any = true
		end
	end
	if not any then
		return
	end
	local fs = b.deps.fs
	local filtered: T.FsAdapter = {
		read = fs.read,
		exists = fs.exists,
		list = function(path: string): { string }?
			for _, root in packRoots(b) do
				if path == root.dir then
					local names = fs.list(path)
					if names == nil then
						return nil
					end
					local out = {}
					for _, name in names do
						if wanted[name] then
							table.insert(out, name)
						end
					end
					return out
				end
			end
			return fs.list(path)
		end,
	}
	local result = loader.loadAll(filtered, b.deps.json.decodeOrError, packRoots(b))
	for id, pack in result.packs do
		if b.packs[id] == nil then
			b.packs[id] = pack
		end
	end
	for _, problem in result.problems do
		log(b, "warn", problem)
	end
end

local function selectPack(b: Brain)
	local wanted = b.config.cat.appearance
	validatePacks(b, { wanted, DEFAULT_PACK })
	local pack, note = loader.select(b.packs, wanted, DEFAULT_PACK)
	-- Not found by folder name (a note means the default was substituted): scan every folder,
	-- since a pack's folder name need not equal its id.
	if (pack == nil or note ~= nil) and not b.all_packs_loaded then
		validatePacks(b, listPackDirs(b))
		b.all_packs_loaded = true
		pack, note = loader.select(b.packs, wanted, DEFAULT_PACK)
	end
	b.pack = pack
	b.pack_note = note
	if note then
		log(b, "warn", note)
	end
end

-- Every available pack, validated on first use (settings appearance page).
local function availablePacks(b: Brain): { T.LoadedPack }
	if not b.all_packs_loaded then
		validatePacks(b, listPackDirs(b))
		b.all_packs_loaded = true
	end
	local out: { T.LoadedPack } = {}
	for _, id in util.sortedKeys(b.packs) do
		table.insert(out, b.packs[id])
	end
	return out
end

-- Bytes of a pack-relative asset (validated path, size-capped, cached).
local function assetBytes(b: Brain, pack: T.LoadedPack, rel: string?): string?
	if rel == nil or not manifest.isSafePath(rel) then
		return nil
	end
	local path = loader.assetPath(pack, rel)
	if path == nil then
		return nil
	end
	local cached = b.asset_cache[path]
	if cached then
		return cached
	end
	local bytes = b.deps.fs.read(path, MAX_ASSET_BYTES)
	if bytes then
		b.asset_cache[path] = bytes
	end
	return bytes
end

-- Sound -------------------------------------------------------------------------------------

local function ensureSound(b: Brain)
	local cfg = b.config.sound
	if not cfg.enabled or b.deps.run == nil then
		return
	end
	if b.sound_pack == nil or b.sound_pack.id ~= cfg.pack then
		local pack, err = sound.loadPack(
			b.deps.fs,
			b.deps.json.decodeOrError,
			{ b.deps.paths.user_sounds, b.deps.paths.bundled_sounds },
			cfg.pack
		)
		b.sound_pack = pack
		if err then
			log(b, "warn", `sound: {err}`)
		end
	end
	if b.sound_detect == "idle" then
		b.sound_detect = "pending"
		sound.detect(b.deps.os, b.deps.fs.exists, b.deps.run :: sound.Run, function(player: sound.Player?)
			b.sound_player = player
			b.sound_detect = "done"
			if player == nil and not b.sound_warned then
				b.sound_warned = true
				log(b, "warn", "sound: no audio player found; staying silent")
			end
		end)
	end
end

local function playFor(b: Brain, decision: T.BehaviorDecision)
	local id: T.SoundId? = decision.sound
	local now = b.deps.clock.now_ms()
	local ok = sound.policy(b.config, id, environment(b), now, b.sound_state)
	if not ok then
		return
	end
	ensureSound(b)
	local player, pack = b.sound_player, b.sound_pack
	if player == nil or pack == nil or b.deps.run == nil then
		return
	end
	local path = if id then pack.files[id] else nil
	if path == nil then
		return
	end
	if sound.play(player, path, b.config.sound.volume, b.deps.run :: sound.Run) then
		sound.markPlayed(b.sound_state, now)
	else
		b.sound_player = nil
		if not b.sound_warned then
			b.sound_warned = true
			log(b, "warn", "sound: player failed to start; staying silent")
		end
	end
end

-- Decisions ---------------------------------------------------------------------------------

local function isNotable(d: T.BehaviorDecision): boolean
	local id = d.id
	return string.sub(id, 1, 8) == "gesture."
		or string.sub(id, 1, 6) == "react."
		or string.sub(id, 1, 13) == "wake.gesture."
		or string.sub(id, 1, 11) == "wake.react."
end

local function adopt(b: Brain, d: T.BehaviorDecision)
	b.decision_seq += 1
	if isNotable(d) then
		b.env = store.recordReaction(b.env, d, b.deps.clock.wall_precise())
	end
	playFor(b, d)
end

-- Saves and notifies. `coalesce` defers the save to a later tick or inbox poll when one was
-- written less than PERSIST_GAP_MS ago (bursts of host events).
local function finish(b: Brain, why: string, changed: boolean, coalesce: boolean?)
	persist(b, coalesce)
	if changed then
		notify(b, why)
	end
end

local function react(b: Brain, event: T.CatEvent): T.BehaviorDecision?
	local s, d = behavior.react(b.engine, event, ctx(b))
	b.engine = s
	if d then
		adopt(b, d)
	end
	return d
end

local function newId(b: Brain, prefix: string): string
	return events.newId(b.ids, prefix)
end

local function nextDelay(b: Brain): number
	local wait = b.engine.until_ms - b.deps.clock.now_ms()
	return math.clamp(math.ceil(wait), MIN_TICK_MS, MAX_TICK_MS)
end

-- Advances the engine (and periodic needs decay). Returns the delay until the next tick.
local function tick(b: Brain): number
	if b.frozen then
		return MAX_TICK_MS
	end
	local c = b.deps.clock
	local wall = c.wall_s()
	local rev = b.env.rev
	local adopted = retryState(b)
	if wall - b.last_catchup_s >= CATCHUP_EVERY_S then
		b.last_catchup_s = wall
		b.env = store.catchUp(b.env, wall, b.config, b.engine.posture == "asleep")
	end
	local s, d = behavior.tick(b.engine, ctx(b))
	b.engine = s
	if d then
		adopt(b, d)
	end
	finish(b, "tick", adopted or d ~= nil or b.env.rev ~= rev, true)
	return nextDelay(b)
end

-- Host hooks (callers pass the command category only; the line never reaches this module) ---
-- Running commands are tracked before reacting, so a command's own start counts as busy and
-- its finish does not (its reaction stays eligible unless another pane is still running).

export type CommandArgs = { pane: number?, category: T.CommandCategory, status: number?, took_ms: number? }

local function onCommandStarted(b: Brain, args: CommandArgs)
	running.started(b.running, args.pane, b.deps.clock.now_ms())
	local ev = events.commandStarted({
		id = newId(b, "cms"),
		time = b.deps.clock.wall_s(),
		pane = args.pane,
		category = args.category,
	})
	local d = react(b, ev)
	finish(b, "command", d ~= nil, true)
end

local function onCommandFinished(b: Brain, args: CommandArgs)
	running.stopped(b.running, args.pane)
	local ev = events.commandFinished({
		id = newId(b, "cmd"),
		time = b.deps.clock.wall_s(),
		pane = args.pane,
		category = args.category,
		status = args.status or -1,
		took_ms = args.took_ms or 0,
	})
	local s, d = behavior.react(b.engine, ev, ctx(b))
	b.engine = s
	if d then
		ev.attributes.reacted = true
	end
	local mood = b.env.profile.mood
	b.env = store.applyEvent(b.env, ev, b.config)
	if d then
		adopt(b, d)
	end
	-- Statistics alone are not visible: re-render only for a reaction or a mood change.
	finish(b, "command", d ~= nil or b.env.profile.mood ~= mood, true)
end

local function onPaneEvent(b: Brain, pane: number?, kind: string)
	if kind == "exited" then
		running.stopped(b.running, pane)
	end
	local ev = if kind == "cwd"
		then events.cwdChanged({ id = newId(b, "cwd"), time = b.deps.clock.wall_s(), pane = pane })
		else events.paneEvent({ id = newId(b, "pane"), time = b.deps.clock.wall_s(), pane = pane, kind = kind })
	local d = react(b, ev)
	finish(b, "pane", d ~= nil, true)
end

-- Config ------------------------------------------------------------------------------------

-- An unreadable config.json (it exists, but is a symlink, oversize or failed to read) keeps the
-- current config when there is one, and blocks writes until it can be read again.
local function applyLoaded(b: Brain, loaded: configFile.Loaded)
	local previous = b.config
	local unreadable = loaded.unreadable == true
	if not unreadable or previous == nil then
		b.config = loaded.config
	end
	b.config_text = loaded.text
	if unreadable then
		b.config_unreadable = true
	elseif b.config_unreadable then
		b.config_unreadable = false
		b.config_write_logged = false
		removeNote(b, configFile.UNREADABLE_ERROR)
	end
	if loaded.error then
		addNote(b, loaded.error)
		log(b, "warn", loaded.error)
	end
	for _, w in loaded.warnings do
		log(b, "warn", w)
	end
	if previous == nil or previous.cat.appearance ~= b.config.cat.appearance then
		selectPack(b)
	end
	if b.config.sound.enabled then
		ensureSound(b)
	end
end

-- Writes `changes` ({[dotted path] = value}, nil value = remove the key) into the user's
-- config.json, preserving every other key the user wrote. Refuses to write over a config.json
-- that exists but cannot be read.
local function setConfig(b: Brain, changes: { [string]: any }): (boolean, string?)
	local d = b.deps
	local current = configFile.read(d.fs, d.json, d.paths.config)
	if current.unreadable then
		addNote(b, configFile.UNREADABLE_ERROR)
		if not b.config_write_logged then
			b.config_write_logged = true
			log(b, "error", "not writing settings: config.json exists but cannot be read; fix or remove it")
		end
		return false, configFile.UNREADABLE_ERROR
	end
	if current.error and current.text then
		local backup = `{d.paths.config}.broken-{d.clock.wall_s()}`
		d.fs.write(backup, current.text :: string)
		addNote(b, `The unreadable config.json was saved as {backup}`)
	end
	local raw = configFile.applyChanges(current.raw, changes)
	if raw.schema_version == nil then
		raw.schema_version = 1
	end
	local text = configFile.encode(raw, d.json, b.example_text)
	d.fs.mkdir(d.paths.data)
	local ok, err = d.fs.write(d.paths.config, text)
	if not ok then
		log(b, "error", `could not write config.json: {err or "unknown error"}`)
		return false, err
	end
	applyLoaded(b, configFile.parse(text, d.json))
	notify(b, "config")
	return true, nil
end

-- Re-reads config.json when its content (or readability) changed on disk. Returns true when
-- it changed.
local function pollConfig(b: Brain): boolean
	local d = b.deps
	if not d.fs.exists(d.paths.config) then
		configFile.ensure(d.fs, d.paths.config, b.example_text)
	end
	local loaded = configFile.read(d.fs, d.json, d.paths.config)
	if loaded.text == b.config_text and (loaded.unreadable == true) == b.config_unreadable then
		return false
	end
	applyLoaded(b, loaded)
	notify(b, "config")
	return true
end

-- Intents -----------------------------------------------------------------------------------

local function exportIdentity(b: Brain, profile: T.Profile): string?
	local d = b.deps
	d.fs.mkdir(d.paths.exports)
	local wall = d.clock.wall_s()
	local path = `{d.paths.exports}/identity-{profile.cat_id}-{wall}.json`
	local body = {
		kind = "tern-cat.identity",
		exported_at = wall,
		name = b.config.cat.name,
		appearance = b.config.cat.appearance,
		personality = b.config.personality,
		profile = profile,
	}
	local text = configFile.encode(body, d.json, nil)
	local ok, err = d.fs.write(path, text)
	if not ok then
		log(b, "error", `export failed: {err or "unknown error"}`)
		return nil
	end
	b.last_export = path
	return path
end

export type IntentOutcome = { kind: string, [string]: any }

-- Validates and applies one raw intent once. Returns what happened, for toasts.
local function applyIntent(b: Brain, raw: any): IntentOutcome
	local c = b.deps.clock
	local rev = b.env.rev
	local env, effects = store.applyIntent(b.env, raw, b.config, {
		wall_s = c.wall_s(),
		new_cat_id = function()
			return model.newCatId(b.ids)
		end,
	})
	b.env = env
	local outcome: IntentOutcome = { kind = "duplicate" }
	for _, effect in effects do
		local kind = effect.kind
		outcome = { kind = kind }
		if kind == "rejected" then
			outcome.error = effect.error
			log(b, "warn", `intent rejected: {tostring(effect.error)}`)
		elseif kind == "gesture" then
			react(b, effect.event)
		elseif kind == "config" then
			local ok, err = setConfig(b, effect.changes)
			outcome.ok = ok
			outcome.error = err
		elseif kind == "snooze" or kind == "unsnooze" then
			local s, d
			if kind == "unsnooze" and b.engine.posture == "asleep" then
				-- An explicit wake, like the window's optimistic `wake`, not a natural-wake roll.
				s, d = behavior.wake(b.engine, ctx(b), "wake.unsnooze", "Woke up from a snooze.")
			else
				b.engine = table.clone(b.engine)
				b.engine.until_ms = c.now_ms()
				s, d = behavior.tick(b.engine, ctx(b))
			end
			b.engine = s
			if d then
				adopt(b, d)
			end
			outcome.until_s = effect.until_s
		elseif kind == "reset_identity" then
			b.engine = behavior.newState(c.now_ms())
			b.decision_seq += 1
			outcome.cat_id = effect.cat_id
		elseif kind == "export_identity" then
			outcome.path = exportIdentity(b, effect.profile)
		end
	end
	finish(b, "intent", b.env.rev ~= rev or outcome.kind ~= "duplicate")
	return outcome
end

-- Builds and applies an intent that originates inside this host (block buttons, keys).
local function localIntent(b: Brain, kind: string, args: { [string]: any }?, source: string?): IntentOutcome
	return applyIntent(b, {
		intent_id = newId(b, "blk"),
		at = b.deps.clock.wall_s(),
		kind = kind,
		source = source or "block",
		args = args or {},
	})
end

-- Drains the inbox; also writes coalesced saves and retries an unreadable kv.json (it runs
-- every 500 ms, unlike the engine tick).
local function pollInbox(b: Brain): number
	local d = b.deps
	local result = inbox.poll(b.inbox, d.fs, d.json, d.paths.inbox, d.clock.now_ms())
	for _, item in result.items do
		local ok, err = pcall(applyIntent, b, item.intent)
		if not ok then
			log(b, "error", `intent {item.name} failed: {tostring(err)}`)
		end
	end
	for _, gone in result.discarded do
		log(b, "warn", `inbox: discarded {gone.name} ({gone.reason})`)
	end
	for _, kept in result.ignored do
		log(b, "warn", `inbox: ignoring {kept.name} ({kept.reason})`)
	end
	local adopted = retryState(b)
	finish(b, "state", adopted, true)
	return #result.items
end

-- Test mode: deterministic seed and no engine ticks (goldens).
local function setTestMode(b: Brain, seed: number, frozen: boolean)
	b.rng = rngMod.new(seed)
	b.ids = rngMod.new(seed + 1)
	b.frozen = frozen
	b.engine = behavior.newState(b.deps.clock.now_ms())
	b.decision_seq += 1
	notify(b, "test")
end

-- Load --------------------------------------------------------------------------------------

local function load(deps: Deps): Brain
	local started = deps.clock.now_ms()
	local b: Brain = {
		deps = deps,
		config = nil :: any,
		config_text = nil,
		example_text = deps.fs.read(deps.paths.example_config, configFile.MAX_BYTES),
		env = nil :: any,
		written_rev = -1,
		last_persist_ms = -math.huge,
		kv_read_failed = false,
		kv_retry_ms = started,
		config_unreadable = false,
		config_write_logged = false,
		engine = behavior.newState(started),
		running = running.new(),
		decision_seq = 0,
		rng = rngMod.new(deps.seed),
		ids = rngMod.new(deps.seed + 1),
		frozen = deps.frozen == true,
		notes = {},
		packs = {},
		pack = nil,
		pack_note = nil,
		all_packs_loaded = false,
		asset_cache = {},
		inbox = inbox.newState(),
		last_catchup_s = deps.clock.wall_s(),
		sound_state = sound.newState(),
		sound_pack = nil,
		sound_player = nil,
		sound_detect = "idle",
		sound_warned = false,
		last_export = nil,
		persist_error = nil,
		listeners = {},
		load_ms = 0,
	}

	deps.fs.mkdir(deps.paths.data)
	deps.fs.mkdir(deps.paths.inbox)
	local created, ensureErr = configFile.ensure(deps.fs, deps.paths.config, b.example_text)
	if created then
		log(b, "info", `created {deps.paths.config}`)
	elseif ensureErr then
		log(b, "warn", `config.json not created: {ensureErr}`)
	end
	applyLoaded(b, configFile.read(deps.fs, deps.json, deps.paths.config))

	readState(b)
	persist(b)
	b.load_ms = deps.clock.now_ms() - started
	return b
end

return {
	DEFAULT_PACK = DEFAULT_PACK,
	MIN_TICK_MS = MIN_TICK_MS,
	MAX_TICK_MS = MAX_TICK_MS,
	load = load,
	subscribe = subscribe,
	environment = environment,
	tick = tick,
	nextDelay = nextDelay,
	onCommandStarted = onCommandStarted,
	onCommandFinished = onCommandFinished,
	onPaneEvent = onPaneEvent,
	applyIntent = applyIntent,
	localIntent = localIntent,
	pollInbox = pollInbox,
	pollConfig = pollConfig,
	setConfig = setConfig,
	setTestMode = setTestMode,
	availablePacks = availablePacks,
	assetBytes = assetBytes,
	listPackDirs = listPackDirs,
	isNotable = isNotable,
}
