--!strict
local t = require("../../lib/test")
local factories = require("../../lib/factories")
local support = require("../sprite/support")
local sound = require("../../../cat/integrations/sound")

local describe, it, expect = t.describe, t.it, t.expect

local AWAKE = { reduced_motion = false, quiet_hours = false, snoozed = false }

local function enabled(extra: { [string]: any }?): any
	local overrides: { [string]: any } = { sound = { enabled = true } }
	for k, v in extra or {} do
		overrides[k] = v
	end
	return factories.config(overrides)
end

local function decode(text: string): any
	return require("@lune/serde").decode("json", text)
end

local MANIFEST = [[{"schema_version":1,"id":"default","name":"Default","license":"CC-BY-4.0",
"sounds":{"meow":"meow.wav","purr":"purr.wav","surprise":"surprise.wav","happy":"happy.wav","swat":"swat.wav"}}]]

local function packFiles(manifestText: string?): { [string]: string }
	return {
		["/s/default/sounds.json"] = manifestText or MANIFEST,
		["/s/default/meow.wav"] = "RIFF",
		["/s/default/purr.wav"] = "RIFF",
		["/s/default/surprise.wav"] = "RIFF",
		["/s/default/happy.wav"] = "RIFF",
		["/s/default/swat.wav"] = "RIFF",
	}
end

