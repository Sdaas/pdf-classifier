#!/usr/bin/env python3
"""Fingerprint-based text classifier.

Matches extracted text against fingerprints in kb.yaml.
Outputs JSON classification result to stdout.

Exit codes:
    0 - success (match found or no_match)
    2 - error
"""

import argparse
import json
import re
import sys

import yaml

# Characters that indicate a fingerprint is a regex pattern
REGEX_META = set(r"[(*+?{\\^$|")


def is_regex(pattern: str) -> bool:
    """Return True if pattern contains regex metacharacters."""
    return any(c in REGEX_META for c in pattern)


def fingerprint_matches(fingerprint: str, text: str) -> bool:
    """Check if a fingerprint matches the normalized text.

    Fingerprints containing regex metacharacters are treated as regex patterns.
    Otherwise, plain case-insensitive substring match (text is already normalized).
    """
    fp_lower = fingerprint.lower()
    if is_regex(fingerprint):
        try:
            return bool(re.search(fp_lower, text))
        except re.error:
            return False
    else:
        # Normalize fingerprint whitespace to match normalized text
        fp_normalized = re.sub(r"\s+", " ", fp_lower).strip()
        return fp_normalized in text


CONF_RANK = {"HIGH": 3, "MEDIUM": 2, "LOW": 1}


def classify(text: str, kb: dict) -> dict:
    """Classify text against the knowledge base.

    Evaluates all sources and returns the best match (highest confidence,
    most evidence). Within a single entry, confidence rules are applied
    in order: HIGH > MEDIUM > LOW (stop at first passing rule).
    """
    best = None

    for source in kb.get("sources", []):
        source_name = source.get("name", "")
        for account in source.get("accounts", []):
            account_type = account.get("type")
            for statement in account.get("statements", []):
                statement_name = statement.get("name", "")
                fingerprints = statement.get("fingerprints", [])

                if not fingerprints:
                    continue

                matched = []
                for fp in fingerprints:
                    if fingerprint_matches(fp, text):
                        matched.append(fp)

                total = len(fingerprints)
                match_count = len(matched)

                if match_count == 0:
                    continue

                # Determine confidence - stop at first passing rule
                if match_count == total:
                    confidence = "HIGH"
                elif match_count > 1:
                    confidence = "MEDIUM"
                else:
                    confidence = "LOW"

                candidate = {
                    "status": "success",
                    "confidence": confidence,
                    "issuer": source_name,
                    "account_type": account_type,
                    "statement_type": statement_name,
                    "evidence": matched,
                }

                # Keep the best match: higher confidence wins,
                # then more evidence as tiebreaker
                if best is None:
                    best = candidate
                else:
                    best_rank = CONF_RANK.get(best["confidence"], 0)
                    cand_rank = CONF_RANK.get(confidence, 0)
                    if cand_rank > best_rank or (
                        cand_rank == best_rank
                        and match_count > len(best["evidence"])
                    ):
                        best = candidate

    return best if best else {"status": "no_match"}


def main():
    parser = argparse.ArgumentParser(description="Fingerprint-based text classifier.")
    parser.add_argument("text_file", help="Path to file containing normalized text")
    parser.add_argument("kb_file", help="Path to kb.yaml knowledge base file")
    args = parser.parse_args()

    try:
        with open(args.text_file, "r") as f:
            text = f.read().strip()

        with open(args.kb_file, "r") as f:
            kb = yaml.safe_load(f)
    except Exception as e:
        result = {"status": "error", "error": str(e)}
        print(json.dumps(result))
        sys.exit(2)

    result = classify(text, kb)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
