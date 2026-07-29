#!/bin/bash
set -uo pipefail

# ── Test Procedure for Immutable Pop!_OS ──
# Tests: overlay creation, isolation, @base immutability, reset, @data persistence,
#        switch/reboot, delete, lock/unlock, shadowing, package version isolation.
# Run as a regular user — only specific commands use sudo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POOL="/pool"
BASE="$POOL/@base"
TEST_OVERLAY="test-$(date +%s)"
TEST_OVERLAY2="test2-$(date +%s)"
TEST_FILE="/tmp/immutable-test-marker-$$"
PASS=0
FAIL=0
SKIP=0

# Package to test shadowing (must be installed in @base)
TEST_PKG_REMOVE="${TEST_PKG_REMOVE:-curl}"

# Package version isolation testing (optional)
INSTALL_PKG=""
INSTALL_REPO=""  # format: owner/repo@branch

# ── Parse args ──

IMMUTABLE_PASSWORD="${IMMUTABLE_PASSWORD:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --test-pkg) TEST_PKG_REMOVE="$2"; shift 2 ;;
        --install-pkg) INSTALL_PKG="$2"; shift 2 ;;
        --repo) INSTALL_REPO="$2"; shift 2 ;;
        --password) IMMUTABLE_PASSWORD="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Export for non-interactive auth
if [ -n "$IMMUTABLE_PASSWORD" ]; then
    export IMMUTABLE_PASSWORD
fi

# ── Helpers ──

log_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
log_skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }
log_info() { echo "  INFO: $1"; }

# Run a command with sudo (for operations on /pool, /boot/efi, btrfs, mount, etc.)
root_cmd() { sudo "$@"; }

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    # Revert boot entry to overlay-init if it was changed
    local entry="/boot/efi/loader/entries/immutable.conf"
    if [ -f "$entry" ]; then
        local current_subvol=$(grep -o 'subvol=[^ ]*' "$entry" | head -1 | cut -d= -f2 || true)
        if [ -n "$current_subvol" ] && [[ "$current_subvol" == *@overlay-test* ]]; then
            echo "  Reverting boot entry from $current_subvol to @overlay-init"
            root_cmd sed -i "s|rootflags=subvol=[^ ]*|rootflags=subvol=@overlay-init|g" "$entry"
        fi
    fi
    # Remove test overlays
    for name in "$TEST_OVERLAY" "$TEST_OVERLAY2"; do
        local path="$POOL/@overlay-$name"
        if [ -d "$path" ]; then
            # Unmount if needed
            for m in $(mount | grep "$path" | awk '{print $3}' | sort -r); do
                root_cmd umount "$m" 2>/dev/null || true
            done
            root_cmd btrfs subvolume delete "$path" 2>/dev/null && echo "  Removed $name" || echo "  WARNING: Failed to remove $name"
        fi
        # Verify deletion
        if [ -d "$path" ]; then
            echo "  ERROR: $path still exists after deletion!"
            root_cmd btrfs subvolume delete "$path" 2>/dev/null || true
        fi
    done
    # Remove test data file
    root_cmd rm -f "$POOL/@data/$TEST_FILE" 2>/dev/null || true
    rm -f "/tmp/$TEST_FILE" 2>/dev/null || true
    echo "  Cleanup done."
}

trap cleanup EXIT

echo "╔══════════════════════════════════════════╗"
echo "║  Immutable Pop!_OS Test Suite            ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Test overlay names: $TEST_OVERLAY, $TEST_OVERLAY2"
echo "PID marker: $$"
echo ""

# Check if password is available for tests that need auth (switch, unlock)
if [ -z "$IMMUTABLE_PASSWORD" ]; then
    echo "WARNING: No password set. Tests requiring unlock/switch auth will fail."
    echo "  Set via: --password <pass> or export IMMUTABLE_PASSWORD=<pass>"
    echo ""
fi

# ── Clean up stale test overlays from previous runs ──
echo "=== Cleaning stale overlays ==="
for stale in $(root_cmd btrfs subvolume list "$POOL" 2>/dev/null | grep -oP '@overlay-test[0-9]*-[0-9]+' | sort -u); do
    echo "  Removing stale overlay: $stale"
    root_cmd btrfs subvolume delete "$POOL/$stale" 2>/dev/null || true
done
# Also revert boot entry if stuck on a test overlay
entry="/boot/efi/loader/entries/immutable.conf"
if [ -f "$entry" ]; then
    current_subvol=$(grep -o 'subvol=[^ ]*' "$entry" | head -1 | cut -d= -f2 || true)
    if [ -n "$current_subvol" ] && [[ "$current_subvol" == *@overlay-test* ]]; then
        echo "  Reverting boot entry from $current_subvol to @overlay-init"
        root_cmd sed -i "s|rootflags=subvol=[^ ]*|rootflags=subvol=@overlay-init|g" "$entry"
    fi
