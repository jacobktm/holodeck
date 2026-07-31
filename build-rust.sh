#!/bin/bash
set -euo pipefail

KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1 ;;
        *) echo "Usage: $0 [--keep]"; exit 1 ;;
    esac
    shift
done

cd "$(dirname "$0")"

echo "==> Building Rust CLI..."
cd rust
cargo build --release
cd ..

echo "==> Installing binary to $(pwd)/immutable"
cp rust/target/release/immutable immutable
chmod +x immutable

if [ "$KEEP" -eq 0 ]; then
    echo "==> Cleaning build artifacts..."
    rm -rf rust/target
fi

echo "==> Done. Built $(file --brief immutable)"
