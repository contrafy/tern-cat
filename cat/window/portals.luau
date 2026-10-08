--!strict
-- Window-side pane-switch props: reads and validates assets/portals/portals.json once, then turns
-- the selected style's sheets (two to four small PNGs) into cached data URLs on first use. Path
-- and image rules are the sprite packs' (sprite/manifest, sprite/png). Never throws.

local T = require("../types")
local manifest = require("../sprite/manifest")
local png = require("../sprite/png")
local overlay = require("../render/overlay")

export type Deps = {
	fs: T.FsAdapter,
	-- Raising JSON decoder (pcalled here).
	decode: (text: string) -> any,
	base64: (bytes: string) -> string,
	-- Directory holding portals.json.
	dir: string,
}

type LayerSpec = { sheet: string, frames: number, durations_ms: { number } }
type TimelineSpec = { back: LayerSpec, front: LayerSpec? }
type StyleSpec = { name: string, enter: TimelineSpec, exit: TimelineSpec }

export type Catalog = {
	frame_w: number,
	frame_h: number,
	anchor: { number },
	styles: { [string]: StyleSpec },
}

export type Cache = {
	deps: Deps,
	-- nil until read; false when portals.json is missing or invalid.
	catalog: Catalog | false | nil,
	problem: string?,
	props: { [string]: overlay.Prop | false },
	problems: { [string]: string },
}

local MANIFEST_FILE = "portals.json"
local MAX_JSON_BYTES = 64 * 1024
local STYLES = { "portal", "vent", "box" }
local NAME_MAX = 64
local FRAME_MIN = 8
local FRAME_MAX = 256

local function isInt(v: any, lo: number, hi: number): boolean
	return type(v) == "number" and v == v and v == math.floor(v) and v >= lo and v <= hi
end

local function parseLayer(raw: any, field: string): (LayerSpec?, string?)
	if type(raw) ~= "table" then
		return nil, `{field}: must be an object`
	end
	local ok, why = manifest.checkPath(raw.sheet)
	if not ok then
		return nil, `{field}.sheet: {why}`
	end
	local frames = raw.frames
	if not isInt(frames, 1, manifest.LIMITS.frames_max) then
		return nil, `{field}.frames: must be a whole number 1..{manifest.LIMITS.frames_max}`
	end
	local durations = raw.durations_ms
	if type(durations) ~= "table" or #durations ~= frames then
		return nil, `{field}.durations_ms: must list one duration per frame`
	end
	local out: { number } = {}
	for i = 1, frames do
		local d = durations[i]
		if not isInt(d, manifest.LIMITS.duration_min_ms, manifest.LIMITS.duration_max_ms) then
			return nil,
				`{field}.durations_ms[{i}]: must be a whole number {manifest.LIMITS.duration_min_ms}..{manifest.LIMITS.duration_max_ms}`
		end
		out[i] = d
	end
	return { sheet = raw.sheet, frames = frames, durations_ms = out }, nil
end

local function parseTimeline(raw: any, field: string): (TimelineSpec?, string?)
	if type(raw) ~= "table" then
		return nil, `{field}: must be an object`
	end
	local back, err = parseLayer(raw.back, field .. ".back")
	if not back then
		return nil, err
	end
	local front: LayerSpec? = nil
	if raw.front ~= nil then
		local f, ferr = parseLayer(raw.front, field .. ".front")
		if not f then
			return nil, ferr
		end
		front = f
	end
	return { back = back, front = front }, nil
end

-- Validates a decoded portals.json. Styles other than the known ones are ignored.
local function parse(raw: any): (Catalog?, string?)
	if type(raw) ~= "table" then
		return nil, "must contain a JSON object"
	end
	if raw.schema_version ~= 1 then
		return nil, "schema_version: must be 1"
	end
	local frame = raw.frame
	if
		type(frame) ~= "table"
		or not isInt(frame.width, FRAME_MIN, FRAME_MAX)
		or not isInt(frame.height, FRAME_MIN, FRAME_MAX)
	then
		return nil, `frame: width and height must be whole numbers {FRAME_MIN}..{FRAME_MAX}`
	end
	local anchor = raw.anchor
	if type(anchor) ~= "table" or not isInt(anchor[1], 0, frame.width) or not isInt(anchor[2], 0, frame.height) then
		return nil, "anchor: must be [x, y] inside the frame"
	end
	if type(raw.styles) ~= "table" then
		return nil, "styles: must be an object"
	end
	local styles: { [string]: StyleSpec } = {}
	for _, id in STYLES do
		local s = raw.styles[id]
		if s == nil then
			continue
		end
		local base = `styles.{id}`
		if type(s) ~= "table" then
			return nil, `{base}: must be an object`
		end
		if type(s.name) ~= "string" or #s.name == 0 or #s.name > NAME_MAX then
			return nil, `{base}.name: must be 1..{NAME_MAX} characters`
		end
		local enter, eerr = parseTimeline(s.enter, base .. ".enter")
		if not enter then
			return nil, eerr
		end
		local exit, xerr = parseTimeline(s.exit, base .. ".exit")
		if not exit then
			return nil, xerr
		end
		styles[id] = { name = s.name, enter = enter, exit = exit }
	end
	return {
		frame_w = frame.width,
		frame_h = frame.height,
		anchor = { anchor[1], anchor[2] },
		styles = styles,
	},
		nil
