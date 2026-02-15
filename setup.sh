#!/usr/bin/env bash
# Setup script: create venv and install Python dependencies.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

echo "=== Setting up pdf-classifier ==="

# 1. Create virtual environment
if [ -d "$VENV_DIR" ]; then
    echo "Virtual environment already exists at $VENV_DIR"
else
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
    echo "Created $VENV_DIR"
fi

# 2. Install dependencies
echo "Installing Python dependencies..."
"$VENV_DIR/bin/pip" install --quiet -r "$SCRIPT_DIR/requirements.txt"
echo "Dependencies installed."

# 3. Verify Ollama
if command -v ollama &>/dev/null; then
    echo "Ollama found: $(command -v ollama)"
else
    echo "WARNING: Ollama is not installed."
    echo "Install it from https://ollama.ai and then run start-server.sh"
fi

echo "=== Setup complete ==="
