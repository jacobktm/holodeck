#!/bin/bash
set -euo pipefail

# ── Build immutable Pop!_OS base rootfs ──
# Follows pop-os/iso build patterns for repo setup and package installation

VERSION="0.2.0"
DISTRO="noble"
MIRROR="http://apt.pop-os.org/ubuntu"
ARCH="amd64"
BUILD_DIR="${BUILD_DIR:-/tmp/immutable-build}"
ROOTFS_DIR="$BUILD_DIR/rootfs"

# Pop!_OS repo URIs and keys (matching iso/config/pop-os/*.mk)
RELEASE_URI="http://apt.pop-os.org/release"
APPS_URI="http://apt.pop-os.org/proprietary"
POP_KEY="/etc/apt/trusted.gpg.d/pop-keyring-2017-archive.gpg"
UBUNTU_KEY="/etc/apt/trusted.gpg.d/ubuntu-keyring-2018-archive.gpg"

# ── Package lists (matching iso/config/pop-os/22.04.mk structure) ──

# Base packages — minimal desktop session, no hardware-specific packages
DISTRO_PKGS="systemd-sysv init dbus sudo network-manager \
    cosmic-session cosmic-term"

# Utilities
UTIL_PKGS="btrfs-progs vim less git curl wget htop"

# Packages to remove (from iso/config/pop-os/22.04.mk)
RM_PKGS="snapd ubuntu-session ubuntu-wallpapers"

# ── Helpers ──

cleanup() {
    umount -R "$ROOTFS_DIR/dev" 2>/dev/null || true
    umount -R "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount -R "$ROOTFS_DIR/sys" 2>/dev/null || true
    umount "$ROOTFS_DIR/run" 2>/dev/null || true
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ""; echo "══════════════════════════════════════"; echo " $1"; echo "══════════════════════════════════════"; echo ""; }

# Check for apt-cacher-ng proxy
APT_PROXY=""
if ping -c 1 -W 2 PROXY_HOST &>/dev/null; then
    APT_PROXY="http://PROXY_HOST:3142"
    echo "APT proxy detected: $APT_PROXY"
fi

usage() {
    cat <<EOF
build-base.sh v${VERSION} — Build immutable Pop!_OS base rootfs

Usage:
  ./build-base.sh [OPTIONS]

Options:
  --mirror URL       APT mirror (default: $MIRROR)
  --distro NAME      Ubuntu codename (default: $DISTRO)
  --output PATH      Output tarball path
  --help             Show this help

Output:
  $BUILD_DIR/base-rootfs.tar.zst (base image)
EOF
}

# ── Parse args ──

OUTPUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --mirror) MIRROR="$2"; shift 2 ;;
        --distro) DISTRO="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Must run as root"

# ── Repo setup (following pop-os/iso repos.sh pattern) ──

create_sources_file() {
    # Create a .sources file in DEB822 format
    # Usage: create_sources_file <filename> <name> <types> <uris> <suites> <components> [signed-by]
    local filename="$1" name="$2" types="$3" uris="$4" suites="$5" components="$6" signed_by="${7:-}"

    cat > "$ROOTFS_DIR/etc/apt/sources.list.d/$filename" <<SOURCES
X-Repolib-Name: ${name}
Enabled: yes
Architectures: amd64 i386
Types: ${types}
URIs: ${uris}
Suites: ${suites}
Components: ${components}
SOURCES

    if [ -n "$signed_by" ]; then
        echo "Signed-By: ${signed_by}" >> "$ROOTFS_DIR/etc/apt/sources.list.d/$filename"
    fi
}

# ── Chroot functions ──

setup_chroot() {
    mount --bind /dev "$ROOTFS_DIR/dev"
    mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
    mount -t proc proc "$ROOTFS_DIR/proc"
    mount --rbind /sys "$ROOTFS_DIR/sys"
    mount --make-rslave "$ROOTFS_DIR/sys"
    mount --bind /run "$ROOTFS_DIR/run"
}

teardown_chroot() {
    umount -R "$ROOTFS_DIR/dev" 2>/dev/null || true
    umount -R "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount -R "$ROOTFS_DIR/sys" 2>/dev/null || true
    umount "$ROOTFS_DIR/run" 2>/dev/null || true
}

