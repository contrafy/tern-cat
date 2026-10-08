# Using tern-cat

Detailed reference. Settings: [configuration.md](configuration.md). Privacy: [security-privacy.md](security-privacy.md).

## First steps

1. After install, every Tern window shows the overlay cat in the bottom-right corner of the
   focused pane. You do not have to do anything else.
2. Open the interactive block from the command palette:
   - **Open cat** (group Tern Cat) opens it as a floating card in the bottom-right corner of the
     focused pane. If the focused tab already shows a cat block (tiled or floating), it focuses
     that one instead. A cat card floating in another tab, or a parked cat, moves over the focused
     pane; a cat block tiled into another tab is left there and a new card opens. With
     `rendering.block_placement: "split"` it opens as a split beside the focused pane instead (a
     parked cat is dealt back beside it). If floating fails the block stays a split, and a toast
     says why.
   - **New Tern Cat block** (Tern's own block catalog entry, not a tern-cat command) opens it like
     any other block, in a new tab or split; it never floats.
3. While the block is focused, or floats over the focused pane, the overlay cat hides so it does
   not cover the card.

## Controls

### In the block

- Click the sprite to pet, double-click to play, right-click for a menu: Pet, Poke, the three
  foods (treat, kibble, fish), the three toys (ball, string, feather), Snooze 30m or Wake, Overlay
  on or off, Settings.
- Buttons: Pet, Poke, Feed (right-click for foods), Play (right-click for toys), Snooze 30m /
  Wake, Overlay off / Overlay on, Settings.
- Keys while the block is focused (unmodified only; chords with ctrl, alt or cmd pass through to
  Tern):

  | Key | Action |
  |---|---|
  | `p` | Pet |
  | `o` | Poke |
  | `f` | Feed (kibble) |
  | `space` | Play (ball) |
  | `s` | Open settings |
  | `h` | Overlay off / on |
  | `z` | Snooze 30 min / wake |
  | `Escape` | Close settings |

  Turn the single-key shortcuts off with `controls.keyboard_enabled: false`.
- The settings page edits `config.json` directly; each row has a Reset.
- Settings > Appearance lists **Remove <pack>** for each sprite pack you installed under
  `<tern.plugin.data>/packs/`. Click Remove..., then Confirm within 10 seconds: the pack's folder
  is deleted. If it was the cat's appearance, the cat switches back to Orange Menace in the block
  and, within about 3 seconds, in every window. Bundled packs cannot be removed.

### On the overlay cat

- Move the pointer near the overlay cat (within about 48 px) or onto it: it plays `look`.
- Press on it or near it: it swats (`swat`) and holds the pose for about 0.7 s after you let go.
- These reactions are visual only. The click, drag or key still goes to the terminal (focus,
  text selection and programs that read the mouse work as usual), the pointer keeps the
  terminal's cursor, and nothing is counted: a hover or press is not a pet. Pet the cat in the
  block.
- Turn them off with `behavior.allow_pointer_reactions: false` (settings label "React to the
  pointer (overlay)"; off in the `quiet_office` preset). With reduced motion the cat shows the
  first frame of each reaction instead. Packs without a `look` or `swat` sheet use their fallback
  animation or its first frame.

### Global hide chord

`ctrl+alt+cmd+c` runs **Hide or show the overlay cat** in any window. It is free in Tern 0.6.2's
default keymap. Your own keybinds always win over plugin binds, so you can move or remove it in
Tern's `settings.json` (`<config>/settings.json`; macOS `~/Library/Application Support/Tern/`,
Linux `~/.config/tern/`):

```json
{
  "keybinds": {
    "cmd+shift+j": "plugin.tern-cat.toggle-overlay",
    "ctrl+alt+cmd+c": "unbind"
  }
}
```

If the chord is ever not bound to the action, the window logs a warning; the palette command
still works.

### Palette commands

All are in the group **Tern Cat**; their action names are `plugin.tern-cat.<id>`.

| Title | Id | What it does |
|---|---|---|
| Open cat | `open` | Bring the cat to the focused pane, floated or split per `rendering.block_placement`; focus it if this tab already shows one. |
| Pet the cat | `pet` | Pet. |
| Poke the cat | `poke` | Poke. |
| Feed the cat | `feed` | Feed. |
| Play with the cat | `play` | Play. |
| Hide or show the overlay cat | `toggle-overlay` | Toggle `rendering.overlay`. Bound to `ctrl+alt+cmd+c`. |
| Snooze the cat (30 min) | `snooze` | Snooze for 30 minutes: the cat sleeps and stays silent. |
| Wake the cat | `wake` | End a snooze. |
| Reload config | `reload-config` | Re-read `config.json` now; the toast shows its path. |
| Cat settings | `settings` | Open the block on its settings page. |
| Export cat identity | `export-identity` | Write the cat's identity and stats as JSON to `<data>/exports/`. |
| Reset cat identity | `reset-identity` | Replace the cat with a new one (stats and journal start over; config is kept). Runs only if you run it twice within 10 seconds. |
| Clear AI state | `clear-ai-state` | Remove AI-related journal entries. |

In the first fraction of a second after a plugin reload, commands answer "Tern Cat is still
starting; try again in a moment."

## Behaviors

There are 20 animations. A pack that lacks one falls back along a chain that ends in `idle`.

| Animation | Triggered by |
|---|---|
| `idle`, `sit`, `blink`, `groom`, `stretch`, `look` | Ambient choice, weighted by personality, mood and preset. A hungry `look` may come with a meow (`talkativeness`). |
| `walk` | Ambient pacing (`allow_pacing`; not with reduced motion). The overlay cat paces along the bottom of the pane; pointer reactions keep working while it walks. |
| `sleep` | Low energy, you being away for 2-10 minutes (after a `groom` or `stretch` to settle), quiet hours, snooze (`allow_idle_sleep`). |
| `wake` | Leaving sleep: rested, or when idle naps are turned off. |
| `pet` | Pet. |
| `poke`, `startled` | Poke (`startled` is more likely with low `affection`). |
| `eat` | Feed. |
| `play`, `swat` | Play (`swat` is more likely with high `mischief`; needs `allow_swats`). Ambient swats. |
| `swat` (after `ls`) | A successful listing command, sometimes. The block shows a fake `$ ls README.md src tests` line being swatted; your real terminal is never touched. |
| `look`, `swat` (overlay only) | The pointer near or on the overlay cat (`look`), a press there (`swat`), while `allow_pointer_reactions` is on. Drawn by CSS for as long as the pointer stays; not a decision of the behavior engine, so it changes no needs or stats and is not limited by `allow_swats`. |
| `happy` | A command succeeded (more likely after a long command or in a good mood). |
| `disappointed` | A command failed. |
| `flop` | Three failed test runs in a row (`allow_development_reactions`). |
| `stare` | A `sudo` command started. |
| `hop` | A pane opened or closed (with `look`), ambient bursts of energy. |

Command reactions are sampled (`reaction_sample_rate`, default 35%) and rate limited
(`reaction_cooldown_s`, default 45 s). Only the command's category (test, build, vcs, list, sudo,
editor, network, package, other) and exit status are used; the command line is dropped inside
the hook.

