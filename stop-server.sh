#!/usr/bin/env bash
# Stop the Ollama server.
set -euo pipefail

echo "=== Stopping Ollama server ==="

# Find and kill ollama serve processes
if pkill -f "ollama serve" 2>/dev/null; then
    echo "Ollama server stopped."
else
    echo "No Ollama server process found."
fi

# Verify shutdown
sleep 1
if curl -s http://localhost:11434/api/tags &>/dev/null; then
    echo "WARNING: Ollama server is still responding." >&2
else
    echo "Confirmed: Ollama server is not running."
fi
