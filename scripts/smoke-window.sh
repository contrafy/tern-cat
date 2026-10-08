#!/usr/bin/env bash
# Real-window smoke test for the tern-cat window half, fully sandboxed (own config dir, daemon
# and logs under $SB). Opens two control windows on the desktop, checks the overlay sheet, intents,
# the hide toggle and chord, Carly exports/context and single counting across windows, takes a
# screenshot, then quits the windows and stops the sandbox daemon.
#
#   SB=/tmp/tern-cat-dev/<name> bash scripts/smoke-window.sh
#
# Exits non-zero when any assertion fails.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
export SB="${SB:-/tmp/tern-cat-dev/smoke-window}"
# shellcheck source=scripts/sandbox-env.sh
source scripts/sandbox-env.sh || exit 2
command -v python3 >/dev/null || { echo "smoke-window: python3 required" >&2; exit 2; }
for f in plugin.toml host.luau window.luau; do
  [ -f "$f" ] || { echo "smoke-window: $f missing" >&2; exit 2; }
done

DATA="$SB/config/plugin-data/tern-cat"
KV="$DATA/kv.json"
SHOTS="$SB/shots"
WA="$SB/winA.sock"
WB="$SB/winB.sock"
SHEET="plugin:local:tern-cat:overlay"
MARK="tcsmoke$RANDOM$RANDOM"
mkdir -p "$SB/work" "$SHOTS"
rm -f "$WA" "$WB"

