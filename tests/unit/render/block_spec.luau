--!strict
local t = require("../../lib/test")
local factories = require("../../lib/factories")
local block = require("../../../cat/render/block")

local describe, it, expect = t.describe, t.it, t.expect

local function node(k: string, p: { [string]: any }?, c: { any }?): any
	return { k = k, p = p or {}, c = c }
end

local ui: block.Ui = {
	node = node,
	col = function(c)
		return node("col", nil, c)
	end,
	row = function(c)
		return node("row", nil, c)
	end,
	text = function(spans)
		return node("text", { spans = spans })
	end,
	span = function(text: string, s: string?)
		return { t = text, s = s }
	end,
	el = function(tag: string, p: { [string]: any }?, c: { any }?)
		local props = table.clone(p or {})
		props.tag = tag
		return node("el", props, c)
	end,
	meter = function(value: number, label: any)
		return node("meter", { value = value, label = label })
	end,
	badge = function(text: string, tone: string)
		return node("badge", { text = text, tone = tone })
	end,
}

local ANIMS = { "idle", "pet", "swat", "sleep" }

local function model(overrides: { [string]: any }?): block.Model
	local sprites = {}
	for _, a in ANIMS do
		table.insert(sprites, { anim = a, blob = "blob-" .. a })
	end
	local m: { [string]: any } = {
		page = "main",
		config = factories.config(),
		profile = factories.profile(),
		snoozed = false,
		sprites = sprites,
		active = "idle",
		seq = 3,
		one_shot = false,
		canvas = { width = 32, height = 32 },
		reaction = nil,
		current_reason = "Just hanging out.",
		ls_gag = false,
		notes = {},
		settings = nil,
	}
	for k, v in overrides or {} do
		m[k] = v
	end
	return m :: any
end

local function walk(n: any, fn: (any) -> ())
	if type(n) ~= "table" then
		return
	end
	if n.k then
		fn(n)
	end
	for _, child in n.c or {} do
		walk(child, fn)
	end
end

local function find(root: any, pred: (any) -> boolean): { any }
	local out = {}
	walk(root, function(n)
		if pred(n) then
			table.insert(out, n)
		end
	end)
	return out
end

local function images(root: any): { any }
	return find(root, function(n)
		return n.k == "image" and string.sub(n.p.key or "", 1, 2) == "s."
	end)
end

