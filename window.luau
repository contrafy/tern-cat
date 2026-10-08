--!strict
-- Window half: this window's overlay cat, palette commands, the hide chord and Carly exports.
-- Everything is set up from entry load (window_start does not re-fire on reload); the logic lives
-- in cat/window/*.luau and cat/integrations/carly.luau.
--
-- Compiling every module takes 30-45 ms, too close to the 50 ms window budget for one call, so
-- the entry only registers commands and events and then loads the modules in time-boxed timer
-- slices before starting the overlay.

local entryStart = tern.now()
local blocks = require("./cat/window/blocks")

type ControllerModule = typeof(require("./cat/window/controller"))
type CarlyModule = typeof(require("./cat/integrations/carly"))

local BLOCK_KIND = "tern-cat.cat"
local GROUP = "Tern Cat"
local TITLE = "Tern Cat"
local TOGGLE_ID = "toggle-overlay"
local TOGGLE_ACTION = "plugin.tern-cat." .. TOGGLE_ID
-- The always-available instant dismiss. Free in Tern 0.6.2's default keymap; rebind it with a
-- settings.json "keybinds" entry for action plugin.tern-cat.toggle-overlay.
local TOGGLE_CHORD = "ctrl+alt+cmd+c"
local SNOOZE_MINUTES = 30
local STARTING = "Tern Cat is still starting; try again in a moment."
local WINDOW_EVENTS = {
	"focus",
	"pane_created",
	"pane_closed",
	"tab_created",
	"tab_closed",
	"command_started",
	"command_finished",
	"cwd",
}
-- Dependency order, so each require compiles only that module.
local BOOT_MODULES = {
	"types",
	"core/util",
	"core/rng",
	"core/clock",
	"render/animations",
	"sprite/png",
	"sprite/manifest",
	"sprite/loader",
	"render/overlay",
	"config/schema",
	"core/events",
	"core/commands",
	"core/needs",
	"core/model",
	"core/store",
	"core/behavior",
	"integrations/ai",
	"integrations/carly",
	"adapters/clock",
	"adapters/fs",
	"adapters/json",
	"adapters/kv",
	"adapters/paths",
	"adapters/config",
	"window/presenter",
	"window/packs",
	"window/intents",
	"window/mirror",
	"window/controller",
}
local SLICE_MS = 15

local controllerMod: ControllerModule = nil :: any
local carly: CarlyModule = nil :: any
local ctl: any = nil
local exportsDir = ""
local keysChecked = false

local function toast(cx: WindowCx, level: ToastLevel, text: string, sub: string?)
	pcall(function()
		cx:toast(level, text, sub)
	end)
end

local function checkChord(cx: WindowCx)
	keysChecked = true
	local ok, keys = pcall(function()
		return cx.actions:keys()
	end)
	if not ok or type(keys) ~= "table" then
		return
	end
	local bound = keys[TOGGLE_CHORD]
	if bound == nil or table.find(bound, TOGGLE_ACTION) == nil then
		tern.log.warn(`tern-cat: {TOGGLE_CHORD} is not bound to {TOGGLE_ACTION}; use the palette or rebind it`)
	end
end

local function reduceMotion(cx: WindowCx): boolean?
	local ok, value = pcall(function()
		return cx.settings:get("reduce_motion")
	end)
	if not ok then
		return nil
	end
	return value == "on"
end

-- True when the focused pane is a tern-cat block, or one floats over it: the overlay would sit
-- on top of the interactive cat.
local function cardCovers(cx: WindowCx): boolean?
	local ok, covered = pcall(function(): boolean
		local focused = cx.session:focused()
		local own = if focused then cx.session:pane(focused) else nil
		if own and own.block == BLOCK_KIND then
			return true
		end
		local tab = if focused then cx.session:tab_of(focused) else nil
		local layout = if tab then cx.session:layout(tab) else nil
		if layout == nil then
			return false
		end
		for _, float in layout.floats do
			if float.over == focused then
				local info = cx.session:pane(float.pane)
				if info and info.block == BLOCK_KIND and not info.parked then
					return true
				end
			end
		end
		return false
	end)
	return if ok then covered else nil
end

local function updateCover(cx: WindowCx)
	if ctl == nil then
		return
	end
	local covered = cardCovers(cx)
	if covered ~= nil then
		controllerMod.setCovered(ctl, covered)
	end
end

local function blockUi(cx: WindowCx): blocks.Ui
	return {
		focused = function(): number?
			return cx.session:focused()
		end,
		tabOf = function(pane: number): number?
			return cx.session:tab_of(pane)
		end,
		catBlocks = function(): { blocks.CatBlock }
			local out = {}
			for _, info in cx.session:panes() do
				if info.block == BLOCK_KIND then
					table.insert(out, {
						pane = info.pane,
						tab = info.tab,
						floating = info.floating == true,
						parked = info.parked == true,
					})
				end
			end
			return out
		end,
		newBlock = function(args: { string }): number?
			return cx:new_block(BLOCK_KIND, args, "beside")
		end,
		float = function(pane: number, owner: number): (boolean, string?)
			return cx.layout:float(pane, owner, "br")
		end,
		unpark = function(pane: number): (boolean, string?)
			return cx.layout:unpark(pane)
		end,
		focus = function(pane: number)
			cx.layout:focus(pane)
		end,
		send = function(pane: number, payload: { [string]: any })
			cx.session:event(pane, payload)
		end,
		debug = function(message: string)
			tern.log.debug(`tern-cat: {message}`)
		end,
	}
end

-- Commands ------------------------------------------------------------------------------

type Result = { ok: boolean, error: string? }

local function reportFailure(cx: WindowCx, result: Result)
	if not result.ok then
		toast(cx, "error", TITLE, result.error)
	end
end

local function command(id: string, title: string, run: (cx: WindowCx) -> (), keys: { string }?)
	tern.command({
		id = id,
		title = title,
		group = GROUP,
		keys = keys,
		run = function(cx: WindowCx)
			if ctl == nil then
				toast(cx, "info", TITLE, STARTING)
				return
			end
			local ok, err = pcall(function()
				run(cx)
			end)
			if not ok then
				tern.log.warn(`tern-cat: command {id} failed: {err}`)
				toast(cx, "error", TITLE, `{title} failed`)
			end
		end,
	})
end

local function intentCommand(id: string, title: string, kind: string, args: { [string]: any }?, done: string?)
	command(id, title, function(cx: WindowCx)
		local result = controllerMod.request(ctl, kind :: any, args, "window")
		reportFailure(cx, result)
		if result.ok and done then
			toast(cx, "info", TITLE, done)
		end
	end)
end

local function openBlock(cx: WindowCx, settings: boolean)
	local opened = blocks.open(blockUi(cx), ctl.config.rendering.block_placement, settings)
	if opened.error then
		tern.log.warn(`tern-cat: {opened.error}`)
		toast(cx, "error", TITLE, opened.error)
	elseif opened.note then
		tern.log.warn(`tern-cat: {opened.note}`)
		toast(cx, "info", TITLE, `Opened as a split: {opened.note}`)
	end
	updateCover(cx)
end

command("open", "Open cat", function(cx: WindowCx)
	openBlock(cx, false)
end)
intentCommand("pet", "Pet the cat", "pet")
intentCommand("poke", "Poke the cat", "poke")
intentCommand("feed", "Feed the cat", "feed")
intentCommand("play", "Play with the cat", "play")
command(TOGGLE_ID, "Hide or show the overlay cat", function(cx: WindowCx)
	local result, visible = controllerMod.toggleOverlay(ctl, "window")
	reportFailure(cx, result)
	if not visible then
		toast(
			cx,
			"info",
			"Overlay cat hidden",
			`Press {TOGGLE_CHORD} or run "Hide or show the overlay cat" to bring it back.`
		)
	end
end, { TOGGLE_CHORD })
intentCommand(
	"snooze",
	`Snooze the cat ({SNOOZE_MINUTES} min)`,
	"snooze",
	{ minutes = SNOOZE_MINUTES },
	`Snoozed for {SNOOZE_MINUTES} minutes.`
)
intentCommand("wake", "Wake the cat", "unsnooze")
command("reload-config", "Reload config", function(cx: WindowCx)
	controllerMod.reloadConfig(ctl)
	toast(cx, "info", "Tern Cat config reloaded", ctl.ports.paths.config)
end)
command("settings", "Cat settings", function(cx: WindowCx)
	openBlock(cx, true)
end)
command("export-identity", "Export cat identity", function(cx: WindowCx)
	local result = controllerMod.request(ctl, "export_identity", nil, "window")
	reportFailure(cx, result)
	if result.ok then
		toast(cx, "info", TITLE, `Export requested: {exportsDir}/`)
	end
end)
command("reset-identity", "Reset cat identity", function(cx: WindowCx)
	if not controllerMod.confirmReset(ctl) then
		toast(
			cx,
			"info",
			"Run Reset cat identity again within 10 seconds to confirm",
			"A new cat replaces the current one: stats and journal start over. Config is kept."
		)
		return
	end
	local result = controllerMod.request(ctl, "reset_identity", nil, "window")
	reportFailure(cx, result)
	if result.ok then
		toast(cx, "info", TITLE, "A new cat is moving in.")
	end
end)
intentCommand("clear-ai-state", "Clear AI state", "clear_ai_state", nil, "AI-related journal entries cleared.")

for _, name in WINDOW_EVENTS do
	tern.on(name, function(ev: any, cx: WindowCx)
		if ctl == nil then
			return
		end
		controllerMod.onWindowEvent(ctl, name, ev)
		updateCover(cx)
	end)
end

-- Carly -----------------------------------------------------------------------------------

local function registerCarly()
	local api = tern.carly
	if not api then
		return
	end
	local function call(name: string, a: any, b: any): { [string]: any }
		if name == "status" then
			return carly.status(controllerMod.snapshot(ctl))
		elseif name == "explain" then
			return carly.explain(controllerMod.snapshot(ctl))
		elseif name == "ai_status" then
			return carly.aiStatus(ctl.config)
		end
		local kind, args, err = carly.toIntent(name, a, b)
		if kind == nil then
			return { ok = false, error = err or `unknown export {name}` }
		end
		local result = controllerMod.request(ctl, kind :: any, args, "carly")
		return { ok = result.ok, error = result.error }
	end

	local function safe(name: string, a: any, b: any): { [string]: any }
		local ok, result = pcall(call, name, a, b)
		if ok then
			return result
		end
		tern.log.warn(`tern-cat: Carly export {name} failed: {result}`)
		return { ok = false, error = "internal error" }
	end

	for _, def in carly.EXPORTS do
		local name = def.name
		local fn: (...any) -> ...any
		if def.arity == 2 then
			fn = function(a: any, b: any, _cx: any, _call: any)
				return safe(name, a, b)
			end
		elseif def.arity == 1 then
			fn = function(a: any, _cx: any, _call: any)
				return safe(name, a, nil)
			end
		else
			fn = function(_cx: any, _call: any)
				return safe(name, nil, nil)
			end
		end
		api.export(name, { sig = def.sig, doc = def.doc }, fn)
	end

	api.context(function(_cx: WindowCx): string?
		return controllerMod.context(ctl)
	end)
end

-- Boot ------------------------------------------------------------------------------------

local load = require :: any
local boot = { index = 1, slices = 0, max_slice_ms = 0 }

local function start()
	local clockAdapter = load("./cat/adapters/clock")
	local pathsAdapter = load("./cat/adapters/paths")
	local clock = clockAdapter.real()
	local paths = pathsAdapter.current()
	exportsDir = paths.exports
	local instance = controllerMod.new({
		clock = clock,
		wall_ms = function(): number
			return clock.wall_precise() * 1000
		end,
		fs = load("./cat/adapters/fs").new(),
		json = load("./cat/adapters/json").new(),
		kv = load("./cat/adapters/kv").new(),
		paths = paths,
		css = function(name: string, source: string)
			tern.css(name, source)
		end,
		timer = function(ms: number, fn: (any) -> ()): any
			return tern.timer(ms, function(cx: WindowCx?)
				local info = nil
				if cx then
					if not keysChecked then
						checkChord(cx)
					end
					info = { reduce_motion = reduceMotion(cx), covered = cardCovers(cx) }
				end
				fn(info)
			end)
		end,
		base64 = function(bytes: string): string
			return tern.base64.encode(bytes)
		end,
		log = function(level: "debug" | "info" | "warn", message: string)
			tern.log[level](message)
		end,
		seed = math.floor(tern.now() * 1000) + os.time(),
	})
	local setupMs = controllerMod.start(instance)
	ctl = instance
	registerCarly()
	tern.log.info(
		string.format(
			"tern-cat window ready in %.1f ms (%d load slices, slowest %.1f ms; overlay setup %.1f ms)",
			tern.now() - entryStart,
			boot.slices,
			boot.max_slice_ms,
			setupMs
		)
	)
end

local function bootSlice()
	local t0 = tern.now()
	local ok, err = pcall(function()
		while boot.index <= #BOOT_MODULES and tern.now() - t0 < SLICE_MS do
			load("./cat/" .. BOOT_MODULES[boot.index])
			boot.index += 1
		end
	end)
	boot.slices += 1
	boot.max_slice_ms = math.max(boot.max_slice_ms, tern.now() - t0)
	if not ok then
		tern.log.error(`tern-cat: loading failed: {err}`)
		return
	end
	if boot.index <= #BOOT_MODULES then
		tern.timer(0, bootSlice)
		return
	end
	tern.timer(0, function()
		controllerMod = load("./cat/window/controller")
		carly = load("./cat/integrations/carly")
		local started, startErr = pcall(function()
			start()
		end)
		if not started then
			tern.log.error(`tern-cat: overlay start failed: {startErr}`)
		end
	end)
end

tern.timer(0, bootSlice)
