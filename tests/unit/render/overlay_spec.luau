--!strict
local t = require("../../lib/test")
local overlay = require("../../../cat/render/overlay")

local describe, it, expect = t.describe, t.it, t.expect

local HOST = "section.tn-pane.on > div.tn-body > div.tv > div.tv-fx.top"
local SELECTOR = HOST .. "::after"
local LOOK_URL = "data:image/png;base64,TE9PSw=="
local SWAT_URL = "data:image/png;base64,U1dBVA=="

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

local function reactive(overrides: { [string]: any }?): overlay.Params
	local p: { [string]: any } = {
		reactions = {
			hover = { sheet_url = LOOK_URL, durations_ms = { 100, 100, 200 }, loop = false },
			press = { sheet_url = SWAT_URL, durations_ms = { 100, 100, 100, 100 }, loop = false },
		},
	}
	for k, v in overrides or {} do
		p[k] = v
	end
	return params(p)
end

-- The body of the first rule set whose selector list starts with `selector`.
local function block(css: string, selector: string): string?
	local i = string.find(css, selector .. " {", 1, true)
	if not i then
		return nil
	end
	return string.match(css, "%b{}", i)
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
		it("anchors to the focused pane's top effects layer and lets every click through", function()
			local css = overlay.css(params())
			expect(overlay.SELECTOR).toBe(SELECTOR)
			expect(overlay.HOST).toBe(HOST)
			expect(css).toContain(SELECTOR)
			expect(css).toContain("pointer-events: none")
			expect(css).toContain("visibility: visible")
			expect(css).toContain("position: absolute")
			expect(css).toContain("right: 12px")
			expect(css).toContain("top: 12px")
			expect(css).notToContain("bottom:")
			expect(css).toContain("image-rendering: pixelated")
			expect(css).notToContain(":hover")
			expect(css).notToContain(":active")
			expect(css).notToContain("::before")
			expect(css).notToContain("cursor")
			expect(balanced(css)).toBe(true)
		end)

		it("scales the frame box and the sheet together", function()
			local css = overlay.css(params({ durations_ms = { 100, 100, 100 } }))
			expect(css).toContain("width: 64px")
			expect(css).toContain("height: 64px")
			expect(css).toContain("background-size: 192px 64px")
		end)

		it("honours a custom gap and z-index", function()
			local css = overlay.css(params({ offset_px = 40, z = 77 }))
			expect(css).toContain("right: 40px")
			expect(css).toContain("top: 40px")
			expect(css).toContain("z-index: 77")
		end)

		local corners = {
			{ "top-right", "top", "right" },
			{ "top-left", "top", "left" },
			{ "bottom-right", "bottom", "right" },
			{ "bottom-left", "bottom", "left" },
		}
		for _, c in corners do
			it(`rests in the {c[1]} corner`, function()
				local cat = block(overlay.css(params({ position = c[1], offset_px = 20 })), SELECTOR)
				assert(cat, "missing cat rule")
				expect(cat).toContain(`{c[2]}: 20px`)
				expect(cat).toContain(`{c[3]}: 20px`)
				local other = if c[2] == "top" then "bottom" else "top"
				local otherH = if c[3] == "left" then "right" else "left"
				expect(cat).notToContain(`{other}:`)
				expect(cat).notToContain(`\t{otherH}:`)
			end)
		end

		it("falls back to the top-right corner for anything but a known corner", function()
			for _, bad in { "middle", "top-right; color: red", 3, "TOP-LEFT" } do
				local cat = block(overlay.css(params({ position = bad :: any })), SELECTOR)
				assert(cat, "missing cat rule")
				expect(cat).toContain("top: 12px")
				expect(cat).toContain("right: 12px")
				expect(cat).notToContain("color: red")
			end
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

		it("walks into the pane from either side: leftwards from right corners, rightwards from left", function()
			for _, corner in { "top-right", "bottom-right" } do
				local css = overlay.css(params({ pace = true, position = corner }))
				expect(css).toContain("0% { transform: translateX(0px) scaleX(-1);")
				expect(css).toContain("48% { transform: translateX(-160px) scaleX(-1);")
				expect(css).notToContain("translateX(160px)")
			end
			for _, corner in { "top-left", "bottom-left" } do
				local css = overlay.css(params({ pace = true, position = corner }))
				expect(css).toContain("0% { transform: translateX(0px) scaleX(1);")
				expect(css).toContain("48% { transform: translateX(160px) scaleX(1);")
				expect(css).toContain("50% { transform: translateX(160px) scaleX(-1);")
				expect(css).notToContain("translateX(-160px)")
			end
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

		it("renders a still frame without any animation when asked (reduced motion 'on')", function()
			local css = overlay.css(params({ pace = true, still = true, durations_ms = { 100, 120, 140 } }))
			expect(css).toContain(SELECTOR)
			expect(css).toContain("background-position: 0px 0px")
			expect(css).toContain("url(")
			expect(css).notToContain("@keyframes")
			expect(css).notToContain("animation: tern-cat")
			expect(css).toContain("background-size: 192px 64px")
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
				offset_px = "2px; x" :: any,
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

		for _, url in hostileUrls do
			it(`refuses reaction sheet_url {string.format("%q", url)}`, function()
				local css = overlay.css(params({
					reactions = {
						hover = { sheet_url = url, durations_ms = { 100, 100 } },
						press = { sheet_url = url, durations_ms = { 100, 100 } },
					},
				}))
				expect(count(css, "url(")).toBe(1)
				expect(css).notToContain(":hover")
				expect(css).notToContain(":active")
				expect(css).notToContain("::before")
				expect(css).toContain("pointer-events: none")
				expect(css).notToContain("display: none")
				expect(css).notToContain("evil")
				expect(balanced(css)).toBe(true)
			end)
		end

		it("clamps reaction durations and ignores junk fields", function()
			local css = overlay.css(params({
				reactions = {
					hover = {
						sheet_url = LOOK_URL,
						durations_ms = { -1, 1e12, 0 / 0, "x; color: red" :: any },
						loop = "}" :: any,
					},
					press = "body { display: none }" :: any,
				},
			}))
			expect(css).toContain(LOOK_URL)
			expect(css).notToContain("nan")
			expect(css).notToContain("infms")
			expect(css).notToContain("color: red")
			expect(css).notToContain("display: none")
			expect(css).notToContain(":active")
			expect(balanced(css)).toBe(true)
		end)
	end)

	describe("pointer reactions", function()
		it("makes only the cat and its ring take pointer state, without changing the cursor", function()
			local css = overlay.css(reactive())
			local cat = block(css, SELECTOR)
			local ring = block(css, HOST .. "::before")
			assert(cat and ring, "missing cat or ring rule")
			expect(cat).toContain("pointer-events: auto")
			expect(cat).toContain("visibility: visible")
			expect(ring).toContain("pointer-events: auto")
			expect(ring).toContain("visibility: visible")
			expect(ring).notToContain("background-color")
			expect(css).notToContain("cursor")
			expect(balanced(css)).toBe(true)
		end)

		it("centres the proximity ring on the cat and keeps it inside the pane", function()
			local ring = block(overlay.css(reactive()), HOST .. "::before")
			assert(ring, "missing ring")
			expect(ring).toContain("right: 0px")
			expect(ring).toContain("top: 0px")
			expect(ring).toContain("width: 124px")
			expect(ring).toContain("height: 124px")
			expect(ring).toContain("padding: 12px 12px 48px 48px")
			expect(ring).toContain("transform-origin: 80px 44px")
			local far = block(overlay.css(reactive({ offset_px = 60 })), HOST .. "::before")
			assert(far, "missing ring")
			expect(far).toContain("right: 12px")
			expect(far).toContain("top: 12px")
			expect(far).toContain("padding: 48px 48px 48px 48px")
		end)

		it("shrinks the ring only on the two edges at the cat's corner", function()
			local cases = {
				["top-left"] = {
					"left: 0px",
					"top: 0px",
					"padding: 12px 48px 48px 12px",
					"transform-origin: 44px 44px",
				},
				["bottom-right"] = {
					"right: 0px",
					"bottom: 0px",
					"padding: 48px 12px 12px 48px",
					"transform-origin: 80px 80px",
				},
				["bottom-left"] = {
					"left: 0px",
					"bottom: 0px",
					"padding: 48px 48px 12px 12px",
					"transform-origin: 44px 80px",
				},
			}
			for corner, want in cases do
				local ring = block(overlay.css(reactive({ position = corner })), HOST .. "::before")
				assert(ring, `missing ring at {corner}`)
				for _, line in want do
					expect(ring).toContain(line)
				end
			end
		end)

		it("plays the hover sheet once while the pointer is near or on the cat", function()
			local css = overlay.css(reactive())
			local hover = block(css, HOST .. ":hover::after")
			assert(hover, "missing hover rule")
			expect(hover).toContain(`url("{LOOK_URL}")`)
			expect(hover).toContain("background-size: 192px 64px")
			expect(hover).toContain("animation: tern-cat-hover 400ms step-end 1 forwards")
			expect(css).toContain("@keyframes tern-cat-hover {")
			expect(css).toContain("50% { background-position: -128px 0px; }")
		end)

		it("loops a looping hover sheet", function()
			local css = overlay.css(reactive({
				reactions = { hover = { sheet_url = LOOK_URL, durations_ms = { 100, 100 }, loop = true } },
			}))
			expect(css).toContain("animation: tern-cat-hover 200ms step-end infinite")
		end)

		it("swats in the ring's content box while pressed and holds the pose after release", function()
			local css = overlay.css(reactive())
			local ring = block(css, HOST .. "::before")
			local press = block(css, HOST .. ":active::before")
			local hide = block(css, HOST .. ":active::after")
			local cat = block(css, SELECTOR)
			assert(ring and press and hide and cat, "missing press rules")
			expect(ring).toContain(`url("{SWAT_URL}")`)
			expect(ring).toContain("background-clip: content-box")
			expect(ring).toContain("background-origin: content-box")
			expect(ring).toContain("background-size: 0px 0px")
			expect(ring).toContain("background-position: -192px 0px")
			expect(ring).toContain("transition: background-size 0s linear 700ms")
			expect(press).toContain("background-size: 256px 64px")
			expect(press).toContain("animation: tern-cat-press 400ms step-end 1 forwards")
			expect(press).toContain("transition: background-size 0s;")
			expect(hide).toContain("opacity: 0")
			expect(hide).toContain("transition: opacity 0s;")
			expect(cat).toContain("transition: opacity 0s linear 700ms")
		end)

		it("keeps pacing through hover and press by repeating the walk by name", function()
			local css = overlay.css(reactive({ pace = true }))
			local walk = "tern-cat-pace-idle-1 8333ms step-end infinite"
			for _, sel in { SELECTOR, HOST .. "::before", HOST .. ":hover::after", HOST .. ":active::before" } do
				local body = block(css, sel)
				assert(body, `missing {sel}`)
				expect(body).toContain(walk)
			end
			expect(count(css, "@keyframes tern-cat-pace-idle-1")).toBe(1)
		end)

		it("mirrors the ring with the cat", function()
			local ring = block(overlay.css(reactive({ facing = "left" })), HOST .. "::before")
			assert(ring, "missing ring")
			expect(ring).toContain("transform: scaleX(-1)")
		end)

		it("shows each reaction's first frame without animation when still", function()
			local css = overlay.css(reactive({ still = true, pace = true }))
			expect(css).notToContain("@keyframes")
			local hover = block(css, HOST .. ":hover::after")
			local ring = block(css, HOST .. "::before")
			local press = block(css, HOST .. ":active::before")
			assert(hover and ring and press, "missing reaction rules")
			expect(hover).toContain("animation: none")
			expect(hover).toContain("background-position: 0px 0px")
			expect(ring).toContain("background-position: 0px 0px")
			expect(press).toContain("animation: none")
		end)

		it("stops reaction animations under reduced motion", function()
			local css = overlay.css(reactive({ pace = true }))
			local media = string.match(css, "@media %(prefers%-reduced%-motion: reduce%) (%b{})")
			assert(media, "missing reduced-motion block")
			for _, sel in { SELECTOR, HOST .. "::before", HOST .. ":hover::after", HOST .. ":active::before" } do
				expect(media).toContain(sel)
			end
			expect(media).toContain("animation: none !important")
		end)

		it("supports a hover without a press sheet (no swat rules)", function()
			local css =
				overlay.css(reactive({ reactions = { hover = { sheet_url = LOOK_URL, durations_ms = { 100 } } } }))
			expect(css).toContain(HOST .. "::before")
			expect(css).toContain(HOST .. ":hover::after")
			expect(css).notToContain(":active")
			expect(css).notToContain("opacity")
			expect(block(css, HOST .. ":hover::after")).toContain("animation: none")
		end)

		it("renders nothing, not even the ring, when hidden", function()
			expect(overlay.css(reactive({ hidden = true }))).notToContain("{")
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
