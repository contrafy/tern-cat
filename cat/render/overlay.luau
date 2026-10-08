--!strict
-- Window overlay stylesheet generator (pure). The sheet draws a sprite-sheet animation in one
-- corner of the focused pane. With reactions, the cat and an invisible proximity ring around it
-- take `:hover`/`:active` (Tern still delivers every click, drag and key to the terminal), so the
-- cat looks at a nearby pointer and swats when pressed; nothing about the pointer reaches Lua.
-- With a pane transition the cat dives into a prop in the pane that loses focus and climbs out
-- of one in the pane that gains it, in pure CSS (see docs/architecture.md). Every interpolated
-- value is sanitized so a hostile pack cannot inject CSS.

local manifest = require("../sprite/manifest")
local animationDefaults = require("./animations")

-- A reaction's sheet: same frame size as the main sheet (one pack).
export type Reaction = {
	sheet_url: string,
	durations_ms: { number },
	loop: boolean?,
}

-- Resting corner of the focused pane.
export type Corner = "top-right" | "top-left" | "bottom-right" | "bottom-left"

-- One layer of a prop timeline: a horizontal strip of `frame_w` x `frame_h` frames.
export type PropLayer = {
	sheet_url: string,
	durations_ms: { number },
}

-- A pane-switch prop drawn at the cat's scale. `anchor` is the point (prop pixels, edge
-- coordinates) that sits under the cat's feet: the bottom centre of the cat's frame.
export type Prop = {
	frame_w: number,
	frame_h: number,
	anchor: { number }?,
	enter: { back: PropLayer, front: PropLayer? },
	exit: { back: PropLayer, front: PropLayer? },
}

-- Pane-switch transition. `dive`/`emerge` are the pack's own sheets (same frame size as the main
-- sheet); without them the cat sinks into and rises out of the floor with a height clip.
export type Transition = {
	prop: Prop,
	dive: Reaction?,
	emerge: Reaction?,
}

export type Params = {
	sheet_url: string,
	frame_w: number,
	frame_h: number,
	durations_ms: { number },
	loop: boolean,
	scale: number,
	facing: "left" | "right",
	pace: boolean,
	hidden: boolean,
	anim_key: string,
	-- Reduced motion: show frame 0 without frame or pacing animation (and no transition).
	still: boolean?,
	z: number?,
	-- Resting corner (default top-right) and its gap from both edges in CSS px (default 12).
	position: Corner?,
	offset_px: number?,
	-- Pointer reactions: `hover` plays while the pointer is on the cat or its proximity ring,
	-- `press` while the button is down there (held briefly after release). Nil: no reactions,
	-- the cat takes no pointer state at all.
	reactions: { hover: Reaction?, press: Reaction? }?,
	-- Pane-switch transition; nil: the cat simply appears in the newly focused pane.
	transition: Transition?,
}

-- Panes in hidden tabs and sessions keep `.on` and gain `.off` (display:none); `:not(.off)` makes
-- the focused pane's rules match anew, and so restart their animations, on every tab and
-- session switch.
local PANE = "section.tn-pane"
local ON = "section.tn-pane.on:not(.off)"
local TV = " > div.tn-body > div.tv"
-- Tern's top effects layer (`position:absolute; inset:0; pointer-events:none`) in the focused
-- pane's terminal view. Its `:hover` is local to its own pseudo-elements.
local HOST = ON .. TV .. " > div.tv-fx.top"
local SELECTOR = HOST .. "::after"
local RING = HOST .. "::before"
local HOVER = HOST .. ":hover::after"
local PRESS = HOST .. ":active::after"
local PRESS_RING = HOST .. ":active::before"
-- The cat on every pane: the dive's end state, reached by transitions on the pane that loses focus.
local EVERY = PANE .. TV .. " > div.tv-fx.top::after"
-- Back prop: the grid's effects layer (under the cat; the grid box starts at the terminal's
-- padding, `--tv-px`/`--tv-py`, and ends `--tv-aside` short of the right edge).
local BACK = PANE .. TV .. " > div.tv-grid > div.tv-fx::after"
local BACK_ON = ON .. TV .. " > div.tv-grid > div.tv-fx::after"
-- Front prop: Tern's layer over the whole view (above the cat).
local FRONT = PANE .. TV .. " > div.tv-layer::after"
local FRONT_ON = ON .. TV .. " > div.tv-layer::after"
-- Constant names: rules that change the cat's animation list repeat them, so a decision change,
-- hover or press never replays the emerge (animations are matched by name).
local EMERGE = "tern-cat-emerge"
local EMERGE_RING = "tern-cat-emerge-ring"
local PROP_BACK = "tern-cat-prop-back"
local PROP_FRONT = "tern-cat-prop-front"

