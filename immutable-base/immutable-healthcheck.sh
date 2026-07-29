#!/bin/bash
set -euo pipefail

# Boot healthcheck: resets the boot counter after a successful boot.
# Runs after multi-user.target. Does NOT use the daemon.

POOL="${IMMUTABLE_POOL:-/pool}"
DATA="$POOL/@data"

if ! mountpoint -q "$POOL" 2>/dev/null; then
    dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    [ -z "$dev" ] && exit 0
    fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
    [ "$fstype" != "btrfs" ] && exit 0
    mkdir -p "$POOL"
    mount -o subvolid=5 "$dev" "$POOL" 2>/dev/null || exit 0
fi

mkdir -p "$DATA" 2>/dev/null || exit 0

# Reset counter — this boot reached multi-user.target successfully
echo "0" > "$DATA/boot-counter" 2>/dev/null || true

echo "Boot marked as healthy."
