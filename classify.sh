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
    LLM_RESULT=$("$PYTHON" "$SCRIPTS/llm_classifier.py" "${LLM_ARGS[@]}") || LLM_EXIT=$?
else
    LLM_RESULT=$("$PYTHON" "$SCRIPTS/llm_classifier.py" "${LLM_ARGS[@]}" 2>/dev/null) || LLM_EXIT=$?
fi

if [ "$VERBOSE" = true ]; then
    echo "LLM classifier result: $LLM_RESULT" >&2
fi

# Step 4: Combine results
# Use Python to merge the two JSON results according to confidence rules
"$PYTHON" - "$TEXT_RESULT" "$LLM_RESULT" "$FILE_BASENAME" "$FILE_TYPE" "$PAGES_META" <<'PYEOF'
import json
import sys

text_json_str = sys.argv[1]
llm_json_str = sys.argv[2]
file_name = sys.argv[3]
file_type = sys.argv[4]
pages_meta_str = sys.argv[5] if len(sys.argv) > 5 else ""

def parse_result(s):
    try:
        return json.loads(s) if s else {"status": "error", "error": "empty response"}
    except json.JSONDecodeError:
        return {"status": "error", "error": f"invalid JSON: {s}"}

text_r = parse_result(text_json_str)
llm_r = parse_result(llm_json_str)

text_status = text_r.get("status", "error")
llm_status = llm_r.get("status", "error")

CONF_RANK = {"HIGH": 3, "MEDIUM": 2, "LOW": 1}

def combine(text_r, llm_r):
    ts = text_r.get("status", "error")
    ls = llm_r.get("status", "error")

    # Both error => error
    if ts == "error" and ls == "error":
        return {"status": "error", "confidence": None,
                "issuer": None, "account_type": None, "statement_type": None}

    # One error, other no_match => no_match
    if (ts == "error" and ls == "no_match") or (ts == "no_match" and ls == "error"):
        return {"status": "no_match", "confidence": None,
                "issuer": None, "account_type": None, "statement_type": None}

    # One error/no_match, other success => success with LOW
    if ts == "success" and ls in ("error", "no_match"):
        return {"status": "success", "confidence": "LOW",
                "issuer": text_r.get("issuer"),
                "account_type": text_r.get("account_type"),
                "statement_type": text_r.get("statement_type")}
    if ls == "success" and ts in ("error", "no_match"):
        return {"status": "success", "confidence": "LOW",
                "issuer": llm_r.get("issuer"),
                "account_type": llm_r.get("account_type"),
                "statement_type": llm_r.get("statement_type")}

    # Both no_match => no_match
    if ts == "no_match" and ls == "no_match":
        return {"status": "no_match", "confidence": None,
                "issuer": None, "account_type": None, "statement_type": None}

    # Both success
    if ts == "success" and ls == "success":
        t_conf = text_r.get("confidence", "LOW")
        l_conf = llm_r.get("confidence", "LOW")
        t_issuer = text_r.get("issuer")
        l_issuer = llm_r.get("issuer")
        t_stmt = text_r.get("statement_type")
        l_stmt = llm_r.get("statement_type")

        agree = (t_issuer == l_issuer and t_stmt == l_stmt)

        if agree and t_conf == "HIGH" and l_conf == "HIGH":
            return {"status": "success", "confidence": "HIGH",
                    "issuer": t_issuer,
                    "account_type": text_r.get("account_type"),
                    "statement_type": t_stmt}
        elif agree:
            return {"status": "success", "confidence": "MEDIUM",
                    "issuer": t_issuer,
                    "account_type": text_r.get("account_type"),
                    "statement_type": t_stmt}
        else:
            # Disagree: pick highest confidence, report LOW
            if CONF_RANK.get(t_conf, 0) >= CONF_RANK.get(l_conf, 0):
                winner = text_r
            else:
                winner = llm_r
            return {"status": "success", "confidence": "LOW",
                    "issuer": winner.get("issuer"),
                    "account_type": winner.get("account_type"),
                    "statement_type": winner.get("statement_type")}

    # Fallback
    return {"status": "error", "confidence": None,
            "issuer": None, "account_type": None, "statement_type": None}

combined = combine(text_r, llm_r)

# Parse pages_analyzed from extractor metadata
pages_analyzed = None
if pages_meta_str:
    try:
        pages_analyzed = json.loads(pages_meta_str).get("pages_analyzed")
    except (json.JSONDecodeError, AttributeError):
        pass

additional = {
    "text_analysis": text_r,
    "llm_classification": llm_r
}
if pages_analyzed is not None:
    additional["pages_analyzed"] = pages_analyzed

output = {
    "input": {
        "file": file_name,
        "file_type": file_type
    },
    "result": {
        "status": combined["status"],
        "confidence": combined["confidence"],
        "issuer": combined["issuer"],
        "account_type": combined["account_type"],
        "statement_type": combined["statement_type"]
    },
    "additional_info": additional
}

print(json.dumps(output, indent=2))

# Exit code based on combined status
if combined["status"] == "success":
    sys.exit(0)
elif combined["status"] == "no_match":
    sys.exit(1)
else:
    sys.exit(2)
PYEOF
