#!/bin/bash
set -euo pipefail

# ── Install immutable Pop!_OS to disk ──

VERSION="0.3.0"
BUILD_DIR="${BUILD_DIR:-/tmp/immutable-build}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOTFS_TAR="${SCRIPT_DIR}/base-rootfs.tar.zst"
[ -f "$ROOTFS_TAR" ] || ROOTFS_TAR="$BUILD_DIR/base-rootfs.tar.zst"
MOUNT_POINT="/mnt/immutable"
SWAP_SIZE="8G"

die() { echo "ERROR: $*" >&2; exit 1; }
confirm() { read -p "$1 [y/N]: " -n 1 -r; echo; [[ $REPLY =~ ^[Yy]$ ]]; }

usage() {
    cat <<EOF
install.sh v${VERSION} — Install immutable Pop!_OS to disk

Usage:
  sudo ./install.sh [OPTIONS]

Options:
  --device PATH       Target disk (e.g., /dev/sda) — DESTRUCTIVE!
  --rootfs PATH       Rootfs tarball (default: $ROOTFS_TAR)
  --swap SIZE         Swap size (default: $SWAP_SIZE)
  --username NAME     Username to create (prompted if omitted)
  --password PASS     User password (prompted if omitted)
  --help              Show this help

This will ERASE ALL DATA on the target disk.
EOF
}

# ── Parse args ──

TARGET_DEVICE=""
USERNAME=""
PASSWORD=""

while [ $# -gt 0 ]; do
    case "$1" in
        --device) TARGET_DEVICE="$2"; shift 2 ;;
        --rootfs) ROOTFS_TAR="$2"; shift 2 ;;
        --swap) SWAP_SIZE="$2"; shift 2 ;;
        --username) USERNAME="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Must run as root"
[ -b "$TARGET_DEVICE" ] || die "Target device not found: $TARGET_DEVICE (use --device /dev/sdX)"
[ -f "$ROOTFS_TAR" ] || die "Rootfs tarball not found: $ROOTFS_TAR (run build-base.sh first)"

# Prompt for username if not provided
if [ -z "$USERNAME" ]; then
    read -rp "Enter username to create: " USERNAME
fi
[ -n "$USERNAME" ] || die "Username cannot be empty"

# Prompt for password if not provided
if [ -z "$PASSWORD" ]; then
    read -rsp "Enter password for $USERNAME: " PASSWORD
    echo
fi
[ -n "$PASSWORD" ] || die "Password cannot be empty"

echo "Username: $USERNAME"

# ── Partition ──

echo "Current partition layout:"
lsblk "$TARGET_DEVICE" 2>/dev/null || true
echo ""
echo "WARNING: This will ERASE ALL DATA on $TARGET_DEVICE"
confirm "Continue?" || exit 1

for mnt in $(mount | grep "$TARGET_DEVICE" | awk '{print $3}' | sort -r); do
    umount "$mnt" 2>/dev/null || true
done

EFI_END=2049
SWAP_MIB=$(( ${SWAP_SIZE%G} * 1024 ))
SWAP_START="${EFI_END}MiB"
SWAP_END="$(( EFI_END + SWAP_MIB ))MiB"

parted -s "$TARGET_DEVICE" mklabel gpt
parted -s "$TARGET_DEVICE" mkpart ESP fat32 1MiB 2049MiB
parted -s "$TARGET_DEVICE" set 1 esp on
parted -s "$TARGET_DEVICE" mkpart swap linux-swap "$SWAP_START" "$SWAP_END"
parted -s "$TARGET_DEVICE" mkpart root btrfs "$SWAP_END" 100%

sleep 1
partprobe "$TARGET_DEVICE" 2>/dev/null || true

if [[ "$TARGET_DEVICE" == *"nvme"* ]] || [[ "$TARGET_DEVICE" == *"mmcblk"* ]]; then
    PART_EFI="${TARGET_DEVICE}p1"
    PART_SWAP="${TARGET_DEVICE}p2"
    PART_ROOT="${TARGET_DEVICE}p3"
