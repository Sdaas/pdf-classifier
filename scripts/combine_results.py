#!/usr/bin/env python3
"""Combine text classifier and LLM classifier results.

Merges the two JSON results according to confidence rules and produces
the final output JSON envelope.

Exit codes:
    0 - success (match found)
    1 - no_match
    2 - error
"""

import argparse
import json
import sys

CONF_RANK = {"HIGH": 3, "MEDIUM": 2, "LOW": 1}


def parse_result(s):
    """Parse a JSON result string, returning an error dict on failure."""
    try:
        return json.loads(s) if s else {"status": "error", "error": "empty response"}
    except json.JSONDecodeError:
        return {"status": "error", "error": f"invalid JSON: {s}"}


def combine(text_r, llm_r):
    """Apply confidence matrix to merge text and LLM classifier results."""
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


def main():
    parser = argparse.ArgumentParser(description="Combine classifier results.")
    parser.add_argument("text_result", help="Text classifier JSON result string")
    parser.add_argument("llm_result", help="LLM classifier JSON result string")
    parser.add_argument("file_name", help="Input file basename")
    parser.add_argument("file_type", help="Input file type (pdf/xlsx)")
    parser.add_argument("--pages-meta", default="", help="Pages metadata JSON string")
    args = parser.parse_args()

    text_r = parse_result(args.text_result)
    llm_r = parse_result(args.llm_result)
    combined = combine(text_r, llm_r)

    # Parse pages_analyzed from extractor metadata
    pages_analyzed = None
    if args.pages_meta:
        try:
            pages_analyzed = json.loads(args.pages_meta).get("pages_analyzed")
        except (json.JSONDecodeError, AttributeError):
            pass

    additional = {
        "text_analysis": text_r,
        "llm_classification": llm_r,
    }
    if pages_analyzed is not None:
        additional["pages_analyzed"] = pages_analyzed

    output = {
        "input": {
            "file": args.file_name,
            "file_type": args.file_type,
        },
        "result": {
            "status": combined["status"],
            "confidence": combined["confidence"],
            "issuer": combined["issuer"],
            "account_type": combined["account_type"],
            "statement_type": combined["statement_type"],
        },
        "additional_info": additional,
    }

    print(json.dumps(output, indent=2))

    if combined["status"] == "success":
        sys.exit(0)
    elif combined["status"] == "no_match":
        sys.exit(1)
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