end

local function new(deps: Deps): Cache
	return { deps = deps, catalog = nil, problem = nil, props = {}, problems = {} }
end

-- Forgets everything read so far (plugin reload, files changed).
local function invalidate(c: Cache)
	c.catalog = nil
	c.problem = nil
	c.props = {}
	c.problems = {}
end

local function loadCatalog(c: Cache)
	local path = manifest.joinPath(c.deps.dir, MANIFEST_FILE)
	local okRead, text = pcall(c.deps.fs.read, path, MAX_JSON_BYTES + 1)
	if not okRead or type(text) ~= "string" then
		c.catalog = false
		c.problem = `{MANIFEST_FILE} not found at {c.deps.dir}`
		return
	end
	if #text > MAX_JSON_BYTES then
		c.catalog = false
		c.problem = `{MANIFEST_FILE} exceeds {MAX_JSON_BYTES} bytes`
		return
	end
	local okDecode, raw = pcall(c.deps.decode, text)
	if not okDecode then
		c.catalog = false
		c.problem = `{MANIFEST_FILE} is not valid JSON`
		return
	end
	local catalog, err = parse(raw)
	if not catalog then
		c.catalog = false
		c.problem = `{MANIFEST_FILE}: {err}`
		return
	end
	c.catalog = catalog
end

local function loadLayer(c: Cache, catalog: Catalog, layer: LayerSpec, field: string): (overlay.PropLayer?, string?)
	local okRead, bytes =
		pcall(c.deps.fs.read, manifest.joinPath(c.deps.dir, layer.sheet), manifest.LIMITS.file_max_bytes + 1)
	if not okRead or type(bytes) ~= "string" or #bytes == 0 then
		return nil, `{field}: cannot read {layer.sheet}`
	end
	if #bytes > manifest.LIMITS.file_max_bytes then
		return nil, `{field}: {layer.sheet} exceeds {manifest.LIMITS.file_max_bytes} bytes`
	end
	local info, why = png.inspect(bytes)
	if not info then
		return nil, `{field}: {layer.sheet}: {why}`
	end
	if info.animated or not info.has_alpha then
		return nil, `{field}: {layer.sheet} must be a still PNG with alpha`
	end
	if info.width ~= catalog.frame_w * layer.frames or info.height ~= catalog.frame_h then
		return nil,
			`{field}: {layer.sheet} is {info.width}x{info.height}, expected {catalog.frame_w * layer.frames}x{catalog.frame_h}`
	end
	local okUrl, url = pcall(overlay.dataUrl, bytes, c.deps.base64)
	if not okUrl then
		return nil, `{field}: could not encode {layer.sheet}`
	end
	return { sheet_url = url, durations_ms = table.clone(layer.durations_ms) }, nil
end

local function build(c: Cache, catalog: Catalog, id: string): (overlay.Prop?, string?)
	local spec = catalog.styles[id]
	if spec == nil then
		return nil, `{MANIFEST_FILE}: no style "{id}"`
	end
	local layers: { [string]: overlay.PropLayer } = {}
	for _, part in { "enter", "exit" } do
		local timeline: TimelineSpec = (spec :: any)[part]
		for _, depth in { "back", "front" } do
			local layer: LayerSpec? = (timeline :: any)[depth]
			if layer then
				local loaded, err = loadLayer(c, catalog, layer, `styles.{id}.{part}.{depth}`)
				if not loaded then
					return nil, `{MANIFEST_FILE}: {err}`
				end
				layers[`{part}.{depth}`] = loaded
			end
		end
	end
	return {
		frame_w = catalog.frame_w,
		frame_h = catalog.frame_h,
		anchor = table.clone(catalog.anchor),
		enter = { back = layers["enter.back"], front = layers["enter.front"] },
		exit = { back = layers["exit.back"], front = layers["exit.front"] },
	},
		nil
end

-- The prop for `style` ("portal", "vent", "box"), or nil plus the reason it cannot be drawn.
-- Reads portals.json at most once and each style's sheets at most once until `invalidate`.
local function prop(c: Cache, style: string): (overlay.Prop?, string?)
	if c.catalog == nil then
		loadCatalog(c)
	end
	local catalog = c.catalog
	if catalog == false or catalog == nil then
		return nil, c.problem
	end
	local cached = c.props[style]
	if cached == false then
		return nil, c.problems[style]
	elseif cached ~= nil then
		return cached :: overlay.Prop, nil
	end
	local built, err = build(c, catalog :: Catalog, style)
	if built then
		c.props[style] = built
		return built, nil
	end
	c.props[style] = false
	c.problems[style] = err or "invalid style"
	return nil, c.problems[style]
end

return {
	STYLES = STYLES,
	MANIFEST_FILE = MANIFEST_FILE,
	parse = parse,
	new = new,
	invalidate = invalidate,
	prop = prop,
}
