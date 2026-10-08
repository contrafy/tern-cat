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
- Development tooling: Lune test runner, StyLua, selene, luau-lsp type checking against the
  Tern SDK types, `scripts/check.sh`, sandboxed Tern environment (`scripts/sandbox-env.sh`,
  `scripts/dev-link.sh`) and CI on macOS and Linux.
- Documentation: sprite pack specification, security and privacy, developer guide, release
  checklist, contributing guide, issue and pull request templates.

[Unreleased]: https://github.com/contrafy/tern-cat/commits/master
