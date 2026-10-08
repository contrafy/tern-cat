#!/usr/bin/env bash
# Idle CPU and incremental memory baseline (docs/performance.md), fully sandboxed. Opens one
# control window on the desktop at a time, links a snapshot copy of the package, writes the zen
# preset config and runs tools/perf_baseline.py. Takes about 45 minutes with the defaults.
#
#   SB=/tmp/tern-cat-dev/<name> bash scripts/perf-baseline.sh [tools/perf_baseline.py args]
set -uo pipefail
cd "$(dirname "$0")/.."
export SB="${SB:-/tmp/tern-cat-dev/perf}"
# shellcheck source=scripts/sandbox-env.sh
source scripts/sandbox-env.sh || exit 2
REPO="$PWD"

PKG="$SB/pkg"
rm -rf "$PKG" && mkdir -p "$PKG"
cp -R plugin.toml host.luau window.luau ./*.css cat assets config "$PKG"/ || exit 1
tern plugin link "$PKG" >/dev/null || { echo "perf-baseline: link failed" >&2; exit 1; }
# Zen with the overlay drawn: the zen preset sets allow_visual_obscuring = false, which hides the
# overlay entirely, so that one field is overridden.
DATA="$TERN_CONFIG_DIR/plugin-data/tern-cat"
mkdir -p "$DATA"
cat >"$DATA/config.json" <<'JSON'
{
  "schema_version": 1,
  "behavior": { "activity": "zen", "allow_visual_obscuring": true },
  "rendering": { "overlay": true, "block_placement": "float" }
}
JSON

uv run "$REPO/tools/perf_baseline.py" "$@"
