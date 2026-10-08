--!strict
-- Real clock over tern.now and os.time/os.date.

local T = require("../types")
local clock = require("../core/clock")

export type RealClock = T.Clock & {
	-- Unix seconds with millisecond resolution (for ordering records written within one second).
	wall_precise: () -> number,
}

local function real(): RealClock
	local base_wall = os.time()
	local base_now = tern.now()
	local function wall_precise(): number
		local precise = base_wall + (tern.now() - base_now) / 1000
		local coarse = os.time()
		if math.abs(precise - coarse) > 2 then
			base_wall, base_now = coarse, tern.now()
			precise = coarse
		end
		return math.floor(precise * 1000 + 0.5) / 1000
	end
	local c = clock.fromPrimitives(function()
		return tern.now()
	end, function()
		return os.time()
	end, function()
		local ok, t = pcall(function(): any
			return os.date("*t")
		end)
		if ok and type(t) == "table" then
			return { hour = (t :: any).hour, min = (t :: any).min }
		end
		local s = os.time() % 86400
		return { hour = s // 3600, min = (s % 3600) // 60 }
	end)
	return {
		now_ms = c.now_ms,
		wall_s = c.wall_s,
		local_hm = c.local_hm,
		wall_precise = wall_precise,
	}
end

return {
	real = real,
}
