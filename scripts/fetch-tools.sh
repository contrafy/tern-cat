#!/usr/bin/env bash
# Downloads pinned lune, stylua, selene release binaries into .tools/bin (used by CI).
set -euo pipefail
cd "$(dirname "$0")/.."
LUNE_VERSION="0.10.5"
STYLUA_VERSION="2.5.2"
SELENE_VERSION="0.32.0"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) LUNE_OS="macos-aarch64"; STYLUA_OS="macos-aarch64"; SELENE_OS="macos" ;;
  Linux-x86_64) LUNE_OS="linux-x86_64"; STYLUA_OS="linux-x86_64"; SELENE_OS="linux" ;;
  *) echo "fetch-tools: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac
BIN=".tools/bin"
mkdir -p "$BIN"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
get() {
  local name="$1" url="$2"
  curl -fsSL "$url" -o "$TMP/$name.zip"
  unzip -q -o "$TMP/$name.zip" -d "$TMP/$name"
  install -m 0755 "$TMP/$name/$name" "$BIN/$name"
  echo "fetch-tools: $name <- $url"
}
get lune "https://github.com/lune-org/lune/releases/download/v${LUNE_VERSION}/lune-${LUNE_VERSION}-${LUNE_OS}.zip"
get stylua "https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-${STYLUA_OS}.zip"
get selene "https://github.com/Kampfkarren/selene/releases/download/${SELENE_VERSION}/selene-${SELENE_VERSION}-${SELENE_OS}.zip"
