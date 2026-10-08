--!strict
local t = require("../../lib/test")
local blocks = require("../../../cat/window/blocks")

local describe, it, expect = t.describe, t.it, t.expect

-- The focused pane (default 1) sits in tab 1.
local function fakeUi(opts: {
	cats: { blocks.CatBlock }?,
	focused: number?,
	newPane: number?,
	floatOk: boolean?,
	floatRaises: boolean?,
	newRaises: boolean?,
	unparkOk: boolean?,
}?)
	local o = opts or {}
	local calls: { string } = {}
	local logs: { string } = {}
	local ui: blocks.Ui = {
		focused = function(): number?
			if o.focused == -1 then
				return nil
			end
			return o.focused or 1
		end,
		tabOf = function(pane: number): number?
			for _, b in o.cats or {} do
				if b.pane == pane then
					return b.tab
				end
			end
			return 1
		end,
		catBlocks = function(): { blocks.CatBlock }
			return o.cats or {}
		end,
		newBlock = function(args: { string }): number?
			table.insert(calls, "new:" .. table.concat(args, ","))
			if o.newRaises then
				error("no host")
			end
			if o.newPane == -1 then
				return nil
			end
			return o.newPane or 7
		end,
		float = function(pane: number, owner: number): (boolean, string?)
			table.insert(calls, `float:{pane}:{owner}`)
			if o.floatRaises then
				error("boom")
			end
			if o.floatOk == false then
				return false, "cannot float"
			end
			return true, nil
		end,
		unpark = function(pane: number): (boolean, string?)
			table.insert(calls, `unpark:{pane}`)
			if o.unparkOk == false then
				return false, "cannot unpark"
			end
			return true, nil
		end,
		focus = function(pane: number)
			table.insert(calls, `focus:{pane}`)
		end,
		send = function(pane: number, payload: { [string]: any })
			table.insert(calls, `send:{pane}:{payload.ev}:{payload.id}:{payload.act}`)
		end,
		debug = function(message: string)
			table.insert(logs, message)
		end,
	}
	return ui, calls, logs
end

local function cat(pane: number, tab: number?, how: ("tiled" | "floating" | "parked")?): blocks.CatBlock
	local kind = how or "tiled"
	return {
		pane = pane,
		tab = if kind == "parked" then nil else tab,
		floating = kind == "floating",
		parked = kind == "parked",
	}
end

