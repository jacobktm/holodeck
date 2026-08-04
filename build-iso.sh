#!/bin/bash
set -euo pipefail

# Full ISO build orchestration:
#   1. build the Rust immutable CLI        (build-rust.sh)
#   2. assemble the immutable data bundle  (build-bundle.sh)
#   3. build classic distinst debs         (build-distinst.sh)
#        — libdistinst-dev is a Build-Depends of pop-installer
#   4. build distinst-v2 debs              (build-distinst-v2.sh)
#        — the DBus installer service pop-installer drives at runtime
#   5. build pop-installer debs            (build-installer.sh)
#   6. stage the override debs and run the forked ISO build
#
# The iso fork reads LOCAL_DEBS (dir of .deb) and IMMUTABLE_BUNDLE (dir) as
# make variables; chroot.mk copies them into the live rootfs and replaces the
# stock pop-os distinst-v2/pop-installer with ours.

cd "$(dirname "$0")"

DISTRO_CODE="${DISTRO_CODE:-pop-os}"
DISTRO_VERSION="${DISTRO_VERSION:-24.04}"
NVIDIA="${NVIDIA:-0}"

export DEBS="$(pwd)/dist/debs"
export BUNDLE="$(pwd)/dist/immutable-bundle"
export ISO_DEBS="$(pwd)/dist/iso-debs"

echo "═══════════════════════════════════════════════"
echo " 1/6  Building Rust immutable CLI"
echo "═══════════════════════════════════════════════"
./build-rust.sh

echo "═══════════════════════════════════════════════"
echo " 2/6  Assembling immutable data bundle"
echo "═══════════════════════════════════════════════"
./build-bundle.sh

echo "═══════════════════════════════════════════════"
echo " 3/6  Building classic distinst debs"
echo "═══════════════════════════════════════════════"
./build-distinst.sh

echo "═══════════════════════════════════════════════"
echo " 4/6  Building distinst-v2 debs"
echo "═══════════════════════════════════════════════"
./build-distinst-v2.sh

echo "═══════════════════════════════════════════════"
echo " 5/6  Building pop-installer debs"
echo "═══════════════════════════════════════════════"
./build-installer.sh

echo "═══════════════════════════════════════════════"
echo " 6/6  Staging override debs + building ISO"
echo "      ($DISTRO_CODE $DISTRO_VERSION, NVIDIA=$NVIDIA)"
echo "═══════════════════════════════════════════════"
rm -rf "$ISO_DEBS"
mkdir -p "$ISO_DEBS"
cp "$DEBS"/distinst-v2_*.deb "$ISO_DEBS"/
cp "$DEBS"/pop-installer_*.deb "$ISO_DEBS"/
cp "$DEBS"/gir1.2-pop-installer_*.deb "$ISO_DEBS"/ 2>/dev/null || true
ls -1 "$ISO_DEBS"

exec make -C forks/iso \
    DISTRO_CODE="$DISTRO_CODE" \
    DISTRO_VERSION="$DISTRO_VERSION" \
    NVIDIA="$NVIDIA" \
    LOCAL_DEBS="$ISO_DEBS" \
    IMMUTABLE_BUNDLE="$BUNDLE" \
    iso
