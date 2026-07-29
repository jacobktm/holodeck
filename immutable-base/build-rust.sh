#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Building Rust CLI..."
cd rust
cargo build --release
cd ..

echo "==> Installing binary to $(pwd)/immutable"
cp rust/target/release/immutable immutable
chmod +x immutable

echo "==> Done. Built $(file --brief immutable)"
