--!strict
-- Block view builder (host). Pure: takes a view model and the ui builders (tern.ui in Tern, a
-- recording fake in tests). Every animation keeps its image node in the view and only `role`
-- changes, so every blob stays referenced for windows that attach later; a one-shot animation
-- gets a fresh key per play so its APNG restarts.

local T = require("../types")
local util = require("../core/util")
local schema = require("../config/schema")
local controls = require("../host/controls")

local ROLE_ON = "tern-cat.sprite"
local ROLE_OFF = "tern-cat.sprite-off"
local PREFS_TITLE = "Tern Cat"

export type Ui = {
	node: (kind: string, props: { [string]: any }?, children: { any }?) -> any,
	col: (children: { any }) -> any,
	row: (children: { any }) -> any,
	text: (spans: any) -> any,
	span: (t: string, s: string?) -> any,
	el: (tag: string, props: { [string]: any }?, children: { any }?) -> any,
	meter: (value: number, label: any) -> any,
	badge: (t: string, tone: string) -> any,
}

export type Sprite = { anim: string, blob: string }

export type PackChoice = { id: string, name: string, preview: string? }

export type SettingsModel = {
	page: string,
	editing: string?,
	confirm_reset: boolean,
	packs: { PackChoice },
	ai_reason: string,
	last_export: string?,
}

export type Model = {
	page: string,
	config: T.Config,
	profile: T.Profile,
	snoozed: boolean,
	sprites: { Sprite },
	active: string,
	seq: number,
	one_shot: boolean,
	canvas: { width: number, height: number },
	reaction: T.ReactionRecord?,
	current_reason: string?,
	ls_gag: boolean,
	notes: { string },
	settings: SettingsModel?,
}

local function withProps(node: any, props: { [string]: any }): any
	local p = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- Sprite ------------------------------------------------------------------------------------

local function spriteStack(model: Model, ui: Ui): any
	local scale = model.config.rendering.block_scale
	local w = model.canvas.width * scale
	local h = model.canvas.height * scale
	local menu = controls.menuActions(model.snoozed, model.config.rendering.overlay)
	local nodes = {}
	for _, sprite in model.sprites do
		local active = sprite.anim == model.active
		local key = if active and model.one_shot then `s.{sprite.anim}.{model.seq}` else `s.{sprite.anim}`
		local props: { [string]: any } = {
			key = key,
			blob = sprite.blob,
			alt = `{model.config.cat.name} ({sprite.anim})`,
			role = if active then ROLE_ON else ROLE_OFF,
			w = w,
			h = h,
		}
		if active then
			props.title = "Click to pet, double-click to play, right-click for more"
			props.actions = { click = "pet", dblclick = "play", menu = menu }
		end
		table.insert(nodes, ui.node("image", props))
	end
	return withProps(ui.col(nodes), { key = "sprite", role = "tern-cat.stage" })
end

-- Main --------------------------------------------------------------------------------------

local MOOD_TONE: { [string]: string } = {
	calm = "neutral",
	playful = "accent",
	sleepy = "muted",
	annoyed = "warning",
	curious = "info",
	happy = "success",
}

local function needsMeters(model: Model, ui: Ui): { any }
	local n = model.profile.needs
	local rows: { { label: string, value: number } } = {
		{ label = "fed", value = 1 - n.hunger },
		{ label = "energy", value = n.energy },
		{ label = "love", value = n.affection },
		{ label = "fun", value = 1 - n.boredom },
	}
	local out = {}
	for _, r in rows do
		local meter = ui.meter(util.clamp01(r.value), { ui.span(r.label, "muted") })
		table.insert(out, withProps(meter, { key = `need.{r.label}` }))
	end
	return out
end

local function statsLine(model: Model, ui: Ui): any
	local s = model.profile.stats
	return ui.text({
		ui.span("pets ", "muted"),
		ui.span(tostring(s.pets), "num"),
		ui.span("  feeds ", "muted"),
		ui.span(tostring(s.feeds), "num"),
		ui.span("  plays ", "muted"),
		ui.span(tostring(s.plays), "num"),
		ui.span("  pokes ", "muted"),
		ui.span(tostring(s.pokes), "num"),
		ui.span("  reactions ", "muted"),
		ui.span(tostring(s.command_reactions), "num"),
	})
end

-- The block-only parody of knocking a letter off `ls` output: a fixed fake listing, never
-- real terminal text.
local function lsGag(model: Model, ui: Ui): any
	return ui.el("div", { class = "tc-ls", key = `ls.{model.seq}` }, {
		ui.el("span", { class = "tc-prompt", text = "$ ls" }),
		ui.el("span", { class = "tc-entry", text = "README.md" }),
		ui.el("span", { class = "tc-entry", text = "src" }),
		ui.el("span", { class = "tc-entry", text = "test" }),
		ui.el("span", { class = "tc-tumble", text = "s" }),
	})
