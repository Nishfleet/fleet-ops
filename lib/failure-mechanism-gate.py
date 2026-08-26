#!/usr/bin/env python3
"""Mechanical-fix gate (fleet-ops#366).

A failure-fix is REJECT unless it ships a class-prevention mechanism or an
explicit `mechanism-impossible:` reason. Pure evaluator: no dispatch, no
GitHub writes, no retry.

Subcommands:
  evaluate (default)  JSON PR description on stdin / --input → verdict JSON
  hunt                closed fixes + current signals → recurrence findings
  --ledger-line       print the decisions-ledger line verbatim
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any

# Verbatim decisions-ledger line (2026-08-26, "every failure gets a mechanical
# fix"). Auditor packets and REJECT verdicts must carry this exact text.
LEDGER_LINE = (
    "STANDING, NON-NEGOTIABLE: a failure is not fixed until its CLASS is "
    "mechanically prevented where possible — fix the instance, then ship the "
    "mechanism (detector that auto-files the ticket, gate that rejects the "
    "pattern, regression test/drill that proves the guard fires, "
    "observe-to-close so \"done\" = detector green, never a merge or a "
    "sentence). If no mechanism is possible, the fix must declare "
    "`mechanism-impossible:` with a reason, judged by the conference and "
    "re-litigable by the blind audit. Enforced mechanically at the senior "
    "conference + blind audit (fleet-ops #366). Origin: 08-26 night — seven "
    "dropped balls (#221/#76/#124 closed-but-undelivered, SKIP spam post-fix, "
    "stale blockers parking #180, swallowed logs, never-run audit) all shared "
    "one cause: fixes without mechanisms."
)

TITLE_FAILURE_FIX = re.compile(
    r"(?i)^\s*(fix\b|revert\b|hotfix\b|auto-revert\b|incident\b)"
)
CONVENTIONAL_PREFIX = re.compile(
    r"(?i)^\s*(fix|feat|chore|revert|hotfix|docs|test|refactor|auto-revert)"
    r"(\([^)]*\))?:\s*"
)
FAILURE_LABELS = {
    "bug",
    "incident",
    "gap-audit",
    "canary",
    "detector",
    "postmortem",
    "auto-revert",
}
MECHANISM_FILE = re.compile(
    r"(?i)(^|/)("
    r"tests/.+"
    r"|[^/]+\.(test|spec)\.(sh|py|mjs|js|ts|tsx)$"
    r"|[^/]+-detector\.(sh|py|mjs|js)$"
    r"|[^/]+-guard\.(sh|py|mjs|js)$"
    r"|[^/]+-canary\.(sh|py|mjs|js)$"
    r"|[^/]*drill[^/]*\.(sh|py|mjs|js)$"
    r")"
)
MECHANISM_DIFF = re.compile(
    r"(?i)(OnFailure=|observe-to-close|mechanism-impossible:"
    r"|gh issue create|auto-filed)"
)
IMPOSSIBLE = re.compile(r"(?im)^[ \t]*mechanism-impossible:[ \t]*\S")
DECLARED = re.compile(r"(?im)^[ \t]*mechanism:[ \t]*\S")


def label_names(labels: Any) -> list[str]:
    out: list[str] = []
    if not isinstance(labels, list):
        return out
    for item in labels:
        if isinstance(item, dict):
            out.append(str(item.get("name") or "").strip().lower())
        else:
            out.append(str(item).strip().lower())
    return [x for x in out if x]


def is_failure_fix(pr: dict[str, Any]) -> bool:
    title = str(pr.get("title") or "")
    if TITLE_FAILURE_FIX.search(title):
        return True
    if set(label_names(pr.get("labels"))) & FAILURE_LABELS:
        return True
    for issue in pr.get("closing_issues") or []:
        if not isinstance(issue, dict):
            continue
        ititle = str(issue.get("title") or "")
        if TITLE_FAILURE_FIX.search(ititle):
            return True
        if set(label_names(issue.get("labels"))) & FAILURE_LABELS:
            return True
    return False


def _blob(pr: dict[str, Any]) -> str:
    parts = [
        str(pr.get("body") or ""),
        "\n".join(str(m) for m in (pr.get("commit_messages") or [])),
        str(pr.get("diff") or ""),
    ]
    return "\n".join(parts)


def mechanism_kind(pr: dict[str, Any]) -> str | None:
    blob = _blob(pr)
    if IMPOSSIBLE.search(blob):
        return "mechanism-impossible"
    if DECLARED.search(blob):
        return "declared-mechanism"
    files = pr.get("files") or []
    for path in files:
        if MECHANISM_FILE.search(str(path).replace("\\", "/")):
            return "regression-test"
    if MECHANISM_DIFF.search(blob):
        return "prevention-wiring"
    return None


def evaluate(pr: dict[str, Any]) -> dict[str, Any]:
    if not is_failure_fix(pr):
        return {
            "verdict": "PASS",
            "reason": "not a failure-fix; mechanical-fix rule does not apply",
        }
    kind = mechanism_kind(pr)
    if kind:
        return {
            "verdict": "PASS",
            "mechanism": kind,
            "reason": f"failure-fix ships {kind}",
        }
    return {
        "verdict": "REJECT",
        "rule": LEDGER_LINE,
        "reason": (
            "failure-fix ships no prevention mechanism and no "
            "mechanism-impossible: declaration (fleet-ops#366)"
        ),
    }


def signal_key(title: str) -> str:
    text = CONVENTIONAL_PREFIX.sub("", title or "")
    text = re.sub(r"#\d+", " ", text)
    text = re.sub(r"[^a-z0-9]+", " ", text.lower()).strip()
    return text


def keys_match(a: str, b: str) -> bool:
    if not a or not b:
        return False
    if a == b:
        return True
    shorter, longer = (a, b) if len(a) <= len(b) else (b, a)
    if len(shorter) < 10:
        return False
    return shorter in longer


def _issue_is_failure_fix(issue: dict[str, Any]) -> bool:
    title = str(issue.get("title") or "")
    if TITLE_FAILURE_FIX.search(title):
        return True
    return bool(set(label_names(issue.get("labels"))) & FAILURE_LABELS)


def _collect_signals(payload: dict[str, Any]) -> list[dict[str, str]]:
    signals: list[dict[str, str]] = list(payload.get("current_signals") or [])
    for unit in payload.get("failed_units") or []:
        name = str(unit).strip()
        if name:
            signals.append(
                {"kind": "failed-unit", "key": signal_key(name), "evidence": name}
            )
    for issue in payload.get("open_issues") or []:
        if not isinstance(issue, dict):
            continue
        title = str(issue.get("title") or "")
        key = signal_key(title)
        if key:
            signals.append(
                {
                    "kind": "open-issue",
                    "key": key,
                    "evidence": f"#{issue.get('number', '?')}: {title}",
                }
            )
    return signals


def _recurrence_finding(
    rank: int,
    closed_num: str,
    closed_key: str,
    issue: dict[str, Any],
    sig: dict[str, str],
) -> dict[str, Any]:
    evidence = str(sig.get("evidence") or "")
    return {
        "rank": rank,
        "title": (
            f"recurred failure class after closed fix #{closed_num}: "
            f"{closed_key[:60]}"
        ),
        "body": (
            "A failure class came back after a closed fix. Same signal key "
            "fired again post-close. Automatic blind-audit finding "
            "(fleet-ops#366)."
        ),
        "severity": "high",
        "evidence": (
            f"closed #{closed_num} {issue.get('title')} "
            f"(closedAt={issue.get('closedAt', '')}); "
            f"live {sig.get('kind')}: {evidence}"
        ),
    }


def hunt(payload: dict[str, Any]) -> dict[str, Any]:
    """Find failure classes that recurred after a closed fix."""
    findings: list[dict[str, Any]] = []
    signals = _collect_signals(payload)
    seen: set[tuple[str, str]] = set()
    rank = 90
    for issue in payload.get("closed_issues") or []:
        if not isinstance(issue, dict) or not _issue_is_failure_fix(issue):
            continue
        closed_num = str(issue.get("number") or "")
        closed_key = signal_key(str(issue.get("title") or ""))
        if not closed_key:
            continue
        for sig in signals:
            evidence = str(sig.get("evidence") or "")
            # Fixtures may echo the same issue as closed and open; real GitHub
            # cannot. Skip same-number pairs.
            if closed_num and f"#{closed_num}:" in evidence:
                continue
            if not keys_match(closed_key, str(sig.get("key") or "")):
                continue
            pair = (closed_num, evidence)
            if pair in seen:
                continue
            seen.add(pair)
            findings.append(
                _recurrence_finding(rank, closed_num, closed_key, issue, sig)
            )
            rank += 1
    return {"findings": findings}


def _load_input(path: str | None) -> dict[str, Any]:
    if path in (None, "-", ""):
        raw = sys.stdin.read()
    else:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    if not raw.strip():
        raise SystemExit("empty input")
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise SystemExit("input must be a JSON object")
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Mechanical-fix gate (fleet-ops#366). Pure evaluator."
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="evaluate",
        choices=["evaluate", "hunt"],
        help="evaluate a PR (default) or hunt recurred failure classes",
    )
    parser.add_argument("--input", "-i", help="JSON file (default: stdin)")
    parser.add_argument(
        "--ledger-line",
        action="store_true",
        help="print the decisions-ledger line verbatim and exit 0",
    )
    args = parser.parse_args(argv)

    if args.ledger_line:
        sys.stdout.write(LEDGER_LINE + "\n")
        return 0

    payload = _load_input(args.input)
    if args.command == "hunt":
        json.dump(hunt(payload), sys.stdout)
        sys.stdout.write("\n")
        return 0

    verdict = evaluate(payload)
    json.dump(verdict, sys.stdout)
    sys.stdout.write("\n")
    return 0 if verdict.get("verdict") == "PASS" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except json.JSONDecodeError as exc:
        print(json.dumps({"verdict": "REJECT", "reason": f"invalid JSON: {exc}"}))
        raise SystemExit(2) from exc
