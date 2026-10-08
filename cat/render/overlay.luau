--!strict
-- Window overlay stylesheet generator (pure). The sheet draws a sprite-sheet animation in the
-- focused pane's corner. With reactions, the cat and an invisible proximity ring around it take
-- `:hover`/`:active` (Tern still delivers every click, drag and key to the terminal), so the cat
-- looks at a nearby pointer and swats when pressed; nothing about the pointer reaches Lua. Every
-- interpolated value is sanitized so a hostile pack cannot inject CSS.

local manifest = require("../sprite/manifest")

-- A reaction's sheet: same frame size as the main sheet (one pack).
export type Reaction = {
	sheet_url: string,
	durations_ms: { number },
	loop: boolean?,
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
	-- Reduced motion: show frame 0 without frame or pacing animation.
	still: boolean?,
	z: number?,
	offset_px: { right: number, bottom: number }?,
	-- Pointer reactions: `hover` plays while the pointer is on the cat or its proximity ring,
	-- `press` while the button is down there (held briefly after release). Nil: no reactions,
	-- the cat takes no pointer state at all.
	reactions: { hover: Reaction?, press: Reaction? }?,
}

-- Tern's top effects layer (`position:absolute; inset:0; pointer-events:none`) in the focused
-- pane's terminal view. Its `:hover` is local to its own pseudo-elements.
local HOST = "section.tn-pane.on > div.tn-body > div.tv > div.tv-fx.top"
local SELECTOR = HOST .. "::after"
local RING = HOST .. "::before"
local HOVER = HOST .. ":hover::after"
local PRESS = HOST .. ":active::after"
local PRESS_RING = HOST .. ":active::before"
local HIDDEN_SHEET = "/* tern-cat overlay hidden */\n"
local DATA_PREFIX = "data:image/png;base64,"
local MAX_URL_BYTES = 4 * 1024 * 1024
local DEFAULT_Z = 2147483000
local DEFAULT_OFFSET = 12
local PACE_PX = 160
local PACE_STEP_PX = 8
local PACE_SPEED_PX_S = 40
-- Proximity ring margin around the cat box (CSS px).
local RING_PX = 48
-- How long the swat pose stays after the button is released.
local PRESS_HOLD_MS = 700

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

local function frameKeyframes(name: string, durations: { number }, stepPx: number): string
	local total = 0
	for _, d in durations do
		total += d
	end
	local lines = { `@keyframes {name} \{` }
	local elapsed = 0
	for i, d in durations do
		local pct = elapsed / total * 100
		table.insert(lines, `\t{num(pct)}% \{ background-position: {px(-(i - 1) * stepPx)} 0px; }`)
		elapsed += d
	end
	table.insert(lines, `\t100% \{ background-position: {px(-(#durations - 1) * stepPx)} 0px; }`)
	table.insert(lines, "}")
	return table.concat(lines, "\n")
end

