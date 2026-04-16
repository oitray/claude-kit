#!/usr/bin/env python3
"""Lightweight PII / credential scanner for CI."""
import re, sys, pathlib, json

PATTERNS = {
    "aws_key": r"AKIA[0-9A-Z]{16}",
    "github_token": r"gh[pousr]_[A-Za-z0-9_]{36,}",
    "jwt": r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}",
    "pem_block": r"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----",
    "slack_webhook": r"https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[a-zA-Z0-9]+",
    "teams_webhook": r"https://[a-z0-9-]+\.webhook\.office\.com/",
}

def scan(root: pathlib.Path):
    findings = []
    for p in sorted(root.rglob("*")):
        if not p.is_file() or p.suffix in (".pyc",) or ".git" in p.parts:
            continue
        try:
            text = p.read_text(errors="ignore")
        except Exception:
            continue
        for name, pat in PATTERNS.items():
            for m in re.finditer(pat, text):
                findings.append({"file": str(p), "detector": name, "match": m.group()[:40]})
    return findings

if __name__ == "__main__":
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(".")
    results = scan(root)
    if results:
        print(json.dumps(results, indent=2))
        sys.exit(1)
    print("No findings.")
