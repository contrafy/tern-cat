--!strict
local t = require("../../lib/test")
local overlay = require("../../../cat/render/overlay")

local describe, it, expect = t.describe, t.it, t.expect

local HOST = "section.tn-pane.on:not(.off) > div.tn-body > div.tv > div.tv-fx.top"
local SELECTOR = HOST .. "::after"
local EVERY = "section.tn-pane > div.tn-body > div.tv > div.tv-fx.top::after"
local BACK = "section.tn-pane > div.tn-body > div.tv > div.tv-grid > div.tv-fx::after"
local BACK_ON = "section.tn-pane.on:not(.off) > div.tn-body > div.tv > div.tv-grid > div.tv-fx::after"
local FRONT = "section.tn-pane > div.tn-body > div.tv > div.tv-layer::after"
local FRONT_ON = "section.tn-pane.on:not(.off) > div.tn-body > div.tv > div.tv-layer::after"
local LOOK_URL = "data:image/png;base64,TE9PSw=="
local SWAT_URL = "data:image/png;base64,U1dBVA=="
local DIVE_URL = "data:image/png;base64,RElWRQ=="
local EMERGE_URL = "data:image/png;base64,RU1FUkdF"
local ENTER_URL = "data:image/png;base64,RU5URVI="
local EXIT_URL = "data:image/png;base64,RVhJVA=="
local FLAP_IN_URL = "data:image/png;base64,RkxBUElO"
local FLAP_OUT_URL = "data:image/png;base64,RkxBUE9VVA=="

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

-- A 48x24 floor prop: enter 7 frames (800 ms), exit 8 equal frames (640 ms).
local function prop(overrides: { [string]: any }?): any
	local p: { [string]: any } = {
		frame_w = 48,
		frame_h = 24,
		anchor = { 24, 12 },
		enter = { back = { sheet_url = ENTER_URL, durations_ms = { 80, 80, 160, 160, 160, 80, 80 } } },
		exit = { back = { sheet_url = EXIT_URL, durations_ms = { 80, 80, 80, 80, 80, 80, 80, 80 } } },
	}
	for k, v in overrides or {} do
		p[k] = v
	end
	return p
end

local PACK_DIVE = { sheet_url = DIVE_URL, durations_ms = { 60, 60, 60, 60, 60, 60, 60, 60 } }
local PACK_EMERGE = { sheet_url = EMERGE_URL, durations_ms = { 160, 70, 70, 80, 80, 60, 60, 60 } }

local function portal(overrides: { [string]: any }?, transition: { [string]: any }?): overlay.Params
	local tr: { [string]: any } = { prop = prop() }
	for k, v in transition or {} do
		tr[k] = v
	end
	local p: { [string]: any } = { transition = tr, position = "bottom-right" }
	for k, v in overrides or {} do
		p[k] = v
	end
	return reactive(p)
end

