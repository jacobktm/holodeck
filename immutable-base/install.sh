#!/bin/bash
set -euo pipefail

# ── Install immutable Pop!_OS to disk ──

VERSION="0.1.0"
BUILD_DIR="${BUILD_DIR:-/tmp/immutable-build}"
ROOTFS_TAR="$BUILD_DIR/base-rootfs.tar.zst"
POOL="/pool"
MOUNT_POINT="/mnt/immutable"

# ── Helpers ──

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ""; echo "══════════════════════════════════════"; echo " $1"; echo "══════════════════════════════════════"; echo ""; }
confirm() { read -p "$1 [y/N]: " -n 1 -r; echo; [[ $REPLY =~ ^[Yy]$ ]]; }

usage() {
    cat <<EOF
install.sh v${VERSION} — Install immutable Pop!_OS to disk

Usage:
  sudo ./install.sh [OPTIONS]

Options:
  --device PATH       Target disk (e.g., /dev/sda) — DESTRUCTIVE!
  --rootfs PATH       Rootfs tarball (default: $ROOTFS_TAR)
  --efi-only          Skip data partition, mount data from root
  --help              Show this help

This will ERASE ALL DATA on the target disk.
EOF
}

# ── Parse args ──

TARGET_DEVICE=""
EFI_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --device) TARGET_DEVICE="$2"; shift 2 ;;
        --rootfs) ROOTFS_TAR="$2"; shift 2 ;;
        --efi-only) EFI_ONLY=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Must run as root"
[ -b "$TARGET_DEVICE" ] || die "Target device not found: $TARGET_DEVICE (use --device /dev/sdX)"
[ -f "$ROOTFS_TAR" ] || die "Rootfs tarball not found: $ROOTFS_TAR (run build-base.sh first)"

# ── Step 1: Partition ──

info "Step 1: Partitioning $TARGET_DEVICE"

echo "Current partition layout:"
lsblk "$TARGET_DEVICE" 2>/dev/null || true
echo ""
echo "WARNING: This will ERASE ALL DATA on $TARGET_DEVICE"
confirm "Continue?" || exit 1

# Unmount anything on the target
for mnt in $(mount | grep "$TARGET_DEVICE" | awk '{print $3}' | sort -r); do
    umount "$mnt" 2>/dev/null || true
done

# GPT partition table
parted -s "$TARGET_DEVICE" mklabel gpt

# EFI partition (512MB)
parted -s "$TARGET_DEVICE" mkpart ESP fat32 1MiB 513MiB
parted -s "$TARGET_DEVICE" set 1 esp on

# BTRFS partition (rest)
parted -s "$TARGET_DEVICE" mkpart root btrfs 513MiB 100%

sleep 1
partprobe "$TARGET_DEVICE" 2>/dev/null || true

# Determine partition names
if [[ "$TARGET_DEVICE" == *"nvme"* ]] || [[ "$TARGET_DEVICE" == *"mmcblk"* ]]; then
    PART_EFI="${TARGET_DEVICE}p1"
    PART_ROOT="${TARGET_DEVICE}p2"
else
    PART_EFI="${TARGET_DEVICE}1"
    PART_ROOT="${TARGET_DEVICE}2"
fi

echo "EFI: $PART_EFI"
echo "Root: $PART_ROOT"

# ── Step 2: Format ──

info "Step 2: Formatting"

mkfs.fat -F32 -n EFI "$PART_EFI"
mkfs.btrfs -f -L immutable "$PART_ROOT"

# ── Step 3: Create BTRFS subvolumes ──

info "Step 3: Creating BTRFS subvolumes"

mkdir -p "$MOUNT_POINT"
mount "$PART_ROOT" "$MOUNT_POINT"

btrfs subvolume create "$MOUNT_POINT/@base"
btrfs subvolume create "$MOUNT_POINT/@data"
btrfs subvolume create "$MOUNT_POINT/@snapshots"
btrfs subvolume create "$MOUNT_POINT/@overlay-init"

# Create initial overlay from base (will be populated later)
# For now, create empty overlay structure

umount "$MOUNT_POINT"

# ── Step 4: Mount and extract rootfs ──

info "Step 4: Installing base rootfs"

# Mount @overlay-init as root (writable, will be the initial boot)
mount -o subvol=@overlay-init "$PART_ROOT" "$MOUNT_POINT"

