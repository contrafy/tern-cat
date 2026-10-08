# Architecture

tern-cat is a standard Tern plugin package (`plugin.toml`, `host.luau`, `window.luau`) with
pure Luau modules under `cat/`. Every behavior that matters is decided by deterministic,
dependency-injected modules that run unchanged under Tern and under Lune for tests.

The design follows from the M0 findings in [sdk-capability-matrix.md](sdk-capability-matrix.md).

## Runtime topology

```text
                      one per local user (daemon)                     one per Tern window
 ┌──────────────────────────────────────────────────┐   ┌──────────────────────────────────────────┐
 │ host.luau                                        │   │ window.luau                              │
 │  host hooks (command_*, cwd, title, pane_exited) │   │  window events (focus, pane_*, tab_*,    │
 │        │ sanitize (category only, never line)    │   │   command_*, cwd)                        │
 │        ▼                                         │   │        │ sanitize                        │
 │  store (single writer) ◄── inbox/*.json ◄────────┼───┼── intents (commands, keys, Carly)        │
 │   profile, needs, stats, journal, seen ids       │   │        ▼                                 │
 │        │ tern.kv "state" (rev)  ─────────────────┼───┼─► poll kv ─► behavior engine (per window)│
 │        ▼                                         │   │                    │                     │
 │  behavior engine ─► block renderer               │   │                    ▼                     │
 │   (interactive home: sprite, buttons, settings)  │   │  overlay renderer: tern.css sheet        │
 │                                                  │   │  (pointer-events:none, per window)       │
 │                                                  │   │  Carly exports/context, sound (process)  │
 └──────────────────────────────────────────────────┘   └──────────────────────────────────────────┘
```

### Ownership rules (multi-window correctness)

1. **The host half is the only writer of `tern.kv`.** `tern.kv.set` rewrites the whole file and
   the later rename wins, so a second writer could silently drop profile updates.
2. **Windows never mutate shared state directly.** They write one intent per file into
   `<tern.plugin.data>/inbox/<at_ms>-<rand>.json` (unique names, no write races). The host polls
   the inbox, validates each intent with `cat/core/commands.luau`, applies it, records its
   `intent_id` in `seen`, and deletes the file. Files that fail to decode are retried for a short
   grace period (a write may be in progress) and then discarded.
3. **Command statistics are counted only from host hooks** (fired once per event per daemon).
   Window `command_*` events fire once per window and are used only for that window's
   presentation. This is what prevents double counting across windows.
4. **Config** (`<tern.plugin.data>/config.json`) is human-editable. The host is the only
   plugin-side writer (settings UI, Carly `set_personality`, Hide). Both halves re-read it on a
   slow poll (content comparison) and on an explicit "Reload config" command.
5. **Per-window presentation is ephemeral.** Each window VM keeps its own engine state, seed and
   overlay CSS in memory. Window VMs lose state on plugin reload; `window_start` does not refire,
   so the window entry re-creates presentation at load time.

### Renderers

| Renderer | Where | Interactive | Notes |
|---|---|---|---|
| Block | host, `tern.block.define("cat")` | yes: click/dblclick/menu actions, keys when focused | Opened manually (palette "Tern Cat: Open", or `cx:new_block`); preferred placement is a floating corner card via `cx.layout:float`, else a split beside. One APNG blob per animation (Tern-clocked, free when hidden, deterministic in goldens). Settings page uses the `prefs` node. |
| Overlay | window, `tern.css("overlay", css)` | no (pointer-events: none) | On by default. Anchored to the focused pane's bottom-right corner via `.tn-pane.on > .tn-body::after`; animation via sprite-sheet `@keyframes` with step timing (about 2% CPU at 10 Hz). Never changes terminal content, input, selection or layout. Frozen by Tern's reduced-motion media query. |

The overlay is a decoration, not a compositor: it cannot read or locate terminal text, so the
"knock a character off `ls` output" gag is a parody inside the block. The upstream API that would
enable the real gag is proposed in [overlay-upstream-rfc.md](overlay-upstream-rfc.md).

## Modules

All modules are `--!strict`, return a table of functions, and never reference the `tern` global
except the entries and `cat/adapters/*`. Data contracts live in `cat/types.luau`.

