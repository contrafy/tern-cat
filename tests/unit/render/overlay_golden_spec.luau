--!strict
-- The portal, vent, box and off sheets are frozen: the walk transition must not change one byte of
-- them. Each case's SHA-256 was taken before the walk mode existed. Run with TERN_CAT_GOLDEN=print
-- to list the current hashes after an intended change.
local serde = require("@lune/serde")
local process = require("@lune/process")
local t = require("../../lib/test")
local overlay = require("../../../cat/render/overlay")

local describe, it, expect = t.describe, t.it, t.expect

local SHEET = "data:image/png;base64,iVBORw0KGgo="
local LOOK = { sheet_url = "data:image/png;base64,TE9PSw==", durations_ms = { 100, 100, 200 }, loop = false }
local SWAT = { sheet_url = "data:image/png;base64,U1dBVA==", durations_ms = { 100, 100, 100, 100 }, loop = false }
local DIVE = { sheet_url = "data:image/png;base64,RElWRQ==", durations_ms = { 60, 60, 60, 60, 60, 60, 60, 60 } }
local EMERGE = { sheet_url = "data:image/png;base64,RU1FUkdF", durations_ms = { 160, 70, 70, 80, 80, 60, 60, 60 } }
local PROP = {
	frame_w = 48,
	frame_h = 24,
	anchor = { 24, 12 },
	enter = {
		back = { sheet_url = "data:image/png;base64,RU5URVI=", durations_ms = { 80, 80, 160, 160, 160, 80, 80 } },
		front = { sheet_url = "data:image/png;base64,RkxBUElO", durations_ms = { 80, 80, 160, 160, 160, 80, 80 } },
	},
	exit = {
		back = { sheet_url = "data:image/png;base64,RVhJVA==", durations_ms = { 80, 80, 80, 80, 80, 80, 80, 80 } },
		front = { sheet_url = "data:image/png;base64,RkxBUE9VVA==", durations_ms = { 80, 80, 80, 80, 80, 80, 80, 80 } },
	},
}

local function params(overrides: { [string]: any }): overlay.Params
	local p: { [string]: any } = {
		sheet_url = SHEET,
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
	for k, v in overrides do
		p[k] = v
	end
	return p :: any
end

type Case = { name: string, params: overlay.Params, sha256: string }

local CASES: { Case } = {
	{ name = "off", params = params({}), sha256 = "ca522d32eb32bf3c0839bef6f6a999b871f3a8262cbb88e40af081f80aa15f0d" },
	{
		name = "off-reactive-pace",
		params = params({ pace = true, reactions = { hover = LOOK, press = SWAT } }),
		sha256 = "1e4de81d3e6d09ee5aa184b1c60f2192caefab75451631e1a507696690cc6c81",
	},
	{
		name = "portal-pack-sheets",
		params = params({
			position = "bottom-right",
			reactions = { hover = LOOK, press = SWAT },
			transition = { prop = PROP, dive = DIVE, emerge = EMERGE },
		}),
		sha256 = "c6b611e899c6e539def937e1f00982113a6ed6333a19823b4bce1b4c578b9aa6",
	},
	{
		name = "portal-clip-top-left",
		params = params({
			position = "top-left",
			facing = "left",
			pace = true,
			reactions = { hover = LOOK, press = SWAT },
			transition = { prop = PROP },
		}),
		sha256 = "54f382c8bb73a84ae96fcb03485cc5792476dd18605e55bd4165e245d87d99a9",
	},
	{
		name = "portal-translucent",
		params = params({
			opacity = 0.5,
			position = "top-right",
			transition = { prop = PROP, dive = DIVE, emerge = EMERGE },
		}),
		sha256 = "858c7ea35791c0123fbc40e4a204a9e8bb2a5971a3f045b012f184d4acb259b2",
	},
	{
		name = "portal-still",
		params = params({ still = true, transition = { prop = PROP, dive = DIVE } }),
		sha256 = "3bd0d968ad6e16c567beec3d22fa461b96ffb021e1c5b4a66c3b1c013e1b7a53",
	},
	{
		name = "hidden",
		params = params({ hidden = true }),
		sha256 = "67f5500d09b88671d2ad758c1097506aca7df319640f07a401a5ec1255eca412",
	},
}

describe("render/overlay.css golden sheets", function()
	local show = process.env.TERN_CAT_GOLDEN == "print"
	for _, case in CASES do
		it(`keeps the {case.name} sheet byte for byte`, function()
			local css = overlay.css(case.params)
			local sha = serde.hash("sha256", css)
			if show then
				print(`{case.name} {sha}`)
			end
			expect(sha).toBe(case.sha256)
		end)
	end
end)
