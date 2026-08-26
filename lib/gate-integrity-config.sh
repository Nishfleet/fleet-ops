#!/usr/bin/env bash
# gate-integrity-config.sh — load `.fleet/gate-integrity.yml` into the JSON
# fields the decision script (`.github/scripts/gate-integrity.sh`) reads from the bundle.
#
# Restricted YAML, Python stdlib only. No PyYAML. The schema is three keys:
#   gate_globs:                 list of fnmatch globs (replaces the default set)
#   ratchet_paths:              list of paths whose numeric ceilings must not rise
#                               (`ratchet_ceilings` is accepted as an alias)
#   auto_revert_body_opener:    verbatim PR-body prefix for the auto-revert waiver
#
# Usage:
#   lib/gate-integrity-config.sh                 # defaults (no file)
#   lib/gate-integrity-config.sh PATH.yml        # file, or defaults if missing/empty
#   lib/gate-integrity-config.sh -               # YAML on stdin
#
# Prints one JSON object on stdout. Fail closed on unknown keys or bad YAML.
set -euo pipefail

python3 - "$@" <<'PY'
import json
import os
import sys

DEFAULTS = {
    "gate_globs": [
        ".github/workflows/**",
        ".github/scripts/**",
        ".github/CODEOWNERS",
        ".gitleaksignore",
        ".gitleaks.toml",
        ".semgrepignore",
        ".semgrep.yml",
        ".semgrep.yaml",
        ".fleet/**",
    ],
    "ratchet_paths": [],
    "auto_revert_body_opener": (
        "Automatic revert opened because a push-to-main CI workflow went red."
    ),
}

ALLOWED = {"gate_globs", "ratchet_paths", "ratchet_ceilings", "auto_revert_body_opener"}


def parse_scalar(raw):
    text = raw.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    if text in ("null", "~", ""):
        return ""
    return text


def parse_restricted_yaml(text):
    result = {}
    current_list = None
    for lineno, raw in enumerate(text.splitlines(), 1):
        stripped = raw.split("#", 1)[0].rstrip()
        if not stripped.strip():
            continue
        if stripped.startswith("  - "):
            if current_list is None:
                raise ValueError(f"line {lineno}: list item without a key")
            item = parse_scalar(stripped[4:])
            if not item:
                raise ValueError(f"line {lineno}: empty list item")
            current_list.append(item)
            continue
        if stripped[:1] == " ":
            raise ValueError(f"line {lineno}: unexpected indent")
        if ":" not in stripped:
            raise ValueError(f"line {lineno}: expected key:")
        key, rest = stripped.split(":", 1)
        key = key.strip()
        rest = rest.strip()
        if key not in ALLOWED:
            raise ValueError(f"line {lineno}: unknown key {key!r}")
        if rest == "" or rest == "[]":
            current_list = []
            result[key] = current_list
        else:
            current_list = None
            result[key] = parse_scalar(rest)
    return result


def merge(parsed):
    out = {
        "gate_globs": list(DEFAULTS["gate_globs"]),
        "ratchet_paths": list(DEFAULTS["ratchet_paths"]),
        "auto_revert_body_opener": DEFAULTS["auto_revert_body_opener"],
    }
    if "gate_globs" in parsed:
        globs = parsed["gate_globs"]
        if not isinstance(globs, list) or not globs:
            raise ValueError("gate_globs must be a non-empty list")
        if not all(isinstance(g, str) and g for g in globs):
            raise ValueError("gate_globs must be a list of non-empty strings")
        out["gate_globs"] = globs
    raw_ratchet = parsed.get("ratchet_paths", parsed.get("ratchet_ceilings"))
    if "ratchet_paths" in parsed or "ratchet_ceilings" in parsed:
        ceilings = raw_ratchet
        if isinstance(ceilings, str):
            ceilings = [ceilings] if ceilings else []
        if not isinstance(ceilings, list) or not all(
            isinstance(x, str) and x for x in ceilings
        ):
            raise ValueError("ratchet_paths must be a list of non-empty strings")
        out["ratchet_paths"] = ceilings
    if "auto_revert_body_opener" in parsed:
        opener = parsed["auto_revert_body_opener"]
        if not isinstance(opener, str) or not opener.strip():
            raise ValueError("auto_revert_body_opener must be a non-empty string")
        out["auto_revert_body_opener"] = opener
    return out


def load_text():
    args = sys.argv[1:]
    if not args:
        return ""
    path = args[0]
    if path == "-":
        return sys.stdin.read()
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return ""
    with open(path, encoding="utf-8") as fh:
        return fh.read()


try:
    text = load_text()
    parsed = parse_restricted_yaml(text) if text.strip() else {}
    json.dump(merge(parsed), sys.stdout)
    sys.stdout.write("\n")
except ValueError as exc:
    print(f"FAIL: gate-integrity config: {exc}", file=sys.stderr)
    sys.exit(1)
PY
