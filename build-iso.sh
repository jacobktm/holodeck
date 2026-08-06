#!/bin/bash
set -euo pipefail

# Full ISO build orchestration:
#   1. build the Rust immutable CLI        (build-rust.sh)
#   2. assemble the immutable data bundle  (build-bundle.sh)
#   3. build classic distinst debs         (build-distinst.sh)
#        — the install engine; pop-installer drives it via the C API
#   4. build pop-installer debs            (build-installer.sh)
#   5. stage the override debs and run the forked ISO build
#
# Only classic distinst and pop-installer are forked (the immutable port
# lives there); distinst-v2 stays stock from apt since pop-installer merely
# uses it for live-session disk discovery.
#
# The iso fork reads LOCAL_DEBS (dir of .deb) and IMMUTABLE_BUNDLE (dir) as
# make variables; chroot.mk copies them into the live rootfs and replaces the
# stock pop-os distinst/pop-installer with ours.
#
# APT_PROXY (optional) routes the ISO build chroot's deb downloads through a
# proxy. Resolution order: APT_PROXY / APT_PROXY_URL env vars, then the
# /etc/immutable-apt-proxy.conf APT_PROXY= line (same convention as the
# booted immutable system).

cd "$(dirname "$0")"

CLEAN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=1 ;;
        *) echo "Usage: $0 [--clean]" >&2; exit 1 ;;
    esac
    shift
done

DISTRO_CODE="${DISTRO_CODE:-pop-os}"
DISTRO_VERSION="${DISTRO_VERSION:-24.04}"
# NVIDIA=0 builds the generic (intel) ISO, NVIDIA=1 builds the NVIDIA ISO,
# NVIDIA=both builds both variants sequentially (each in its own build tree).
NVIDIA="${NVIDIA:-both}"

if [ "$CLEAN" -eq 1 ]; then
    echo "═══════════════════════════════════════════════"
    echo " Cleaning all build artifacts"
    echo "═══════════════════════════════════════════════"
    # Unmount any leftover chroot/live mounts before removing the trees
    for partial in forks/iso/build/*/*/*/*/*.partial; do
        [ -e "$partial" ] || continue
        forks/iso/scripts/unmount.sh "$partial" >/dev/null 2>&1 || true
    done
    sudo rm -rf forks/iso/build
    rm -rf dist/debs dist/iso-debs dist/immutable-bundle
    rm -rf build
    rm -rf rust/target
    echo "==> Cleaned."
fi

APT_PROXY="${APT_PROXY:-${APT_PROXY_URL:-}}"
if [ -z "$APT_PROXY" ] && [ -f /etc/immutable-apt-proxy.conf ]; then
    APT_PROXY="$(sed -n 's/^APT_PROXY=//p' /etc/immutable-apt-proxy.conf | head -1 || true)"
fi
export APT_PROXY
if [ -n "$APT_PROXY" ]; then
    echo "==> ISO build deb downloads will use apt proxy: $APT_PROXY"
fi

export DEBS="$(pwd)/dist/debs"
export BUNDLE="$(pwd)/dist/immutable-bundle"
export ISO_DEBS="$(pwd)/dist/iso-debs"

case "$NVIDIA" in
    0|1) NVIDIA_BUILDS=("$NVIDIA") ;;
    both) NVIDIA_BUILDS=(0 1) ;;
    *) echo "ERROR: NVIDIA must be 0, 1, or both (got '$NVIDIA')" >&2; exit 1 ;;
esac

echo "═══════════════════════════════════════════════"
echo " 1/5  Building Rust immutable CLI"
echo "═══════════════════════════════════════════════"
./build-rust.sh

echo "═══════════════════════════════════════════════"
echo " 2/5  Assembling immutable data bundle"
echo "═══════════════════════════════════════════════"
./build-bundle.sh

echo "═══════════════════════════════════════════════"
echo " 3/5  Building distinst debs"
echo "═══════════════════════════════════════════════"
./build-distinst.sh

echo "═══════════════════════════════════════════════"
echo " 4/5  Building pop-installer debs"
echo "═══════════════════════════════════════════════"
./build-installer.sh

echo "═══════════════════════════════════════════════"
echo " 5/5  Staging override debs + building ISO"
echo "      ($DISTRO_CODE $DISTRO_VERSION, variants: ${NVIDIA_BUILDS[*]})"
echo "═══════════════════════════════════════════════"
rm -rf "$ISO_DEBS"
mkdir -p "$ISO_DEBS"
cp "$DEBS"/distinst_*.deb "$ISO_DEBS"/
cp "$DEBS"/libdistinst_*.deb "$ISO_DEBS"/
cp "$DEBS"/pop-installer_*.deb "$ISO_DEBS"/
ls -1 "$ISO_DEBS"

for nv in "${NVIDIA_BUILDS[@]}"; do
    echo "── Building ISO variant: NVIDIA=$nv ──"
    make -C forks/iso \
        DISTRO_CODE="$DISTRO_CODE" \
        DISTRO_VERSION="$DISTRO_VERSION" \
        NVIDIA="$nv" \
        APT_PROXY="$APT_PROXY" \
        LOCAL_DEBS="$ISO_DEBS" \
        IMMUTABLE_BUNDLE="$BUNDLE" \
        iso
done

BUILD_NUMBER_FILE=".iso-build-number"
BUILD_NUMBER="$(cat "$BUILD_NUMBER_FILE" 2>/dev/null || echo 0)"
BUILD_NUMBER=$((BUILD_NUMBER + 1))
echo "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"

echo "==> Gathering ISOs into build/ (build #$BUILD_NUMBER)"
mkdir -p build
for iso in forks/iso/build/"$DISTRO_CODE"/"$DISTRO_VERSION"/*/*/*.iso; do
    [ -e "$iso" ] || continue
    base="$(basename "$iso" .iso)"
    cp -v "$iso" "build/${base}_b${BUILD_NUMBER}.iso"
done

echo "==> Built ISOs:"
ls -1 build/"$DISTRO_CODE"_*.iso 2>/dev/null || true