Focus mode (`behavior.focus_mode`, off by default, on in `quiet_office`; switch under Quiet
hours & sound in the settings page) keeps the cat still while any command runs: it only idles,
sits, blinks, grooms or sleeps, does not react to commands or panes, and plays no sound. Your own
pets, treats, play and `perform` requests still play. When the last running command finishes,
the cat behaves normally again and may react to that command. Snooze and quiet hours rank above
focus mode; reduced motion and the `allow_*` toggles below it.

The mood (calm, playful, sleepy, annoyed, curious, happy) comes from the needs (hunger, energy,
affection, boredom), which never reduce stats and are simulated, capped, for time Tern was
closed.

Presets (`behavior.activity`): `orange_menace` (default), `quiet_office` (fewer swats, no pacing,
rare reactions, focus mode), `chaos` (frequent reactions, more swats, hops and walks), `zen`
(mostly sitting and sleeping). Explicit keys in your config beat the preset.

## Carly integration

The window half registers these Carly exports (Carly calls them as
`plugins['tern-cat'].<name>(...)`). Every argument is validated, every call is wrapped in
`pcall`, and actions return `{ok = true}` or `{ok = false, error = "..."}`. Requests are rate
limited (a burst of 3, then 10 per minute), and Carly can only mute sound or turn quiet hours or
focus mode on, never the reverse.