end

local function info(model: Model, ui: Ui): any
	local children: { any } = {
		ui.row({
			ui.text({ ui.span(model.config.cat.name, "strong") }),
			withProps(ui.badge(model.profile.mood, MOOD_TONE[model.profile.mood] or "neutral"), { key = "mood" }),
			if model.snoozed then withProps(ui.badge("snoozed", "muted"), { key = "snoozed" }) else nil,
		}),
	}
	if model.config.needs.enabled then
		for _, m in needsMeters(model, ui) do
			table.insert(children, m)
		end
	end
	table.insert(children, statsLine(model, ui))
	if model.current_reason then
		table.insert(children, ui.text({ ui.span("now ", "muted"), ui.span(model.current_reason :: string) }))
	end
	local r = model.reaction
	if r then
		table.insert(
			children,
			ui.text({ ui.span("last ", "muted"), ui.span(r.animation, "strong"), ui.span(" " .. r.reason, "muted") })
		)
	end
	for _, note in model.notes do
		table.insert(children, ui.text({ ui.span(note, "warning") }))
	end
	return withProps(ui.col(children), { key = "info", grow = 1 })
end

local function button(ui: Ui, label: string, act: string, extra: { [string]: any }?): any
	local actions: { [string]: any } = { click = act }
	local props: { [string]: any } =
		{ class = "tc-btn", text = label, key = `btn.{act}`, attrs = { ["data-act"] = act } }
	if extra then
		for k, v in extra do
			if k == "menu" then
				actions.menu = v
			else
				props[k] = v
			end
		end
	end
	props.actions = actions
	return ui.el("button", props)
end

local function dock(model: Model, ui: Ui): any
	if model.page == "settings" then
		return ui.col({ ui.row({ button(ui, "Close settings", "close-settings") }) })
	end
	local overlay = model.config.rendering.overlay
	return ui.col({
		withProps(
			ui.row({
				button(ui, "Pet", "pet", { title = "p" }),
				button(ui, "Poke", "poke", { title = "o" }),
				button(
					ui,
					"Feed",
					"feed",
					{ title = "f; right-click for treats", menu = { "feed-treat", "feed-kibble", "feed-fish" } }
				),
				button(
					ui,
					"Play",
					"play",
					{ title = "space; right-click for toys", menu = { "play-ball", "play-string", "play-feather" } }
				),
				if model.snoozed
					then button(ui, "Wake", "wake", { title = "z" })
					else button(ui, "Snooze 30m", "snooze-30m", { title = "z" }),
				if overlay
					then button(ui, "Overlay off", "overlay-off", { title = "h" })
					else button(ui, "Overlay on", "overlay-on", { title = "h" }),
				button(ui, "Settings", "settings", { title = "s" }),
			}),
			{ key = "buttons", role = "tern-cat.buttons", wrap = true }
		),
	})
end

-- Settings ----------------------------------------------------------------------------------

local PAGES = {
	{ id = "general", label = "General", icon = "sliders" },
	{ id = "appearance", label = "Appearance", icon = "palette" },
	{ id = "personality", label = "Personality", icon = "sparkle" },
	{ id = "behavior", label = "Behavior", icon = "activity" },
	{ id = "quiet", label = "Quiet hours & sound", icon = "moon" },
	{ id = "ai", label = "AI", icon = "brain" },
	{ id = "identity", label = "Identity", icon = "user" },
}

local function baseline(config: T.Config): any
	return util.deepMerge(schema.defaults(), schema.preset(config.behavior.activity))
end

local function choiceOptions(values: { string }, labels: { [string]: string }?): { any }
	local out = {}
	for _, v in values do
		table.insert(out, { value = v, label = if labels then labels[v] or v else v })
	end
	return out
end

local function hourOptions(current: string): { any }
	local out = {}
	local seen = false
	for h = 0, 23 do
		local v = string.format("%02d:00", h)
		seen = seen or v == current
		table.insert(out, { value = v, label = v })
	end
	if not seen then
		table.insert(out, 1, { value = current, label = current })
	end
	return out
end

type RowOpts = { label: string, hint: string?, disabled: string? }

local function row(config: T.Config, base: any, path: string, opts: RowOpts, control: { [string]: any }): any
	local value = util.getPath(config, path)
	local default = util.getPath(base, path)
	local changed = not util.deepEqual(value, default)
	local defaultLabel: string? = nil
	if type(default) == "boolean" then
		defaultLabel = if default then "On" else "Off"
	elseif type(default) == "number" then
		defaultLabel = tostring(if controls.isPercent(path) then math.floor(default * 100 + 0.5) else default)
	elseif type(default) == "string" then
		defaultLabel = default
	end
	return {
		id = path,
		label = opts.label,
		hint = opts.hint,
		disabled = opts.disabled,
		changed = changed and opts.disabled == nil,
		defaultLabel = defaultLabel,
		control = control,
	}