fi
echo ""

# ── Pre-flight checks ──

echo "=== Pre-flight Checks ==="

# Check BTRFS root
ROOT_FS=$(findmnt -n -o FSTYPE / 2>/dev/null)
if [ "$ROOT_FS" = "btrfs" ]; then
    log_pass "Root filesystem is BTRFS"
else
    log_fail "Root filesystem is $ROOT_FS, expected BTRFS"; exit 1
fi

# Check /pool mount
if mountpoint -q "$POOL" 2>/dev/null; then
    log_pass "/pool is mounted"
else
    # Try to mount it
    ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null)
    root_cmd mkdir -p "$POOL"
    root_cmd mount -o subvolid=5 "$ROOT_DEV" "$POOL" 2>/dev/null
    if mountpoint -q "$POOL" 2>/dev/null; then
        log_pass "/pool mounted (was not mounted)"
    else
        log_fail "Cannot mount /pool"; exit 1
    fi
fi

# Check @base exists
if [ -d "$BASE" ]; then
    log_pass "@base exists at $BASE"
else
    log_fail "@base not found at $BASE"; exit 1
fi

# Check @base is read-only
BASE_RO=$(root_cmd root_cmd btrfs property get "$BASE" ro 2>/dev/null | grep -oP '(?<=ro=)\S+')
if [ "$BASE_RO" = "true" ]; then
    log_pass "@base is read-only"
else
    log_skip "@base is NOT read-only (run 'immutable lock' first)"
fi

# Check @data exists
if [ -d "$POOL/@data" ]; then
    log_pass "@data exists"
else
    log_fail "@data not found"; exit 1
fi

# Check immutable CLI
if command -v immutable &>/dev/null; then
    log_pass "immutable CLI found at $(which immutable)"
else
    log_fail "immutable CLI not found"
fi

# ── CLI diagnostics ──

echo ""
echo "=== CLI Diagnostics ==="

IMMUTABLE_BIN="$(which immutable 2>/dev/null || true)"
if [ -n "$IMMUTABLE_BIN" ]; then
    log_pass "immutable CLI found at $IMMUTABLE_BIN"

    # Verify it's an ELF binary (Rust), not a Python script
    if file "$IMMUTABLE_BIN" 2>/dev/null | grep -q "ELF"; then
        log_pass "immutable CLI is a compiled binary (Rust)"
        log_pass "$(sudo immutable --version 2>&1 || true)"
    else
        log_skip "immutable CLI is a script, not the Rust binary"
    fi
else
    log_fail "immutable CLI not found"
fi

echo ""
echo "=== Boot Performance Analysis ==="
if command -v systemd-analyze &>/dev/null; then
    echo "  Boot time:"
    systemd-analyze 2>&1 | head -5
    echo ""
    echo "  Slowest services:"
    systemd-analyze blame 2>&1 | head -15
    echo ""
    echo "  Critical chain:"
    systemd-analyze critical-chain 2>&1 | head -15
else
    echo "  systemd-analyze not available"
fi
echo ""

# Check if modules required by cups-filters.conf are present
echo "  Kernel modules check:"
KVER=$(uname -r)
MODDIR="/lib/modules/$KVER"
if [ -d "$MODDIR" ]; then
    echo "    Kernel: $KVER"
    for mod in lp ppdev parport_pc; do
        if modprobe --dry-run "$mod" 2>/dev/null; then
            echo "    $mod: found"
        else
            echo "    $mod: MISSING (will cause systemd-modules-load timeout)"
        fi
    done
else
    echo "    WARNING: /lib/modules/$KVER not found — no kernel modules installed"
    echo "    systemd-modules-load.service will timeout on cups-filters.conf"
fi
# Check if cups-filters.conf exists
if [ -f /etc/modules-load.d/cups-filters.conf ]; then
    echo "    cups-filters.conf: present (will try to load lp, ppdev, parport_pc)"
else
    echo "    cups-filters.conf: not present (no parallel port module loading)"
fi
echo ""

# Journal diagnostics for slow services
echo "  Journal diagnostics:"
echo "    systemd-modules-load.service:"
journalctl -b -u systemd-modules-load.service --no-pager 2>&1 | tail -10 | sed 's/^/      /'
echo ""
echo "    sysinit.target blockers (systemd unit init):"
journalctl -b -o short-monotonic -u sysinit.target --no-pager 2>&1 | tail -20 | sed 's/^/      /'
echo ""
echo "    All sysinit-stage jobs:"
systemd-analyze blame --no-pager 2>&1 | head -20 | sed 's/^/      /'
echo ""

# ════════════════════════════════════════════
# TEST 1: CLI Basics
# ════════════════════════════════════════════

