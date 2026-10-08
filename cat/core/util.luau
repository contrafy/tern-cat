--!strict
-- Pure helpers shared by core modules. No Tern globals.

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function clamp(value: number, lo: number, hi: number): number
	if value ~= value then
		return lo
	end
	if value < lo then
		return lo
	end
	if value > hi then
		return hi
	end
	return value
end

local function clamp01(value: number): number
	return clamp(value, 0, 1)
end

local function deepCopy<V>(value: V): V
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[k] = deepCopy(v)
	end
	return out :: any
end

local function shallowCopy<K, V>(tbl: { [K]: V }): { [K]: V }
	return table.clone(tbl)
end

local function isArray(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	local n = 0
	for _ in value do
		n += 1
	end
	return n == #value
end

local function isDict(value: any): boolean
	return type(value) == "table" and (next(value) == nil or not isArray(value))
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

-- Returns a new table: `overlay` fields win; dictionaries merge recursively, arrays replace.
local function deepMerge(base: any, overlay: any): any
	local out = if type(base) == "table" then deepCopy(base) else {}
	if type(overlay) ~= "table" then
		return out
	end
	for k, v in overlay do
		local existing = out[k]
		if isDict(v) and next(v) ~= nil and isDict(existing) then
			out[k] = deepMerge(existing, v)
		else
			out[k] = deepCopy(v)
		end
	end
	return out
end

-- Returns a new list with `item` appended and only the newest `max` entries kept.
local function ringPush<V>(list: { V }, item: V, max: number): { V }
	local out = table.clone(list)
	table.insert(out, item)
	local excess = #out - math.max(max, 0)
	if excess > 0 then
		out = table.move(out, excess + 1, #out, 1, {})
	end
	return out
end

local function contains<V>(list: { V }, value: V): boolean
	return table.find(list, value) ~= nil
end

local function sortedKeys(tbl: { [any]: any }): { string }
	local keys = {}
	for k in tbl do
		table.insert(keys, tostring(k))
	end
	table.sort(keys)
	return keys
end

local function splitPath(path: string): { string }
	return string.split(path, ".")
end

local function getPath(tbl: any, path: string): any
	local cur = tbl
	for _, key in splitPath(path) do
		if type(cur) ~= "table" then
			return nil
		end
		cur = cur[key]
	end
	return cur
end

-- Returns a deep copy of `tbl` with `value` stored at the dotted `path`.
local function setPath(tbl: any, path: string, value: any): any
	local out = if type(tbl) == "table" then deepCopy(tbl) else {}
	local keys = splitPath(path)
	local cur = out
	for i = 1, #keys - 1 do
		local key = keys[i]
		if type(cur[key]) ~= "table" then
			cur[key] = {}
		end
		cur = cur[key]
	end
	cur[keys[#keys]] = deepCopy(value)
	return out
end

local function stripControl(s: string): string
	return (string.gsub(s, "%c", ""))
end

local function parseHm(value: any): { hour: number, min: number }?
	if type(value) ~= "string" then
		return nil
	end
	local h, m = string.match(value, "^(%d%d):(%d%d)$")
	if not h or not m then
		return nil
	end
	local hour, min = tonumber(h) :: number, tonumber(m) :: number
	if hour > 23 or min > 59 then
		return nil
	end
	return { hour = hour, min = min }
end

return {
	isFiniteNumber = isFiniteNumber,
	clamp = clamp,
	clamp01 = clamp01,
	deepCopy = deepCopy,
	shallowCopy = shallowCopy,
	deepEqual = deepEqual,
	deepMerge = deepMerge,
	isDict = isDict,
	ringPush = ringPush,
	contains = contains,
	isArray = isArray,
	sortedKeys = sortedKeys,
	getPath = getPath,
	setPath = setPath,
	stripControl = stripControl,
	parseHm = parseHm,
}
