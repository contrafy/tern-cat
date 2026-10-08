--!strict
-- tern-cat host half: the single writer of the shared cat (tern.kv "state"), host hooks, the
-- intent inbox, sound, and the interactive "Tern Cat" block. Logic lives in cat/host/brain.luau.

local T = require("./cat/types")
local fsAdapter = require("./cat/adapters/fs")
local jsonAdapter = require("./cat/adapters/json")
local kvAdapter = require("./cat/adapters/kv")
local pathsAdapter = require("./cat/adapters/paths")
local clockAdapter = require("./cat/adapters/clock")
local brainMod = require("./cat/host/brain")
local controls = require("./cat/host/controls")
local blockView = require("./cat/render/block")
local animations = require("./cat/render/animations")
local hooks = require("./cat/integrations/hooks")
local ai = require("./cat/integrations/ai")
local soundMod = require("./cat/integrations/sound")

local INBOX_MS = 500
local CONFIG_MS = 3000

local function log(level: string, msg: string)
	local fn = (tern.log :: any)[level] or tern.log.info
	fn("tern-cat: " .. msg)
end

local clock = clockAdapter.real()
local run: soundMod.Run = function(argv, opts, cb)
	tern.process.run(argv, { timeout_ms = opts.timeout_ms }, function(result: ProcessResult)
		cb(result)
	end)
end

local brain = brainMod.load({
	fs = fsAdapter.new(),
	json = jsonAdapter.new(),
	kv = kvAdapter.new(),
	clock = clock,
	paths = pathsAdapter.current(),
	os = tern.runtime.os,
	seed = math.floor(os.time() + tern.now()) % 0x7FFFFFFF + 1,
	log = log,
	run = run,
})
log(
	"info",
	string.format("host loaded in %.1f ms (pack %s)", brain.load_ms, brain.pack and brain.pack.manifest.id or "none")
)

local envTest = controls.parseTestMode(tern.getenv("TERN_CAT_TEST"))
if envTest then
	brainMod.setTestMode(brain, envTest.seed, envTest.frozen)
	log("info", `test mode from TERN_CAT_TEST: seed {envTest.seed}, frozen {envTest.frozen}`)
end

-- Engine timer: one self-rescheduling timer at the current decision's end (0.5..5 s).
local engineTimer: TimerHandle? = nil

local function scheduleEngine()
	if engineTimer then
		engineTimer:cancel()
		engineTimer = nil
	end
	if brain.frozen then
		return
	end
	engineTimer = tern.timer(brainMod.nextDelay(brain), function()
		engineTimer = nil
		local ok, err = pcall(brainMod.tick, brain)
		if not ok then
			log("error", "tick failed: " .. tostring(err))
		end
		scheduleEngine()
	end)
end

-- Blocks ----------------------------------------------------------------------------------------

type BlockState = {
	pane: number,
	page: string,
	settings_page: string,
	editing: string?,
	-- The armed first click of Reset identity ("reset") or Remove ("pack:<id>").
	confirm: controls.Confirm?,
	sprite_key: string?,
	sprites: { blockView.Sprite },
	canvas: { width: number, height: number },
	previews: { [string]: string },
}

type Live = { state: BlockState, cx: BlockCx }

local live: { [number]: Live } = {}
local handling: number? = nil

local function ensureSprites(state: BlockState, cx: BlockCx)
	local pack = brain.pack
	if pack == nil then
		return
	end
	local still = brainMod.environment(brain).reduced_motion
	local key = pack.manifest.id .. (if still then ":still" else ":anim")
	if state.sprite_key == key then
		return
	end
	local sprites: { blockView.Sprite } = {}
	local names: { string } = {}
	for name in pack.manifest.animations do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local spec = pack.manifest.animations[name]
		local bytes = if still then nil else brainMod.assetBytes(brain, pack, spec.apng)
		if bytes == nil then
			bytes = brainMod.assetBytes(brain, pack, spec.frames[1])
		end
		if bytes then
			table.insert(sprites, { anim = name, blob = cx:blob(bytes, "image/png") })
		end
	end
	state.sprites = sprites
	state.canvas = { width = pack.manifest.canvas.width, height = pack.manifest.canvas.height }
	state.sprite_key = key
end

local function ensurePreviews(state: BlockState, cx: BlockCx): { blockView.PackChoice }
	local out: { blockView.PackChoice } = {}
	for _, pack in brainMod.availablePacks(brain) do
		local id = pack.manifest.id
		if state.previews[id] == nil then
			local idle = pack.manifest.animations.idle
			local bytes = if idle then brainMod.assetBytes(brain, pack, idle.apng or idle.frames[1]) else nil
			if bytes then
				state.previews[id] = cx:blob(bytes, "image/png")
			end
		end
		table.insert(out, {
			id = id,
			name = pack.manifest.name,
			preview = state.previews[id],
			removable = pack.source == "user",
		})
	end
	return out
end

