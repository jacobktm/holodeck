#!/bin/bash
set -euo pipefail

# ── Build immutable Pop!_OS base rootfs ──

VERSION="0.1.0"
DISTRO="noble"
MIRROR="http://apt.pop-os.org/ubuntu"
ARCH="amd64"
BUILD_DIR="${BUILD_DIR:-/tmp/immutable-build}"
ROOTFS_DIR="$BUILD_DIR/rootfs"
OUTPUT="$BUILD_DIR/base-rootfs.tar.zst"

# ── Packages ──

BASE_PKGS="systemd-sysv init dbus sudo network-manager"
COSMIC_PKGS="cosmic cosmic-term pop-desktop"
KERNEL_PKGS="linux-system76 linux-headers-system76"
DRIVER_PKGS="system76-driver system76-power"
UTIL_PKGS="btrfs-progs vim less git curl wget htop"
LIVE_PKGS="casper pop-installer"

ALL_PKGS="$BASE_PKGS $COSMIC_PKGS $KERNEL_PKGS $DRIVER_PKGS $UTIL_PKGS"

# ── Helpers ──

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ""; echo "══════════════════════════════════════"; echo " $1"; echo "══════════════════════════════════════"; echo ""; }

usage() {
    cat <<EOF
build-base.sh v${VERSION} — Build immutable Pop!_OS base rootfs

Usage:
  ./build-base.sh [OPTIONS]

Options:
  --mirror URL       APT mirror (default: $MIRROR)
  --distro NAME      Ubuntu codename (default: $DISTRO)
  --output PATH      Output tarball path (default: $OUTPUT)
  --live             Include live ISO packages (casper, installer)
  --help             Show this help

Output:
  $OUTPUT — Compressed rootfs tarball
EOF
}

# ── Parse args ──

INCLUDE_LIVE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --mirror) MIRROR="$2"; shift 2 ;;
        --distro) DISTRO="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --live) INCLUDE_LIVE=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Must run as root"

if [ "$INCLUDE_LIVE" -eq 1 ]; then
    ALL_PKGS="$ALL_PKGS $LIVE_PKGS"
fi

# ── Step 1: debootstrap ──

info "Step 1: Creating rootfs with debootstrap"

mkdir -p "$BUILD_DIR"
rm -rf "$ROOTFS_DIR"

# Copy host APT sources and keys for debootstrap
TEMP_APT="$BUILD_DIR/apt"
mkdir -p "$TEMP_APT/sources.list.d" "$TEMP_APT/keyrings"

# Copy host sources
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] && cp "$f" "$TEMP_APT/sources.list.d/" 2>/dev/null || true
done

