#!/bin/bash
set -euo pipefail

# Full ISO build orchestration:
#   1. build the Rust immutable CLI        (build-rust.sh)
#   2. assemble the immutable data bundle  (build-bundle.sh)
#   3. build distinst debs                 (build-distinst.sh)
#   4. build pop-installer debs            (build-installer.sh)
#   5. run the forked ISO build, feeding it our debs + bundle
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
echo " 5/5  Building ISO ($DISTRO_CODE $DISTRO_VERSION, NVIDIA=$NVIDIA)"
echo "═══════════════════════════════════════════════"
exec make -C forks/iso \
    DISTRO_CODE="$DISTRO_CODE" \
    DISTRO_VERSION="$DISTRO_VERSION" \
    NVIDIA="$NVIDIA" \
    LOCAL_DEBS="$DEBS" \
    IMMUTABLE_BUNDLE="$BUNDLE" \
    iso