| Module | Responsibility | Key functions |
|---|---|---|
| `cat/core/rng.luau` | Seeded PRNG (xorshift32 on `bit32`) | `new(seed) -> Rng` |
| `cat/core/clock.luau` | Real (injected primitives) and fake clocks | `fromPrimitives(now_ms, wall_s, local_hm)`, `fake(opts) -> Clock & {advance}` |
| `cat/core/util.luau` | Pure helpers: clamp, deep copy, deep merge, ring buffer push | |
| `cat/core/model.luau` | Profile defaults, validation, schema migration | `newProfile(cat_id, wall_s)`, `migrate(raw) -> (Profile?, err)` |
| `cat/core/needs.luau` | Needs decay, capped offline catch-up, gesture effects, mood derivation | `decay`, `catchUp`, `applyGesture`, `deriveMood`, `neutral` |
| `cat/core/store.luau` | `StoreEnvelope` lifecycle: decode/recover, apply event/intent once (dedupe by id), bounded journal, rev bump | `empty`, `decode`, `applyEvent`, `applyIntent`, `catchUp` |
| `cat/config/schema.luau` | Config defaults, presets, validation with per-field fallback, migrations, precedence merge | `defaults()`, `preset(activity)`, `resolve(raw) -> (Config, warnings)` |
| `cat/core/events.luau` | Event construction, command-line classifier (category only), id generation, dedupe ring | `classify(line) -> CommandCategory`, `commandFinished(...)`, `gesture(...)` |
| `cat/core/behavior.luau` | Weighted FSM: posture transitions, trigger rules, rate limits, precedence (quiet hours, snooze, reduced motion, toggles) | `newState(now_ms)`, `tick(state, ctx)`, `react(state, event, ctx)` |
| `cat/core/commands.luau` | Validate intents from any source (allowlisted kinds and args) | `validate(raw) -> (Intent?, err)`, `toEvent(intent) -> CatEvent?` |
| `cat/render/animations.luau` | Canonical animation list and fallback chains | `resolve(pack_animations, wanted) -> Animation` |
| `cat/render/block.luau` | Block view builder (host) | |
| `cat/render/overlay.luau` | Overlay CSS generator (pure string output) | `css(params) -> string` |
| `cat/sprite/png.luau` | PNG/APNG header parsing (dimensions, frame count) without decoding pixels | `inspect(bytes)` |
| `cat/sprite/manifest.luau` | `pack.json` validation: limits, paths (no traversal/absolute), animation set | `validate(table, fs, root) -> ValidationResult` |
| `cat/sprite/loader.luau` | Discover bundled and user packs, validate, fall back to the default pack | `loadAll(fs, roots)`, `get(id)` |
| `cat/integrations/ai.luau` | Provider interface, budget/rate limiter, redaction, response allowlist, mock and disabled Carly adapter | |
| `cat/integrations/sound.luau` | Player detection, mute/quiet-hours policy | |
| `cat/adapters/*.luau` | Thin wrappers over `tern.fs`, `tern.kv`, `tern.json`, timers | |

### Behavior engine

Separated into triggers (events), decision policy (`behavior.luau`), animation actions
(`render/animations.luau`) and presentation (renderers) so a new species can reuse the engine.

Precedence, highest first:

1. Snooze / hidden: no new decisions except `sleep`.
2. Quiet hours: only `sleep`, `blink`, `groom`; no sound.
3. Reduced motion: same decisions, renderers show a still frame (overlay is frozen by CSS).
4. Granular toggles (`allow_*`) remove whole rule families.
5. Activity preset and personality weights.

Posture is a two-state FSM: `asleep` can only leave through `wake`; nothing else may start while
asleep (startle reactions route through `wake`).

### Persistence

- `tern.kv` key `state` holds one `StoreEnvelope` (schema version, `rev`, profile, bounded
  journal, bounded `seen` ring, last reaction, snooze).
- Offline time is simulated on load, capped by `needs.offline_hours_cap`, and can never reduce
  stats or push needs past their non-punishing bounds.
- Corrupt or unknown-version data is replaced by a fresh profile (with a journal note and a toast),
  never by a crash.
- Paths come from `tern.plugin.data` (verified writable state dir), never the plugin dir (writing
  there triggers a reload).

## Safety invariants

Enforced by code review and red-team tests (`tests/unit/safety_spec.luau` greps the shipped
sources for forbidden calls):

- No `tern.pane.write`, `cx:run`, `cx.session:read`, `cx.session:settle`, `tern.fetch`, clipboard
  `cx:copy`, `cx.settings:set`, lenses, or `spawn` hooks.
- Command lines are reduced to a `CommandCategory` inside the hook handler and discarded.
- `tern.process.run` is used only for the sound player, with a fixed argv and pack-validated
  file paths.
- Carly exports validate every argument and never return command text or paths.
