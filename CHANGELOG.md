# Changelog

All notable changes to tern-cat are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (0.x while in public beta; see
[docs/release.md](docs/release.md)).

## [Unreleased]

Targets Tern 0.6.2.

### Added

- M0 research: SDK capability matrix (`docs/sdk-capability-matrix.md`), overlay upstream RFC
  (`docs/overlay-upstream-rfc.md`) and architecture (`docs/architecture.md`) with the shared data
  contracts in `cat/types.luau`.
- Deterministic core engine: seeded PRNG, real and fake clocks, command-line classifier that
  reduces a command to a category, event sanitizer, profile model with schema migration, needs
  with capped and non-punishing offline catch-up, single-writer state store with bounded journal
  and dedupe, config schema with presets and per-field fallback, weighted behavior FSM with
  precedence (snooze, quiet hours, reduced motion, `allow_*` toggles, personality), and an intent
  allowlist.
- Twenty canonical animations with fallback chains ending in `idle`.
- Sprite packs: header-only PNG/APNG inspection, `pack.json` validation (limits, path traversal,
  canvas and frame-count checks), pack loader with fallback to the default pack, and a sanitized
  overlay CSS generator.
- AI policy module: provider interface, turn budget, redaction, response allowlist and a mock
  provider. The Carly scheduled-turn provider is disabled because scheduled Carly turns run with
  full tool access.
- Bundled original sprite packs, CC-BY-4.0: Orange Menace (default), Void and Tuxedo, each with
  all 20 animations.
- Bundled synthesized default sound pack (meow, purr, surprise, happy, swat), CC-BY-4.0.
- Pack validators: `lune run tools/validate_pack.luau` (the plugin's own rules) and
  `uv run tools/validate_packs.py` (Pillow cross-check, sprite and sound packs).
- Asset tooling: `tools/build_packs.py`, `tools/build_sounds.py`, `tools/make_fixtures.py`, and
  `tools/pack_build.py` for building the derived APNG and sprite sheet files of any pack.
- Host half (`host.luau`, `cat/host/*`): the daemon-side brain is the single writer of the cat's
  state (`tern.kv`), applies intents from the file inbox, counts commands once from host hooks
  (category only), recovers from a corrupt `kv.json` or `config.json` without crashing, and
  serves the interactive "Tern Cat" block: APNG sprite per animation, needs bars and stats,
  buttons, right-click menu, focused-block keys (`p o f space s h z`, Escape), a 7-page settings
  page that writes `config.json`, and the block-only `ls` swat parody. Opt-in sound from the host
  half (`afplay` on macOS; `pw-play`/`paplay`/`aplay` on Linux).
- Window half (`window.luau`, `cat/window/*`): per-window overlay cat drawn with `tern.css`, on
  by default, anchored to the focused pane and hidden while a cat block is focused or floats over
  it; palette commands in the Tern Cat group (open, pet, poke, feed, play, toggle-overlay,
  snooze, wake, reload-config, settings, export-identity, reset-identity, clear-ai-state); the
  global `ctrl+alt+cmd+c` hide chord; "Open cat" floats the block in the bottom-right corner
  (`rendering.block_placement`); host reactions mirrored across windows; module loading in
  timer slices to stay within the 50 ms window budget.
- Carly integration: 12 validated exports (`status`, `pet`, `poke`, `feed`, `play`, `perform`,
  `set_personality`, `configure`, `snooze`, `wake`, `explain`, `ai_status`) and a context line of
  at most 160 characters with no command text or paths.
- `rendering.block_placement` config key (`float` or `split`).
- Safety guard `tests/unit/safety_spec.luau`: fails the test run if shipped sources call APIs
  that type into panes, read terminal output, use the network or clipboard, change Tern settings
  or keybinds, start Carly turns, or spawn processes outside the host sound player.
- `scripts/visual.sh` (headless block goldens, light and dark) and `scripts/smoke-window.sh`
  (sandboxed two-window smoke test).
- Documentation: README, configuration reference (`docs/configuration.md`), performance report
  (`docs/performance.md`), updated architecture.
- Development tooling: Lune test runner, StyLua, selene, luau-lsp type checking against the
  Tern SDK types, `scripts/check.sh`, sandboxed Tern environment (`scripts/sandbox-env.sh`,
  `scripts/dev-link.sh`) and CI on macOS and Linux.
- Documentation: sprite pack specification, security and privacy, developer guide, release
  checklist, contributing guide, issue and pull request templates.

### Changed

- Carly may only mute sound and turn quiet hours on; it can no longer enable sound or loosen
  quiet hours. Window and Carly requests are rate limited (Carly: burst 3, then 10 per minute)
  and refused while more than 64 requests are pending.
- `behavior.allow_visual_obscuring: false` now keeps the overlay off terminal panes entirely; the
  `quiet_office` preset sets it.

### Removed

- `rendering.animation_fps` and `behavior.obscure_max_ms`, which never had an effect.

### Fixed

- A napping cat now regains energy while Tern stays open; `offline_hours_cap` no longer freezes
  needs in session.
- Wake and unsnooze actually wake the cat in the block.
- A transient state read error or an unwritable backup can no longer overwrite or delete a saved
  cat; an unreadable (symlinked or oversize) `config.json` is never overwritten.
- The inbox only deletes its own intent files; foreign files and directories are left alone.
- Host and windows discover the same user packs; renames longer than the name limit are rejected
  up front instead of silently reverting.
- Full pack scans in a window run one pack per timer slice to stay inside Tern's 50 ms budget.
- Command statistics are persisted at most every 1.5 s under command storms.

[Unreleased]: https://github.com/contrafy/tern-cat/commits/master
