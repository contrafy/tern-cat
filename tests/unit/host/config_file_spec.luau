--!strict
local t = require("../../lib/test")
local support = require("./support")
local configFile = require("../../../cat/adapters/config")

local describe, it, expect = t.describe, t.it, t.expect

local TEMPLATE =
	'{\n  "schema_version": 1,\n  "cat": {\n    "name": "x",\n    "appearance": "y"\n  },\n  "sound": {}\n}'

describe("config file", function()
	it("resolves a missing file to defaults without an error", function()
		local loaded = configFile.parse(nil, support.json())
		expect(loaded.error).toBeNil()
		expect(loaded.config.cat.appearance).toBe("orange-menace")
		expect(loaded.raw).toEqual({})
	end)

	it("reports invalid JSON and uses defaults", function()
		local loaded = configFile.parse("{ nope", support.json())
		expect(loaded.error).notToBeNil()
		expect(loaded.config.rendering.overlay).toBe(true)
	end)

	it("reports a non-object document", function()
		local loaded = configFile.parse("[1]", support.json())
		expect(loaded.error).notToBeNil()
	end)

	it("keeps the user's raw table next to the resolved config", function()
		local loaded = configFile.parse('{"cat":{"name":"Biscuit"},"mine":1}', support.json())
		expect(loaded.raw.mine).toBe(1)
		expect(loaded.config.cat.name).toBe("Biscuit")
		expect(#loaded.warnings).toBe(1)
	end)

	it("applies dotted changes and removals without touching other keys", function()
		local raw = { cat = { name = "Biscuit" }, sound = { volume = 0.9, enabled = true } }
		local out = configFile.applyChanges(raw, {
			["sound.volume"] = configFile.REMOVE,
			["rendering.overlay"] = false,
		})
		expect(out).toEqual({ cat = { name = "Biscuit" }, sound = { enabled = true }, rendering = { overlay = false } })
		expect(raw.sound.volume).toBe(0.9)
	end)

	it("pretty-prints in template key order, unknown keys last and sorted", function()
		local text = configFile.encode({
			zeta = true,
			cat = { appearance = "void", name = "N", extra = { 1, 2 } },
			schema_version = 1,
			alpha = "a",
		}, support.json(), TEMPLATE)
		expect(text).toBe(
			'{\n  "schema_version": 1,\n  "cat": {\n    "name": "N",\n    "appearance": "void",\n'
				.. '    "extra": [\n      1,\n      2\n    ]\n  },\n  "alpha": "a",\n  "zeta": true\n}\n'
		)
		expect(support.json().decode(text).cat.extra[2]).toBe(2)
	end)

	it("escapes strings through the JSON encoder", function()
		local text = configFile.encode({ cat = { name = 'a"b\n' } }, support.json(), nil)
		expect(support.json().decode(text).cat.name).toBe('a"b\n')
	end)

	it("creates the file from the example only when missing", function()
		local m = support.memFs()
		m.dirs["/d"] = true
		expect((configFile.ensure(m.fs, "/d/config.json", "{}\n"))).toBe(true)
		m.files["/d/config.json"] = "mine"
		expect((configFile.ensure(m.fs, "/d/config.json", "{}\n"))).toBe(false)
		expect(m.files["/d/config.json"]).toBe("mine")
	end)
end)
