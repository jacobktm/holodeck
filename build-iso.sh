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

cd "$(dirname "$0")"

DISTRO_CODE="${DISTRO_CODE:-pop-os}"
DISTRO_VERSION="${DISTRO_VERSION:-24.04}"
NVIDIA="${NVIDIA:-0}"

export DEBS="$(pwd)/dist/debs"
export BUNDLE="$(pwd)/dist/immutable-bundle"
export ISO_DEBS="$(pwd)/dist/iso-debs"

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
echo "      ($DISTRO_CODE $DISTRO_VERSION, NVIDIA=$NVIDIA)"
echo "═══════════════════════════════════════════════"
rm -rf "$ISO_DEBS"
mkdir -p "$ISO_DEBS"
cp "$DEBS"/distinst_*.deb "$ISO_DEBS"/
cp "$DEBS"/libdistinst_*.deb "$ISO_DEBS"/
cp "$DEBS"/pop-installer_*.deb "$ISO_DEBS"/
ls -1 "$ISO_DEBS"

exec make -C forks/iso \
    DISTRO_CODE="$DISTRO_CODE" \
    DISTRO_VERSION="$DISTRO_VERSION" \
    NVIDIA="$NVIDIA" \
    LOCAL_DEBS="$ISO_DEBS" \
    IMMUTABLE_BUNDLE="$BUNDLE" \
    iso
