# Performance

Measured numbers for tern-cat, how they were taken, and how they compare with the PRD targets.
All figures come from sandboxed runs (`scripts/sandbox-env.sh`) on one machine: an Apple
M-series Mac (M5) on macOS 27, Tern 0.6.2 (`4b3ed42`). They are single-machine samples, not a
benchmark suite.

## Method

- **CPU**: process CPU-time deltas (psutil, or `ps` sampling) over 15-30 s per state, reported as
  percent of one core. The daemon (host half) and the window process (window half) are measured
  separately.
- **Frames**: `tern ctl --control <sock> stats` frames per second.
- **Latency**: time from `tern ctl click` on the block's sprite until the updated text appears in
  the window DOM, polled with `tern ctl tree`. Each poll includes a `ctl` process spawn and round
  trip (about 7-15 ms), so the figures are upper bounds.
- **Load times**: the plugin's own log lines (`tern-cat window ready in ... ms (N load slices,
  slowest ... ms; overlay setup ... ms)` and the host's load timing).
- The sandbox window may have been unfocused or partly occluded on the desktop; that was not
  controlled. The CPU figures for the integrated plugin include a few plugin reloads caused by
  repository edits during the run.

Sources: the M0 spikes (RenderSpike: block rendering; OverlaySpike: CSS overlay), the
integration runs of the host half and the window half, and the baseline run below.

### Idle and memory baseline run

`SB=/tmp/tern-cat-dev/<name> bash scripts/perf-baseline.sh` (driver: `tools/perf_baseline.py`,
psutil via uv; about 40 minutes, one visible control window at a time). It links a snapshot copy
of the package and writes `$TERN_CONFIG_DIR/plugin-data/tern-cat/config.json` with the `zen`
activity, `rendering.overlay = true` and `rendering.block_placement = "float"`. The zen preset
sets `behavior.allow_visual_obscuring = false`, which hides the overlay entirely, so the config
overrides that one field to `true`; without it "overlay on" would draw nothing.

- **Idle CPU**: one window on a fresh sandbox daemon, no input for 10 minutes, CPU time of the
  window and daemon processes (each with its child processes) sampled every 15 s (40 samples).
  Run once with the cat block floated over the shell pane (`plugin.tern-cat.open`; when that
  leaves a split, the driver floats the focused pane with `ctl pip float br`) and once with no
  block. While the block floats over the focused pane the overlay steps aside by design (its
  sheet had 0 rules at the end of that run; 2 rules in the run without a block).
- **Memory**: RSS (psutil) and macOS physical footprint (`footprint -p`, the figure Activity
  Monitor shows as Memory) of the window and daemon processes after a 2-minute settle, in three
  states, each repeat on a fresh daemon and window: (a) plugin unlinked
  (`tern plugin unlink tern-cat`), (b) linked, overlay only, (c) linked, block floated. Three
  repeats, interleaved a, b, c. psutil's USS is unavailable on macOS here (`task_for_pid`
  denied), so physical footprint replaces it.
- Apple M5, 10 cores, macOS 27, Tern 0.6.2. Window focus and occlusion were not controlled; no
  other Tern windows ran on the sandbox daemon.

## Results

### Integrated plugin (host and window halves together)

| State | Daemon CPU | Window CPU | Notes |
|---|---|---|---|
| No block open, overlay on | 0.13% | 0.87% | Window figure includes the animated overlay. |
| Block visible, cat sleeping | 0.11% | 0.82% | |
| Block visible, cat awake and animating | 0.22% | 1.29% | |

### Overlay only (window half, block closed, Carly UI never opened)

| State | Window CPU | Frames/s |
|---|---|---|
| Animating (default preset) | 0.07-0.83% | about 3 |
| Hidden (toggle) | 0.17-0.20% | 0 |
| Still frame (reduced motion) | 0.13-0.33% | 0 |
| `chaos` preset, frequent walking | 0.53% | not recorded |

No slow-tick warnings were logged. With Carly's own pill open the window baseline was about 3.3%,
from Carly's animation, not tern-cat.

### Latency and load

| Measure | Result |
|---|---|
| Click on the block sprite to visible update | p50 21.9 ms, max 29.2 ms over 12 clicks (includes about 9.4 ms of `ctl` round trip) |
| M0 spike, same measurement | 16-29 ms over 8 clicks |
| Host half load | 3.2-16 ms (selected and default pack validated) |
| Window half load | 2-3 timer slices of 15-17 ms each; overlay setup 2.5-12.6 ms |
| Overlay visible after a plugin reload | about 40-60 ms (up to about 800 ms while the app is still starting) |

Why the window half loads in slices: Tern disables a window hook that takes longer than 50 ms.
Compiling every module in one call took 26-45 ms and once exceeded 50 ms, which disabled the
plugin. The entry now registers commands and events first, then loads modules in timer slices of
about 15 ms.

### Idle CPU baseline (zen, 10 minutes, no input)

Percent of one core per 15 s sample, 40 samples per run (method above).

| State | Process | Mean | Median | p95 | Max | Samples over 1% |
|---|---|---|---|---|---|---|
| Block floated, overlay on (stepped aside) | Window | 0.73% | 0.64% | 1.24% | 1.42% | 7 of 40 |
| | Daemon | 0.12% | 0.12% | 0.17% | 0.22% | 0 |
| Block closed, overlay on (drawn) | Window | 0.77% | 0.68% | 1.39% | 1.48% | 7 of 40 |
| | Daemon | 0.12% | 0.12% | 0.14% | 0.14% | 0 |

Window plus daemon: mean 0.85% with the block floated, 0.89% with it closed. These are whole
process figures and include Tern's own idle work; no CPU run without the plugin was taken. With
the block closed, the first five samples (75 s) were 1.03-1.48% and the rest 0.52-1.07%; with the
block floated the samples over 1% came in the second half of the run (minutes 6-10), when the cat
presumably changed animation (the animation sequence was not logged).

### Memory

Incremental memory baseline (method above). MiB per repeat, after a 2-minute settle:

| State | Window RSS | Window footprint | Daemon RSS | Daemon footprint |
|---|---|---|---|---|
| (a) Plugin unlinked | 166.6, 152.4, 153.6 | 279, 280, 201 | 23.9, 22.7, 22.3 | 7.5, 7.5, 7.7 |
| (b) Overlay only | 251.1, 181.9, 191.0 | 290, 288, 290 | 39.6, 30.6, 32.7 | 15, 14, 15 |
| (c) Block floated | 257.8, 259.2, 190.3 | 302, 305, 305 | 40.8, 41.1, 32.9 | 15, 16, 15 |

Increment over (a), window plus daemon:

| State | Footprint, median of states | Footprint, per repeat | RSS, median of states | RSS, per repeat |
|---|---|---|---|---|
| (b) Overlay only | +18.5 MiB | +18.5, +14.5, +96.3 | +47.4 MiB | +100.2, +37.4, +47.8 |
| (c) Block floated | +33.5 MiB | +30.5, +33.5, +111.3 | +122.3 MiB | +108.1, +125.2, +47.3 |

Per repeat pairs each state with the unlinked run of the same repeat. The third unlinked window
settled 78 MiB below the other two (201 against 279-280 MiB footprint), which inflates that
repeat's deltas; the plugin-loaded windows were within 3 MiB of each other. RSS is much noisier
(window spread up to 69 MiB within one state) and counts shared and file-backed pages, so the
footprint figures are the better estimate of what the plugin adds. The daemon increment is
stable: about +7 MiB footprint, +8-18 MiB RSS.

Earlier single samples, totals only: daemon with tern-cat loaded about 23-28 MiB RSS; M0 spike
daemon about 20 MiB and window about 100-112 MiB RSS.

### Design numbers from M0

These shaped the design and are not measurements of the shipped plugin:

| Approach | Window CPU |
|---|---|
| Overlay walk with smooth (`linear`) CSS animation | 12.9% at about 80 frames/s |
| Overlay walk quantized with `steps()` at 10 Hz | 2.0% |
| Re-installing the overlay sheet from a Lua timer at 10 Hz | 5.8% |
| Block sprite swapped by a Lua timer at 10 fps plus an APNG | 5.05% window, 1.02% daemon |
| Block APNG only, visible | 2.35% window |
| Block hidden, Lua timer still running | 0.84% window, 0.9% daemon |

Hence the shipped design: one APNG per animation in the block (Tern-clocked, free when hidden),
`steps()` sprite-sheet animation in the overlay, and host timers that back off to 0.5-5 s.

## Soak test

Run on 2026-10-08 with `scripts/soak.sh` (how to run it: [develop-with-omp-tern.md](develop-with-omp-tern.md)),
same machine and Tern version as above.

**Method.** 30 minutes, `chaos` preset (the most activity), two control windows on one sandbox
daemon, the cat block open (floated) in window A. Every 20 s the driver alternated between typing
`true`, `false` or `ls` + Enter in window A's shell and running **Pet the cat** in window B
(45 commands, 44 pets). Every 30 s it took a CPU-time delta (percent of one core) and RSS of each
process: 59 samples. The windows were visible but not focused or controlled for occlusion, as in
the runs above.

| Process | CPU p50 | CPU p95 | CPU max | RSS first / last / max | RSS slope, whole run | RSS slope, second half |
|---|---|---|---|---|---|---|
| Window A (block open) | 1.16% | 1.62% | 1.80% | 152 / 69 / 152 MiB | -1.98 MiB/min | -0.14 MiB/min |
| Window B | 1.10% | 2.06% | 2.12% | 153 / 70 / 153 MiB | -2.04 MiB/min | +0.30 MiB/min |
| Daemon (host half) | 0.22% | 0.29% | 0.32% | 28 / 25 / 28 MiB | -0.07 MiB/min | +0.09 MiB/min |

Both windows' RSS fell from about 150 MiB to 63-70 MiB in the first 12 minutes (macOS reclaiming
start-up memory) and then moved between 63 and 74 MiB with no trend; the second-half slopes are
within that noise (+0.30 MiB/min would be 4.5 MiB over the half, less than the sample spread).

State and logs:

| Check | Result |
|---|---|
| Commands counted once | 45 typed, 45 `cmd-` ids in `seen` (two windows open) |
| Pets counted once | 44 run, `stats.pets` 44 |
| Journal at most 50 | Reached 50 at about 12 minutes and stayed there |
| `seen` at most 256 | 89 at the end (grows one id per command or pet until the cap) |
| Inbox drained | 0 files in every sample and at the end |
| `kv.json` size | 11.5 KiB at the end; growth after minute 12 is the `seen` ring only |
| Logs | No errors, warnings, "took over", budget or disabled-hook messages, and no plugin reloads. Window load: 2 slices, slowest 15.1-16.8 ms |

**Verdict against the PRD targets.** Animated CPU at most 3%: pass (window p95 at most 2.1%,
daemon p95 0.29%, with the block and overlay animating under `chaos`). Idle CPU at most 1%: not
tested by this run (the cat is rarely idle under `chaos`); see the table above. Memory at most
100 MiB incremental and no leaks: pass for growth (no upward RSS trend in any process over 30
minutes, every process below its starting size); the increment over a plugin-free baseline is
measured separately under [Memory](#memory).

### Sound smoke

One pet in a fresh sandbox with `sound.enabled = true` and `sound.volume = 0.01`: `ps` showed the
host running `/usr/bin/afplay -v 0.01 <package>/assets/sounds/default/purr.wav`, and the host
logged `sound: played purr (afplay) status 0` at debug level. The real player path works on macOS.

## Against the PRD targets

| Target | Result | Verdict |
|---|---|---|
| p95 event-to-visible at most 150 ms | Max 29.2 ms over 12 clicks (p95 not computable from 12 samples; every sample is far under the bound) | Pass |
| Idle CPU at most 1% | Zen, 10 min no input: window plus daemon mean 0.85% (block floated) and 0.89% (block closed); window p95 1.24-1.39%, 7 of 40 window samples over 1% in each run. Earlier short runs: daemon 0.11-0.13%, window 0.82-0.87% | Pass on the 10-minute mean, with little margin; individual 15 s samples exceed 1%. Figures include Tern's own idle cost |
| Animated CPU at most 3% | Daemon 0.22% plus window 1.29% with block and overlay animating | Pass |
| Memory at most 100 MiB incremental | Window plus daemon physical footprint over plugin unlinked: median +18.5 MiB (overlay only), +33.5 MiB (block floated); one of three repeats +96-111 MiB because of a low unlinked baseline. RSS deltas: median +47 / +122 MiB, per repeat 37-125 MiB. No RSS growth in any process over a 30-minute soak | Pass on median footprint, no leak seen; RSS is too noisy to confirm, and its block-floated median exceeds the bound |

## Not measured

- Battery and energy impact.
- Behavior when the window is fully occluded or minimized (the window state was not controlled).
- Multi-hour runs (the soak test ran 30 minutes).
- Idle CPU with the plugin unlinked (the idle figures are whole-process totals).
- Pacing (`walk`) CPU on its own; it is included in the `chaos` figure.
- Linux, Intel Macs, other Tern versions, high-refresh or multi-monitor setups.
- Many windows at once (only two windows were run together, for correctness, not timing).
