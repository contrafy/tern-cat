# Configuration

tern-cat reads one human-editable JSON file. Every key is optional: a missing key takes its
default, and an invalid value falls back to its default on its own (the rest of the file still
applies). The annotated full file is [`config/example.json`](../config/example.json).

## Where the file lives

The file is `<tern.plugin.data>/config.json`, inside the plugin's data folder. Tern creates that
folder at `<state>/plugin-data/tern-cat/`:

| Platform | Path |
|---|---|
| macOS | `~/Library/Application Support/Tern/plugin-data/tern-cat/config.json` |
| Linux | `$XDG_STATE_HOME/tern/plugin-data/tern-cat/config.json` (default `~/.local/state/tern/plugin-data/tern-cat/config.json`) |
| `TERN_CONFIG_DIR` set | `$TERN_CONFIG_DIR/plugin-data/tern-cat/config.json` |

The Linux and macOS paths are from Tern's documentation
([Packages and Manifests, Directories](https://docs.stencil.so/tern/concepts/packages.html#directories));
the macOS and `TERN_CONFIG_DIR` forms were also observed in sandboxes. The Linux path was not
checked on a Linux machine.

To find it:

- `tern plugin dir` prints `<config>/plugins`. On macOS, and whenever `TERN_CONFIG_DIR` is set,
  `<config>` and `<state>` are the same folder, so the data folder is the sibling
  `plugin-data/tern-cat/` of that directory. On Linux they differ (`~/.config/tern` versus
  `~/.local/state/tern`), so use the table above.
- The palette command **Reload config** (group Tern Cat) shows the config path in its toast.

The file is created from `config/example.json` the first time the plugin runs if it does not
exist. The settings page in the block changes only the edited keys in your existing file and
writes it back as pretty JSON in the example's key order. If the file is not valid JSON, the cat uses the defaults, shows
`config.json is not valid JSON; using defaults` in the block, and leaves the file untouched. If a
settings change has to replace an unparsable file, the old file is first saved as
`config.json.broken-<unix seconds>`.

If `config.json` exists but cannot be read at all (it is a symlink, it is larger than 256 KiB, or
the read fails), the file is never written: the block shows a note, settings changes from the
block, the overlay toggle or Carly fail with an error instead of replacing the file, and the
cat keeps its current settings (the defaults if it could not be read at startup). Replace the
symlink with a regular file or shrink the file; the note clears once it reads again.

Unknown keys are ignored with a warning in the log. Older files may still contain
`rendering.animation_fps` and `behavior.obscure_max_ms`; they never had an effect and were
removed, so they now only produce that warning.

Changes are picked up within about 3 seconds (the host and each window re-read the file every
3 s) or immediately with **Reload config**.

## Precedence

From lowest to highest:

1. Built-in defaults (the values in the tables below).
2. The preset named by `behavior.activity`.
3. Keys you set explicitly in `config.json`.

So a preset only changes the keys you did not set yourself. For example, with
`"activity": "zen"` and `"allow_pacing": true`, the cat paces even though `zen` turns pacing off.

At run time, some state ranks above config: snooze, then quiet hours, then focus mode (while a
command runs), then reduced motion, then the `allow_*` toggles, then preset and personality
weights ([architecture.md](architecture.md#behavior-engine)).

## Presets (`behavior.activity`)

| Preset | Changes from the defaults |
|---|---|
| `orange_menace` (default) | None. |
| `quiet_office` | `personality`: mischief 0.3, energy 0.4, talkativeness 0.05. `behavior`: `allow_visual_obscuring`, `allow_swats` and `allow_pacing` off, `focus_mode` on, `reaction_sample_rate` 0.1, `reaction_cooldown_s` 180. No overlay over terminal panes; fewer swats and hops; the cat keeps still while commands run. |
| `chaos` | `personality`: curiosity 1, mischief 1, energy 0.95, talkativeness 0.4. Every `allow_*` toggle on, `reaction_sample_rate` 0.8, `reaction_cooldown_s` 10. About three times as many swats and hops, twice as much walking. |
| `zen` | `personality`: curiosity 0.4, mischief 0.1, energy 0.15, talkativeness 0.05. `allow_visual_obscuring`, `allow_swats` and `allow_pacing` off, `allow_idle_sleep` on, `reaction_sample_rate` 0.05, `reaction_cooldown_s` 600. No overlay over terminal panes; mostly sitting and sleeping. |

## Keys

`schema_version` (integer, default `1`) is the file format version. Leave it as is; older
versions are migrated on load.

### `cat`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `name` | string, 1-32 characters | `"Orange Menace"` | Name shown in the block and in Carly's context line (control characters and quotes are stripped there). Renames use the same limit. |
| `appearance` | pack id (`^[a-z][a-z0-9-]*$`, at most 32) | `"orange-menace"` | Sprite pack. Bundled: `orange-menace`, `void`, `tuxedo`. User packs go in `<data>/packs/<id>/` ([sprite-pack-spec.md](sprite-pack-spec.md)). An unknown or invalid pack falls back to the default pack. |

### `personality`

All numbers from 0 to 1. The settings page shows them as percentages.

| Key | Default | Meaning |
|---|---|---|
| `curiosity` | `0.9` | More `look`; more `hop` (rather than `look`) when panes open or close. |
| `affection` | `0.65` | Lower affection makes a poke more likely to startle the cat, and a failed command more likely to show `disappointed`. |
| `mischief` | `0.85` | More ambient `swat`/`hop`; more swats when you play and after `ls`. |
| `energy` | `0.75` | More `stretch` and `walk`; the cat waits longer (2-10 min) before settling down when you are away. |
| `talkativeness` | `0.15` | Chance of a hungry `meow` look when hunger is high. |

### `needs`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | boolean | `true` | Hunger, energy, affection and boredom change over time. They never punish: stats are never reduced. |
| `offline_progress` | boolean | `true` | Simulate time that passed while Tern was closed (awake for up to an hour, then napping). Off: only a short gap counts. |
| `offline_hours_cap` | number 0-168 | `12` | Cap on simulated offline hours. Applies only to time away; needs keep changing while Tern is open (a napping cat regains energy) even with `0`. |

### `rendering`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `overlay` | boolean | `true` | Show the decorative overlay cat in every window. Toggled by **Hide or show the overlay cat**, the global chord, the block's Overlay button or `h`. |
| `overlay_scale` | integer 1-8 | `2` | Pixel scale of the overlay sprite. |
| `block_scale` | integer 1-12 | `4` | Pixel scale of the sprite in the block. |
| `reduced_motion` | `"follow_tern"`, `"on"`, `"off"` | `"follow_tern"` | `on`: still frames in the overlay and the block. `follow_tern`: the overlay follows Tern's reduced-motion setting; the block keeps animating (the host cannot read that setting). `off`: does not override Tern: when Tern reduces motion, its stylesheet stops every animation, including the cat's. |
| `block_placement` | `"float"`, `"split"` | `"float"` | How the palette command **Open cat** (and **Cat settings**) places a new block: a floating card in the bottom-right corner of the focused pane, or a split beside it. If floating fails the block stays a split. |

### `behavior`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `activity` | `"quiet_office"`, `"orange_menace"`, `"chaos"`, `"zen"` | `"orange_menace"` | Preset (see above). |
| `allow_visual_obscuring` | boolean | `true` | Settings label "Draw over terminal panes (overlay)". `false`: the overlay cat is not drawn over terminal panes at all, so it never covers your text; the block cat is unaffected. `rendering.overlay` hides the overlay everywhere. |
| `allow_swats` | boolean | `true` | Allows `swat` and ambient `hop`, the swat when you play, and the `ls` swat. |
| `allow_command_reactions` | boolean | `true` | React to commands finishing (and `stare` at `sudo`). |
| `allow_development_reactions` | boolean | `true` | Development-specific reactions: `flop` after 3 failed test runs in a row, the `ls` swat. |
| `allow_pane_reactions` | boolean | `true` | `look`/`hop` when a pane opens or closes. |
| `allow_idle_sleep` | boolean | `true` | Naps when tired or when you are away. |
| `allow_pacing` | boolean | `true` | `walk` (the overlay cat paces along the pane's bottom edge). |
| `focus_mode` | boolean | `false` (`true` in `quiet_office`) | Keep still while a command runs (see below). |
| `reaction_sample_rate` | number 0-1 | `0.35` | Chance that a finished command gets a reaction. |
| `reaction_cooldown_s` | integer 0-3600 | `45` | Minimum seconds between reactions of the same kind. |

With `focus_mode` on, while any command runs the cat only idles, sits, blinks, grooms or sleeps:
no pacing, hops, swats, stares or command and pane reactions, and no sound. A moving animation
already playing stops when the command starts. Your own pets, pokes, treats, play and `perform`
requests (block, keys, palette, Carly) still play, silently. When the last command finishes,
normal behavior resumes and that command's reaction is eligible as usual (sampling and cooldowns
unchanged). The host half counts commands in every local pane; each window counts its own panes
(including remote ones). A command counts until it finishes or its pane closes, and at most
6 hours, so a missed finish event cannot keep the cat still for good. The settings page has the
switch under Quiet hours & sound.

### `quiet`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `hours_enabled` | boolean | `false` | Turn on quiet hours. |
| `start` | `"HH:MM"` (local time) | `"22:00"` | Start. May be later than `stop` (spans midnight). |
| `stop` | `"HH:MM"` | `"08:00"` | End. |

During quiet hours the cat only sleeps, blinks or grooms, and no sound plays when
`sound.respect_quiet_hours` is on.

### `ai`

Autonomous AI is disabled in this version regardless of these keys (see the README's
[AI status](../README.md#ai-status)). The keys are validated so a future version can use them.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | boolean | `false` | Master switch. |
| `provider` | `"none"`, `"mock"`, `"carly_schedule"` | `"none"` | `carly_schedule` always reports unavailable; `mock` exists for tests. |
| `max_turns_per_hour` | integer 0-10 | `2` | Budget. |
| `max_turns_per_day` | integer 0-100 | `10` | Budget. |
| `cooldown_s` | integer 60-86400 | `300` | Minimum seconds between turns. |
| `share_command_output` | boolean | `false` | Validated; no code path reads or shares command output. |

### `sound`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | boolean | `false` | Sound is off until you turn it on. |
| `volume` | number 0-1 | `0.25` | Player volume. `0` is silent. |
| `pack` | pack id | `"default"` | Sound pack: bundled `default`, or `<data>/sounds/<id>/`. |
| `events` | object of booleans: `meow`, `purr`, `surprise`, `happy`, `swat` | all `true` | Per-sound switches. |
| `respect_quiet_hours` | boolean | `true` | Silent during quiet hours. |

Sounds also stay silent while snoozed, in focus mode while a command runs, and play at most once
every 2 seconds.

### `controls`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `keyboard_enabled` | boolean | `true` | Single-key shortcuts while the block is focused (`p o f space s h z`). `Escape` on the settings page works either way. |

## What can change config besides you

- The block's settings page (any row it shows).
- The overlay toggle and Carly's `configure` / `set_personality` exports. `configure` accepts
  only these keys: `behavior.activity`, `behavior.allow_visual_obscuring`, `behavior.allow_swats`,
  `behavior.allow_command_reactions`, `behavior.allow_development_reactions`,
  `behavior.allow_pane_reactions`, `behavior.allow_idle_sleep`, `behavior.allow_pacing`,
  `behavior.focus_mode`, `sound.enabled`, `sound.volume`, `rendering.overlay`,
  `rendering.reduced_motion`, `quiet.hours_enabled`, `quiet.start`, `quiet.stop`,
  `needs.enabled`.
- Carly is held to less than that, because it calls exports without asking you: it may set
  `sound.enabled` only to `false`, and `quiet.hours_enabled` and `behavior.focus_mode` only to
  `true`, and may not change `sound.volume`, `quiet.start` or `quiet.stop`. Turning sound on,
  loosening quiet hours or turning focus mode off takes the block's settings page or an edit to
  `config.json`.

Only the host half writes the file. AI settings, appearance and sharing are never changeable
through Carly.
