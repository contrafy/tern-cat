--!strict
-- The Cat menu: the items of Tern's inline picker (`cx:pick`) for quick actions, and what a chosen
-- item does. Pure: the window glue opens the picker, then runs the returned Action through the
-- same paths as the palette commands (intents for anything that changes the cat or config.json).

local T = require("../types")
local schema = require("../config/schema")

export type Menu = "top" | "feed" | "play" | "appearance" | "transition" | "corner"

-- One sprite pack the Appearance submenu offers.
export type PackChoice = { id: string, name: string, detail: string? }
-- A valid sprite pack (from the host's catalog, or validated by this window).
export type PackInfo = { id: string, name: string, author: string?, source: T.PackSource }

-- What the menu shows: read from this window's controller when it opens.
export type State = {
	overlay_visible: boolean,
	snoozed: boolean,
	-- The pack the cat shows (the configured one, or the fallback when that one is unavailable).
	appearance: string,
	pane_transition: T.PaneTransition,
	overlay_position: T.OverlayPosition,
	-- Valid packs, sorted by name.
	packs: { PackChoice },
	-- Pack folders not validated yet (the window scans them one per timer tick).
	packs_pending: boolean,
}

-- A picker row. `act` and `arg` ride along to the answer (Tern hands back the item passed in).
export type Item = {
	label: string,
	detail: string?,
	group: string?,
	icon: string?,
	current: boolean?,
	act: string,
	arg: string?,
}

export type Options = { items: { Item }, placeholder: string, icon: string? }

export type Action =
	{ kind: "intent", intent: T.IntentKind, args: { [string]: any }?, done: string? }
	| { kind: "toggle_overlay" }
	| { kind: "open", settings: boolean }
	| { kind: "menu", menu: Menu }

local SNOOZE_MINUTES = 30
local FOODS = { "treat", "kibble", "fish" }
local TOYS = { "ball", "string", "feather" }
-- Same labels as the block's settings page (cat/render/block.luau).
local TRANSITION_LABELS: { [string]: string } = {
	portal = "Swirly portal",
	vent = "Floor vent",
	box = "Cardboard box",
	walk = "Walk over",
	auto = "Walk to neighbors",
	off = "Off",
}
local CORNER_LABELS: { [string]: string } = {
	["top-right"] = "Top right",
	["top-left"] = "Top left",
	["bottom-right"] = "Bottom right",
	["bottom-left"] = "Bottom left",
}
local SUBMENUS: { Menu } = { "feed", "play", "appearance", "transition", "corner" }

-- Tern's picture-in-picture corner icons (`pip` is its bottom-right one).
local CORNER_ICONS: { [string]: string } = {
	["top-right"] = "pip-tr",
	["top-left"] = "pip-tl",
	["bottom-right"] = "pip",
	["bottom-left"] = "pip-bl",
}
local function capitalize(s: string): string
	return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

local function packName(state: State, id: string): string
	for _, p in state.packs do
		if p.id == id then
			return p.name
		end
	end
	return id
end

local function top(state: State): Options
	local cat, overlay, block = "Cat", "Overlay", "Block"
	return {
		placeholder = "Tern Cat",
		icon = "footprints",
		items = {
			{ label = "Pet", group = cat, icon = "hand", act = "pet" },
			{ label = "Poke", group = cat, icon = "cursor", act = "poke" },
			{ label = "Feed...", group = cat, icon = "cherry", act = "menu", arg = "feed" },
			{ label = "Play...", group = cat, icon = "sparkle", act = "menu", arg = "play" },
			if state.snoozed
				then { label = "Wake", group = cat, icon = "sun", act = "wake" }
				else { label = `Snooze {SNOOZE_MINUTES} min`, group = cat, icon = "moon", act = "snooze" },
			{
				label = if state.overlay_visible then "Hide overlay" else "Show overlay",
				group = overlay,
				icon = if state.overlay_visible then "eye-off" else "eye",
				act = "toggle",
			},
			{
				label = "Appearance...",
				detail = packName(state, state.appearance),
				group = overlay,
				icon = "palette",
				act = "menu",
				arg = "appearance",
			},
			{
				label = "Pane switch...",
				detail = TRANSITION_LABELS[state.pane_transition],
				group = overlay,
				icon = "swap",
				act = "menu",
				arg = "transition",
			},
			{
				label = "Overlay corner...",
				detail = CORNER_LABELS[state.overlay_position],
				group = overlay,
				icon = CORNER_ICONS[state.overlay_position],
				act = "menu",
				arg = "corner",
			},
			{ label = "Open cat", group = block, icon = "open", act = "open" },
			{ label = "Cat settings", group = block, icon = "sliders", act = "settings" },
		},
	}
end

local function choices(
	act: string,
	values: { string },
	labels: { [string]: string }?,
	current: string?,
	icons: { [string]: string }?
): { Item }
	local out: { Item } = {}
	for _, v in values do
		table.insert(out, {
			label = if labels then labels[v] or v else capitalize(v),
			icon = if icons then icons[v] else nil,
			current = if current ~= nil then v == current else nil,
			act = act,
			arg = v,
		})
	end
	return out
end

-- The picker options of `name` for `state`.
local function options(name: Menu, state: State): Options
	if name == "feed" then
		return { placeholder = "Feed the cat", icon = "cherry", items = choices("feed", FOODS) }
	elseif name == "play" then
		return { placeholder = "Play with the cat", icon = "sparkle", items = choices("play", TOYS) }
	elseif name == "transition" then
		return {
			placeholder = "Pane switch",
			icon = "swap",
			items = choices("transition", schema.PANE_TRANSITIONS, TRANSITION_LABELS, state.pane_transition),
		}
	elseif name == "corner" then
		return {
			placeholder = "Overlay corner",
			icon = CORNER_ICONS[state.overlay_position],
			items = choices("corner", schema.OVERLAY_POSITIONS, CORNER_LABELS, state.overlay_position, CORNER_ICONS),
		}
	elseif name == "appearance" then
		local items: { Item } = {}
		for _, p in state.packs do
			table.insert(items, {
				label = p.name,
				detail = p.detail,
				current = p.id == state.appearance,
				act = "appearance",
				arg = p.id,
			})
		end
		if state.packs_pending then
			table.insert(items, { label = "More packs are loading...", act = "menu", arg = "appearance" })
		end
		return { placeholder = "Appearance", icon = "palette", items = items }
	end
	return top(state)
end

local function setConfig(key: string, value: string, done: string): Action
	return { kind = "intent", intent = "set_config", args = { key = key, value = value }, done = done }
end

-- What a chosen picker item does; nil for a dismissed picker (nil) or an item this menu did not make.
local function choose(item: any): Action?
	if type(item) ~= "table" or type(item.act) ~= "string" then
		return nil
	end
	local act: string = item.act
	local arg: string? = if type(item.arg) == "string" then item.arg else nil
	if act == "pet" or act == "poke" then
		return { kind = "intent", intent = act :: T.IntentKind }
	elseif act == "snooze" then
		return {
			kind = "intent",
			intent = "snooze",
			args = { minutes = SNOOZE_MINUTES },
			done = `Snoozed for {SNOOZE_MINUTES} minutes.`,
		}
	elseif act == "wake" then
		return { kind = "intent", intent = "unsnooze" }
	elseif act == "toggle" then
		return { kind = "toggle_overlay" }
	elseif act == "open" or act == "settings" then
		return { kind = "open", settings = act == "settings" }
	elseif arg == nil then
		return nil
	elseif act == "menu" then
		local menu = table.find(SUBMENUS, arg :: Menu)
		return if menu then { kind = "menu", menu = SUBMENUS[menu] } else nil
	elseif act == "feed" then
		return { kind = "intent", intent = "feed", args = { item = arg } }
	elseif act == "play" then
		return { kind = "intent", intent = "play", args = { toy = arg } }
	elseif act == "appearance" then
		local label = if type(item.label) == "string" then item.label else arg
		return setConfig("cat.appearance", arg, `Appearance: {label}`)
	elseif act == "transition" then
		return setConfig("rendering.pane_transition", arg, `Pane switch: {TRANSITION_LABELS[arg] or arg}`)
	elseif act == "corner" then
		return setConfig("rendering.overlay_position", arg, `Overlay corner: {CORNER_LABELS[arg] or arg}`)
	end
	return nil
end

-- Appearance choices from valid packs: sorted by name (then id), detail the author, else where
-- the pack comes from.
local function packChoices(packs: { PackInfo }): { PackChoice }
	local out: { PackChoice } = {}
	for _, p in packs do
		local author = p.author
		table.insert(out, {
			id = p.id,
			name = p.name,
			detail = if author and author ~= "" then author elseif p.source == "user" then "user pack" else "bundled",
		})
	end
	table.sort(out, function(a, b)
		local la, lb = string.lower(a.name), string.lower(b.name)
		if la ~= lb then
			return la < lb
		end
		return a.id < b.id
	end)
	return out
end

-- Whether this window's Tern has the inline picker (`cx:pick`, added in Tern 0.7.1).
local function canPick(cx: any): boolean
	local ok, pick = pcall(function(): any
		return cx.pick
	end)
	return ok and type(pick) == "function"
end

return {
	SNOOZE_MINUTES = SNOOZE_MINUTES,
	options = options,
	canPick = canPick,
	choose = choose,
	packChoices = packChoices,
}
