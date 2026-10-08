--!strict
local t = require("../../lib/test")
local blocks = require("../../../cat/window/blocks")

local describe, it, expect = t.describe, t.it, t.expect

local function fakeUi(opts: {
	existing: number?,
	focused: number?,
	newPane: number?,
	floatOk: boolean?,
	floatRaises: boolean?,
	newRaises: boolean?,
}?)
	local o = opts or {}
	local calls: { string } = {}
	local ui: blocks.Ui = {
		focused = function(): number?
			if o.focused == -1 then
				return nil
			end
			return o.focused or 1
		end,
		catBlocks = function(): { number }
			return if o.existing then { o.existing } else {}
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
		focus = function(pane: number)
			table.insert(calls, `focus:{pane}`)
		end,
		send = function(pane: number, payload: { [string]: any })
			table.insert(calls, `send:{pane}:{payload.ev}:{payload.id}:{payload.act}`)
		end,
	}
	return ui, calls
end

describe("window/blocks.open", function()
	it("opens beside the focused pane and floats it into the bottom-right corner", function()
		local ui, calls = fakeUi()
		local r = blocks.open(ui, "float", false)
		expect(r.pane).toBe(7)
		expect(r.placement).toBe("float")
		expect(calls).toEqual({ "new:", "float:7:1" })
	end)

	it("keeps the split when floating fails or raises", function()
		local ui, calls = fakeUi({ floatOk = false })
		local r = blocks.open(ui, "float", false)
		expect(r.placement).toBe("split")
		expect(r.pane).toBe(7)
		expect(r.note).toContain("cannot float")
		expect(calls).toEqual({ "new:", "float:7:1" })
		local ui2 = fakeUi({ floatRaises = true })
		expect(blocks.open(ui2, "float", false).placement).toBe("split")
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

	it("focuses an existing cat block instead of opening another", function()
		local ui, calls = fakeUi({ existing = 9 })
		local r = blocks.open(ui, "float", false)
		expect(r.placement).toBe("existing")
		expect(r.pane).toBe(9)
		expect(calls).toEqual({ "focus:9" })
	end)

	it("switches an existing block to its settings page", function()
		local ui, calls = fakeUi({ existing = 9 })
		blocks.open(ui, "float", true)
		expect(calls).toEqual({ "focus:9", "send:9:action:settings:settings" })
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