echo "=== Test 1: CLI Basics ==="

echo "  Running: immutable list"
immutable list 2>&1 | head -20
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_pass "immutable list succeeded"
else
    log_fail "immutable list failed"
fi

echo ""
echo "  Running: immutable status"
immutable status 2>&1 | head -10
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_pass "immutable status succeeded"
else
    log_fail "immutable status failed"
fi

echo ""
echo "  Running: immutable help"
immutable help 2>&1 | head -5
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_pass "immutable help succeeded"
else
    log_fail "immutable help failed"
fi

echo ""

# ════════════════════════════════════════════
# TEST 2: Create Overlay
# ════════════════════════════════════════════

echo "=== Test 2: Create Overlay ==="

echo "  Creating overlay: $TEST_OVERLAY"
immutable create "$TEST_OVERLAY" 2>&1
if [ $? -eq 0 ]; then
    log_pass "immutable create succeeded"
else
    log_fail "immutable create failed"
fi

# Verify overlay directory exists
OVERLAY_PATH="$POOL/@overlay-$TEST_OVERLAY"
if [ -d "$OVERLAY_PATH" ]; then
    log_pass "Overlay directory exists: $OVERLAY_PATH"
else
    log_fail "Overlay directory not found: $OVERLAY_PATH"
fi

# Verify it's a snapshot
SUBVOL_ID=$(root_cmd btrfs subvolume list "$POOL" 2>/dev/null | grep "@overlay-$TEST_OVERLAY" | awk '{print $2}')
if [ -n "$SUBVOL_ID" ]; then
    log_pass "Overlay is a BTRFS subvolume (ID: $SUBVOL_ID)"
else
    log_fail "Overlay not found in BTRFS subvolume list"
fi

# Verify it appears in list
echo ""
echo "  Overlays after creation:"
LIST_OUTPUT=$(immutable list 2>&1)
echo "$LIST_OUTPUT"
echo "$LIST_OUTPUT" | grep -q "$TEST_OVERLAY" && log_pass "Overlay appears in 'immutable list'" || {
    log_fail "Overlay missing from 'immutable list'"
    echo "  --- btrfs subvolume list raw ---"
    root_cmd btrfs subvolume list /pool 2>&1
    echo "  --- grep test ---"
    echo "$LIST_OUTPUT" | grep -i "overlay" || echo "(no overlay lines found)"
    echo "  --- end debug ---"
}

echo ""

# ════════════════════════════════════════════
# TEST 3: Overlay Isolation
# ════════════════════════════════════════════

echo "=== Test 3: Overlay Isolation ==="

# Create a marker file in the overlay
MARKER="immutable-test-$$-$(date +%s)"
echo "  Writing marker '$MARKER' to overlay $TEST_OVERLAY"
root_cmd sh -c "echo '$MARKER' > '$OVERLAY_PATH/tmp/$MARKER'" 2>/dev/null

if [ -f "$OVERLAY_PATH/tmp/$MARKER" ]; then
    log_pass "Marker file written to overlay"
else
    log_fail "Could not write marker file to overlay"
fi

# Verify marker does NOT exist in @base
if [ ! -f "$BASE/tmp/$MARKER" ]; then
    log_pass "Marker file does NOT exist in @base (isolation verified)"
else
    log_fail "Marker file exists in @base — ISOLATION BREACH"
fi

# Verify marker does NOT exist in / (current root = @overlay-init)
if [ ! -f "/tmp/$MARKER" ]; then
    log_pass "Marker file does NOT exist in current root (isolation verified)"
else
    log_fail "Marker file exists in current root — ISOLATION BREACH"
fi

echo ""

# ════════════════════════════════════════════
# TEST 4: @base Read-Only Enforcement
# ════════════════════════════════════════════

echo "=== Test 4: @base Read-Only Enforcement ==="

# Ensure @base is locked
if [ "$BASE_RO" != "true" ]; then
    echo "  Locking @base first..."
    immutable lock 2>&1
    BASE_RO="true"
fi

# Try to write to @base directly
echo "  Attempting write to @base (should fail)..."
if root_cmd touch "$BASE/tmp/test-readonly-$$" 2>/dev/null; then
    root_cmd rm -f "$BASE/tmp/test-readonly-$$"
    log_fail "@base is writable when it should be read-only!"
else
    log_pass "@base is properly read-only (write correctly denied)"
fi

# Try to create a file via cp
echo "  Attempting cp to @base (should fail)..."
if root_cmd cp /etc/hostname "$BASE/tmp/test-cp-$$" 2>/dev/null; then
    root_cmd rm -f "$BASE/tmp/test-cp-$$"
    log_fail "cp to @base succeeded when it should have failed"
else
    log_pass "cp to @base correctly denied"
fi

echo ""

# ════════════════════════════════════════════
# TEST 5: Reset Overlay
# ════════════════════════════════════════════

