#!/usr/bin/env bash
# classify.sh — Main entry point for the PDF/XLSX classifier.
# Orchestrates extraction + text-based + LLM-based classification.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"
SCRIPTS="$SCRIPT_DIR/scripts"

# Defaults
MODEL="llama3.1:8b"
KB_FILE="$SCRIPT_DIR/kb.yaml"
TIMEOUT=60
VERBOSE=false
INPUT_FILE=""

# Temp file management
TEMP_FILE=""
TEMP_META=""
cleanup() {
    if [ -n "$TEMP_FILE" ] && [ -f "$TEMP_FILE" ]; then
        rm -f "$TEMP_FILE"
    fi
    if [ -n "$TEMP_META" ] && [ -f "$TEMP_META" ]; then
        rm -f "$TEMP_META"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: classify.sh [options] <file>

Options:
  --help                Show usage
  --model <name>        Ollama model (default: llama3.1:8b)
  --kb <path>           Knowledge base file (default: ./kb.yaml)
  --timeout <seconds>   LLM request timeout (default: 60)
  --verbose             Show intermediate steps on stderr

Arguments:
  <file>                Path to input file (PDF or XLSX)
EOF
    exit 0
}

error_json() {
    local file="$1"
    local msg="$2"
    printf '{"file":"%s","error":"%s"}\n' "$file" "$msg"
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --help)
            usage
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --kb)
            KB_FILE="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            exit 2
            ;;
        *)
            INPUT_FILE="$1"
            shift
            ;;
    esac
done

# Validate input file
if [ -z "$INPUT_FILE" ]; then
    echo "Error: No input file specified." >&2
    echo "Run with --help for usage." >&2
    exit 2
fi

if [ ! -f "$INPUT_FILE" ]; then
    error_json "$INPUT_FILE" "File not found: $INPUT_FILE"
    exit 2
fi

# Determine file type
FILE_EXT="${INPUT_FILE##*.}"
FILE_EXT_LOWER="$(echo "$FILE_EXT" | tr '[:upper:]' '[:lower:]')"
FILE_BASENAME="$(basename "$INPUT_FILE")"

case "$FILE_EXT_LOWER" in
    pdf)
        FILE_TYPE="pdf"
        EXTRACTOR="$SCRIPTS/extract_pdf.py"
        ;;
    xlsx)
        FILE_TYPE="xlsx"
        EXTRACTOR="$SCRIPTS/extract_xls.py"
        ;;
    *)
        error_json "$FILE_BASENAME" "Unsupported file type: .$FILE_EXT_LOWER (supported: pdf, xlsx)"
        exit 2
        ;;
esac

# Validate KB file
if [ ! -f "$KB_FILE" ]; then
    error_json "$FILE_BASENAME" "Knowledge base not found: $KB_FILE"
    exit 2
fi

# Health check Ollama
if ! curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
    error_json "$FILE_BASENAME" "Ollama server is not running. Start it with: ./start-server.sh"
    exit 2
fi

if [ "$VERBOSE" = true ]; then
    echo "=== Classifying: $INPUT_FILE (type: $FILE_TYPE) ===" >&2
fi

# Step 1: Extract text
TEMP_FILE="$(mktemp)"
TEMP_META="$(mktemp)"
if [ "$VERBOSE" = true ]; then
    echo "=== Extracting text ===" >&2
fi

EXTRACT_EXIT=0
if [ "$VERBOSE" = true ]; then
    echo ">>> $PYTHON $EXTRACTOR $INPUT_FILE" >&2
fi
"$PYTHON" "$EXTRACTOR" "$INPUT_FILE" > "$TEMP_FILE" 2>"$TEMP_META" || EXTRACT_EXIT=$?

if [ "$EXTRACT_EXIT" -ne 0 ]; then
    error_json "$FILE_BASENAME" "Text extraction failed (exit code: $EXTRACT_EXIT)"
    exit 2
fi

# Read pages_analyzed metadata (from extractor stderr, JSON format)
PAGES_META=""
if [ -s "$TEMP_META" ]; then
    PAGES_META="$(cat "$TEMP_META")"
fi

if [ "$VERBOSE" = true ]; then
    echo "=== Extracted text ===" >&2
    cat "$TEMP_FILE" >&2
    echo "" >&2
    echo "=======================" >&2
fi

# Step 2: Run text classifier
if [ "$VERBOSE" = true ]; then
    echo "=== Running text classifier ===" >&2
fi

TEXT_RESULT=""
TEXT_EXIT=0
if [ "$VERBOSE" = true ]; then
    echo ">>> $PYTHON $SCRIPTS/text_classifier.py $TEMP_FILE $KB_FILE" >&2
    TEXT_RESULT=$("$PYTHON" "$SCRIPTS/text_classifier.py" "$TEMP_FILE" "$KB_FILE") || TEXT_EXIT=$?
else
    TEXT_RESULT=$("$PYTHON" "$SCRIPTS/text_classifier.py" "$TEMP_FILE" "$KB_FILE" 2>/dev/null) || TEXT_EXIT=$?
fi

if [ "$VERBOSE" = true ]; then
    echo "Text classifier result: $TEXT_RESULT" >&2
fi

# Step 3: Run LLM classifier
if [ "$VERBOSE" = true ]; then
    echo "=== Running LLM classifier ===" >&2
fi

LLM_ARGS=("$TEMP_FILE" "$KB_FILE" --model "$MODEL" --timeout "$TIMEOUT")
if [ "$VERBOSE" = true ]; then
    LLM_ARGS+=(--verbose)
fi

LLM_RESULT=""
LLM_EXIT=0
if [ "$VERBOSE" = true ]; then
    echo ">>> $PYTHON $SCRIPTS/llm_classifier.py ${LLM_ARGS[*]}" >&2
    LLM_RESULT=$("$PYTHON" "$SCRIPTS/llm_classifier.py" "${LLM_ARGS[@]}") || LLM_EXIT=$?
else
    LLM_RESULT=$("$PYTHON" "$SCRIPTS/llm_classifier.py" "${LLM_ARGS[@]}" 2>/dev/null) || LLM_EXIT=$?
fi

if [ "$VERBOSE" = true ]; then
    echo "LLM classifier result: $LLM_RESULT" >&2
fi

# Step 4: Combine results
COMBINE_ARGS=("$SCRIPTS/combine_results.py" "$TEXT_RESULT" "$LLM_RESULT" "$FILE_BASENAME" "$FILE_TYPE")
if [ -n "$PAGES_META" ]; then
    COMBINE_ARGS+=(--pages-meta "$PAGES_META")
fi

if [ "$VERBOSE" = true ]; then
    echo ">>> $PYTHON ${COMBINE_ARGS[*]}" >&2
fi
"$PYTHON" "${COMBINE_ARGS[@]}"
