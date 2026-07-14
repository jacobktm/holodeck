#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

echo "Building base image: pop-os:24.04-latest"
docker build -t pop-os:24.04-latest -f Dockerfile .

echo ""
echo "Building nested session image: pop-os:24.04-cosmic-latest"
docker build -t pop-os:24.04-cosmic-latest -f Dockerfile.cosmic .

docker image prune -f

echo ""
echo "Done. Images:"
echo "  pop-os:24.04-latest       (standard)"
echo "  pop-os:24.04-cosmic-latest (nested COSMIC session)"