# Copy GPG keys
for f in /etc/apt/trusted.gpg /etc/apt/trusted.gpg.d/*.gpg /etc/apt/keyrings/*.gpg; do
    [ -f "$f" ] && cp "$f" "$TEMP_APT/keyrings/" 2>/dev/null || true
done

# Create debootstrap hook to copy APT config into rootfs
cat > "$BUILD_DIR/01-copy-apt.sh" <<'HOOK'
#!/bin/sh
# Copy host APT sources into debootstrap
cp /tmp/apt-setup/sources.list.d/* /rootfs/etc/apt/sources.list.d/ 2>/dev/null || true
cp /tmp/apt-setup/keyrings/* /rootfs/etc/apt/keyrings/ 2>/dev/null || true
HOOK
chmod +x "$BUILD_DIR/01-copy-apt.sh"

# Run debootstrap with minimal packages only
# Pop!_OS packages and network-manager will be installed in chroot
# to avoid dependency chain issues (polkitd needs logind)
debootstrap \
    --arch="$ARCH" \
    --include="systemd-sysv init dbus sudo btrfs-progs" \
    --variant=minbase \
    "$DISTRO" \
    "$ROOTFS_DIR" \
    "$MIRROR"

# ── Step 2: Configure the rootfs ──

info "Step 2: Configuring rootfs"

# Mount API filesystems for chroot
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
mount -t proc proc "$ROOTFS_DIR/proc"
mount --rbind /sys "$ROOTFS_DIR/sys"
mount --make-rslave "$ROOTFS_DIR/sys"
mount --bind /run "$ROOTFS_DIR/run"

# DNS
cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

# Set up clean APT sources (no host third-party repos)
mkdir -p "$ROOTFS_DIR/etc/apt/sources.list.d" "$ROOTFS_DIR/etc/apt/keyrings"

# Ubuntu base repos
cat > "$ROOTFS_DIR/etc/apt/sources.list" <<SOURCES
deb $MIRROR $DISTRO main restricted universe multiverse
deb $MIRROR $DISTRO-updates main restricted universe multiverse
deb $MIRROR $DISTRO-security main restricted universe multiverse
deb $MIRROR $DISTRO-backports main restricted universe multiverse
SOURCES

# Pop!_OS release and proprietary repos
cat > "$ROOTFS_DIR/etc/apt/sources.list.d/pop-os.sources" <<POP
Types: deb
URIs: http://apt.pop-os.org/release
Suites: $DISTRO
Components: main
Signed-By: /etc/apt/keyrings/pop-os-archive-keyring.gpg

Types: deb
URIs: http://apt.pop-os.org/proprietary
Suites: $DISTRO
Components: main
Signed-By: /etc/apt/keyrings/pop-os-archive-keyring.gpg
POP

# Install ca-certificates first (needed for HTTPS)
echo "Installing ca-certificates..."
chroot "$ROOTFS_DIR" apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list
chroot "$ROOTFS_DIR" apt-get install -y ca-certificates

# Import Pop!_OS GPG key
echo "Importing Pop!_OS GPG key..."
mkdir -p "$ROOTFS_DIR/etc/apt/keyrings"
curl -fsSL https://raw.githubusercontent.com/pop-os/pop/master/sig/pop-os-archive-keyring.gpg \
    -o "$ROOTFS_DIR/etc/apt/keyrings/pop-os-archive-keyring.gpg"

# Update APT and install packages in dependency order
echo "Installing packages..."
chroot "$ROOTFS_DIR" apt-get update

# First: logind (provides default-logind, needed by polkitd)
echo "  Installing systemd-logind..."
chroot "$ROOTFS_DIR" apt-get install -y libpam-systemd

# Second: polkitd and network-manager (depend on logind)
echo "  Installing polkitd and network-manager..."
chroot "$ROOTFS_DIR" apt-get install -y polkitd network-manager

# Third: COSMIC desktop and Pop!_OS packages
echo "  Installing COSMIC desktop..."
chroot "$ROOTFS_DIR" apt-get install -y --allow-downgrades \
    cosmic cosmic-term pop-desktop \
    linux-system76 linux-headers-system76 \
    system76-driver system76-power

# Fourth: utilities
echo "  Installing utilities..."
chroot "$ROOTFS_DIR" apt-get install -y vim less git curl wget htop

# Hostname
echo "immutable" > "$ROOTFS_DIR/etc/hostname"

# Locale
echo "en_US.UTF-8 UTF-8" > "$ROOTFS_DIR/etc/locale.gen"
chroot "$ROOTFS_DIR" locale-gen 2>/dev/null || true

# Timezone
ln -sf /usr/share/zoneinfo/UTC "$ROOTFS_DIR/etc/localtime"

# Users
chroot "$ROOTFS_DIR" useradd -m -s /bin/bash -G sudo USERNAME2>/dev/null || true
echo "USERNAME:CHANGEME" | chroot "$ROOTFS_DIR" chpasswd
echo "root:root" | chroot "$ROOTFS_DIR" chpasswd
echo "ALL ALL=(ALL) NOPASSWD: ALL" > "$ROOTFS_DIR/etc/sudoers.d/nopasswd"

# Enable services
chroot "$ROOTFS_DIR" systemctl enable NetworkManager 2>/dev/null || true
chroot "$ROOTFS_DIR" systemctl enable dbus 2>/dev/null || true

# Clean up
umount -R "$ROOTFS_DIR/dev" 2>/dev/null || true
umount -R "$ROOTFS_DIR/proc" 2>/dev/null || true
umount -R "$ROOTFS_DIR/sys" 2>/dev/null || true
umount "$ROOTFS_DIR/run" 2>/dev/null || true

# ── Step 3: Package rootfs ──

info "Step 3: Packaging rootfs"

# Remove unnecessary files to reduce size
rm -rf "$ROOTFS_DIR"/{tmp/*,var/tmp/*,var/cache/apt/archives/*.deb}

echo "Creating compressed tarball: $OUTPUT"
tar -C "$ROOTFS_DIR" -cf - . | zstd -T0 -19 -o "$OUTPUT"

SIZE=$(du -sh "$OUTPUT" | cut -f1)
echo ""
echo "Build complete!"
echo "  Output: $OUTPUT"
echo "  Size: $SIZE"
echo ""
echo "Next: ./install.sh to install to disk"
