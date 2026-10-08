# Source this file: isolates Tern CLI/daemon state under $SB (default $PWD/.sandbox).
# shellcheck shell=bash
SB="${SB:-$PWD/.sandbox}"
mkdir -p "$SB/config" "$SB/logs" || return 1
SB="$(cd "$SB" && pwd -P)"
export SB
export TERN_CONFIG_DIR="$SB/config"
export TERN_DAEMON_SOCKET="$SB/daemon.sock"
export STENCIL_LOG_DIR="$SB/logs"
export STENCIL_LOG="warn,stencil=info,tern::plugin=debug"
unset TERN_PANE TERN_PANE_SOCKET TERN_WINDOW_KEY TERN_WINDOW_SOCKET TERN_BLOB_DIR TERN_COMPLETE TERN_LENSES TERN_IDENTITY
if ! command -v tern >/dev/null 2>&1; then
  echo "sandbox-env: tern not on PATH" >&2
  return 1
fi
__tern_plugin_dir="$(tern plugin dir 2>/dev/null)"
case "$__tern_plugin_dir" in
  "$SB"/*) echo "sandbox-env: plugin dir $__tern_plugin_dir" ;;
  *)
    echo "sandbox-env: refusing, plugin dir '$__tern_plugin_dir' is not under $SB" >&2
    unset __tern_plugin_dir
    return 1
    ;;
esac
unset __tern_plugin_dir
