--!strict
-- Canonical animation names, fallback chains for packs that lack an animation, and
-- pack-independent loop/duration defaults. Pure.

local T = require("../types")

local CANONICAL: { T.Animation } = {
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

local CANONICAL_SET: { [string]: boolean } = {}
for _, name in CANONICAL do
	CANONICAL_SET[name] = true
end

-- Full chain tried in order after the wanted animation; every chain ends in idle.
local FALLBACKS: { [string]: { T.Animation } } = {
	idle = {},
	walk = { "idle" },
	sit = { "idle" },
	sleep = { "sit", "idle" },
	wake = { "stretch", "blink", "idle" },
	stretch = { "blink", "idle" },
	groom = { "sit", "idle" },
	blink = { "idle" },
	look = { "blink", "idle" },
	pet = { "happy", "blink", "idle" },
	poke = { "startled", "look", "idle" },
	eat = { "happy", "idle" },
	play = { "swat", "happy", "idle" },
	happy = { "blink", "idle" },
	disappointed = { "look", "sit", "idle" },
	swat = { "play", "happy", "idle" },
	startled = { "hop", "look", "idle" },
	flop = { "disappointed", "sit", "idle" },
	stare = { "look", "sit", "idle" },
	hop = { "look", "idle" },
}

local LOOPS: { [string]: boolean } = { idle = true, walk = true, sit = true, sleep = true }

local DURATIONS_MS: { [string]: number } = {
	idle = 6000,
	walk = 4000,
	sit = 8000,
	sleep = 45000,
	wake = 1200,
	stretch = 1800,
	groom = 2400,
	blink = 600,
	look = 1600,
	pet = 2000,
	poke = 900,
	eat = 2400,
	play = 2400,
	happy = 1400,
	disappointed = 1800,
	swat = 1000,
	startled = 800,
	flop = 2400,
	stare = 2000,
	hop = 900,
}

local function isCanonical(name: any): boolean
	return type(name) == "string" and CANONICAL_SET[name] == true
end

local function resolve(available: { [string]: any }, wanted: string): T.Animation
	if available[wanted] and isCanonical(wanted) then
		return wanted :: T.Animation
	end
	local chain = FALLBACKS[wanted]
	if chain then
		for _, step in chain do
			if available[step] then
				return step :: T.Animation
			end
		end
	end
	return "idle"
end

local function isLoop(anim: string): boolean
	return LOOPS[anim] == true
end

local function defaultDurationMs(anim: string): number
	return DURATIONS_MS[anim] or DURATIONS_MS.idle
end

return {
	CANONICAL = CANONICAL,
	FALLBACKS = FALLBACKS,
	isCanonical = isCanonical,
	resolve = resolve,
	isLoop = isLoop,
	defaultDurationMs = defaultDurationMs,
}
