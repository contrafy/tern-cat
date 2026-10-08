--!strict
-- Opening the interactive cat block from the window half. A cat block already shown in the
-- focused pane's tab is focused. Otherwise (by default) the cat is brought to the focused pane as
-- a floating card in its bottom-right corner: a cat card floating in another tab or parked moves
-- here, else a new block opens beside the focused pane and floats. Cat blocks tiled into other
-- tabs are left where they are. When floating fails the block stays a split and the reason is
-- returned as a note.

export type CatBlock = {
	pane: number,
	-- Containing tab; nil when parked.
	tab: number?,
	floating: boolean,
	parked: boolean,
}

export type Ui = {
	focused: () -> number?,
	tabOf: (pane: number) -> number?,
	-- Panes of this window that show a tern-cat block, parked ones included.
	catBlocks: () -> { CatBlock },
	newBlock: (args: { string }) -> number?,
	float: (pane: number, owner: number) -> (boolean, string?),
	unpark: (pane: number) -> (boolean, string?),
	focus: (pane: number) -> (),
	send: (pane: number, payload: { [string]: any }) -> (),
	debug: (message: string) -> (),
}

export type Placement = "float" | "split"

export type Opened = {
	pane: number?,
	placement: "float" | "split" | "existing" | nil,
	-- Set when the new block could not be floated and stays a split.
	note: string?,
	error: string?,
}

local SETTINGS_ARG = "settings"
local SETTINGS_EVENT = { ev = "action", id = "settings", act = "settings" }

local function describe(b: CatBlock): string
	local where = if b.parked then "parked" elseif b.floating then "floating" else "tiled"
	return `{b.pane}({where}, tab {tostring(b.tab)})`
end

local function showSettings(ui: Ui, pane: number, settings: boolean)
	if settings then
		pcall(ui.send, pane, table.clone(SETTINGS_EVENT))
	end
end

-- Runs a (boolean, string?) layout call; a raise becomes false with the error as the reason.
local function attempt(call: () -> (boolean, string?)): (boolean, string)
	local called, ok, why = pcall(call)
	if called and ok then
		return true, ""
	end
	return false, tostring((if called then why else ok) or "unknown")
end

local function open(ui: Ui, placement: Placement, settings: boolean): Opened
	local owner = ui.focused()
	local here = if owner ~= nil then ui.tabOf(owner) else nil
	local found = ui.catBlocks()
	local listed = {}
	for _, b in found do
		table.insert(listed, describe(b))
	end
	ui.debug(
		`open: placement {placement}, focused {tostring(owner)} in tab {tostring(here)}, cat blocks [{table.concat(
			listed,
			", "
		)}]`
	)

	-- A cat already in this tab: focus it wherever it sits.
	for _, b in found do
		if not b.parked and here ~= nil and b.tab == here then
			ui.debug(`open: focusing cat block {b.pane} already in this tab`)
			pcall(ui.focus, b.pane)
			showSettings(ui, b.pane, settings)
			return { pane = b.pane, placement = "existing" }
		end
	end

	-- A floating card from another tab, or a parked cat: bring it here.
	if owner ~= nil then
		for _, b in found do
			if placement == "float" and (b.floating or b.parked) then
				local ok, why = attempt(function()
					return ui.float(b.pane, owner)
				end)
				if ok then
					ui.debug(`open: floated cat block {b.pane} over pane {owner}`)
					showSettings(ui, b.pane, settings)
					return { pane = b.pane, placement = "float" }
				end
				ui.debug(`open: floating cat block {b.pane} failed: {why}; opening a new block`)
				break
			elseif placement == "split" and b.parked then
				local ok, why = attempt(function()
					return ui.unpark(b.pane)
				end)
				if ok then
					ui.debug(`open: unparked cat block {b.pane} beside pane {owner}`)
					showSettings(ui, b.pane, settings)
					return { pane = b.pane, placement = "split" }
				end
				ui.debug(`open: unparking cat block {b.pane} failed: {why}; opening a new block`)
				break
			end
		end
	end

	local ok, pane = pcall(ui.newBlock, if settings then { SETTINGS_ARG } else {})
	if not ok then
		return { error = `could not open the cat block: {pane}` }
	end
	if type(pane) ~= "number" then
		return { error = "could not open the cat block (is the tern-cat host half running?)" }
	end
	if placement ~= "float" or owner == nil then
		ui.debug(`open: opened cat block {pane} as a split ({placement}, focused {tostring(owner)})`)
		return { pane = pane, placement = "split" }
	end
	local floated, why = attempt(function()
		return ui.float(pane, owner)
	end)
	if floated then
		ui.debug(`open: opened cat block {pane} floating over pane {owner}`)
		return { pane = pane, placement = "float" }
	end
	ui.debug(`open: floating new cat block {pane} failed: {why}; keeping the split`)
	return { pane = pane, placement = "split", note = `floating failed: {why}` }
end

return {
	SETTINGS_ARG = SETTINGS_ARG,
	open = open,
}