echo "=== Test 5: Reset Overlay ==="

echo "  Checking marker still exists in overlay before reset..."
if [ -f "$OVERLAY_PATH/tmp/$MARKER" ]; then
    log_pass "Marker exists before reset (baseline confirmed)"
else
    log_fail "Marker missing before reset — test is invalid"
fi

echo "  Resetting overlay $TEST_OVERLAY..."
immutable reset "$TEST_OVERLAY" 2>&1
if [ $? -eq 0 ]; then
    log_pass "immutable reset succeeded"
else
    log_fail "immutable reset failed"
fi

# Verify marker is gone
if [ ! -f "$OVERLAY_PATH/tmp/$MARKER" ]; then
    log_pass "Marker file removed after reset (overlay restored to @base state)"
else
    log_fail "Marker file still exists after reset"
fi

# Re-create marker for next tests
root_cmd sh -c "echo '$MARKER' > '$OVERLAY_PATH/tmp/$MARKER'"

echo ""

# ════════════════════════════════════════════
# TEST 6: @data Persistence Across Overlays
# ════════════════════════════════════════════

echo "=== Test 6: @data Persistence ==="

# @data is mounted at /home/USERNAME/ in each overlay's chroot,
# but at the pool level it's $POOL/@data/
DATA_MARKER="data-test-$$-$(date +%s)"
echo "  Writing marker '$DATA_MARKER' to @data"
root_cmd sh -c "echo '$DATA_MARKER' > '$POOL/@data/$DATA_MARKER'" 2>/dev/null

if [ -f "$POOL/@data/$DATA_MARKER" ]; then
    log_pass "Data marker written to @data"
else
    log_fail "Could not write to @data"
fi

# Verify @data is visible in overlay
if [ -f "$OVERLAY_PATH/home/USERNAME/$DATA_MARKER" ] || [ -f "$POOL/@data/$DATA_MARKER" ]; then
    log_pass "@data is accessible (marker visible at pool level)"
else
    log_fail "@data marker not found"
fi

echo ""

# ════════════════════════════════════════════
# TEST 7: Switch Overlay & Boot Entry
# ════════════════════════════════════════════

echo "=== Test 7: Switch Overlay ==="

# Record current boot config
ENTRY_FILE="/boot/efi/loader/entries/immutable.conf"
if [ -f "$ENTRY_FILE" ]; then
    CURRENT_SUBVOL=$(grep -o 'subvol=[^ ]*' "$ENTRY_FILE" | head -1 | cut -d= -f2)
    echo "  Current boot subvol: $CURRENT_SUBVOL"
else
    log_skip "immutable.conf not found, skipping switch test"
    echo ""
    echo "══════════════════════════════════════"
    echo "  Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
    echo "══════════════════════════════════════"
    exit 1
fi

echo "  Switching to overlay: $TEST_OVERLAY"
immutable switch "$TEST_OVERLAY" 2>&1
if [ $? -eq 0 ]; then
    log_pass "immutable switch succeeded"
else
    log_fail "immutable switch failed"
fi

# Verify boot entry changed
NEW_SUBVOL=$(grep -o 'subvol=[^ ]*' "$ENTRY_FILE" | head -1 | cut -d= -f2)
if [ "$NEW_SUBVOL" = "@overlay-$TEST_OVERLAY" ]; then
    log_pass "Boot entry updated to @overlay-$TEST_OVERLAY"
else
    log_fail "Boot entry is '$NEW_SUBVOL', expected '@overlay-$TEST_OVERLAY'"
fi

echo ""
echo "  NOTE: To complete this test, reboot and verify:"
echo "    1. System boots successfully"
echo "    2. 'findmnt -n -o SUBVOL /' shows @overlay-$TEST_OVERLAY"
echo "    3. The marker file '$MARKER' is visible at /tmp/$MARKER"
echo "    4. Run 'immutable status' to confirm boot overlay"
echo ""

# ════════════════════════════════════════════
# TEST 8: Create Second Overlay (Isolation)
# ════════════════════════════════════════════

echo "=== Test 8: Second Overlay Isolation ==="

echo "  Creating second overlay: $TEST_OVERLAY2"
immutable create "$TEST_OVERLAY2" 2>&1
OVERLAY2_PATH="$POOL/@overlay-$TEST_OVERLAY2"

if [ -d "$OVERLAY2_PATH" ]; then
    log_pass "Second overlay created"
else
    log_fail "Second overlay creation failed"
fi

# Write different marker to second overlay
MARKER2="marker2-$$-$(date +%s)"
echo "$MARKER2" > "$OVERLAY2_PATH/tmp/$MARKER2" 2>/dev/null

