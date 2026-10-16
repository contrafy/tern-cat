--!strict
-- Pane travel planner (pure). With `rendering.pane_transition` = `walk` (or `auto` between panes
-- that share an edge) the overlay cat travels from its resting corner in the pane that loses focus
-- to its corner in the pane that gains it: along the start's row, leaping over every vertical
-- divider on the way, then climbing along the destination corner's column (across horizontal
-- dividers). A diagonal trip is those two legs.
--
-- Tern 0.8.3 tiles `div.tn-stage` exactly by the split ratios of `cx.session:layout(tab)`, so a
-- point is a stage percentage plus a CSS px offset (`calc(X% + Npx)` on the stage's pseudo) and no
-- pixel size is needed. The traveler is drawn on `div.tn-stage::after` (spans every pane, drawn
-- above dividers, clipped only by the panel) by a sheet installed per switch; the same sheet hides
-- every unfocused pane's cat and holds the focused pane's cat hidden until the traveler arrives,
-- so the hand-off is frame exact. The main overlay sheet keeps the old pane's cat for
-- `LINGER_MS` and the new pane's cat away for `ARRIVE_MS`, which hides the Lua latency of the
-- switch. Zoomed tabs, floating panes and unknown panes get no trip (the caller uses the portal).
-- Every interpolated value is sanitized like cat/render/overlay.luau.

local manifest = require("../sprite/manifest")
local animations = require("./animations")

-- A `cx.session:layout(tab)` split tree: a pane at a leaf; [1] left/top and [2] right/bottom.
export type Tree = { pane: number?, split: string?, ratio: number?, [number]: Tree }
export type Layout = { root: Tree, zoomed: boolean?, floats: { any }? }

-- Stage fractions (0..1).
export type Rect = { x: number, y: number, w: number, h: number }

-- `left: calc(xp% + xo px); top: calc(yp% + yo px)` of the cat's box in the stage.
export type Point = { xp: number, xo: number, yp: number, yo: number }

export type Corner = "top-right" | "top-left" | "bottom-right" | "bottom-left"

-- Where the in-pane cat's host starts inside its pane, in CSS px: the layout's pane padding and
-- the pane header's height (0 without one).
export type Insets = { pad: number, header: number }

export type LegKind = "walk" | "run" | "climb" | "leap"
export type Direction = "left" | "right" | "up" | "down"

-- One leg of a trip. A leap is two segments of `ms / 2` (up to `apex`, then down to `to`), each
-- with `steps` steps; every other leg is one segment of `ms` with `steps` steps.
export type Leg = {
	kind: LegKind,
	dir: Direction,
	from: Point,
	to: Point,
	apex: Point?,
	start_ms: number,
	ms: number,
	steps: number,
}

export type Trip = {
	from: number,
	to: number,
	corner: Corner,
	-- Side of the cat the climbing wall is on (the corner's side of the pane).
	wall: "left" | "right",
	box_w: number,
	box_h: number,
	start: Point,
	finish: Point,
	legs: { Leg },
	total_ms: number,
	-- The two panes share an edge (`auto` walks only then).
	adjacent: boolean,
}

export type PlanInput = {
	layout: Layout,
	from: number,
	to: number,
	-- `rendering.overlay_position` (default top-right).
	position: Corner?,
	-- The in-pane cat's gap from the corner's edges in CSS px (default 12); `offset_v_px` overrides
	-- the vertical gap when it differs (a portal prop lifts the cat).
	offset_px: number?,
	offset_v_px: number?,
	-- The cat's box in CSS px (frame size x scale).
	box_w: number,
	box_h: number,
	insets: Insets?,
	-- Length of the pack's leap (or its fallback) in ms; clamped to LEAP_MIN_MS..LEAP_MAX_MS.
	leap_ms: number?,
	-- A switch during a trip: the new trip starts where the previous one has the cat after
	-- `elapsed_ms` (ignored once it has arrived).
	interrupt: { trip: Trip, elapsed_ms: number }?,
}

-- A leg's sprite strip: `animation` is the pack animation it resolved to (decides the climb's
-- rotation and whether the strip loops).
export type Sheet = { sheet_url: string, durations_ms: { number }, animation: string? }
export type Art = { walk: Sheet, run: Sheet?, climb: Sheet?, leap: Sheet? }

export type CssParams = {
	trip: Trip,
	-- Increases per switch: keyframe names are constant per trip, so reinstalling the same trip
	-- (the overlay sheet changed mid-travel) keeps every animation running.
	id: number,
	art: Art,
	-- The focused cat's current animation list in the overlay sheet (`name duration ...`
	-- entries); the hold rule repeats it so the decision keeps playing.
	hold: { string }?,
	z: number?,
	reduced: boolean?,
}

