# Architecture

tern-cat is a standard Tern plugin package (`plugin.toml`, `host.luau`, `window.luau`,
`tern-cat.css`) with Luau modules under `cat/`. Every behavior that matters is decided by
deterministic, dependency-injected modules that run unchanged under Tern and under Lune for
tests. The two entries are thin glue that build the ports (`tern.*` wrappers) and hand them to
the host brain or the window controller.

The design follows from the M0 findings in [sdk-capability-matrix.md](sdk-capability-matrix.md).

## Runtime topology

```text
                      one per local user (daemon)                     one per Tern window
 ┌──────────────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
 │ host.luau ─► cat/host/brain                      │   │ window.luau ─► cat/window/controller     │
 │  host hooks (command_*, cwd, pane_exited)        │   │  window events (focus, pane_*, tab_*,    │
 │        │ classify: category only, never line     │   │   command_*, cwd)                        │
 │        ▼                                         │   │        │ classify: category only         │
 │  store (single writer) ◄── inbox/*.json ◄────────┼───┼── intents (commands, chord, Carly)       │
 │   profile, needs, stats, journal, seen ids       │   │        ▼                                 │
 │        │ tern.kv "state" (rev)  ─────────────────┼───┼─► poll kv 2 s ─► presenter (behavior    │
 │        ▼                                         │   │      engine per window) + mirror         │
 │  behavior engine ─► block renderer               │   │                    │                     │
 │   (interactive home: sprite, buttons, settings)  │   │                    ▼                     │
 │  config.json writer (settings, intents)          │   │  overlay: tern.css sheet "overlay"       │
 │  sound player (tern.process.run, opt-in)         │   │  (pointer-events:none, per window)       │
 │                                                  │   │  Carly exports + context line            │
 └──────────────────────────────────────────────────┘   └──────────────────────────────────────────┘
```

### Ownership rules (multi-window correctness)

1. **The host half is the only writer of `tern.kv`.** `tern.kv.set` rewrites the whole file and
   the later rename wins, so a second writer could silently drop profile updates. The window
   controller never calls `kv.set`.
2. **Windows never mutate shared state directly.** They write one intent per file into
   `<tern.plugin.data>/inbox/<at_ms>-<8hex>.json` (`cat/window/intents.luau`; unique names, no
   write races). The host polls the inbox every 500 ms (`cat/host/inbox.luau`, at most 32 files
   per poll), validates each intent with `cat/core/commands.luau`, applies it, records its id in
   `seen`, and deletes the file. Undecodable or foreign files are retried for 5 s (a write may be
   in progress), then deleted with a log line.
3. **Command statistics are counted only from host hooks** (fired once per event per daemon).
   Window `command_*` events fire once per window and are used only for that window's
   presentation. This is what prevents double counting across windows.
4. **Config** (`<tern.plugin.data>/config.json`) is human-editable. The host is the only
   plugin-side writer (settings page, overlay toggle, Carly `configure`/`set_personality` via
   intents). Both halves re-read it every 3 s (content comparison) and on "Reload config".
5. **Per-window presentation is ephemeral.** Each window VM keeps its own presenter state, seed
   and overlay CSS in memory. Window VMs lose state on plugin reload and `window_start` does not
   refire, so the window entry re-creates presentation at load time.
6. **Host reactions are mirrored, not recomputed.** `cat/window/mirror.luau` replays the host's
   last reaction in each window if it is new (by `at` and id) and under 5 s old, unless this
   window already played it (an optimistic gesture, or its own reaction to the same command).

### Window entry boot

Tern disables a window hook that runs longer than 50 ms. Compiling every module in one call took
26-45 ms and once exceeded the budget, so `window.luau` only registers commands, window events
and the chord at top level, then `require`s the modules in dependency order in `tern.timer(0)`
slices of at most about 15 ms (`SLICE_MS`), and finally starts the controller and registers the
Carly exports. Until then, commands toast "Tern Cat is still starting; try again in a moment."
Measured: 2-3 slices of 15-17 ms; see [performance.md](performance.md).

### Renderers

