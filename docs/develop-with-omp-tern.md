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
else downloads it from `stencil-hq/tern-sdk` (`TERN_SDK_REF`, default a pinned commit whose types
match Tern 0.9.16, the tested version). The type checker and editor tooling read it. Tern has no
plugin API version, so regenerate after upgrading Tern.

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
agent should not open real windows (`scripts/sandbox-window.sh`, `tern --control`) unless asked:
they appear on the user's desktop unless a window manager rule moves them
([Keeping test windows off your workspaces](#keeping-test-windows-off-your-workspaces-omniwm--other-wms)).

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
bash scripts/sandbox-window.sh "$SB/ctl.sock" "$SB/work"   # a window on the sandbox daemon; prints its pid
tern ctl --control "$SB/ctl.sock" stats   # then drive it: shot, pick X Y, click, css, perf, tree, ...
```

`tern help dev` lists every control command. `scripts/sandbox-window.sh` starts
`tern --control <socket> --out "$SB/target/shots" <workdir>` (from the sandbox app when it exists,
see the next section), waits for the control socket and logs where the window landed. A window
started with `TERN_DAEMON_SOCKET` set spawns its own daemon on that socket. `ctl shot` answers
with the PNG's path; with `--out` it is absolute (`$SB/target/shots/live/<name>.png`), without it
relative to the window's working directory.

Carly exports can be exercised in such a window with the Carly script commands documented at
<https://docs.stencil.so/tern/scripts/carly.html> (for example
`carly lua "return await(plugins['tern-cat'].status())"`); M0 recorded these from the docs
without executing them.

Agent reactions need no model: agent blocks report their state with OSC 7501, so a shell script
as the agent command drives `agent_state` and `agent_finished` (blocked is `waiting_input`, error
is `failed`, and the script exiting is `exited`):

```sh
cat > "$SB/fake-agent.sh" <<'EOF'
#!/bin/sh
s() { printf '\033]7501;state=%s\007' "$1"; sleep "$2"; }
sleep 24; s working 3; s blocked 8; s working 3; s done 8; s working 3; s error 8
EOF
chmod +x "$SB/fake-agent.sh"
tern ctl --control "$SB/ctl.sock" agent-command "$SB/fake-agent.sh"
tern ctl --control "$SB/ctl.sock" block agent &   # opens the agent block beside the focused pane
```

While an agent block animates, scenario commands (`block agent`, `agent-command`, `alert`) answer
"timed out after 20s" but still apply, and the control endpoint takes one command at a time, so
the script waits before its first status. Watch `last_reaction` in
`$SB/config/plugin-data/tern-cat/kv.json` and take `ctl shot`s once `block agent` has returned.

## Keeping test windows off your workspaces (OmniWM / other WMs)

Every script that opens a real window (`scripts/smoke-window.sh`, the `scripts/compat.sh` probe,
`scripts/soak.sh`, `scripts/perf-baseline.sh`) starts it through `scripts/sandbox-window.sh`. By
default that is a plain `tern --control` window: a tiling window manager cannot tell it from your
own Tern and tiles it into the workspace you are working in. Give test windows their own app
identity, then route that identity elsewhere:

```sh
bash scripts/sandbox-app.sh    # macOS; once, prints /tmp/tern-cat-dev/TernSandbox.app
```

This builds `TernSandbox.app`, an APFS clone of the Tern.app around `tern` on `PATH` (else
`/Applications/Tern.app`; override with `TERN_CAT_TERN_APP`) with bundle id
`so.stencil.tern.sandbox` (its daemon helper `so.stencil.tern.sandbox.daemon`) and the name "Tern
Sandbox". It drops the URL scheme, document types, Services entry and launch agents, so the copy
never claims `tern://` links or login items, re-signs everything ad hoc and clears quarantine. It
takes about 330 MB in `/tmp` (signing rewrites the executables; the rest stays cloned). It is
idempotent and records the source version, so it rebuilds after a Tern update; the launcher runs
it before every window, and it refuses to rebuild while windows of the copy are open.
`TERN_CAT_SANDBOX_APP` moves the copy. When the copy is missing (or off macOS) the launcher falls
back to `tern --control`, so nothing else changes. `tern ctl` and `tern plugin` keep using `tern`
on `PATH` with the same sandbox variables.

With the copy, `scripts/sandbox-window.sh`:

- launches it with `open -g -n -a TernSandbox.app --env ... --args --control ...`: in the
  background, without activating it, passing `TERN_CONFIG_DIR`, `TERN_DAEMON_SOCKET`,
  `STENCIL_LOG_DIR`, `STENCIL_LOG`, `TERN_CAT_TEST` and `PATH` (nothing else of your shell
  reaches it). A macOS whose `open` lacks `--env` runs the copy's executable directly instead; the
  window may then take the focus;
- leaves the daemon to the window as before: it starts the copy's helper (`Tern Daemon.app`) on
  `TERN_DAEMON_SOCKET`;
- gets past the closed-beta sign-in card: the ad-hoc signed copy cannot read your Tern account
  from the keychain, so the launcher sets the harness's stand-in account
  (`tern ctl ... account signed-in`). No credentials are used, and test windows and their shots
  do not show your account;
- logs placement per window on stderr, measured with CoreGraphics
  (`tools/window_placement.swift`, needs `swift`) rather than asked of the window manager, for
  example `sandbox-window: pid 53843 winB.sock: window 110394 onscreen=1 frame=-1279,30 1280x800
  visible=0%`. Window managers that hide workspaces park their windows off screen, so
  `visible=0%` means the window is on a workspace you are not looking at.

Then add one rule for `so.stencil.tern.sandbox` to your window manager; your real Tern
(`so.stencil.tern`) never matches it.

**OmniWM** (tested with 0.7.6): add one entry to `~/.config/omniwm/settings.toml` after the last
`[[appRules]]` entry (back the file up first). OmniWM live-reloads the file when it is saved; no
restart or IPC is needed. A file it cannot parse is left alone and reported on screen, and the
running settings stay.

```toml
[[appRules]]
assignToWorkspace = "7"
bundleId = "so.stencil.tern.sandbox"
id = "B4838E7D-7EA9-47C2-AC55-59A4A02012E8"
layout = "float"
```

- `assignToWorkspace` names an existing workspace you do not usually look at. OmniWM applies it
  to a window whose process has no other tracked windows; every test window is its own process,
  so each one lands there.
- `layout = "float"` keeps Tern's own 1280x800 frame, as without a window manager, and leaves the
  windows tiled on that workspace alone. `tile` would add a column and resize them.
- `id` is any UUID (`uuidgen`). Keys are sorted as OmniWM writes them. The App Rules editor's
  "Assign to Workspace" toggle is not a file key: the rule is on while `assignToWorkspace` is
  set.
- To remove the rule, delete those five lines (or the rule in Settings > App Rules) and save.

**AeroSpace** (untested): `~/.aerospace.toml`, then `aerospace reload-config`:

```toml
[[on-window-detected]]
if.app-id = 'so.stencil.tern.sandbox'
run = ['layout floating', 'move-node-to-workspace 7']
```

**yabai** (untested; it matches the app name): `yabai -m rule --add app='^Tern Sandbox$'
space=7 manage=off`.

**No window manager**: build the copy anyway if you like; its windows open behind the active app
without taking the focus.

Parked windows still run, and every check reads them through the control socket and `ctl shot`,
which renders the window's own document. macOS may throttle drawing for a window it considers
hidden, so for `scripts/perf-baseline.sh` frame and CPU figures, look at that workspace while it
runs or compare runs made the same way.

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

Tern stops a hook that exceeds its budget (host 2 s, window 50 ms per call). Up to 0.8.3 the hook
then stays off until the next reload; 0.9.6 and later pause it (5 s, doubling for repeated trips)
and log `plugin hook exceeded its budget; paused` and `resumed after its pause`
([sdk-capability-matrix.md](sdk-capability-matrix.md#1-host-hooks)); look for those in the logs
when the cat stops reacting.

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

Opens **two windows** (`$SB/winA.sock` and `winB.sock`, through `scripts/sandbox-window.sh`) on
a sandboxed daemon. They appear on your desktop unless a window manager rule moves them
([Keeping test windows off your workspaces](#keeping-test-windows-off-your-workspaces-omniwm--other-wms)),
so run it only when that is acceptable. It links a snapshot copy of the
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

On exit (including failure) it quits both windows and stops the sandbox daemon. Plain
`tern --control` windows show your real signed-in Tern account (sign-in is not isolated by
`TERN_CONFIG_DIR`), so crop screenshots before sharing them; sandbox app windows show the
harness's stand-in account.

## Tern compatibility: `scripts/compat.sh` (needs Tern and a desktop)

```sh
bash scripts/compat.sh      # SB defaults to /tmp/tern-cat-dev/compat-<tern version>
```

Run it after every Tern update and before every release ([release.md](release.md)). Everything
runs in sandboxes under `$SB`; it opens windows (the smoke test's two, then one probe window at a
time, all through `scripts/sandbox-window.sh`) and, on exit, quits them and stops the sandbox
daemon. Re-running is safe. Steps:

1. Records `tern --version` in `$SB/compat/version.txt`.
2. Writes `tern plugin types` to `$SB/compat/types/` and compares it with the pinned tern-sdk
   types (`SDK_REF` in `scripts/fetch-types.sh`; needs network): identical, or a `+N -M` count,
   the changed declarations and the full diff in `$SB/compat/types.diff`. A difference is
   reported, not a failure: classify it in [sdk-capability-matrix.md](sdk-capability-matrix.md)
   and re-pin.
3. Runs `scripts/check.sh`, `scripts/visual.sh` (`$SB/visual`; view the shots) and
   `scripts/smoke-window.sh` (`$SB/smoke`), logging to `$SB/compat/`.
4. The DOM-hook probe (`tests/compat/dom_probe.py`, Python standard library): links snapshots of
   tern-cat and of `tests/compat/probe` (a sandbox-only plugin whose **Report** command writes
   what `window.luau` reads from Tern: the inset settings and `reduce_motion`, the focused
   `PaneInfo`, the tab layout, the chord's binding), opens a control window, splits it and checks
   with `ctl dump`, `ctl pick`, `ctl css` and `ctl stats`:
   - `div.tn-stage > section.tn-pane` (two, ratio-exact), `.on:not(.off)` on the focused pane
     only, and in each `div.tn-body > div.tv` with `div.tv-fx.top` (covering the view),
     `div.tv-grid > div.tv-fx` and `div.tv-layer`;
   - the view's inset against `travel.insets`, at Tern's defaults and again in a second window
     with `pane_headers` Split, Islands and a 16 px interface;
   - `--tv-px`/`--tv-py` (a probe sheet's pseudo-element must land on the grid's origin) and,
     statically in the Tern executable, `var(--tv-aside)`;
   - the overlay cat (`div.tv-fx.top::after`, picked) at all four corners, a click on it keeping
     the terminal focused and typing running; `walk` (travel sheet installed and cleared, one
     cat) and `portal` switches; the cat stepping aside in `less`; **Open cat** floating a
     focused `section.tn-pane.pip.pip-focus.pip-r.pip-b` whose block renders in
     `div.tv-cover > div.sf-region.sf-main` with `.sf-img-frame`, whose Pet and Settings buttons
     work and which closes; system Reduce Motion stopping the cat's animation.

   It exits non-zero with the missing or changed hooks listed; results and shots are in
   `$SB/compat/dom-probe.txt` and `$SB/compat/shots/`. Pointer reactions and transition frames
   still need a look: shoot frames as in [README screenshots](#readme-screenshots-needs-tern-and-a-desktop).

The summary is in `$SB/compat/summary.txt`.

## Soak test: `scripts/soak.sh` (needs Tern, a desktop and `uv`)

```sh
SB=/tmp/tern-cat-dev/soak bash scripts/soak.sh          # 30 minutes
SB=/tmp/tern-cat-dev/soak bash scripts/soak.sh 300      # duration in seconds
```

Like the window smoke test it opens **two windows** through `scripts/sandbox-window.sh` on a
sandboxed daemon and links a snapshot of the package. It resets the sandbox's `kv.json` and
inbox, writes
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

`docs/images/overlay-cat.png`, `floated-card.png`, `pane-switch.gif` and `pane-walk.gif` come from a sandbox
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

- For `pane-walk.gif`: set `rendering.pane_transition` to `walk`, split right and then split the
  right pane down, and `ctl size 960 600` so the shots are 1920x1200 (halve with a box filter
  and crop below the tab strip for a 960 px wide GIF). A walk takes about 0.9 s and a climb or
  leap trip longer: shoot `focus right`, `focus down` and `focus left` the same way, `freeze-anims`
  first, then the switch, then `motion-at <ms>` and `shot` every 40 ms. The in-pane cat's
  clear timer runs in real time, so shoot a sandbox copy whose `CLEAR_AFTER_MS` in
  `cat/render/travel.luau` is raised to 20000. Join the trips with short holds on one shared palette.

View every frame before committing it.

## Cleaning up

`rm -rf .sandbox` removes the sandbox config, daemon socket, logs and shots. Stop any sandbox
window first; an idle daemon with no clients exits on its own after about 10 s.
`rm -rf /tmp/tern-cat-dev/TernSandbox.app` (or `$TERN_CAT_SANDBOX_APP`) removes the sandbox app;
remove its window manager rule with it.
