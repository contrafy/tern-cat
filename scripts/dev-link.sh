#!/usr/bin/env bash
# Links this checkout into the sandboxed Tern plugins directory.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=sandbox-env.sh
source scripts/sandbox-env.sh
tern plugin link .