| Renderer | Where | Interactive | Notes |
|---|---|---|---|
| Block | host, `tern.block.define("cat")` (kind `tern-cat.cat`) | yes: click (pet), double-click (play), right-click menu, buttons, keys when focused | Opened from the palette ("Open cat" from the window half, or Tern's "New Tern Cat block"). "Open cat" reuses an existing block, else `cx:new_block` beside and `cx.layout:float(pane, owner, "br")` (`rendering.block_placement = "float"`), staying a split if floating fails (`cat/window/blocks.luau`). One APNG per animation, every animation's image node kept in the view and toggled by `role` so late-attaching windows never show a missing blob; one-shot animations get a fresh key per play so they restart. Settings page uses the `prefs` node (7 pages). |
| Overlay | window, `tern.css("overlay", css)` | no (`pointer-events: none`) | On by default. Anchored to the focused pane's bottom-right corner via `.tn-pane.on > .tn-body::after`; sprite-sheet `@keyframes` with `steps()` timing from the pack's `durations_ms`; pacing is a stepped `translateX`. The sheet is reinstalled only when the CSS text changes. Hidden (empty sheet) when toggled off, and while the focused pane is a cat block or a cat block floats over it, so it never covers the card's buttons. Still frame when `rendering.reduced_motion = "on"` or Tern's `reduce_motion` is `on`; Tern's own reduced-motion CSS also stops it. Never changes terminal content, input, selection or layout. |

The overlay is a decoration, not a compositor: it cannot read or locate terminal text, so the
"knock a character off `ls` output" gag is a parody inside the block (a fixed fake listing). The
upstream API that would enable the real gag is proposed in
[overlay-upstream-rfc.md](overlay-upstream-rfc.md).

## Modules

All modules are `--!strict` and return a table of functions. Only the entries and
`cat/adapters/*` reference the `tern` global. Data contracts live in `cat/types.luau`.

### Core (pure)

| Module | Responsibility | Key functions |
|---|---|---|
| `cat/core/rng.luau` | Seeded PRNG (xorshift32 on `bit32`) | `new(seed) -> Rng` |
| `cat/core/clock.luau` | Real (injected primitives) and fake clocks | `fromPrimitives(now_ms, wall_s, local_hm)`, `fake(opts)` |
| `cat/core/util.luau` | Pure helpers: clamp, deep copy, deep merge, ring buffer push | |
| `cat/core/model.luau` | Profile defaults, validation, schema migration | `newProfile(cat_id, wall_s)`, `migrate(raw)` |
| `cat/core/needs.luau` | Needs decay, capped offline catch-up, gesture effects, mood | `decay`, `catchUp`, `applyGesture`, `deriveMood` |
| `cat/core/store.luau` | `StoreEnvelope` lifecycle: decode/recover, apply event/intent once (dedupe by id), bounded journal, rev bump; config-changing intents become `{kind = "config", changes}` effects | `empty`, `decode`, `applyEvent`, `applyIntent`, `catchUp` |
| `cat/core/events.luau` | Event construction, command classifier (category only), ids, dedupe ring | `classify(line)`, `commandFinished(...)`, `gesture(...)` |
| `cat/core/behavior.luau` | Weighted FSM: posture, trigger rules, cooldowns, precedence | `newState(now_ms)`, `tick(state, ctx)`, `react(state, event, ctx)` |
| `cat/core/running.luau` | Commands running per pane for focus mode (pane id and start time only; 6 h safety timeout) | `new`, `started`, `stopped`, `busy` |
| `cat/core/commands.luau` | Intent allowlist and argument validation for every source (block, keyboard, window, carly); `SET_CONFIG_KEYS` | `validate(raw)`, `toEvent(intent)` |
| `cat/config/schema.luau` | Config defaults, presets, per-field validation and fallback, migrations, precedence merge | `defaults()`, `preset(activity)`, `resolve(raw)`, `checkField(path, v)` |

### Rendering and sprites (pure)

| Module | Responsibility | Key functions |
|---|---|---|
| `cat/render/animations.luau` | The 20 canonical animations and fallback chains ending in `idle` | `resolve(pack_animations, wanted)`, `isCanonical(name)` |
| `cat/render/block.luau` | Block view: sprite stack, needs bars, stats, buttons, menus, `prefs` settings page, `ls` parody | `view(model, ui)` |
| `cat/render/overlay.luau` | Overlay CSS generator (sanitized string output; optional `still`) | `css(params)` |
| `cat/sprite/png.luau` | PNG/APNG header parsing without decoding pixels | `inspect(bytes)` |
| `cat/sprite/manifest.luau` | `pack.json` validation: limits, path segment rules, animation set | `validate(table, fs, root)`, `checkPath` |
| `cat/sprite/loader.luau` | Discover bundled and user packs, validate, fall back to the default pack; the only folder a pack removal may delete | `loadAll(fs, roots)`, `select`, `removableDir(pack, user_root)` |

### Host half (`host.luau`)

| Module | Responsibility | Key functions |
|---|---|---|
| `cat/host/brain.luau` | The single writer: owns the store, ticks the engine (next delay clamped to 0.5-5 s), applies inbox intents, polls config, writes config changes (pretty JSON in example key order; backs up an unreadable file first), persists kv only when `rev` changes, moves a corrupt `kv.json` aside and starts a fresh cat, tracks running commands in every local pane (focus mode), plays sounds, removes user packs (switching the appearance back to the default when the removed pack was selected) | `load(deps)`, `tick`, `onCommandStarted/Finished`, `onPaneEvent`, `applyIntent`, `pollInbox`, `pollConfig`, `setConfig`, `availablePacks`, `removePack`, `subscribe` |
| `cat/host/inbox.luau` | Inbox poll: name pattern `<ms>-<8hex>.json`, 5 s grace for bad files, 32 files per poll | `poll(state, fs, json, dir, now)` |
| `cat/host/controls.luau` | Block input mapping: actions, menu, focused-block keys (`p o f space s h z`, Escape), settings-row changes, two-step confirmation for Reset identity and Remove pack (10 s), test mode (`test`, `frozen`, `seed=N`, or `TERN_CAT_TEST`) | `resolveAction`, `menuActions`, `keyAction`, `settingsChange`, `armConfirm`, `isArmed`, `parseTestMode` |
| `cat/integrations/hooks.luau` | Registers `command_started`, `command_finished`, `cwd`, `pane_exited`; classifies the line inside the handler and drops it (no `title` hook: shells retitle on every prompt) | `register(on, sink)` |
| `cat/integrations/sound.luau` | Policy (off by default, per-event flags, quiet hours, snooze, focus mode, volume 0, 2 s minimum gap), sound pack loading, player detection and argv | `policy`, `loadPack`, `detect`, `argv`, `play` |

Sound runs only in the host half: `host.luau` holds the single `tern.process.run` call site and
passes it to `sound.detect` and `sound.play`.

### Window half (`window.luau`)

| Module | Responsibility | Key functions |
|---|---|---|
| `cat/window/controller.luau` | The window loop behind injected ports: one self-rescheduling timer (next decision, kv poll every 2 s, config poll every 3 s), requests to intents, overlay toggle, reset confirmation (second run within 10 s), cover state, Carly snapshot and context. Never writes kv | `new`, `start`, `onWindowEvent`, `request`, `toggleOverlay`, `reloadConfig`, `confirmReset`, `setCovered`, `snapshot`, `context` |
| `cat/window/presenter.luau` | One read-only behavior engine per window; command lines reduced to a category immediately; this window's running commands (focus mode, tracked even while the overlay is hidden; host `react.*` mirrors are skipped while busy); overlay parameters; local override until config agrees | `new`, `view`, `params`, `tick`, `react`, `observe`, `gesture`, `mirror`, `eventFor`, `setConfig`, `setCovered`, `visible` |
| `cat/window/packs.luau` | Validates only the wanted and default packs (full scan only if both miss), resolves fallbacks, caches each sheet as a data URL; a pack without a built sheet uses its first frame; a cached pack whose `pack.json` is gone (removed) invalidates the cache. The controller reselects on every config poll | `new`, `select`, `asset`, `invalidate` |
| `cat/window/intents.luau` | Builds, validates and writes inbox files | `build`, `fileName`, `write` |
| `cat/window/mirror.luau` | Decides whether to replay a host reaction | `check`, `key` |
| `cat/window/blocks.luau` | Opens or focuses the cat block, floated or split | `open(ui, placement, settings)` |
| `cat/integrations/carly.luau` | The 12 export definitions (signature, doc, arity), intent mapping, `status`/`explain`/`aiStatus`, context line (at most 160 characters, no command text, paths, journal text or reasons) | `EXPORTS`, `toIntent`, `status`, `explain`, `aiStatus`, `context` |

### Shared

| Module | Responsibility |
|---|---|
| `cat/adapters/fs.luau` | `pcall`-wrapped `tern.fs` (list returns a plain copy) |
| `cat/adapters/json.luau` | `tern.json` decode/encode |
| `cat/adapters/kv.luau` | `tern.kv` (only the host calls `set`) |
| `cat/adapters/paths.luau` | All paths derived from `tern.plugin.data` and `tern.plugin.dir`: inbox, config, exports, user and bundled packs and sounds, kv file |
| `cat/adapters/clock.luau` | Real clock from `tern.now`/`os.time` |
| `cat/adapters/config.luau` | Read/parse/encode config, apply changes (with a `REMOVE` sentinel for Reset), create from the example |
| `cat/integrations/ai.luau` | Provider interface, turn budget, redaction, response allowlist, mock provider, and the disabled `carly_schedule` provider |

### Behavior engine

Separated into triggers (events), decision policy (`behavior.luau`), animation actions
(`render/animations.luau`) and presentation (renderers) so a new species can reuse the engine.

Precedence, highest first:

1. Snooze / hidden: no new decisions except `sleep`.
2. Quiet hours: only `sleep`, `blink`, `groom`; no sound.
3. Focus mode (`behavior.focus_mode` and a command running, `env.busy`): only `idle`, `sit`,
   `blink`, `groom`, `sleep`; no reactions, no sound; a moving decision in progress is replaced
   at once. Gestures still play (silently). The host counts every local pane, each window its
   own panes; a pane stops counting on finish, on `pane_exited`/`pane_closed`, or after 6 h.
4. Reduced motion: no `walk` or ambient `hop`; renderers show a still frame.
5. Granular toggles (`allow_*`) remove whole rule families.
6. Activity preset and personality weights.

Posture is a two-state FSM: `asleep` can only leave through `wake`; nothing else may start while
asleep (startle reactions route through `wake`).

### Persistence

- `tern.kv` key `state` holds one `StoreEnvelope` (schema version, `rev`, profile, bounded
  journal, bounded `seen` ring, last reaction, snooze).
- Offline time is simulated on load, capped by `needs.offline_hours_cap`, and can never reduce
  stats or push needs past their non-punishing bounds.
- Undecodable or unknown-version data is replaced by a fresh profile with a note in the block,
  never by a crash. An unreadable `kv.json` is moved to `kv.json.corrupt-<ts>` first. Recovery
  notes are kept in memory and disappear on the next plugin reload.
- Paths come from `tern.plugin.data` (writable state dir), never the plugin dir (writing there
  triggers a reload).

## Safety invariants

Enforced by code review and by `tests/unit/safety_spec.luau`, which scans every shipped source
(`host.luau`, `window.luau`, `cat/**/*.luau`) and fails if any of these appear:

- `pane.write`, `cx:run(`, `cx:action(` (typing into panes or running actions that can type);
- `session:read(`, `session:settle(`, `tern.lens` (reading terminal output);
- `tern.fetch` (network), `:copy(` (clipboard);
- `settings:set`, `settings:set_many`, `settings:bind`, `settings:unbind` (changing Tern
  settings or keybinds), `tern.override` (replacing built-in commands);
- `on("spawn"` (intercepting shell spawns);
- `ask_carly`, `carly.schedule`, `cx.agents` (starting Carly turns or agent panes).

It also checks that `process.run` appears only in `host.luau` (the sound player) and
`session:event` only in `window.luau` (UI events to the cat's own block).

Further guarantees, enforced by design and unit tests rather than the scan:

- Command lines are reduced to a `CommandCategory` inside the hook handler and discarded.
- The sound player runs with a fixed argv and pack-validated file paths; on Linux one fixed
  `sh -c "command -v pw-play paplay aplay"` probe finds the player.
- Carly exports validate every argument and never return command text or paths.

See [security-privacy.md](security-privacy.md) for the threat model.
