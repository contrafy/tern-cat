--!strict
-- pack.json validation: limits, path safety, animation set and image checks.
-- Path rules are enforced before any filesystem access. Never throws.

local T = require("../types")
local png = require("./png")

local LIMITS = table.freeze({
	schema_version = 1,
	id_max = 32,
	name_max = 64,
	license_max = 64,
	author_max = 64,
	description_max = 512,
	canvas_min = 8,
	canvas_max = 256,
	animations_max = 32,
	frames_max = 64,
	duration_min_ms = 40,
	duration_max_ms = 10000,
	path_max = 200,
	file_max_bytes = 1024 * 1024,
	files_max = 512,
	pack_max_bytes = 16 * 1024 * 1024,
})

local CANONICAL: { [string]: boolean } = {}
for _, name in
	{
		"idle",
		"walk",
		"sit",
		"sleep",
		"wake",
		"stretch",
		"groom",
		"blink",
		"look",
		"pet",
		"poke",
		"eat",
		"play",
		"happy",
		"disappointed",
		"swat",
		"startled",
		"flop",
		"stare",
		"hop",
	}
do
	CANONICAL[name] = true
end

local function isInteger(v: any): boolean
	return type(v) == "number" and v == v and v == math.floor(v) and math.abs(v) < 2 ^ 53
end

local function isIntIn(v: any, lo: number, hi: number): boolean
	return isInteger(v) and v >= lo and v <= hi
end

-- Returns the length when `v` is a proper sequence (keys exactly 1..n), else nil.
local function sequenceLength(v: any): number?
	if type(v) ~= "table" then
		return nil
	end
	local count = 0
	for k in v do
		if not isInteger(k) or k < 1 then
			return nil
		end
		count += 1
	end
	for i = 1, count do
		if v[i] == nil then
			return nil
		end
	end
	return count
end

local function describe(v: any): string
	if type(v) == "string" then
		if #v > 40 then
			return string.format("%q", string.sub(v, 1, 40) .. "...")
		end
		return string.format("%q", v)
	end
	if type(v) == "number" then
		return tostring(v)
	end
	return type(v)
end

-- Checks a pack-relative path. Returns (true, nil) or (false, reason).
local function checkPath(p: any): (boolean, string?)
	if type(p) ~= "string" then
		return false, "must be a string path"
	end
	if p == "" then
		return false, "must not be empty"
	end
	if #p > LIMITS.path_max then
		return false, `must be at most {LIMITS.path_max} characters`
	end
	if string.find(p, "\\", 1, true) then
		return false, "must use forward slashes (no backslashes)"
	end
	if string.find(p, ":", 1, true) then
		return false, "must be a relative path inside the pack (no URL schemes or drive letters)"
	end
	if string.sub(p, 1, 1) == "/" then
		return false, "must be relative (no leading /)"
	end
	for segment in string.gmatch(p .. "/", "([^/]*)/") do
		if segment == "" then
			return false, "must not contain empty path segments"
		end
		if segment == "." or segment == ".." then
			return false, "must not contain . or .. segments"
		end
		if not string.match(segment, "^[A-Za-z0-9._%-]+$") then
			return false, "may only contain letters, digits, '.', '_', '-' and '/'"
		end
	end
	local lower = string.lower(p)
	if not (string.match(p, "%.png$") or string.match(p, "%.apng$")) then
		if string.match(lower, "%.a?png$") then
			return false, "extension must be lowercase .png or .apng"
		end
		return false, "must end in .png or .apng"
	end
	return true, nil
end

local function isSafePath(p: any): boolean
	return (checkPath(p))
end

local function joinPath(root: string, rel: string): string
	if root == "" then
		return rel
	end
	if string.sub(root, -1) == "/" then
		return root .. rel
	end
	return root .. "/" .. rel
end

type Ref = { field: string, path: string, role: "frame" | "apng" | "sheet", frames: number }