describe("render/overlay.css pane transition", function()
	it("keeps the cat on the visible focused pane only, and every other pane at the dive's end", function()
		local css = overlay.css(portal())
		local every = block(css, EVERY)
		local on = block(css, SELECTOR)
		assert(every and on, "missing cat rules")
		expect(every).toContain("height: 0px")
		expect(every).toContain("pointer-events: none")
		expect(every).toContain("visibility: visible")
		expect(every).notToContain("animation")
		expect(on).toContain("height: 64px")
		expect(balanced(css)).toBe(true)
	end)

	it("plays the emerge last on the focused pane, with no delay on the decision", function()
		local on = block(overlay.css(portal({ pace = true })), SELECTOR)
		assert(on, "missing cat rule")
		expect(on).toContain(
			"animation: tern-cat-idle-1 200ms step-end infinite, tern-cat-pace-idle-1 8333ms step-end infinite, tern-cat-emerge 640ms step-end 1 backwards;"
		)
		expect(on).toContain("transition: opacity 0s linear 700ms")
		local plain = block(overlay.css(portal({ reactions = {} })), SELECTOR)
		assert(plain, "missing cat rule")
		expect(plain).toContain("transition: none")
	end)

	it("names the emerge the same for every decision so a decision change never replays it", function()
		local a = overlay.css(portal({ anim_key = "idle" }))
		local b = overlay.css(portal({ anim_key = "walk-7", loop = false }))
		for _, css in { a, b } do
			expect(count(css, "@keyframes tern-cat-emerge {")).toBe(1)
			expect(css).toContain("tern-cat-emerge 640ms step-end 1 backwards")
		end
	end)

	it("repeats the emerge by name in the hover rule and the ring's in the press rule", function()
		local css = overlay.css(portal({ pace = true }))
		local hover = block(css, HOST .. ":hover::after")
		local ring = block(css, HOST .. "::before")
		local press = block(css, HOST .. ":active::before")
		assert(hover and ring and press, "missing reaction rules")
		expect(hover).toContain("tern-cat-emerge 640ms step-end 1 backwards")
		expect(ring).toContain("tern-cat-emerge-ring 640ms step-end 1 backwards")
		expect(press).toContain("tern-cat-emerge-ring 640ms step-end 1 backwards")
		expect(press).toContain("tern-cat-pace-idle-1 ")
	end)

	it("keeps a pressed cat emerging instead of swatting until the emerge ends", function()
		local css = overlay.css(portal())
		local emerge = string.match(css, "@keyframes tern%-cat%-emerge (%b{})")
		local ring = string.match(css, "@keyframes tern%-cat%-emerge%-ring (%b{})")
		assert(emerge and ring, "missing emerge keyframes")
		expect(emerge).toContain("0% { opacity: 1;")
		expect(emerge).toContain("100% { opacity: 1;")
		expect(ring).toContain("0% { background-size: 0px 0px; }")
		expect(ring).toContain("100% { background-size: 0px 0px; }")
	end)

	it("sinks the decision sheet into the floor and rises from it when the pack has no dive or emerge", function()
		local css = overlay.css(portal())
		local every = block(css, EVERY)
		assert(every, "missing every-pane rule")
		expect(every).toContain('background-image: url("data:image/png;base64,iVBORw0KGgo=")')
		expect(every).toContain("background-position: 0px 0px")
		expect(every).toContain("transition: height 480ms steps(8, end);")
		local emerge = string.match(css, "@keyframes tern%-cat%-emerge (%b{})")
		assert(emerge, "missing emerge keyframes")
		expect(emerge).toContain("0% { opacity: 1; height: 0px; }")
		expect(emerge).toContain("25% { height: 8px; }")
		expect(emerge).toContain("68.75% { height: 64px; }")
		expect(emerge).toContain("100% { opacity: 1; height: 64px; }")
		expect(emerge).notToContain("background-image")
	end)

	it("plays the pack's dive in even steps and its emerge at the pack's frame times", function()
		local css = overlay.css(portal(nil, { dive = PACK_DIVE, emerge = PACK_EMERGE }))
		local every = block(css, EVERY)
		assert(every, "missing every-pane rule")
		expect(every).toContain(`background-image: url("{DIVE_URL}")`)
		expect(every).toContain("background-size: 512px 64px")
		expect(every).toContain("background-position: -448px 0px")
		expect(every).toContain("transition: background-position 420ms steps(7, end), height 0s step-end 480ms;")
		local emerge = string.match(css, "@keyframes tern%-cat%-emerge (%b{})")
		assert(emerge, "missing emerge keyframes")
		expect(count(emerge, EMERGE_URL)).toBe(2)
		expect(emerge).toContain(
			`0% \{ opacity: 1; background-image: url("{EMERGE_URL}"); background-size: 512px 64px; background-position: 0px 0px; }`
		)
		expect(emerge).toContain("25% { background-position: -64px 0px; }")
		expect(emerge).toContain("90.625% { background-position: -448px 0px; }")
		expect(emerge).toContain("background-position: -448px 0px; }")
		expect(emerge).notToContain("height")
	end)

	it("copies the facing to every pane so the cat does not flip as it dives", function()
		local every = block(overlay.css(portal({ facing = "left" })), EVERY)
		assert(every, "missing every-pane rule")
		expect(every).toContain("transform: scaleX(-1)")
	end)

	it("lifts the cat so the prop fits inside the pane and puts the prop's anchor under its feet", function()
		local css = overlay.css(portal())
		local on = block(css, SELECTOR)
		local back = block(css, BACK)
		assert(on and back, "missing rules")
		expect(on).toContain("right: 16px")
		expect(on).toContain("bottom: 24px")
		expect(back).toContain("right: calc(0px - var(--tv-aside, 0px))")
		expect(back).toContain("bottom: 0px")
		expect(back).toContain("width: 96px")
		expect(back).toContain("height: 48px")
		local far = block(overlay.css(portal({ offset_px = 60 })), BACK)
		assert(far, "missing back prop")
		expect(far).toContain("right: calc(44px - var(--tv-aside, 0px))")
		expect(far).toContain("bottom: 36px")
	end)

	it("keeps the floor line fixed at top corners and hangs the prop below the cat's feet", function()
		local css = overlay.css(portal({ position = "top-right" }))
		local on = block(css, SELECTOR)
		local every = block(css, EVERY)
		local back = block(css, BACK)
		local ring = block(css, HOST .. "::before")
		assert(on and every and back and ring, "missing rules")
		for _, cat in { on, every } do
			expect(cat).toContain("right: 16px")
			expect(cat).toContain("bottom: calc(100% - 76px)")
			expect(cat).notToContain("top:")
		end
		expect(back).toContain("right: calc(0px - var(--tv-aside, 0px))")
		expect(back).toContain("top: calc(52px - var(--tv-py, 0px))")
		expect(ring).toContain("top: 0px")
		expect(ring).toContain("padding: 12px 16px 48px 48px")
		local left = overlay.css(portal({ position = "top-left" }))
		local leftBack = block(left, BACK)
		local leftCat = block(left, SELECTOR)
		assert(leftBack and leftCat, "missing left rules")
		expect(leftBack).toContain("left: calc(0px - var(--tv-px, 0px))")
		expect(leftCat).toContain("left: 16px")
		local box = prop({
			enter = {
				back = { sheet_url = ENTER_URL, durations_ms = { 800 } },
				front = { sheet_url = FLAP_IN_URL, durations_ms = { 800 } },
			},
		})
		local front = block(overlay.css(portal({ position = "bottom-left" }, { prop = box })), FRONT)
		assert(front, "missing front prop")
		expect(front).toContain("left: 0px")
		expect(front).toContain("bottom: 0px")
	end)

	it("opens and closes the back prop on the focused pane and plays its exit on the pane left", function()
		local css = overlay.css(portal())
		local back = block(css, BACK)
		local on = block(css, BACK_ON)
		assert(back and on, "missing prop rules")
		expect(back).toContain("pointer-events: none")
		expect(back).toContain("visibility: visible")
		expect(back).toContain(`background-image: url("{EXIT_URL}")`)
		expect(back).toContain("background-size: 768px 48px")
		expect(back).toContain("background-position: -672px 0px")
		expect(back).toContain("opacity: 0")
		expect(back).toContain("transition: background-position 560ms steps(7, end), opacity 0s step-end 640ms;")
		expect(back).notToContain("animation")
		expect(on).toContain(`background-image: url("{ENTER_URL}")`)
		expect(on).toContain("background-size: 0px 0px")
		expect(on).toContain("background-position: 0px 0px")
		expect(on).toContain("opacity: 1")
		expect(on).toContain("transition: none")
		expect(on).toContain("animation: tern-cat-prop-back 800ms step-end 1;")
		local frames = string.match(css, "@keyframes tern%-cat%-prop%-back (%b{})")
		assert(frames, "missing prop keyframes")
		expect(frames).toContain("0% { background-size: 672px 48px; background-position: 0px 0px; }")
		expect(frames).toContain("20% { background-position: -192px 0px; }")
		expect(frames).toContain("90% { background-position: -576px 0px; }")
		expect(frames).toContain("100% { background-size: 672px 48px; background-position: -576px 0px; }")
		expect(count(css, ENTER_URL)).toBe(1)
		expect(count(css, EXIT_URL)).toBe(1)
		expect(css).notToContain(FRONT)
	end)

	it("draws an optional front layer over the cat on Tern's layer host", function()
		local box = prop({
			enter = {
				back = { sheet_url = ENTER_URL, durations_ms = { 400, 400 } },
				front = { sheet_url = FLAP_IN_URL, durations_ms = { 400, 400 } },
			},
			exit = {
				back = { sheet_url = EXIT_URL, durations_ms = { 320, 320 } },
				front = { sheet_url = FLAP_OUT_URL, durations_ms = { 320, 320 } },
			},
		})
		local css = overlay.css(portal(nil, { prop = box }))
		local front = block(css, FRONT)
		local on = block(css, FRONT_ON)
		assert(front and on, "missing front prop rules")
		expect(front).toContain("right: 0px")
		expect(front).toContain("pointer-events: none")
		expect(front).toContain(`url("{FLAP_OUT_URL}")`)
		expect(front).toContain("transition: background-position 320ms steps(1, end), opacity 0s step-end 640ms;")
		expect(on).toContain(`url("{FLAP_IN_URL}")`)
		expect(on).toContain("animation: tern-cat-prop-front 800ms step-end 1;")
		expect(css).toContain("@keyframes tern-cat-prop-front {")
	end)

	it("does nothing on panes it leaves or enters when motion is reduced", function()
		local css = overlay.css(portal({ pace = true }))
		local media = string.match(css, "@media %(prefers%-reduced%-motion: reduce%) (%b{})")
		assert(media, "missing reduced-motion block")
		for _, sel in { EVERY, BACK, BACK_ON, SELECTOR, HOST .. "::before" } do
			expect(media).toContain(sel)
		end
		expect(media).toContain("transition: none !important")
		expect(media).toContain("animation: none !important")
	end)

	it("draws no transition at all for a still cat", function()
		local css = overlay.css(portal({ still = true }, { dive = PACK_DIVE, emerge = PACK_EMERGE }))
		expect(css).notToContain(EVERY)
		expect(css).notToContain("tv-grid")
		expect(css).notToContain("tern-cat-emerge")
		expect(css).notToContain(DIVE_URL)
		expect(css).toContain("right: 12px")
	end)

	it("matches the current overlay when there is no transition", function()
		local css = overlay.css(reactive())
		expect(css).notToContain(EVERY)
		expect(css).notToContain("tv-grid")
		expect(css).notToContain("tv-layer")
		expect(css).notToContain("emerge")
	end)

	describe("sanitization", function()
		local hostile = { 'x.png") } body { display: none } a { b: url("', "https://evil.invalid/p.png", "" }
		for _, url in hostile do
			it(`drops the whole transition for a prop sheet_url {string.format("%q", url)}`, function()
				local css = overlay.css(portal(nil, {
					prop = prop({ enter = { back = { sheet_url = url, durations_ms = { 100 } } } }),
				}))
				expect(css).notToContain(EVERY)
				expect(css).notToContain("emerge")
				expect(css).notToContain("evil")
				expect(css).notToContain("display: none")
				expect(balanced(css)).toBe(true)
			end)
			it(`ignores a hostile dive, emerge or front sheet_url {string.format("%q", url)}`, function()
				local bad = { sheet_url = url, durations_ms = { 100, 100 } }
				local css = overlay.css(portal(nil, {
					dive = bad,
					emerge = bad,
					prop = prop({
						enter = { back = { sheet_url = ENTER_URL, durations_ms = { 100 } }, front = bad },
						exit = { back = { sheet_url = EXIT_URL, durations_ms = { 100 } }, front = bad },
					}),
				}))
				expect(css).toContain(EVERY)
				expect(css).toContain("transition: height 480ms steps(8, end);")
				expect(css).notToContain(FRONT)
				expect(css).notToContain("evil")
				expect(css).notToContain("display: none")
				expect(balanced(css)).toBe(true)
			end)
		end

		it("clamps prop geometry and durations", function()
			local css = overlay.css(portal(nil, {
				prop = prop({
					frame_w = 0 / 0,
					frame_h = "24; color: red" :: any,
					anchor = { -1e9, math.huge },
					exit = { back = { sheet_url = EXIT_URL, durations_ms = { 1e12, -5, 0 / 0 } } },
				}),
			}))
			expect(css).toContain(EVERY)
			expect(css).notToContain("nan")
			expect(css).notToContain("infpx")
			expect(css).notToContain("infms")
			expect(css).notToContain("color: red")
			expect(css).notToContain("-1000000000")
			expect(balanced(css)).toBe(true)
		end)

		it("ignores a transition that is not a table", function()
			local css = overlay.css(reactive({ transition = "} body { display: none }" :: any }))
			expect(css).notToContain(EVERY)
			expect(css).notToContain("display: none")
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
