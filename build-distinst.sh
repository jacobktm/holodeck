#!/bin/bash
set -euo pipefail

# Build the forked distinst into .deb packages and collect them in dist/debs/.
# Produces: distinst, libdistinst, libdistinst-dev.
#
# Uses the host cargo (VENDORED=0) and skips `make clean` (CLEAN=0) so the
# target/ cache survives between builds.

cd "$(dirname "$0")"

FORK="forks/distinst"
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

echo "==> Building distinst debs from $FORK..."
(
    cd "$FORK"
    CLEAN=0 VENDORED=0 dpkg-buildpackage -us -uc --build=binary
)

echo "==> Collecting debs..."
mv -f "$FORK"/../distinst_*.deb "$FORK"/../libdistinst*.deb "$FORK"/../distinst*.ddeb "$OUT"/ 2>/dev/null || true

echo "==> Built:"
ls -1 "$OUT"/distinst*.deb "$OUT"/libdistinst*.deb 2>/dev/null