type Ctx = {
	errors: { string },
	warnings: { string },
}

local function err(ctx: Ctx, field: string, message: string)
	table.insert(ctx.errors, `{field}: {message}`)
end

local function optionalString(ctx: Ctx, raw: { [any]: any }, key: string, max: number): string?
	local v = raw[key]
	if v == nil then
		return nil
	end
	if type(v) ~= "string" or #v > max then
		err(ctx, key, `must be a string of at most {max} characters`)
		return nil
	end
	return v
end

local function requiredString(ctx: Ctx, raw: { [any]: any }, key: string, max: number): string
	local v = raw[key]
	if type(v) ~= "string" or #v < 1 or #v > max then
		err(ctx, key, `required string of 1..{max} characters (got {describe(v)})`)
		return ""
	end
	return v
end

local function validateIntList(
	ctx: Ctx,
	field: string,
	v: any,
	arity: number,
	check: (values: { number }) -> string?
): { number }?
	if v == nil then
		return nil
	end
	if sequenceLength(v) ~= arity then
		err(ctx, field, `must be a list of {arity} integers`)
		return nil
	end
	local out = {}
	for i = 1, arity do
		if not isInteger(v[i]) then
			err(ctx, field, `must be a list of {arity} integers`)
			return nil
		end
		out[i] = v[i]
	end
	local problem = check(out)
	if problem then
		err(ctx, field, problem)
		return nil
	end
	return out
end

local function validateAnimation(
	ctx: Ctx,
	name: string,
	raw: any,
	canvas: { width: number, height: number }?,
	refs: { Ref }
): T.AnimationSpec?
	local base = `animations.{name}`
	if type(raw) ~= "table" then
		err(ctx, base, "must be an object")
		return nil
	end
	local before = #ctx.errors

	local frames: { string } = {}
	local count = sequenceLength(raw.frames)
	if count == nil then
		err(ctx, base .. ".frames", "must be a list of file paths")
	elseif count < 1 or count > LIMITS.frames_max then
		err(ctx, base .. ".frames", `must have between 1 and {LIMITS.frames_max} frames (got {count})`)
	else
		for i = 1, count do
			local p = raw.frames[i]
			local field = `{base}.frames[{i}]`
			local ok, reason = checkPath(p)
			if ok then
				frames[i] = p
				table.insert(refs, { field = `{field} {describe(p)}`, path = p, role = "frame", frames = 1 })
			else
				err(ctx, field, `unsafe path {describe(p)}: {reason}`)
			end
		end
	end

	local durations: { number } = {}
	local dcount = sequenceLength(raw.durations_ms)
	if dcount == nil then
		err(ctx, base .. ".durations_ms", "must be a list of integers (one per frame)")
	else
		if count ~= nil and dcount ~= count then
			err(ctx, base .. ".durations_ms", `has {dcount} entries but there are {count} frames`)
		end
		for i = 1, dcount do
			local d = raw.durations_ms[i]
			if isIntIn(d, LIMITS.duration_min_ms, LIMITS.duration_max_ms) then
				durations[i] = d
			else
				err(
					ctx,
					`{base}.durations_ms[{i}]`,
					`must be an integer between {LIMITS.duration_min_ms} and {LIMITS.duration_max_ms} (got {describe(d)})`
				)
			end
		end
	end

	if type(raw.loop) ~= "boolean" then
		err(ctx, base .. ".loop", `must be true or false (got {describe(raw.loop)})`)
	end

	local w = canvas and canvas.width or math.huge
	local h = canvas and canvas.height or math.huge
	local anchor = validateIntList(ctx, base .. ".anchor", raw.anchor, 2, function(v)
		if v[1] < 0 or v[2] < 0 or v[1] > w or v[2] > h then
			return `point ({v[1]}, {v[2]}) is outside the canvas`
		end
		return nil
	end)
	local hitbox = validateIntList(ctx, base .. ".hitbox", raw.hitbox, 4, function(v)
		if v[1] < 0 or v[2] < 0 or v[3] < 1 or v[4] < 1 or v[1] + v[3] > w or v[2] + v[4] > h then
			return `[x, y, w, h] = [{v[1]}, {v[2]}, {v[3]}, {v[4]}] must have positive size and lie inside the canvas`
		end
		return nil
	end)

	local derived: { [string]: string } = {}
	for _, key in { "apng", "sheet" } do
		local p = raw[key]
		if p ~= nil then
			local ok, reason = checkPath(p)
			if ok then
				derived[key] = p
				table.insert(refs, {
					field = `{base}.{key} {describe(p)}`,
					path = p,
					role = key :: any,
					frames = count or 0,
				})
			else
				err(ctx, `{base}.{key}`, `unsafe path {describe(p)}: {reason}`)
			end
		end
	end

	if #ctx.errors > before then
		return nil
	end
	return {
		frames = frames,
		durations_ms = durations,
		loop = raw.loop,
		anchor = anchor,
		hitbox = hitbox,
		apng = derived.apng,
		sheet = derived.sheet,
	}
