"""Soak driver for scripts/soak.sh: drives two sandbox windows, samples resources, then reports.

Run through scripts/soak.sh (it sets up the sandbox, links a snapshot and opens the windows):

    uv run --with psutil python tools/soak.py --sb $SB --duration 1800

Every --action-every seconds it alternates: type `true`, `false` or `ls` + Enter in window A's
shell pane, then `plugins run plugin.tern-cat.pet` in window B. Every --sample-every seconds it
records CPU% (CPU-time delta over the interval, percent of one core) and RSS of window A, window B
and the daemon, plus kv.json size, journal/seen lengths and the inbox file count. Samples go to
$SB/soak/samples.csv; the summary (slopes, percentiles, counting and log checks) to stdout and
$SB/soak/summary.json. Exits 1 when a check fails.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
import time
from pathlib import Path

import psutil

COMMANDS = ["true", "false", "ls"]
# Log patterns worth a look after a run (Tern's budget/takeover/disable messages and our warnings).
LOG_PATTERNS = {
    "error": re.compile(r"\bERROR\b|\berror\b"),
    "warn": re.compile(r"\bWARN\b"),
    "took_over": re.compile(r"took over", re.I),
    "budget": re.compile(r"budget|exceeded|too long|slow tick", re.I),
    "disabled": re.compile(r"disabl", re.I),
    "reload": re.compile(r"reload", re.I),
}


def find_proc(pattern: str) -> psutil.Process | None:
    for p in psutil.process_iter(["cmdline"]):
        try:
            if pattern in " ".join(p.info["cmdline"] or []):
                return p
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return None


def ctl(sock: Path, *args: str) -> None:
    subprocess.run(["tern", "ctl", "--control", str(sock), *args], capture_output=True, timeout=20)


def kv_state(kv: Path) -> dict:
    try:
        return json.loads(kv.read_text()).get("state") or {}
    except Exception:
        return {}


def counts(kv: Path) -> dict:
    s = kv_state(kv)
    seen = [x for x in s.get("seen") or [] if isinstance(x, str)]
    stats = ((s.get("profile") or {}).get("stats")) or {}
    return {
        "journal": len(s.get("journal") or []),
        "seen": len(seen),
        "seen_cmd": sum(1 for x in seen if x.startswith("cmd-")),
        "pets": stats.get("pets", -1),
        "rev": s.get("rev", -1),
    }


def pct(values: list[float], q: float) -> float:
    if not values:
        return float("nan")
    v = sorted(values)
    i = min(len(v) - 1, max(0, round(q * (len(v) - 1))))
    return v[i]


def slope(xs: list[float], ys: list[float]) -> float:
    n = len(xs)
    if n < 2:
        return float("nan")
    mx, my = sum(xs) / n, sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else float("nan")


def scan_logs(logs: Path, since: float) -> dict:
    hits: dict[str, list[str]] = {k: [] for k in LOG_PATTERNS}
    for f in sorted(logs.glob("*")):
        if not f.is_file() or f.stat().st_mtime < since:
            continue
        for line in f.read_text(errors="replace").splitlines():
            for key, rx in LOG_PATTERNS.items():
                if rx.search(line):
                    hits[key].append(f"{f.name}: {line.strip()[:240]}")
    return hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sb", type=Path, required=True)
    ap.add_argument("--duration", type=int, default=1800)
    ap.add_argument("--action-every", type=float, default=20)
    ap.add_argument("--sample-every", type=float, default=30)
    a = ap.parse_args()

    sb = a.sb
    data = sb / "config" / "plugin-data" / "tern-cat"
    kv = data / "kv.json"
    inbox = data / "inbox"
    wa, wb = sb / "winA.sock", sb / "winB.sock"
    out = sb / "soak"
    out.mkdir(parents=True, exist_ok=True)

    procs = {
        "winA": find_proc(f"--control {wa}"),
        "winB": find_proc(f"--control {wb}"),
        "daemon": find_proc(f"daemon --socket {sb}/daemon.sock"),
    }
    missing = [k for k, p in procs.items() if p is None]
    if missing:
        print(f"soak: processes not found: {missing}", file=sys.stderr)
        return 2

    start = time.time()
    c0 = counts(kv)
    last_cpu = {k: sum(p.cpu_times()[:2]) for k, p in procs.items()}
    last_t = time.monotonic()
    rows: list[dict] = []
    typed: list[str] = []
    pets = 0
    step = 0
    next_action = time.monotonic() + a.action_every
    next_sample = time.monotonic() + a.sample_every
    end = time.monotonic() + a.duration
    with open(out / "samples.csv", "w", newline="") as fh:
        w = None
        while time.monotonic() < end:
            now = time.monotonic()
            if now >= next_action:
                if step % 2 == 0:
                    cmd = COMMANDS[(step // 2) % len(COMMANDS)]
                    ctl(wa, "type", cmd)
                    ctl(wa, "key", "Enter")
                    typed.append(cmd)
                else:
                    ctl(wb, "plugins", "run", "plugin.tern-cat.pet")
                    pets += 1
                step += 1
                next_action += a.action_every
            if now >= next_sample:
                dt = now - last_t
                row: dict = {"t": round(time.time() - start, 1)}
                for k, p in procs.items():
                    try:
                        cpu = sum(p.cpu_times()[:2])
                        row[f"{k}_cpu"] = round(100 * (cpu - last_cpu[k]) / dt, 3)
                        row[f"{k}_rss_mib"] = round(p.memory_info().rss / 2**20, 2)
                        last_cpu[k] = cpu
                    except psutil.NoSuchProcess:
                        print(f"soak: {k} exited", file=sys.stderr)
                        return 1
                last_t = now
                c = counts(kv)
                row["kv_bytes"] = kv.stat().st_size if kv.exists() else -1
                row["journal"] = c["journal"]
                row["seen"] = c["seen"]
                row["inbox"] = len(list(inbox.glob("*.json"))) if inbox.exists() else 0
                rows.append(row)
                if w is None:
                    w = csv.DictWriter(fh, fieldnames=list(row))
                    w.writeheader()
                w.writerow(row)
                fh.flush()
                print(json.dumps(row), flush=True)
                next_sample += a.sample_every
            time.sleep(max(0.05, min(next_action, next_sample, end) - time.monotonic()))

    time.sleep(5)  # let the last command and pet land
    c1 = counts(kv)
    inbox_left = len(list(inbox.glob("*.json"))) if inbox.exists() else 0
    summary: dict = {"duration_s": a.duration, "samples": len(rows), "typed": len(typed), "pets_run": pets}
    for k in procs:
        t = [r["t"] / 60 for r in rows]
        cpu = [r[f"{k}_cpu"] for r in rows]
        rss = [r[f"{k}_rss_mib"] for r in rows]
        summary[k] = {
            "cpu_p50": pct(cpu, 0.5),
            "cpu_p95": pct(cpu, 0.95),
            "cpu_max": max(cpu, default=float("nan")),
            "rss_first_mib": rss[0] if rss else None,
            "rss_last_mib": rss[-1] if rss else None,
            "rss_max_mib": max(rss, default=float("nan")),
            "rss_slope_mib_per_min": slope(t, rss),
            # Second half only: excludes warm-up growth.
            "rss_slope_2nd_half_mib_per_min": slope(t[len(t) // 2 :], rss[len(rss) // 2 :]),
        }
    summary["kv"] = {"before": c0, "after": c1, "max_bytes": max((r["kv_bytes"] for r in rows), default=-1)}
    summary["log_hits"] = {k: v[:20] for k, v in scan_logs(sb / "logs", start).items()}
    summary["log_hit_counts"] = {k: len(v) for k, v in scan_logs(sb / "logs", start).items()}
    checks = {
        "commands counted once": c1["seen_cmd"] - c0["seen_cmd"] == len(typed),
        "pets counted once": c1["pets"] - c0["pets"] == pets,
        "journal <= 50": max([r["journal"] for r in rows] + [c1["journal"]]) <= 50,
        "seen <= 256": max([r["seen"] for r in rows] + [c1["seen"]]) <= 256,
        "inbox drained": inbox_left == 0,
    }
    summary["checks"] = checks
    (out / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