local HIDDEN_SHEET = "/* tern-cat overlay hidden */\n"
local DATA_PREFIX = "data:image/png;base64,"
local MAX_URL_BYTES = 4 * 1024 * 1024
local DEFAULT_Z = 2147483000
local DEFAULT_OFFSET = 12
type Side = { v: "top" | "bottom", h: "left" | "right" }
local CORNERS: { [string]: Side } = {
	["top-right"] = { v = "top", h = "right" },
	["top-left"] = { v = "top", h = "left" },
	["bottom-right"] = { v = "bottom", h = "right" },
	["bottom-left"] = { v = "bottom", h = "left" },
}
local DEFAULT_CORNER = "top-right"
-- Pacing walks along the corner's horizontal edge into the pane and back.
local PACE_PX = 160
local PACE_STEP_PX = 8
local PACE_SPEED_PX_S = 40
-- Proximity ring margin around the cat box (CSS px).
local RING_PX = 48
-- How long the swat pose stays after the button is released.
local PRESS_HOLD_MS = 700
-- Height-clip fallback for packs without dive/emerge: at most this many steps.
local CLIP_STEPS = 8
-- The fallback emerge stays below the floor for its first quarter (the prop opens), rises over
-- the next half and stands for the last quarter.
local RISE_START_PCT = 25
local RISE_PCT = 50

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
	if n == math.floor(n) then
		return string.format("%d", n)
	end
	local s = string.format("%.3f", n)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
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

local function safeKey(v: any): string
	local key = if type(v) == "string" then string.gsub(string.lower(v), "[^a-z0-9%-]", "") else ""
	key = string.sub(key, 1, 48)
	if key == "" then
		return "anim"
	end
	return key
end

-- Stepped strip keyframes; `edge` (declarations ending in a space) is added to the first and the
-- last stop only, which holds discrete values such as the sheet over the whole animation.
local function stripKeyframes(name: string, durations: { number }, stepPx: number, edge: string?): string
	local total = 0
	for _, d in durations do
		total += d
	end
	local extra = edge or ""
	local lines = { `@keyframes {name} \{` }
	local elapsed = 0
	for i, d in durations do
		local pct = elapsed / total * 100
		local head = if i == 1 then extra else ""
		table.insert(lines, `\t{num(pct)}% \{ {head}background-position: {px(-(i - 1) * stepPx)} 0px; }`)
		elapsed += d
	end
	table.insert(lines, `\t100% \{ {extra}background-position: {px(-(#durations - 1) * stepPx)} 0px; }`)
	table.insert(lines, "}")
	return table.concat(lines, "\n")
end

local function frameKeyframes(name: string, durations: { number }, stepPx: number): string
	return stripKeyframes(name, durations, stepPx, nil)
end

-- `dir` is -1 from a right corner (the first leg walks left) and 1 from a left corner. The sprite
-- faces right unmirrored, so a leftward leg is mirrored.
local function paceKeyframes(name: string, steps: number, dir: number): string
	local far = px(dir * PACE_PX)
	local out = if dir < 0 then "-1" else "1"
	local back = if dir < 0 then "1" else "-1"
	return table.concat({
		`@keyframes {name} \{`,
		`\t0% \{ transform: translateX(0px) scaleX({out}); animation-timing-function: steps({steps}, end); }`,
		`\t48% \{ transform: translateX({far}) scaleX({out}); animation-timing-function: step-end; }`,
		`\t50% \{ transform: translateX({far}) scaleX({back}); animation-timing-function: steps({steps}, end); }`,
		`\t98% \{ transform: translateX(0px) scaleX({back}); animation-timing-function: step-end; }`,
		`\t100% \{ transform: translateX(0px) scaleX({back}); }`,
		"}",
	}, "\n")
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