PASS=0
FAIL=0
RESULTS=()
ok() { PASS=$((PASS + 1)); RESULTS+=("PASS  $1"); echo "PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); RESULTS+=("FAIL  $1${2:+: $2}"); echo "FAIL  $1${2:+: $2}"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

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

# Values read from kv.json (written only by the host half).
kv() {
  python3 - "$KV" "$1" <<'PY'
import json, sys
path, what = sys.argv[1], sys.argv[2]
try:
    state = json.load(open(path)).get("state") or {}
except Exception:
    print(-1); sys.exit()
if what == "pets":
    print(((state.get("profile") or {}).get("stats") or {}).get("pets", -1))
elif what == "cmds":
    print(sum(1 for s in state.get("seen") or [] if isinstance(s, str) and s.startswith("cmd-")))
elif what == "rev":
    print(state.get("rev", -1))
PY
}

# Rule count of the overlay sheet in window $1 (-1 when absent).
rules() {
  ctl "$1" css | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(-1); sys.exit()
print(next((s["rules"] for s in d.get("sheets", []) if s["name"] == sys.argv[1]), -1))' "$SHEET"
}

inbox_count() { find "$DATA/inbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

# wait_for SECONDS CMD...: polls every 100 ms until CMD succeeds.
wait_for() {
  local secs="$1"; shift
  local end=$(( $(date +%s) * 10 + secs * 10 ))
  while [ $(( $(date +%s) * 10 )) -le "$end" ]; do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

open_window() {
  local ep="$1"
  (cd "$SB" && nohup tern --control "$ep" "$SB/work" >>"$SB/logs/$(basename "$ep").out" 2>&1 &)
  wait_for 30 test -S "$ep" || return 1
  ctl "$ep" ready >/dev/null
}

# ctl joins its arguments into one scenario line: multi-word values need their own quotes.
carly_last() { ctl "$WA" carly last "\"$1\"" >/dev/null; }

plugin_context_line() {
  ctl "$WA" state | python3 -c '
import json, sys
text = ((json.load(sys.stdin).get("carly") or {}).get("last_tool") or {}).get("text") or ""
print(next((l for l in text.splitlines() if l.startswith("- Tern Cat:")), ""))'
}

# Link a snapshot: edits in the working tree during the run would otherwise reload the plugin.
PKG="$SB/pkg"
rm -rf "$PKG" && mkdir -p "$PKG"
cp -R plugin.toml host.luau window.luau ./*.css cat assets config "$PKG"/ || { echo "smoke-window: copy failed" >&2; exit 1; }
echo "==> link snapshot of $REPO"
tern plugin link "$PKG" >/dev/null || { echo "smoke-window: link failed" >&2; exit 1; }
# Start from fresh sessions (the sandbox daemon otherwise restores earlier runs' tabs).
rm -f "$SB/daemon.sock.state"

echo "==> window A"
open_window "$WA" || { bad "window A starts"; exit 1; }
ok "window A starts"

has_state() { [ "$(kv rev)" -ge 0 ]; }
check "host wrote kv state" wait_for 15 has_state

sheet_visible() { [ "$(rules "$WA")" -gt 0 ]; }
sheet_hidden() { [ "$(rules "$WA")" -eq 0 ]; }
check "overlay sheet installed" wait_for 5 sheet_visible

LOAD="$(grep -ho 'tern-cat window ready in [^)]*)' "$SB"/logs/*.log 2>/dev/null | tail -1)"

echo "==> pet intent"
PETS0="$(kv pets)"
ctl "$WA" plugins run plugin.tern-cat.pet >/dev/null
pets_plus_one() { [ "$(kv pets)" -eq $((PETS0 + 1)) ] && [ "$(inbox_count)" -eq 0 ]; }
check "pet: stats.pets +1 and inbox drained within 2 s" wait_for 2 pets_plus_one
sleep 1.5
check "pet applied exactly once" test "$(kv pets)" -eq $((PETS0 + 1))

echo "==> hide toggle"
ctl "$WA" plugins run plugin.tern-cat.toggle-overlay >/dev/null
check "toggle-overlay hides the overlay" wait_for 2 sheet_hidden
ctl "$WA" plugins run plugin.tern-cat.toggle-overlay >/dev/null
check "toggle-overlay shows it again" wait_for 2 sheet_visible
ctl "$WA" key ctrl+alt+cmd+c >/dev/null
check "ctrl+alt+cmd+c hides the overlay" wait_for 2 sheet_hidden
ctl "$WA" key ctrl+alt+cmd+c >/dev/null
check "ctrl+alt+cmd+c shows it again" wait_for 2 sheet_visible

echo "==> Carly exports (no model)"
ctl "$WA" carly lua "return await(plugins['tern-cat'].status())" >/dev/null
check "carly status() answers with mood" carly_last "mood"
ctl "$WA" carly lua "return await(plugins['tern-cat'].feed('rm -rf /'))" >/dev/null
check "carly feed() rejects a bad item" carly_last "ok = false"
ctl "$WA" carly lua "return await(plugins['tern-cat'].ai_status())" >/dev/null
check "carly ai_status() reports AI off" carly_last "enabled = false"

echo "==> second window, one command in window A"
open_window "$WB" || bad "window B starts"
check "window B has its own overlay sheet" wait_for 5 test "$(rules "$WB")" -gt 0
sleep 1
CMDS0="$(kv cmds)"
ctl "$WA" carly close >/dev/null
ctl "$WA" type "\"true $MARK\"" >/dev/null
ctl "$WA" key Enter >/dev/null
cmd_plus_one() { [ "$(kv cmds)" -ge $((CMDS0 + 1)) ]; }
check "host counted the command" wait_for 5 cmd_plus_one
sleep 2
check "command counted exactly once with two windows" test "$(kv cmds)" -eq $((CMDS0 + 1))

echo "==> Carly context"
ctl "$WA" carly context >/dev/null
LINE="$(plugin_context_line)"
echo "      context: $LINE"
case "$LINE" in *"Tern Cat \""*) ok "context has the cat summary" ;; *) bad "context has the cat summary" "$LINE" ;; esac
case "$LINE" in *"$MARK"* | *"true "*) bad "context has no command text" "$LINE" ;; *) ok "context has no command text" ;; esac
check "context within 160 chars" test "$(printf '%s' "${LINE#- Tern Cat: }" | sed 's/; exports: .*//' | wc -c | tr -d ' ')" -le 160

echo "==> screenshot"
sheet_visible || ctl "$WA" plugins run plugin.tern-cat.toggle-overlay >/dev/null
SHOT_JSON="$(ctl "$WA" shot overlay)"
SHOT_REL="$(printf '%s' "$SHOT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("png",""))' 2>/dev/null)"
if [ -n "$SHOT_REL" ] && [ -f "$SB/$SHOT_REL" ]; then
  cp "$SB/$SHOT_REL" "$SHOTS/overlay.png"
  ok "screenshot saved to $SHOTS/overlay.png"
else
  bad "screenshot" "$SHOT_JSON"
fi

echo
echo "smoke-window summary ($PASS passed, $FAIL failed)"
echo "  load: ${LOAD:-n/a}"
printf '  %s\n' "${RESULTS[@]}"
[ "$FAIL" -eq 0 ]
