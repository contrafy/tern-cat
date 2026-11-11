--!strict
-- Sandbox-only probe linked by scripts/compat.sh next to a snapshot of tern-cat; never shipped.
-- Its "report" command writes <plugin data>/probe.json with what tern-cat's window glue reads
-- from Tern (window.luau): the settings that place the in-pane cat and the reduced-motion
-- setting, the focused pane's PaneInfo fields, its tab's split layout, the cat blocks' pane
-- flags, the hide chord's binding, and which window events fired with which pane ids. It keeps
-- no command line (only whether one is running) and reads no pane content.

local OUT = tern.plugin.data .. "/probe.json"
local SETTINGS = { "layout", "density", "pane_headers", "ui_font_size", "font_size", "reduce_motion" }
local EVENTS = { "focus", "pane_created", "pane_closed", "command_started", "command_finished", "budget" }
local CHORD = "ctrl+alt+cmd+c"

local fired: { [string]: number } = {}
local lastPane: { [string]: number } = {}

for _, name in EVENTS do
	tern.on(name, function(ev: any, _cx: any)
		fired[name] = (fired[name] or 0) + 1
		if type(ev) == "table" and type(ev.pane) == "number" then
			lastPane[name] = ev.pane
		end
	end)
end

local function try(fn: () -> any): any
	local ok, value = pcall(fn)
	if ok then
		return if value == nil then "<nil>" else value
	end
	return { error = tostring(value) }
end

local function tree(node: any, depth: number): any
	if type(node) ~= "table" or depth > 32 then
		return nil
	end
	if node.pane ~= nil then
		return { pane = node.pane }
	end
	return {
		split = node.split,
		ratio = node.ratio,
		first = tree(node[1], depth + 1),
		second = tree(node[2], depth + 1),
	}
end

local function paneInfo(info: PaneInfo?): any
	if info == nil then
		return "<nil>"
	end
	return {
		pane = info.pane,
		kind = info.kind,
		tab = info.tab,
		program = info.program,
		at_prompt = info.at_prompt,
		running = info.running ~= nil,
		block = info.block,
		floating = info.floating,
		parked = info.parked,
		focused = info.focused,
	}
end

local function report(cx: WindowCx)
	local out: { [string]: any } = { settings = {} }
	for _, key in SETTINGS do
		out.settings[key] = try(function(): any
			return cx.settings:get(key)
		end)
	end
	local focused = cx.session:focused()
	out.focused = focused or "<nil>"
	out.pane = try(function(): any
		return paneInfo(if focused then cx.session:pane(focused) else nil)
	end)
	out.layout = try(function(): any
		local tab = if focused then cx.session:tab_of(focused) else nil
		local layout = if tab then cx.session:layout(tab) else nil
		if layout == nil then
			return nil
		end
		local floats = {}
		for _, f in layout.floats do
			table.insert(floats, { pane = f.pane, over = f.over })
		end
		return { tab = tab, zoomed = layout.zoomed, root = tree(layout.root, 0), floats = floats }
	end)
	out.panes = try(function(): any
		local list = {}
		for _, info in cx.session:panes() do
			table.insert(list, paneInfo(info))
		end
		return list
	end)
	out.chord = try(function(): any
		return cx.actions:keys()[CHORD]
	end)
	local anyCx = cx :: any
	out.window_key = if type(anyCx.window_key) == "function"
		then try(function(): any
			return anyCx:window_key()
		end)
		else "<absent>"
	out.events = { fired = fired, last_pane = lastPane }
	tern.fs.mkdir(tern.plugin.data)
	tern.fs.write(OUT, tern.json.encode(out, true))
end

tern.command({
	id = "report",
	title = "Report",
	group = "Tern Cat compat probe",
	run = report,
})
