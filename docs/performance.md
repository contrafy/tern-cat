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

Sources: the M0 spikes (RenderSpike: block rendering; OverlaySpike: CSS overlay) and the
integration runs of the host half and the window half.

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

### Memory

| Process | RSS |
|---|---|
| Daemon with tern-cat loaded | about 23-28 MiB (whole process) |
| Daemon in the M0 spike | about 20 MiB (whole process) |
| Window in the M0 spike | about 100-112 MiB (whole process) |

These are totals for Tern's processes, not tern-cat's increment. No baseline without the plugin
was taken in the same run.

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

## Against the PRD targets

| Target | Result | Verdict |
|---|---|---|
| p95 event-to-visible at most 150 ms | Max 29.2 ms over 12 clicks (p95 not computable from 12 samples; every sample is far under the bound) | Pass |
| Idle CPU at most 1% | Daemon 0.11-0.13%; window 0.82-0.87% with the overlay animating, 0.17-0.20% with it hidden | Pass (window close to the bound when the overlay animates) |
| Animated CPU at most 3% | Daemon 0.22% plus window 1.29% with block and overlay animating | Pass |
| Memory at most 100 MiB incremental | Daemon process 23-28 MiB in total; the window increment was not isolated | Unknown for the window; daemon pass |

## Not measured

- Battery and energy impact.
- Behavior when the window is fully occluded or minimized (the window state was not controlled).
- Multi-hour runs and memory growth over time (no leak test).
- Incremental memory of the window process with and without the plugin.
- Pacing (`walk`) CPU on its own; it is included in the `chaos` figure.
- Linux, Intel Macs, other Tern versions, high-refresh or multi-monitor setups.
- Many windows at once (only two windows were run together, for correctness, not timing).
