#!/usr/bin/env bash
# Soak test for tern-cat, fully sandboxed (own config dir, daemon and logs under $SB). Links a
# snapshot of this checkout, writes the `chaos` preset, opens two control windows on one sandbox
# daemon, opens the cat block in window A, then runs tools/soak.py for DURATION seconds: commands
# typed in window A and pets from window B alternate every 20 s, resources are sampled every 30 s.
# Afterwards it quits the windows and stops the sandbox daemon.
#
#   SB=/tmp/tern-cat-dev/soak bash scripts/soak.sh [DURATION_S]   # default 1800
#
# Results: $SB/soak/samples.csv, $SB/soak/summary.json. Exits non-zero when a check fails.
# Needs uv (psutil is pulled in with `uv run --with psutil`).
set -uo pipefail
cd "$(dirname "$0")/.."
DURATION="${1:-1800}"
export SB="${SB:-/tmp/tern-cat-dev/soak}"
# shellcheck source=scripts/sandbox-env.sh
source scripts/sandbox-env.sh || exit 2
command -v uv >/dev/null || { echo "soak: uv required" >&2; exit 2; }

DATA="$SB/config/plugin-data/tern-cat"
WA="$SB/winA.sock"
WB="$SB/winB.sock"
mkdir -p "$SB/work" "$DATA"
rm -f "$WA" "$WB"

ctl() { local ep="$1"; shift; tern ctl --control "$ep" "$@" 2>/dev/null; }

cleanup() {
  for ep in "$WA" "$WB"; do [ -S "$ep" ] && ctl "$ep" quit >/dev/null; done
  sleep 1
  local pids
  pids="$(pgrep -f "tern daemon --socket $SB/daemon.sock" || true)"
  [ -n "$pids" ] && kill $pids 2>/dev/null
  pids="$(pgrep -f "tern --control $SB/win" || true)"
  [ -n "$pids" ] && kill $pids 2>/dev/null
  return 0
}
trap cleanup EXIT

open_window() {
  local ep="$1" i
  (cd "$SB" && nohup tern --control "$ep" "$SB/work" >>"$SB/logs/$(basename "$ep").out" 2>&1 &)
  for i in $(seq 300); do [ -S "$ep" ] && break; sleep 0.1; done
  [ -S "$ep" ] || return 1
  ctl "$ep" ready >/dev/null
}

# Link a snapshot: edits in the working tree during the run would otherwise reload the plugin.
PKG="$SB/pkg"
rm -rf "$PKG" && mkdir -p "$PKG"
cp -R plugin.toml host.luau window.luau ./*.css cat assets config "$PKG"/ || { echo "soak: copy failed" >&2; exit 1; }
tern plugin link "$PKG" >/dev/null || { echo "soak: link failed" >&2; exit 1; }
# Fresh sessions and state; the chaos preset gives the most activity.
rm -f "$SB/daemon.sock.state" "$DATA/kv.json"
rm -rf "$DATA/inbox"
printf '{ "behavior": { "activity": "chaos" } }\n' >"$DATA/config.json"

echo "==> windows"
open_window "$WA" || { echo "soak: window A did not start" >&2; exit 1; }
open_window "$WB" || { echo "soak: window B did not start" >&2; exit 1; }
sleep 3
ctl "$WA" plugins run plugin.tern-cat.open >/dev/null
sleep 2
ctl "$WA" tree | grep -q 'Tern Cat ·' || { echo "soak: cat block did not open in window A" >&2; exit 1; }

echo "==> soak for ${DURATION}s"
uv run --quiet --with psutil python tools/soak.py --sb "$SB" --duration "$DURATION"
