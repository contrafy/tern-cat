# /// script
# requires-python = ">=3.11"
# dependencies = ["psutil==7.1.0"]
# ///
"""Idle CPU and incremental memory baseline for tern-cat (docs/performance.md).

Usage: run through scripts/perf-baseline.sh, which sources the sandbox, links a snapshot of the
package and writes the zen config. Directly (in a sandboxed shell, plugin linked):

  uv run tools/perf_baseline.py [--idle-minutes 10] [--interval 15] [--settle 120]
                                [--repeats 3] [--skip-idle] [--skip-mem] [--out FILE]

Idle: one control window with the overlay on, no input; CPU of the window and daemon processes
(each with its children) sampled every --interval seconds, once with the cat block floated
(`pip float br`) and once without a block. Memory: RSS and USS of both processes after --settle
seconds in three states (plugin unlinked, overlay only, block floated), --repeats times each,
every repeat on a fresh daemon and window. Writes JSON results to --out and prints a summary.

--transition replaces both with an A/B of rendering.pane_transition (--styles, default
off,portal,vent,box; --repeats rounds, interleaved): a fresh window with a two-pane split,
zen without pacing and frozen host timers (TERN_CAT_TEST=frozen,seed=7), --ab-seconds of no
input, then --switches `focus next` every --switch-gap seconds; CPU and `stats` frames each.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

import psutil

SB = Path(os.environ.get("SB", ""))
SHEET = "plugin:local:tern-cat:overlay"


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def ctl(*args: str) -> str:
    out = subprocess.run(
        ["tern", "ctl", "--control", str(SB / "perf.sock"), *args],
        capture_output=True,
        text=True,
        timeout=30,
    )
    return out.stdout


def find(pattern: str) -> psutil.Process | None:
    for p in psutil.process_iter(["cmdline"]):
        if pattern in " ".join(p.info["cmdline"] or []):
            return p
    return None


def daemon() -> psutil.Process | None:
    return find(f"tern daemon --socket {SB}/daemon.sock")


def window() -> psutil.Process | None:
    return find(f"tern --control {SB}/perf.sock")


def family(p: psutil.Process) -> list[psutil.Process]:
    try:
        return [p, *p.children(recursive=True)]
    except psutil.NoSuchProcess:
        return []


def cpu_seconds(p: psutil.Process) -> float:
    total = 0.0
    for q in family(p):
        try:
            t = q.cpu_times()
            total += t.user + t.system
        except psutil.NoSuchProcess:
            pass
    return total


def footprint_mib(pid: int) -> float | None:
    if not shutil.which("footprint"):
        return None
    try:
        out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True, timeout=60).stdout
    except subprocess.TimeoutExpired:
        return None
    m = re.search(r"Footprint:\s*([\d.]+)\s*([KMG])B", out)
    if not m:
        return None
    return float(m.group(1)) * {"K": 1 / 1024, "M": 1.0, "G": 1024.0}[m.group(2)]


def memory(p: psutil.Process) -> dict[str, float | None]:
    rss = 0
    uss: int | None = 0
    for q in family(p):
        try:
            rss += q.memory_info().rss
        except psutil.NoSuchProcess:
            continue
        try:
            uss = None if uss is None else uss + q.memory_full_info().uss
        except psutil.AccessDenied:
            # macOS denies task_for_pid without entitlements; `footprint` still answers.
            uss = None
        except psutil.NoSuchProcess:
            pass
    return {
        "rss_mib": rss / 2**20,
        "uss_mib": None if uss is None else uss / 2**20,
        "footprint_mib": footprint_mib(p.pid),
    }


def stop() -> None:
    if (SB / "perf.sock").exists():
        ctl("quit")
    time.sleep(1.5)
    for p in (window(), daemon()):
        if p:
            try:
                p.terminate()
                p.wait(5)
            except psutil.Error:
                pass
    (SB / "perf.sock").unlink(missing_ok=True)
    # Fresh sessions: the daemon otherwise restores the previous run's tabs and blocks.
    (SB / "daemon.sock.state").unlink(missing_ok=True)


def overlay_rules() -> int:
    try:
        sheets = json.loads(ctl("css")).get("sheets", [])
    except json.JSONDecodeError:
        return -1
    return next((s["rules"] for s in sheets if s["name"] == SHEET), 0)


def wait_until(secs: float, cond) -> bool:
    end = time.time() + secs
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.25)
    return False


def start(plugin: bool, block: bool, env: dict[str, str] | None = None) -> tuple[psutil.Process, psutil.Process]:
    stop()
    (SB / "work").mkdir(exist_ok=True)
    with open(SB / "logs" / "perf-window.out", "ab") as out:
        subprocess.Popen(
            ["tern", "--control", str(SB / "perf.sock"), str(SB / "work")],
            cwd=SB,
            stdout=out,
            stderr=out,
            start_new_session=True,
            env={**os.environ, **(env or {})},
        )
    if not wait_until(30, lambda: (SB / "perf.sock").exists()):
        sys.exit("perf: window did not start")
    ctl("ready")
    if plugin and not wait_until(15, lambda: overlay_rules() > 0):
        sys.exit("perf: overlay sheet not installed")
    if block:
        ctl("plugins", "run", "plugin.tern-cat.open")
        time.sleep(2)
        if not json.loads(ctl("state")).get("pips"):
            # The plugin's own float did not take (observed on Tern 0.6.2): float the focused
            # cat pane through the control endpoint instead.
            ctl("pip", "float", "br")
            time.sleep(1)
        if not json.loads(ctl("state")).get("pips"):
            sys.exit("perf: cat block is not floated")
    w, d = window(), daemon()
    if not (w and d):
        sys.exit("perf: window or daemon process not found")
    return w, d


def summarize(xs: list[float]) -> dict[str, float]:
    s = sorted(xs)
    return {
        "mean": statistics.fmean(s),
        "median": statistics.median(s),
        "p95": s[min(len(s) - 1, round(0.95 * (len(s) - 1)))],
        "min": s[0],
        "max": s[-1],
        "n": len(s),
    }


def idle(block: bool, minutes: float, interval: float) -> dict:
    w, d = start(plugin=True, block=block)
    log(f"idle, block={'floated' if block else 'closed'}: {minutes} min, every {interval} s")
    samples: dict[str, list[float]] = {"window": [], "daemon": []}
    prev = {"window": cpu_seconds(w), "daemon": cpu_seconds(d)}
    t0 = time.monotonic()
    last = t0
    while last - t0 < minutes * 60 - 1e-6:
        time.sleep(interval)
        now = time.monotonic()
        for name, p in (("window", w), ("daemon", d)):
            cur = cpu_seconds(p)
            samples[name].append(100 * (cur - prev[name]) / (now - last))
            prev[name] = cur
        last = now
    rules = overlay_rules()
    stop()
    return {
        "block": block,
        "overlay_rules_at_end": rules,
        "samples": samples,
        "window": summarize(samples["window"]),
        "daemon": summarize(samples["daemon"]),
    }


def link(on: bool) -> None:
    pkg = str(SB / "pkg")
    args = ["tern", "plugin", "link", pkg] if on else ["tern", "plugin", "unlink", "tern-cat"]
    subprocess.run(args, capture_output=True, check=True)


def mem(settle: float, repeats: int) -> dict:
    states = [("unlinked", False, False), ("overlay", True, False), ("block", True, True)]
    runs: dict[str, list[dict]] = {name: [] for name, _, _ in states}
    for rep in range(repeats):
        for name, plugin, block in states:
            link(plugin)
            w, d = start(plugin=plugin, block=block)
            log(f"memory rep {rep + 1}/{repeats} {name}: settle {settle} s")
            time.sleep(settle)
            runs[name].append({"window": memory(w), "daemon": memory(d)})
            stop()
    return runs


def frames() -> int:
    try:
        return int(json.loads(ctl("stats")).get("frames", -1))
    except (json.JSONDecodeError, ValueError):
        return -1


def measure(w: psutil.Process, d: psutil.Process, secs: float, action=None, every: float = 0) -> dict:
    """CPU (percent of one core) of window and daemon and frames/s over secs, optionally running
    action every `every` seconds (first call at the start)."""
    f0, cw, cd, t0 = frames(), cpu_seconds(w), cpu_seconds(d), time.monotonic()
    n = 0
    while time.monotonic() - t0 < secs:
        if action and time.monotonic() - t0 >= n * every:
            action()
            n += 1
        time.sleep(0.05)
    dt = time.monotonic() - t0
    f1 = frames()
    return {
        "secs": dt,
        "actions": n,
        "window": 100 * (cpu_seconds(w) - cw) / dt,
        "daemon": 100 * (cpu_seconds(d) - cd) / dt,
        "frames": f1 - f0,
        "fps": (f1 - f0) / dt,
    }


def transition_ab(styles: list[str], secs: float, repeats: int, switches: int, gap: float, settle: float) -> list[dict]:
    """Idle A/B of rendering.pane_transition, then per-switch cost, each run on a fresh daemon and
    window with a two-pane split, frozen host timers (TERN_CAT_TEST=frozen,seed=7) and a fresh
    plugin state, so every run shows the same overlay animation."""
    data = Path(os.environ["TERN_CONFIG_DIR"]) / "plugin-data" / "tern-cat"
    runs = []
    for rep in range(repeats):
        for style in styles:
            shutil.rmtree(data, ignore_errors=True)
            data.mkdir(parents=True)
            (data / "config.json").write_text(json.dumps({
                "schema_version": 1,
                "behavior": {"activity": "zen", "allow_visual_obscuring": True, "allow_pacing": False},
                "rendering": {"overlay": True, "block_placement": "float", "pane_transition": style},
            }))
            w, d = start(plugin=True, block=False, env={"TERN_CAT_TEST": "frozen,seed=7"})
            ctl("split", "right")
            ctl("ready")
            time.sleep(settle)
            log(f"transition rep {rep + 1}/{repeats} {style}: idle {secs} s")
            idle_m = measure(w, d, secs)
            log(f"transition rep {rep + 1}/{repeats} {style}: {switches} switches every {gap} s")
            sw = measure(w, d, switches * gap, lambda: ctl("focus", "next"), gap)
            sw["extra_frames_per_switch"] = (sw["frames"] - idle_m["fps"] * sw["secs"]) / max(1, sw["actions"])
            runs.append({"style": style, "rep": rep + 1, "idle": idle_m, "switch": sw})
            stop()
    shutil.rmtree(data, ignore_errors=True)
    return runs


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--idle-minutes", type=float, default=10)
    ap.add_argument("--interval", type=float, default=15)
    ap.add_argument("--settle", type=float, default=120)
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--skip-idle", action="store_true")
    ap.add_argument("--skip-mem", action="store_true")
    ap.add_argument("--transition", action="store_true", help="pane_transition A/B instead of idle/memory")
    ap.add_argument("--styles", default="off,portal,vent,box")
    ap.add_argument("--ab-seconds", type=float, default=60)
    ap.add_argument("--switches", type=int, default=20)
    ap.add_argument("--switch-gap", type=float, default=2)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    if not str(SB) or not os.environ.get("TERN_CONFIG_DIR", "").startswith(str(SB)):
        sys.exit("perf: source scripts/sandbox-env.sh first")
    result: dict = {"cpu_count": psutil.cpu_count()}
    try:
        if a.transition:
            result["transition"] = transition_ab(
                a.styles.split(","), a.ab_seconds, a.repeats, a.switches, a.switch_gap, min(a.settle, 15)
            )
        else:
            if not a.skip_idle:
                result["idle"] = [idle(True, a.idle_minutes, a.interval), idle(False, a.idle_minutes, a.interval)]
            if not a.skip_mem:
                result["memory"] = mem(a.settle, a.repeats)
    finally:
        stop()
        link(True)
    out = Path(a.out or SB / "perf.json")
    out.write_text(json.dumps(result, indent=2))
    log(f"wrote {out}")
    for run in result.get("transition", []):
        i, s = run["idle"], run["switch"]
        print(
            f"transition {run['style']:6} rep {run['rep']} idle window {i['window']:.2f}% daemon {i['daemon']:.2f}% "
            f"{i['fps']:.2f} fps | switch window {s['window']:.2f}% daemon {s['daemon']:.2f}% {s['fps']:.2f} fps "
            f"{s['extra_frames_per_switch']:.1f} extra frames/switch"
        )
    for run in result.get("idle", []):
        label = "block floated" if run["block"] else "block closed"
        for name in ("window", "daemon"):
            s = run[name]
            print(
                f"idle {label:13} {name:6} mean {s['mean']:.2f}% median {s['median']:.2f}% "
                f"p95 {s['p95']:.2f}% max {s['max']:.2f}% (n={s['n']})"
            )
    for name, reps in result.get("memory", {}).items():
        for proc in ("window", "daemon"):
            for key in ("rss_mib", "uss_mib", "footprint_mib"):
                vals = [r[proc][key] for r in reps if r[proc][key] is not None]
                if vals:
                    print(f"mem {name:8} {proc:6} {key:13} " + " ".join(f"{v:.1f}" for v in vals))


if __name__ == "__main__":
    main()