type Sheet = { url: string, durations: { number }, loop: boolean }

local function safeReaction(v: any): Sheet?
	if type(v) ~= "table" then
		return nil
	end
	local url = safeUrl(v.sheet_url)
	if not url then
		return nil
	end
	return { url = url, durations = safeDurations(v.durations_ms), loop = v.loop == true }
end

type PropSpec = {
	w: number,
	h: number,
	ax: number,
	ay: number,
	enter_back: Sheet,
	enter_front: Sheet?,
	exit_back: Sheet,
	exit_front: Sheet?,
}

-- Nil unless both back layers are usable: a prop without them draws no transition at all.
local function safeProp(v: any): PropSpec?
	if type(v) ~= "table" then
		return nil
	end
	local enter = if type(v.enter) == "table" then v.enter else {} :: any
	local exit = if type(v.exit) == "table" then v.exit else {} :: any
	local enterBack = safeReaction(enter.back)
	local exitBack = safeReaction(exit.back)
	if enterBack == nil or exitBack == nil then
		return nil
	end
	local w = clampInt(v.frame_w, 8, 256, 48)
	local h = clampInt(v.frame_h, 8, 256, 24)
	local anchor = if type(v.anchor) == "table" then v.anchor else {} :: any
	return {
		w = w,
		h = h,
		ax = clampInt(anchor[1], 0, w, math.floor(w / 2)),
		ay = clampInt(anchor[2], 0, h, math.floor(h / 2)),
		enter_back = enterBack,
		enter_front = safeReaction(enter.front),
		exit_back = exitBack,
		exit_front = safeReaction(exit.front),
	}
end

local function animationValue(list: { string }): string
	return if #list > 0 then table.concat(list, ", ") else "none"
end

local function append(target: { string }, lines: { string })
	for _, line in lines do
		table.insert(target, line)
	end
end

-- Largest divisor of `frameH` up to CLIP_STEPS: every clip step is a whole number of sprite pixels.
local function clipSteps(frameH: number): number
	for k = CLIP_STEPS, 1, -1 do
		if frameH % k == 0 then
			return k
		end
	end
	return 1
end

-- Exit transition for one strip: steps evenly through its frames (transitions cannot honour
-- per-frame durations) and holds the last frame until `hold` ms, then `property` flips.
local function exitTransition(sheet: Sheet, holdMs: number, flip: string): string
	local n = #sheet.durations
	local frame = totalMs(sheet.durations) / n
	local flipPart = `{flip} 0s step-end {ms(holdMs)}`
	if n <= 1 then
		return flipPart
	end
	return `background-position {ms(frame * (n - 1))} steps({n - 1}, end), {flipPart}`
end

type Geometry = {
	side: Side,
	boxW: number,
	boxH: number,
	h: number,
	v: number,
	scale: number,
}

