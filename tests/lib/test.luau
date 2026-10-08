--!strict
-- Minimal BDD-style test framework for Lune. Specs call `describe`/`it`/`expect`;
-- tests/run.luau collects and executes them.

type TestCase = { name: string, fn: () -> () }

local registered: { TestCase } = {}
local prefix: { string } = {}

local function fullName(name: string): string
	local parts = table.clone(prefix)
	table.insert(parts, name)
	return table.concat(parts, " > ")
end

local function describe(name: string, fn: () -> ())
	table.insert(prefix, name)
	fn()
	table.remove(prefix)
end

local function it(name: string, fn: () -> ())
	table.insert(registered, { name = fullName(name), fn = fn })
end

local function render(value: any, depth: number?): string
	local d = depth or 0
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" then
		return tostring(value)
	end
	if d > 4 then
		return "{...}"
	end
	local keys = {}
	for k in value do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, k in keys do
		table.insert(parts, tostring(k) .. "=" .. render(value[k], d + 1))
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function fail(message: string)
	error(message, 3)
end

local function expect(actual: any)
	local matchers = {}

	function matchers.toBe(expected: any)
		if actual ~= expected then
			fail(`expected {render(actual)} to be {render(expected)}`)
		end
	end

	function matchers.toEqual(expected: any)
		if not deepEqual(actual, expected) then
			fail(`expected {render(actual)} to deep-equal {render(expected)}`)
		end
	end

	function matchers.notToEqual(expected: any)
		if deepEqual(actual, expected) then
			fail(`expected {render(actual)} not to deep-equal {render(expected)}`)
		end
	end

	function matchers.toBeNil()
		if actual ~= nil then
			fail(`expected nil, got {render(actual)}`)
		end
	end

	function matchers.notToBeNil()
		if actual == nil then
			fail("expected a non-nil value")
		end
	end

	function matchers.toBeTruthy()
		if not actual then
			fail(`expected truthy, got {render(actual)}`)
		end
	end

	function matchers.toBeFalsy()
		if actual then
			fail(`expected falsy, got {render(actual)}`)
		end
	end

	function matchers.toBeCloseTo(expected: number, epsilon: number?)
		local eps = epsilon or 1e-6
		if type(actual) ~= "number" or math.abs(actual - expected) > eps then
			fail(`expected {render(actual)} to be within {eps} of {expected}`)
		end
	end

	function matchers.toBeGreaterThan(expected: number)
		if type(actual) ~= "number" or not (actual > expected) then
			fail(`expected {render(actual)} > {expected}`)
		end
	end

	function matchers.toBeGreaterThanOrEqual(expected: number)
		if type(actual) ~= "number" or not (actual >= expected) then
			fail(`expected {render(actual)} >= {expected}`)
		end
	end

	function matchers.toBeLessThan(expected: number)
		if type(actual) ~= "number" or not (actual < expected) then
			fail(`expected {render(actual)} < {expected}`)
		end
	end

	function matchers.toBeLessThanOrEqual(expected: number)
		if type(actual) ~= "number" or not (actual <= expected) then
			fail(`expected {render(actual)} <= {expected}`)
		end
	end

	function matchers.toContain(item: any)
		if type(actual) == "string" then
			if not string.find(actual, item, 1, true) then
				fail(`expected {render(actual)} to contain {render(item)}`)
			end
			return
		end
		if type(actual) == "table" then
			for _, v in actual do
				if deepEqual(v, item) then
					return
				end
			end
		end
		fail(`expected {render(actual)} to contain {render(item)}`)
	end

	function matchers.notToContain(item: any)
		if type(actual) == "string" then
			if string.find(actual, item, 1, true) then
				fail(`expected {render(actual)} not to contain {render(item)}`)
			end
			return
		end
		if type(actual) == "table" then
			for _, v in actual do
				if deepEqual(v, item) then
					fail(`expected {render(actual)} not to contain {render(item)}`)
				end
			end
		end
	end

	function matchers.toThrow(pattern: string?)
		local ok, err = pcall(actual)
		if ok then
			fail("expected function to throw")
		end
		if pattern and not string.find(tostring(err), pattern, 1, true) then
			fail(`expected error containing {render(pattern)}, got {render(tostring(err))}`)
		end
	end

	return matchers
end

local function collected(): { TestCase }
	return registered
end

return {
	describe = describe,
	it = it,
	expect = expect,
	collected = collected,
	render = render,
	deepEqual = deepEqual,
}