export type Timing = {
	-- Main sheet: an unfocused pane's cat stays this long after losing focus.
	linger_ms: number,
	-- Main sheet: the focused pane's cat appears this long after gaining focus.
	arrive_ms: number,
	-- Travel sheet: the focused pane's cat takes over from the traveler.
	arrival_ms: number,
	-- When the caller replaces the travel sheet with EMPTY.
	clear_ms: number,
}

local LINGER_MS = 150
local ARRIVE_MS = 80
local CLEAR_AFTER_MS = 200
local FPS = 10
-- Speeds in percent of the stage's width (walk, run) or height (climb) per second.
local WALK_PCT_S = 110
local RUN_PCT_S = 160
local CLIMB_PCT_S = 140
-- A horizontal stretch at least this long (percent of the stage width) is run.
local RUN_MIN_PCT = 40
-- Shortest leg (a few px between a corner and a take-off point).
local MIN_LEG_MS = 100
local LEAP_MIN_MS = 240
local LEAP_MAX_MS = 720
-- The cat takes off and lands this far from the divider (CSS px), and its arc rises this high.
local LEAP_MARGIN_PX = 4
local HOP_PX = 18
local DEFAULT_OFFSET = 12
local DEFAULT_Z = 2147483000
local MAX_DEPTH = 32
local MAX_HOLD = 8
local MAX_HOLD_BYTES = 200
local MAX_FRAME_STOPS = 600
local EPS = 1e-6
-- Keyframe offset (percent) that holds a value up to the next stop.
local STOP_EPS = 0.001

local EMPTY = "/* tern-cat travel */\n"
local STAGE = "div.tn-stage"
local TV = " > div.tn-body > div.tv > div.tv-fx.top::after"
-- Every unfocused pane's cat (the old pane's lingering one) goes as the traveler appears.
local HIDE = STAGE .. " > section.tn-pane:not(.on)" .. TV
-- The focused, visible pane's cat waits for the traveler; it and its pointer ring take no pointer
-- state meanwhile.
local HOLD = STAGE .. " > section.tn-pane.on:not(.off)" .. TV
local HOLD_RING = STAGE .. " > section.tn-pane.on:not(.off) > div.tn-body > div.tv > div.tv-fx.top::before"
local TRAVELER = STAGE .. "::after"
local DATA_PREFIX = "data:image/png;base64,"
local MAX_URL_BYTES = 4 * 1024 * 1024

type Side = { v: "top" | "bottom", h: "left" | "right" }
local CORNERS: { [string]: Side } = {
	["top-right"] = { v = "top", h = "right" },
	["top-left"] = { v = "top", h = "left" },
	["bottom-right"] = { v = "bottom", h = "right" },
	["bottom-left"] = { v = "bottom", h = "left" },
}
local DEFAULT_CORNER: Corner = "top-right"

-- Sanitizing and formatting (as in cat/render/overlay.luau) -------------------------------------

local function clampNumber(v: any, lo: number, hi: number, default: number): number
	if type(v) ~= "number" or v ~= v then
		return default
	end
	return math.clamp(v, lo, hi)
end

local function clampInt(v: any, lo: number, hi: number, default: number): number
	return math.floor(clampNumber(v, lo, hi, default) + 0.5)
end

