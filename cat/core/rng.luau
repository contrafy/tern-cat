--!strict
-- Seeded xorshift32 PRNG (bit32). Pure; deterministic for a given seed.

local T = require("../types")

local TWO_32 = 4294967296
local ZERO_SEED_STATE = 0x9E3779B9
local WARMUP_ROUNDS = 12

local function step(x: number): number
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	return x
end

local function normalize(seed: number): number
	if seed ~= seed or seed == math.huge or seed == -math.huge then
		return ZERO_SEED_STATE
	end
	local x = math.floor(seed) % TWO_32
	if x == 0 then
		return ZERO_SEED_STATE
	end
	return x
end

local function fromState(state: number): T.Rng
	local x = normalize(state)

	local self = {}

	function self.next(_: T.Rng): number
		x = step(x)
		return x / TWO_32
	end

	function self.int(r: T.Rng, lo: number, hi: number): number
		if hi <= lo then
			return lo
		end
		return lo + math.floor(r:next() * (hi - lo + 1))
	end

	function self.chance(r: T.Rng, p: number): boolean
		if p <= 0 then
			return false
		end
		if p >= 1 then
			return true
		end
		return r:next() < p
	end

	function self.weighted(r: T.Rng, weights: { [string]: number }): string?
		local keys = {}
		local total = 0
		for k, w in weights do
			if w > 0 then
				table.insert(keys, k)
				total += w
			end
		end
		if total <= 0 then
			return nil
		end
		table.sort(keys)
		local target = r:next() * total
		local acc = 0
		for _, k in keys do
			acc += weights[k]
			if target < acc then
				return k
			end
		end
		return keys[#keys]
	end

	function self.state(_: T.Rng): number
		return x
	end

	return self :: T.Rng
end

local function new(seed: number): T.Rng
	local x = bit32.bxor(normalize(seed), 0x2545F491)
	if x == 0 then
		x = ZERO_SEED_STATE
	end
	for _ = 1, WARMUP_ROUNDS do
		x = step(x)
	end
	return fromState(x)
end

return {
	new = new,
	fromState = fromState,
}
