#!/usr/bin/env bash
# Runs format, lint, typecheck, tests, and pack validation. CI=1 turns missing tools into failures.
set -uo pipefail
cd "$(dirname "$0")/.."
[ -d .tools/bin ] && export PATH="$PWD/.tools/bin:$PATH"
STRICT="${CI:-0}"; [ "$STRICT" = "true" ] && STRICT=1
RESULTS=()
FAILED=0
record() { RESULTS+=("$(printf '%-12s %s' "$1" "$2")"); [ "$2" = FAIL ] && FAILED=1; return 0; }
missing() {
  echo "check: $1 unavailable: $2" >&2
  if [ "$STRICT" = 1 ]; then record "$1" FAIL; else record "$1" "SKIP ($2)"; fi
}
step() {
  local name="$1"; shift
  echo "==> $name"
  if "$@"; then record "$name" ok; else record "$name" FAIL; fi
}
LUAU_PATHS=(cat tests)
for f in host.luau window.luau; do [ -f "$f" ] && LUAU_PATHS+=("$f"); done

if command -v stylua >/dev/null; then step stylua stylua --check "${LUAU_PATHS[@]}"; else missing stylua "stylua not on PATH"; fi
if command -v selene >/dev/null; then step selene selene --display-style=quiet "${LUAU_PATHS[@]}"; else missing selene "selene not on PATH"; fi

echo "==> typecheck"
bash scripts/typecheck.sh
case $? in
  0) record typecheck ok ;;
  2) missing typecheck "luau-lsp or types missing" ;;
  *) record typecheck FAIL ;;
esac

if command -v lune >/dev/null; then step tests lune run tests/run.luau; else missing tests "lune not on PATH"; fi

if [ -f tools/validate_packs.py ]; then
  if command -v uv >/dev/null; then step packs uv run tools/validate_packs.py; else missing packs "uv not on PATH"; fi
else
  record packs "SKIP (tools/validate_packs.py absent)"
fi

echo
echo "check summary:"
printf '  %s\n' "${RESULTS[@]}"
if [ "$FAILED" = 1 ]; then echo "check: FAILED"; exit 1; fi
echo "check: passed"
