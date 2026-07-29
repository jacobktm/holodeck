#!/bin/bash
set -euo pipefail

# Boot counter with tiered auto-rollback.
#
# Runs every boot before multi-user.target. Increments a counter on each
# boot. If the healthcheck (which runs after multi-user.target) resets the
# counter to 0, the boot was successful. If the system fails before
# reaching multi-user.target, the counter persists and increments until
# the threshold is reached, triggering an automatic rollback.
#
# Tier 1: non-init overlay fails THRESHOLD times → revert to @overlay-init
# Tier 2: @overlay-init itself fails THRESHOLD times → switch to @overlay-recovery
# Tier 3: @overlay-recovery is the boot target → stop (last resort)

POOL="${IMMUTABLE_POOL:-/pool}"
DATA="$POOL/@data"
BOOT_ENTRY="/boot/efi/loader/entries/immutable.conf"
THRESHOLD=3

INIT_OVERLAY="@overlay-init"
RECOVERY_OVERLAY="@overlay-recovery"

COUNTER_FILE="$DATA/boot-counter"
LAST_OVERLAY_FILE="$DATA/boot-last-overlay"
ROLLBACK_MESSAGE_FILE="$DATA/rollback-message"

ensure_pool() {
    if ! mountpoint -q "$POOL" 2>/dev/null; then
        local dev fstype
        dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
        [ -z "$dev" ] && return 1
        fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
        [ "$fstype" != "btrfs" ] && return 1
        mkdir -p "$POOL"
        mount -o subvolid=5 "$dev" "$POOL" 2>/dev/null || return 1
    fi
    mkdir -p "$DATA" 2>/dev/null || true
}

esp_remount() {
    local mode="$1"
    mount -o "remount,$mode" /boot/efi 2>/dev/null || true
}

read_boot_overlay() {
    if [ -f "$BOOT_ENTRY" ]; then
        grep -oP 'rootflags=subvol=\K\S+' "$BOOT_ENTRY" 2>/dev/null || true
    fi
}

write_rollback_message() {
    local from="$1" to="$2" count="$3"
    cat > "$ROLLBACK_MESSAGE_FILE" <<EOF
SYSTEM ROLLBACK
===============
The system automatically rolled back after $count consecutive failed boot(s).

  Previous overlay: $from
  New overlay:      $to

This means a software update or configuration change prevented the system
from booting successfully. To re-apply your changes:
  1. immutable create myenv --from "${to#@overlay-}"
  2. immutable shell myenv
  3. Make changes, then:
  4. immutable switch myenv && reboot

Run 'immutable status' to see this message. Delete $ROLLBACK_MESSAGE_FILE
to dismiss it.
EOF
}

ensure_pool || exit 0

# --- Read current overlay ---
CURRENT=$(read_boot_overlay)
if [ -z "$CURRENT" ]; then
    exit 0
fi

# --- Guard: configured overlay must exist, else fall back to init ---
if [ ! -d "$POOL/$CURRENT" ]; then
    echo "Boot counter: '$CURRENT' not found — falling back to $INIT_OVERLAY"
    esp_remount rw
    sed -i "s|rootflags=subvol=[^ ]*|rootflags=subvol=${INIT_OVERLAY}|g" "$BOOT_ENTRY"
    esp_remount ro
    CURRENT="$INIT_OVERLAY"
fi

# --- Last resort: already in recovery, stop counting ---
if [ "$CURRENT" = "$RECOVERY_OVERLAY" ]; then
    exit 0
fi

# --- Detect user-initiated overlay switch ---
LAST=""
[ -f "$LAST_OVERLAY_FILE" ] && LAST=$(cat "$LAST_OVERLAY_FILE" 2>/dev/null || true)

if [ "$CURRENT" != "$LAST" ]; then
    echo "0" > "$COUNTER_FILE" 2>/dev/null || true
    echo "$CURRENT" > "$LAST_OVERLAY_FILE" 2>/dev/null || true
fi

# --- Increment counter (runs every boot, including healthy ones) ---
COUNT=0
[ -f "$COUNTER_FILE" ] && COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE" 2>/dev/null || true

# --- Check threshold ---
if [ "$COUNT" -lt "$THRESHOLD" ]; then
    exit 0
fi

# --- Rollback ---
if [ "$CURRENT" != "$INIT_OVERLAY" ]; then
    TARGET="$INIT_OVERLAY"
    echo "Boot counter: $COUNT failures on '$CURRENT' — rolling back to $TARGET"
else
    TARGET="$RECOVERY_OVERLAY"
    echo "Boot counter: $COUNT failures on init — rolling back to recovery"
fi

esp_remount rw
sed -i "s|rootflags=subvol=[^ ]*|rootflags=subvol=${TARGET}|g" "$BOOT_ENTRY"
esp_remount ro

echo "0" > "$COUNTER_FILE" 2>/dev/null || true
echo "$TARGET" > "$LAST_OVERLAY_FILE" 2>/dev/null || true
write_rollback_message "$CURRENT" "$TARGET" "$COUNT"

echo "Boot counter: rollback complete. Next boot will use $TARGET."
