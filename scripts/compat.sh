#!/usr/bin/env bash
# Tern compatibility check. Run it after every Tern update and before every release:
#
#   bash scripts/compat.sh            # SB defaults to /tmp/tern-cat-dev/compat-<tern version>
#
# Everything runs in sandboxes under $SB (own config dir, daemon and logs; see
# scripts/sandbox-env.sh). Steps:
#   1. record `tern --version`;
#   2. write `tern plugin types` to $SB/compat/types and summarize its diff against the pinned
#      tern-sdk types (scripts/fetch-types.sh SDK_REF; needs network, informational);
#   3. scripts/check.sh, scripts/visual.sh ($SB/visual), scripts/smoke-window.sh ($SB/smoke);
#   4. the DOM-hook probe (tests/compat/dom_probe.py): a real control window with a 2-pane split,
#      asserting every undocumented Tern selector, variable and setting the overlay and the walk
#      rely on, and the behaviors built on them (corners, pass-through, walk, portal, full-screen
#      hide, floated card, settings page, reduced motion).
#
# Opens visible windows on the desktop (smoke and probe). Re-running is safe: each run relinks
# fresh snapshots and resets the probe's plugin data; on exit it quits its windows and stops the
# sandbox daemon. Exits non-zero when any step fails, listing missing Tern hooks.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
command -v tern >/dev/null || { echo "compat: tern not on PATH" >&2; exit 2; }
command -v python3 >/dev/null || { echo "compat: python3 required" >&2; exit 2; }

VERSION_LINE="$(tern --version 2>/dev/null | grep '^tern ' | head -1)"
VERSION="$(printf '%s' "$VERSION_LINE" | awk '{print $2}')"
[ -n "$VERSION" ] || { echo "compat: could not read tern --version" >&2; exit 2; }
export SB="${SB:-/tmp/tern-cat-dev/compat-$VERSION}"
# shellcheck source=scripts/sandbox-env.sh
source scripts/sandbox-env.sh || exit 2
OUT="$SB/compat"
rm -rf "$OUT" && mkdir -p "$OUT/types"
printf '%s\n' "$VERSION_LINE" >"$OUT/version.txt"
echo "==> $VERSION_LINE (sandbox $SB)"

RESULTS=()
FAILED=0
record() { RESULTS+=("$(printf '%-12s %s' "$1" "$2")"); case "$2" in FAIL*) FAILED=1 ;; esac; return 0; }

cleanup() {
  local ep="$SB/probe-win.sock" pids
  [ -S "$ep" ] && tern ctl --control "$ep" quit >/dev/null 2>&1
  pids="$(pgrep -f "tern --control $ep" || true)"
  [ -n "$pids" ] && kill $pids 2>/dev/null
  pids="$(pgrep -f "tern daemon --socket $SB/daemon.sock" || true)"
  [ -n "$pids" ] && kill $pids 2>/dev/null
  return 0
}
trap cleanup EXIT

# 1-2. Types --------------------------------------------------------------------------------
echo "==> types"
SDK_REF="$(sed -n 's/^SDK_REF="\${TERN_SDK_REF:-\(.*\)}"$/\1/p' scripts/fetch-types.sh)"
PINNED_URL="https://raw.githubusercontent.com/stencil-hq/tern-sdk/${SDK_REF}/plugins/tern.d.luau"
if ! tern plugin types "$OUT/types" >/dev/null 2>&1; then
  record types "FAIL (tern plugin types)"
elif ! curl -fsSL "$PINNED_URL" -o "$OUT/types/pinned.d.luau"; then
  record types "SKIP (could not download pinned types $SDK_REF)"
elif cmp -s "$OUT/types/tern.d.luau" "$OUT/types/pinned.d.luau"; then
  echo "types: identical to the pinned tern-sdk ${SDK_REF:0:10}"
  record types "ok (identical to pinned)"
else
  diff -u "$OUT/types/pinned.d.luau" "$OUT/types/tern.d.luau" >"$OUT/types.diff"
  added="$(grep -c '^+[^+]' "$OUT/types.diff")"
  removed="$(grep -c '^-[^-]' "$OUT/types.diff")"
  echo "types: differ from the pinned tern-sdk ${SDK_REF:0:10}: +$added -$removed lines (full diff: $OUT/types.diff)"
  echo "types: changed declarations (- pinned, + this Tern):"
  grep -E '^[+-][[:space:]]*(export type |declare |function |[a-z_]+: \(|[a-z_]+: \{)' "$OUT/types.diff" | head -80 | sed 's/^/  /'
  echo "types: classify the changes in docs/sdk-capability-matrix.md and re-pin scripts/fetch-types.sh"
  record types "DIFFERS (+$added -$removed; see $OUT/types.diff)"
fi

# 3. Checks, goldens, window smoke -----------------------------------------------------------
echo "==> check"
if bash scripts/check.sh >"$OUT/check.log" 2>&1; then record check ok; else record check "FAIL (see $OUT/check.log)"; fi
tail -10 "$OUT/check.log"

echo "==> visual"
if SB="$SB/visual" bash scripts/visual.sh >"$OUT/visual.log" 2>&1; then
  record visual "ok (shots in $SB/visual/shots; compare them by eye)"
else
  record visual "FAIL (see $OUT/visual.log)"
fi

echo "==> smoke-window"
if SB="$SB/smoke" bash scripts/smoke-window.sh >"$OUT/smoke.log" 2>&1; then record smoke ok; else record smoke "FAIL (see $OUT/smoke.log)"; fi
sed -n '/smoke-window summary/,$p' "$OUT/smoke.log"

# 4. DOM-hook probe ---------------------------------------------------------------------------
echo "==> DOM-hook probe"
cleanup
PKG="$SB/pkg"
PROBE_PKG="$SB/probe-plugin"
rm -rf "$PKG" "$PROBE_PKG" "$TERN_CONFIG_DIR/plugin-data/tern-cat" "$TERN_CONFIG_DIR/plugin-data/tern-cat-probe"
mkdir -p "$PKG" "$SB/work"
cp -R plugin.toml host.luau window.luau ./*.css cat assets config "$PKG"/ &&
  cp -R tests/compat/probe "$PROBE_PKG" &&
  tern plugin link "$PKG" >/dev/null &&
  tern plugin link "$PROBE_PKG" >/dev/null || { echo "compat: linking the snapshots failed" >&2; exit 1; }
TERN_BIN="$(python3 -c 'import os, shutil; print(os.path.realpath(shutil.which("tern")))')"
if TERN_BIN="$TERN_BIN" python3 tests/compat/dom_probe.py; then
  record dom-probe "ok ($OUT/dom-probe.txt)"
else
  record dom-probe "FAIL ($OUT/dom-probe.txt)"
fi
tern plugin unlink tern-cat-probe >/dev/null 2>&1

echo
echo "compat summary for $VERSION_LINE ($REPO):"
printf '  %s\n' "${RESULTS[@]}" | tee "$OUT/summary.txt"
if [ "$FAILED" = 1 ]; then echo "compat: FAILED"; exit 1; fi
echo "compat: passed"
