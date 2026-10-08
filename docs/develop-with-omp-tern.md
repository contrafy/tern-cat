# Developing tern-cat

The dev loop for working on tern-cat by hand or from an agent (omp) running inside Tern. Commands
run from the repository root. Commands marked **needs Tern** require the `tern` CLI and, for
windows, a desktop session; everything else runs headless.

## Prerequisites

| Tool | Used for | Install |
|---|---|---|
| [Lune](https://github.com/lune-org/lune) | Unit tests, Luau pack validator | `brew install lune` |
| [StyLua](https://github.com/JohnnyMorganz/StyLua) | Formatting (`.stylua.toml`) | `brew install stylua` |
| [selene](https://github.com/Kampfkarren/selene) | Linting (`selene.toml`, `tern.yml`) | `brew install selene` |
| [uv](https://docs.astral.sh/uv/) | Python tools (Pillow is pinned inline in each script) | `brew install uv` |
| luau-lsp | Type checking against the Tern SDK types | `bash scripts/fetch-luau-lsp.sh` (pinned, into `.tools/`) |
| Tern | Running the plugin | <https://docs.stencil.so/tern/> |

`bash scripts/fetch-tools.sh` downloads the pinned Lune, StyLua and selene versions CI uses into
`.tools/bin` (macOS arm64 and Linux x86_64); `scripts/check.sh` puts that directory first on
`PATH`. Do not install tools globally from a test run.

## Types

```sh
bash scripts/fetch-types.sh
```

Writes `types/tern.d.luau` (gitignored) with `tern plugin types` when the `tern` CLI is present,
else downloads it from `stencil-hq/tern-sdk` (`TERN_SDK_REF`, default `main`). The type checker
and editor tooling read it. M0 targeted Tern 0.6.2; Tern has no plugin API version, so regenerate
after upgrading Tern.

## Checks

```sh
bash scripts/check.sh
```

Runs, in order: `stylua --check`, `selene`, `scripts/typecheck.sh` (luau-lsp over `host.luau`,
`window.luau` and `cat/**`), `lune run tests/run.luau`, and `uv run tools/validate_packs.py`. It
prints a summary and exits 1 if any step fails. Missing tools are reported as `SKIP` locally; with
`CI=1` they fail, which is how `.github/workflows/ci.yml` runs it on macOS and Linux.

Faster loops:

```sh
lune run tests/run.luau             # every tests/unit/**/*_spec.luau
lune run tests/run.luau manifest    # only tests whose name contains "manifest"
stylua cat tests                    # format in place
selene cat tests                    # lint
bash scripts/typecheck.sh           # exit 0 ok, 1 type errors, 2 luau-lsp or types missing
```

Every module under `cat/` except `cat/adapters/*` is pure and dependency-injected, so behavior,
rendering decisions, validation and the host/window controllers are tested under Lune without
Tern. Write the test first.

## Sandbox isolation

Never run development builds against your real Tern config. Source the sandbox script in every
shell that runs `tern`:

```sh
source scripts/sandbox-env.sh
```

It:

- sets `SB` (default `$PWD/.sandbox`, gitignored) and points `TERN_CONFIG_DIR`,
  `TERN_DAEMON_SOCKET`, `STENCIL_LOG_DIR` and `STENCIL_LOG` into it;
- unsets `TERN_PANE`, `TERN_PANE_SOCKET`, `TERN_WINDOW_KEY`, `TERN_WINDOW_SOCKET`,
  `TERN_BLOB_DIR`, `TERN_COMPLETE`, `TERN_LENSES` and `TERN_IDENTITY`;
- refuses (returns 1) unless `tern plugin dir` now resolves under `$SB`.

Why the `unset` matters: a shell running inside a Tern pane inherits variables that point at your
real daemon and pane. In M0 a sandboxed window half still read the parent Tern's
`TERN_PANE_SOCKET` and `TERN_PANE` through `tern.getenv` until they were unset
([sdk-capability-matrix.md](sdk-capability-matrix.md#dev-isolation-recipe)).

Set `SB` before sourcing to use another directory (`SB=/tmp/tern-cat-dev source
scripts/sandbox-env.sh`). The Tern account sign-in is not isolated by `TERN_CONFIG_DIR`; the
plugin never touches it.

### Running inside omp

omp agent shells live in a Tern pane, so they carry the variables above. Every agent command that
invokes `tern` must run in a shell that has sourced `scripts/sandbox-env.sh` in the same command
(for example `bash -c 'source scripts/sandbox-env.sh && tern plugin list'`), because each tool
call may start a fresh shell. Unit tests, linters and the pack tools do not need the sandbox. An
agent should not open real windows (`tern --control`) unless asked: they appear on the user's
desktop.

## Linking and reloading (needs Tern)

```sh
bash scripts/dev-link.sh            # sources the sandbox, then `tern plugin link .`
```

Then, in a sandboxed shell:

```sh
tern plugin list                    # the running daemon's plugins, else the directory's
tern plugin reload                  # reload every plugin; exits 1 on problems or with no daemon running
```

Linking requires the plugin entries (`plugin.toml`, `host.luau`, `window.luau`). Saving a file in
a linked plugin reloads it in under 1.5 s. Window halves lose all Lua state on reload and
`window_start` does not refire, so the window entry rebuilds its presentation at load
([architecture.md](architecture.md#ownership-rules-multi-window-correctness)).

## Real windows (needs Tern and a desktop)

The window half (overlay CSS, Carly exports, palette commands, keybindings) only runs in a real
window; headless shots load no window halves.

```sh
source scripts/sandbox-env.sh
tern --control "$SB/ctl.sock" &           # a window on the sandbox daemon, with a control endpoint
tern ctl --control "$SB/ctl.sock" stats   # then drive it: shot, pick X Y, click, css, perf, tree, ...
```

`tern help dev` lists every control command. A window started with `TERN_DAEMON_SOCKET` set
spawns its own daemon on that socket. `ctl shot` writes relative to the window's working
directory.

Carly exports can be exercised in such a window with the Carly script commands documented at
<https://docs.stencil.so/tern/scripts/carly.html> (for example
`carly lua "return await(plugins['tern-cat'].status())"`); M0 recorded these from the docs
without executing them.

## Headless golden shots (needs Tern)

`tern shot` renders scenarios offscreen. It loads user plugins only when the scenario attaches an
in-process daemon with `remote loopback`, which loads `$TERN_CONFIG_DIR/plugins` (the sandbox,
after `scripts/dev-link.sh`). Only the host half (the block) runs headless.

A scenario is one command per line (`#` comments, quoted strings):

```text
remote loopback sandbox
# The palette offers "New Tern Cat block" (the [[blocks]] title in plugin.toml); Enter opens it.
palette "New Tern Cat"
key Enter
freeze-anims
motion-at 150
shot cat-block
```

```sh
source scripts/sandbox-env.sh
tern shot path/to/scenario.txt --theme both --out "$SB/shots"
```

- `freeze-anims` plus `motion-at <ms>` pin APNG and CSS animation to a deterministic time. They
  do not pin Lua timers, which run on the daemon's real clock.
- Headless panes run your real login shell and dotfiles. Avoid the scenario `run` command, or pin
  `SHELL` and `HOME`.
- Screenshots must not show personal paths, hostnames or prompts
  ([release.md](release.md)).

## Logs

The sandbox sets `STENCIL_LOG=warn,stencil=info,tern::plugin=debug` and writes daemon and window
logs to `$SB/logs` (`STENCIL_LOG_DIR`). Plugin load errors, budget trips and plugin log lines
appear there. `tern plugin list --json` and `tern plugin reload` also report load problems.

Tern disables a hook that exceeds its budget (host 2 s, window 50 ms per call) until the next
reload ([sdk-capability-matrix.md](sdk-capability-matrix.md#1-host-hooks)); look for that in the
logs when the cat stops reacting.

## Block goldens: `scripts/visual.sh` (needs Tern)

```sh
SB=/tmp/tern-cat-dev/visual bash scripts/visual.sh          # every tests/visual/*.txt scenario
SB=/tmp/tern-cat-dev/visual bash scripts/visual.sh block    # only scenarios whose name contains "block"
```

Sources the sandbox, links the repository, and runs each `tests/visual/*.txt` scenario with
`tern shot --theme light` and `--theme dark`. Before each theme it deletes
`$TERN_CONFIG_DIR/plugin-data/tern-cat` and sets `TERN_CAT_TEST=frozen,seed=7`, so every run
starts from a fresh cat with a fixed seed and frozen host timers (see `parseTestMode` in
`cat/host/controls.luau`; block args `test`, `frozen`, `seed=N` do the same). PNGs and layout JSON
go to `$SB/shots/<scenario>/`. It exits 1 if any shot fails.

`tests/visual/block.txt` produces `block-idle`, `block-petted` and `block-settings` in both
themes (6 shots). The scenario syncs on a main-region line (`<name> settings · saved to
config.json`) because `plugins expect` cannot see `prefs` or dock text.

Compare the block region only: headless panes run your real login shell, so the left pane shows
your prompt and clock. Only the host half runs headless, so the overlay never appears here.

## Window smoke test: `scripts/smoke-window.sh` (needs Tern and a desktop)

```sh
SB=/tmp/tern-cat-dev/smoke bash scripts/smoke-window.sh
```

Opens **two visible windows** on your desktop (`tern --control $SB/winA.sock` and `winB.sock`) on
a sandboxed daemon, so run it only when that is acceptable. It links a snapshot copy of the
package (`plugin.toml`, entries, CSS, `cat`, `assets`, `config`) rather than the working tree,
so edits made during the run do not reload the plugin mid-test. It needs `python3` for reading
`kv.json` and `ctl` output.

Checks (each prints `PASS` or `FAIL`; exit code non-zero if any fail):

- the overlay sheet `plugin:local:tern-cat:overlay` is installed;
- "Pet the cat" raises `stats.pets` by exactly 1 and the inbox empties within 2 s;
- the toggle command and the `ctrl+alt+cmd+c` chord each hide (0 rules) and show the sheet;
- Carly `status()` contains a mood, `feed('rm -rf /')` returns `ok = false`, `ai_status()`
  reports `enabled = false`;
- window B has its own sheet;
- one command typed in window A adds exactly one `cmd-` entry to kv `seen` with two windows
  open;
- the Tern Cat line in `carly context` has the cat summary, no command text, and is at most 160
  characters;
- a screenshot is saved to `$SB/shots/`.

On exit (including failure) it quits both windows and stops the sandbox daemon. The windows show
your real signed-in Tern account (sign-in is not isolated by `TERN_CONFIG_DIR`), so crop
screenshots before sharing them.

## Soak test: `scripts/soak.sh` (needs Tern, a desktop and `uv`)

```sh
SB=/tmp/tern-cat-dev/soak bash scripts/soak.sh          # 30 minutes
SB=/tmp/tern-cat-dev/soak bash scripts/soak.sh 300      # duration in seconds
```

Like the window smoke test it opens **two visible windows** on a sandboxed daemon and links a
snapshot of the package. It resets the sandbox's `kv.json` and inbox, writes
`{ "behavior": { "activity": "chaos" } }` as `config.json` (the most activity), and opens the cat
block in window A. `tools/soak.py` (run with `uv run --with psutil`) then alternates every 20 s
between typing `true`, `false` or `ls` + Enter in window A and running **Pet the cat** in window
B, and every 30 s samples CPU (CPU-time delta, percent of one core) and RSS of both windows and
the daemon, `kv.json` size, journal and `seen` lengths and the inbox file count.

Output: one JSON line per sample on stdout, `$SB/soak/samples.csv`, and `$SB/soak/summary.json`
with CPU p50/p95/max, RSS first/last/max and slope (MiB per minute, whole run and second half),
log lines since the start matching error, warn, "took over", budget, disable and reload, and these
checks (exit code non-zero if any fail):

- `cmd-` entries in `seen` grew by exactly the number of typed commands;
- `stats.pets` grew by exactly the number of pets;
- journal stayed at most 50 entries and `seen` at most 256;
- the inbox is empty at the end.

The command count compares `seen` entries, so it is only exact while `seen` has not wrapped
(256 ids, about 85 minutes at the default pace of one command and one pet per 40 s). Results for
the last run are in [performance.md](performance.md#soak-test).

## Regenerating assets

All bundled assets are generated by deterministic scripts; rerunning them reproduces
byte-identical files. Commit the script change and its output together.

```sh
uv run tools/build_packs.py         # bundled sprite packs from tools/art/ + docs/images/packs-preview.png
uv run tools/build_portals.py       # pane-switch props in assets/portals/ + docs/images/portals-preview.png
uv run tools/build_sounds.py        # assets/sounds/default
uv run tools/make_fixtures.py       # tests/fixtures/packs (tiny good/bad packs for the specs)
uv run tools/pack_build.py DIR      # derived apng/sheet for one hand-drawn pack (see sprite-pack-spec.md)
uv run tools/validate_packs.py      # validate every bundled sprite and sound pack
```

## README screenshots (needs Tern and a desktop)

`docs/images/overlay-cat.png`, `floated-card.png` and `pane-switch.gif` come from a sandbox
window, cropped to the panes so the window chrome (account avatar, tabs) is not in them:

- Link a snapshot copy of the package, as `scripts/smoke-window.sh` does, and start the window in
  a neutral directory such as `/tmp/catnip` (the floated card's title shows the directory relative
  to the temp folder).
- Panes run the window's `SHELL` with your dotfiles. Start the window with `SHELL=/bin/bash`,
  then make the prompt plain in every pane before anything is shot:
  `tern ctl --control "$SB/win.sock" run "\"export PS1='\$ ' BASH_SILENCE_DEPRECATION_WARNING=1; clear\""`.
- The window shows your real Tern account. If it shows the closed-beta gate instead (for example
  with a changed `HOME`), `tern ctl ... account signed-in` puts a stand-in account there; crop the
  chrome either way.
- `run`, `split right`, `focus left|right` and `plugins run plugin.tern-cat.open` drive the
  window; `plugins run plugin.tern-cat.wake` wakes a napping cat before a shot.
- For the pane-switch GIF: `freeze-anims`, `focus left`, then `motion-at <ms>` and `shot` every
  40 ms from 0 to 840 (the dive and the emerge both start at the switch), and again for
  `focus right`. Assemble the frames with Pillow on one shared palette.

View every frame before committing it.

## Cleaning up

`rm -rf .sandbox` removes the sandbox config, daemon socket, logs and shots. Stop any sandbox
window first; an idle daemon with no clients exits on its own after about 10 s.