run_in_chroot() {
    # Run a command in chroot with proper environment
    chroot "$ROOTFS_DIR" /bin/bash -e -c "$1"
}

configure_rootfs_apt() {
    # DNS (matching iso/scripts/chroot.sh)
    mkdir -p "$ROOTFS_DIR/run/systemd/resolve"
    echo "nameserver 1.1.1.1" > "$ROOTFS_DIR/run/systemd/resolve/stub-resolv.conf"
    ln -sf ../run/systemd/resolve/stub-resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

    # Set up clean APT sources
    mkdir -p "$ROOTFS_DIR/etc/apt/sources.list.d" "$ROOTFS_DIR/etc/apt/trusted.gpg.d"

    # Copy GPG keys from host
    cp /etc/apt/trusted.gpg.d/pop-keyring-2017-archive.gpg "$ROOTFS_DIR/etc/apt/trusted.gpg.d/"
    cp /etc/apt/trusted.gpg.d/ubuntu-keyring-2018-archive.gpg "$ROOTFS_DIR/etc/apt/trusted.gpg.d/" 2>/dev/null || true

    # Keep debootstrap's sources.list for initial installs
    # (needed for ca-certificates before DEB822 repos are available)
}

configure_rootfs_repos() {
    # Now that ca-certificates is installed, switch to DEB822 format repos
    # Truncate sources.list (matching iso pattern)
    truncate --size=0 "$ROOTFS_DIR/etc/apt/sources.list"

    # Create DEB822 format repos (matching iso/config/pop-os/22.04.mk)
    # system.sources — Ubuntu mirror
    create_sources_file "system.sources" \
        "Pop_OS System Sources" \
        "deb deb-src" \
        "$MIRROR" \
        "$DISTRO $DISTRO-security $DISTRO-updates $DISTRO-backports" \
        "main restricted universe multiverse" \
        "$UBUNTU_KEY"

    # Pop!_OS release sources
    create_sources_file "pop-os-release.sources" \
        "Pop_OS Release Sources" \
        "deb deb-src" \
        "$RELEASE_URI" \
        "$DISTRO" \
        "main" \
        "$POP_KEY"

    # Note: pop-default-settings creates pop-os-apps.sources itself
    # Don't create it here — it expects a hardcoded filename
}

configure_rootfs_system() {
    # Kernelstub configuration (matching iso/data/amd64/kernelstub)
    mkdir -p "$ROOTFS_DIR/etc/kernelstub"
    cat > "$ROOTFS_DIR/etc/kernelstub/configuration" <<'KERNELSTUB'
{
    "extensions": {
        "initrd": {
            "systemd": true
        }
    },
    "kernel": {
        "copy_default": true,
        "replace_default": false,
        "cmdline": [
            "quiet"
        ]
    },
    "esp": {
        "path": "/boot/efi",
        "mount_point": "/boot/efi"
    },
    "initrd": {
        "microcode": true,
        "modules": [],
        "cleanup": true
    },
    "update": {
        "refresh": true,
        "auto_refresh": false
    }
}
KERNELSTUB

    # Hostname
    echo "immutable-pop" > "$ROOTFS_DIR/etc/hostname"

    # Remove cups-filters parallel port config — modules don't exist in
    # the debootstrap rootfs, causing systemd-modules-load.service to
    # timeout for 90s during boot.
    rm -f "$ROOTFS_DIR/etc/modules-load.d/cups-filters.conf"

    # Locale
    echo "en_US.UTF-8 UTF-8" > "$ROOTFS_DIR/etc/locale.gen"
    chroot "$ROOTFS_DIR" locale-gen 2>/dev/null || true

    # Timezone
    ln -sf /usr/share/zoneinfo/UTC "$ROOTFS_DIR/etc/localtime"

    # Root password (user created during install)
    echo "root:root" | chroot "$ROOTFS_DIR" chpasswd

    # Enable services
    chroot "$ROOTFS_DIR" systemctl enable NetworkManager 2>/dev/null || true
    chroot "$ROOTFS_DIR" systemctl enable dbus 2>/dev/null || true
}

