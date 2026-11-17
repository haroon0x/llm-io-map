#!/usr/bin/env python3
"""redact.py — redact secrets from an .llmmap output tree.

Usage:
  python3 redact.py [path ...] [--check] [--dry-run] [--quiet]
Defaults to ./.llmmap if no path given.

Two layers:
  1. Value patterns (sk-..., Bearer ..., AIza..., connection strings, JWT-ish blobs).
  2. Sensitive key names anywhere in a JSON object (authorization, api_key, ...).

With --check: exit 1 if anything would be redacted (CI-friendly). Does not write.
Prints a summary of what changed; never prints the secret values themselves.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

SECRET_KEY = re.compile(
    r"(?i)^(authorization|proxy-authorization|x-api-key|api[-_]?key|apikey|access[-_]?token|"
    r"refresh[-_]?token|id[-_]?token|token|secret|client[-_]?secret|password|passwd|pwd|"
    r"cookie|set[-_]?cookie|session[-_]?id|private[-_]?key|aws[-_]?secret[-_]?access[-_]?key|"
    r"openai[-_]?api[-_]?key|anthropic[-_]?api[-_]?key)$"
)

REDACTED_RE = re.compile(r"^<REDACTED:[a-z_]+>$")

VALUE_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("openai_key", re.compile(r"\bsk-(?:proj-|ant-)?[A-Za-z0-9_\-]{16,}")),
    ("google_key", re.compile(r"\bAIza[0-9A-Za-z_\-]{20,}")),
    ("github_token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}")),
    ("aws_key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("slack_token", re.compile(r"\bxox[baprs]-[A-Za-z0-9\-]{10,}")),
    ("bearer", re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._\-]{12,}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}")),
    ("db_url", re.compile(r"\b(postgres(?:ql)?|postgres|mysql|mongodb(?:\+srv)?|redis|amqp)://[^\s\"'<>]+")),
]

# Keys whose *name* is not sensitive but whose value may hold env-var style secrets.
TEXT_EXTS = {".json", ".jsonl", ".txt", ".md", ".log", ".http", ".sse", ".ndjson"}
SKIP_DIR_NAMES = {".git", "node_modules"}


def redact_value(kind: str, value: str) -> str:
    return f"<REDACTED:{kind}>"


def walk_json(obj, path: str, hits: list[tuple[str, str]]):
    if isinstance(obj, dict):
        return {k: walk_json(v, f"{path}.{k}" if path else k, hits) for k, v in obj.items()}
    if isinstance(obj, list):
        return [walk_json(v, f"{path}[{i}]", hits) for i, v in enumerate(obj)]
    if isinstance(obj, str):
        new = obj
        for kind, pat in VALUE_PATTERNS:
            if pat.search(new):
                new = pat.sub(redact_value(kind, ""), new)
                hits.append((path, kind))
        return new
    return obj


def walk_json_keys(obj, path: str, hits: list[tuple[str, str]]):
    """Second pass: redact values under sensitive key names, whatever they contain."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            child = f"{path}.{k}" if path else k
            already = isinstance(v, str) and REDACTED_RE.match(v)
            if SECRET_KEY.match(k) and isinstance(v, (str, int, float)) and v != "" and not already:
                out[k] = redact_value("secret", "")
                hits.append((child, "secret-key"))
            else:
                out[k] = walk_json_keys(v, child, hits)
        return out
    if isinstance(obj, list):
        return [walk_json_keys(v, f"{path}[{i}]", hits) for i, v in enumerate(obj)]
    return obj


def redact_text(text: str, path: str, hits: list[tuple[str, str]]) -> str:
    for kind, pat in VALUE_PATTERNS:
        if pat.search(text):
            text = pat.sub(redact_value(kind, ""), text)
            hits.append((path, kind))
    return text


def fingerprint(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", "replace")).hexdigest()[:8]


def main() -> int:
    ap = argparse.ArgumentParser(description="Redact secrets from .llmmap outputs")
    ap.add_argument("paths", nargs="*", default=[".llmmap"])
    ap.add_argument("--check", action="store_true", help="report only; exit 1 if secrets found")
    ap.add_argument("--dry-run", action="store_true", help="do not write files")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    targets: list[Path] = []
    for p in args.paths or [".llmmap"]:
        path = Path(p)
        if not path.exists():
            print(f"warning: {path} does not exist", file=sys.stderr)
            continue
        if path.is_dir():
            for f in sorted(path.rglob("*")):
                if f.is_file() and f.suffix.lower() in TEXT_EXTS and not (set(f.parts) & SKIP_DIR_NAMES):
                    targets.append(f)
        else:
            targets.append(path)

    total_hits = 0
    changed_files = 0
    for f in targets:
        original = f.read_text(encoding="utf-8", errors="replace")
        hits: list[tuple[str, str]] = []
        try:
            data = json.loads(original)
        except json.JSONDecodeError:
            new_text = redact_text(original, "<text>", hits)
        else:
            data = walk_json(data, "", hits)
            data = walk_json_keys(data, "", hits)
            new_text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"

        if hits:
            changed_files += 1
            total_hits += len(hits)
            if not args.quiet:
                rel = f
                uniq = sorted({f"{kind} @ {where}" for where, kind in hits})
                print(f"{rel}: {len(hits)} redaction(s)")
                for u in uniq[:8]:
                    print(f"  - {u}")
                if len(uniq) > 8:
                    print(f"  … {len(uniq) - 8} more")
            if not (args.check or args.dry_run):
                f.write_text(new_text, encoding="utf-8")

    if args.check:
        if total_hits:
            print(f"\nFAIL: {total_hits} secret(s) across {changed_files} file(s) — run redact.py to fix.")
            return 1
        print("OK: no secrets found.")
        return 0

    if total_hits == 0:
        print("OK: no secrets found.")
        return 0

    action = "would redact" if args.dry_run else "redacted"
    print(f"\n{action} {total_hits} value(s) in {changed_files} file(s). Re-run --check to confirm.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
