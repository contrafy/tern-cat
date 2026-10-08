--!strict
-- Clock construction (injected primitives or fake) and quiet-hours math. Pure.

local T = require("../types")

export type FakeClock = T.Clock & { advance: (ms: number) -> () }

export type FakeOptions = {
	now_ms: number?,
	wall_s: number?,
	hour: number?,
	min: number?,
}

local MINUTES_PER_DAY = 24 * 60
local DEFAULT_WALL_S = 1767225600

local function fromPrimitives(
	now_ms: () -> number,
	wall_s: () -> number,
	local_hm: () -> { hour: number, min: number }
): T.Clock
	return {
		now_ms = now_ms,
		wall_s = wall_s,
		local_hm = local_hm,
	}
end

local function fake(opts: FakeOptions?): FakeClock
	local o: FakeOptions = opts or {}
	local now = o.now_ms or 0
	local wall_ms = (o.wall_s or DEFAULT_WALL_S) * 1000
	local base_wall_ms = wall_ms
	local base_minutes = (o.hour or 12) * 60 + (o.min or 0)

	local function advance(ms: number)
		if ms < 0 then
			error("fake clock: monotonic time cannot go backwards")
		end
		now += ms
		wall_ms += ms
	end

	return {
		now_ms = function()
			return now
		end,
		wall_s = function()
			return math.floor(wall_ms / 1000)
		end,
		local_hm = function()
			local elapsed_min = math.floor((wall_ms - base_wall_ms) / 60000)
			local m = (base_minutes + elapsed_min) % MINUTES_PER_DAY
			return { hour = math.floor(m / 60), min = m % 60 }
		end,
		advance = advance,
	}
end

local function parseHm(s: string): number?
	local h, m = string.match(s, "^(%d%d?):(%d%d)$")
	if not h or not m then
		return nil
	end
	local hour, min = tonumber(h) :: number, tonumber(m) :: number
	if hour > 23 or min > 59 then
		return nil
	end
	return hour * 60 + min
end

local function inQuietHours(hm: { hour: number, min: number }, start: string, stop: string): boolean
	local a = parseHm(start)
	local b = parseHm(stop)
	if a == nil or b == nil or a == b then
		return false
	end
	local now = hm.hour * 60 + hm.min
	if a < b then
		return now >= a and now < b
	end
	return now >= a or now < b
end

return {
	fromPrimitives = fromPrimitives,
	fake = fake,
	parseHm = parseHm,
	inQuietHours = inQuietHours,
}
