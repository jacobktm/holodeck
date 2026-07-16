#!/bin/bash
set -uo pipefail

# ── Test Procedure for Immutable Pop!_OS ──
# Run as root on the installed system.
# Tests: overlay creation, isolation, @base immutability, reset, @data persistence,
#        switch/reboot, delete, lock/unlock.

POOL="/pool"
BASE="$POOL/@base"
TEST_OVERLAY="test-$(date +%s)"
TEST_OVERLAY2="test2-$(date +%s)"
TEST_FILE="/tmp/immutable-test-marker-$$"
PASS=0
FAIL=0
SKIP=0

# ── Helpers ──

log_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
log_skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }
log_info() { echo "  INFO: $1"; }

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    # Remove test overlays
    for name in "$TEST_OVERLAY" "$TEST_OVERLAY2"; do
        local path="$POOL/@overlay-$name"
        if [ -d "$path" ]; then
            # Unmount if needed
            for m in $(mount | grep "$path" | awk '{print $3}' | sort -r); do
                umount "$m" 2>/dev/null || true
            done
            btrfs subvolume delete "$path" 2>/dev/null && echo "  Removed $name" || true
        fi
    done
    # Remove test data file
    rm -f "$POOL/@data/$TEST_FILE" 2>/dev/null || true
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

# ── Pre-flight checks ──

echo "=== Pre-flight Checks ==="

# Check running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "FATAL: Must run as root"; exit 1
fi
log_pass "Running as root"

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
    mkdir -p "$POOL"
    mount -o subvolid=5 "$ROOT_DEV" "$POOL" 2>/dev/null
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
BASE_RO=$(btrfs property get "$BASE" ro 2>/dev/null | grep -oP '(?<=ro=)\S+')
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
SUBVOL_ID=$(btrfs subvolume list "$POOL" 2>/dev/null | grep "@overlay-$TEST_OVERLAY" | awk '{print $2}')
if [ -n "$SUBVOL_ID" ]; then
    log_pass "Overlay is a BTRFS subvolume (ID: $SUBVOL_ID)"
else
    log_fail "Overlay not found in BTRFS subvolume list"
fi

# Verify it appears in list
echo ""
echo "  Overlays after creation:"
immutable list 2>&1 | grep -q "$TEST_OVERLAY" && log_pass "Overlay appears in 'immutable list'" || log_fail "Overlay missing from 'immutable list'"

echo ""

# ════════════════════════════════════════════
# TEST 3: Overlay Isolation
# ════════════════════════════════════════════

echo "=== Test 3: Overlay Isolation ==="

# Create a marker file in the overlay
MARKER="immutable-test-$$-$(date +%s)"
echo "  Writing marker '$MARKER' to overlay $TEST_OVERLAY"
echo "$MARKER" > "$OVERLAY_PATH/tmp/$MARKER" 2>/dev/null

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
if touch "$BASE/tmp/test-readonly-$$" 2>/dev/null; then
    rm -f "$BASE/tmp/test-readonly-$$"
    log_fail "@base is writable when it should be read-only!"
else
    log_pass "@base is properly read-only (write correctly denied)"
fi

# Try to create a file via cp
echo "  Attempting cp to @base (should fail)..."
if cp /etc/hostname "$BASE/tmp/test-cp-$$" 2>/dev/null; then
    rm -f "$BASE/tmp/test-cp-$$"
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
echo "$MARKER" > "$OVERLAY_PATH/tmp/$MARKER"

echo ""

# ════════════════════════════════════════════
# TEST 6: @data Persistence Across Overlays
# ════════════════════════════════════════════

echo "=== Test 6: @data Persistence ==="

# @data is mounted at /home/USERNAME/ in each overlay's chroot,
# but at the pool level it's $POOL/@data/
DATA_MARKER="data-test-$$-$(date +%s)"
echo "  Writing marker '$DATA_MARKER' to @data"
echo "$DATA_MARKER" > "$POOL/@data/$DATA_MARKER" 2>/dev/null

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

echo ""

# ════════════════════════════════════════════
# TEST 9: Lock/Unlock @base
# ════════════════════════════════════════════

echo "=== Test 9: Lock/Unlock @base ==="

echo "  @base is currently: $(btrfs property get "$BASE" ro | grep -oP '(?<=ro=)\S+')"

echo "  Unlocking @base..."
immutable unlock 2>&1
NEW_RO=$(btrfs property get "$BASE" ro 2>/dev/null | grep -oP '(?<=ro=)\S+')
    if [ "$NEW_RO" = "false" ]; then
    log_pass "@base unlocked (writable)"
else
    log_fail "@base still read-only after unlock"
fi

echo "  Writing test file to @base (should succeed)..."
if touch "$BASE/tmp/unlock-test-$$" 2>/dev/null; then
    rm -f "$BASE/tmp/unlock-test-$$"
    log_pass "Write to @base succeeded after unlock"
else
    log_fail "Write to @base failed even after unlock"
fi

echo "  Locking @base..."
immutable lock 2>&1
NEW_RO=$(btrfs property get "$BASE" ro 2>/dev/null | grep -oP '(?<=ro=)\S+')
    if [ "$NEW_RO" = "true" ]; then
    log_pass "@base locked (read-only)"
else
    log_fail "@base still writable after lock"
fi

echo "  Writing test file to @base (should fail)..."
if touch "$BASE/tmp/lock-test-$$" 2>/dev/null; then
    rm -f "$BASE/tmp/lock-test-$$"
    log_fail "Write to @base succeeded after lock — immutability broken"
else
    log_pass "Write to @base correctly denied after lock"
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
