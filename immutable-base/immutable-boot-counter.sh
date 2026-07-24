#!/bin/bash
set -euo pipefail

# Tiered boot recovery counter.
#   1. If a non-init overlay fails 3 boots → revert to init
#   2. If init itself fails 3 boots → switch to recovery
#   3. If recovery is already the boot target and fails → do nothing (last resort)
# Runs early in boot before healthcheck.
# Does NOT use the daemon — runs directly as root.

POOL="${IMMUTABLE_POOL:-/pool}"
DATA_SUBVOL="@data"
DATA="$POOL/$DATA_SUBVOL"
BOOT_ENTRY="/boot/efi/loader/entries/immutable.conf"
THRESHOLD=3

INIT_OVERLAY="@overlay-init"
RECOVERY_OVERLAY="@overlay-recovery"

COUNTER_FILE="$DATA/boot-counter"
LAST_OVERLAY_FILE="$DATA/boot-last-overlay"

# Check if pool is mounted
if ! mountpoint -q "$POOL" 2>/dev/null; then
    DEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    [ -z "$DEV" ] && exit 0
    FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
    [ "$FSTYPE" != "btrfs" ] && exit 0
    mkdir -p "$POOL"
    mount -o subvolid=5 "$DEV" "$POOL" 2>/dev/null || exit 0
fi

mkdir -p "$DATA" 2>/dev/null || exit 0

# --- Guard: if the configured overlay doesn't exist, fall back to init ---
if [ -f "$BOOT_ENTRY" ]; then
    CONFIGURED=$(grep -oP 'rootflags=subvol=\K\S+' "$BOOT_ENTRY" 2>/dev/null || true)
    if [ -n "$CONFIGURED" ]; then
        if [ ! -d "$POOL/$CONFIGURED" ]; then
            echo "Configured overlay '$CONFIGURED' not found — falling back to $INIT_OVERLAY"
            sed -i "s|rootflags=subvol=[^ ]*|rootflags=subvol=${INIT_OVERLAY}|g" "$BOOT_ENTRY"
            CONFIGURED="$INIT_OVERLAY"
        fi
    fi
else
    CONFIGURED=""
fi

# --- Healthcheck OK: reset counter ---
OK_MARKER="$DATA/boot-ok"
if [ -f "$OK_MARKER" ]; then
    echo "0" > "$COUNTER_FILE" 2>/dev/null || true
    rm -f "$OK_MARKER" 2>/dev/null || true
    exit 0
fi

# --- If we already switched to recovery and are still failing, stop ---
if [ "$CONFIGURED" = "$RECOVERY_OVERLAY" ]; then
    exit 0
fi

# --- Detect if the overlay changed since last boot (user switched) ---
CURRENT="$CONFIGURED"
LAST=""
[ -f "$LAST_OVERLAY_FILE" ] && LAST=$(cat "$LAST_OVERLAY_FILE" 2>/dev/null || true)

if [ "$CURRENT" != "$LAST" ]; then
    # Overlay changed — reset the counter (fresh attempt)
    echo "0" > "$COUNTER_FILE" 2>/dev/null || true
    echo "$CURRENT" > "$LAST_OVERLAY_FILE" 2>/dev/null || true
fi

# --- Increment counter ---
COUNT=0
[ -f "$COUNTER_FILE" ] && COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE" 2>/dev/null || true

# --- Tiered recovery ---
if [ "$COUNT" -ge "$THRESHOLD" ] && [ -n "$CURRENT" ]; then
    if [ "$CURRENT" != "$INIT_OVERLAY" ]; then
        # Tier 1: non-init overlay is failing → revert to init
        echo "Boot failed $COUNT times on '$CURRENT' — reverting to init..."
        sed -i "s|rootflags=subvol=[^ ]*|rootflags=subvol=${INIT_OVERLAY}|g" "$BOOT_ENTRY"
        echo "0" > "$COUNTER_FILE" 2>/dev/null || true
        echo "$INIT_OVERLAY" > "$LAST_OVERLAY_FILE" 2>/dev/null || true
    else
        # Tier 2: init itself is failing → switch to recovery
        echo "Boot failed $COUNT times on init — switching to recovery..."
        sed -i "s|rootflags=subvol=[^ ]*|rootflags=subvol=${RECOVERY_OVERLAY}|g" "$BOOT_ENTRY"
        echo "0" > "$COUNTER_FILE" 2>/dev/null || true
        echo "$RECOVERY_OVERLAY" > "$LAST_OVERLAY_FILE" 2>/dev/null || true
    fi
fi