end

local function checkFiles(
	ctx: Ctx,
	fs: T.FsAdapter,
	root: string,
	canvas: { width: number, height: number },
	refs: { Ref }
)
	local cache: { [string]: { info: png.PngInfo?, problem: string? } } = {}
	local total = 0
	for _, ref in refs do
		local entry = cache[ref.path]
		if not entry then
			local okRead, data = pcall(fs.read, joinPath(root, ref.path), LIMITS.file_max_bytes + 1)
			if not okRead then
				entry = { problem = "could not be read" }
			elseif type(data) ~= "string" then
				entry = { problem = "file not found" }
			elseif #data > LIMITS.file_max_bytes then
				entry = { problem = `file exceeds {LIMITS.file_max_bytes} bytes` }
			else
				total += #data
				if total > LIMITS.pack_max_bytes then
					table.insert(ctx.errors, `pack exceeds total size limit of {LIMITS.pack_max_bytes} bytes`)
					return
				end
				local info, why = png.inspect(data)
				if info then
					entry = { info = info }
				else
					entry = { problem = `not a PNG ({why})` }
				end
			end
			cache[ref.path] = entry
		end
		local info = entry.info
		if not info then
			err(ctx, ref.field, entry.problem or "invalid")
			continue
		end
		if ref.role == "frame" then
			if info.width ~= canvas.width or info.height ~= canvas.height then
				err(ctx, ref.field, `image is {info.width}x{info.height} but canvas is {canvas.width}x{canvas.height}`)
			end
		elseif ref.role == "apng" then
			if not info.animated then
				err(ctx, ref.field, "not an animated PNG (no acTL chunk)")
			elseif info.frames ~= ref.frames then
				err(ctx, ref.field, `has {info.frames} frames but the animation has {ref.frames}`)
			end
			if info.width ~= canvas.width or info.height ~= canvas.height then
				err(ctx, ref.field, `image is {info.width}x{info.height} but canvas is {canvas.width}x{canvas.height}`)
			end
		else
			local ew, eh = canvas.width * ref.frames, canvas.height
			if info.width ~= ew or info.height ~= eh then
				err(
					ctx,
					ref.field,
					`sheet is {info.width}x{info.height} but expected {ew}x{eh} ({ref.frames} frames of {canvas.width}x{canvas.height})`
				)
			end
		end
	end
end

