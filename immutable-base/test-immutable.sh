#!/bin/bash
set -uo pipefail

# ── Test Procedure for Immutable Pop!_OS ──
# Run as root on the installed system.
# Tests: overlay creation, isolation, @base immutability, reset, @data persistence,
#        switch/reboot, delete, lock/unlock, shadowing, package version isolation.

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

while [ $# -gt 0 ]; do
    case "$1" in
        --test-pkg) TEST_PKG_REMOVE="$2"; shift 2 ;;
        --install-pkg) INSTALL_PKG="$2"; shift 2 ;;
        --repo) INSTALL_REPO="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Helpers ──

log_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
log_skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }
log_info() { echo "  INFO: $1"; }

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    # Revert boot entry to overlay-init if it was changed
    local entry="/boot/efi/loader/entries/immutable.conf"
    if [ -f "$entry" ]; then
        local current_subvol=$(grep -o 'subvol=[^ ]*' "$entry" | head -1 | cut -d= -f2 || true)
        if [ -n "$current_subvol" ] && [[ "$current_subvol" == *@overlay-test* ]]; then
            echo "  Reverting boot entry from $current_subvol to @overlay-init"
            sed -i "s|rootflags=subvol=[^ ]*|rootflags=subvol=@overlay-init|g" "$entry"
        fi
    fi
    # Remove test overlays
    for name in "$TEST_OVERLAY" "$TEST_OVERLAY2"; do
        local path="$POOL/@overlay-$name"
        if [ -d "$path" ]; then
            # Unmount if needed
            for m in $(mount | grep "$path" | awk '{print $3}' | sort -r); do
                umount "$m" 2>/dev/null || true
            done
            btrfs subvolume delete "$path" 2>/dev/null && echo "  Removed $name" || echo "  WARNING: Failed to remove $name"
        fi
        # Verify deletion
        if [ -d "$path" ]; then
            echo "  ERROR: $path still exists after deletion!"
            btrfs subvolume delete "$path" 2>/dev/null || true
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

# ── Clean up stale test overlays from previous runs ──
echo "=== Cleaning stale overlays ==="
for stale in $(btrfs subvolume list "$POOL" 2>/dev/null | grep -oP '@overlay-test[0-9]*-[0-9]+' | sort -u); do
    echo "  Removing stale overlay: $stale"
    btrfs subvolume delete "$POOL/$stale" 2>/dev/null || true
done
# Also revert boot entry if stuck on a test overlay
entry="/boot/efi/loader/entries/immutable.conf"
if [ -f "$entry" ]; then
    current_subvol=$(grep -o 'subvol=[^ ]*' "$entry" | head -1 | cut -d= -f2 || true)
    if [ -n "$current_subvol" ] && [[ "$current_subvol" == *@overlay-test* ]]; then
        echo "  Reverting boot entry from $current_subvol to @overlay-init"
        sed -i "s|rootflags=subvol=[^ ]*|rootflags=subvol=@overlay-init|g" "$entry"
    fi
fi
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
SUBVOL_ID=$(btrfs subvolume list "$POOL" 2>/dev/null | grep "@overlay-$TEST_OVERLAY" | awk '{print $2}')
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
    btrfs subvolume list /pool 2>&1
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
# TEST 10: Package Shadowing
# ════════════════════════════════════════════

echo "=== Test 10: Package Shadowing ==="
echo "  Testing with package: $TEST_PKG_REMOVE"

# Verify package exists in @base
if immutable run @base test -x "/usr/bin/$TEST_PKG_REMOVE" 2>/dev/null; then
    log_pass "Package '$TEST_PKG_REMOVE' exists in @base (baseline)"
else
    log_skip "Package '$TEST_PKG_REMOVE' not in @base — skipping shadowing test"
    goto_shadow=1
fi

if [ "${goto_shadow:-0}" != "1" ]; then
    # Remove the package in overlay1
    echo "  Removing '$TEST_PKG_REMOVE' in overlay $TEST_OVERLAY..."
    immutable run "$TEST_OVERLAY" bash -c "apt-get remove -y $TEST_PKG_REMOVE &>/dev/null" 2>&1

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
    KEYRING_SRC="$(dirname "$(dirname "$0")")/lib/popdev-archive-keyring.gpg"
    KEYRING_DST="$POOL/@overlay-$TEST_OVERLAY/etc/apt/keyrings/popdev-archive-keyring.gpg"
    if [ -f "$KEYRING_SRC" ]; then
        mkdir -p "$(dirname "$KEYRING_DST")"
        cp "$KEYRING_SRC" "$KEYRING_DST"
    fi
    immutable run "$TEST_OVERLAY" bash -c "
        # Add popdev staging repo in DEB822 format (matching docker_ops.py pattern)
        cat > /etc/apt/sources.list.d/popdev-${BRANCH}.sources <<EOF
X-Repolib-ID: popdev-${BRANCH}
X-Repolib-Name: Pop Development Branch ${BRANCH}
Enabled: yes
Types: deb
URIs: http://apt.pop-os.org/staging/${BRANCH}
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/popdev-archive-keyring.gpg
EOF
        # Pin this branch higher than default so its packages win
        mkdir -p /etc/apt/preferences.d
        printf 'Package: *\nPin: release o=pop-os-staging-%s\nPin-Priority: 1002\n' '$BRANCH' > /etc/apt/preferences.d/pop-os-staging-${BRANCH}
        apt-get update -qq 2>&1 | tail -5
        timeout 60 apt-get install -y --allow-downgrades $INSTALL_PKG 2>&1 | tail -10
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
    BASE_BIN=$(immutable run @base bash -c "test -x /usr/bin/$INSTALL_PKG && echo /usr/bin/$INSTALL_PKG" 2>/dev/null || true)
    if [ -n "$BASE_BIN" ]; then
        BASE_HASH=$(chroot "$CHROOT_HELPER" sha256sum "$BASE_BIN" 2>/dev/null | awk '{print $1}')
        echo "  SHA256 in @base: $BASE_HASH"
    else
        BASE_HASH=""
        echo "  Package not in @base"
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
