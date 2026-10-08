--!strict
local t = require("../../lib/test")
local overlay = require("../../../cat/render/overlay")

local describe, it, expect = t.describe, t.it, t.expect

local SELECTOR = "section.tn-pane.on > .tn-body::after"

local function params(overrides: { [string]: any }?): overlay.Params
	local p: { [string]: any } = {
		sheet_url = "data:image/png;base64,iVBORw0KGgo=",
		frame_w = 32,
		frame_h = 32,
		durations_ms = { 100, 100 },
		loop = true,
		scale = 2,
		facing = "right",
		pace = false,
		hidden = false,
		anim_key = "idle-1",
	}
	for k, v in overrides or {} do
		p[k] = v
	end
	return p :: any
end

local function count(haystack: string, needle: string): number
	local n = 0
	local start = 1
	while true do
		local i = string.find(haystack, needle, start, true)
		if not i then
			return n
		end
		n += 1
		start = i + 1
	end
end

local function balanced(css: string): boolean
	local depth = 0
	for c in string.gmatch(css, "[{}]") do
		depth += if c == "{" then 1 else -1
		if depth < 0 then
			return false
		end
	end
	return depth == 0
end

describe("render/overlay.css", function()
	describe("decoration that never interferes with the terminal", function()
		it("anchors to the focused pane and lets every click through", function()
			local css = overlay.css(params())
			expect(css).toContain(SELECTOR)
			expect(css).toContain("pointer-events: none")
			expect(css).toContain("position: absolute")
			expect(css).toContain("right: 12px")
			expect(css).toContain("bottom: 12px")
			expect(css).toContain("image-rendering: pixelated")
			expect(balanced(css)).toBe(true)
		end)

		it("scales the frame box and the sheet together", function()
			local css = overlay.css(params({ durations_ms = { 100, 100, 100 } }))
			expect(css).toContain("width: 64px")
			expect(css).toContain("height: 64px")
			expect(css).toContain("background-size: 192px 64px")
		end)

		it("honours custom offsets and z-index", function()
			local css = overlay.css(params({ offset_px = { right = 40, bottom = 5 }, z = 77 }))
			expect(css).toContain("right: 40px")
			expect(css).toContain("bottom: 5px")
			expect(css).toContain("z-index: 77")
		end)
	end)

	describe("frame animation", function()
		it("places keyframe stops at cumulative times so non-uniform durations are honoured", function()
			local css = overlay.css(params({ durations_ms = { 100, 300, 100 } }))
			expect(css).toContain("@keyframes tern-cat-idle-1")
			expect(css).toContain("0% { background-position: 0px 0px; }")
			expect(css).toContain("20% { background-position: -64px 0px; }")
			expect(css).toContain("80% { background-position: -128px 0px; }")
			expect(css).toContain("100% { background-position: -128px 0px; }")
			expect(css).toContain("tern-cat-idle-1 500ms step-end infinite")
		end)

		it("plays once and holds the last frame when the animation does not loop", function()
			local css = overlay.css(params({ loop = false }))
			expect(css).toContain("tern-cat-idle-1 200ms step-end 1 forwards")
			expect(css).notToContain("infinite")
		end)

		it("does not animate a single-frame animation", function()
			local css = overlay.css(params({ durations_ms = { 500 } }))
			expect(css).notToContain("@keyframes")
		end)

		it("mirrors the sprite when facing left", function()
			expect(overlay.css(params({ facing = "left" }))).toContain("transform: scaleX(-1)")
			expect(overlay.css(params({ facing = "right" }))).notToContain("scaleX(-1)")
		end)
	end)

	describe("pacing", function()
		it("adds a quantized walk that turns around at both ends", function()
			local css = overlay.css(params({ pace = true }))
			expect(css).toContain("@keyframes tern-cat-pace-idle-1")
			expect(css).toContain("steps(")
			expect(css).toContain("translateX(-160px) scaleX(-1)")
			expect(css).toContain("translateX(-160px) scaleX(1)")
			expect(css).toContain("tern-cat-pace-idle-1 ")
			expect(balanced(css)).toBe(true)
		end)

		it("never uses a smooth (display-rate) timing function", function()
			local css = overlay.css(params({ pace = true }))
			expect(css).notToContain("ease")
			expect(css).notToContain("linear")
		end)
	end)

	describe("reduced motion", function()
		it("keeps the cat visible on frame 0 without animation", function()
			local css = overlay.css(params({ pace = true }))
			local media = string.match(css, "@media %(prefers%-reduced%-motion: reduce%) (%b{})")
			assert(media, "missing reduced-motion block")
			expect(media).toContain(SELECTOR)
			expect(media).toContain("animation: none !important")
			expect(media).toContain("background-position: 0px 0px")
			expect(media).notToContain("display: none")
		end)
	end)

	describe("hidden", function()
		it("renders nothing", function()
			local css = overlay.css(params({ hidden = true }))
			expect(css).notToContain("{")
			expect(css).notToContain("url(")
		end)
	end)

	describe("sanitization against hostile packs", function()
		local hostileUrls = {
			'x.png") } body { display: none } a { b: url("',
			'data:image/png;base64,AAAA") ; }',
			"data:text/html;base64,AAAA",
			"javascript:alert(1).png",
			"https://evil.invalid/sheet.png",
			"../../sheet.png",
			"/etc/sheet.png",
			"sheet.png\n}",
			"",
		}
		for _, url in hostileUrls do
			it(`refuses sheet_url {string.format("%q", url)}`, function()
				local css = overlay.css(params({ sheet_url = url }))
				expect(css).notToContain("url(")
				expect(css).notToContain("display: none")
				expect(css).notToContain("evil")
				expect(balanced(css)).toBe(true)
			end)
		end

		it("accepts a safe plugin-relative sheet path", function()
			expect(overlay.css(params({ sheet_url = "assets/packs/void/idle_sheet.png" }))).toContain(
				'url("assets/packs/void/idle_sheet.png")'
			)
		end)

		it("strips everything but [a-z0-9-] from the keyframe name", function()
			local css = overlay.css(params({ anim_key = "Idle} body{display:none} @keyframes x{" }))
			expect(css).notToContain("display:none")
			expect(css).notToContain("body{")
			expect(css).toContain("@keyframes tern-cat-idlebodydisplaynonekeyframesx ")
			expect(balanced(css)).toBe(true)
		end)

		it("falls back to a fixed keyframe name when nothing survives sanitizing", function()
			expect(overlay.css(params({ anim_key = "}}}" }))).toContain("@keyframes tern-cat-anim ")
		end)

		it("clamps non-finite and absurd numbers", function()
			local css = overlay.css(params({
				frame_w = 0 / 0,
				frame_h = math.huge,
				scale = -5,
				z = "1; color: red" :: any,
				durations_ms = { -1, 1e12, 0 / 0 },
				offset_px = { right = -1e9, bottom = "2px; x" :: any },
			}))
			expect(css).notToContain("nan")
			expect(css).notToContain("infpx")
			expect(css).notToContain("infms")
			expect(css).notToContain("color: red")
			expect(css).notToContain("-1000000000")
			expect(balanced(css)).toBe(true)
		end)

		it("emits only one rule set per selector it owns", function()
			local css = overlay.css(params({ pace = true }))
			expect(count(css, SELECTOR)).toBe(2)
		end)
	end)
end)

describe("render/overlay.dataUrl", function()
	it("wraps encoder output as a PNG data URL that css accepts", function()
		local url = overlay.dataUrl("\137PNG", function(_bytes: string): string
			return "iVBO\nRw==\n"
		end)
		expect(url).toBe("data:image/png;base64,iVBORw==")
		expect(overlay.css(params({ sheet_url = url }))).toContain(url)
	end)
end)
