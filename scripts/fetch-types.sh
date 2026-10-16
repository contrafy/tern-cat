#!/usr/bin/env bash
# Writes types/tern.d.luau: from the local `tern` CLI if present, else from stencil-hq/tern-sdk (MIT).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p types
# tern-sdk commit whose plugins/tern.d.luau is byte-identical to `tern plugin types` of Tern 0.8.3
# (e2b8656); CI has no tern CLI and type-checks against it. Bump it with the tested Tern version.
SDK_REF="${TERN_SDK_REF:-ccdb4b8266c638ed53736aa813d0a1dd2f81b1ec}"
URL="https://raw.githubusercontent.com/stencil-hq/tern-sdk/${SDK_REF}/plugins/tern.d.luau"
if command -v tern >/dev/null 2>&1 && tern plugin types types/ >/dev/null 2>&1; then
  echo "fetch-types: wrote types/tern.d.luau via 'tern plugin types'"
elif curl -fsSL "$URL" -o types/tern.d.luau.tmp; then
  mv types/tern.d.luau.tmp types/tern.d.luau
  echo "fetch-types: downloaded $URL"
else
  rm -f types/tern.d.luau.tmp
  echo "fetch-types: could not obtain tern.d.luau (no tern CLI, download failed); type analysis will be skipped" >&2
  exit 1
fi
