#!/usr/bin/env bash
# Builds a re-signed copy of Tern.app with its own bundle id, so a window manager can tell sandbox
# test windows from your real Tern (docs/develop-with-omp-tern.md, "Keeping test windows off your
# workspaces"). macOS only. Idempotent: rebuilds only when the source Tern's version changes.
#
#   bash scripts/sandbox-app.sh        # prints the app path
#
# TERN_CAT_SANDBOX_APP   the copy (default /tmp/tern-cat-dev/TernSandbox.app)
# TERN_CAT_TERN_APP      the source (default: the Tern.app around `tern` on PATH, else
#                        /Applications/Tern.app)
#
# The copy is an APFS clone (`cp -c`, no extra disk space): CFBundleIdentifier
# so.stencil.tern.sandbox (helper: so.stencil.tern.sandbox.daemon), name "Tern Sandbox", no URL
# scheme, document types, Services entry or launch agents (so it never claims tern:// links or
# registers login items), ad-hoc signed, quarantine cleared.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo "sandbox-app: macOS only" >&2; exit 2; }
APP="${TERN_CAT_SANDBOX_APP:-/tmp/tern-cat-dev/TernSandbox.app}"
BUNDLE_ID="so.stencil.tern.sandbox"
NAME="Tern Sandbox"

SRC="${TERN_CAT_TERN_APP:-}"
if [ -z "$SRC" ]; then
  bin="$(command -v tern 2>/dev/null || true)"
  [ -n "$bin" ] && bin="$(realpath "$bin" 2>/dev/null || true)"
  case "$bin" in
    *.app/Contents/MacOS/*) SRC="${bin%/Contents/MacOS/*}" ;;
    *) SRC=/Applications/Tern.app ;;
  esac
fi
if [ ! -x "$SRC/Contents/MacOS/tern" ]; then
  echo "sandbox-app: no Tern at $SRC (set TERN_CAT_TERN_APP)" >&2
  exit 2
fi

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
SOURCE="$SRC $(plist "$SRC" CFBundleShortVersionString) ($(plist "$SRC" CFBundleVersion))"
MARKER="Contents/Resources/tern-cat-sandbox-source"

if [ "$(cat "$APP/$MARKER" 2>/dev/null)" = "$SOURCE" ] &&
  codesign --verify --deep --strict "$APP" 2>/dev/null; then
  echo "$APP"
  exit 0
fi
if pgrep -f "$APP/Contents/" >/dev/null; then
  echo "sandbox-app: $APP is out of date but running; quit its windows first" >&2
  exit 1
fi

echo "sandbox-app: building $APP from $SOURCE" >&2
mkdir -p "$(dirname "$APP")"
TMP="$APP.tmp.$$"
trap 'rm -rf "$TMP"' EXIT
rm -rf "$TMP"
cp -cR "$SRC" "$TMP" 2>/dev/null || { rm -rf "$TMP"; cp -R "$SRC" "$TMP"; }
xattr -cr "$TMP"

HELPER="$TMP/Contents/Helpers/Tern Daemon.app"
edit() { /usr/libexec/PlistBuddy -c "$2" "$1/Contents/Info.plist" >/dev/null 2>&1 || true; }
edit "$TMP" "Set :CFBundleIdentifier $BUNDLE_ID"
edit "$TMP" "Set :CFBundleName $NAME"
edit "$TMP" "Set :CFBundleDisplayName $NAME"
for key in CFBundleURLTypes CFBundleDocumentTypes NSServices; do edit "$TMP" "Delete :$key"; done
if [ -d "$HELPER" ]; then
  edit "$HELPER" "Set :CFBundleIdentifier $BUNDLE_ID.daemon"
  edit "$HELPER" "Set :CFBundleName $NAME Daemon"
  edit "$HELPER" "Set :CFBundleDisplayName $NAME Daemon"
fi
rm -rf "$TMP/Contents/Library/LaunchAgents"
rmdir "$TMP/Contents/Library" 2>/dev/null || true
printf '%s\n' "$SOURCE" >"$TMP/$MARKER"

# Drop every original signature (the main executable, nested apps, frameworks, dylibs), then sign
# the whole bundle ad hoc; --deep signs nested code inside out. Without the hardened runtime the
# original entitlements (JIT, camera, ...) are not needed, so none are carried over.
while IFS= read -r -d '' f; do
  codesign --remove-signature "$f" 2>/dev/null || true
done < <(find "$TMP" \( -name '*.app' -o -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \
  -o -name '*.xpc' -o -path '*/MacOS/*' \) -print0)
find "$TMP" -name _CodeSignature -type d -prune -exec rm -rf {} +
rm -f "$TMP/Contents/CodeResources"
codesign --force --deep --sign - "$TMP" >/dev/null
codesign --verify --deep --strict "$TMP"
"$TMP/Contents/MacOS/tern" --version >/dev/null

rm -rf "$APP"
mv "$TMP" "$APP"
trap - EXIT
echo "$APP"
