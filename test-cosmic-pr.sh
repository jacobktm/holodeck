#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
PYTHON="$VENV_DIR/bin/python3"

# ── Auto-install Docker if missing ──────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found. Installing..."
    echo ""

    if ! command -v curl >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl
    fi

    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu noble stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    sudo usermod -aG docker "$USER"
    echo ""
    echo "Docker installed. You may need to log out and back in for group"
    echo "membership to take effect, or run: newgrp docker"
    echo ""
fi

# ── Auto-setup venv if missing ──────────────────────────────────────
if [ ! -d "$VENV_DIR" ] || [ ! -f "$VENV_DIR/bin/python3" ]; then
    if ! python3 -m venv --help >/dev/null 2>&1; then
        echo "python3-venv not found. Installing..."
        sudo apt-get update
        sudo apt-get install -y python3-venv
    fi
    echo "Virtual environment not found. Running setup..."
    "$SCRIPT_DIR/setup.sh"
    echo ""
fi

if [ ! -f "$PYTHON" ]; then
    echo "ERROR: Python venv not available at $PYTHON"
    echo "Run: ./setup.sh"
    exit 1
fi

# ── Run the Python backend ─────────────────────────────────────────
exec "$PYTHON" "$SCRIPT_DIR/cosmic_test.py" "$@"
