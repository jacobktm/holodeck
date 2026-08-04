#!/bin/bash
set -euo pipefail

# Build the forked distinst-v2 (DBus installer service) into a .deb and
# collect it in dist/debs/. Produces: distinst-v2.
#
# pop-installer master drives this service (com.system76.Distinst); this is
# the package the ISO's live image must ship our port of.

cd "$(dirname "$0")"

FORK="forks/distinst-v2"
OUT="dist/debs"

if [ ! -d "$FORK" ]; then
    echo "ERROR: $FORK missing. Did submodules fail to init? Try: git submodule update --init --recursive" >&2
    exit 1
fi

if [ -n "$(git -C "$FORK" status --porcelain)" ]; then
    echo "ERROR: $FORK has uncommitted changes; dpkg-buildpackage requires a clean tree." >&2
    git -C "$FORK" status --short >&2
    exit 1
fi

mkdir -p "$OUT"

echo "==> Building distinst-v2 deb from $FORK..."
(
    cd "$FORK"
    VENDOR=0 CLEAN=0 dpkg-buildpackage -us -uc --build=binary
)

echo "==> Collecting debs..."
mv -f "$FORK"/../distinst-v2_*.deb "$OUT"/ 2>/dev/null || true

echo "==> Built:"
ls -1 "$OUT"/distinst-v2_*.deb 2>/dev/null
