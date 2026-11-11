#!/usr/bin/env bash
# Opens one sandboxed Tern control window and prints its pid once the control socket is up:
#
#   bash scripts/sandbox-window.sh <control-socket> <workdir> [extra tern args]
#
# Runs in the sandbox of scripts/sandbox-env.sh (sourced here unless TERN_DAEMON_SOCKET is set
# already). When the sandbox app of scripts/sandbox-app.sh exists (TERN_CAT_SANDBOX_APP, default
# /tmp/tern-cat-dev/TernSandbox.app), the window comes from that copy, whose own bundle id lets a
# window manager rule keep it off your workspaces, and is launched in the background
# (`open -g -n`) so it does not take the focus. Otherwise it is a plain `tern --control` window.
# Either way the window spawns its daemon at TERN_DAEMON_SOCKET, logs to
# $SB/logs/<socket name>.out, writes `ctl shot` files under $SB/target/shots and runs from $SB.
# With `swift` available it logs where the window landed (tools/window_placement.swift).
set -uo pipefail
usage="usage: sandbox-window.sh <control-socket> <workdir> [extra args]"
[ "$#" -ge 2 ] || { echo "$usage" >&2; exit 2; }
SOCK="$1"
WORKDIR="$2"
shift 2
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ -z "${TERN_DAEMON_SOCKET:-}" ]; then
  # shellcheck source=scripts/sandbox-env.sh
  source "$REPO/scripts/sandbox-env.sh" >&2 || exit 2
fi
: "${SB:?sandbox-window: SB unset}" "${TERN_CONFIG_DIR:?sandbox-window: TERN_CONFIG_DIR unset}"
LOG="$SB/logs/$(basename "$SOCK").out"
mkdir -p "$SB/logs" "$WORKDIR"
rm -f "$SOCK"
APP="${TERN_CAT_SANDBOX_APP:-/tmp/tern-cat-dev/TernSandbox.app}"
log() { echo "sandbox-window: $*" >&2; }

ARGS=(--control "$SOCK" --out "$SB/target/shots" "$WORKDIR" "$@")
direct() { (cd "$SB" || exit; nohup "$1" "${ARGS[@]}" </dev/null >>"$LOG" 2>&1 &); }

if [ "$(uname -s)" = Darwin ] && [ -x "$APP/Contents/MacOS/tern" ]; then
  # Rebuilds the copy after a Tern update (refuses while windows of it are open; the old copy then
  # still works).
  bash "$REPO/scripts/sandbox-app.sh" >/dev/null || log "keeping the existing $APP"
  ENVS=()
  for var in TERN_CONFIG_DIR TERN_DAEMON_SOCKET STENCIL_LOG_DIR STENCIL_LOG TERN_CAT_TEST PATH; do
    [ -n "${!var+x}" ] && ENVS+=(--env "$var=${!var}")
  done
  if [[ "$(open -h 2>&1)" == *--env* ]]; then
    # LaunchServices starts the app with cwd /, hence the absolute --out.
    open -g -n -a "$APP" --stdout "$LOG" --stderr "$LOG" "${ENVS[@]}" --args "${ARGS[@]}" || exit 1
  else
    # Older macOS without `open --env`: started directly, the window may take the focus.
    direct "$APP/Contents/MacOS/tern"
  fi
else
  command -v tern >/dev/null || { log "tern not on PATH"; exit 2; }
  direct tern
fi

for _ in $(seq 300); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { log "no control socket at $SOCK after 30 s (see $LOG)"; exit 1; }
PID="$(pgrep -n -f -- "tern --control $SOCK( |$)")"
[ -n "$PID" ] || { log "no process for $SOCK"; exit 1; }
tern ctl --control "$SOCK" ready >/dev/null 2>&1

# The copy's ad-hoc signature cannot read your Tern account from the keychain, so it opens on the
# closed-beta sign-in card; the harness's stand-in account (no credentials) gets past it.
GATED="$(tern ctl --control "$SOCK" state 2>/dev/null | python3 -c '
import json, sys
a = json.load(sys.stdin).get("account") or {}
print(1 if a.get("applies") and not a.get("signed_in") else "")' 2>/dev/null)"
if [ -n "$GATED" ]; then
  tern ctl --control "$SOCK" account signed-in >/dev/null 2>&1 &&
    log "stand-in account past the sign-in card"
fi

if command -v swift >/dev/null; then
  sleep 1
  while IFS= read -r line; do log "pid $PID $(basename "$SOCK"): $line"; done \
    < <(swift "$REPO/tools/window_placement.swift" "$PID" 2>&1)
fi
echo "$PID"
