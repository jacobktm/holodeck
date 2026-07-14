#!/usr/bin/env bash
# Setup script for the COSMIC PR testing framework.
# Creates a Python virtual environment and installs dependencies.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

echo "Setting up COSMIC PR test environment..."

# Check Python
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 not found"
    exit 1
fi

PYTHON_VERSION=$(python3 --version 2>&1)
echo "Found: $PYTHON_VERSION"

# Create venv
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    echo "Created virtual environment at $VENV_DIR"
else
    echo "Using existing venv at $VENV_DIR"
fi

# Activate and install deps
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet psutil

echo ""
echo "Dependencies installed:"
pip list --format=columns 2>/dev/null | grep -E "psutil|pip"

echo ""
echo "========================================"
echo " Environment ready."
echo "========================================"
echo ""
echo "Usage:"
echo "  ./test-cosmic-pr.sh <pkg:branch,...> [rebuild] [--nested]"
echo ""
echo "Examples:"
echo "  ./test-cosmic-pr.sh cosmic-files:testing-cosmic-files-pr1885 rebuild"
echo '  ./test-cosmic-pr.sh "cosmic-settings:pr-2068,cosmic-settings-daemon:daemon-branch" --nested'
