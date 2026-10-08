--!strict
-- Opening the interactive cat block from the window half: reuse an existing block in this
-- window, else open one beside the focused pane and (by default) float it into that pane's
-- bottom-right corner, keeping the split when floating is not possible.

export type Ui = {
	focused: () -> number?,
	-- Panes of this window that show a tern-cat block.
	catBlocks: () -> { number },
	newBlock: (args: { string }) -> number?,
	float: (pane: number, owner: number) -> (boolean, string?),
	focus: (pane: number) -> (),
	send: (pane: number, payload: { [string]: any }) -> (),
}

export type Placement = "float" | "split"

export type Opened = {
	pane: number?,
	placement: "float" | "split" | "existing" | nil,
	note: string?,
	error: string?,
}

local SETTINGS_ARG = "settings"
local SETTINGS_EVENT = { ev = "action", id = "settings", act = "settings" }

local function open(ui: Ui, placement: Placement, settings: boolean): Opened
	local existing = ui.catBlocks()[1]
	if existing ~= nil then
		pcall(ui.focus, existing)
		if settings then
			pcall(ui.send, existing, table.clone(SETTINGS_EVENT))
		end
		return { pane = existing, placement = "existing" }
	end

	local owner = ui.focused()
	local ok, pane = pcall(ui.newBlock, if settings then { SETTINGS_ARG } else {})
	if not ok then
		return { error = `could not open the cat block: {pane}` }
	end
	if type(pane) ~= "number" then
		return { error = "could not open the cat block (is the tern-cat host half running?)" }
	end
	if placement ~= "float" or owner == nil then
		return { pane = pane, placement = "split" }
	end
	local called, floated, why = pcall(ui.float, pane, owner)
	if called and floated then
		return { pane = pane, placement = "float" }
	end
	local reason = if called then why else floated
	return { pane = pane, placement = "split", note = `floating failed: {tostring(reason or "unknown")}` }
end

return {
	SETTINGS_ARG = SETTINGS_ARG,
	open = open,
}
