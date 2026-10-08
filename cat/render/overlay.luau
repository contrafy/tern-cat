--!strict
-- Window overlay stylesheet generator (pure). The sheet decorates the focused pane's body with
-- a sprite-sheet animation; it never takes input. Every interpolated value is sanitized so a
-- hostile pack cannot inject CSS.

local manifest = require("../sprite/manifest")

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
	z: number?,
	offset_px: { right: number, bottom: number }?,
}

local SELECTOR = "section.tn-pane.on > .tn-body::after"
local HIDDEN_SHEET = "/* tern-cat overlay hidden */\n"
local DATA_PREFIX = "data:image/png;base64,"
local MAX_URL_BYTES = 4 * 1024 * 1024
local DEFAULT_Z = 2147483000
local DEFAULT_OFFSET = 12
local PACE_PX = 160
local PACE_STEP_PX = 8
local PACE_SPEED_PX_S = 40

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

	local durations: { number } = {}
	if type(params.durations_ms) == "table" then
		for i = 1, math.min(#params.durations_ms, manifest.LIMITS.frames_max) do
			durations[i] =
				clampInt(params.durations_ms[i], manifest.LIMITS.duration_min_ms, manifest.LIMITS.duration_max_ms, 100)
		end
	end
	if #durations == 0 then
		durations[1] = 100
	end

	local key = safeKey(params.anim_key)
	local frameName = `tern-cat-{key}`
	local paceName = `tern-cat-pace-{key}`
	local boxW = frameW * scale
	local boxH = frameH * scale

	local animations: { string } = {}
	local blocks: { string } = {}
	if #durations > 1 then
		local total = 0
		for _, d in durations do
			total += d
		end
		local iteration = if params.loop == true then "infinite" else "1 forwards"
		table.insert(animations, `{frameName} {total}ms step-end {iteration}`)
		table.insert(blocks, frameKeyframes(frameName, durations, boxW))
	end
	if params.pace == true then
		local steps = math.floor(PACE_PX / PACE_STEP_PX)
		local legMs = PACE_PX / PACE_SPEED_PX_S * 1000
		local totalMs = math.floor(legMs / 0.48 + 0.5)
		table.insert(animations, `{paceName} {totalMs}ms step-end infinite`)
		table.insert(blocks, paceKeyframes(paceName, steps))
	end

	local rule = {
		"/* tern-cat overlay */",
		`{SELECTOR} \{`,
		'\tcontent: "";',
		"\tposition: absolute;",
		`\tright: {px(right)};`,
		`\tbottom: {px(bottom)};`,
		`\twidth: {px(boxW)};`,
		`\theight: {px(boxH)};`,
		"\tpointer-events: none;",
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
	table.insert(rule, "}")

	table.insert(
		blocks,
		table.concat({
			"@media (prefers-reduced-motion: reduce) {",
			`\t{SELECTOR} \{`,
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
	SELECTOR = SELECTOR,
}
