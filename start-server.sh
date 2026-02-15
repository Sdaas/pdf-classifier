#!/usr/bin/env bash
# Start Ollama server and ensure the model is available.
set -euo pipefail

MODEL="${1:-llama3.1:8b}"

echo "=== Starting Ollama server ==="

# Check if already running
if curl -s http://localhost:11434/api/tags &>/dev/null; then
    echo "Ollama server is already running."
else
    echo "Starting ollama serve..."
    ollama serve &>/dev/null &
    OLLAMA_PID=$!
    echo "Started Ollama (PID: $OLLAMA_PID)"

    # Wait for health check (up to 15 seconds)
    for i in $(seq 1 15); do
        if curl -s http://localhost:11434/api/tags &>/dev/null; then
            echo "Ollama is healthy."
            break
        fi
        if [ "$i" -eq 15 ]; then
            echo "ERROR: Ollama failed to start within 15 seconds." >&2
            exit 1
        fi
        sleep 1
    done
fi

# Check if model is available
echo "Checking model: $MODEL"
if ollama list | grep -q "$MODEL"; then
    echo "Model $MODEL is available."
else
    echo "Model $MODEL not found. Pulling..."
    ollama pull "$MODEL"
    echo "Model $MODEL pulled successfully."
fi

echo "=== Ollama server ready (model: $MODEL) ==="