else
    PART_EFI="${TARGET_DEVICE}1"
    PART_SWAP="${TARGET_DEVICE}2"
    PART_ROOT="${TARGET_DEVICE}3"
fi

echo "EFI: $PART_EFI  Swap: $PART_SWAP  Root: $PART_ROOT"

# ── Format ──

mkfs.fat -F32 -n EFI "$PART_EFI"
mkfs.btrfs -f -L immutable "$PART_ROOT"

# ── BTRFS subvolumes ──

mkdir -p "$MOUNT_POINT"
mount "$PART_ROOT" "$MOUNT_POINT"

btrfs subvolume create "$MOUNT_POINT/@data"
btrfs subvolume create "$MOUNT_POINT/@snapshots"
btrfs subvolume create "$MOUNT_POINT/@base"

# Create @data user directories and default dotfile stubs
for dir in Documents Downloads Pictures Videos Music; do
    mkdir -p "$MOUNT_POINT/@data/$dir"
done
for dotfile in .bash_history .profile .bashrc .gitconfig; do
    touch "$MOUNT_POINT/@data/$dotfile"
done

umount "$MOUNT_POINT"

# ── Extract rootfs into @base ──

mount -o subvol=@base "$PART_ROOT" "$MOUNT_POINT"

echo "Extracting rootfs..."
zstd -d "$ROOTFS_TAR" --stdout | tar -C "$MOUNT_POINT" -xf -

mkdir -p "$MOUNT_POINT/boot/efi"
mount "$PART_EFI" "$MOUNT_POINT/boot/efi"

# ── Remove stale APT proxy if unreachable ──
# The base image may be built with an apt-cacher-ng proxy that isn't
# available at the install location. Remove it to avoid hung installs.
PROXY_CONF="$MOUNT_POINT/etc/apt/apt.conf.d/99proxy"
if [ -f "$PROXY_CONF" ]; then
    PROXY_URL=$(grep -oP 'http://\S+' "$PROXY_CONF" | head -1 | tr -d '";')
    if [ -n "$PROXY_URL" ]; then
        # Extract host:port from URL
        PROXY_HOST=$(echo "$PROXY_URL" | sed -E 's|https?://||; s|/.*||; s|:.*||')
        PROXY_PORT=$(echo "$PROXY_URL" | sed -E 's|.*:||; s|/.*||')
        if ! ping -c 1 -W 2 "$PROXY_HOST" &>/dev/null; then
            echo "APT proxy $PROXY_URL is unreachable — removing from rootfs"
            rm -f "$PROXY_CONF"
        else
            echo "APT proxy $PROXY_URL is reachable — keeping"
        fi
    fi
fi

# ── Encrypted swap (plain dm-crypt, auto-generated key like Pop!_OS) ──

mkswap -L swap "$PART_SWAP"
SWAP_UUID=$(blkid -s UUID -o value "$PART_SWAP")
echo "cryptswap UUID=$SWAP_UUID /dev/urandom swap,plain,offset=1024,cipher=aes-xts-plain64,size=512" >> "$MOUNT_POINT/etc/crypttab"

# ── Chroot setup ──

mount --bind /dev "$MOUNT_POINT/dev"
mount --bind /dev/pts "$MOUNT_POINT/dev/pts"
mount -t proc proc "$MOUNT_POINT/proc"
mount --rbind /sys "$MOUNT_POINT/sys"
mount --make-rslave "$MOUNT_POINT/sys"
mount --bind /run "$MOUNT_POINT/run"

if ! cmp -s /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf" 2>/dev/null; then
    cp /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf"
fi

# ── Preseed debconf (non-interactive installs) ──

