--!strict
local t = require("../../lib/test")
local travel = require("../../../cat/render/travel")

local describe, it, expect = t.describe, t.it, t.expect

local WALK_URL = "data:image/png;base64,V0FMSw=="
local RUN_URL = "data:image/png;base64,UlVO"
local CLIMB_URL = "data:image/png;base64,Q0xJTUI="
local LEAP_URL = "data:image/png;base64,TEVBUA=="
local HIDE = "div.tn-stage > section.tn-pane:not(.on) > div.tn-body > div.tv > div.tv-fx.top::after"
local HOLD = "div.tn-stage > section.tn-pane.on:not(.off) > div.tn-body > div.tv > div.tv-fx.top::after"

-- A split node as `cx.session:layout` returns it ([1] left/top, [2] right/bottom).
local function split(dir: string, ratio: number?, first: any, second: any?): travel.Tree
	local node: any = { split = dir, ratio = ratio }
	node[1] = first
	node[2] = second
	return node
end

local function leaf(pane: any): travel.Tree
	return { pane = pane }
end

local function tab(root: travel.Tree): travel.Layout
	return { root = root, zoomed = false }
end

-- 1 | 2
local TWO = tab(split("right", 0.5, leaf(1), leaf(2)))
-- 1 over 2
local STACK = tab(split("down", 0.5, leaf(1), leaf(2)))
-- 1 2
-- 3 4
local GRID = tab(split("right", 0.5, split("down", 0.5, leaf(1), leaf(3)), split("down", 0.5, leaf(2), leaf(4))))
-- 1 | 2 over 3 (the spike's 0.391 / 0.386 split)
local UNEVEN = tab(split("right", 0.391, leaf(1), split("down", 0.386, leaf(2), leaf(3))))
-- 1 | 2 | 3
local COLUMNS = tab(split("right", 1 / 3, leaf(1), split("right", 0.5, leaf(2), leaf(3))))

local function input(layout: travel.Layout, from: number, to: number, overrides: { [string]: any }?): travel.PlanInput
	local p: { [string]: any } = {
		layout = layout,
		from = from,
		to = to,
		position = "top-right",
		offset_px = 12,
		box_w = 64,
		box_h = 64,
		insets = { pad = 3, header = 0 },
	}
	for k, v in overrides or {} do
		p[k] = v
	end
	return p :: any
end

local function plan(layout: travel.Layout, from: number, to: number, overrides: { [string]: any }?): travel.Trip
	local trip = travel.plan(input(layout, from, to, overrides))
	assert(trip, "expected a trip")
	return trip
end

local function legs(trip: travel.Trip): { string }
	local out = {}
	for _, leg in trip.legs do
		table.insert(out, `{leg.kind}:{leg.dir}`)
	end
	return out
end

local function durations(trip: travel.Trip): { number }
	local out = {}
	for _, leg in trip.legs do
		table.insert(out, leg.ms)
	end
	return out
end

local function expectPoint(p: travel.Point?, xp: number, xo: number, yp: number, yo: number)
	assert(p, "expected a point")
	expect(p.xp).toBeCloseTo(xp, 1e-3)
	expect(p.xo).toBeCloseTo(xo, 1e-3)
	expect(p.yp).toBeCloseTo(yp, 1e-3)
	expect(p.yo).toBeCloseTo(yo, 1e-3)
end

local function expectRect(r: travel.Rect?, x: number, y: number, w: number, h: number)
	assert(r, "expected a rect")
	expect(r.x).toBeCloseTo(x, 1e-9)
	expect(r.y).toBeCloseTo(y, 1e-9)
	expect(r.w).toBeCloseTo(w, 1e-9)
	expect(r.h).toBeCloseTo(h, 1e-9)
end

local function sheet(url: string, frames: number, frameMs: number, animation: string): travel.Sheet
	local d = {}
	for i = 1, frames do
		d[i] = frameMs
	end
	return { sheet_url = url, durations_ms = d, animation = animation }
end

local function art(): travel.Art
	return {
		walk = sheet(WALK_URL, 4, 130, "walk"),
		run = sheet(RUN_URL, 4, 70, "run"),
		climb = sheet(CLIMB_URL, 4, 90, "climb"),
		leap = sheet(LEAP_URL, 6, 80, "leap"),
	}
end

local function css(trip: travel.Trip, overrides: { [string]: any }?): string
	local p: { [string]: any } = { trip = trip, id = 7, art = art() }
	for k, v in overrides or {} do
		p[k] = v
	end
	local out = travel.css(p :: any)
	assert(out, "expected a sheet")
	return out
end

local function block(text: string, selector: string): string?
	local start = string.find(text, selector .. " {", 1, true)
	if not start then
		return nil
	end
	local stop = string.find(text, "}", start, true)
	return string.sub(text, start, stop)
end

local function keyframes(text: string, name: string): string?
	local start = string.find(text, `@keyframes {name} \{`, 1, true)
	if not start then
		return nil
	end
	local stop = string.find(text, "\n}", start, true)
	return string.sub(text, start, stop)
end

local function balanced(text: string): boolean
	local depth = 0
	for c in string.gmatch(text, "[{}]") do
		depth += if c == "{" then 1 else -1
		if depth < 0 then
			return false
		end
	end
	return depth == 0
end

describe("render.travel", function()
	describe("layout", function()
		it("splits the stage by the ratio for two panes", function()
			local rs = travel.rects(TWO)
			assert(rs, "expected rects")
			expectRect(rs[1], 0, 0, 0.5, 1)
			expectRect(rs[2], 0.5, 0, 0.5, 1)
			local stack = travel.rects(STACK)
			assert(stack, "expected rects")
			expectRect(stack[1], 0, 0, 1, 0.5)
			expectRect(stack[2], 0, 0.5, 1, 0.5)
		end)

		it("tiles a 2x2 grid", function()
			local rs = travel.rects(GRID)
			assert(rs, "expected rects")
			expectRect(rs[1], 0, 0, 0.5, 0.5)
			expectRect(rs[2], 0.5, 0, 0.5, 0.5)
			expectRect(rs[3], 0, 0.5, 0.5, 0.5)
			expectRect(rs[4], 0.5, 0.5, 0.5, 0.5)
		end)

		it("multiplies nested uneven ratios", function()
			local rs = travel.rects(UNEVEN)
			assert(rs, "expected rects")
			expectRect(rs[1], 0, 0, 0.391, 1)
			expectRect(rs[2], 0.391, 0, 0.609, 0.386)
			expectRect(rs[3], 0.391, 0.386, 0.609, 0.614)
		end)

		it("takes a missing ratio as an even split", function()
			local rs = travel.rects(tab(split("right", nil, leaf(1), leaf(2))))
			assert(rs, "expected rects")
			expectRect(rs[2], 0.5, 0, 0.5, 1)
		end)

		it("rejects malformed trees", function()
			expect(travel.rects(nil)).toBeNil()
			expect(travel.rects(tab(split("right", 1.5, leaf(1), leaf(2))))).toBeNil()
			expect(travel.rects(tab(split("right", 0, leaf(1), leaf(2))))).toBeNil()
			expect(travel.rects(tab(split("diagonal", 0.5, leaf(1), leaf(2))))).toBeNil()
			expect(travel.rects(tab(split("right", 0.5, leaf(1))))).toBeNil()
			expect(travel.rects(tab(split("right", 0.5, leaf(1), leaf(1))))).toBeNil()
			expect(travel.rects(tab(leaf("1")))).toBeNil()
			local deep = leaf(99)
			for i = 1, 40 do
				deep = split("right", 0.5, leaf(i), deep)
			end
			expect(travel.rects(tab(deep))).toBeNil()
		end)
	end)

	describe("neighbors", function()
		it("finds panes that share an edge", function()
			expect(travel.neighbors(TWO, 1, 2)).toBe(true)
			expect(travel.neighbors(GRID, 1, 2)).toBe(true)
			expect(travel.neighbors(GRID, 1, 3)).toBe(true)
			expect(travel.neighbors(GRID, 4, 2)).toBe(true)
			expect(travel.neighbors(UNEVEN, 1, 2)).toBe(true)
			expect(travel.neighbors(UNEVEN, 1, 3)).toBe(true)
			expect(travel.neighbors(UNEVEN, 2, 3)).toBe(true)
		end)

		it("does not count a shared corner or a pane across another", function()
			expect(travel.neighbors(GRID, 1, 4)).toBe(false)
			expect(travel.neighbors(GRID, 2, 3)).toBe(false)
			expect(travel.neighbors(COLUMNS, 1, 3)).toBe(false)
		end)

		it("knows nothing about untiled or identical panes", function()
			expect(travel.neighbors(GRID, 1, 9)).toBeNil()
			expect(travel.neighbors(GRID, 1, 1)).toBeNil()
			expect(travel.neighbors({ root = { split = "up" } } :: any, 1, 2)).toBeNil()
		end)

		it("marks the trip for auto", function()
			expect(plan(GRID, 4, 2).adjacent).toBe(true)
			expect(plan(GRID, 4, 1).adjacent).toBe(false)
		end)
	end)

	describe("plan", function()
		it("falls back (nil) for zoom, floats, unknown and identical panes", function()
			local zoomed = table.clone(TWO)
			zoomed.zoomed = true
			expect(travel.plan(input(zoomed, 1, 2))).toBeNil()
			-- A floating pane is in `floats`, not in the tree.
			local floats: any = table.clone(TWO)
			floats.floats = { { pane = 5, over = 1, corner = "bottom-right" } }
			expect(travel.plan(input(floats, 1, 5))).toBeNil()
			expect(travel.plan(input(floats, 5, 2))).toBeNil()
			expect(travel.plan(input(TWO, 1, 1))).toBeNil()
			expect(travel.plan(input({ root = { split = "right", ratio = 2 } } :: any, 1, 2))).toBeNil()
			expect(travel.plan(nil :: any)).toBeNil()
			expect(travel.plan(input(TWO, "1" :: any, 2))).toBeNil()
		end)

		it("walks to the divider, leaps it and runs to the next top-right corner", function()
			local trip = plan(TWO, 1, 2)
			-- Corner: pane edge minus padding, gap and box; top plus padding and gap.
			expectPoint(trip.start, 50, -79, 0, 15)
			expectPoint(trip.finish, 100, -79, 0, 15)
			expect(legs(trip)).toEqual({ "walk:right", "leap:right", "run:right" })
			expect(durations(trip)).toEqual({ 100, 480, 313 })
			expect(trip.total_ms).toBe(893)
			local leap = trip.legs[2]
			expectPoint(leap.from, 50, -68, 0, 15)
			expectPoint(leap.to, 50, 4, 0, 15)
			-- The arc stays inside the panel at the top of the stage.
			expectPoint(leap.apex, 50, -32, 0, 0)
			expect(trip.legs[1].start_ms).toBe(0)
			expect(trip.legs[2].start_ms).toBe(100)
			expect(trip.legs[3].start_ms).toBe(580)
			expect(trip.legs[3].steps).toBe(3)
		end)

		it("mirrors the trip going left", function()
			local trip = plan(TWO, 2, 1)
			expect(legs(trip)).toEqual({ "run:left", "leap:left", "walk:left" })
			expectPoint(trip.legs[2].from, 50, 4, 0, 15)
			expectPoint(trip.legs[2].to, 50, -68, 0, 15)
			expectPoint(trip.finish, 50, -79, 0, 15)
		end)

		it("plans every corner", function()
			local tl = plan(TWO, 1, 2, { position = "top-left" })
			expectPoint(tl.start, 0, 15, 0, 15)
			expectPoint(tl.finish, 50, 15, 0, 15)
			expect(legs(tl)).toEqual({ "run:right", "leap:right", "walk:right" })

			local br = plan(TWO, 1, 2, { position = "bottom-right" })
			expectPoint(br.start, 50, -79, 100, -79)
			expectPoint(br.finish, 100, -79, 100, -79)
			expect(legs(br)).toEqual({ "walk:right", "leap:right", "run:right" })
			-- Away from the top the arc rises its full height.
			expectPoint(br.legs[2].apex, 50, -32, 100, -97)

			local bl = plan(TWO, 2, 1, { position = "bottom-left" })
			expectPoint(bl.start, 50, 15, 100, -79)
			expectPoint(bl.finish, 0, 15, 100, -79)
			expect(legs(bl)).toEqual({ "walk:left", "leap:left", "run:left" })
			expect(bl.wall).toBe("left")
			expect(br.wall).toBe("right")
		end)

		it("climbs between stacked panes along the corner's column", function()
			local down = plan(STACK, 1, 2, { position = "bottom-left" })
			expect(legs(down)).toEqual({ "climb:down" })
			expectPoint(down.start, 0, 15, 50, -79)
			expectPoint(down.finish, 0, 15, 100, -79)
			expect(down.total_ms).toBe(357)
			local up = plan(STACK, 2, 1)
			expect(legs(up)).toEqual({ "climb:up" })
			expectPoint(up.start, 100, -79, 50, 15)
			expectPoint(up.finish, 100, -79, 0, 15)
		end)

		it("goes diagonally in two legs: along the row, then up the column", function()
			local trip = plan(GRID, 4, 1)
			expect(legs(trip)).toEqual({ "run:left", "leap:left", "walk:left", "climb:up" })
			expect(durations(trip)).toEqual({ 313, 480, 100, 357 })
			expectPoint(trip.legs[4].from, 50, -79, 50, 15)
			expectPoint(trip.legs[4].to, 50, -79, 0, 15)
			local back = plan(GRID, 1, 4, { position = "bottom-right" })
			expect(legs(back)).toEqual({ "walk:right", "leap:right", "run:right", "climb:down" })
			expectPoint(back.legs[4].from, 100, -79, 50, -79)
			expectPoint(back.legs[4].to, 100, -79, 100, -79)
		end)

		it("only leaps dividers on the cat's own row", function()
			-- From the full-height pane into the lower right pane: the divider between 2 and 3
			-- is crossed while climbing, never leapt.
			local trip = plan(UNEVEN, 1, 3)
			expect(legs(trip)).toEqual({ "walk:right", "leap:right", "run:right", "climb:down" })
			expectPoint(trip.legs[2].to, 39.1, 4, 0, 15)
			expectPoint(trip.finish, 100, -79, 38.6, 15)
			local low = plan(UNEVEN, 3, 1, { position = "bottom-left" })
			expect(legs(low)).toEqual({ "walk:left", "leap:left", "walk:left" })
			expectPoint(low.finish, 0, 15, 100, -79)
		end)

		it("leaps every divider between distant columns", function()
			local trip = plan(COLUMNS, 1, 3)
			expect(legs(trip)).toEqual({ "walk:right", "leap:right", "walk:right", "leap:right", "walk:right" })
			expect(durations(trip)).toEqual({ 100, 480, 303, 480, 303 })
			expect(trip.total_ms).toBe(1666)
		end)

		it("adds the pane header to the top inset", function()
			local trip = plan(TWO, 1, 2, { insets = { pad = 4, header = 30 } })
			expectPoint(trip.start, 50, -80, 0, 46)
			local bottom = plan(TWO, 1, 2, { insets = { pad = 4, header = 30 }, position = "bottom-left" })
			expectPoint(bottom.start, 0, 16, 100, -80)
		end)

		it("uses a separate vertical gap when the corner is lifted", function()
			local trip = plan(TWO, 1, 2, { offset_v_px = 40 })
			expectPoint(trip.start, 50, -79, 0, 43)
		end)

		it("fits the leap to the pack's leap", function()
			expect(plan(TWO, 1, 2, { leap_ms = 900 }).legs[2].ms).toBe(720)
			expect(plan(TWO, 1, 2, { leap_ms = 10 }).legs[2].ms).toBe(240)
			expect(plan(TWO, 1, 2, { leap_ms = 361 }).legs[2].ms).toBe(362)
		end)

		it("sanitizes geometry inputs", function()
			local trip = plan(TWO, 1, 2, {
				position = "middle",
				offset_px = 0 / 0,
				box_w = -5,
				box_h = math.huge,
				insets = { pad = "x", header = 1e9 },
			})
			expect(trip.corner).toBe("top-right")
			expect(trip.box_w).toBe(1)
			expect(trip.box_h).toBe(2048)
			expectPoint(trip.start, 50, -13, 0, 212)
		end)
	end)

	describe("interrupts", function()
		it("steps the traveler like its CSS", function()
			local trip = plan(TWO, 1, 2)
			expectPoint(travel.positionAt(trip, 0), 50, -79, 0, 15)
			expectPoint(travel.positionAt(trip, -50), 50, -79, 0, 15)
			-- Half way up the leap's first half (2 steps): the first step.
			expectPoint(travel.positionAt(trip, 220), 50, -50, 0, 7.5)
			expectPoint(travel.positionAt(trip, 340), 50, -32, 0, 0)
			-- 210 ms into the 313 ms run (3 steps): two thirds of the way.
			expectPoint(travel.positionAt(trip, 790), 50 + 50 * 2 / 3, 4 - 83 * 2 / 3, 0, 15)
			expect(travel.positionAt(trip, 893)).toBeNil()
			expect(travel.positionAt(trip, 5000)).toBeNil()
			expect(travel.positionAt(trip, 0 / 0)).toBeNil()
		end)

		it("starts a new trip where the cat is", function()
			local first = plan(TWO, 1, 2)
			local back = plan(TWO, 2, 1, { interrupt = { trip = first, elapsed_ms = 790 } })
			expectPoint(back.start, 50 + 50 * 2 / 3, 4 - 83 * 2 / 3, 0, 15)
			expect(legs(back)).toEqual({ "walk:left", "leap:left", "walk:left" })
			expect(durations(back)).toEqual({ 303, 480, 100 })
			expectPoint(back.finish, 50, -79, 0, 15)
		end)

		it("leaps only the dividers still ahead", function()
			local first = plan(COLUMNS, 1, 3)
			-- 150 ms into the walk across the middle column (3 steps): one third of it.
			local turn = plan(COLUMNS, 3, 2, { interrupt = { trip = first, elapsed_ms = 730 } })
			expectPoint(turn.start, 100 / 3 + 100 / 9, 4 - 72 / 3, 0, 15)
			expect(legs(turn)).toEqual({ "walk:right" })
			expectPoint(turn.finish, 200 / 3, -79, 0, 15)
		end)

		it("starts from the corner once the previous trip has arrived", function()
			local first = plan(TWO, 1, 2)
			local back = plan(TWO, 2, 1, { interrupt = { trip = first, elapsed_ms = 2000 } })
			expectPoint(back.start, 100, -79, 0, 15)
			local junk = plan(TWO, 2, 1, { interrupt = { trip = first, elapsed_ms = "soon" } })
			expectPoint(junk.start, 100, -79, 0, 15)
		end)
	end)

	describe("timing", function()
		it("gives the main sheet its linger, arrive and the arrival", function()
			local trip = plan(TWO, 1, 2)
			local tm = travel.timing(trip)
			expect(tm.linger_ms).toBe(150)
			expect(tm.arrive_ms).toBe(80)
			expect(tm.arrival_ms).toBe(893)
			expect(tm.clear_ms).toBe(1093)
			expect(travel.LINGER_MS).toBe(150)
			expect(travel.ARRIVE_MS).toBe(80)
			expect(travel.timing(nil).arrival_ms).toBe(0)
		end)
	end)

	describe("facing", function()
		local function leg(kind: travel.LegKind, dir: travel.Direction): travel.Leg
			local p = { xp = 0, xo = 0, yp = 0, yo = 0 }
			return { kind = kind, dir = dir, from = p, to = p, start_ms = 0, ms = 100, steps = 1 }
		end

		it("mirrors horizontal legs going left", function()
			for _, kind in { "walk", "run", "leap" } do
				expect(travel.transform(leg(kind :: any, "right"), "right", kind)).toBe("none")
				expect(travel.transform(leg(kind :: any, "left"), "right", kind)).toBe("scaleX(-1)")
			end
		end)

		it("draws a pack's climb head up with the wall on its right", function()
			expect(travel.transform(leg("climb", "up"), "right", "climb")).toBe("none")
			expect(travel.transform(leg("climb", "down"), "right", "climb")).toBe("scaleY(-1)")
			expect(travel.transform(leg("climb", "up"), "left", "climb")).toBe("scaleX(-1)")
			expect(travel.transform(leg("climb", "down"), "left", "climb")).toBe("scale(-1, -1)")
		end)

		it("turns the walk on its side, feet to the wall, without a climb", function()
			expect(travel.transform(leg("climb", "up"), "right", "walk")).toBe("rotate(-90deg)")
			expect(travel.transform(leg("climb", "down"), "right", "walk")).toBe("rotate(90deg) scaleY(-1)")
			expect(travel.transform(leg("climb", "up"), "left", "walk")).toBe("rotate(-90deg) scaleY(-1)")
			expect(travel.transform(leg("climb", "down"), "left", "walk")).toBe("rotate(90deg)")
		end)
	end)

	describe("css", function()
		it("hides unfocused cats, holds the focused one and draws the traveler on the stage", function()
			local trip = plan(TWO, 1, 2)
			local out = css(trip, { hold = { "tern-cat-idle-1 1560ms step-end infinite" } })
			expect(string.sub(out, 1, 22)).toBe("/* tern-cat travel 7 *")
			expect(out).toContain(`{HIDE} \{ opacity: 0 !important; transition: none !important; }`)
			expect(out).toContain(
				`{HOLD} \{ animation: tern-cat-idle-1 1560ms step-end infinite, tern-cat-travel-hold-7 893ms step-end 1 backwards; }`
			)
			local traveler = block(out, "div.tn-stage::after")
			assert(traveler, "missing traveler")
			expect(traveler).toContain("position: absolute;")
			expect(traveler).toContain("pointer-events: none;")
			expect(traveler).toContain("width: 64px;")
			expect(traveler).toContain("z-index: 2147483000;")
			expect(traveler).toContain("opacity: 0;")
			expect(traveler).toContain(
				"animation: tern-cat-travel-path-7 893ms linear 1 both, tern-cat-travel-frames-7 893ms step-end 1 both, tern-cat-travel-vis-7 893ms step-end 1 both;"
			)
			expect(out).toContain("@keyframes tern-cat-travel-hold-7 { 0% { opacity: 0; } 100% { opacity: 0; } }")
			expect(out).toContain("@keyframes tern-cat-travel-vis-7 { 0% { opacity: 1; } 100% { opacity: 0; } }")
			expect(balanced(out)).toBe(true)
		end)

		it("moves along the path in stage percentages with stepped legs", function()
			local out = css(plan(TWO, 1, 2))
			local path = keyframes(out, "tern-cat-travel-path-7")
			assert(path, "missing path")
			expect(path).toContain(
				"\t0% { left: calc(50% - 79px); top: 15px; transform: none; animation-timing-function: steps(1, end); }"
			)
			-- Leap: up to the apex (100 ms of 893), down to the landing.
			expect(path).toContain(
				"\t11.198% { left: calc(50% - 68px); top: 15px; transform: none; animation-timing-function: steps(2, end); }"
			)
			expect(path).toContain(
				"\t38.074% { left: calc(50% - 32px); top: 0%; transform: none; animation-timing-function: steps(2, end); }"
			)
			expect(path).toContain("\t100% { left: calc(100% - 79px); top: 15px; transform: none; }")
		end)

		it("holds the old facing up to a turn", function()
			local out = css(plan(GRID, 4, 1), { art = { walk = art().walk } })
			local path = keyframes(out, "tern-cat-travel-path-7")
			assert(path, "missing path")
			-- Turns from walking left onto its side at 893 of 1250 ms.
			expect(path).toContain(
				"\t71.439% { left: calc(50% - 79px); top: calc(50% + 15px); transform: scaleX(-1); animation-timing-function: step-end; }"
			)
			expect(path).toContain(
				"\t71.44% { left: calc(50% - 79px); top: calc(50% + 15px); transform: rotate(-90deg); animation-timing-function: steps(4, end); }"
			)
		end)

		it("uses the pack's climb upright when it has one", function()
			local down = plan(STACK, 1, 2, { position = "bottom-left" })
			expect(keyframes(css(down), "tern-cat-travel-path-7")).toContain("transform: scale(-1, -1);")
			expect(css(down)).toContain(CLIMB_URL)
			local walkOnly = css(down, { art = { walk = art().walk } })
			expect(keyframes(walkOnly, "tern-cat-travel-path-7")).toContain("transform: rotate(90deg);")
			expect(walkOnly).notToContain(CLIMB_URL)
		end)

		it("plays each leg's sheet, stretching the one-shot leap over its leg", function()
			local out = css(plan(TWO, 1, 2))
			local frames = keyframes(out, "tern-cat-travel-frames-7")
			assert(frames, "missing frames")
			expect(frames).toContain(
				`\t0% \{ background-image: url("{WALK_URL}"); background-size: 256px 64px; background-position: 0px 0px; }`
			)
			expect(frames).toContain(
				`\t11.198% \{ background-image: url("{LEAP_URL}"); background-size: 384px 64px; background-position: 0px 0px; }`
			)
			-- The leap's sixth (last) frame, 400 ms into it.
			expect(frames).toContain("\t55.991% { background-position: -320px 0px; }")
			expect(frames).notToContain("-384px")
			expect(frames).toContain(`url("{RUN_URL}")`)
			-- The run loops (70 ms frames) over its 313 ms: frames 1-4 then 1 again.
			expect(frames).toContain("\t96.305% { background-position: 0px 0px; }")
		end)

		it("falls back to the walk sheet for missing or unusable leg sheets", function()
			local a = art()
			a.leap = nil
			a.run = { sheet_url = 'data:image/png;base64,AAAA"); } body { color: red', durations_ms = { 70 } }
			local out = css(plan(TWO, 1, 2), { art = a })
			expect(out).notToContain(LEAP_URL)
			expect(out).notToContain("color: red")
			expect(out).toContain(WALK_URL)
			expect(balanced(out)).toBe(true)
		end)

		it("gives up (nil) without a usable walk sheet", function()
			local trip = plan(TWO, 1, 2)
			expect(travel.css({ trip = trip, id = 1, art = { walk = { sheet_url = "javascript:alert(1)" } } } :: any)).toBeNil()
			expect(travel.css({ trip = trip, id = 1, art = {} } :: any)).toBeNil()
		end)

		it("keeps keyframe names constant per trip id", function()
			local trip = plan(TWO, 1, 2)
			expect(css(trip, { id = 3 })).toBe(css(trip, { id = 3 }))
			local again = css(trip, { id = 4 })
			expect(again).toContain("tern-cat-travel-path-4")
			expect(again).notToContain("tern-cat-travel-path-3")
			expect(css(trip, { id = "1; } x {" })).toContain("tern-cat-travel-path-0 ")
			expect(css(trip, { id = 2.6 })).toContain("tern-cat-travel-path-3 ")
		end)

		it("drops hold entries that could escape the rule", function()
			local out = css(plan(TWO, 1, 2), {
				hold = {
					"evil 1s; } body { color: red",
					'quote"1s',
					"paren( 1s",
					")( 1s",
					"ok-1 520ms steps(4, end) infinite",
					string.rep("a", 201),
				},
			})
			local hold = block(out, HOLD)
			assert(hold, "missing hold")
			expect(hold).toContain("animation: ok-1 520ms steps(4, end) infinite, tern-cat-travel-hold-7 893ms")
			expect(out).notToContain("evil")
			expect(out).notToContain("quote")
			expect(out).notToContain("paren")
			expect(out).notToContain(string.rep("a", 201))
			expect(balanced(out)).toBe(true)
		end)

		it("sanitizes the frame durations and z", function()
			local a = art()
			a.walk = { sheet_url = WALK_URL, durations_ms = { 0 / 0, -5, 1e12 }, animation = "<walk>" }
			local out = css(plan(TWO, 1, 2), { art = a, z = "top" })
			expect(out).toContain("z-index: 2147483000;")
			expect(out).notToContain("nan")
			expect(out).notToContain("inf")
			expect(out).notToContain("<walk>")
			expect(balanced(out)).toBe(true)
		end)

		it("stops the traveler and the hold under reduced motion", function()
			local out = css(plan(TWO, 1, 2))
			expect(out).toContain("@media (prefers-reduced-motion: reduce) {")
			expect(out).toContain("\tdiv.tn-stage::after { display: none; animation: none !important; }")
			expect(out).toContain(`\t{HOLD} \{ animation: none !important; }`)
		end)

		it("installs the empty sheet with reduced motion or nothing to travel", function()
			local trip = plan(TWO, 1, 2)
			expect(css(trip, { reduced = true })).toBe(travel.EMPTY)
			local still = table.clone(trip)
			still.legs = {}
			still.total_ms = 0
			expect(css(still)).toBe(travel.EMPTY)
			expect(travel.css(nil :: any)).toBe(travel.EMPTY)
			expect(travel.EMPTY).toBe("/* tern-cat travel */\n")
		end)
	end)
end)
