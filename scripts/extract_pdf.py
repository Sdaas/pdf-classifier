#!/usr/bin/env python3
"""Extract text from a PDF file (first/last N lines of first/last page).

Outputs normalized text to stdout, with first-page and last-page blocks
clearly labelled so downstream classifiers can distinguish header/footer
from tabular content.

Exit codes:
    0 - success
    1 - extraction produced empty text
    2 - error (file not found, unreadable, etc.)
"""

import argparse
import json
import re
import sys

import pdfplumber


def normalize_line(line: str) -> str:
    """Lowercase and collapse whitespace within a single line."""
    return re.sub(r"\s+", " ", line.lower()).strip()


def extract(pdf_path: str, lines: int) -> tuple[str, list[int]]:
    """Return (normalized text, pages_analyzed) from first/last page.

    Output is structured with labelled page blocks so the LLM can
    distinguish header/footer from tabular content.
    """
    with pdfplumber.open(pdf_path) as pdf:
        if not pdf.pages:
            return "", []

        num_pages = len(pdf.pages)
        first_page_text = pdf.pages[0].extract_text() or ""
        first_lines = first_page_text.splitlines()[:lines]

        if num_pages == 1:
            all_lines = first_page_text.splitlines()
            if len(all_lines) <= lines * 2:
                selected = all_lines
            else:
                selected = first_lines + all_lines[-lines:]
            normalized = [normalize_line(l) for l in selected if l.strip()]
            text = "--- Page 1 ---\n" + "\n".join(normalized)
            pages_analyzed = [1]
        else:
            last_page_text = pdf.pages[-1].extract_text() or ""
            last_lines = last_page_text.splitlines()[-lines:]
            first_norm = [normalize_line(l) for l in first_lines if l.strip()]
            last_norm = [normalize_line(l) for l in last_lines if l.strip()]
            text = (
                "--- First Page ---\n"
                + "\n".join(first_norm)
                + "\n\n--- Last Page ---\n"
                + "\n".join(last_norm)
            )
            pages_analyzed = [1, num_pages]

    return text, pages_analyzed


def main():
    parser = argparse.ArgumentParser(description="Extract text from a PDF file.")
    parser.add_argument("file", help="Path to PDF file")
    parser.add_argument(
        "--lines",
        type=int,
        default=15,
        help="Number of lines to extract from first/last page (default: 15)",
    )
    args = parser.parse_args()

    try:
        text, pages = extract(args.file, args.lines)
    except Exception as e:
        print(f"Error extracting PDF: {e}", file=sys.stderr)
        sys.exit(2)

    if not text.strip():
        print("Error: extraction produced empty text", file=sys.stderr)
        sys.exit(1)

    # Output page metadata to stderr as JSON for classify.sh to capture
    print(json.dumps({"pages_analyzed": pages}), file=sys.stderr)
    print(text)


if __name__ == "__main__":
    main()