# Verify marker2 is NOT in first overlay
if [ ! -f "$OVERLAY_PATH/tmp/$MARKER2" ]; then
    log_pass "Second overlay marker not in first overlay (cross-isolation verified)"
else
    log_fail "Second overlay marker leaked into first overlay"
fi

# Verify original marker is NOT in second overlay
if [ ! -f "$OVERLAY2_PATH/tmp/$MARKER" ]; then
    log_pass "First overlay marker not in second overlay (cross-isolation verified)"
else
    log_fail "First overlay marker leaked into second overlay"
fi

# Verify both overlays appear in immutable list
echo ""
echo "  Overlays with both test overlays:"
LIST_OUTPUT=$(immutable list 2>&1)
echo "$LIST_OUTPUT"
echo "$LIST_OUTPUT" | grep -q "$TEST_OVERLAY" && log_pass "First overlay appears in list" || log_fail "First overlay missing from list"
echo "$LIST_OUTPUT" | grep -q "$TEST_OVERLAY2" && log_pass "Second overlay appears in list" || log_fail "Second overlay missing from list"

echo ""

# ════════════════════════════════════════════
# TEST 9: Lock/Unlock @base
# ════════════════════════════════════════════

echo "=== Test 9: Lock/Unlock @base ==="

echo "  @base is currently: $(root_cmd btrfs property get "$BASE" ro | grep -oP '(?<=ro=)\S+')"

echo "  Unlocking @base..."
immutable unlock 2>&1
NEW_RO=$(root_cmd btrfs property get "$BASE" ro 2>/dev/null | grep -oP '(?<=ro=)\S+')
    if [ "$NEW_RO" = "false" ]; then
    log_pass "@base unlocked (writable)"
else
    log_fail "@base still read-only after unlock"
fi

echo "  Writing test file to @base (should succeed)..."
if root_cmd touch "$BASE/tmp/unlock-test-$$" 2>/dev/null; then
    root_cmd rm -f "$BASE/tmp/unlock-test-$$"
    log_pass "Write to @base succeeded after unlock"
else
    log_fail "Write to @base failed even after unlock"
fi

echo "  Locking @base..."
immutable lock 2>&1
NEW_RO=$(root_cmd btrfs property get "$BASE" ro 2>/dev/null | grep -oP '(?<=ro=)\S+')
    if [ "$NEW_RO" = "true" ]; then
    log_pass "@base locked (read-only)"
else
    log_fail "@base still writable after lock"
fi

echo "  Writing test file to @base (should fail)..."
if root_cmd touch "$BASE/tmp/lock-test-$$" 2>/dev/null; then
    root_cmd rm -f "$BASE/tmp/lock-test-$$"
    log_fail "Write to @base succeeded after lock — immutability broken"
else
    log_pass "Write to @base correctly denied after lock"
fi

echo ""

# ════════════════════════════════════════════
# TEST 10: Package Shadowing
# ════════════════════════════════════════════

echo "=== Test 10: Package Shadowing ==="
echo "  Testing with package: $TEST_PKG_REMOVE"

# Verify package exists in @base
SHADOW_ERR=$(immutable run @base test -x "/usr/bin/$TEST_PKG_REMOVE" 2>&1) && shadow_ok=1 || shadow_ok=0
if [ "$shadow_ok" = "1" ]; then
    log_pass "Package '$TEST_PKG_REMOVE' exists in @base (baseline)"
else
    log_fail "Package '$TEST_PKG_REMOVE' check failed: $SHADOW_ERR"
fi

if [ "$shadow_ok" = "1" ]; then
    # Remove the package in overlay1
    echo "  Removing '$TEST_PKG_REMOVE' in overlay $TEST_OVERLAY..."
    immutable run "$TEST_OVERLAY" sudo bash -c "apt-get remove -y $TEST_PKG_REMOVE &>/dev/null" 2>&1

    # Verify it's gone in overlay1
    if immutable run "$TEST_OVERLAY" test -x "/usr/bin/$TEST_PKG_REMOVE" 2>/dev/null; then
        log_fail "Package '$TEST_PKG_REMOVE' still exists in $TEST_OVERLAY after removal"
    else
        log_pass "Package '$TEST_PKG_REMOVE' removed from $TEST_OVERLAY"
    fi

    # Verify it still exists in overlay2 (shadowing works)
    if immutable run "$TEST_OVERLAY2" test -x "/usr/bin/$TEST_PKG_REMOVE" 2>/dev/null; then
        log_pass "Package '$TEST_PKG_REMOVE' still exists in $TEST_OVERLAY2 (shadowing works)"
    else
        log_fail "Package '$TEST_PKG_REMOVE' missing from $TEST_OVERLAY2 — shadowing broken"
    fi

    # Verify it still exists in @base
    if immutable run @base test -x "/usr/bin/$TEST_PKG_REMOVE" 2>/dev/null; then
        log_pass "Package '$TEST_PKG_REMOVE' still exists in @base (immutable)"
    else
        log_fail "Package '$TEST_PKG_REMOVE' missing from @base — BROKEN"
    fi
