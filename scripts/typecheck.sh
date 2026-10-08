#!/usr/bin/env bash
# Type-checks plugin sources (host.luau, window.luau, cat/**) with luau-lsp against types/tern.d.luau.
# Exit 0 ok, 1 type errors, 2 missing prerequisites.
set -euo pipefail
cd "$(dirname "$0")/.."
LSP=".tools/luau-lsp"
[ -x "$LSP" ] || LSP="$(command -v luau-lsp || true)"
if [ -z "$LSP" ]; then echo "typecheck: luau-lsp missing (run scripts/fetch-luau-lsp.sh)" >&2; exit 2; fi
if [ ! -f types/tern.d.luau ]; then echo "typecheck: types/tern.d.luau missing (run scripts/fetch-types.sh)" >&2; exit 2; fi
mkdir -p .tools
# luau-lsp definition files do not know the `userdata` type the Tern SDK uses.
{ echo "type userdata = any"; cat types/tern.d.luau; } > .tools/tern.d.luau
FILES=()
for f in host.luau window.luau; do [ -f "$f" ] && FILES+=("$f"); done
while IFS= read -r f; do FILES+=("$f"); done < <(find cat -name '*.luau' -type f 2>/dev/null | sort)
if [ "${#FILES[@]}" -eq 0 ]; then echo "typecheck: no files"; exit 0; fi
"$LSP" analyze --platform=standard --definitions=@tern=.tools/tern.d.luau "${FILES[@]}"
