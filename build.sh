#!/usr/bin/env bash
# Nautilus build script (Linux/macOS). Requires Odin compiler on PATH or ODIN env var.
set -euo pipefail
ODIN_CMD="${ODIN:-odin}"
exec "$ODIN_CMD" build src -out:nautilus "$@"
