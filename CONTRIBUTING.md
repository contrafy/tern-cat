# Contributing to tern-cat

Thanks for helping. tern-cat is a public-beta Tern plugin; changes are welcome as small, tested
pull requests. Before changing behavior or I/O, read [docs/architecture.md](docs/architecture.md)
and [docs/security-privacy.md](docs/security-privacy.md). Everyone taking part follows the
[Code of Conduct](CODE_OF_CONDUCT.md). Security problems go through [SECURITY.md](SECURITY.md),
not public issues; questions through [SUPPORT.md](SUPPORT.md).

## Setup

| Tool | Used for | Install |
|---|---|---|
| [Lune](https://github.com/lune-org/lune) | Unit tests, Luau pack validator | `brew install lune` |
| [StyLua](https://github.com/JohnnyMorganz/StyLua) | Formatting (`.stylua.toml`) | `brew install stylua` |
| [selene](https://github.com/Kampfkarren/selene) | Linting (`selene.toml`, `tern.yml`) | `brew install selene` |
| [uv](https://docs.astral.sh/uv/) | Python asset tools and their tests (dependencies pinned inline) | `brew install uv` |
| luau-lsp | Type checking against the Tern SDK types | `bash scripts/fetch-luau-lsp.sh` (pinned, into `.tools/`) |
| [Tern](https://docs.stencil.so/tern/) 0.6.2 or later | Running the plugin in a sandbox | see Tern's docs |

```sh
brew install lune stylua selene uv
bash scripts/fetch-luau-lsp.sh   # pinned luau-lsp into .tools/
bash scripts/fetch-types.sh      # types/tern.d.luau (from `tern plugin types`, else tern-sdk)
```

`bash scripts/fetch-tools.sh` instead downloads the exact Lune, StyLua and selene versions CI
uses into `.tools/bin`. Never install tools globally from a script or test.

## Checks

```sh
bash scripts/check.sh
```

Runs StyLua (check only), selene, luau-lsp type checking, the Lune specs, the pack validators and
the Python tool tests, prints a summary and exits 1 if any step fails. A missing tool is a `SKIP`
locally and a failure with `CI=1`, which is how CI runs it on macOS and Linux. Faster loops
(`lune run tests/run.luau <filter>`, `stylua cat tests`) are in
[docs/develop-with-omp-tern.md](docs/develop-with-omp-tern.md#checks).

## Sandbox dev loop

Never point a development build at your real Tern. Source the sandbox in every shell that runs
`tern`; it moves Tern's config, daemon socket and logs under `$SB` and refuses to continue
otherwise:

```sh
export SB=/tmp/tern-cat-dev/me
source scripts/sandbox-env.sh
bash scripts/dev-link.sh          # tern plugin link . (saving a file reloads it)
tern --control "$SB/win.sock" &   # a sandboxed window you can drive with `tern ctl`
```

Logs land in `$SB/logs`. Block goldens (`scripts/visual.sh`), the real-window smoke test
(`scripts/smoke-window.sh`) and the soak test (`scripts/soak.sh`) are described in
[docs/develop-with-omp-tern.md](docs/develop-with-omp-tern.md). Quit sandbox windows when you are
done; the idle daemon exits on its own.

## Tests first

Write the failing spec before the code. Logic lives in pure modules under `cat/` and is tested
with Lune (`tests/unit/**/*_spec.luau`, mirroring `cat/`; runner `lune run tests/run.luau`).

- Inject time, randomness and I/O. Only `host.luau`, `window.luau` and `cat/adapters/*` may touch
  the `tern` global; everything else takes ports, so it runs under Lune without Tern.
- Test behavior through public functions, with a fixed seed: the engine is deterministic. Assert
  what a user or Tern would observe (the decision, the CSS, the intent written), not internals.
- A bug fix starts with a spec that reproduces it.
- `tests/unit/safety_spec.luau` fails the run if shipped sources call forbidden APIs; do not
  weaken it to make a change pass.
- Python tools have pytest suites in `tests/tools/`.
- Window-only behavior (overlay CSS in a real pane, palette commands) is checked by hand in a
  sandbox window; say how in the pull request.

## Safety invariants

These are review blockers. A pull request that breaks one is not merged, whatever else it does
([docs/security-privacy.md](docs/security-privacy.md) explains each):

- No writes to a terminal: no `tern.pane.write`, `cx:run`, input or key injection, `spawn` hooks.
- No reads of terminal output: no `cx.session:read`, `cx.session:settle`, lenses.
- Command lines are reduced to a category inside the hook handler (`classify` in
  `cat/core/events.luau`) and never stored, logged, returned or sent anywhere.
- No network: no `tern.fetch`, no telemetry, no remote assets.
- No clipboard (`cx:copy`) and no settings writes (`cx.settings:set`).
- `tern.process.run` only for the sound player, with a fixed argv and a validated pack path.
- The overlay never changes terminal content, focus or layout, and no pointer data reaches
  plugin code: pointer reactions are `:hover`/`:active` styles only, props are
  `pointer-events: none`.
- Carly exports validate every argument and return no command text, output or paths; Carly can
  never turn sound on, loosen quiet hours or end focus mode.
- Autonomous AI stays disabled while scheduled Carly turns are full-power.
- Only the host half writes `tern.kv`; windows send intents through the inbox.
- Packs are data: no code execution; every path and interpolated CSS value is validated.

Run the audit greps in
[docs/security-privacy.md](docs/security-privacy.md#auditing-the-guarantees) before opening a
pull request that touches I/O.

## Assets and licensing

- Code is MIT ([LICENSE](LICENSE)). Bundled art and sound are
  [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). Asset-generating code is code (MIT);
  its output is an asset (CC-BY-4.0).
- Bundled assets must be original work contributed under CC-BY-4.0. No third-party sprites,
  samples, fonts or ripped game assets, and no AI output you cannot license.
- Bundled assets are generated by deterministic scripts; commit the script change and its output
  together:
  - `uv run tools/build_packs.py`: the bundled sprite packs from `tools/art/`, plus
    `docs/images/packs-preview.png`;
  - `uv run tools/build_portals.py`: the pane-switch props in `assets/portals/`, plus
    `docs/images/portals-preview.png`;
  - `uv run tools/build_sounds.py`: the default sound pack;
  - `uv run tools/pack_build.py <dir>`: derived APNG and sheet files for a hand-drawn pack.
- Credit every bundled asset in [assets/CREDITS.md](assets/CREDITS.md), and set `author` and
  `license` in its manifest.
- Screenshots in `docs/images/` come from a sandbox and must not show a hostname, user name,
  avatar, account or home path.

## Style

- Luau: `--!strict`, formatted by StyLua (tabs, 120 columns), linted by selene. Modules return a
  table of functions; shared data shapes live in `cat/types.luau`.
- Python tools: single-file `uv run` scripts with inline dependencies (PEP 723), Pillow pinned.
- No emojis in code, comments, docs, commit messages or UI strings.
- No new runtime dependencies.

## Pull requests

1. Open an issue first for anything larger than a bug fix, so the design can be agreed on.
2. Branch off `master`. Keep pull requests small: one behavior, one fix or one pack each.
3. Commit with [Conventional Commits](https://www.conventionalcommits.org/): `feat(overlay): ...`,
   `fix(sprite): ...`, `docs: ...`, `test: ...`, `build: ...`. Scope by area: `core`, `sprite`,
   `overlay`, `assets`, `host`, `window`, `ai`.
4. Add an entry under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md) for every user-visible
   change, and update the docs it affects (config keys, pack format, safety guarantees).
5. `bash scripts/check.sh` passes locally and CI is green on macOS and Linux before review.
6. Fill in the pull request template, including how you tested window behavior.

Releases are cut by the maintainer following [docs/release.md](docs/release.md).

## Repository layout

```text
plugin.toml, host.luau, window.luau   Tern plugin manifest and the two entries
tern-cat.css                          block styles
cat/
  types.luau                          shared data contracts
  core/                               pure engine: rng, clock, events, model, needs, store, behavior, commands
  config/schema.luau                  config defaults, presets, validation, migrations
  render/                             animation names and fallbacks, block view, overlay CSS generator
  sprite/                             PNG inspection, pack.json validation, pack loader
  integrations/                       AI policy, Carly exports, sound
  host/, window/                      host and window controllers (pure, ports injected)
  adapters/                           the only modules that touch tern.fs, tern.kv, tern.json, timers
assets/
  packs/<id>/                         bundled sprite packs (orange-menace is the default)
  portals/                            pane-switch props (portal, vent, box)
  sounds/default/                     bundled sound pack
  CREDITS.md                          asset authors and licenses
config/example.json                   every config key with its default
docs/                                 usage, configuration, architecture, specs, guides
scripts/                              check, typecheck, sandbox, dev-link, smoke, soak, tool and type fetchers
tests/
  run.luau, lib/                      Lune runner and expectation library
  unit/                               *_spec.luau, mirroring cat/
  fixtures/packs/                     tiny good-* and bad-* packs (tools/make_fixtures.py)
  tools/                              pytest suites for the Python tools
  visual/                             headless block scenarios for scripts/visual.sh
tools/
  art/                                code-authored sprite and prop art
  build_packs.py, build_portals.py, build_sounds.py   regenerate bundled assets
  pack_build.py, packlib.py           derived apng/sheet files for any pack
  validate_packs.py, validate_pack.luau  pack validators
```

## How to add a behavior

A behavior is a decision in `cat/core/behavior.luau`: an id (`react.*`, `ambient.*`,
`gesture.*`), an animation, a short reason and a duration.

1. Write the spec first in `tests/unit/core/behavior_spec.luau`: the triggering event or state,
   the expected animation, and that it is suppressed by snooze, quiet hours, focus mode and the
   relevant `allow_*` toggle. Use a fixed seed.
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
