#!/bin/bash
set -euo pipefail

# Build the forked pop-installer into .deb packages and collect them in
# dist/debs/. Produces: pop-installer, pop-installer-casper, pop-installer-session.
#
# Requires the libdistinst-dev deb built by build-distinst.sh (installed with
# sudo so dpkg-checkbuilddeps passes).

cd "$(dirname "$0")"

FORK="forks/installer"
OUT="dist/debs"
DEVD="$(ls -t "$OUT"/libdistinst-dev_*.deb 2>/dev/null | head -1 || true)"

if [ ! -d "$FORK" ]; then
    echo "ERROR: $FORK missing. Did submodules fail to init? Try: git submodule update --init --recursive" >&2
    exit 1
fi

if [ -z "$DEVD" ]; then
    echo "ERROR: no libdistinst-dev deb in $OUT. Run ./build-distinst.sh first." >&2
    exit 1
fi

if [ -n "$(git -C "$FORK" status --porcelain)" ]; then
    echo "ERROR: $FORK has uncommitted changes; dpkg-buildpackage requires a clean tree." >&2
    git -C "$FORK" status --short >&2
    exit 1
fi

# Make our freshly built libdistinst-dev available to the build (idempotent).
if ! dpkg-query -W -f='${Version}' libdistinst-dev 2>/dev/null | grep -q "$(dpkg-deb -f "$DEVD" Version)"; then
    echo "==> Installing $DEVD (sudo required)..."
    sudo dpkg -i "$DEVD"
fi

echo "==> Building pop-installer debs from $FORK..."
(
    cd "$FORK"
    dpkg-buildpackage -us -uc --build=binary
)

echo "==> Collecting debs..."
mv -f "$FORK"/../pop-installer*.deb "$FORK"/../gir1.2-pop-installer*.deb "$OUT"/ 2>/dev/null || true

echo "==> Built:"
ls -1 "$OUT"/pop-installer*.deb 2>/dev/null
