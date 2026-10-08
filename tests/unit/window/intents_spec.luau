--!strict
local t = require("../../lib/test")
local rng = require("../../../cat/core/rng")
local commands = require("../../../cat/core/commands")
local intents = require("../../../cat/window/intents")

local describe, it, expect = t.describe, t.it, t.expect

local NAME_PATTERN = "^%d+%-%x%x%x%x%x%x%x%x%.json$"

local function fakeFs()
	local files: { [string]: string } = {}
	local dirs: { [string]: boolean } = {}
	local fail = false
	return {
		files = files,
		dirs = dirs,
		setFail = function(v: boolean)
			fail = v
		end,
		write = function(path: string, text: string): (boolean, string?)
			if fail then
				return false, "disk full"
			end
			files[path] = text
			return true, nil
		end,
		mkdir = function(path: string): boolean
			dirs[path] = true
			return true
		end,
	}
end

local function fakeJson()
	return {
		encode = function(value: any, _pretty: boolean?): string?
			return "JSON:" .. tostring(value.kind) .. ":" .. tostring(value.intent_id)
		end,
	}
end

describe("window/intents.build", function()
	it("builds a validated intent with a fresh id and the given source", function()
		local r = rng.new(7)
		local intent, err = intents.build(r, 1000, "pet", nil, "window")
		expect(err).toBeNil()
		assert(intent, "intent")
		expect(intent.kind).toBe("pet")
		expect(intent.source).toBe("window")
		expect(intent.at).toBe(1000)
		expect(intent.args).toEqual({})
		expect(string.match(intent.intent_id, "^w%-%x+$") ~= nil).toBe(true)
		local again = commands.validate(intent)
		expect(again).toEqual(intent)
	end)

	it("never reuses an id", function()
		local r = rng.new(1)
		local a = intents.build(r, 1, "poke", {}, "keyboard")
		local b = intents.build(r, 1, "poke", {}, "keyboard")
		assert(a and b, "intents")
		expect(a.intent_id == b.intent_id).toBe(false)
	end)

	it("normalizes arguments through commands.validate", function()
		local intent = intents.build(rng.new(2), 5, "feed", {}, "carly")
		assert(intent, "intent")
		expect(intent.args).toEqual({ item = "kibble" })
	end)

	it("rejects invalid arguments with a readable reason", function()
		local intent, err = intents.build(rng.new(3), 5, "feed", { item = "rm -rf /" }, "carly")
		expect(intent).toBeNil()
		expect(err).toContain("item must be one of")
	end)

	it("rejects unknown kinds and sources", function()
		local a, errA = intents.build(rng.new(3), 5, "eat_homework" :: any, {}, "carly")
		expect(a).toBeNil()
		expect(errA).toContain("unknown kind")
		local b, errB = intents.build(rng.new(3), 5, "pet", {}, "network" :: any)
		expect(b).toBeNil()
		expect(errB).toContain("unknown source")
	end)
end)

describe("window/intents.fileName", function()
	it("matches the host inbox pattern <at_ms>-<8 hex>.json", function()
		local r = rng.new(9)
		for _, at_ms in { 0, 1, 1767225600123, 1767225600123.7 } do
			local name = intents.fileName(at_ms, r)
			expect(string.match(name, NAME_PATTERN) ~= nil).toBe(true)
		end
	end)

	it("sorts by time for the host's name-order processing", function()
		local r = rng.new(4)
		local a = intents.fileName(1767225600123, r)
		local b = intents.fileName(1767225600124, r)
		expect(a < b).toBe(true)
	end)
end)

describe("window/intents.write", function()
	it("writes one JSON file per intent into the inbox", function()
		local fs = fakeFs()
		local intent = intents.build(rng.new(5), 10, "pet", {}, "window")
		assert(intent, "intent")
		local path, err = intents.write(fs, fakeJson(), "/data/inbox", intent, 10000, rng.new(6))
		expect(err).toBeNil()
		assert(path, "path")
		expect(string.sub(path, 1, #"/data/inbox/")).toBe("/data/inbox/")
		expect(string.match(string.sub(path, #"/data/inbox/" + 1), NAME_PATTERN) ~= nil).toBe(true)
		expect(fs.files[path]).toBe("JSON:pet:" .. intent.intent_id)
	end)

	it("reports write failures instead of raising", function()
		local fs = fakeFs()
		fs.setFail(true)
		local intent = intents.build(rng.new(5), 10, "pet", {}, "window")
		assert(intent, "intent")
		local path, err = intents.write(fs, fakeJson(), "/data/inbox", intent, 10000, rng.new(6))
		expect(path).toBeNil()
		expect(err).toContain("disk full")
	end)

	it("reports encode failures", function()
		local fs = fakeFs()
		local intent = intents.build(rng.new(5), 10, "pet", {}, "window")
		assert(intent, "intent")
		local json = {
			encode = function(_: any, _p: boolean?): string?
				return nil
			end,
		}
		local path, err = intents.write(fs, json, "/data/inbox", intent, 10000, rng.new(6))
		expect(path).toBeNil()
		expect(err).toContain("encode")
	end)
end)
