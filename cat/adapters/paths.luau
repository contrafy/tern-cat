--!strict
-- Plugin file locations. Writable state lives under `data` (tern.plugin.data), never under `dir`.

export type Paths = {
	dir: string,
	data: string,
	inbox: string,
	config: string,
	exports: string,
	user_packs: string,
	bundled_packs: string,
	bundled_sounds: string,
	user_sounds: string,
	example_config: string,
	-- tern.kv's backing file (read only for corruption recovery).
	kv_file: string,
}

local function join(a: string, b: string): string
	if a == "" then
		return b
	end
	if string.sub(a, -1) == "/" then
		return a .. b
	end
	return a .. "/" .. b
end

local function fromPlugin(info: { dir: string, data: string }): Paths
	return {
		dir = info.dir,
		data = info.data,
		inbox = join(info.data, "inbox"),
		config = join(info.data, "config.json"),
		exports = join(info.data, "exports"),
		user_packs = join(info.data, "packs"),
		bundled_packs = join(info.dir, "assets/packs"),
		bundled_sounds = join(info.dir, "assets/sounds"),
		user_sounds = join(info.data, "sounds"),
		example_config = join(info.dir, "config/example.json"),
		kv_file = join(info.data, "kv.json"),
	}
end

local function current(): Paths
	return fromPlugin(tern.plugin)
end

return {
	join = join,
	fromPlugin = fromPlugin,
	current = current,
}