# Extract rootfs
echo "Extracting rootfs..."
zstd -d "$ROOTFS_TAR" --stdout | tar -C "$MOUNT_POINT" -xf -

# Mount boot
mkdir -p "$MOUNT_POINT/boot/efi"
mount "$PART_EFI" "$MOUNT_POINT/boot/efi"

# ── Step 5: Configure fstab ──

info "Step 5: Configuring fstab"

ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
EFI_UUID=$(blkid -s UUID -o value "$PART_EFI")

cat > "$MOUNT_POINT/etc/fstab" <<FSTAB
# /etc/fstab: immutable Pop!_OS
UUID=$ROOT_UUID  /            btrfs  defaults,noatime,compress=zstd:1,ssd,subvol=/@overlay-init  0 0
UUID=$ROOT_UUID  /pool        btrfs  defaults,noatime,subvolid=5                                  0 0
UUID=$ROOT_UUID  /home/USERNAME/.config  btrfs  defaults,noatime,compress=zstd:1,ssd,subvol=/@overlay-init  0 0
UUID=$EFI_UUID   /boot/efi    vfat   defaults,noatime,fmask=0022,dmask=0022,codepage=437         0 2
FSTAB

# ── Step 6: Configure systemd-boot ──

info "Step 6: Configuring systemd-boot"

# Install systemd-boot
chroot "$MOUNT_POINT" bootctl --path=/boot/efi install 2>/dev/null || true

# Create loader config
mkdir -p "$MOUNT_POINT/boot/efi/loader"
cat > "$MOUNT_POINT/boot/efi/loader/loader.conf" <<BOOTCFG
default  immutable.conf
timeout  5
console-mode auto
editor   yes
BOOTCFG

# Create boot entry
mkdir -p "$MOUNT_POINT/boot/efi/loader/entries"
cat > "$MOUNT_POINT/boot/efi/loader/entries/immutable.conf" <<ENTRY
title   Immutable Pop!_OS
linux   /vmlinuz
initrd  /initrd.img
options root=UUID=$ROOT_UUID rootflags=subvol=/@overlay-init rw quiet splash
ENTRY

# ── Step 7: Configure initramfs for BTRFS ──

info "Step 7: Configuring initramfs"

# Ensure btrfs module is in initramfs
echo "btrfs" >> "$MOUNT_POINT/etc/initramfs-tools/modules"

# Rebuild initramfs
chroot "$MOUNT_POINT" update-initramfs -u 2>/dev/null || true

# ── Step 8: Set up pool mount ──

info "Step 8: Setting up pool"

mkdir -p "$MOUNT_POINT/pool"

# Add pool to fstab
echo "UUID=$ROOT_UUID  /pool  btrfs  defaults,noatime,subvolid=5  0 0" >> "$MOUNT_POINT/etc/fstab"

# Mount pool
mount -o subvolid=5 "$PART_ROOT" "$MOUNT_POINT/pool"

# Move @overlay-init contents to @base (the immutable base)
echo "Setting up immutable base..."
btrfs subvolume snapshot "$MOUNT_POINT/pool/@overlay-init" "$MOUNT_POINT/pool/@base"

# Set @base as read-only
btrfs property set "$MOUNT_POINT/pool/@base" ro true

# ── Step 9: Install immutable CLI ──

info "Step 9: Installing immutable CLI"

cp "$(dirname "$0")/immutable" "$MOUNT_POINT/usr/local/bin/immutable"
chmod +x "$MOUNT_POINT/usr/local/bin/immutable"

# ── Step 10: Cleanup ──

info "Step 10: Cleanup"

# Unmount
umount "$MOUNT_POINT/pool" 2>/dev/null || true
umount "$MOUNT_POINT/boot/efi" 2>/dev/null || true
umount "$MOUNT_POINT" 2>/dev/null || true

echo ""
echo "══════════════════════════════════════"
echo " Installation complete!"
echo "══════════════════════════════════════"
echo ""
echo "Reboot into your new immutable Pop!_OS."
echo ""
echo "After boot, use:"
echo "  immutable list              # show overlays"
echo "  immutable create mytest     # create overlay for testing"
echo "  immutable shell mytest      # chroot into overlay"
echo "  immutable switch mytest     # set boot overlay (needs reboot)"