describe("window/blocks.open", function()
	it("opens beside the focused pane and floats it into the bottom-right corner", function()
		local ui, calls = fakeUi()
		local r = blocks.open(ui, "float", false)
		expect(r.pane).toBe(7)
		expect(r.placement).toBe("float")
		expect(r.note).toBeNil()
		expect(calls).toEqual({ "new:", "float:7:1" })
	end)

	it("keeps the split and notes why when floating fails or raises", function()
		local ui, calls = fakeUi({ floatOk = false })
		local r = blocks.open(ui, "float", false)
		expect(r.placement).toBe("split")
		expect(r.pane).toBe(7)
		expect(r.note).toContain("cannot float")
		expect(calls).toEqual({ "new:", "float:7:1" })
		local r2 = blocks.open(fakeUi({ floatRaises = true }), "float", false)
		expect(r2.placement).toBe("split")
		expect(r2.note).toContain("boom")
	end)

	it("does not float when configured to split or with no focused owner", function()
		local ui, calls = fakeUi()
		expect(blocks.open(ui, "split", false).placement).toBe("split")
		expect(calls).toEqual({ "new:" })
		local ui2, calls2 = fakeUi({ focused = -1 })
		expect(blocks.open(ui2, "float", false).placement).toBe("split")
		expect(calls2).toEqual({ "new:" })
	end)

	it("opens the settings page through block args", function()
		local ui, calls = fakeUi()
		blocks.open(ui, "float", true)
		expect(calls[1]).toBe("new:settings")
	end)

	it("focuses a cat block already in the focused pane's tab, tiled or floating", function()
		local ui, calls = fakeUi({ cats = { cat(9, 1) } })
		local r = blocks.open(ui, "float", false)
		expect(r.placement).toBe("existing")
		expect(r.pane).toBe(9)
		expect(calls).toEqual({ "focus:9" })
		local ui2, calls2 = fakeUi({ cats = { cat(4, 2, "floating"), cat(9, 1, "floating") } })
		expect(blocks.open(ui2, "float", false).pane).toBe(9)
		expect(calls2).toEqual({ "focus:9" })
	end)

	it("focuses the cat block when it is itself focused", function()
		local ui, calls = fakeUi({ focused = 9, cats = { cat(9, 3) } })
		expect(blocks.open(ui, "float", false).placement).toBe("existing")
		expect(calls).toEqual({ "focus:9" })
	end)

	it("switches an existing block in this tab to its settings page", function()
		local ui, calls = fakeUi({ cats = { cat(9, 1) } })
		blocks.open(ui, "float", true)
		expect(calls).toEqual({ "focus:9", "send:9:action:settings:settings" })
	end)

	it("leaves a cat tiled in another tab alone and floats a new one here", function()
		local ui, calls = fakeUi({ cats = { cat(9, 2) } })
		local r = blocks.open(ui, "float", false)
		expect(r.placement).toBe("float")
		expect(r.pane).toBe(7)
		expect(calls).toEqual({ "new:", "float:7:1" })
	end)

	it("moves a cat card floating in another tab, or a parked cat, over the focused pane", function()
		local ui, calls = fakeUi({ cats = { cat(9, 2), cat(8, 3, "floating") } })
		local r = blocks.open(ui, "float", false)
		expect(r.placement).toBe("float")
		expect(r.pane).toBe(8)
		expect(calls).toEqual({ "float:8:1" })
		local ui2, calls2 = fakeUi({ cats = { cat(6, nil, "parked") } })
		expect(blocks.open(ui2, "float", true).pane).toBe(6)
		expect(calls2).toEqual({ "float:6:1", "send:6:action:settings:settings" })
	end)

	it("opens a new block when moving a card here fails", function()
		local ui, calls = fakeUi({ cats = { cat(8, 3, "floating") }, floatOk = false })
		local r = blocks.open(ui, "float", false)
		expect(r.pane).toBe(7)
		expect(r.placement).toBe("split")
		expect(r.note).toContain("cannot float")
		expect(calls).toEqual({ "float:8:1", "new:", "float:7:1" })
	end)

	it("in split mode unparks a parked cat and opens a new one beside a card elsewhere", function()
		local ui, calls = fakeUi({ cats = { cat(6, nil, "parked") } })
		local r = blocks.open(ui, "split", false)
		expect(r.pane).toBe(6)
		expect(r.placement).toBe("split")
		expect(calls).toEqual({ "unpark:6" })
		local ui2, calls2 = fakeUi({ cats = { cat(8, 3, "floating") } })
		expect(blocks.open(ui2, "split", false).pane).toBe(7)
		expect(calls2).toEqual({ "new:" })
		local ui3, calls3 = fakeUi({ cats = { cat(6, nil, "parked") }, unparkOk = false })
		expect(blocks.open(ui3, "split", false).pane).toBe(7)
		expect(calls3).toEqual({ "unpark:6", "new:" })
	end)

	it("logs the decision path", function()
		local ui, _, logs = fakeUi({ cats = { cat(9, 2) } })
		blocks.open(ui, "float", false)
		expect(logs[1]).toContain("placement float")
		expect(logs[1]).toContain("9(tiled, tab 2)")
		expect(logs[#logs]).toContain("floating over pane 1")
	end)

	it("reports failures to open", function()
		local ui = fakeUi({ newRaises = true })
		local r = blocks.open(ui, "float", false)
		expect(r.pane).toBeNil()
		expect(r.error).toContain("no host")
		local ui2 = fakeUi({ newPane = -1 })
		expect(blocks.open(ui2, "float", false).error).notToBeNil()
	end)
end)
