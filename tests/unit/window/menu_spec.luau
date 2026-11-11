--!strict
local t = require("../../lib/test")
local commands = require("../../../cat/core/commands")
local menu = require("../../../cat/window/menu")

local describe, it, expect = t.describe, t.it, t.expect

local function state(overrides: { [string]: any }?): menu.State
	local s: { [string]: any } = {
		overlay_visible = true,
		snoozed = false,
		appearance = "orange-menace",
		pane_transition = "portal",
		overlay_position = "top-right",
		packs = {
			{ id = "orange-menace", name = "Orange Menace", detail = "Ahmad Raaiyan" },
			{ id = "void", name = "Void", detail = "bundled" },
		},
		packs_pending = false,
	}
	for k, v in overrides or {} do
		s[k] = v
	end
	return s :: any
end

local function labels(opts: menu.Options): { string }
	local out = {}
	for _, item in opts.items do
		table.insert(out, item.label)
	end
	return out
end

local function find(opts: menu.Options, label: string): menu.Item
	for _, item in opts.items do
		if item.label == label then
			return item
		end
	end
	error(`no item {label}`)
end

local function currents(opts: menu.Options): { string }
	local out = {}
	for _, item in opts.items do
		if item.current then
			table.insert(out, item.label)
		end
	end
	return out
end

-- The intent a window would write for `action`, validated like the host does.
local function validated(action: menu.Action): any
	assert(action.kind == "intent", "intent action")
	local a = action :: any
	local intent, err = commands.validate({
		intent_id = "w-1",
		at = 1,
		kind = a.intent,
		source = "window",
		args = a.args or {},
	})
	assert(intent, err)
	return intent
end