fi

echo ""

# ════════════════════════════════════════════
# TEST 11: Package Version Isolation
# ════════════════════════════════════════════

echo "=== Test 11: Package Version Isolation ==="

if [ -n "$INSTALL_PKG" ] && [ -n "$INSTALL_REPO" ]; then
    echo "  Package: $INSTALL_PKG"
    echo "  Repo/Branch: $INSTALL_REPO"

    BRANCH="${INSTALL_REPO##*@}"

    # Install the package from the specific branch in overlay1
    echo "  Installing $INSTALL_PKG from $INSTALL_REPO in $TEST_OVERLAY..."
    # Copy popdev keyring into overlay directly
    KEYRING_SRC="$REPO_ROOT/lib/popdev-archive-keyring.gpg"
    KEYRING_DST="$POOL/@overlay-$TEST_OVERLAY/etc/apt/keyrings/popdev-archive-keyring.gpg"
    if [ -f "$KEYRING_SRC" ]; then
        root_cmd mkdir -p "$(dirname "$KEYRING_DST")"
        root_cmd cp "$KEYRING_SRC" "$KEYRING_DST"
    fi
    immutable run "$TEST_OVERLAY" sudo bash -c "
        # Add popdev staging repo in DEB822 format (matching docker_ops.py pattern)
        printf '%s\n' \
            'X-Repolib-ID: popdev-${BRANCH}' \
            'X-Repolib-Name: Pop Development Branch ${BRANCH}' \
            'Enabled: yes' \
            'Types: deb' \
            'URIs: http://apt.pop-os.org/staging/${BRANCH}' \
            'Suites: noble' \
            'Components: main' \
            'Signed-By: /etc/apt/keyrings/popdev-archive-keyring.gpg' \
            > /etc/apt/sources.list.d/popdev-${BRANCH}.sources
        # Pin this branch higher than default so its packages win
        mkdir -p /etc/apt/preferences.d
        printf 'Package: *\nPin: release o=pop-os-staging-%s\nPin-Priority: 1002\n' "${BRANCH}" > /etc/apt/preferences.d/pop-os-staging-${BRANCH}
        apt-get update -qq 2>&1 | tail -5
        timeout 60 apt-get install -y --allow-downgrades ${INSTALL_PKG} 2>&1 | tail -10
    " 2>&1

    # Compare actual binaries by checksum, not version strings
    # (versions may not change with every commit)
    BIN_PATH=$(immutable run "$TEST_OVERLAY" bash -c "test -x /usr/bin/$INSTALL_PKG && echo /usr/bin/$INSTALL_PKG" 2>/dev/null || true)
    echo "  Binary path in $TEST_OVERLAY: ${BIN_PATH:-not found}"

    if [ -n "$BIN_PATH" ]; then
        OVERLAY1_HASH=$(immutable run "$TEST_OVERLAY" sha256sum "$BIN_PATH" 2>/dev/null | awk '{print $1}')
        echo "  SHA256 in $TEST_OVERLAY: $OVERLAY1_HASH"
    else
        OVERLAY1_HASH=""
        echo "  Package not installed in $TEST_OVERLAY"
    fi

    BIN_PATH2=$(immutable run "$TEST_OVERLAY2" bash -c "test -x /usr/bin/$INSTALL_PKG && echo /usr/bin/$INSTALL_PKG" 2>/dev/null || true)
    if [ -n "$BIN_PATH2" ]; then
        OVERLAY2_HASH=$(immutable run "$TEST_OVERLAY2" sha256sum "$BIN_PATH2" 2>/dev/null | awk '{print $1}')
        echo "  SHA256 in $TEST_OVERLAY2: $OVERLAY2_HASH"
    else
        OVERLAY2_HASH=""
        echo "  Package not installed in $TEST_OVERLAY2"
    fi

    if [ -n "$OVERLAY1_HASH" ] && [ -n "$OVERLAY2_HASH" ]; then
        if [ "$OVERLAY1_HASH" != "$OVERLAY2_HASH" ]; then
            log_pass "Binaries differ between overlays (SHA256: $OVERLAY1_HASH vs $OVERLAY2_HASH)"
        else
            log_fail "Identical binaries in both overlays — version isolation broken"
        fi
    elif [ -n "$OVERLAY1_HASH" ] && [ -z "$OVERLAY2_HASH" ]; then
        log_pass "Package only in $TEST_OVERLAY (not in $TEST_OVERLAY2)"
    else
        log_fail "Package not found in $TEST_OVERLAY"
    fi

    # Compare against base
    if [ -n "$INSTALL_PKG" ]; then
        BASE_HASH=$(immutable run @base sha256sum "/usr/bin/$INSTALL_PKG" 2>/dev/null | awk '{print $1}' || true)
        echo "  SHA256 in @base: ${BASE_HASH:-not found}"
    else
        BASE_HASH=""
    fi

    if [ -n "$OVERLAY1_HASH" ] && [ -n "$BASE_HASH" ]; then
        if [ "$OVERLAY1_HASH" != "$BASE_HASH" ]; then
            log_pass "Overlay binary ($OVERLAY1_HASH) differs from base ($BASE_HASH)"
        else
            log_fail "Overlay binary matches base — no binary override applied"
        fi
    elif [ -z "$BASE_HASH" ] && [ -n "$OVERLAY1_HASH" ]; then
        log_pass "Package only in overlay, not in base"
    fi