local function validateInner(raw: any, fs: T.FsAdapter, root: string): T.ValidationResult
	local ctx: Ctx = { errors = {}, warnings = {} }
	local function result(m: T.PackManifest?): T.ValidationResult
		local ok = #ctx.errors == 0
		return { ok = ok, errors = ctx.errors, warnings = ctx.warnings, manifest = if ok then m else nil }
	end

	if type(raw) ~= "table" then
		err(ctx, "manifest", "pack.json must contain a JSON object")
		return result(nil)
	end

	if raw.schema_version ~= LIMITS.schema_version then
		err(ctx, "schema_version", `must be {LIMITS.schema_version} (got {describe(raw.schema_version)})`)
	end

	local id = raw.id
	if type(id) ~= "string" or #id > LIMITS.id_max or not string.match(id, "^[a-z][a-z0-9%-]*$") then
		err(
			ctx,
			"id",
			`must be 1..{LIMITS.id_max} chars of a-z, 0-9 and '-', starting with a letter (got {describe(id)})`
		)
	end
	local name = requiredString(ctx, raw, "name", LIMITS.name_max)
	local license = requiredString(ctx, raw, "license", LIMITS.license_max)
	local author = optionalString(ctx, raw, "author", LIMITS.author_max)
	local description = optionalString(ctx, raw, "description", LIMITS.description_max)

	local canvas: { width: number, height: number }? = nil
	if type(raw.canvas) ~= "table" then
		err(ctx, "canvas", "must be an object with width and height")
	else
		local okCanvas = true
		for _, key in { "width", "height" } do
			local v = raw.canvas[key]
			if not isIntIn(v, LIMITS.canvas_min, LIMITS.canvas_max) then
				okCanvas = false
				err(
					ctx,
					`canvas.{key}`,
					`must be an integer between {LIMITS.canvas_min} and {LIMITS.canvas_max} (got {describe(v)})`
				)
			end
		end
		if okCanvas then
			canvas = { width = raw.canvas.width, height = raw.canvas.height }
		end
	end

	local animations: { [string]: T.AnimationSpec } = {}
	local refs: { Ref } = {}
	if type(raw.animations) ~= "table" then
		err(ctx, "animations", "must be an object keyed by animation name")
	else
		local names: { string } = {}
		local badKeys = false
		for k in raw.animations do
			if type(k) == "string" then
				table.insert(names, k)
			else
				badKeys = true
			end
		end
		table.sort(names)
		if badKeys then
			err(ctx, "animations", "must be an object keyed by animation name")
		elseif #names > LIMITS.animations_max then
			err(ctx, "animations", `at most {LIMITS.animations_max} animations allowed (got {#names})`)
		else
			for _, animName in names do
				if CANONICAL[animName] then
					local spec = validateAnimation(ctx, animName, raw.animations[animName], canvas, refs)
					if spec then
						animations[animName] = spec
					end
				else
					local shown = if string.match(animName, "^[%w_%-]+$") and #animName <= 40
						then animName
						else describe(animName)
					table.insert(ctx.warnings, `animations.{shown}: unknown animation name, ignored`)
				end
			end
			if raw.animations.idle == nil then
				err(ctx, "animations", 'missing required animation "idle"')
			end
		end
	end

	local unique: { [string]: boolean } = {}
	local fileCount = 0
	for _, ref in refs do
		if not unique[ref.path] then
			unique[ref.path] = true
			fileCount += 1
		end
	end
	if fileCount > LIMITS.files_max then
		err(ctx, "animations", `references {fileCount} files; at most {LIMITS.files_max} allowed`)
	end

	if #ctx.errors > 0 or canvas == nil then
		return result(nil)
	end

	checkFiles(ctx, fs, root, canvas, refs)

	return result({
		schema_version = LIMITS.schema_version,
		id = id,
		name = name,
		author = author,
		license = license,
		description = description,
		canvas = canvas,
		animations = animations,
	})
end

local function validate(raw: any, fs: T.FsAdapter, root: string): T.ValidationResult
	local ok, res = pcall(validateInner, raw, fs, root)
	if ok then
		return res
	end
	return { ok = false, errors = { `internal validation error: {tostring(res)}` }, warnings = {}, manifest = nil }
end

return {
	validate = validate,
	checkPath = checkPath,
	isSafePath = isSafePath,
	joinPath = joinPath,
	LIMITS = LIMITS,
}
