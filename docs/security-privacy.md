# Security and privacy

tern-cat runs inside your terminal, next to shells, editors and secrets. This document states
what it can and cannot do, what it stores, and how to check those claims yourself.

**Tern has no permission system.** "Tern does not declare, check or prompt for capabilities"
([Tern docs, concepts/security](https://docs.stencil.so/tern/concepts/security.html); see
[sdk-capability-matrix.md](sdk-capability-matrix.md#8-api-version-and-cli-routes)). Any plugin can
call every API in the SDK. Every guarantee below is therefore self-imposed by tern-cat's code and
enforced by review and tests, not by Tern. The [audit](#auditing-the-guarantees) section shows how
to verify them.

## Threat model

| Asset | Threat | Mitigation |
|---|---|---|
| Shell input and running programs | The cat types into a pane or runs commands | Never calls PTY or input APIs |
| Terminal output and scrollback | The cat reads secrets printed to the terminal | Never calls output-reading APIs |
| Command lines (may contain tokens, hostnames, paths) | Stored, logged or sent to a model | Reduced to a category inside the hook handler |
| Local files | A sprite pack escapes its directory or injects CSS | Path validation before any read; CSS values sanitized |
| Network | Telemetry or data exfiltration | No network API is used |
| AI agent (Carly) | The cat triggers a full-power agent turn, or an agent abuses exported functions | Autonomous AI disabled; exports validate arguments and return no private data |
| Focus and input | The overlay steals clicks, selection or keystrokes | Overlay is CSS with `pointer-events: none` |

Out of scope: a malicious Tern build, other plugins (which have the same unrestricted access), and
a user who edits the plugin source.

## Guarantees

### Never writes to a terminal

tern-cat does not call `tern.pane.write` (writes into a pane's PTY), `cx:run`, or any API that
sends input, keys or commands to a pane. It does not register a `spawn` hook, so it cannot alter
how shells start. No mischief mode changes this: the "knock a character off `ls`" gag is drawn
inside the cat's own block ([architecture.md](architecture.md#renderers)).

### Never reads terminal output

tern-cat does not call `cx.session:read`, `cx.session:settle`, or `tern.lens.*` (lenses receive
command output lines). Host hooks deliver metadata only: `CommandFinishedEvent` is
`{ pane, line, status, took_ms }` with no output text
([sdk-capability-matrix.md](sdk-capability-matrix.md#1-host-hooks)).

### Command lines become a category and are discarded

`command_started`/`command_finished` carry the full command line. tern-cat passes it to
`classify(line)` in `cat/core/events.luau` inside the hook handler, which returns one of `test`,
`build`, `vcs`, `list`, `sudo`, `editor`, `network`, `package`, `other`. Only the category
continues. The line is not stored, logged, put in an event, or returned. Focus mode
(`cat/core/running.luau`) additionally keeps, in memory only, the pane id and start time of
each running command.

Every event's attributes then pass through `sanitizeAttributes` (same file), which keeps only
allowlisted keys per event type and only values of the declared kind: booleans, finite numbers,
known categories, or words matching `^[%w_%-]+$` of at most 32 characters. A path, a URL or a
sentence cannot survive it.

`tests/unit/core/events_spec.luau` covers the classifier and sanitizer.

### No network

tern-cat does not call `tern.fetch` or any other network API, and has no telemetry, update check
or remote asset loading. Pack paths cannot be URLs (`:` is rejected).

### Autonomous AI is disabled

The PRD asked for opt-in autonomous AI reactions. M0 found that Tern 0.6.2 has no hidden or
constrained completion API: a scheduled Carly turn is a full Carly turn with access to Lua,
`run_command` and `send_input`, and "there is no separate Carly approval or per-turn access tier"
([sdk-capability-matrix.md](sdk-capability-matrix.md#7-carly)). Prompt wording cannot make that
safe, so the `carly_schedule` provider in `cat/integrations/ai.luau` is permanently unavailable
and reports why. `ai.enabled` defaults to `false` and `ai.provider` to `none`.

The AI module still contains the policy that a future provider must go through, all tested with a
mock provider (`tests/unit/integrations/ai_spec.luau`):

- a per-hour, per-day and cooldown budget;
- `redact`: providers receive only a fixed-template sentence built from the event type,
  category, outcome and duration or idle bucket (for example "A test command failed after ..."),
  never command text, output or paths;
- a response allowlist: a suggestion may contain only `animation` (an allowed canonical
  animation) and short printable `text`; text containing links is rejected.

`ai.share_command_output` exists in the config schema but is forced to `false` with a warning
(`cat/config/schema.luau`).

### Carly exports

The window half exposes a small set of functions to Carly (`cat/integrations/carly.luau`). Tern
does not ask the user before Carly calls them, so:

- every argument is validated; a call that cannot be turned into a valid intent returns an error
  and is never applied;
- mutating calls become intents that go through the same allowlist as every other source
  (`cat/core/commands.luau`: allowlisted kinds and per-kind arguments);
- the `set_config` allowlist is source-aware: intents with source `carly` may not opt into sound
  (the only feature that starts a process), loosen quiet hours or end focus mode. Carly may set
  `sound.enabled` only to `false`, `quiet.hours_enabled` and `behavior.focus_mode` only to
  `true`, and may not change `sound.volume`, `quiet.start` or `quiet.stop`; the block, the window
  and the keyboard keep the full allowlist;
- read-only views (status, explain, AI status, context) return small summaries; nothing returns
  command text, terminal output, file paths or journal summaries.

### Process execution is limited to the sound player

Tern has no audio API, so sound effects run a local player (`cat/integrations/sound.luau`):

- macOS: `/usr/bin/afplay` (fixed path, checked for existence).
- Linux: one fixed probe, `sh -c "command -v pw-play paplay aplay"` (fixed argv, no
  interpolation), then the first player found.
- Sound is opt-in (`sound.enabled`, default `false`) and Carly cannot turn it on (see above).
- The argv is fixed per player; the only variable parts are the clamped volume and the file path.
- The path comes from a validated sound pack: pack-relative, same segment rules as sprite paths,
  audio extension only.
- Sound is off by default (`sound.enabled: false`), respects quiet hours and snooze, and is rate
  limited to one sound per 2 seconds.

No other `tern.process.run` call exists. The single call site is the `run` port in `host.luau`,
which `cat/host/brain.luau` passes only to `sound.detect` and `sound.play`.

### The overlay is visual only

The on-by-default overlay is a stylesheet installed with `tern.css` from the window half
(`cat/render/overlay.luau`). It draws a `::after` pseudo-element on the focused pane's body with
`pointer-events: none`.

M0 verified ([sdk-capability-matrix.md](sdk-capability-matrix.md#2-drawing-over-panes)):

- clicks, focus, selection and typing pass through the cat to the terminal;
- `cx.session:read` returned identical content with the overlay on and off (a one-off check during
  the M0 experiment, not something the plugin does).

It is frozen by Tern's reduced-motion setting and can be hidden or snoozed.

### Pack validation

Sprite and sound packs are data, never code ([sprite-pack-spec.md](sprite-pack-spec.md)):

- `pack.json` is parsed as JSON; there is no scripting, templating or behavior hook in a pack.
- Paths are validated before any filesystem access: relative only, no `..`, `.`, empty segments,
  `\`, `:` or leading `/`, restricted character set, `.png`/`.apng` only
  (`checkPath` in `cat/sprite/manifest.luau`). The `bad-traversal` and `bad-absolute` fixtures in
  `tests/fixtures/packs/` are rejected by both validators.
- Sizes are bounded before reading: 1 MiB per file, 512 files, 16 MiB per pack, 64 KiB manifest.
- Images are inspected by header only (`cat/sprite/png.luau`); pixels are never decoded by the
  plugin.
- The overlay CSS generator sanitizes every interpolated value (`cat/render/overlay.luau`): the
  sheet URL must be a validated relative path or a base64-only `data:image/png` URL, keyframe
  names are reduced to `[a-z0-9-]`, and every number is clamped. A pack cannot inject CSS.
- A user pack cannot replace a bundled pack (duplicate ids are ignored).
- Removing a pack (Settings > Appearance, two clicks) is the only delete of user-installed files.
  It refuses bundled packs and any folder that is not a direct child of `<data>/packs/`
  (`removableDir` in `cat/sprite/loader.luau`; `.`/`..` segments are refused, not resolved). It is
  not reachable from windows, the inbox or Carly.

## What is stored where

All writable state lives under `tern.plugin.data` (`cat/adapters/paths.luau`); tern-cat never
writes inside its plugin directory. On a default install `tern.kv` lives at
`<tern config>/plugin-data/<plugin id>/kv.json`
([sdk-capability-matrix.md](sdk-capability-matrix.md#6-shared-per-user-cat-model)).

| Data | Location | Contents | Writer |
|---|---|---|---|
| Cat state | `tern.kv`, key `state` | One `StoreEnvelope` (`cat/types.luau`): schema version, `rev`, profile (cat id, needs, mood, counters of pets/pokes/feeds/plays/command reactions, fail streak, timestamps), journal (last 50 entries of time, event id, kind and a short fixed summary), `seen` ring (last 256 event/intent ids), last reaction, snooze time | host half only |
| Config | `<data>/config.json` | Your settings (`config/example.json` documents every key). Human-editable. A file that exists but cannot be read (symlink, over 256 KiB, read error) is never overwritten; settings changes fail with a note instead | you; the host half for settings changes |
| Inbox | `<data>/inbox/<ms>-<hex>.json` | One pending intent per file (`kind`, `source`, validated `args`, id, time). The host deletes each file after applying it, and undecodable intent files after 5 s. It only ever deletes readable files with the intent name pattern; foreign names, directories and unreadable entries are logged once and left in place (`cat/host/inbox.luau`) | window halves |
| Identity export | `<data>/exports/identity-<cat id>-<time>.json` | Written only when you request an export: cat name, appearance, personality and profile | host half |
| User packs | `<data>/packs/<id>/`, `<data>/sounds/<id>/` | Packs you install | you; the host half deletes a sprite pack's folder when you remove it in settings |

No command line, command output, working directory, hostname or file path is stored. Counters
are bounded and never derived from command output.

To erase everything, remove the plugin and delete its `plugin-data/<id>/` directory.

## Auditing the guarantees

Run from the repository root. Each command searches the shipped Luau sources (entries and `cat/`,
excluding tests, which mention these names on purpose).

```sh
# Forbidden APIs: PTY writes, command execution, output reads, lenses, network, clipboard,
# settings writes and spawn hooks. Expected: no output (grep exits 1).
grep -rnE --include='*.luau' --exclude-dir=tests --exclude-dir=types --exclude-dir=.tools --exclude-dir=.sandbox \
  'tern\.pane\.write|:run\(|session:(read|settle)|tern\.fetch|:copy\(|settings:set|tern\.lens|on\("spawn"' .

# Process execution. Expected: one match, the `run` port in host.luau; then check that
# cat/host/brain.luau passes deps.run only to sound.detect and sound.play.
grep -rnE --include='*.luau' --exclude-dir=tests --exclude-dir=types --exclude-dir=.tools --exclude-dir=.sandbox \
  'process\.run' .

# Direct filesystem and kv access. Expected: only cat/adapters/*.
grep -rnE --include='*.luau' --exclude-dir=tests --exclude-dir=types --exclude-dir=.tools --exclude-dir=.sandbox \
  'tern\.(fs|kv)\.' .
```

Also review:

- `cat/core/events.luau`: `classify` and `sanitizeAttributes`.
- `cat/core/commands.luau`: the intent allowlist.
- `cat/integrations/carly.luau`: what each export returns.
- `cat/integrations/sound.luau`: the player argv.
- `cat/render/overlay.luau`: `pointer-events: none` and value sanitizing.

A change that weakens any guarantee in this document is a review blocker
([CONTRIBUTING.md](../CONTRIBUTING.md#safety-invariants)).

## Reporting a vulnerability

Open a GitHub issue without exploit details and ask for a private contact, or use GitHub's
private vulnerability reporting on the repository if it is enabled.