local function paceKeyframes(name: string, steps: number): string
	local far = px(-PACE_PX)
	return table.concat({
		`@keyframes {name} \{`,
		`\t0% \{ transform: translateX(0px) scaleX(-1); animation-timing-function: steps({steps}, end); }`,
		`\t48% \{ transform: translateX({far}) scaleX(-1); animation-timing-function: step-end; }`,
		`\t50% \{ transform: translateX({far}) scaleX(1); animation-timing-function: steps({steps}, end); }`,
		"\t98% { transform: translateX(0px) scaleX(1); animation-timing-function: step-end; }",
		"\t100% { transform: translateX(0px) scaleX(1); }",
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

local function animationValue(list: { string }): string
	return if #list > 0 then table.concat(list, ", ") else "none"
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
	local offset = if type(params.offset_px) == "table" then params.offset_px else {} :: any
	local right = clampInt(offset.right, 0, 4096, DEFAULT_OFFSET)
	local bottom = clampInt(offset.bottom, 0, 4096, DEFAULT_OFFSET)
	local durations = safeDurations(params.durations_ms)

	local key = safeKey(params.anim_key)
	local frameName = `tern-cat-{key}`
	local paceName = `tern-cat-pace-{key}`
	local boxW = frameW * scale
	local boxH = frameH * scale

	local still = params.still == true
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
		table.insert(blocks, paceKeyframes(paceName, steps))
	end

	local reactions = if type(params.reactions) == "table" then params.reactions else {} :: any
	local hover = safeReaction(reactions.hover)
	local press = safeReaction(reactions.press)
	local reactive = hover ~= nil or press ~= nil

	local rule = {
		"/* tern-cat overlay */",
		`{SELECTOR} \{`,
		'\tcontent: "";',
		"\tposition: absolute;",
		`\tright: {px(right)};`,
		`\tbottom: {px(bottom)};`,
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
	}
	if params.facing == "left" then
		table.insert(rule, "\ttransform: scaleX(-1);")
	end
	if #animations > 0 then
		table.insert(rule, `\tanimation: {table.concat(animations, ", ")};`)
	end
	if press then
		table.insert(rule, `\ttransition: opacity 0s linear {PRESS_HOLD_MS}ms;`)
	end
	table.insert(rule, "}")

	local reduced = { SELECTOR }
	if reactive then
		-- Invisible ring around the cat (it shares the host's single hover bit, so "near" and "on
		-- the cat" look the same). Its padding keeps it inside the pane at small offsets; the
		-- press sheet is drawn in its content box, exactly over the cat, while the cat hides.
		local padR = math.min(RING_PX, right)
		local padB = math.min(RING_PX, bottom)
		table.insert(rule, `{RING} \{`)
		for _, line in
			{
				'\tcontent: "";',
				"\tposition: absolute;",
				`\tright: {px(right - padR)};`,
				`\tbottom: {px(bottom - padB)};`,
				`\twidth: {px(boxW + RING_PX + padR)};`,
				`\theight: {px(boxH + RING_PX + padB)};`,
				"\tbox-sizing: border-box;",
				`\tpadding: {px(RING_PX)} {px(padR)} {px(padB)} {px(RING_PX)};`,
				"\tpointer-events: auto;",
				"\tvisibility: visible;",
				`\tz-index: {num(z)};`,
				`\ttransform-origin: {px(RING_PX + boxW / 2)} {px(RING_PX + boxH / 2)};`,
			}
		do
			table.insert(rule, line)
		end
		if params.facing == "left" then
			table.insert(rule, "\ttransform: scaleX(-1);")
		end
		if pace then
			table.insert(rule, `\tanimation: {pace};`)
		end
		if press then
			-- Rests on the last frame: the pose held after release.
			local rest = if still then 0 else -(#press.durations - 1) * boxW
			for _, line in
				{
					"\timage-rendering: pixelated;",
					`\tbackground-image: url("{press.url}");`,
					"\tbackground-repeat: no-repeat;",
					"\tbackground-origin: content-box;",
					"\tbackground-clip: content-box;",
					"\tbackground-size: 0px 0px;",
					`\tbackground-position: {px(rest)} 0px;`,
					`\ttransition: background-size 0s linear {PRESS_HOLD_MS}ms;`,
				}
			do
				table.insert(rule, line)
			end
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
		for _, line in
			{
				`{HOVER} \{`,
				`\tbackground-image: url("{hover.url}");`,
				`\tbackground-size: {px(boxW * #hover.durations)} {px(boxH)};`,
				"\tbackground-position: 0px 0px;",
				`\tanimation: {animationValue(list)};`,
				"}",
			}
		do
			table.insert(rule, line)
		end
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
		for _, line in
			{
				`{PRESS} \{`,
				"\topacity: 0;",
				"\ttransition: opacity 0s;",
				"}",
				`{PRESS_RING} \{`,
				`\tbackground-size: {px(boxW * #press.durations)} {px(boxH)};`,
				`\tanimation: {animationValue(list)};`,
				"\ttransition: background-size 0s;",
				"}",
			}
		do
			table.insert(rule, line)
		end
		table.insert(reduced, PRESS_RING)
	end

	table.insert(
		blocks,
		table.concat({
			"@media (prefers-reduced-motion: reduce) {",
			`\t{table.concat(reduced, ", ")} \{`,
			"\t\tanimation: none !important;",
			"\t\tbackground-position: 0px 0px;",
			"\t}",
			"}",
		}, "\n")
	)

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
