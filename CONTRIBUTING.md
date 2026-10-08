# Contributing to tern-cat

Thanks for helping. tern-cat is a public-beta Tern plugin; changes are welcome as small, tested
pull requests. Read [docs/architecture.md](docs/architecture.md) and
[docs/security-privacy.md](docs/security-privacy.md) before changing behavior or I/O, and
[docs/develop-with-omp-tern.md](docs/develop-with-omp-tern.md) to set up the dev loop.

## Workflow

1. Open an issue first for anything larger than a bug fix, so the design can be agreed on.
2. Keep pull requests small and focused: one behavior, one fix, or one pack per PR.
3. Write the test first. Logic lives in pure modules under `cat/` and is tested with Lune
   (`tests/unit/**/*_spec.luau`, runner `lune run tests/run.luau`). Inject time, randomness and
   I/O; do not reach for the `tern` global outside `host.luau`, `window.luau` and
   `cat/adapters/*`.
4. `bash scripts/check.sh` must pass (format, lint, typecheck, tests, pack validation). CI runs
   it with `CI=1` on macOS and Linux.
5. Use [Conventional Commits](https://www.conventionalcommits.org/): `feat(core): ...`,
   `fix(sprite): ...`, `docs: ...`, `test: ...`, `build: ...`. Name the scope after the area
   touched, e.g. `core`, `sprite`, `ai`, `assets`, `host`, `window`.
6. Add an entry under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for user-visible changes.
7. Update the docs your change affects (pack format, config keys, safety guarantees).

Style:

- Luau: `--!strict`, formatted by StyLua (`.stylua.toml`: tabs, 120 columns), linted by selene.
  Modules return a table of functions; shared data shapes live in `cat/types.luau`.
- Python tools: single-file `uv run` scripts with inline dependencies (PEP 723), Pillow pinned.
- No emojis in code, comments, docs, commit messages or UI strings.
- No new runtime dependencies. Tooling is installed with `brew` or `uv`, never globally from a
  script.

## Safety invariants

These are review blockers. A PR that breaks one is not merged, whatever else it does
([docs/security-privacy.md](docs/security-privacy.md) explains each):

- No writes to a terminal: no `tern.pane.write`, `cx:run`, input or key injection, `spawn` hooks.
- No reads of terminal output: no `cx.session:read`, `cx.session:settle`, lenses.
- Command lines are reduced to a category inside the hook handler (`classify` in
  `cat/core/events.luau`) and never stored, logged, returned or sent anywhere.
- No network: no `tern.fetch`, no telemetry, no remote assets.
- No clipboard (`cx:copy`) and no settings writes (`cx.settings:set`).
- `tern.process.run` only for the sound player, with a fixed argv and a validated pack path.
- The overlay stays `pointer-events: none` and never changes terminal content, focus or layout.
- Carly exports validate every argument and return no command text, output or paths.
- Autonomous AI stays disabled while scheduled Carly turns are full-power.
- Only the host half writes `tern.kv`; windows send intents through the inbox.
- Packs are data: no code execution; every path and interpolated CSS value is validated.

Run the audit greps in
[docs/security-privacy.md](docs/security-privacy.md#auditing-the-guarantees) before opening a PR
that touches I/O.

## Asset licensing

- Bundled art and sound must be original work contributed under
  [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). No third-party sprites, samples,
  fonts or ripped game assets, and no AI output you cannot license.
- Code is MIT ([LICENSE](LICENSE)). Asset-generating code is code (MIT); its output is an asset
  (CC-BY-4.0).
- Credit every bundled asset in [assets/CREDITS.md](assets/CREDITS.md), and set `author` and
  `license` in its manifest.

## Repository layout

```text
plugin.toml, host.luau, window.luau   Tern plugin manifest and the two entries
cat/
  types.luau                          shared data contracts
  core/                               pure engine: rng, clock, events, model, needs, store, behavior, commands
  config/schema.luau                  config defaults, presets, validation, migrations
  render/                             animation names and fallbacks, overlay CSS generator
  sprite/                             PNG inspection, pack.json validation, pack loader
  integrations/                       AI policy, Carly exports, sound
  host/, window/                      host and window controllers (pure, ports injected)
  adapters/                           the only modules that touch tern.fs, tern.kv, tern.json, timers
assets/
  packs/<id>/                         bundled sprite packs (orange-menace is the default)
  sounds/default/                     bundled sound pack
  CREDITS.md                          asset authors and licenses
config/example.json                   every config key with its default
docs/                                 architecture, SDK capability matrix, specs, guides
scripts/                              check, typecheck, sandbox, dev-link, tool and type fetchers
tests/
  run.luau, lib/                      Lune runner and expectation library
  unit/                               *_spec.luau, mirroring cat/
  fixtures/packs/                     tiny good-* and bad-* packs (tools/make_fixtures.py)
tools/
  art/                                code-authored sprite art for the bundled packs
  build_packs.py, build_sounds.py     regenerate bundled assets
  pack_build.py, packlib.py           derived apng/sheet files for any pack
  validate_packs.py, validate_pack.luau  pack validators
```

## How to add a behavior

A behavior is a decision in `cat/core/behavior.luau`: an id (`react.*`, `ambient.*`,
`gesture.*`), an animation, a short reason and a duration.

1. Write the spec first in `tests/unit/core/behavior_spec.luau`: the triggering event or state,
   the expected animation, and that it is suppressed by snooze, quiet hours and the relevant
   `allow_*` toggle. Use a fixed seed; the engine is deterministic.
2. If it reacts to a new event, construct the event in `cat/core/events.luau` and add its
   attributes to `ALLOWED` there (only categories, booleans, numbers or short words).
3. Add the rule to `reactiveDecision`, `commandFinishDecision`, `gestureDecision` or the
   ambient weights, respecting the precedence documented at the top of the file. Gate it on an
   existing `allow_*` family in `familyAllowed`, or add a new toggle to `cat/config/schema.luau`
   and `config/example.json`.
4. Rate-limit reactions with `ready`/`markTrigger`; nothing may fire on every command.
5. Use an existing canonical animation. Fallbacks make it work in every pack.

## How to add an animation

Canonical names are part of the pack format, so adding one touches every layer:

1. `cat/render/animations.luau`: add it to `CANONICAL`, give it a `FALLBACKS` chain ending in
   `idle`, and a `DURATIONS_MS` entry (and `LOOPS` if it is a looping state).
2. `cat/types.luau`: add it to the `Animation` union.
3. `cat/sprite/manifest.luau` and `tools/validate_packs.py`: add it to their `CANONICAL` lists.
4. `tools/art/animations.py`: add a frame script, then `uv run tools/build_packs.py`. Bundled
   packs must provide every canonical animation.
5. Update the table in [docs/sprite-pack-spec.md](docs/sprite-pack-spec.md#canonical-animations)
   and `tests/unit/render/animations_spec.luau`.
6. `bash scripts/check.sh`.

Existing community packs keep working: they fall back along the new chain.

## How to add a sprite pack

- **Community pack** (installed by users into `<tern.plugin.data>/packs/<id>/`): follow
  [docs/sprite-pack-spec.md](docs/sprite-pack-spec.md), build the derived files with
  `uv run tools/pack_build.py <dir>`, and validate with `uv run tools/validate_packs.py <dir>`.
  Share it in its own repository; open a "Sprite pack" issue to have it listed.
- **Bundled pack** (shipped in `assets/packs/`): it must be original CC-BY-4.0 art, provide all
  canonical animations, include `LICENSE.txt`, use a directory named after its `id`, and be
  listed in `assets/CREDITS.md`. Existing bundled packs are generated from `tools/art/` (add a
  palette in `tools/art/palettes.py`); hand-drawn packs are built with `tools/pack_build.py`.
  `uv run tools/validate_packs.py` with no arguments must pass.
