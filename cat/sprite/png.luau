--!strict
-- PNG/APNG header inspection without decoding pixels. Bounds-checked; never throws.

export type PngInfo = {
	width: number,
	height: number,
	bit_depth: number,
	color_type: number,
	-- 1 for a plain PNG; acTL num_frames for an APNG.
	frames: number,
	animated: boolean,
	has_alpha: boolean,
}

local SIGNATURE = "\137PNG\r\n\26\n"
local MAX_DIMENSION = 0x7fffffff

local VALID_DEPTHS: { [number]: { [number]: boolean } } = {
	[0] = { [1] = true, [2] = true, [4] = true, [8] = true, [16] = true },
	[2] = { [8] = true, [16] = true },
	[3] = { [1] = true, [2] = true, [4] = true, [8] = true },
	[4] = { [8] = true, [16] = true },
	[6] = { [8] = true, [16] = true },
}

local function inspect(bytes: string): (PngInfo?, string?)
	if type(bytes) ~= "string" then
		return nil, "not a byte string"
	end
	local size = #bytes
	if size < 8 or string.sub(bytes, 1, 8) ~= SIGNATURE then
		return nil, "missing PNG signature"
	end
	if size < 33 then
		return nil, "truncated PNG header"
	end
	local ihdrLen = string.unpack(">I4", bytes, 9)
	if ihdrLen ~= 13 or string.sub(bytes, 13, 16) ~= "IHDR" then
		return nil, "first chunk is not a valid IHDR"
	end
	local width, height, depth, colorType = string.unpack(">I4I4BB", bytes, 17)
	if width == 0 or height == 0 or width > MAX_DIMENSION or height > MAX_DIMENSION then
		return nil, `invalid dimensions {width}x{height}`
	end
	local depths = VALID_DEPTHS[colorType]
	if not depths then
		return nil, `invalid color type {colorType}`
	end
	if not depths[depth] then
		return nil, `invalid bit depth {depth} for color type {colorType}`
	end

	local frames = 1
	local animated = false
	local hasAlpha = colorType == 4 or colorType == 6
	local pos = 34
	while true do
		if pos + 7 > size then
			return nil, "truncated PNG: no image data"
		end
		local len = string.unpack(">I4", bytes, pos)
		local kind = string.sub(bytes, pos + 4, pos + 7)
		local dataStart = pos + 8
		if len > size or dataStart + len + 3 > size then
			return nil, `truncated PNG: chunk {kind} runs past end of data`
		end
		if kind == "IDAT" then
			break
		elseif kind == "IEND" then
			return nil, "PNG has no image data"
		elseif kind == "acTL" then
			if len ~= 8 then
				return nil, "malformed acTL chunk"
			end
			local n = string.unpack(">I4", bytes, dataStart)
			if n == 0 then
				return nil, "acTL declares zero frames"
			end
			frames = n
			animated = true
		elseif kind == "tRNS" then
			hasAlpha = true
		end
		pos = dataStart + len + 4
	end

	return {
		width = width,
		height = height,
		bit_depth = depth,
		color_type = colorType,
		frames = frames,
		animated = animated,
		has_alpha = hasAlpha,
	},
		nil
end

return {
	inspect = inspect,
	SIGNATURE = SIGNATURE,
}
