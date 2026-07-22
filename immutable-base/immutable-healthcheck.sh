#!/bin/bash
set -euo pipefail

# Boot healthcheck: marks boot as successful.
# Runs after multi-user.target. Does NOT use the daemon.

POOL="${IMMUTABLE_POOL:-/pool}"
DATA_SUBVOL="@data"
DATA="$POOL/$DATA_SUBVOL"

mkdir -p "$DATA" 2>/dev/null || exit 0
echo "1" > "$DATA/boot-ok" 2>/dev/null || true
echo "0" > "$DATA/boot-counter" 2>/dev/null || true

echo "Boot marked as healthy."
