--!strict
local t = require("../../lib/test")
local catalog = require("../../../cat/sprite/catalog")

local describe, it, expect = t.describe, t.it, t.expect

local ROOTS = {
	{ dir = "/plugin/assets/packs", source = "bundled" :: "bundled" },
	{ dir = "/data/packs", source = "user" :: "user" },
}

local function pack(id: string, name: string, author: string?): any
	return {
		manifest = { id = id, name = name, author = author },
		root = "/x/" .. id,
		source = "bundled",
		warnings = {},
	}
end

local function entry(overrides: { [string]: any }): any
	local e: { [string]: any } = { folder = "calico", source = "user", valid = true, id = "calico", name = "Calico" }
	for k, v in overrides do
		e[k] = v
	end
	return e
end

local function raw(packs: { any }): any
	return { schema_version = 1, rev = 3, complete = true, packs = packs }
end

describe("sprite/catalog.build", function()
	it("lists folders in loader order with the first valid folder of an id winning", function()
		local void = pack("void", "Void", "A")
		local entries, winners = catalog.build({
			{ source = "user", folder = "z-copy", pack = pack("void", "Void copy") },
			{ source = "user", folder = "broken", problem = "pack.json is not valid JSON" },
			{ source = "user", folder = "empty" },
			{ source = "bundled", folder = "void", pack = void },
		})
		expect(entries).toEqual({
			{ folder = "void", source = "bundled", valid = true, id = "void", name = "Void", author = "A" },
			{ folder = "broken", source = "user", valid = false, problem = "pack.json is not valid JSON" },
			{
				folder = "z-copy",
				source = "user",
				valid = false,
				id = "void",
				name = "Void copy",
				problem = 'id "void" is already provided by the bundled pack in folder "void"',
			},
		})
		expect(winners.void).toBe(void)
	end)

	it("clips long problems", function()
		local entries = catalog.build({ { source = "user", folder = "x", problem = string.rep("e", 500) } })
		expect(#(entries[1].problem :: string)).toBe(200)
	end)

	it("compares entry lists field by field", function()
		local a = catalog.build({ { source = "bundled", folder = "void", pack = pack("void", "Void") } })
		local b = catalog.build({ { source = "bundled", folder = "void", pack = pack("void", "Void") } })
		local c = catalog.build({ { source = "bundled", folder = "void", pack = pack("void", "Void 2") } })
		expect(catalog.equal(a, b)).toBe(true)
		expect(catalog.equal(a, c)).toBe(false)
		expect(catalog.equal(a, {})).toBe(false)
	end)
end)

describe("sprite/catalog.decode", function()
	it("keeps well-formed valid entries and joins folders to this side's roots", function()
		local c = catalog.decode(
			raw({ entry({}), entry({ folder = "void", source = "bundled", id = "void", name = "Void" }) }),
			ROOTS
		)
		assert(c, "catalog")
		expect(c.rev).toBe(3)
		expect(c.complete).toBe(true)
		expect(#c.packs).toBe(2)
		expect(catalog.dirOf(c.packs[1], ROOTS)).toBe("/data/packs/calico")
		expect(catalog.dirOf(c.packs[2], ROOTS)).toBe("/plugin/assets/packs/void")
	end)

	it("drops entries that could point outside the pack roots or are malformed", function()
		local c = catalog.decode(
			raw({
				entry({ folder = ".." }),
				entry({ folder = "../inbox" }),
				entry({ folder = "a/b" }),
				entry({ folder = "/etc" }),
				entry({ folder = ".hidden" }),
				entry({ folder = 5 }),
				entry({ source = "system" }),
				entry({ id = "../x" }),
				entry({ id = "Calico" }),
				entry({ name = "" }),
				entry({ name = string.rep("n", 65) }),
				entry({ author = 3 }),
				entry({ valid = false }),
				"not an entry",
			}),
			ROOTS
		)
		assert(c, "catalog")
		expect(#c.packs).toBe(0)
	end)

	it("is absent for another schema, a bad rev or no list", function()
		expect(catalog.decode(nil, ROOTS)).toBeNil()
		expect(catalog.decode({ schema_version = 2, rev = 1, packs = {} }, ROOTS)).toBeNil()
		expect(catalog.decode({ schema_version = 1, rev = "1", packs = {} }, ROOTS)).toBeNil()
		expect(catalog.decode({ schema_version = 1, rev = 0 / 0, packs = {} }, ROOTS)).toBeNil()
		expect(catalog.decode({ schema_version = 1, rev = 1 }, ROOTS)).toBeNil()
	end)

	it("treats a missing complete flag as incomplete and round-trips encode", function()
		local c = catalog.decode({ schema_version = 1, rev = 1, packs = {} }, ROOTS)
		expect((c :: any).complete).toBe(false)
		local again = catalog.decode(catalog.encode(4, { entry({}) }, true), ROOTS)
		expect((again :: any).rev).toBe(4)
		expect((again :: any).packs[1].id).toBe("calico")
	end)
end)
