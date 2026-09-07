#!/usr/bin/env python3
"""Closed-but-undelivered detector (fleet-ops#3683).

A "closed-but-undelivered delivery" is an issue that was closed after a PR
tried to deliver it, but none of the PRs that reference the issue ever
merged — the delivery never landed. This is the class behind the 08-26
incident (#221/#76/#124 closed-but-undelivered) and the manual seam filed
in fleet-ops#3683: a human had to hand-verify four such deliveries because
no mechanical detector flagged them.

Pure evaluator: no dispatch, no GitHub writes, no retry. The blind-audit
harness fetches `closed_issues` (with `closedByPullRequestsReferences`) and
`merged_prs` and pipes them to `hunt`, exactly like the fleet-ops#366
recurrence hunt. Findings flow through the existing panel + filing path, so
observe-to-close is the same as every other gap-audit finding: once a merged
PR lands for the issue, `closedByPullReferences` includes a merged PR and the
detector stops flagging it; the filed gap-audit issue is then closed by the
existing staleness/triage observe-to-close path.

What this is NOT:
  - It does NOT flag issues closed with no PR references at all (those are
    closed by hand for other reasons — duplicate, wontfix, decision — and
    would be noisy). It only flags issues where a delivery was *attempted*
    (a PR referenced the issue) but never landed (no referenced PR merged).
  - It does NOT flag issues carrying an exclusion label (duplicate / invalid
    / wontfix / triage-mass-close / staleness-detector): a closed unmerged
    PR on those is expected, not a dropped ball.

Subcommand:
  hunt (default)   JSON {closed_issues, merged_prs} on stdin / --input
                   → {"findings": [...]} on stdout, exit 0
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any

# Labels that make a closed-with-unmerged-PR issue legitimate (not a dropped
# delivery). A closed unmerged PR on a duplicate / wontfix / invalid / mass-
# triage / staleness issue is expected, not a closed-but-undelivered ball.
EXCLUSION_LABELS = {
    "duplicate",
    "invalid",
    "wontfix",
    "triage-mass-close",
    "staleness-detector",
}

CLOSES_RE = re.compile(r"(?i)(?:clos(?:e[sd]?|ing)|fix(?:e[sd]?|ing)?|resolv(?:e[sd]?|ing)|implement(?:s|ed|ing)?)\s+#(\d+)")


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


def ref_pr_numbers(issue: dict[str, Any]) -> list[int]:
    out: list[int] = []
    refs = issue.get("closedByPullRequestsReferences") or []
    if not isinstance(refs, list):
        return out
    for r in refs:
        if not isinstance(r, dict):
            continue
        try:
            out.append(int(r.get("number")))
        except (TypeError, ValueError):
            continue
    return out


def merged_pr_numbers(merged_prs: Any) -> set[int]:
    out: set[int] = set()
    if not isinstance(merged_prs, list):
        return out
    for pr in merged_prs:
        if isinstance(pr, dict):
            try:
                out.add(int(pr.get("number")))
            except (TypeError, ValueError):
                continue
        else:
            try:
                out.add(int(pr))
            except (TypeError, ValueError):
                continue
    return out


def is_excluded(issue: dict[str, Any]) -> bool:
    return bool(set(label_names(issue.get("labels"))) & EXCLUSION_LABELS)


def hunt(payload: dict[str, Any]) -> dict[str, Any]:
    """Flag closed issues whose referencing PRs never merged."""
    findings: list[dict[str, Any]] = []
    merged = merged_pr_numbers(payload.get("merged_prs"))
    rank = 70
    for issue in payload.get("closed_issues") or []:
        if not isinstance(issue, dict):
            continue
        refs = ref_pr_numbers(issue)
        if not refs:
            # No PR tried to deliver this issue — closed by hand for another
            # reason. Not a "delivery", so not this detector's beat.
            continue
        if is_excluded(issue):
            continue
        delivered = any(num in merged for num in refs)
        if delivered:
            continue
        num = issue.get("number", "?")
        title = str(issue.get("title") or "").strip()
        closed_at = issue.get("closedAt", "")
        refs_str = ", ".join(f"#{n}" for n in refs)
        findings.append(
            {
                "rank": rank,
                "title": (
                    f"closed-but-undelivered: issue #{num} closed with no "
                    f"merged PR ({refs_str})"
                ),
                "body": (
                    "An issue was closed after a PR tried to deliver it, but "
                    "none of the referencing PRs merged — the delivery never "
                    "landed. This is the class behind the 08-26 incident "
                    "(#221/#76/#124) and fleet-ops#3683. Confirm the "
                    "referencing PR(s) were closed without merging; if the "
                    "work is still wanted, re-open the issue or re-land the "
                    "delivery via a fresh PR. Automatic closed-but-undelivered "
                    "detector finding (fleet-ops#3683)."
                ),
                "severity": "high",
                "evidence": (
                    f"closed #{num} {title} (closedAt={closed_at}); "
                    f"referencing PRs: {refs_str}; none in the merged set"
                ),
            }
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
        description="Closed-but-undelivered detector (fleet-ops#3683). Pure evaluator."
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="hunt",
        choices=["hunt"],
        help="hunt closed-but-undelivered issues (default and only command)",
    )
    parser.add_argument("--input", "-i", help="JSON file (default: stdin)")
    args = parser.parse_args(argv)

    payload = _load_input(args.input)
    json.dump(hunt(payload), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except json.JSONDecodeError as exc:
        print(json.dumps({"findings": [], "error": f"invalid JSON: {exc}"}))
        raise SystemExit(2) from exc