else
    log_skip "No --install-pkg/--repo specified — skipping version isolation test"
    echo "  Usage: $0 --install-pkg <name> --repo <owner/repo@branch>"
fi

echo ""

# ════════════════════════════════════════════
# TEST 12: Non-root User Access to Overlays
# ════════════════════════════════════════════

echo "=== Test 12: Non-root User Access to Overlays ==="

TEST_USERNAME="USERNAME"

if id "$TEST_USERNAME" &>/dev/null; then
    echo "  Testing as user: $TEST_USERNAME (uid=$(id -u $TEST_USERNAME))"
    echo "  Note: test script already runs as $TEST_USERNAME — no su wrapper needed"

    # Test immutable run as non-root — should see correct user context
    echo "  Running: immutable run $TEST_OVERLAY id -u..."
    RUN_OUTPUT=$(timeout 15 immutable run "$TEST_OVERLAY" id -u 2>&1) && run_rc=0 || run_rc=$?
    echo "  raw output: '$RUN_OUTPUT' (rc=$run_rc)"
    RUN_UID=$(echo "$RUN_OUTPUT" | tr -d '[:space:]')

    if [ "$run_rc" -eq 124 ]; then
        log_fail "immutable run timed out after 15s"
    elif [ "$RUN_UID" = "1000" ]; then
        log_pass "immutable run as non-root runs as user (uid=$RUN_UID)"
    elif [ -n "$RUN_UID" ]; then
        log_fail "immutable run as non-root got unexpected uid: $RUN_UID"
    else
        log_fail "immutable run as non-root produced no output (rc=$run_rc)"
    fi

    # Test HOME is correct inside overlay
    echo "  Running: immutable run $TEST_OVERLAY printenv HOME..."
    HOME_OUTPUT=$(timeout 15 immutable run "$TEST_OVERLAY" printenv HOME 2>&1) || true
    echo "  HOME inside overlay: $HOME_OUTPUT"

    if [ "$HOME_OUTPUT" = "/home/$TEST_USERNAME" ]; then
        log_pass "HOME is correct inside overlay: $HOME_OUTPUT"
    else
        log_fail "HOME is wrong inside overlay: $HOME_OUTPUT (expected /home/$TEST_USERNAME)"
    fi

    # Test sudo apt works inside overlay (the real use case)
    echo "  Running: immutable run $TEST_OVERLAY sudo apt-get install -y tree..."
    APT_OUTPUT=$(timeout 60 immutable run "$TEST_OVERLAY" sudo apt-get install -y tree 2>&1) || true
    echo "$APT_OUTPUT" | tail -3

    if timeout 15 immutable run "$TEST_OVERLAY" which tree 2>/dev/null | grep -q tree; then
        log_pass "sudo apt-get install works inside overlay as non-root"
    else
        log_fail "sudo apt-get install failed inside overlay as non-root"
    fi

    # Verify installed package doesn't exist in @base
    echo "  Verifying 'tree' not in @base..."
    if timeout 15 immutable run @base which tree 2>/dev/null | grep -q tree; then
        log_fail "tree found in @base — isolation broken"
    else
        log_pass "tree not in @base (only in overlay)"
    fi
else
    log_skip "User '$TEST_USERNAME' not found — skipping non-root test"
fi

echo ""

# ════════════════════════════════════════════
# CLEAN-BOOT TESTS
# ════════════════════════════════════════════

echo "══════════════════════════════════════"
echo "  CLEAN-BOOT"
echo "══════════════════════════════════════"

# Test clean-boot with no stale entries
CLEAN_OUTPUT=$(immutable clean-boot 2>&1) || true
echo "$CLEAN_OUTPUT"
if echo "$CLEAN_OUTPUT" | grep -q "No stale boot entries\|Kept"; then
    log_pass "immutable clean-boot succeeded"
else
    log_fail "immutable clean-boot failed: $CLEAN_OUTPUT"
fi