mkdir -p "$MOUNT_POINT/tmp"
cat > "$MOUNT_POINT/tmp/debconf-seed.conf" <<'SEED'
console-setup console-setup/charmap42 select UTF-8
console-setup console-setup/charmap select UTF-8
console-setup console-setup/codeset select guess
locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8
locales locales/default_environment_locale select en_US.UTF-8
locales locales/purge_multiselect boolean false
SEED
chroot "$MOUNT_POINT" debconf-set-selections < "$MOUNT_POINT/tmp/debconf-seed.conf"
rm -f "$MOUNT_POINT/tmp/debconf-seed.conf"

# ── Create user ──

echo "Creating user: $USERNAME"
chroot "$MOUNT_POINT" useradd -m -s /bin/bash -G sudo "$USERNAME" 2>/dev/null || true
echo "$USERNAME:$PASSWORD" | chroot "$MOUNT_POINT" chpasswd

# Write immutable config (used by immutable CLI for username)
cat > "$MOUNT_POINT/etc/immutable.conf" <<CONF
# Immutable Pop!_OS configuration
USERNAME=$USERNAME
CONF

# Passwordless sudo inside chroots (overlays snapshot this)
cat > "$MOUNT_POINT/etc/sudoers.d/immutable-$USERNAME" <<SUDOERS
$USERNAME ALL=(ALL) NOPASSWD: ALL
SUDOERS
chmod 0440 "$MOUNT_POINT/etc/sudoers.d/immutable-$USERNAME"

# ── Kernelstub config (must exist before apt postinst runs) ──

mkdir -p "$MOUNT_POINT/etc/kernelstub"
cat > "$MOUNT_POINT/etc/kernelstub/configuration" <<'KERNELSTUB'
{
  "default": {
    "kernel_options": ["quiet", "loglevel=0", "systemd.show_status=false", "splash", "rootflags=subvol=@overlay-init"],
    "esp_path": "/boot/efi",
    "setup_loader": false,
    "manage_mode": false,
    "force_update": false,
    "live_mode": false,
    "config_rev": 3
  },
  "user": {
    "kernel_options": ["quiet", "loglevel=0", "systemd.show_status=false", "splash", "rootflags=subvol=@overlay-init"],
    "esp_path": "/boot/efi",
    "setup_loader": true,
    "manage_mode": true,
    "force_update": false,
    "live_mode": false,
    "config_rev": 3
  }
}
KERNELSTUB

# ── Detect hardware ──

HW_PACKAGES="pop-desktop linux-system76 system76-driver system76-power efibootmgr systemd-boot"
NVIDIA_BOOT_OPTS=""
if lspci 2>/dev/null | grep -qi nvidia; then
    echo "NVIDIA GPU detected"
    HW_PACKAGES="$HW_PACKAGES system76-driver-nvidia"
    NVIDIA_BOOT_OPTS="nvidia-drm.modeset=1"
fi

# ── Install packages ──

chroot "$MOUNT_POINT" dpkg --add-architecture i386
chroot "$MOUNT_POINT" env DEBIAN_FRONTEND=noninteractive apt-get update -y
chroot "$MOUNT_POINT" env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    initramfs-tools-core initramfs-tools \
    locales console-setup

chroot "$MOUNT_POINT" env DEBIAN_FRONTEND=noninteractive apt-get install -y $HW_PACKAGES

chroot "$MOUNT_POINT" env DEBIAN_FRONTEND=noninteractive dpkg --configure -a
chroot "$MOUNT_POINT" env DEBIAN_FRONTEND=noninteractive apt-get install -f -y

# ── fstab ──

ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
EFI_UUID=$(blkid -s UUID -o value "$PART_EFI")
SWAP_UUID=$(blkid -s UUID -o value "$PART_SWAP")

cat > "$MOUNT_POINT/etc/fstab" <<FSTAB
UUID=$ROOT_UUID  /            btrfs  defaults,noatime,compress=zstd:1,ssd,subvol=@overlay-init  0 0
UUID=$ROOT_UUID  /pool        btrfs  defaults,noatime,subvolid=5                                0 0
UUID=$EFI_UUID   /boot/efi    vfat   defaults,noatime,fmask=0022,dmask=0022,codepage=437        0 2
/dev/mapper/cryptswap  none  swap   sw                                                          0 0
FSTAB

