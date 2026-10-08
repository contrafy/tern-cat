#!/usr/bin/env bash
# Headless block goldens: runs every tests/visual/*.txt scenario with `tern shot` against an
# isolated sandbox (remote loopback loads the host half) and writes PNGs to $SB/shots.
# Usage: bash scripts/visual.sh [scenario-name-filter]
set -euo pipefail
cd "$(dirname "$0")/.."
export SB="${SB:-/tmp/tern-cat-dev/visual}"
# shellcheck source=scripts/sandbox-env.sh
source scripts/sandbox-env.sh
tern plugin link . >/dev/null
OUT="$SB/shots"
mkdir -p "$OUT"
status=0
for scenario in tests/visual/*.txt; do
  name="$(basename "$scenario" .txt)"
  if [ -n "${1:-}" ] && [[ "$name" != *"$1"* ]]; then continue; fi
  for theme in light dark; do
    # Each run starts from a fresh cat so stats and needs are deterministic.
    rm -rf "$TERN_CONFIG_DIR/plugin-data/tern-cat"
    echo "==> $name ($theme)"
    if ! TERN_CAT_TEST="frozen,seed=7" tern shot "$scenario" --out "$OUT" --theme "$theme"; then
      echo "visual: $name ($theme) FAILED" >&2
      status=1
    fi
  done
done
echo "shots in $OUT"
exit "$status"