describe("sound", function()
	describe("policy", function()
		it("never plays when sound is disabled (the default)", function()
			local ok, why = sound.policy(factories.config(), "purr", AWAKE, 10000, sound.newState())
			expect(ok).toBe(false)
			expect(why).toBe("sound disabled")
		end)

		it("plays an enabled event when nothing else blocks it", function()
			expect((sound.policy(enabled(), "purr", AWAKE, 10000, sound.newState()))).toBe(true)
		end)

		it("ignores decisions without a sound", function()
			expect((sound.policy(enabled(), nil, AWAKE, 10000, sound.newState()))).toBe(false)
		end)

		it("respects per-event toggles", function()
			local cfg = enabled({ sound = { enabled = true, events = { purr = false } } })
			expect((sound.policy(cfg, "purr", AWAKE, 10000, sound.newState()))).toBe(false)
			expect((sound.policy(cfg, "meow", AWAKE, 10000, sound.newState()))).toBe(true)
		end)

		it("stays quiet during quiet hours unless told otherwise", function()
			local quiet = { reduced_motion = false, quiet_hours = true, snoozed = false }
			expect((sound.policy(enabled(), "meow", quiet, 10000, sound.newState()))).toBe(false)
			local cfg = enabled({ sound = { enabled = true, respect_quiet_hours = false } })
			expect((sound.policy(cfg, "meow", quiet, 10000, sound.newState()))).toBe(true)
		end)

		it("stays quiet while snoozed", function()
			local snoozed = { reduced_motion = false, quiet_hours = false, snoozed = true }
			expect((sound.policy(enabled(), "meow", snoozed, 10000, sound.newState()))).toBe(false)
		end)

		it("rate limits to one sound every two seconds", function()
			local state = sound.newState()
			expect((sound.policy(enabled(), "meow", AWAKE, 10000, state))).toBe(true)
			sound.markPlayed(state, 10000)
			expect((sound.policy(enabled(), "meow", AWAKE, 11999, state))).toBe(false)
			expect((sound.policy(enabled(), "meow", AWAKE, 12000, state))).toBe(true)
		end)

		it("never plays at volume zero", function()
			local cfg = enabled({ sound = { enabled = true, volume = 0 } })
			expect((sound.policy(cfg, "meow", AWAKE, 10000, sound.newState()))).toBe(false)
		end)
	end)

	describe("pack", function()
		it("loads a valid pack with absolute file paths", function()
			local fs = support.memoryFs(packFiles())
			local pack, err = sound.loadPack(fs, decode, { "/s" }, "default")
			expect(err).toBeNil()
			local p = pack :: any
			expect(p.id).toBe("default")
			expect(p.files.purr).toBe("/s/default/purr.wav")
		end)

		it("rejects traversal, absolute paths and unknown extensions", function()
			for _, bad in { "../x.wav", "/etc/passwd.wav", "a/./b.wav", "x.sh", "x.WAV", "c:x.wav", "a b.wav" } do
				local text = string.gsub(MANIFEST, '"meow.wav"', '"' .. bad .. '"')
				local fs = support.memoryFs(packFiles(text))
				local pack = sound.loadPack(fs, decode, { "/s" }, "default") :: any
				expect(pack.files.meow).toBeNil()
				expect(pack.files.purr).toBe("/s/default/purr.wav")
			end
		end)

		it("ignores unknown sound ids and missing files", function()
			local text = string.gsub(MANIFEST, '"swat":"swat.wav"', '"swat":"gone.wav","bark":"meow.wav"')
			local fs = support.memoryFs(packFiles(text))
			local pack = sound.loadPack(fs, decode, { "/s" }, "default") :: any
			expect(pack.files.swat).toBeNil()
			expect(pack.files.bark).toBeNil()
		end)

		it("rejects invalid pack ids before touching the filesystem", function()
			local fs, log = support.memoryFs(packFiles())
			local pack, err = sound.loadPack(fs, decode, { "/s" }, "../etc")
			expect(pack).toBeNil()
			expect(err).notToBeNil()
			expect(#log).toBe(0)
		end)

		it("reports a missing pack", function()
			local fs = support.memoryFs({})
			local pack, err = sound.loadPack(fs, decode, { "/s" }, "default")
			expect(pack).toBeNil()
			expect(err).notToBeNil()
		end)

		it("rejects a manifest whose id does not match its folder", function()
			local text = string.gsub(MANIFEST, '"id":"default"', '"id":"other"')
			local fs = support.memoryFs(packFiles(text))
			expect((sound.loadPack(fs, decode, { "/s" }, "default"))).toBeNil()
		end)

		it("loads the bundled default pack from the repo", function()
			local pack = sound.loadPack(support.luneFs(), decode, { "assets/sounds" }, "default") :: any
			expect(pack).notToBeNil()
			for _, id in { "meow", "purr", "surprise", "happy", "swat" } do
				expect(pack.files[id]).toBe("assets/sounds/default/" .. id .. ".wav")
			end
		end)
	end)

	describe("players", function()
		it("uses afplay on macOS", function()
			local p = sound.choosePlayer("macos", { afplay = "/usr/bin/afplay" }) :: any
			expect(p.kind).toBe("afplay")
			expect(p.bin).toBe("/usr/bin/afplay")
		end)

		it("prefers pw-play, then paplay, then aplay on Linux", function()
			local all = { ["pw-play"] = "/usr/bin/pw-play", paplay = "/usr/bin/paplay", aplay = "/usr/bin/aplay" }
			expect((sound.choosePlayer("linux", all) :: any).kind).toBe("pw-play")
			expect((sound.choosePlayer("linux", { paplay = "/b/paplay", aplay = "/b/aplay" }) :: any).kind).toBe(
				"paplay"
			)
			expect((sound.choosePlayer("linux", { aplay = "/b/aplay" }) :: any).kind).toBe("aplay")
			expect(sound.choosePlayer("linux", {})).toBeNil()
			expect(sound.choosePlayer("windows", all)).toBeNil()
		end)

		it("parses `command -v` output into absolute paths only", function()
			local found = sound.parseCommandV("/usr/bin/paplay\n/usr/bin/aplay\nalias pw-play=x\nrelative/aplay\n")
			expect(found.paplay).toBe("/usr/bin/paplay")
			expect(found.aplay).toBe("/usr/bin/aplay")
			expect(found["pw-play"]).toBeNil()
		end)

		it("builds fixed argv with the volume for each player", function()
			expect(sound.argv({ kind = "afplay", bin = "/usr/bin/afplay" }, "/p/purr.wav", 0.25)).toEqual({
				"/usr/bin/afplay",
				"-v",
				"0.25",
				"/p/purr.wav",
			})
			expect(sound.argv({ kind = "pw-play", bin = "/b/pw-play" }, "/p/a.wav", 0.5)).toEqual({
				"/b/pw-play",
				"--volume",
				"0.50",
				"/p/a.wav",
			})
			expect(sound.argv({ kind = "paplay", bin = "/b/paplay" }, "/p/a.wav", 0.5)).toEqual({
				"/b/paplay",
				"--volume=32768",
				"/p/a.wav",
			})
			expect(sound.argv({ kind = "aplay", bin = "/b/aplay" }, "/p/a.wav", 0.5)).toEqual({
				"/b/aplay",
				"-q",
				"/p/a.wav",
			})
		end)

		it("detects afplay on macOS without running a process", function()
			local runs = 0
			local got: any = "pending"
			sound.detect("macos", function(path: string)
				return path == "/usr/bin/afplay"
			end, function()
				runs += 1
			end, function(player: any)
				got = player
			end)
			expect(runs).toBe(0)
			expect(got.kind).toBe("afplay")
		end)

		it("detects Linux players with one fixed probe command", function()
			local seen: any = nil
			local got: any = "pending"
			sound.detect("linux", function()
				return false
			end, function(argv: { string }, _opts: any, cb: (any) -> ())
				seen = argv
				cb({ status = 0, stdout = "/usr/bin/aplay\n", stderr = "", timed_out = false })
			end, function(player: any)
				got = player
			end)
			expect(seen).toEqual({ "sh", "-c", "command -v pw-play paplay aplay" })
			expect(got.kind).toBe("aplay")
		end)

		it("falls back to silence when probing raises", function()
			local got: any = "pending"
			sound.detect("linux", function()
				return false
			end, function()
				error("spawn failed")
			end, function(player: any)
				got = player
			end)
			expect(got).toBeNil()
		end)
	end)
end)
