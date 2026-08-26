#!/usr/bin/env python3
"""No-agent-names gate (fleet-ops#519).

Standing rule (Nish, 2026-08-18): "No agent names on Nish's work".
Commits, PRs, and public artifacts must carry Nish's identity only:
no Co-Authored-By agent trailers, no "Generated with" footers, and no
agent names in PR bodies.

This is a pure evaluator. No GitHub writes, no network.

Usage:
  fleet-no-agent-names-check --pr-body FILE --commit-range RANGE
  fleet-no-agent-names-check --pr-body FILE
  fleet-no-agent-names-check --commit-range RANGE

The commit-range form runs `git log --no-merges --format=%B RANGE` in the
current repo (or the repo given by --repo).

Exit codes:
  0 — no agent attribution detected (or nothing to check)
  1 — agent attribution detected
  2 — usage error / bad input
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable

# Prepositions/verbs that, when followed by a known agent name, read as
# attribution.  We require the agent to follow the word (with an optional
# "the") to avoid flagging every mention of an AI product in a rule name.
ATTRIBUTION_WORDS = (
    "by",
    "with",
    "via",
    "from",
    "using",
    "through",
    "used",
)

# Agent/service names that must not be named as authors of Nish's work.
# Lowercase; matched case-insensitively as whole words/phrases.
AGENT_NAMES = (
    # named coding agents / assistants
    "devin",
    "claude",
    "codex",
    "grok",
    "supergrok",
    "cursor",
    # model/model-family names that appear as agent identifiers
    "openai",
    "anthropic",
    "deepseek",
    "minimax",
    "commandcode",
    "opus",
    "gemini",
    "fable",
    "sol",
    "luna",
    "chatgpt",
    "bard",
    # coding-assistant products
    "copilot",
    "github copilot",
)

# Line-anchored trailers/footers.  These are always forbidden, regardless of
# where the agent name is on the line.
COAUTHORED_RE = re.compile(r"^[ \t]*co-authored-by:", re.IGNORECASE | re.MULTILINE)
GENERATED_RE = re.compile(
    r"^[ \t]*generated[ \t]+(with|by|using|from)\b",
    re.IGNORECASE | re.MULTILINE,
)


def _agent_pattern() -> re.Pattern[str]:
    """Build a regex for `attribution (the)? <agent>` in a line."""
    escaped: list[str] = []
    for name in AGENT_NAMES:
        # Multi-word phrases need flexible whitespace; single words are bounded.
        if " " in name:
            part = re.escape(name).replace(r"\ ", r"[ \t]+")
            escaped.append(r"\b" + part + r"\b")
        else:
            escaped.append(r"\b" + re.escape(name) + r"\b")
    agents = "|".join(escaped)
    attribs = "|".join(re.escape(w) for w in ATTRIBUTION_WORDS)
    # Require attribution word, optional "the", then a known agent name, all
    # as whole words.  The leading (^|\s) prevents matching partial words like
    # "reminimax".
    return re.compile(
        r"(?:^|\s)(" + attribs + r")[ \t]+(the[ \t]+)?(" + agents + r")\b",
        re.IGNORECASE,
    )


AGENT_ATTRIBUTION_RE = _agent_pattern()


def read_text(path: str | None) -> str:
    if path is None:
        return ""
    if path == "-":
        return sys.stdin.read()
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"fleet-no-agent-names-check: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(2)


def git_log_messages(repo: Path, rev_range: str) -> str:
    """Return the concatenated commit messages for a range."""
    try:
        result = subprocess.run(
            ["git", "log", "--no-merges", "--format=%B", rev_range],
            cwd=repo,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        print(
            "fleet-no-agent-names-check: git is not installed",
            file=sys.stderr,
        )
        sys.exit(2)
    if result.returncode != 0:
        print(
            f"fleet-no-agent-names-check: git log failed: {result.stderr.strip()}",
            file=sys.stderr,
        )
        sys.exit(2)
    return result.stdout


def _matches(text: str, pattern: re.Pattern[str]) -> Iterable[re.Match[str]]:
    """Yield matches with their 1-indexed line numbers."""
    lines = text.splitlines()
    for idx, line in enumerate(lines, start=1):
        for match in pattern.finditer(line):
            yield idx, line, match


def check_text(text: str, label: str) -> list[str]:
    """Return a list of human-readable rejections found in `text`."""
    findings: list[str] = []

    for idx, line, _ in _matches(text, COAUTHORED_RE):
        findings.append(
            f"{label} line {idx}: Co-Authored-By trailer is forbidden: {line.strip()!r}"
        )

    for idx, line, _ in _matches(text, GENERATED_RE):
        findings.append(
            f"{label} line {idx}: Generated-with/by footer is forbidden: {line.strip()!r}"
        )

    for idx, line, _ in _matches(text, AGENT_ATTRIBUTION_RE):
        findings.append(
            f"{label} line {idx}: agent-name attribution is forbidden: {line.strip()!r}"
        )

    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr-body", help="PR body file (or '-' for stdin)")
    parser.add_argument(
        "--commit-range",
        help="Git revision range whose commit messages are checked (e.g. origin/main...HEAD)",
    )
    parser.add_argument(
        "--repo",
        default=".",
        help="Git repo directory for --commit-range (default: current directory)",
    )
    parser.add_argument(
        "--label",
        default="check",
        help="Internal label for findings (default: check)",
    )
    args = parser.parse_args(argv)

    if not args.pr_body and not args.commit_range:
        parser.error("specify --pr-body and/or --commit-range")

    findings: list[str] = []

    if args.pr_body:
        body = read_text(args.pr_body)
        if body.strip():
            findings.extend(check_text(body, "PR body"))

    if args.commit_range:
        repo = Path(args.repo).resolve()
        messages = git_log_messages(repo, args.commit_range)
        if messages.strip():
            findings.extend(check_text(messages, "commit message"))

    if findings:
        print("REJECT: agent attribution found", file=sys.stderr)
        for item in findings:
            print(f"  - {item}", file=sys.stderr)
        return 1

    if args.pr_body and not read_text(args.pr_body).strip() and not args.commit_range:
        print("SKIP: empty PR body and no commit range")
        return 0

    print("OK: no agent attribution detected")
    return 0


if __name__ == "__main__":
    sys.exit(main())