-- Position declarations for a prop host. `inset` adds the host's offset from the cat's host as a
-- CSS variable (the grid layer) or nothing (Tern's full-view layer).
local function propRules(
	g: Geometry,
	p: PropSpec,
	every: string,
	on: string,
	exit: Sheet?,
	enter: Sheet?,
	name: string,
	grid: boolean,
	blocks: { string }
): { string }
	local s = g.scale
	local pw = p.w * s
	local ph = p.h * s
	-- The prop's edges, measured from the corner's edges of the cat's host.
	local centre = g.h + g.boxW / 2
	local hEdge = if g.side.h == "right" then centre - (p.w - p.ax) * s else centre - p.ax * s
	local feet = g.v + g.boxH
	local vEdge = if g.side.v == "bottom" then g.v - (p.h - p.ay) * s else feet - p.ay * s
	local hValue = px(hEdge)
	local vValue = px(vEdge)
	if grid then
		local hVar = if g.side.h == "right" then "--tv-aside" else "--tv-px"
		hValue = `calc({px(hEdge)} - var({hVar}, 0px))`
		if g.side.v == "top" then
			vValue = `calc({px(vEdge)} - var(--tv-py, 0px))`
		end
	end
	local exitTotal = if exit then totalMs(exit.durations) else 0
	local enterTotal = if enter then totalMs(enter.durations) else 0
	local rules = {
		`{every} \{`,
		'\tcontent: "";',
		"\tposition: absolute;",
		`\t{g.side.h}: {hValue};`,
		`\t{g.side.v}: {vValue};`,
		`\twidth: {px(pw)};`,
		`\theight: {px(ph)};`,
		"\tpointer-events: none;",
		-- The layers are hidden while the pane shows a block; the prop's own exit still plays.
		"\tvisibility: visible;",
		"\timage-rendering: pixelated;",
		"\tbackground-repeat: no-repeat;",
	}
	if exit then
		append(rules, {
			`\tbackground-image: url("{exit.url}");`,
			`\tbackground-size: {px(pw * #exit.durations)} {px(ph)};`,
			`\tbackground-position: {px(-(#exit.durations - 1) * pw)} 0px;`,
			"\topacity: 0;",
			`\ttransition: {exitTransition(exit, exitTotal, "opacity")};`,
		})
	else
		table.insert(rules, "\topacity: 0;")
	end
	table.insert(rules, "}")
	append(rules, { `{on} \{` })
	if enter then
		table.insert(rules, `\tbackground-image: url("{enter.url}");`)
	end
	append(rules, {
		"\tbackground-size: 0px 0px;",
		"\tbackground-position: 0px 0px;",
		"\topacity: 1;",
		"\ttransition: none;",
	})
	if enter then
		table.insert(rules, `\tanimation: {name} {ms(enterTotal)} step-end 1;`)
		table.insert(
			blocks,
			stripKeyframes(name, enter.durations, pw, `background-size: {px(pw * #enter.durations)} {px(ph)}; `)
		)
	end
	table.insert(rules, "}")
	return rules
end

local function css(params: Params): string
	if type(params) ~= "table" or params.hidden == true then
		return HIDDEN_SHEET
	end
	local url = safeUrl(params.sheet_url)
	if not url then
		return HIDDEN_SHEET
	end

	local frameW = clampInt(params.frame_w, 1, 256, 32)
	local frameH = clampInt(params.frame_h, 1, 256, 32)
	local scale = math.floor(clampNumber(params.scale, 0.25, 8, 1) * 100 + 0.5) / 100
	local z = clampInt(params.z, 0, 2147483647, DEFAULT_Z)
	local side = CORNERS[if type(params.position) == "string" then params.position else DEFAULT_CORNER]
		or CORNERS[DEFAULT_CORNER]
	local gap = clampInt(params.offset_px, 0, 4096, DEFAULT_OFFSET)
	local durations = safeDurations(params.durations_ms)

	local key = safeKey(params.anim_key)
	local frameName = `tern-cat-{key}`
	local paceName = `tern-cat-pace-{key}`
	local boxW = frameW * scale
	local boxH = frameH * scale

	local still = params.still == true
	local transition = if type(params.transition) == "table" and not still then params.transition else nil
	local prop = if transition then safeProp(transition.prop) else nil
	-- Gaps from the corner's horizontal and vertical edges. A transition lifts the cat off the
	-- edges far enough for its prop to fit inside the pane (Tern clips the view).
	local gapH, gapV = gap, gap
	if prop then
		local reach = if side.h == "right" then prop.w - prop.ax else prop.ax
		gapH = math.max(gap, reach * scale - boxW / 2)
		if side.v == "bottom" then
			gapV = math.max(gap, (prop.h - prop.ay) * scale)
		else
			gapV = math.max(gap, prop.ay * scale - boxH)
		end
	end
	-- With a transition the cat's box keeps its bottom edge (the floor) fixed while its height
	-- clips it; at a top corner that edge is measured from the top through `100%`.
	local vertical = `{side.v}: {px(gapV)};`
	if prop and side.v == "top" then
		vertical = `bottom: calc(100% - {px(gapV + boxH)});`
	end

	local animations: { string } = {}
	local blocks: { string } = {}
	if #durations > 1 and not still then
		local iteration = if params.loop == true then "infinite" else "1 forwards"
		table.insert(animations, `{frameName} {totalMs(durations)}ms step-end {iteration}`)
		table.insert(blocks, frameKeyframes(frameName, durations, boxW))
	end
	-- Reaction rules repeat the pacing animation by name so a hover or press keeps the walk going.
	local pace: string? = nil
	if params.pace == true and not still then
		local steps = math.floor(PACE_PX / PACE_STEP_PX)
		local legMs = PACE_PX / PACE_SPEED_PX_S * 1000
		pace = `{paceName} {math.floor(legMs / 0.48 + 0.5)}ms step-end infinite`
		table.insert(animations, pace :: string)
		table.insert(blocks, paceKeyframes(paceName, steps, if side.h == "right" then -1 else 1))
	end

	local reactions = if type(params.reactions) == "table" then params.reactions else {} :: any
	local hover = safeReaction(reactions.hover)
	local press = safeReaction(reactions.press)
	local reactive = hover ~= nil or press ~= nil

	-- The emerge goes last: while it runs it wins over the decision for the properties it sets.
	local emerge: string? = nil
	local emergeRing: string? = nil
	local rule = { "/* tern-cat overlay */" }
	if prop then
		local tr = transition :: Transition
		local dive = safeReaction(tr.dive)
		local rise = safeReaction(tr.emerge)
		local diveMs = if dive then totalMs(dive.durations) else animationDefaults.defaultDurationMs("dive")
		local emergeMs = if rise then totalMs(rise.durations) else animationDefaults.defaultDurationMs("emerge")
		emerge = `{EMERGE} {ms(emergeMs)} step-end 1 backwards`
		table.insert(animations, emerge :: string)

		-- Every pane holds the dive's end state (no box). The pane that just lost focus
		-- transitions there from the focused pane's values; nothing fires at install or for a new
		-- pane, which starts in this state.
		local sheet = if dive then dive.url else url
		local frames = if dive then #dive.durations else #durations
		local last = if dive then -(#dive.durations - 1) * boxW else 0
		local diveTransition = if dive
			then exitTransition(dive, diveMs, "height")
			else `height {ms(diveMs)} steps({clipSteps(frameH)}, end)`
		append(rule, {
			`{EVERY} \{`,
			'\tcontent: "";',
			"\tposition: absolute;",
			`\t{side.h}: {px(gapH)};`,
			`\t{vertical}`,
			`\twidth: {px(boxW)};`,
			"\theight: 0px;",
			"\tpointer-events: none;",
			"\tvisibility: visible;",
			`\tz-index: {num(z)};`,
			"\timage-rendering: pixelated;",
			`\tbackground-image: url("{sheet}");`,
			"\tbackground-repeat: no-repeat;",
			`\tbackground-size: {px(boxW * frames)} {px(boxH)};`,
			`\tbackground-position: {px(last)} 0px;`,
		})
		if params.facing == "left" then
			table.insert(rule, "\ttransform: scaleX(-1);")
		end
		append(rule, { `\ttransition: {diveTransition};`, "}" })

		-- The emerge also holds the cat visible (`opacity`) so a press during it does not swap
		-- in the full-height swat frame; the ring's emerge hides that frame meanwhile.
		if rise then
			table.insert(
				blocks,
				stripKeyframes(
					EMERGE,
					rise.durations,
					boxW,
					`opacity: 1; background-image: url("{rise.url}"); background-size: {px(boxW * #rise.durations)} {px(
						boxH
					)}; `
				)
			)
		else
			local steps = clipSteps(frameH)
			local lines = { `@keyframes {EMERGE} \{`, "\t0% { opacity: 1; height: 0px; }" }
			for i = 1, steps do
				local pct = RISE_START_PCT + (i - 1) * RISE_PCT / steps
				table.insert(lines, `\t{num(pct)}% \{ height: {px(boxH * i / steps)}; }`)
			end
			append(lines, { `\t100% \{ opacity: 1; height: {px(boxH)}; }`, "}" })
			table.insert(blocks, table.concat(lines, "\n"))
		end
		if press then
			emergeRing = `{EMERGE_RING} {ms(emergeMs)} step-end 1 backwards`
			table.insert(
				blocks,
				table.concat({
					`@keyframes {EMERGE_RING} \{`,
					"\t0% { background-size: 0px 0px; }",
					"\t100% { background-size: 0px 0px; }",
					"}",
				}, "\n")
			)
		end
	end

	append(rule, {
		`{SELECTOR} \{`,
		'\tcontent: "";',
		"\tposition: absolute;",
		`\t{side.h}: {px(gapH)};`,
		`\t{vertical}`,
		`\twidth: {px(boxW)};`,
		`\theight: {px(boxH)};`,
		`\tpointer-events: {if reactive then "auto" else "none"};`,
		-- The host layer is hidden while the pane shows a block; the cat stays drawn.
		"\tvisibility: visible;",
		`\tz-index: {num(z)};`,
		"\timage-rendering: pixelated;",
		`\tbackground-image: url("{url}");`,
		"\tbackground-repeat: no-repeat;",
		`\tbackground-size: {px(boxW * #durations)} {px(boxH)};`,
		"\tbackground-position: 0px 0px;",
	})
	if params.facing == "left" then
		table.insert(rule, "\ttransform: scaleX(-1);")
	end
	if #animations > 0 then
		table.insert(rule, `\tanimation: {table.concat(animations, ", ")};`)
	end
	if press then
		table.insert(rule, `\ttransition: opacity 0s linear {PRESS_HOLD_MS}ms;`)
	elseif prop then
		-- Replaces the every-pane dive transitions while focused.
		table.insert(rule, "\ttransition: none;")
	end
	table.insert(rule, "}")

	local reduced = { SELECTOR }
	if reactive then
		-- Invisible ring around the cat (it shares the host's single hover bit, so "near" and "on
		-- the cat" look the same). On the two edges at the corner its padding shrinks to the gap so
		-- it stays inside the pane; the press sheet is drawn in its content box, exactly over the
		-- cat, while the cat hides.
		local nearH = math.min(RING_PX, gapH)
		local nearV = math.min(RING_PX, gapV)
		local pad = {
			top = if side.v == "top" then nearV else RING_PX,
			right = if side.h == "right" then nearH else RING_PX,
			bottom = if side.v == "bottom" then nearV else RING_PX,
			left = if side.h == "left" then nearH else RING_PX,
		}
		table.insert(rule, `{RING} \{`)
		append(rule, {
			'\tcontent: "";',
			"\tposition: absolute;",
			`\t{side.h}: {px(gapH - nearH)};`,
			`\t{side.v}: {px(gapV - nearV)};`,
			`\twidth: {px(boxW + RING_PX + nearH)};`,
			`\theight: {px(boxH + RING_PX + nearV)};`,
			"\tbox-sizing: border-box;",
			`\tpadding: {px(pad.top)} {px(pad.right)} {px(pad.bottom)} {px(pad.left)};`,
			"\tpointer-events: auto;",
			"\tvisibility: visible;",
			`\tz-index: {num(z)};`,
			`\ttransform-origin: {px(pad.left + boxW / 2)} {px(pad.top + boxH / 2)};`,
		})
		if params.facing == "left" then
			table.insert(rule, "\ttransform: scaleX(-1);")
		end
		local ringList: { string } = {}
		if pace then
			table.insert(ringList, pace :: string)
		end
		if emergeRing then
			table.insert(ringList, emergeRing :: string)
		end
		if #ringList > 0 then
			table.insert(rule, `\tanimation: {table.concat(ringList, ", ")};`)
		end
		if press then
			-- Rests on the last frame: the pose held after release.
			local rest = if still then 0 else -(#press.durations - 1) * boxW
			append(rule, {
				"\timage-rendering: pixelated;",
				`\tbackground-image: url("{press.url}");`,
				"\tbackground-repeat: no-repeat;",
				"\tbackground-origin: content-box;",
				"\tbackground-clip: content-box;",
				"\tbackground-size: 0px 0px;",
				`\tbackground-position: {px(rest)} 0px;`,
				`\ttransition: background-size 0s linear {PRESS_HOLD_MS}ms;`,
			})
		end
		table.insert(rule, "}")
		table.insert(reduced, RING)
	end
	if hover then
		local list: { string } = {}
		if #hover.durations > 1 and not still then
			local iteration = if hover.loop then "infinite" else "1 forwards"
			table.insert(list, `tern-cat-hover {totalMs(hover.durations)}ms step-end {iteration}`)
			table.insert(blocks, frameKeyframes("tern-cat-hover", hover.durations, boxW))
		end
		if pace then
			table.insert(list, pace :: string)
		end
		if emerge then
			table.insert(list, emerge :: string)
		end
		append(rule, {
			`{HOVER} \{`,
			`\tbackground-image: url("{hover.url}");`,
			`\tbackground-size: {px(boxW * #hover.durations)} {px(boxH)};`,
			"\tbackground-position: 0px 0px;",
			`\tanimation: {animationValue(list)};`,
			"}",
		})
		table.insert(reduced, HOVER)
	end
	if press then
		local list: { string } = {}
		if #press.durations > 1 and not still then
			table.insert(list, `tern-cat-press {totalMs(press.durations)}ms step-end 1 forwards`)
			table.insert(blocks, frameKeyframes("tern-cat-press", press.durations, boxW))
		end
		if pace then
			table.insert(list, pace :: string)
		end
		if emergeRing then
			table.insert(list, emergeRing :: string)
		end
		append(rule, {
			`{PRESS} \{`,
			"\topacity: 0;",
			"\ttransition: opacity 0s;",
			"}",
			`{PRESS_RING} \{`,
			`\tbackground-size: {px(boxW * #press.durations)} {px(boxH)};`,
			`\tanimation: {animationValue(list)};`,
			"\ttransition: background-size 0s;",
			"}",
		})
		table.insert(reduced, PRESS_RING)
	end

	local settled: { string } = {}
	if prop then
		local p = prop :: PropSpec
		local g: Geometry = { side = side, boxW = boxW, boxH = boxH, h = gapH, v = gapV, scale = scale }
		append(rule, propRules(g, p, BACK, BACK_ON, p.exit_back, p.enter_back, PROP_BACK, true, blocks))
		table.insert(settled, EVERY)
		table.insert(settled, BACK)
		table.insert(reduced, BACK_ON)
		if p.enter_front or p.exit_front then
			append(rule, propRules(g, p, FRONT, FRONT_ON, p.exit_front, p.enter_front, PROP_FRONT, false, blocks))
			table.insert(settled, FRONT)
			table.insert(reduced, FRONT_ON)
		end
	end

	local media = {
		"@media (prefers-reduced-motion: reduce) {",
		`\t{table.concat(reduced, ", ")} \{`,
		"\t\tanimation: none !important;",
		"\t\tbackground-position: 0px 0px;",
		"\t}",
	}
	if #settled > 0 then
		append(media, {
			`\t{table.concat(settled, ", ")} \{`,
			"\t\ttransition: none !important;",
			"\t}",
		})
	end
	table.insert(media, "}")
	table.insert(blocks, table.concat(media, "\n"))

	return table.concat(rule, "\n") .. "\n" .. table.concat(blocks, "\n") .. "\n"
end

local function dataUrl(bytes: string, base64Encode: (string) -> string): string
	local encoded = string.gsub(base64Encode(bytes), "%s", "")
	return DATA_PREFIX .. encoded
end

return {
	css = css,
	dataUrl = dataUrl,
	HOST = HOST,
	SELECTOR = SELECTOR,
}
