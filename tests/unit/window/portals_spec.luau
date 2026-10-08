--!strict
local serde = require("@lune/serde")
local t = require("../../lib/test")
local support = require("../sprite/support")
local overlay = require("../../../cat/render/overlay")
local portals = require("../../../cat/window/portals")

local describe, it, expect = t.describe, t.it, t.expect

local DIR = "/plugin/assets/portals"

local function decode(text: string): any
	return serde.decode("json", text)
end

local function base64(bytes: string): string
	return "B64" .. tostring(#bytes)
end

local function layer(sheet: string, durations: { number }): { [string]: any }
	return { sheet = sheet, frames = #durations, durations_ms = durations }
end

local function catalog(): { [string]: any }
	return {
		schema_version = 1,
		frame = { width = 48, height = 24 },
		anchor = { 24, 12 },
		styles = {
			portal = {
				name = "Swirly portal",
				enter = { back = layer("portal/enter-back.sheet.png", { 400, 400 }) },
				exit = { back = layer("portal/exit-back.sheet.png", { 320, 320 }) },
			},
			box = {
				name = "Cardboard box",
				enter = {
					back = layer("box/enter-back.sheet.png", { 800 }),
					front = layer("box/enter-front.sheet.png", { 800 }),
				},
				exit = {
					back = layer("box/exit-back.sheet.png", { 640 }),
					front = layer("box/exit-front.sheet.png", { 640 }),
				},
			},
		},
	}
end

local function files(raw: { [string]: any }?): { [string]: string }
	local out: { [string]: string } = {
		[DIR .. "/portals.json"] = serde.encode("json", raw or catalog()),
		[DIR .. "/portal/enter-back.sheet.png"] = support.makePng({ width = 96, height = 24 }),
		[DIR .. "/portal/exit-back.sheet.png"] = support.makePng({ width = 96, height = 24 }),
	}
	for _, name in { "enter-back", "enter-front", "exit-back", "exit-front" } do
		out[`{DIR}/box/{name}.sheet.png`] = support.makePng({ width = 48, height = 24 })
	end
	return out
end

local function make(f: { [string]: string })
	local fs, log = support.memoryFs(f)
	return portals.new({ fs = fs, decode = decode, base64 = base64, dir = DIR }), log
end

local function readsUnder(log: { string }, prefix: string): number
	local n = 0
	for _, p in log do
		if string.sub(p, 1, #prefix) == prefix then
			n += 1
		end
	end
	return n
end

describe("window/portals", function()
	it("builds a style's prop from portals.json with data URLs and the shared geometry", function()
		local cache = make(files())
		local prop, err = portals.prop(cache, "portal")
		assert(prop, err)
		expect(prop.frame_w).toBe(48)
		expect(prop.frame_h).toBe(24)
		expect(prop.anchor).toEqual({ 24, 12 })
		expect(prop.enter.back.sheet_url).toBe("data:image/png;base64,B64" .. tostring(#support.makePng()))
		expect(prop.enter.back.durations_ms).toEqual({ 400, 400 })
		expect(prop.exit.back.durations_ms).toEqual({ 320, 320 })
		expect(prop.enter.front).toBeNil()
		local box = portals.prop(cache, "box")
		assert(box, "box")
		expect(box.enter.front).notToBeNil()
		expect(box.exit.front).notToBeNil()
	end)

	it("reads only the selected style's sheets, once", function()
		local cache, log = make(files())
		portals.prop(cache, "portal")
		expect(readsUnder(log, DIR .. "/box/")).toBe(0)
		local before = #log
		portals.prop(cache, "portal")
		expect(#log).toBe(before)
	end)

	it("renders the prop into an overlay transition", function()
		local cache = make(files())
		local prop = portals.prop(cache, "box")
		local css = overlay.css({
			sheet_url = "data:image/png;base64,iVBORw0KGgo=",
			frame_w = 32,
			frame_h = 32,
			durations_ms = { 100, 100 },
			loop = true,
			scale = 2,
			facing = "right",
			pace = false,
			hidden = false,
			anim_key = "idle",
			transition = { prop = prop :: any },
		})
		expect(css).toContain("div.tv-grid > div.tv-fx::after")
		expect(css).toContain("div.tv-layer::after")
	end)

	it("reports a missing or broken portals.json", function()
		local f = files()
		f[DIR .. "/portals.json"] = nil
		local prop, err = portals.prop((make(f)), "portal")
		expect(prop).toBeNil()
		expect(err).toContain("not found")
		f[DIR .. "/portals.json"] = "{ nope"
		prop, err = portals.prop((make(f)), "portal")
		expect(prop).toBeNil()
		expect(err).toContain("not valid JSON")
	end)

	it("reads portals.json once even when it is broken", function()
		local f = files()
		f[DIR .. "/portals.json"] = nil
		local cache, log = make(f)
		portals.prop(cache, "portal")
		local before = #log
		portals.prop(cache, "vent")
		expect(#log).toBe(before)
	end)

	it("re-reads after invalidate", function()
		local f = files()
		local fs = support.memoryFs(f)
		local cache = portals.new({ fs = fs, decode = decode, base64 = base64, dir = DIR })
		f[DIR .. "/portals.json"] = nil
		expect((portals.prop(cache, "portal"))).toBeNil()
		f[DIR .. "/portals.json"] = serde.encode("json", catalog())
		portals.invalidate(cache)
		expect((portals.prop(cache, "portal"))).notToBeNil()
	end)

	it("refuses unknown styles", function()
		local prop, err = portals.prop((make(files())), "vent")
		expect(prop).toBeNil()
		expect(err).toContain('no style "vent"')
	end)

	local function broken(edit: (raw: { [string]: any }) -> ()): string?
		local raw = catalog()
		edit(raw)
		local _, err = portals.prop((make(files(raw))), "portal")
		return err
	end

	it("validates the shared fields", function()
		expect(broken(function(raw)
			raw.schema_version = 2
		end)).toContain("schema_version")
		expect(broken(function(raw)
			raw.frame = { width = 4, height = 24 }
		end)).toContain("frame")
		expect(broken(function(raw)
			raw.anchor = { 60, 12 }
		end)).toContain("anchor")
		expect(broken(function(raw)
			raw.styles.portal.name = ""
		end)).toContain("styles.portal.name")
	end)

	it("applies the sprite packs' path rules to sheets", function()
		for _, bad in { "../../etc/passwd.png", "/abs.png", 'x.png") } body {', "https://evil.invalid/a.png" } do
			local err = broken(function(raw)
				raw.styles.portal.exit.back.sheet = bad
			end)
			expect(err).toContain("styles.portal.exit.back.sheet")
		end
	end)

	it("requires one duration per frame within the pack limits", function()
		expect(broken(function(raw)
			raw.styles.portal.enter.back.frames = 3
		end)).toContain("durations_ms")
		expect(broken(function(raw)
			raw.styles.portal.enter.back.durations_ms = { 400, 5 }
		end)).toContain("durations_ms[2]")
		expect(broken(function(raw)
			raw.styles.portal.enter.front = "flap"
		end)).toContain("styles.portal.enter.front")
	end)

	it("checks every sheet's size and format", function()
		local f = files()
		f[DIR .. "/portal/exit-back.sheet.png"] = support.makePng({ width = 48, height = 24 })
		local prop, err = portals.prop((make(f)), "portal")
		expect(prop).toBeNil()
		expect(err).toContain("expected 96x24")
		f[DIR .. "/portal/exit-back.sheet.png"] = support.makePng({ width = 96, height = 24, frames = 2 })
		prop, err = portals.prop((make(f)), "portal")
		expect(prop).toBeNil()
		expect(err).toContain("still PNG")
		f[DIR .. "/portal/exit-back.sheet.png"] = "GIF89a"
		prop, err = portals.prop((make(f)), "portal")
		expect(prop).toBeNil()
		expect(err).toContain("PNG")
	end)

	it("parses directly for tools", function()
		local parsed = portals.parse(catalog())
		assert(parsed, "parse")
		expect(parsed.styles.portal.enter.back.frames).toBe(2)
		expect((portals.parse("nope"))).toBeNil()
	end)
end)

describe("window/portals with the bundled props", function()
	local fs = require("@lune/fs")
	if not fs.isFile("assets/portals/portals.json") then
		return
	end
	it("loads every bundled style", function()
		local cache = portals.new({ fs = support.luneFs(), decode = decode, base64 = base64, dir = "assets/portals" })
		for _, id in portals.STYLES do
			local prop, err = portals.prop(cache, id)
			assert(prop, err)
			expect(string.sub(prop.enter.back.sheet_url, 1, 22)).toBe("data:image/png;base64,")
		end
	end)
end)