local function num(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		return "0"
	end
	if n == math.floor(n) then
		return string.format("%d", n)
	end
	local s = string.format("%.3f", n)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
	if s == "-0" then
		return "0"
	end
	return s
end

local function px(n: number): string
	return num(n) .. "px"
end

local function ms(n: number): string
	return num(n) .. "ms"
end

local function safeUrl(v: any): string?
	if type(v) ~= "string" or #v > MAX_URL_BYTES then
		return nil
	end
	if string.sub(v, 1, #DATA_PREFIX) == DATA_PREFIX then
		local payload = string.sub(v, #DATA_PREFIX + 1)
		if #payload > 0 and string.match(payload, "^[A-Za-z0-9+/]+=*$") then
			return v
		end
		return nil
	end
	if manifest.isSafePath(v) then
		return v
	end
	return nil
end

local function safeDurations(v: any): { number }
	local durations: { number } = {}
	if type(v) == "table" then
		for i = 1, math.min(#v, manifest.LIMITS.frames_max) do
			durations[i] = clampInt(v[i], manifest.LIMITS.duration_min_ms, manifest.LIMITS.duration_max_ms, 100)
		end
	end
	if #durations == 0 then
		durations[1] = 100
	end
	return durations
end

local function totalMs(durations: { number }): number
	local total = 0
	for _, d in durations do
		total += d
	end
	return total
end

type SafeSheet = { url: string, durations: { number }, animation: string }

local function safeSheet(v: any, default: string): SafeSheet?
	if type(v) ~= "table" then
		return nil
	end
	local url = safeUrl(v.sheet_url)
	if not url then
		return nil
	end
	local anim = if animations.isCanonical(v.animation) then v.animation :: string else default
	return { url = url, durations = safeDurations(v.durations_ms), animation = anim }
end

-- `name 520ms steps(4, end) infinite`-style entries only: nothing that could close the rule.
local function safeHold(v: any): { string }
	local out: { string } = {}
	if type(v) ~= "table" then
		return out
	end
	for i = 1, math.min(#v, MAX_HOLD) do
		local s = v[i]
		if type(s) == "string" and #s <= MAX_HOLD_BYTES and string.match(s, "^[%w%-%. %(%),]+$") then
			local depth = 0
			for c in string.gmatch(s, "[%(%)]") do
				depth += if c == "(" then 1 else -1
				if depth < 0 then
					break
				end
			end
			if depth == 0 then
				table.insert(out, s)
			end
		end
	end
	return out
end

-- Layout -----------------------------------------------------------------------------------------

local function walkTree(node: any, r: Rect, out: { [number]: Rect }, depth: number): boolean
	if type(node) ~= "table" or depth > MAX_DEPTH then
		return false
	end
	if node.pane ~= nil then
		local id = node.pane
		if type(id) ~= "number" or out[id] ~= nil then
			return false
		end
		out[id] = r
		return true
	end
	local ratio = if node.ratio == nil then 0.5 else node.ratio
	if type(ratio) ~= "number" or not (ratio > 0 and ratio < 1) then
		return false
	end
	if node.split == "right" then
		local w1 = r.w * ratio
		return walkTree(node[1], { x = r.x, y = r.y, w = w1, h = r.h }, out, depth + 1)
			and walkTree(node[2], { x = r.x + w1, y = r.y, w = r.w - w1, h = r.h }, out, depth + 1)
	elseif node.split == "down" then
		local h1 = r.h * ratio
		return walkTree(node[1], { x = r.x, y = r.y, w = r.w, h = h1 }, out, depth + 1)
			and walkTree(node[2], { x = r.x, y = r.y + h1, w = r.w, h = r.h - h1 }, out, depth + 1)
	end
	return false
end

-- Every tiled pane's rectangle in stage fractions; nil for a malformed tree.
local function rects(layout: any): { [number]: Rect }?
	if type(layout) ~= "table" then
		return nil
	end
	local out: { [number]: Rect } = {}
	if not walkTree(layout.root, { x = 0, y = 0, w = 1, h = 1 }, out, 0) then
		return nil
	end
	return out
end

local function near(a: number, b: number): boolean
	return math.abs(a - b) <= EPS
end

local function overlaps(a0: number, a1: number, b0: number, b1: number): boolean
	return math.min(a1, b1) - math.max(a0, b0) > EPS
end

local function touching(a: Rect, b: Rect): boolean
	local besideX = (near(a.x + a.w, b.x) or near(b.x + b.w, a.x)) and overlaps(a.y, a.y + a.h, b.y, b.y + b.h)
	local besideY = (near(a.y + a.h, b.y) or near(b.y + b.h, a.y)) and overlaps(a.x, a.x + a.w, b.x, b.x + b.w)
	return besideX or besideY
end

-- Whether two tiled panes share an edge; nil when either is not tiled in `layout`.
local function neighbors(layout: any, a: number, b: number): boolean?
	local rs = rects(layout)
	if rs == nil or rs[a] == nil or rs[b] == nil or a == b then
		return nil
	end
	return touching(rs[a], rs[b])
end

-- Path ---------------------------------------------------------------------------------------------

type Frame = { side: Side, boxW: number, boxH: number, gapH: number, gapV: number, pad: number, header: number }

local function cornerPoint(r: Rect, f: Frame): Point
	local p: Point = { xp = 0, xo = 0, yp = 0, yo = 0 }
	if f.side.h == "right" then
		p.xp, p.xo = (r.x + r.w) * 100, -(f.pad + f.gapH + f.boxW)
	else
		p.xp, p.xo = r.x * 100, f.pad + f.gapH
	end
	if f.side.v == "bottom" then
		p.yp, p.yo = (r.y + r.h) * 100, -(f.pad + f.gapV + f.boxH)
	else
		p.yp, p.yo = r.y * 100, f.pad + f.header + f.gapV
	end
	return p
end

-- -1, 0 or 1: `a` before, at or after `b` along one axis. Panes are far wider than the px
-- offsets, so the percentage decides unless both share it.
local function order(ap: number, ao: number, bp: number, bo: number): number
	if math.abs(ap - bp) > EPS then
		return if ap < bp then -1 else 1
	end
	if math.abs(ao - bo) > EPS then
		return if ao < bo then -1 else 1
	end
	return 0
end

local function orderX(a: Point, b: Point): number
	return order(a.xp, a.xo, b.xp, b.xo)
end

local function orderY(a: Point, b: Point): number
	return order(a.yp, a.yo, b.yp, b.yo)
end

-- Vertical dividers (stage fractions) between `a` and `b` along the row the cat walks at `a`, in
-- travel order.
local function dividers(rs: { [number]: Rect }, a: Point, b: Point): { number }
	local row = a.yp / 100 + (if a.yo > 0 then 1e-4 elseif a.yo < 0 then -1e-4 else 0)
	local seen: { [number]: number } = {}
	for _, r in rs do
		if row > r.y + EPS and row < r.y + r.h - EPS then
			for _, e in { r.x, r.x + r.w } do
				if e > EPS and e < 1 - EPS then
					local sa = order(a.xp, a.xo, e * 100, 0)
					local sb = order(b.xp, b.xo, e * 100, 0)
					if sa * sb < 0 then
						seen[math.floor(e * 1e6 + 0.5)] = e
					end
				end
			end
		end
	end
	local list: { number } = {}
	for _, e in seen do
		table.insert(list, e)
	end
	local rightward = orderX(b, a) > 0
	table.sort(list, function(x: number, y: number): boolean
		return if rightward then x < y else x > y
	end)
	return list
end

local function stepsFor(legMs: number): number
	return math.max(1, math.floor(legMs * FPS / 1000 + 0.5))
end

local function legMs(distPct: number, speed: number): number
	return math.max(MIN_LEG_MS, math.floor(distPct / speed * 1000 + 0.5))
end

type Builder = { legs: { Leg }, t: number }

local function addLeg(b: Builder, kind: LegKind, dir: Direction, from: Point, to: Point, length: number, apex: Point?)
	table.insert(b.legs, {
		kind = kind,
		dir = dir,
		from = from,
		to = to,
		apex = apex,
		start_ms = b.t,
		ms = length,
		steps = stepsFor(if apex then length / 2 else length),
	})
	b.t += length
end

local function walkTo(b: Builder, from: Point, to: Point)
	local dir = orderX(to, from)
	if dir == 0 then
		return
	end
	local dist = math.abs(to.xp - from.xp)
	local run = dist >= RUN_MIN_PCT
	addLeg(
		b,
		if run then "run" else "walk",
		if dir > 0 then "right" else "left",
		from,
		to,
		legMs(dist, if run then RUN_PCT_S else WALK_PCT_S)
	)
end

local function at(xp: number, xo: number, yp: number, yo: number): Point
	return { xp = xp, xo = xo, yp = yp, yo = yo }
end

local function build(rs: { [number]: Rect }, start: Point, finish: Point, f: Frame, leapMs: number): Builder
	local b: Builder = { legs = {}, t = 0 }
	local cur = start
	local dir = orderX(finish, start)
	if dir ~= 0 then
		local side: Direction = if dir > 0 then "right" else "left"
		for _, e in dividers(rs, start, finish) do
			local edge = e * 100
			local before = at(edge, if dir > 0 then -(f.boxW + LEAP_MARGIN_PX) else LEAP_MARGIN_PX, cur.yp, cur.yo)
			if orderX(before, cur) * dir > 0 then
				walkTo(b, cur, before)
				cur = before
			end
			local land = at(edge, if dir > 0 then LEAP_MARGIN_PX else -(f.boxW + LEAP_MARGIN_PX), cur.yp, cur.yo)
			local top = cur.yo - HOP_PX
			if cur.yp <= EPS and top < 0 then
				-- Stay inside the panel (it clips the stage's top edge).
				top = math.min(0, cur.yo)
			end
			local apex = at(edge, -f.boxW / 2, cur.yp, top)
			addLeg(b, "leap", side, cur, land, leapMs, apex)
			cur = land
		end
		local stop = at(finish.xp, finish.xo, cur.yp, cur.yo)
		walkTo(b, cur, stop)
		cur = stop
	end
	local up = orderY(finish, cur)
	if up ~= 0 then
		addLeg(
			b,
			"climb",
			if up > 0 then "down" else "up",
			cur,
			finish,
			legMs(math.abs(finish.yp - cur.yp), CLIMB_PCT_S)
		)
	end
	return b
end

type Segment = { leg: Leg, from: Point, to: Point, start: number, ms: number, steps: number }

local function segments(trip: Trip): { Segment }
	local out: { Segment } = {}
	for _, leg in trip.legs do
		local apex = leg.apex
		if apex then
			local half = leg.ms / 2
			table.insert(
				out,
				{ leg = leg, from = leg.from, to = apex, start = leg.start_ms, ms = half, steps = leg.steps }
			)
			table.insert(
				out,
				{ leg = leg, from = apex, to = leg.to, start = leg.start_ms + half, ms = half, steps = leg.steps }
			)
		else
			table.insert(
				out,
				{ leg = leg, from = leg.from, to = leg.to, start = leg.start_ms, ms = leg.ms, steps = leg.steps }
			)
		end
	end
	return out
end

local function lerp(a: Point, b: Point, k: number): Point
	return {
		xp = a.xp + (b.xp - a.xp) * k,
		xo = a.xo + (b.xo - a.xo) * k,
		yp = a.yp + (b.yp - a.yp) * k,
		yo = a.yo + (b.yo - a.yo) * k,
	}
end

-- Where the traveler is `elapsed` ms into `trip`, stepped exactly like its CSS; nil once it has
-- arrived (the cat rests in the destination pane).
local function positionAt(trip: Trip, elapsed: number): Point?
	if type(trip) ~= "table" or type(elapsed) ~= "number" or elapsed ~= elapsed then
		return nil
	end
	if elapsed >= trip.total_ms then
		return nil
	end
	if elapsed <= 0 then
		return trip.start
	end
	for _, s in segments(trip) do
		if elapsed < s.start + s.ms then
			local k = math.floor((elapsed - s.start) / s.ms * s.steps) / s.steps
			return lerp(s.from, s.to, k)
		end
	end
	return nil
end

-- The trip from `from`'s corner (or the interrupted traveler) to `to`'s corner; nil when the tab
-- is zoomed, either pane is not tiled in `layout` (floating, closed, another tab) or they are the
-- same pane.
local function plan(input: PlanInput): Trip?
	if type(input) ~= "table" or type(input.layout) ~= "table" or input.layout.zoomed == true then
		return nil
	end
	local from, to = input.from, input.to
	if type(from) ~= "number" or type(to) ~= "number" or from == to then
		return nil
	end
	local rs = rects(input.layout)
	if rs == nil or rs[from] == nil or rs[to] == nil then
		return nil
	end
	local corner: Corner = if type(input.position) == "string" and CORNERS[input.position]
		then input.position
		else DEFAULT_CORNER
	local insets = if type(input.insets) == "table" then input.insets else {} :: any
	local gap = clampNumber(input.offset_px, 0, 4096, DEFAULT_OFFSET)
	local f: Frame = {
		side = CORNERS[corner],
		boxW = clampNumber(input.box_w, 1, 2048, 32),
		boxH = clampNumber(input.box_h, 1, 2048, 32),
		gapH = gap,
		gapV = clampNumber(input.offset_v_px, 0, 4096, gap),
		pad = clampNumber(insets.pad, 0, 200, 0),
		header = clampNumber(insets.header, 0, 200, 0),
	}
	local start = cornerPoint(rs[from], f)
	local interrupt = input.interrupt
	if type(interrupt) == "table" and type(interrupt.trip) == "table" then
		start = positionAt(interrupt.trip, interrupt.elapsed_ms) or start
	end
	local finish = cornerPoint(rs[to], f)
	local leapMs = clampNumber(input.leap_ms, LEAP_MIN_MS, LEAP_MAX_MS, animations.defaultDurationMs("leap"))
	leapMs = 2 * math.floor(leapMs / 2 + 0.5)
	local b = build(rs, start, finish, f, leapMs)
	return {
		from = from,
		to = to,
		corner = corner,
		wall = f.side.h,
		box_w = f.boxW,
		box_h = f.boxH,
		start = start,
		finish = finish,
		legs = b.legs,
		total_ms = b.t,
		adjacent = touching(rs[from], rs[to]),
	}
end

-- What Tern's settings say about the in-pane cat's host (Tern 0.8.3, measured with `ctl dump`):
-- `layout`, `density`, `pane_headers` and the interface size (`ui_font_size`, else `font_size`).
export type InsetSettings = { layout: string?, density: string?, pane_headers: string?, ui_size: number? }

local TERN_UI_PX = 13
local HEADER_PX = 30

-- The pane padding (Islands 4 px, Compact tiles 3 px, other Compact layouts 0) and the header a
-- split pane wears unless `pane_headers` is Never (30 px at a 13 px interface, scaled with it).
-- Unknown values take Tern's defaults (Tiles, Compact, Never, 13 px).
local function insets(s: InsetSettings): Insets
	local layout = if type(s) == "table" and type(s.layout) == "string" then s.layout else "Tiles"
	local density = if type(s) == "table" then s.density else nil
	local headers = if type(s) == "table" then s.pane_headers else nil
	local size = if type(s) == "table" then s.ui_size else nil
	if type(size) ~= "number" or not (size >= 8 and size <= 32) then
		size = TERN_UI_PX
	end
	local pad = if density == "Islands"
		then 4
		elseif layout == "Rail" or layout == "Float" or layout == "Studio" then 0
		else 3
	local header = if headers == "Split" or headers == "Always" then HEADER_PX * (size :: number) / TERN_UI_PX else 0
	return { pad = pad, header = header }
end

local function timing(trip: Trip?): Timing
	local arrival = if type(trip) == "table" then trip.total_ms else 0
	return {
		linger_ms = LINGER_MS,
		arrive_ms = ARRIVE_MS,
		arrival_ms = arrival,
		clear_ms = arrival + CLEAR_AFTER_MS,
	}
end

-- CSS ------------------------------------------------------------------------------------------------

-- The sprite faces right and stands on its feet; a climbing pack draws `climb` head up with the
-- wall on its right. Without one, the walk is turned on its side (feet to the wall).
local function transform(leg: Leg, wall: "left" | "right", resolved: string): string
	if leg.kind == "climb" then
		local up = leg.dir == "up"
		if resolved == "climb" then
			if wall == "right" then
				return if up then "none" else "scaleY(-1)"
			end
			return if up then "scaleX(-1)" else "scale(-1, -1)"
		end
		if wall == "right" then
			return if up then "rotate(-90deg)" else "rotate(90deg) scaleY(-1)"
		end
		return if up then "rotate(-90deg) scaleY(-1)" else "rotate(90deg)"
	end
	return if leg.dir == "left" then "scaleX(-1)" else "none"
end

local function calc(p: number, o: number): string
	local pct = clampNumber(p, -100, 200, 0)
	local off = clampNumber(o, -8192, 8192, 0)
	if off == 0 then
		return `{num(pct)}%`
	elseif pct == 0 then
		return px(off)
	end
	return `calc({num(pct)}% {if off < 0 then "-" else "+"} {px(math.abs(off))})`
end

local function place(p: Point): string
	return `left: {calc(p.xp, p.xo)}; top: {calc(p.yp, p.yo)};`
end

local function pct(t: number, total: number): number
	return math.clamp(t / total * 100, 0, 100)
end

type Sheets = { [LegKind]: SafeSheet }

local function pathKeyframes(name: string, trip: Trip, sheets: Sheets): string
	local lines = { `@keyframes {name} \{` }
	local total = trip.total_ms
	local prevTf: string? = nil
	local last: Point = trip.start
	for _, s in segments(trip) do
		local tf = transform(s.leg, trip.wall, sheets[s.leg.kind].animation)
		local at0 = pct(s.start, total)
		if prevTf and prevTf ~= tf and at0 > STOP_EPS then
			-- The previous leg's facing holds up to the turn.
			table.insert(
				lines,
				`\t{num(at0 - STOP_EPS)}% \{ {place(s.from)} transform: {prevTf}; animation-timing-function: step-end; }`
			)
		end
		table.insert(
			lines,
			`\t{num(at0)}% \{ {place(s.from)} transform: {tf}; animation-timing-function: steps({s.steps}, end); }`
		)
		prevTf = tf
		last = s.to
	end
	table.insert(lines, `\t100% \{ {place(last)} transform: {prevTf or "none"}; }`)
	table.insert(lines, "}")
	return table.concat(lines, "\n")
end

-- One step-end strip over the whole trip: each leg starts its own sheet on its first frame. A
-- loop cycles for as long as the leg lasts; a one-shot (the leap) is stretched to fit it.
local function frameKeyframes(name: string, trip: Trip, sheets: Sheets): string
	local lines = { `@keyframes {name} \{` }
	local total = trip.total_ms
	local boxW, boxH = trip.box_w, trip.box_h
	local stops = 0
	local lastImage = ""
	local lastPos = "0px"
	for _, leg in trip.legs do
		local sheet = sheets[leg.kind]
		local n = #sheet.durations
		local image = `background-image: url("{sheet.url}"); background-size: {px(boxW * n)} {px(boxH)}; `
		local loop = animations.isLoop(sheet.animation)
		local stretch = if loop then 1 else leg.ms / totalMs(sheet.durations)
		local t = 0
		local j = 1
		local pos = "0px"
		while t < leg.ms - 0.5 do
			if t > 0 and stops >= MAX_FRAME_STOPS then
				break
			end
			pos = px(-(j - 1) * boxW)
			local head = if t == 0 then image else ""
			table.insert(lines, `\t{num(pct(leg.start_ms + t, total))}% \{ {head}background-position: {pos} 0px; }`)
			stops += 1
			t += sheet.durations[j] * stretch
			if j == n and not loop then
				break
			end
			j = j % n + 1
		end
		local finish = pct(leg.start_ms + leg.ms, total) - STOP_EPS
		if finish > pct(leg.start_ms, total) then
			-- Repeats the sheet at the leg's end so it never changes mid-leg.
			table.insert(lines, `\t{num(finish)}% \{ {image}background-position: {pos} 0px; }`)
		end
		lastImage, lastPos = image, pos
	end
	table.insert(lines, `\t100% \{ {lastImage}background-position: {lastPos} 0px; }`)
	table.insert(lines, "}")
	return table.concat(lines, "\n")
end

-- The per-switch sheet: EMPTY under reduced motion, for a trip without legs, and nil when the
-- walk sheet is unusable (the caller uses the portal).
local function css(params: CssParams): string?
	if type(params) ~= "table" or params.reduced == true then
		return EMPTY
	end
	local trip = params.trip
	if type(trip) ~= "table" or type(trip.legs) ~= "table" or #trip.legs == 0 or not (trip.total_ms > 0) then
		return EMPTY
	end
	local art = if type(params.art) == "table" then params.art else {} :: any
	local walk = safeSheet(art.walk, "walk")
	if walk == nil then
		return nil
	end
	local sheets: Sheets = {
		walk = walk,
		run = safeSheet(art.run, "run") or walk,
		climb = safeSheet(art.climb, "climb") or walk,
		leap = safeSheet(art.leap, "leap") or walk,
	}
	local id = string.format("%d", clampInt(params.id, 0, 2 ^ 31 - 1, 0))
	local holdName = `tern-cat-travel-hold-{id}`
	local pathName = `tern-cat-travel-path-{id}`
	local framesName = `tern-cat-travel-frames-{id}`
	local visName = `tern-cat-travel-vis-{id}`
	local total = ms(trip.total_ms)
	local z = clampInt(params.z, 0, 2147483647, DEFAULT_Z)
	local hold = safeHold(params.hold)
	table.insert(hold, `{holdName} {total} step-end 1 backwards`)

	return table.concat({
		`/* tern-cat travel {id} */`,
		`{HIDE} \{ visibility: hidden !important; transition: none !important; }`,
		`{HOLD} \{ animation: {table.concat(hold, ", ")}; pointer-events: none; }`,
		`{HOLD_RING} \{ pointer-events: none; }`,
		`{TRAVELER} \{`,
		'\tcontent: "";',
		"\tposition: absolute;",
		"\tleft: 0px;",
		"\ttop: 0px;",
		`\twidth: {px(trip.box_w)};`,
		`\theight: {px(trip.box_h)};`,
		"\tpointer-events: none;",
		`\tz-index: {num(z)};`,
		"\timage-rendering: pixelated;",
		"\tbackground-repeat: no-repeat;",
		"\topacity: 0;",
		`\tanimation: {pathName} {total} linear 1 both, {framesName} {total} step-end 1 both, {visName} {total} step-end 1 both;`,
		"}",
		`@keyframes {holdName} \{ 0% \{ opacity: 0; } 100% \{ opacity: 0; } }`,
		`@keyframes {visName} \{ 0% \{ opacity: 1; } 100% \{ opacity: 0; } }`,
		pathKeyframes(pathName, trip, sheets),
		frameKeyframes(framesName, trip, sheets),
		"@media (prefers-reduced-motion: reduce) {",
		`\t{TRAVELER} \{ display: none; animation: none !important; }`,
		`\t{HOLD} \{ animation: none !important; }`,
		"}",
	}, "\n") .. "\n"
end

return {
	plan = plan,
	css = css,
	rects = rects,
	neighbors = neighbors,
	positionAt = positionAt,
	timing = timing,
	insets = insets,
	transform = transform,
	EMPTY = EMPTY,
	HIDE = HIDE,
	HOLD = HOLD,
	TRAVELER = TRAVELER,
	LINGER_MS = LINGER_MS,
	ARRIVE_MS = ARRIVE_MS,
	CLEAR_AFTER_MS = CLEAR_AFTER_MS,
	FPS = FPS,
}