# ── Initramfs + systemd-boot ──

echo "btrfs" >> "$MOUNT_POINT/etc/initramfs-tools/modules"

echo "Installing systemd-boot..."
chroot "$MOUNT_POINT" bootctl --path=/boot/efi install --no-variables

# Create UEFI boot entry
echo "Creating UEFI boot entry..."
chroot "$MOUNT_POINT" efibootmgr --create \
    --disk "$TARGET_DEVICE" --part 1 \
    --write-signature --label "Pop!_OS" \
    --loader '\EFI\systemd\systemd-bootx64.efi' || echo "WARNING: efibootmgr failed"

# Regenerate initramfs (triggers zz-kernelstub which copies kernel/initrd to ESP)
echo "Generating initramfs..."
chroot "$MOUNT_POINT" update-initramfs -c -k all

# ── Clean up stale boot entries from live ISO ──

echo "Cleaning up stale boot entries..."
cd "$MOUNT_POINT/boot/efi/loader/entries" 2>/dev/null || true
# Remove any entries with live ISO options
for entry in *.conf; do
    [ -f "$entry" ] || continue
    if grep -qE 'boot=casper|live-media-path|hostname=pop-os|username=pop-os' "$entry" 2>/dev/null; then
        echo "  Removing stale entry: $entry"
        rm -f "$entry"
    fi
done
cd - >/dev/null

# ── Ensure correct kernelstub boot entry exists ──

echo "Configuring boot entry..."
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")

# Build kernel options
KERNEL_OPTS="root=UUID=$ROOT_UUID ro quiet splash loglevel=0 systemd.show_status=false rootflags=subvol=@overlay-init"
if [ -n "$NVIDIA_BOOT_OPTS" ]; then
    KERNEL_OPTS="$KERNEL_OPTS $NVIDIA_BOOT_OPTS"
fi