describe("window/menu top level", function()
	it("lists the quick actions in groups", function()
		local opts = menu.options("top", state())
		expect(labels(opts)).toEqual({
			"Pet",
			"Poke",
			"Feed...",
			"Play...",
			"Snooze 30 min",
			"Hide overlay",
			"Appearance...",
			"Pane switch...",
			"Overlay corner...",
			"Open cat",
			"Cat settings",
		})
		local groups = {}
		for _, item in opts.items do
			if groups[#groups] ~= item.group then
				table.insert(groups, item.group)
			end
		end
		expect(groups).toEqual({ "Cat", "Overlay", "Block" })
		expect(opts.placeholder).toBe("Tern Cat")
	end)

	it("offers Wake while snoozed and Show overlay while hidden", function()
		local opts = menu.options("top", state({ snoozed = true, overlay_visible = false }))
		expect(labels(opts)).toContain("Wake")
		expect(labels(opts)).notToContain("Snooze 30 min")
		expect(labels(opts)).toContain("Show overlay")
		expect(labels(opts)).notToContain("Hide overlay")
	end)

	it("shows the current settings next to their submenus", function()
		local opts = menu.options(
			"top",
			state({ appearance = "void", pane_transition = "walk", overlay_position = "bottom-left" })
		)
		expect(find(opts, "Appearance...").detail).toBe("Void")
		expect(find(opts, "Pane switch...").detail).toBe("Walk over")
		expect(find(opts, "Overlay corner...").detail).toBe("Bottom left")
	end)

	it("maps every top-level item to an action", function()
		local opts = menu.options("top", state())
		local kinds = {}
		for _, item in opts.items do
			local action = menu.choose(item)
			assert(action, item.label)
			table.insert(kinds, action.kind)
		end
		expect(kinds).toEqual({
			"intent",
			"intent",
			"menu",
			"menu",
			"intent",
			"toggle_overlay",
			"menu",
			"menu",
			"menu",
			"open",
			"open",
		})
		expect(validated(menu.choose(find(opts, "Pet")) :: menu.Action).kind).toBe("pet")
		expect(validated(menu.choose(find(opts, "Poke")) :: menu.Action).kind).toBe("poke")
		local snooze = menu.choose(find(opts, "Snooze 30 min")) :: any
		expect(validated(snooze).args).toEqual({ minutes = 30 })
		expect(snooze.done).toBe("Snoozed for 30 minutes.")
		expect((menu.choose(find(opts, "Feed...")) :: any).menu).toBe("feed")
		expect((menu.choose(find(opts, "Play...")) :: any).menu).toBe("play")
		expect((menu.choose(find(opts, "Appearance...")) :: any).menu).toBe("appearance")
		expect((menu.choose(find(opts, "Pane switch...")) :: any).menu).toBe("transition")
		expect((menu.choose(find(opts, "Overlay corner...")) :: any).menu).toBe("corner")
		expect(menu.choose(find(opts, "Open cat"))).toEqual({ kind = "open", settings = false })
		expect(menu.choose(find(opts, "Cat settings"))).toEqual({ kind = "open", settings = true })
		local wake = menu.options("top", state({ snoozed = true }))
		expect(validated(menu.choose(find(wake, "Wake")) :: menu.Action).kind).toBe("unsnooze")
	end)
end)

describe("window/menu submenus", function()
	it("feeds and plays with every food and toy", function()
		local feed = menu.options("feed", state())
		expect(labels(feed)).toEqual({ "Treat", "Kibble", "Fish" })
		expect(validated(menu.choose(find(feed, "Fish")) :: menu.Action).args).toEqual({ item = "fish" })
		local play = menu.options("play", state())
		expect(labels(play)).toEqual({ "Ball", "String", "Feather" })
		expect(validated(menu.choose(find(play, "Feather")) :: menu.Action).args).toEqual({ toy = "feather" })
	end)

	it("lists every pane switch style with the current one checked", function()
		local opts = menu.options("transition", state({ pane_transition = "box" }))
		expect(labels(opts)).toEqual({
			"Swirly portal",
			"Floor vent",
			"Cardboard box",
			"Walk over",
			"Walk to neighbors",
			"Off",
		})
		expect(currents(opts)).toEqual({ "Cardboard box" })
		local action = menu.choose(find(opts, "Walk over")) :: any
		expect(validated(action).args).toEqual({ values = { ["rendering.pane_transition"] = "walk" } })
		expect(action.done).toBe("Pane switch: Walk over")
	end)

	it("lists the four overlay corners with the current one checked", function()
		local opts = menu.options("corner", state({ overlay_position = "bottom-right" }))
		expect(labels(opts)).toEqual({ "Top right", "Top left", "Bottom right", "Bottom left" })
		expect(currents(opts)).toEqual({ "Bottom right" })
		local action = menu.choose(find(opts, "Top left")) :: menu.Action
		expect(validated(action).args).toEqual({ values = { ["rendering.overlay_position"] = "top-left" } })
	end)

	it("lists the valid packs with the shown one checked and its author or source", function()
		local opts = menu.options("appearance", state({ appearance = "void" }))
		expect(labels(opts)).toEqual({ "Orange Menace", "Void" })
		expect(currents(opts)).toEqual({ "Void" })
		expect(find(opts, "Orange Menace").detail).toBe("Ahmad Raaiyan")
		local action = menu.choose(find(opts, "Orange Menace")) :: any
		expect(validated(action).args).toEqual({ values = { ["cat.appearance"] = "orange-menace" } })
		expect(action.done).toBe("Appearance: Orange Menace")
	end)

	it("offers to reopen Appearance while pack folders are still being validated", function()
		local opts = menu.options("appearance", state({ packs_pending = true }))
		local last = opts.items[#opts.items]
		expect(last.label).toBe("More packs are loading...")
		expect(last.current).toBeNil()
		expect(menu.choose(last)).toEqual({ kind = "menu", menu = "appearance" })
	end)
end)

describe("window/menu choose", function()
	it("does nothing for a dismissed picker or a foreign item", function()
		expect(menu.choose(nil)).toBeNil()
		expect(menu.choose({ label = "Pet" })).toBeNil()
		expect(menu.choose({ label = "x", act = "reset_identity" })).toBeNil()
		expect(menu.choose({ label = "x", act = "menu", arg = "top" })).toBeNil()
		expect(menu.choose({ label = "x", act = "feed" })).toBeNil()
		expect(menu.choose({ label = "x", act = "corner", arg = 3 })).toBeNil()
	end)

	it("leaves argument checks to intent validation", function()
		local action = menu.choose({ label = "x", act = "feed", arg = "rm -rf /" }) :: any
		local intent, err = commands.validate({
			intent_id = "w-1",
			at = 1,
			kind = action.intent,
			source = "window",
			args = action.args,
		})
		expect(intent).toBeNil()
		expect(err).toContain("item must be one of")
	end)
end)

describe("window/menu packChoices", function()
	local function pack(id: string, name: string, source: string, author: string?): any
		return { id = id, name = name, source = source, author = author }
	end

	it("sorts by name and describes each pack by author, else its source", function()
		local out = menu.packChoices({
			pack("void", "Void", "bundled", nil),
			pack("mine", "aardvark", "user", nil),
			pack("orange-menace", "Orange Menace", "bundled", "Ahmad Raaiyan"),
		})
		expect(out).toEqual({
			{ id = "mine", name = "aardvark", detail = "user pack" },
			{ id = "orange-menace", name = "Orange Menace", detail = "Ahmad Raaiyan" },
			{ id = "void", name = "Void", detail = "bundled" },
		})
	end)
end)

describe("window/menu canPick", function()
	it("detects Tern's inline picker and treats a missing or raising field as absent", function()
		local cx = {}
		function cx.pick(_self: any, _opts: any): any
			return nil
		end
		expect(menu.canPick(cx)).toBe(true)
		expect(menu.canPick({})).toBe(false)
		expect(menu.canPick({ pick = "yes" })).toBe(false)
		local strict = setmetatable({}, {
			__index = function(_t: any, key: string): any
				error(`no field {key}`)
			end,
		})
		expect(menu.canPick(strict)).toBe(false)
	end)
end)

describe("window/menu icons", function()
	it("shows the corner the cat rests in", function()
		local opts = menu.options("top", state({ overlay_position = "bottom-left" }))
		expect(find(opts, "Overlay corner...").icon).toBe("pip-bl")
		local corners = menu.options("corner", state())
		local icons = {}
		for _, item in corners.items do
			table.insert(icons, item.icon)
		end
		expect(icons).toEqual({ "pip-tr", "pip-tl", "pip", "pip-bl" })
	end)

	it("switches the snooze and overlay icons with their labels", function()
		local opts = menu.options("top", state({ snoozed = true, overlay_visible = false }))
		expect(find(opts, "Wake").icon).toBe("sun")
		expect(find(opts, "Show overlay").icon).toBe("eye")
	end)
end)
