#!/usr/bin/env bash
# Downloads a pinned luau-lsp release into .tools/.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="1.70.1"
case "$(uname -s)-$(uname -m)" in
  Darwin-*) ASSET="luau-lsp-macos.zip" ;;
  Linux-x86_64) ASSET="luau-lsp-linux-x86_64.zip" ;;
  Linux-aarch64 | Linux-arm64) ASSET="luau-lsp-linux-arm64.zip" ;;
  *) echo "fetch-luau-lsp: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
mkdir -p .tools
if [ -x .tools/luau-lsp ] && [ "$(cat .tools/luau-lsp.version 2>/dev/null)" = "$VERSION" ]; then
  echo "fetch-luau-lsp: $VERSION already present"
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/JohnnyMorganz/luau-lsp/releases/download/${VERSION}/${ASSET}" -o "$TMP/l.zip"
unzip -q -o "$TMP/l.zip" -d "$TMP"
install -m 0755 "$TMP/luau-lsp" .tools/luau-lsp
echo "$VERSION" > .tools/luau-lsp.version
echo "fetch-luau-lsp: installed $VERSION ($ASSET)"
