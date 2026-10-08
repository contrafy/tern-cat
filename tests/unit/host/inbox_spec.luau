--!strict
local t = require("../../lib/test")
local support = require("./support")
local inbox = require("../../../cat/host/inbox")

local describe, it, expect = t.describe, t.it, t.expect

local DIR = "/data/inbox"
local GOOD = '{"intent_id":"w-1","at":1,"kind":"pet","source":"window","args":{}}'

describe("inbox", function()
	it("returns nothing when the inbox does not exist", function()
		local m = support.memFs()
		local r = inbox.poll(inbox.newState(), m.fs, support.json(), DIR, 0)
		expect(#r.items).toBe(0)
		expect(#r.discarded).toBe(0)
	end)

	it("returns decoded intents in name order and deletes their files", function()
		local m = support.memFs({
			[DIR .. "/200-0000000b.json"] = GOOD,
			[DIR .. "/100-0000000a.json"] = '{"kind":"poke"}',
		})
		local r = inbox.poll(inbox.newState(), m.fs, support.json(), DIR, 0)
		expect(#r.items).toBe(2)
		expect(r.items[1].name).toBe("100-0000000a.json")
		expect(r.items[1].intent.kind).toBe("poke")
		expect(r.items[2].intent.intent_id).toBe("w-1")
		expect(m.files[DIR .. "/100-0000000a.json"]).toBeNil()
		expect(m.files[DIR .. "/200-0000000b.json"]).toBeNil()
	end)

	it("retries undecodable files during the grace period, then discards them", function()
		local path = DIR .. "/100-0000000a.json"
		local m = support.memFs({ [path] = '{"kind":' })
		local state = inbox.newState()
		local json = support.json()
		local r1 = inbox.poll(state, m.fs, json, DIR, 1000)
		expect(#r1.items).toBe(0)
		expect(#r1.discarded).toBe(0)
		expect(m.files[path]).notToBeNil()
		local r2 = inbox.poll(state, m.fs, json, DIR, 1000 + inbox.GRACE_MS - 1)
		expect(#r2.discarded).toBe(0)
		local r3 = inbox.poll(state, m.fs, json, DIR, 1000 + inbox.GRACE_MS)
		expect(#r3.discarded).toBe(1)
		expect(r3.discarded[1].name).toBe("100-0000000a.json")
		expect(m.files[path]).toBeNil()
		expect(state.first_seen["100-0000000a.json"]).toBeNil()
	end)

	it("picks up a file that becomes valid within the grace period", function()
		local path = DIR .. "/100-0000000a.json"
		local m = support.memFs({ [path] = "" })
		local state = inbox.newState()
		inbox.poll(state, m.fs, support.json(), DIR, 0)
		m.files[path] = GOOD
		local r = inbox.poll(state, m.fs, support.json(), DIR, 100)
		expect(#r.items).toBe(1)
		expect(state.first_seen["100-0000000a.json"]).toBeNil()
	end)

	it("treats JSON that is not an object as undecodable", function()
		local m = support.memFs({ [DIR .. "/1-00000001.json"] = "[1,2]" })
		local state = inbox.newState()
		inbox.poll(state, m.fs, support.json(), DIR, 0)
		local r = inbox.poll(state, m.fs, support.json(), DIR, inbox.GRACE_MS)
		expect(#r.items).toBe(0)
		expect(#r.discarded).toBe(1)
	end)

	it("never deletes entries with foreign names: they may be the user's or another tool's files", function()
		local m = support.memFs({
			[DIR .. "/notes.txt"] = GOOD,
			[DIR .. "/.1-00000001.json.tmp"] = GOOD,
			[DIR .. "/backup/keep.json"] = GOOD,
		})
		local state = inbox.newState()
		local r1 = inbox.poll(state, m.fs, support.json(), DIR, 0)
		expect(#r1.items).toBe(0)
		expect(#r1.ignored).toBe(3)
		local r2 = inbox.poll(state, m.fs, support.json(), DIR, inbox.GRACE_MS * 2)
		expect(#r2.discarded).toBe(0)
		expect(#r2.ignored).toBe(0)
		expect(m.files[DIR .. "/notes.txt"]).toBe(GOOD)
		expect(m.files[DIR .. "/.1-00000001.json.tmp"]).toBe(GOOD)
		expect(m.files[DIR .. "/backup/keep.json"]).toBe(GOOD)
	end)

	it("never deletes an intent-named directory, which tern.fs.remove would wipe recursively", function()
		local m = support.memFs({ [DIR .. "/1-00000001.json/inner.txt"] = "user data" })
		local state = inbox.newState()
		inbox.poll(state, m.fs, support.json(), DIR, 0)
		local r = inbox.poll(state, m.fs, support.json(), DIR, inbox.GRACE_MS)
		expect(#r.discarded).toBe(0)
		expect(#r.ignored).toBe(1)
		expect(m.files[DIR .. "/1-00000001.json/inner.txt"]).toBe("user data")
		expect(#inbox.poll(state, m.fs, support.json(), DIR, inbox.GRACE_MS * 3).ignored).toBe(0)
	end)

	it("leaves intent files it cannot read in place (oversize files tern.fs refuses)", function()
		local big = '{"pad":"' .. string.rep("x", inbox.MAX_BYTES * 2) .. '"}'
		local m = support.memFs({ [DIR .. "/1-00000001.json"] = big })
		local state = inbox.newState()
		expect(#inbox.poll(state, m.fs, support.json(), DIR, 0).items).toBe(0)
		local r = inbox.poll(state, m.fs, support.json(), DIR, inbox.GRACE_MS)
		expect(#r.discarded).toBe(0)
		expect(m.files[DIR .. "/1-00000001.json"]).toBe(big)
	end)

	it("discards a readable intent file just over the size limit", function()
		local big = '{"pad":"' .. string.rep("x", inbox.MAX_BYTES - 9) .. '"}'
		local m = support.memFs({ [DIR .. "/1-00000001.json"] = big })
		local r = inbox.poll(inbox.newState(), m.fs, support.json(), DIR, 0)
		expect(#r.discarded).toBe(1)
		expect(m.files[DIR .. "/1-00000001.json"]).toBeNil()
	end)

	it("bounds the work done per poll", function()
		local files: { [string]: string } = {}
		for i = 1, inbox.MAX_PER_POLL + 5 do
			files[string.format("%s/%d-%08x.json", DIR, 1000 + i, i)] = GOOD
		end
		local m = support.memFs(files)
		local state = inbox.newState()
		local r1 = inbox.poll(state, m.fs, support.json(), DIR, 0)
		expect(#r1.items).toBe(inbox.MAX_PER_POLL)
		local r2 = inbox.poll(state, m.fs, support.json(), DIR, 0)
		expect(#r2.items).toBe(5)
	end)

	it("forgets files that vanished before their grace ended", function()
		local path = DIR .. "/1-00000001.json"
		local m = support.memFs({ [path] = "{", [DIR .. "/2-00000002.json"] = GOOD })
		local state = inbox.newState()
		inbox.poll(state, m.fs, support.json(), DIR, 0)
		m.files[path] = nil
		inbox.poll(state, m.fs, support.json(), DIR, 10)
		expect(state.first_seen["1-00000001.json"]).toBeNil()
	end)
end)