local function modelFor(state: BlockState, cx: BlockCx?): blockView.Model
	local decision = brain.engine.current
	local pack = brain.pack
	local wanted: string = if decision then decision.animation else "idle"
	local active = if pack then animations.resolve(pack.manifest.animations, wanted) else "idle"
	local spec = if pack then pack.manifest.animations[active] else nil
	local env = brainMod.environment(brain)
	local notes = table.clone(brain.notes)
	if brain.pack_note then
		table.insert(notes, brain.pack_note :: string)
	end
	local settings: blockView.SettingsModel? = nil
	if state.page == "settings" then
		local now = clock.now_ms()
		local pending = state.confirm
		local removing: string? = nil
		if
			pending
			and string.sub(pending.target, 1, 5) == "pack:"
			and controls.isArmed(pending, pending.target, now)
		then
			removing = string.sub(pending.target, 6)
		end
		settings = {
			page = state.settings_page,
			editing = state.editing,
			confirm_reset = controls.isArmed(pending, "reset", now),
			confirm_remove = removing,
			packs = if cx and state.settings_page == "appearance" then ensurePreviews(state, cx) else {},
			ai_reason = ai.carlyScheduleProvider().unavailable_reason or "Not available in this version.",
			last_export = brain.last_export,
		}
	end
	return {
		page = state.page,
		config = brain.config,
		profile = brain.env.profile,
		snoozed = env.snoozed,
		sprites = state.sprites,
		active = active,
		seq = brain.decision_seq,
		one_shot = spec ~= nil and not spec.loop,
		canvas = state.canvas,
		reaction = brain.env.last_reaction,
		current_reason = if decision then decision.reason else nil,
		ls_gag = decision ~= nil and decision.id == "react.ls_swat",
		notes = notes,
		settings = settings,
	}
end

