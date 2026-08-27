#!/usr/bin/env python3
"""Deterministic credential scan of a git diff for salvage pre-push safety
(fleet-ops#1204).

Ports the guard_secrets HARD_PATTERNS + value patterns (stdlib only) so a
salvage push never leaks a credential. sgscan (semgrep) is an additional
layer run by the bash wrapper when available; this file is the always-on,
deterministic core.

Reads a unified diff on stdin, scans the ADDED lines, prints findings to
stderr, and exits 1 if any credential-shaped value is found, 0 otherwise.

Exit:
  0  clean
  1  credential-shaped value(s) found in the added lines
"""
import re
import sys

# ---------------------------------------------------------------------------
# Value-shaped detection: token formats that are nearly always real secrets.
# Ported 1:1 from nish-vault guard_secrets.py (HARD_PATTERNS).
# ---------------------------------------------------------------------------
HARD_PATTERNS = [
    ("AWS / Cloudflare R2 access key id (AKIA...)",
     re.compile(r"\bAKIA[0-9A-Z]{16}\b")),

    ("AWS / Cloudflare R2 access key id (32 hex in key=value form)",
     re.compile(
         r"(?i)\b(?:aws_)?access_key_id\s*[=:]\s*"
         r"['\"]?[A-Fa-f0-9]{32}['\"]?"
     )),

    ("AWS secret access key (40 base64 in key=value form)",
     re.compile(
         r"(?i)\baws_secret_access_key\s*[=:]\s*"
         r"['\"]?[A-Za-z0-9/+=]{40}['\"]?"
     )),

    ("secret_access_key (64 hex in key=value form)",
     re.compile(
         r"(?i)\bsecret_access_key\s*[=:]\s*"
         r"['\"]?[A-Fa-f0-9]{64}['\"]?"
     )),

    ("GitHub PAT (ghp_...)",
     re.compile(r"\bghp_[A-Za-z0-9]{36,}\b")),
    ("GitHub OAuth (gho_...)",
     re.compile(r"\bgho_[A-Za-z0-9]{36,}\b")),
    ("GitHub user token (ghu_...)",
     re.compile(r"\bghu_[A-Za-z0-9]{36,}\b")),
    ("GitHub server token (ghs_...)",
     re.compile(r"\bghs_[A-Za-z0-9]{36,}\b")),
    ("GitHub refresh token (ghr_...)",
     re.compile(r"\bghr_[A-Za-z0-9]{36,}\b")),
    ("GitHub fine-grained PAT (github_pat_...)",
     re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b")),

    ("OpenAI / Anthropic-style secret key (sk-...)",
     re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b")),

    ("Stripe-style live/test key ([psr]k_live_/test_)",
     re.compile(r"\b[psr]k_(?:live|test)_[A-Za-z0-9]{20,}\b")),

    ("Slack token (xox[baprs]-...)",
     re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),

    ("Google API key (AIza...)",
     re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),

    ("PEM private key block",
     re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
]

# ---------------------------------------------------------------------------
# credential key=value with a literal value (guard_secrets WRITE_VALUE_PATTERNS).
# ---------------------------------------------------------------------------
VALUE_PATTERNS = [
    ("credential key=value with literal value",
     re.compile(
         r"(?i)\b(?:aws_access_key_id|aws_secret_access_key|"
         r"access_key_id|secret_access_key|"
         r"api[-_]?key|api[-_]?secret|auth[-_]?token|access[-_]?token|"
         r"client[-_]?secret|client[-_]?password|"
         r"password|passwd|pwd|token|secret|credential)"
         r"\s*[=:]\s*['\"]?([A-Za-z0-9_\-/+=@.]{16,})['\"]?"
     )),
]

_PLACEHOLDER_EXACT = frozenset({
    "changeme", "change_me", "change-me",
    "redacted", "xxx", "xxxx", "xxxxx", "xxxxxx",
    "your_key", "your-key", "your_key_here", "your-key-here",
    "your_access_key", "your_secret_key", "your_token",
    "example", "example_key", "example-key", "example_value",
    "placeholder", "dummy", "fake", "fake_key", "fake-key",
    "notarealkey", "insert_here", "insert-your-key",
    "test", "test_key", "test-key",
})
_PLACEHOLDER_PREFIXES = (
    "your_", "your-",
    "example_", "example-",
    "placeholder", "placeholder_", "placeholder-",
    "dummy_", "dummy-",
    "fake_", "fake-",
    "test_", "test-",
    "sample_", "sample-",
    "insert_", "insert-",
)


def _is_placeholder(s):
    if not isinstance(s, str) or not s:
        return False
    sl = s.lower().strip()
    if not sl:
        return False
    if sl in _PLACEHOLDER_EXACT:
        return True
    for prefix in _PLACEHOLDER_PREFIXES:
        if sl.startswith(prefix):
            return True
    if s.startswith("<") and s.endswith(">") and len(s) >= 3:
        return True
    return False


def added_lines(diff_text):
    """Yield the content of ADDED lines in a unified diff (skip +++ headers)."""
    for line in diff_text.splitlines():
        if line.startswith("+++"):
            continue
        if line.startswith("+"):
            yield line[1:]


def scan_lines(lines):
    """Return a list of (label, line_no, snippet) findings for added lines."""
    findings = []
    for i, content in enumerate(lines, 1):
        for label, pat in HARD_PATTERNS:
            m = pat.search(content)
            if m and not _is_placeholder(m.group(0)):
                findings.append((label, i, content.strip()))
        for label, pat in VALUE_PATTERNS:
            m = pat.search(content)
            if m and not _is_placeholder(m.group(1)):
                findings.append((label, i, content.strip()))
    return findings


def main():
    diff = sys.stdin.read()
    findings = scan_lines(added_lines(diff))
    for label, line_no, snippet in findings:
        sys.stderr.write(
            "salvage-secret-scan: %s (added line %d): %s\n"
            % (label, line_no, snippet)
        )
    if findings:
        sys.stderr.write(
            "salvage-secret-scan: QUARANTINE — %d credential-shaped "
            "value(s) in the salvaged diff\n" % len(findings)
        )
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # fail closed: any error -> quarantine
        sys.stderr.write("salvage-secret-scan: scan error: %s\n" % exc)
        sys.exit(1)