end

local function switch(config: T.Config, base: any, path: string, label: string, hint: string?): any
	return row(
		config,
		base,
		path,
		{ label = label, hint = hint },
		{ k = "switch", on = util.getPath(config, path) == true }
	)
end

local function percent(config: T.Config, base: any, path: string, label: string, hint: string?): any
	return row(config, base, path, { label = label, hint = hint }, {
		k = "number",
		value = controls.displayValue(config, path),
		min = 0,
		max = 100,
		step = 5,
		unit = "%",
	})
end

local function sections(model: Model, s: SettingsModel): { any }
	local c = model.config
	local base = baseline(c)
	local page = s.page
	if page == "general" then
		return {
			{
				id = "general",
				title = "General",
				rows = {
					row(c, base, "behavior.activity", {
						label = "Activity preset",
						hint = "Granular toggles below still win over the preset.",
					}, {
						k = "choice",
						style = "menu",
						value = c.behavior.activity,
						options = choiceOptions(schema.ACTIVITIES, {
							quiet_office = "Quiet office",
							orange_menace = "Orange menace",
							chaos = "Chaos",
							zen = "Zen",
						}),
					}),
					switch(
						c,
						base,
						"needs.enabled",
						"Needs",
						"Hunger, energy, affection and boredom. Never punishing."
					),
					switch(c, base, "rendering.overlay", "Window overlay", "The decorative cat over the focused pane."),
					row(c, base, "rendering.block_placement", { label = "Block placement" }, {
						k = "choice",
						value = c.rendering.block_placement,
						options = choiceOptions({ "float", "split" }, { float = "Floating corner", split = "Split" }),
					}),
					row(c, base, "rendering.reduced_motion", { label = "Reduced motion" }, {
						k = "choice",
						value = c.rendering.reduced_motion,
						options = choiceOptions(
							{ "follow_tern", "on", "off" },
							{ follow_tern = "Follow Tern", on = "On", off = "Off" }
						),
					}),
					row(c, base, "rendering.block_scale", { label = "Sprite scale" }, {
						k = "number",
						value = c.rendering.block_scale,
						min = 1,
						max = 12,
						unit = "x",
					}),
					switch(
						c,
						base,
						"controls.keyboard_enabled",
						"Keyboard shortcuts",
						"Only while this block has focus."
					),
				},
			},
		}
	elseif page == "appearance" then
		local options = {}
		for _, p in s.packs do
			table.insert(options, { value = p.id, label = p.name })
		end
		return {
			{
				id = "appearance",
				title = "Appearance",
				rows = {
					row(c, base, "cat.appearance", { label = "Sprite pack" }, {
						k = "choice",
						style = "menu",
						value = c.cat.appearance,
						options = options,
					}),
				},
			},
		}
	elseif page == "personality" then
		return {
			{
				id = "personality",
				title = "Personality",
				rows = {
					percent(c, base, "personality.curiosity", "Curiosity"),
					percent(c, base, "personality.affection", "Affection"),
					percent(c, base, "personality.mischief", "Mischief"),
					percent(c, base, "personality.energy", "Energy"),
					percent(c, base, "personality.talkativeness", "Talkativeness"),
				},
			},
		}
	elseif page == "behavior" then
		return {
			{
				id = "behavior",
				title = "Behavior",
				rows = {
					switch(c, base, "behavior.allow_command_reactions", "React to commands"),
					switch(c, base, "behavior.allow_development_reactions", "React to tests and listings"),
					switch(c, base, "behavior.allow_swats", "Swats and mischief"),
					switch(c, base, "behavior.allow_pane_reactions", "React to panes opening and closing"),
					switch(c, base, "behavior.allow_idle_sleep", "Nap when idle"),
					switch(c, base, "behavior.allow_pacing", "Pace around (overlay)"),
					switch(c, base, "behavior.allow_visual_obscuring", "Draw over terminal panes (overlay)"),
					percent(c, base, "behavior.reaction_sample_rate", "Reaction rate"),
					row(c, base, "behavior.reaction_cooldown_s", { label = "Reaction cooldown" }, {
						k = "number",
						value = c.behavior.reaction_cooldown_s,
						min = 0,
						max = 3600,
						step = 15,
						unit = "s",
					}),
				},
			},
		}
	elseif page == "quiet" then
		return {
			{
				id = "quiet",
				title = "Quiet hours",
				rows = {
					switch(c, base, "quiet.hours_enabled", "Quiet hours", "Only naps, blinks and grooming; no sound."),
					row(c, base, "quiet.start", { label = "Start" }, {
						k = "choice",
						style = "menu",
						value = c.quiet.start,
						options = hourOptions(c.quiet.start),
					}),
					row(c, base, "quiet.stop", { label = "Stop" }, {
						k = "choice",
						style = "menu",
						value = c.quiet.stop,
						options = hourOptions(c.quiet.stop),
					}),
				},
			},
			{
				id = "focus",
				title = "Focus mode",
				rows = {
					switch(
						c,
						base,
						"behavior.focus_mode",
						"Keep still while commands run",
						"No pacing, reactions or sound until they finish; pets and treats still work."
					),
				},
			},
			{
				id = "sound",
				title = "Sound",
				rows = {
					switch(
						c,
						base,
						"sound.enabled",
						"Sound effects",
						"Off by default. Played with the system audio player."
					),
					percent(c, base, "sound.volume", "Volume"),
					switch(c, base, "sound.respect_quiet_hours", "Silent during quiet hours"),
					(function()
						local values = {}
						for _, id in schema.SOUND_IDS do
							if c.sound.events[id] ~= false then
								table.insert(values, id)
							end
						end
						return row(c, base, "sound.events", { label = "Sounds" }, {
							k = "multi",
							values = values,
							options = choiceOptions(schema.SOUND_IDS),
						})
					end)(),
				},
			},
		}
	elseif page == "ai" then
		return {
			{
				id = "ai",
				title = "AI reactions",
				rows = {
					row(c, base, "ai.enabled", { label = "AI reactions", disabled = s.ai_reason }, {
						k = "switch",
						on = false,
					}),
					{
						id = "ai.clear",
						label = "Clear AI state",
						hint = "Removes AI entries from the cat's journal.",
						control = { k = "action", act = "clear-ai", label = "Clear" },
					},
				},
			},
		}
	elseif page == "identity" then
		return {
			{
				id = "identity",
				title = "Identity",
				rows = {
					{
						id = "identity.export",
						label = "Export identity",
						hint = s.last_export or "Writes the cat's profile as JSON to the plugin's exports folder.",
						control = { k = "action", act = "export", label = "Export" },
					},
					{
						id = "identity.reset",
						label = "Reset identity",
						hint = "A new cat moves in: stats and journal start over.",
						warning = if s.confirm_reset then "Click Confirm to replace this cat." else nil,
						control = {
							k = "action",
							act = if s.confirm_reset then "reset-confirm" else "reset",
							label = if s.confirm_reset then "Confirm" else "Reset...",
						},
					},
				},
			},
		}
	end
	return {}