describe("block view", function()
	it("keeps one image per animation and shows exactly the active one", function()
		local v = block.view(model(), ui)
		local imgs = images(v.main)
		expect(#imgs).toBe(#ANIMS)
		local on = 0
		for _, img in imgs do
			if img.p.role == block.ROLE_ON then
				on += 1
				expect(img.p.blob).toBe("blob-idle")
				expect(img.p.actions.click).toBe("pet")
				expect(img.p.actions.dblclick).toBe("play")
				expect(img.p.actions.menu).toContain("feed-treat")
			else
				expect(img.p.role).toBe(block.ROLE_OFF)
				expect(img.p.actions).toBeNil()
			end
		end
		expect(on).toBe(1)
	end)

	it("scales the sprite by rendering.block_scale", function()
		local m = model({ config = factories.config({ rendering = { block_scale = 3 } }) })
		expect(images(block.view(m, ui).main)[1].p.w).toBe(96)
	end)

	it("re-keys a one-shot animation on every play and keeps loop keys stable", function()
		local a = images(block.view(model({ active = "pet", one_shot = true, seq = 4 }), ui).main)
		local b = images(block.view(model({ active = "pet", one_shot = true, seq = 5 }), ui).main)
		expect(a[2].p.key).toBe("s.pet.4")
		expect(b[2].p.key).toBe("s.pet.5")
		expect(a[1].p.key).toBe("s.idle")
		local loop = images(block.view(model({ active = "idle", seq = 9 }), ui).main)
		expect(loop[1].p.key).toBe("s.idle")
	end)

	it("shows needs only when enabled", function()
		local on = find(block.view(model(), ui).main, function(n)
			return n.k == "meter"
		end)
		expect(#on).toBe(4)
		local off = find(
			block.view(model({ config = factories.config({ needs = { enabled = false } }) }), ui).main,
			function(n)
				return n.k == "meter"
			end
		)
		expect(#off).toBe(0)
	end)

	it("shows the ls parody only for the swat reaction", function()
		local gag = function(m: block.Model): number
			return #find(block.view(m, ui).main, function(n)
				return n.k == "el" and n.p.class == "tc-tumble"
			end)
		end
		expect(gag(model())).toBe(0)
		expect(gag(model({ ls_gag = true, active = "swat" }))).toBe(1)
	end)

	it("switches dock buttons with snooze and overlay state", function()
		local acts = function(m: block.Model): { string }
			local out = {}
			for _, b in
				find(block.view(m, ui).dock, function(n)
					return n.k == "el" and n.p.tag == "button"
				end)
			do
				table.insert(out, b.p.actions.click)
			end
			return out
		end
		expect(acts(model())).toContain("snooze-30m")
		expect(acts(model())).toContain("overlay-off")
		expect(acts(model({ snoozed = true }))).toContain("wake")
		expect(acts(model({ config = factories.config({ rendering = { overlay = false } }) }))).toContain("overlay-on")
		expect(acts(model())).toContain("settings")
	end)

	it("shows recovery notes", function()
		local texts = find(block.view(model({ notes = { "Saved state was unreadable" } }), ui).main, function(n)
			return n.k == "text" and n.p.spans[1] and n.p.spans[1].s == "warning"
		end)
		expect(#texts).toBe(1)
	end)

	describe("settings", function()
		local function settingsModel(page: string, extra: { [string]: any }?): block.Model
			local s: { [string]: any } = {
				page = page,
				editing = nil,
				confirm_reset = false,
				packs = {
					{ id = "orange-menace", name = "Orange Menace", preview = "pv-o" },
					{ id = "void", name = "Void", preview = "pv-v" },
				},
				ai_reason = "Not available",
				last_export = nil,
			}
			for k, v in extra or {} do
				s[k] = v
			end
			return model({ page = "settings", settings = s })
		end

		local function prefs(m: block.Model): any
			return find(block.view(m, ui).main, function(n)
				return n.k == "prefs"
			end)[1]
		end

		it("keeps every sprite mounted but hidden while settings are open", function()
			local v = block.view(settingsModel("general"), ui)
			expect(#images(v.main)).toBe(#ANIMS)
			local stage = find(v.main, function(n)
				return n.p.key == "sprite"
			end)[1]
			expect(stage.p.hidden).toBe(true)
		end)

		it("builds the general page with config-path row ids", function()
			local p = prefs(settingsModel("general"))
			expect(p.p.page).toBe("general")
			local ids = {}
			for _, r in p.p.sections[1].rows do
				table.insert(ids, r.id)
			end
			expect(ids).toContain("behavior.activity")
			expect(ids).toContain("rendering.block_placement")
			expect(ids).toContain("rendering.overlay")
		end)

		it("marks rows changed from the preset baseline", function()
			local m = settingsModel("general")
			m.config = factories.config({ behavior = { activity = "zen" }, rendering = { overlay = false } })
			local rows = prefs(m).p.sections[1].rows
			for _, r in rows do
				if r.id == "rendering.overlay" then
					expect(r.changed).toBe(true)
					expect(r.defaultLabel).toBe("On")
				elseif r.id == "needs.enabled" then
					expect(r.changed).toBe(false)
				end
			end
		end)

		it("shows personality as percentages", function()
			local rows = prefs(settingsModel("personality")).p.sections[1].rows
			expect(rows[3].id).toBe("personality.mischief")
			expect(rows[3].control.value).toBe(85)
			expect(rows[3].control.unit).toBe("%")
		end)

		it("disables the AI switch with the provider's reason", function()
			local rows = prefs(settingsModel("ai")).p.sections[1].rows
			expect(rows[1].disabled).toBe("Not available")
			expect(rows[1].changed).toBe(false)
		end)

		it("asks for confirmation before resetting the identity", function()
			local first = prefs(settingsModel("identity")).p.sections[1].rows[2]
			expect(first.control.act).toBe("reset")
			local second = prefs(settingsModel("identity", { confirm_reset = true })).p.sections[1].rows[2]
			expect(second.control.act).toBe("reset-confirm")
			expect(second.warning).notToBeNil()
		end)

		it("previews packs on the appearance page", function()
			local v = block.view(settingsModel("appearance"), ui)
			local previews = find(v.main, function(n)
				return n.k == "image" and string.sub(n.p.key or "", 1, 3) == "pv."
			end)
			expect(#previews).toBe(2)
			expect(previews[2].p.actions.click).toBe("pack=void")
		end)

		it("keeps a non-hour quiet time selectable", function()
			local m = settingsModel("quiet")
			m.config = factories.config({ quiet = { start = "22:30" } })
			local start = prefs(m).p.sections[1].rows[2]
			expect(start.control.options[1].value).toBe("22:30")
		end)
	end)
end)