install_base_packages() {
    # Temporary proxy for build speed — cleaned up before packaging
    if [ -n "$APT_PROXY" ]; then
        mkdir -p "$ROOTFS_DIR/etc/apt/apt.conf.d"
        echo "Acquire::http::Proxy \"$APT_PROXY\";" > "$ROOTFS_DIR/etc/apt/apt.conf.d/99proxy"
    fi

    # ca-certificates first (needed for HTTPS)
    echo "Installing ca-certificates..."
    run_in_chroot "dpkg --add-architecture i386"
    run_in_chroot "apt-get update -o Dir::Etc::sourceparts=/dev/null"
    run_in_chroot "apt-get install -y ca-certificates"

    # Now switch to DEB822 format repos
    configure_rootfs_repos

    # Update and upgrade (matching chroot.sh pattern)
    echo "Updating package lists..."
    run_in_chroot "apt-get update -y"
    run_in_chroot "apt-get upgrade -y --allow-downgrades"

    # Install base packages
    echo "Installing base packages..."
    run_in_chroot "apt-get install -y $DISTRO_PKGS" || true
    run_in_chroot "dpkg --configure -a" || true

    # Install utilities
    echo "Installing utilities..."
    run_in_chroot "apt-get install -y $UTIL_PKGS"

    # Remove unwanted packages (matching iso RM_PKGS)
    echo "Removing unwanted packages..."
    run_in_chroot "apt-get purge -y $RM_PKGS" || true

    # Cleanup
    run_in_chroot "apt-get autoremove --purge -y"
    run_in_chroot "apt-get clean -y"

    # Remove temporary files
    rm -rf "$ROOTFS_DIR"/{tmp/*,var/tmp/*,var/cache/apt/archives/*.deb}

    # Install immutable-aware hooks (after packages — stock hooks work fine in base build)
    echo "Installing immutable-aware hooks..."
    HOOKS_SRC="$(dirname "$0")/hooks"

    # Install hooks to protected source directory (for dpkg-triggered reinstall in overlays)
    for dir in kernel-postinst.d initramfs-post-update.d; do
        for hook in "$HOOKS_SRC/$dir"/*; do
            [ -f "$hook" ] || continue
            install -Dm755 "$hook" "$ROOTFS_DIR/usr/lib/immutable/hooks/$dir/$(basename "$hook")"
        done
    done

    # Install our hooks to active locations (overwrites stock versions)
    install -Dm755 "$HOOKS_SRC/kernel-postinst.d/zz-kernelstub" \
        "$ROOTFS_DIR/etc/kernel/postinst.d/zz-kernelstub"
    install -Dm755 "$HOOKS_SRC/kernel-postinst.d/zz-systemd-boot" \
        "$ROOTFS_DIR/etc/kernel/postinst.d/zz-systemd-boot"
    install -Dm755 "$HOOKS_SRC/initramfs-post-update.d/zz-kernelstub" \
        "$ROOTFS_DIR/etc/initramfs/post-update.d/zz-kernelstub"
    install -Dm755 "$HOOKS_SRC/initramfs-post-update.d/systemd-boot" \
        "$ROOTFS_DIR/etc/initramfs/post-update.d/systemd-boot"

    # Install dpkg config: auto-keep our modified hooks in overlay chroots
    install -Dm644 "$HOOKS_SRC/dpkg-immutable" \
        "$ROOTFS_DIR/etc/dpkg/dpkg.cfg.d/99-immutable"

    # Install dpkg hook — reinstalls our hooks after dpkg invocations in overlay chroots
    install -Dm644 "$HOOKS_SRC/immutable-hooks-apt-hook" \
        "$ROOTFS_DIR/etc/apt/apt.conf.d/99-immutable-hooks"
    # Also keep source copy for reinstall hook to propagate
    install -Dm644 "$HOOKS_SRC/immutable-hooks-apt-hook" \
        "$ROOTFS_DIR/usr/lib/immutable/immutable-hooks-apt-hook"

    # Bash prompt overlay indicator
    install -Dm644 "$HOOKS_SRC/../immutable-prompt.sh" \
        "$ROOTFS_DIR/etc/profile.d/immutable-prompt.sh"

    # Install reinstall script to protected location
    install -Dm755 "$HOOKS_SRC/immutable-hook-reinstall" \
        "$ROOTFS_DIR/usr/lib/immutable/hooks/immutable-hook-reinstall"

    # Install systemd service unit for reinstall hook propagation
    install -Dm644 "$HOOKS_SRC/../immutable-data-mount.service" \
        "$ROOTFS_DIR/usr/lib/immutable/immutable-data-mount.service"

    # Install boot counter and healthcheck (fallback copies — @data bind-mount overrides)
    install -Dm755 "$HOOKS_SRC/../immutable-boot-counter.sh" \
        "$ROOTFS_DIR/usr/lib/immutable/immutable-boot-counter.sh"
    install -Dm755 "$HOOKS_SRC/../immutable-healthcheck.sh" \
        "$ROOTFS_DIR/usr/lib/immutable/immutable-healthcheck.sh"

    # Apt proxy auto-detect — dynamic probe at apt runtime
    # Install to hooks source dir so reinstall can re-provision
    install -Dm755 "$HOOKS_SRC/apt-proxy-detect" \
        "$ROOTFS_DIR/usr/lib/immutable/hooks/apt-proxy-detect"
    install -Dm755 "$HOOKS_SRC/apt-proxy-detect.sh" \
        "$ROOTFS_DIR/usr/lib/immutable/hooks/apt-proxy-detect.sh"
    # Install to runtime location as well
    install -Dm755 "$HOOKS_SRC/apt-proxy-detect" \
        "$ROOTFS_DIR/usr/lib/immutable/apt-proxy-detect"
    install -Dm755 "$HOOKS_SRC/apt-proxy-detect.sh" \
        "$ROOTFS_DIR/usr/lib/immutable/apt-proxy-detect.sh"
    mkdir -p "$ROOTFS_DIR/etc/apt/apt.conf.d"
    cat > "$ROOTFS_DIR/etc/apt/apt.conf.d/99-immutable-proxy" <<'APT'
Acquire::http::ProxyAutoDetect "/usr/lib/immutable/apt-proxy-detect";
APT

    # Remove temporary build proxy — installed system uses auto-detect
    rm -f "$ROOTFS_DIR/etc/apt/apt.conf.d/99proxy"
}

package_rootfs() {
    local output="$1"
    echo "Creating compressed tarball: $output"
    tar -C "$ROOTFS_DIR" -cf - . | zstd -T0 -19 -o "$output"
    local size
    size=$(du -sh "$output" | cut -f1)
    echo "  Size: $size"
}

# ── Main build logic ──

BASE_OUTPUT="$BUILD_DIR/base-rootfs.tar.zst"

if [ -n "$OUTPUT" ]; then
    BASE_OUTPUT="$OUTPUT"
fi

info "Step 1: Creating rootfs with debootstrap"

    mkdir -p "$BUILD_DIR"
    rm -rf "$ROOTFS_DIR"

    debootstrap \
        --arch="$ARCH" \
        --include="systemd systemd-sysv init dbus sudo btrfs-progs" \
        --variant=minbase \
        "$DISTRO" \
        "$ROOTFS_DIR" \
        "$MIRROR"

    info "Step 2: Configuring rootfs"

    configure_rootfs_apt
    setup_chroot

    install_base_packages
    configure_rootfs_system

    teardown_chroot

    info "Step 3: Building static immutable CLI (Rust)"

    if command -v cargo &>/dev/null; then
        local rust_src="$SCRIPT_DIR/rust"
        if [ -d "$rust_src" ]; then
            echo "Building immutable Rust binary..."
            (cd "$rust_src" && cargo build --release --no-default-features --target x86_64-unknown-linux-musl)
            local rust_binary="$rust_src/target/x86_64-unknown-linux-musl/release/immutable"
            if [ -f "$rust_binary" ]; then
                install -Dm755 "$rust_binary" "$ROOTFS_DIR/usr/bin/immutable"
                echo "  Installed: /usr/bin/immutable (static musl)"
            else
                echo "  WARNING: Rust build failed, binary not found"
            fi
        else
            echo "  WARNING: Rust source not found at $rust_src"
        fi
    else
        echo "  WARNING: cargo not found, skipping Rust binary build"
    fi

    info "Step 4: Packaging base rootfs"
    package_rootfs "$BASE_OUTPUT"

echo ""
echo "Build complete!"
echo "  Output: $BASE_OUTPUT"
echo ""
echo "Next: ./install.sh --device /dev/sdX to install to disk"