local function stillRunning(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function renderAll()
	for pane, b in live do
		if pane == handling then
			continue
		end
		ensureSprites(b.state, b.cx)
		local ok = pcall(function()
			b.cx:render()
		end)
		if not ok then
			live[pane] = nil
		end
	end
end

local lastSeq = brain.decision_seq
brainMod.subscribe(brain, function(why: string)
	renderAll()
	if why ~= "tick" and brain.decision_seq ~= lastSeq then
		scheduleEngine()
	end
	lastSeq = brain.decision_seq
end)

local function toast(cx: BlockCx, level: ToastLevel, text: string, sub: string?)
	pcall(function()
		cx:toast(level, text, sub)
	end)
end

local function applySettings(cx: BlockCx, changes: { [string]: any }?, err: string?)
	if changes == nil then
		toast(cx, "error", "Setting not changed", err)
		return
	end
	local ok, writeErr = brainMod.setConfig(brain, changes)
	if not ok then
		toast(cx, "error", "Could not write config.json", writeErr)
	end
end

local function removePack(cx: BlockCx, id: string)
	local out = brainMod.removePack(brain, id)
	if not out.ok then
		toast(cx, "error", "Pack not removed", out.error)
		return
	end
	for _, b in live do
		b.state.previews[id] = nil
	end
	local name = out.name or id
	if out.config_error then
		toast(cx, "error", `Removed {name}, but the appearance was not saved`, out.config_error)
	elseif out.switched then
		local current = if brain.pack then brain.pack.manifest.name else brainMod.DEFAULT_PACK
		toast(cx, "success", `Removed {name}`, `Switched back to {current}.`)
	else
		toast(cx, "success", `Removed {name}`)
	end
end

local function runAction(state: BlockState, act: string, cx: BlockCx)
	local cmd = controls.resolveAction(act)
	if cmd == nil then
		return
	end
	if cmd.kind == "settings" then
		state.page = "settings"
		state.editing = nil
		return
	end
	local intent = cmd :: any
	local outcome = brainMod.localIntent(brain, intent.intent, intent.args)
	if outcome.kind == "rejected" then
		toast(cx, "error", "Tern Cat", outcome.error)
	elseif outcome.kind == "snooze" then
		toast(cx, "info", "Snoozing for 30 minutes", "Wake the cat any time with z or Wake.")
	end
end

local function handleEvent(state: BlockState, ev: UiEvent, cx: BlockCx)
	local kind = ev.ev
	if kind == "action" then
		local act = ev.act
		if act == "close-settings" or (act == "close" and ev.value == nil) then
			state.page = "main"
			state.editing = nil
		elseif act == "close" then
			state.editing = nil
		elseif act == "page" and type(ev.value) == "string" then
			state.settings_page = ev.value
			state.editing = nil
			state.confirm = nil
		elseif act == "pack" then
			applySettings(cx, controls.settingsChange("cat.appearance", ev.value))
		elseif act == "export" then
			local outcome = brainMod.localIntent(brain, "export_identity")
			if outcome.path then
				toast(cx, "success", "Identity exported", outcome.path)
			else
				toast(cx, "error", "Export failed", "See the Tern log for details.")
			end
		elseif act == "reset" then
			state.confirm = controls.armConfirm("reset", clock.now_ms())
		elseif act == "reset-confirm" then
			if controls.isArmed(state.confirm, "reset", clock.now_ms()) then
				brainMod.localIntent(brain, "reset_identity")
				toast(cx, "info", "A new cat moved in")
			end
			state.confirm = nil
		elseif act == "remove-pack" or act == "remove-pack-confirm" then
			local id = controls.removePackId(ev.value)
			if id == nil then
				return
			end
			local target = "pack:" .. id
			if act == "remove-pack" then
				state.confirm = controls.armConfirm(target, clock.now_ms())
				return
			end
			local armed = controls.isArmed(state.confirm, target, clock.now_ms())
			state.confirm = nil
			if armed then
				removePack(cx, id)
			else
				toast(cx, "info", "Pack not removed", "The confirmation expired; click Remove again.")
			end
		elseif act == "clear-ai" then
			brainMod.localIntent(brain, "clear_ai_state")
			toast(cx, "info", "AI state cleared")
		elseif type(act) == "string" then
			runAction(state, act, cx)
		end
	elseif kind == "activate" and type(ev.item) == "string" then
		state.editing = ev.item
	elseif kind == "change" then
		state.editing = nil
		applySettings(cx, controls.settingsChange(ev.item, ev.value))
	end
end

local function hasArg(args: any, name: string): boolean
	if type(args) ~= "table" then
		return false
	end
	for _, a in args do
		if a == name then
			return true
		end
	end
	return false
end

local cat: BlockDef<BlockState> = {
	init = function(cx, args, saved)
		local test = controls.parseTestMode(args)
		if test then
			brainMod.setTestMode(brain, test.seed, test.frozen)
			log("info", `test mode from block args: seed {test.seed}, frozen {test.frozen}`)
			scheduleEngine()
		end
		local s: any = if type(saved) == "table" then saved else {}
		local state: BlockState = {
			pane = cx.pane,
			page = if hasArg(args, "settings") or s.page == "settings" then "settings" else "main",
			settings_page = if type(s.settings_page) == "string" then s.settings_page else "general",
			editing = nil,
			confirm = nil,
			sprite_key = nil,
			sprites = {},
			canvas = { width = 32, height = 32 },
			previews = {},
		}
		ensureSprites(state, cx)
		live[cx.pane] = { state = state, cx = cx }
		return state
	end,

	title = function(_state)
		return "Tern Cat · " .. brain.config.cat.name
	end,

	view = function(state, cx)
		if live[cx.pane] == nil then
			live[cx.pane] = { state = state, cx = cx }
		end
		return blockView.view(modelFor(state, cx), tern.ui :: any) :: any
	end,

	key = function(state, key, cx)
		local env = brainMod.environment(brain)
		local act = controls.keyAction(
			key,
			state.page,
			brain.config.controls.keyboard_enabled,
			env.snoozed,
			brain.config.rendering.overlay
		)
		if act == nil then
			return false
		end
		handling = cx.pane
		if act == "close-settings" then
			state.page = "main"
			state.editing = nil
		else
			runAction(state, act, cx)
		end
		ensureSprites(state, cx)
		handling = nil
		return true
	end,

	event = function(state, ev, cx)
		handling = cx.pane
		local ok, err = pcall(handleEvent, state, ev, cx)
		ensureSprites(state, cx)
		handling = nil
		if not ok then
			log("error", "block event failed: " .. tostring(err))
		end
	end,

	save = function(state)
		return { page = state.page, settings_page = state.settings_page }
	end,
}

tern.block.define("cat", cat)

-- Host hooks --------------------------------------------------------------------------------------

hooks.register(tern.on, {
	commandStarted = function(pane: number?, category: T.CommandCategory)
		brainMod.onCommandStarted(brain, { pane = pane, category = category })
	end,
	commandFinished = function(pane: number?, category: T.CommandCategory, status: number?, took_ms: number?)
		brainMod.onCommandFinished(brain, { pane = pane, category = category, status = status, took_ms = took_ms })
	end,
	pane = function(pane: number?, kind: "cwd" | "exited")
		brainMod.onPaneEvent(brain, pane, kind)
	end,
	failed = function(hook: string, err: string)
		log("error", hook .. " hook failed: " .. err)
	end,
})

-- Polls -------------------------------------------------------------------------------------------

local function pollInbox()
	local ok, err = pcall(brainMod.pollInbox, brain)
	if not ok then
		log("error", "inbox poll failed: " .. tostring(err))
	end
	tern.timer(INBOX_MS, pollInbox)
end

local function pollConfig()
	local ok, err = pcall(brainMod.pollConfig, brain)
	if not ok then
		log("error", "config poll failed: " .. tostring(err))
	end
	for pane in live do
		if not stillRunning(pane) then
			live[pane] = nil
		end
	end
	tern.timer(CONFIG_MS, pollConfig)
end

tern.timer(INBOX_MS, pollInbox)
tern.timer(CONFIG_MS, pollConfig)
scheduleEngine()