# Get kernel version
KVER=$(ls "$MOUNT_POINT/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's|.*/vmlinuz-||')
if [ -z "$KVER" ]; then
    KVER=$(ls "$MOUNT_POINT/boot/efi/EFI/Pop_OS-"*/vmlinuz.efi 2>/dev/null | head -1 | sed 's|.*/Pop_OS-[^/]*/||')
fi

# Remove any duplicate Pop_OS-current entries and create a clean one
ESP_ENTRIES="$MOUNT_POINT/boot/efi/loader/entries"
if [ -d "$ESP_ENTRIES" ]; then
    # Remove all Pop_OS-current.conf entries (they may be stale/duplicate)
    rm -f "$ESP_ENTRIES/Pop_OS-current.conf"
    
    # Create clean entry
    cat > "$ESP_ENTRIES/Pop_OS-current.conf" <<ENTRY
title Pop!_OS
linux /EFI/Pop_OS-${ROOT_UUID}/vmlinuz.efi
initrd /EFI/Pop_OS-${ROOT_UUID}/initrd.img
options ${KERNEL_OPTS}
ENTRY
    echo "Created: $ESP_ENTRIES/Pop_OS-current.conf"
fi

# ── Create immutable.conf for overlay switching ──

if [ -d "$ESP_ENTRIES" ]; then
    cat > "$ESP_ENTRIES/immutable.conf" <<ENTRY
title Immutable (overlay-init)
linux /EFI/Pop_OS-${ROOT_UUID}/vmlinuz.efi
initrd /EFI/Pop_OS-${ROOT_UUID}/initrd.img
options root=UUID=$ROOT_UUID ro quiet loglevel=0 systemd.show_status=false splash rootflags=subvol=@overlay-init ${NVIDIA_BOOT_OPTS}
ENTRY
    echo "Created: $ESP_ENTRIES/immutable.conf"

    # Recovery boot entry — boots @overlay-recovery as fallback
    cat > "$ESP_ENTRIES/recovery.conf" <<ENTRY
title Pop!_OS Recovery
linux /EFI/Pop_OS-${ROOT_UUID}/vmlinuz.efi
initrd /EFI/Pop_OS-${ROOT_UUID}/initrd.img
options root=UUID=$ROOT_UUID ro quiet splash loglevel=0 systemd.show_status=false rootflags=subvol=@overlay-recovery ${NVIDIA_BOOT_OPTS}
ENTRY
    echo "Created: $ESP_ENTRIES/recovery.conf"

    # Previous kernel boot entry — safety net for kernel updates
    cat > "$ESP_ENTRIES/previous.conf" <<ENTRY
title Pop!_OS (previous kernel)
linux /EFI/Pop_OS-${ROOT_UUID}/vmlinuz-previous.efi
initrd /EFI/Pop_OS-${ROOT_UUID}/initrd.img-previous
options ${KERNEL_OPTS}
ENTRY
    echo "Created: $ESP_ENTRIES/previous.conf"
fi

# ── Set loader timeout ──

if [ -f "$MOUNT_POINT/boot/efi/loader/loader.conf" ]; then
    # timeout 0 = boot immediately, no menu. Hold Shift during boot to see menu.
    sed -i 's/^timeout .*/timeout 0/' "$MOUNT_POINT/boot/efi/loader/loader.conf" 2>/dev/null || true
    if ! grep -q '^timeout' "$MOUNT_POINT/boot/efi/loader/loader.conf" 2>/dev/null; then
        echo "timeout 0" >> "$MOUNT_POINT/boot/efi/loader/loader.conf"
    fi
    # Set default boot entry (normal boot, not recovery)
    sed -i 's|^default .*|default Pop_OS-current.conf|' "$MOUNT_POINT/boot/efi/loader/loader.conf" 2>/dev/null || true
    if ! grep -q '^default' "$MOUNT_POINT/boot/efi/loader/loader.conf" 2>/dev/null; then
        echo "default Pop_OS-current.conf" >> "$MOUNT_POINT/boot/efi/loader/loader.conf"
    fi
    echo "Boot menu: hidden (hold Shift during boot for recovery menu)"
fi

# Verify ESP has the required files
echo "Verifying ESP contents..."
for f in \
    "EFI/systemd/systemd-bootx64.efi" \
    "EFI/BOOT/BOOTX64.EFI" \
    "loader/loader.conf"; do
    if [ ! -f "$MOUNT_POINT/boot/efi/$f" ]; then
        echo "ERROR: Missing ESP file: $f"
    fi
done

# Verify boot entry exists
if ! ls "$MOUNT_POINT"/boot/efi/loader/entries/*.conf >/dev/null 2>&1; then
    echo "ERROR: No boot entries found in /boot/efi/loader/entries/"
fi

# Verify loader.conf default
if [ -f "$MOUNT_POINT/boot/efi/loader/loader.conf" ]; then
    echo "loader.conf contents:"
    cat "$MOUNT_POINT/boot/efi/loader/loader.conf"
fi

echo "Boot entries:"
ls -la "$MOUNT_POINT/boot/efi/loader/entries/" 2>/dev/null || true

# ── Mount pool to access @data for daemon/CLI installation ──

mkdir -p "$MOUNT_POINT/pool"
mount -o subvolid=5 "$PART_ROOT" "$MOUNT_POINT/pool"

# ── Install immutable CLI to @data (shared across all overlays) ──

mkdir -p "$MOUNT_POINT/pool/@data/immutable/bin"
cp "$(dirname "$0")/immutable" "$MOUNT_POINT/pool/@data/immutable/bin/immutable"
chmod +x "$MOUNT_POINT/pool/@data/immutable/bin/immutable"

# Also install directly to @base as baseline (bind mount from @data overrides at boot)
cp "$(dirname "$0")/immutable" "$MOUNT_POINT/usr/local/bin/immutable"
chmod +x "$MOUNT_POINT/usr/local/bin/immutable"

# Bash completions in @data
mkdir -p "$MOUNT_POINT/pool/@data/immutable/bash-completion"
cp "$(dirname "$0")/immutable.bash" "$MOUNT_POINT/pool/@data/immutable/bash-completion/immutable"

# Also install directly to @base
cp "$(dirname "$0")/immutable.bash" "$MOUNT_POINT/usr/share/bash-completion/completions/immutable"

# Manpage in @data
mkdir -p "$MOUNT_POINT/pool/@data/immutable/man"
gzip -c "$(dirname "$0")/immutable.1" > "$MOUNT_POINT/pool/@data/immutable/man/immutable.1.gz"

# Also install directly to @base
mkdir -p "$MOUNT_POINT/usr/share/man/man1"
gzip -c "$(dirname "$0")/immutable.1" > "$MOUNT_POINT/usr/share/man/man1/immutable.1.gz"

# ── Install immutable daemon to @data (shared across all overlays) ──

mkdir -p "$MOUNT_POINT/pool/@data/immutable/daemon"
cp "$(dirname "$0")/daemon/"*.py "$MOUNT_POINT/pool/@data/immutable/daemon/"
touch "$MOUNT_POINT/pool/@data/immutable/daemon/__init__.py"

# ── Install hooks to @data (protected source for overlay reinstalls) ──

HOOKS_SRC="$(dirname "$0")/hooks"

for dir in kernel-postinst.d initramfs-post-update.d; do
    for hook in "$HOOKS_SRC/$dir"/*; do
        [ -f "$hook" ] || continue
        install -Dm755 "$hook" "$MOUNT_POINT/pool/@data/immutable/hooks/$dir/$(basename "$hook")"
    done
done

install -Dm755 "$HOOKS_SRC/immutable-hook-reinstall" \
    "$MOUNT_POINT/pool/@data/immutable/hooks/immutable-hook-reinstall"

# Install active hooks into @base (these get overwritten by reinstall in overlays)
install -Dm755 "$HOOKS_SRC/kernel-postinst.d/zz-kernelstub" \
    "$MOUNT_POINT/etc/kernel/postinst.d/zz-kernelstub"
install -Dm755 "$HOOKS_SRC/kernel-postinst.d/zz-systemd-boot" \
    "$MOUNT_POINT/etc/kernel/postinst.d/zz-systemd-boot"
install -Dm755 "$HOOKS_SRC/initramfs-post-update.d/zz-kernelstub" \
    "$MOUNT_POINT/etc/initramfs/post-update.d/zz-kernelstub"
install -Dm755 "$HOOKS_SRC/initramfs-post-update.d/systemd-boot" \
    "$MOUNT_POINT/etc/initramfs/post-update.d/systemd-boot"

install -Dm644 "$HOOKS_SRC/dpkg-immutable" \
    "$MOUNT_POINT/etc/dpkg/dpkg.cfg.d/99-immutable"
install -Dm644 "$HOOKS_SRC/immutable-hooks-apt-hook" \
    "$MOUNT_POINT/etc/apt/apt.conf.d/99-immutable-hooks"

# Boot recovery scripts in @data
cp "$(dirname "$0")/immutable-boot-counter.sh" "$MOUNT_POINT/pool/@data/immutable/immutable-boot-counter.sh"
chmod +x "$MOUNT_POINT/pool/@data/immutable/immutable-boot-counter.sh"
cp "$(dirname "$0")/immutable-healthcheck.sh" "$MOUNT_POINT/pool/@data/immutable/immutable-healthcheck.sh"
chmod +x "$MOUNT_POINT/pool/@data/immutable/immutable-healthcheck.sh"

# ── Bind mount service: makes @data available at standard paths ──

cat > "$MOUNT_POINT/etc/systemd/system/immutable-data-mount.service" <<'UNIT'
[Unit]
Description=Bind-mount immutable data from @data
After=local-fs.target systemd-remount-fs.service
Before=immutable-daemon.socket immutable-boot-counter.service immutable-healthcheck.service
RequiresMountsFor=/pool
ConditionPathExists=/pool/@data/immutable

[Service]
Type=oneshot
ExecStart=/bin/mount --bind /pool/@data/immutable /usr/lib/immutable
ExecStart=/bin/mount --bind /pool/@data/immutable/bin/immutable /usr/local/bin/immutable
ExecStart=/bin/mount --bind /pool/@data/immutable/bash-completion/immutable /usr/share/bash-completion/completions/immutable
ExecStart=/bin/mount --bind /pool/@data/immutable/man/immutable.1.gz /usr/share/man/man1/immutable.1.gz
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
chroot "$MOUNT_POINT" systemctl enable immutable-data-mount.service 2>/dev/null || true

# ── Daemon and system services ──

chroot "$MOUNT_POINT" groupadd immutable 2>/dev/null || true
chroot "$MOUNT_POINT" usermod -aG immutable USERNAME2>/dev/null || true

cp "$(dirname "$0")/immutable-daemon.service" "$MOUNT_POINT/etc/systemd/system/"
cp "$(dirname "$0")/immutable-daemon.socket" "$MOUNT_POINT/etc/systemd/system/"

cp "$(dirname "$0")/tmpfiles-immutable.conf" "$MOUNT_POINT/etc/tmpfiles.d/immutable.conf"
mkdir -p "$MOUNT_POINT/run/immutable"

chroot "$MOUNT_POINT" systemctl enable immutable-daemon.socket 2>/dev/null || true

# Fix devpts ptmx permissions
cat > "$MOUNT_POINT/etc/systemd/system/fix-devpts.service" <<'UNIT'
[Unit]
Description=Fix devpts ptmxmode for PTY allocation
After=systemd-udevd.service
Before=immutable-daemon.socket

[Service]
Type=oneshot
ExecStart=/bin/mount -o remount,ptmxmode=0666 /dev/pts
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
UNIT
chroot "$MOUNT_POINT" systemctl enable fix-devpts.service 2>/dev/null || true

cp "$(dirname "$0")/immutable-boot-counter.service" "$MOUNT_POINT/etc/systemd/system/"
cp "$(dirname "$0")/immutable-healthcheck.service" "$MOUNT_POINT/etc/systemd/system/"

chroot "$MOUNT_POINT" systemctl enable immutable-boot-counter.service 2>/dev/null || true
chroot "$MOUNT_POINT" systemctl enable immutable-healthcheck.service 2>/dev/null || true

echo "Installed immutable daemon and services"

# ── Unmount chroot ──

umount -R "$MOUNT_POINT/dev" 2>/dev/null || true
umount -R "$MOUNT_POINT/proc" 2>/dev/null || true
umount -R "$MOUNT_POINT/sys" 2>/dev/null || true
umount "$MOUNT_POINT/run" 2>/dev/null || true

# ── Unmount @base and lock ──

umount "$MOUNT_POINT/boot/efi" 2>/dev/null || true
umount "$MOUNT_POINT/pool" 2>/dev/null || true
umount "$MOUNT_POINT" 2>/dev/null || true

mount -o subvol=@base "$PART_ROOT" "$MOUNT_POINT"
btrfs property set "$MOUNT_POINT" ro true
umount "$MOUNT_POINT"

echo "@base locked (read-only)"

# ── Snapshot @base → @overlay-init and @overlay-recovery ──

mkdir -p "$MOUNT_POINT"
mount "$PART_ROOT" "$MOUNT_POINT"

btrfs subvolume snapshot "$MOUNT_POINT/@base" "$MOUNT_POINT/@overlay-init"
btrfs subvolume snapshot "$MOUNT_POINT/@base" "$MOUNT_POINT/@overlay-recovery"
btrfs property set "$MOUNT_POINT/@overlay-recovery" ro true

echo "Created @overlay-init and @overlay-recovery from @base"

# Initialize boot counter in @data
echo "0" > "$MOUNT_POINT/@data/boot-counter"
echo "@overlay-init" > "$MOUNT_POINT/@data/boot-last-overlay"

umount "$MOUNT_POINT"

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