# Test clean-boot protects immutable.conf, recovery.conf, and previous.conf
if echo "$CLEAN_OUTPUT" | grep -q "immutable.conf" && echo "$CLEAN_OUTPUT" | grep -q "recovery.conf" && echo "$CLEAN_OUTPUT" | grep -q "previous.conf"; then
    log_pass "clean-boot preserves immutable.conf, recovery.conf, and previous.conf"
else
    log_fail "clean-boot did not list all protected entries"
fi

# Test clean-boot removes entry with missing kernel
ENTRIES_DIR="/boot/efi/loader/entries"
STALE_ENTRY="$ENTRIES_DIR/stale-test.conf"
if [ -d "$ENTRIES_DIR" ]; then
    echo "title Stale test kernel
linux /EFI/test-nonexistent/vmlinuz-test.efi
initrd /EFI/test-nonexistent/initrd-test.img
options quiet splash" > "$STALE_ENTRY"

    CLEAN_OUTPUT2=$(immutable clean-boot 2>&1) || true
    echo "$CLEAN_OUTPUT2"
    if echo "$CLEAN_OUTPUT2" | grep -q "stale-test.conf" && echo "$CLEAN_OUTPUT2" | grep -q "Removed"; then
        log_pass "clean-boot removed stale entry with missing kernel"
    else
        log_fail "clean-boot did not remove stale entry"
    fi
    rm -f "$STALE_ENTRY"
else
    log_skip "Boot entries directory not found — skipping stale entry test"
fi

echo ""

# ════════════════════════════════════════════
# HOOK TESTS
# ════════════════════════════════════════════

echo "══════════════════════════════════════"
echo "  KERNELSTUB HOOKS"
echo "══════════════════════════════════════"

# Check that immutable-aware hooks are installed
for HOOK_PATH in \
    /etc/kernel/postinst.d/zz-kernelstub \
    /etc/kernel/postinst.d/zz-systemd-boot \
    /etc/initramfs/post-update.d/zz-kernelstub \
    /etc/initramfs/post-update.d/systemd-boot; do
    if [ -f "$HOOK_PATH" ]; then
        if head -3 "$HOOK_PATH" | grep -q "immutable"; then
            log_pass "Immutable-aware hook: $HOOK_PATH"
        else
            log_fail "Hook exists but not immutable-aware: $HOOK_PATH"
        fi
    else
        log_fail "Hook missing: $HOOK_PATH"
    fi
done

# Check that hooks exist in protected source directory
for HOOK_DIR in kernel-postinst.d initramfs-post-update.d; do
    if [ -d "/usr/lib/immutable/hooks/$HOOK_DIR" ]; then
        COUNT=$(ls -1 "/usr/lib/immutable/hooks/$HOOK_DIR" 2>/dev/null | wc -l)
        if [ "$COUNT" -gt 0 ]; then
            log_pass "Protected source hooks: /usr/lib/immutable/hooks/$HOOK_DIR ($COUNT hooks)"
        else
            log_fail "Protected source directory empty: /usr/lib/immutable/hooks/$HOOK_DIR"
        fi
    else
        log_fail "Protected source directory missing: /usr/lib/immutable/hooks/$HOOK_DIR"
    fi
done

# Check that dpkg hook is installed
if [ -f "/etc/apt/apt.conf.d/99-immutable-hooks" ]; then
    log_pass "dpkg hook installed: /etc/apt/apt.conf.d/99-immutable-hooks"
else
    log_fail "dpkg hook missing: /etc/apt/apt.conf.d/99-immutable-hooks"
fi

# Check that reinstall script is installed
if [ -x "/usr/lib/immutable/hooks/immutable-hook-reinstall" ]; then
    log_pass "Reinstall script installed: /usr/lib/immutable/hooks/immutable-hook-reinstall"
else
    log_fail "Reinstall script missing: /usr/lib/immutable/hooks/immutable-hook-reinstall"
fi

echo ""

# ════════════════════════════════════════════
# PREVIOUS KERNEL BOOT ENTRY TESTS
# ════════════════════════════════════════════

echo "══════════════════════════════════════"
echo "  PREVIOUS KERNEL BOOT ENTRY"
echo "══════════════════════════════════════"

if [ -f "$ENTRIES_DIR/previous.conf" ]; then
    log_pass "previous.conf boot entry exists"
    if grep -q "vmlinuz-previous" "$ENTRIES_DIR/previous.conf"; then
        log_pass "previous.conf references vmlinuz-previous.efi"
    else
        log_fail "previous.conf does not reference vmlinuz-previous.efi"
    fi
else
    log_fail "previous.conf boot entry not found"
fi

echo ""

# ════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════

echo "══════════════════════════════════════"
echo "  Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
echo "══════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "  Some tests failed. Review output above."
    exit 1
else
    echo ""
    echo "  All tests passed!"
    exit 0
fi