| Export | Signature |
|---|---|
| `status` | `() -> {ok, name, mood, needs = {hunger, energy, affection, boredom}, stats = {pets, pokes, feeds, plays, command_reactions}, appearance, overlay, snoozed, last_reaction?}` |
| `pet` | `() -> result` |
| `poke` | `() -> result` |
| `feed` | `(item: "treat" \| "kibble" \| "fish"?) -> result` |
| `play` | `(toy: "ball" \| "string" \| "feather"?) -> result` |
| `perform` | `(animation: string) -> result` (one of the 20 animations) |
| `set_personality` | `(values: {curiosity?, affection?, mischief?, energy?, talkativeness?}) -> result` |
| `configure` | `(key: string, value: any) -> result` (only the keys listed in [configuration.md](configuration.md#what-can-change-config-besides-you)) |
| `snooze` | `(minutes: number?) -> result` |
| `wake` | `() -> result` |
| `explain` | `() -> {ok, last_reaction = {animation, reason, ago_s}?, overlay = {animation, reason}?, note?}` |
| `ai_status` | `() -> {ok, enabled, provider, unavailable_reason?}` (always `enabled = false` in this version) |

Exact signatures and docs are in `cat/integrations/carly.luau`.

The context provider adds one line of at most 160 characters to Carly's context, for example
`Tern Cat "Orange Menace": calm; hunger 0.2 energy 0.8; 1 pets`. It contains the cat's name (control
characters and quotes stripped), mood, needs and counts. It never contains command text, paths,
journal text or reasons. tern-cat never starts Carly turns (`ask_carly`, `carly.schedule`).

## AI status

Autonomous AI behavior is disabled. `ai_status()` reports `enabled = false` and the
`carly_schedule` provider reports: "Disabled: Tern 0.6.2 offers no constrained or hidden
completion route. Scheduled Carly turns run with full tool access (commands, input), so tern-cat
will not start them." Ordinary behavior needs no AI. The AI policy code (turn budget, redaction,
response allowlist, mock provider) exists and is tested so a constrained route can be adopted
later.

## Sound

Off by default (`sound.enabled: false`). Tern has no audio API, so when you turn sound on, the
host half runs a local player with a fixed argument list:

- macOS: `/usr/bin/afplay -v <volume> <file>`.
- Linux: the first of `pw-play --volume`, `paplay --volume=`, `aplay -q` found by a one-time
  `sh -c "command -v pw-play paplay aplay"` probe. No player found means silence.

Five sounds (meow, purr, surprise, happy, swat), each switchable in `sound.events`. Silent while
snoozed, during quiet hours (unless `sound.respect_quiet_hours` is off), in focus mode while a
command runs, and at volume 0; at most one sound every 2 seconds.

## Multiple windows and remote panes

- There is one cat per user. The host half (in the Tern daemon) owns its state and is the only
  writer; windows send requests through files in `<data>/inbox/`.
- Each window draws its own overlay cat with its own moment-to-moment behavior, and replays the
  host's reactions (pet, feed, command reactions) so all windows agree.
- Commands are counted once, by the host, no matter how many windows are open.
- Remote panes: a remote host runs its own plugins, and the local host half never sees remote
  commands. A window still sees them, so remote commands can make that window's overlay react,
  but they are not counted in the cat's stats.

## Known limitations

- The overlay cat is a CSS decoration, not a window. It reacts to the pointer with CSS only, so
  it cannot be dragged or petted (input passes through it), it sits in the focused pane's
  bottom-right corner, and it cannot see terminal text.
- Near and on the overlay cat look the same: Tern gives the cat and its proximity ring one
  shared hover state. Hover reactions with the real pointer over a window that is not frontmost
  are untested.
- The cat cannot interact with real terminal text (for example knock a letter off real `ls`
  output). Tern has no API for cell geometry; the gag is a parody inside the block. The API that
  would enable it is proposed in [overlay-upstream-rfc.md](overlay-upstream-rfc.md).
- Autonomous AI is disabled (see [AI status](#ai-status)).
- `rendering.reduced_motion: "off"` cannot override Tern: when Tern reduces motion, its
  stylesheet stops every animation, including the cat's. With `follow_tern` (default) the block
  keeps animating; set `"on"` for still frames everywhere. A change of Tern's setting can take up
  to about 2 s to reach the overlay.
- A plugin cannot size the floated card (Tern picks the size; you can resize it yourself). Floating is per session, so
  each window opens its own card.
- In a user sprite pack, animations without a built sprite sheet show only their first frame in
  the overlay ([sprite-pack-spec.md](sprite-pack-spec.md)).
- `ai.share_command_output` is accepted but has no effect in this version.
- Recovery notes (for example after a corrupt save file) are shown until the next plugin reload.
- Tested on macOS (Apple silicon) with Tern 0.6.2 only.

## Uninstall

```sh
tern plugin remove tern-cat
```

This leaves the cat's data (state, config, exports, user packs). To delete it too, remove the
data folder: macOS `~/Library/Application Support/Tern/plugin-data/tern-cat/`, Linux
`~/.local/state/tern/plugin-data/tern-cat/` (or `$XDG_STATE_HOME/tern/plugin-data/tern-cat/`).
If you added a keybind for `plugin.tern-cat.toggle-overlay` to `settings.json`, remove it as well.
