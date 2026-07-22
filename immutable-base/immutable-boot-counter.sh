#!/bin/bash
set -euo pipefail

# Boot counter: increments on each boot. If threshold exceeded, switch to recovery.
# Runs early in boot before healthcheck.
# Does NOT use the daemon — runs directly as root.

POOL="${IMMUTABLE_POOL:-/pool}"
DATA_SUBVOL="@data"
COUNTER_FILE="$POOL/$DATA_SUBVOL/boot-counter"
OK_MARKER="$POOL/$DATA_SUBVOL/boot-ok"
BOOT_ENTRY="/boot/efi/loader/entries/immutable.conf"
THRESHOLD=3

# Check if pool is mounted
if ! mountpoint -q "$POOL" 2>/dev/null; then
    DEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    [ -z "$DEV" ] && exit 0
    FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
    [ "$FSTYPE" != "btrfs" ] && exit 0
    mkdir -p "$POOL"
    mount -o subvolid=5 "$DEV" "$POOL" 2>/dev/null || exit 0
fi

DATA="$POOL/$DATA_SUBVOL"
mkdir -p "$DATA" 2>/dev/null || exit 0

# If healthcheck marked boot as OK on previous boot, reset counter
if [ -f "$OK_MARKER" ]; then
    echo "0" > "$COUNTER_FILE" 2>/dev/null || true
    rm -f "$OK_MARKER" 2>/dev/null || true
    exit 0
fi

# Increment counter
COUNT=0
if [ -f "$COUNTER_FILE" ]; then
    COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
fi
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE" 2>/dev/null || true

# If threshold exceeded, switch to recovery and reboot
if [ "$COUNT" -ge "$THRESHOLD" ]; then
    echo "Boot failed $COUNT times — switching to recovery overlay..."

    # Switch boot entry directly (daemon may not be running yet)
    if [ -f "$BOOT_ENTRY" ]; then
        sed -i 's|rootflags=subvol=[^ ]*|rootflags=subvol=@overlay-recovery|g' "$BOOT_ENTRY"
        echo "Boot entry updated to @overlay-recovery"
    fi

    reboot
fi
