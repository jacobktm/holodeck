#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
PYTHON="$VENV_DIR/bin/python3"

# ── Auto-setup venv if missing ──────────────────────────────────────
if [ ! -d "$VENV_DIR" ] || [ ! -f "$VENV_DIR/bin/python3" ]; then
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