end

local function prefsProps(model: Model): { [string]: any }
	local s = model.settings :: SettingsModel
	return {
		key = "prefs",
		title = PREFS_TITLE,
		pages = PAGES,
		page = s.page,
		sections = sections(model, s),
		editing = if s.editing then { row = s.editing } else nil,
	}
end

local function packPreviews(model: Model, ui: Ui): any
	local s = model.settings :: SettingsModel
	local cards = {}
	for _, p in s.packs do
		if p.preview then
			table.insert(
				cards,
				ui.node("image", {
					key = `pv.{p.id}`,
					blob = p.preview,
					alt = p.name,
					title = p.name,
					role = if p.id == model.config.cat.appearance then "tern-cat.preview-on" else "tern-cat.preview",
					w = 64,
					h = 64,
					actions = { click = `pack={p.id}` },
				})
			)
		end
	end
	return withProps(ui.row(cards), { key = "previews" })
end

local function view(model: Model, ui: Ui): { [string]: any }
	local stage = spriteStack(model, ui)
	if model.page == "settings" and model.settings then
		local children: { any } = {}
		if (model.settings :: SettingsModel).page == "appearance" then
			table.insert(children, packPreviews(model, ui))
		end
		return {
			main = ui.col({
				withProps(stage, { hidden = true }),
				withProps(
					ui.text({
						ui.span(`{model.config.cat.name} settings`, "strong"),
						ui.span(" · saved to config.json", "muted"),
					}),
					{ key = "settings.hint" }
				),
				ui.node("prefs", prefsProps(model), children),
			}),
			dock = dock(model, ui),
		}
	end
	local top = withProps(ui.row({ stage, info(model, ui) }), { key = "top", align = "start", gap = "md" })
	local main: { any } = { top }
	if model.ls_gag then
		table.insert(main, lsGag(model, ui))
	end
	return {
		main = ui.col(main),
		dock = dock(model, ui),
	}
end

local function title(model: Model): string
	return `Tern Cat · {model.config.cat.name}`
end

return {
	ROLE_ON = ROLE_ON,
	ROLE_OFF = ROLE_OFF,
	PAGES = PAGES,
	view = view,
	title = title,
	prefsProps = prefsProps,
	spriteStack = spriteStack,
}
