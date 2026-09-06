#!/usr/bin/env python3
"""PR-body receipt check for Execution IS the review (fleet-ops#537).

The standing rule's failure mode is a worker that skipped the run: a PR
opened with no journal/proof receipt. The inner loop stays agentic
(no bin/exec-review dispatcher). This helper only classifies a body.

A body has a receipt when either:
  1. A `run-proof:` line with a non-empty value, or
  2. A Verification: section (heading or inline) carrying a run-cue:
     journalctl, systemctl, https?://, exit N, rc=N, a fenced code
     block, ALL PHASES PASSED, a `$ ` prompt line, or `ok: N`.

Same cues as bin/prove-one-run-check. That checker only fires for a
NEW unit/timer/workflow. This one fires for every worker PR.

Usage:
  python3 lib/exec-review-receipt.py check --body FILE
  python3 lib/exec-review-receipt.py scan --prs FILE [--now ISO]
      [--window-hours 24]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from typing import Any

RUN_PROOF_RE = re.compile(r"^[\t ]*run-proof:[\t ]+\S+", re.M)
# Section marker: a markdown heading, a bold heading, or a "Name:" line
# that opens an evidence section. fleet-ops#3731: the fleet's real bodies
# use three section names — Verification, Test plan, run-proof — so all
# three open a section. "Test plan" is restricted to heading/bold/line-
# start forms: mid-sentence "the test plan:" is prose, not a section.
VERIFICATION_RE = re.compile(
    r"(?:^#+\s+(?:[Vv]erification|[Tt]est[ \t]+[Pp]lan|[Rr]un-?[Pp]roof):?[\t ]*\*?[\t ]*$"
    r"|\*{2}[\t ]*(?:[Vv]erification|[Tt]est[ \t]+[Pp]lan|[Rr]un-?[Pp]roof):?[\t ]*\*{0,2}[\t ]*$"
    r"|^[Tt]est[ \t]+[Pp]lan:[\t ]*"
    r"|(?:^|[\t ])[Vv]erification:[\t ]*)"
)
JOURNALCTL_RE = re.compile(r"(^|[^A-Za-z0-9_])journalctl([^A-Za-z0-9_]|$)")
SYSTEMCTL_RE = re.compile(r"(^|[^A-Za-z0-9_])systemctl([^A-Za-z0-9_]|$)")
EXIT_RE = re.compile(r"exit[\t ]+[0-9]")
RC_RE = re.compile(r"rc=[0-9]")
PROMPT_RE = re.compile(r"^[\t ]*\$ ")
OK_N_RE = re.compile(r"ok: [0-9]")
# fleet-ops#3731: the dominant evidence formats in merged worker PRs are
# "- [x] `cmd` — result" test-plan checkboxes and "- `cmd` — result"
# verification bullets — neither carries a magic keyword, so the keyword
# list alone classified verified PRs as no-receipt (5 of 60 in the
# 2026-09-05/06 24h merged sample, all five carrying real run evidence).
# A backticked span whose first token is a runner (or a ./path, or a
# *.sh script) inside an evidence section is itself the cue. An
# unchecked "- [ ]" box is a plan, not a run — it never counts.
UNCHECKED_BOX_RE = re.compile(r"^[\t ]*[-*+][\t ]+\[[ \t]\]")
CHECKED_BOX_RE = re.compile(r"^[\t ]*[-*+][\t ]+\[[xX]\]")
BACKTICK_SPAN_RE = re.compile(r"`([^`\n]+)`")
# A checked test-plan box without a backticked command still counts when
# it names a result ("- [x] fleet-restore-drill passes: ...", fleet-ops
# #3627). An unchecked box never does — it is a plan, not a run.
CHECKED_RESULT_RE = re.compile(
    r"\b(pass|passes|passed|green|clean|verified|ok)\b|exit[\t ]+[0-9]",
    re.I,
)
COMMAND_RUNNERS = frozenset(
    {
        "bash", "sh", "python", "python3", "node", "npm", "npx", "pnpm",
        "yarn", "bun", "deno", "vitest", "playwright", "pytest", "make",
        "curl", "gh", "git", "systemctl", "journalctl", "sgscan", "cargo",
        "terraform", "wrangler", "docker", "kubectl", "pi",
        "pi-systemd-run", "go",
    }
)


def _has_backticked_command(line: str) -> bool:
    for m in BACKTICK_SPAN_RE.finditer(line):
        tokens = m.group(1).strip().split()
        if not tokens:
            continue
        first = tokens[0]
        if (
            first in COMMAND_RUNNERS
            or first.startswith("./")
            or first.endswith(".sh")
        ):
            return True
    return False

WORKER_LOGINS = frozenset(
    {
        "app/nishfleet-worker",
        "nishfleet-worker[bot]",
        "nishfleet-worker",
    }
)


def has_receipt(body: str) -> bool:
    text = body or ""
    if RUN_PROOF_RE.search(text):
        return True
    in_v = False
    for line in text.splitlines():
        if VERIFICATION_RE.search(line):
            in_v = True
        if not in_v:
            continue
        if UNCHECKED_BOX_RE.match(line):
            continue
        if (
            _has_backticked_command(line)
            or (
                CHECKED_BOX_RE.match(line) and CHECKED_RESULT_RE.search(line)
            )
            or JOURNALCTL_RE.search(line)
            or SYSTEMCTL_RE.search(line)
            or "http://" in line
            or "https://" in line
            or EXIT_RE.search(line)
            or RC_RE.search(line)
            or "```" in line
            or "ALL PHASES PASSED" in line
            or PROMPT_RE.match(line)
            or OK_N_RE.search(line)
        ):
            return True
    return False


def parse_now(value: str | None) -> float:
    if not value:
        return datetime.now(timezone.utc).timestamp()
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    return datetime.fromisoformat(text).timestamp()


def _author_login(pr: dict[str, Any]) -> str:
    author = pr.get("author")
    if isinstance(author, dict):
        return str(author.get("login") or "")
    return ""


def is_worker_pr(pr: dict[str, Any]) -> bool:
    login = _author_login(pr)
    if login in WORKER_LOGINS:
        return True
    if "nishfleet-worker" in login:
        return True
    head = str(pr.get("headRefName") or "")
    return head.startswith("claim/issue-")


def _created_ts(pr: dict[str, Any]) -> float | None:
    raw = str(pr.get("createdAt") or "").strip()
    if not raw:
        return None
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(raw).timestamp()
    except ValueError:
        return None


def scan_prs(
    prs: list[dict[str, Any]],
    now: float,
    window_hours: float,
) -> dict[str, Any]:
    window_s = max(window_hours, 0) * 3600
    findings: list[dict[str, Any]] = []
    skipped_old = 0
    skipped_human = 0
    skipped_receipt = 0
    scanned = 0
    for pr in prs:
        if not isinstance(pr, dict):
            continue
        scanned += 1
        if not is_worker_pr(pr):
            skipped_human += 1
            continue
        created = _created_ts(pr)
        if created is None or (now - created) > window_s or created > now + 60:
            skipped_old += 1
            continue
        if has_receipt(str(pr.get("body") or "")):
            skipped_receipt += 1
            continue
        number = pr.get("number")
        repo = str(pr.get("repo") or "")
        slug = f"{repo}#{number}" if repo and number is not None else str(number)
        findings.append(
            {
                "slug": slug,
                "repo": repo,
                "number": number,
                "url": str(pr.get("url") or ""),
                "headRefName": str(pr.get("headRefName") or ""),
                "title": str(pr.get("title") or ""),
                # fleet-ops#3731: an ARMED no-receipt PR is the silent
                # pass this gate exists to close — the caller disarms it.
                "auto_merge_armed": bool(pr.get("autoMergeRequest")),
            }
        )
    return {
        "scanned": scanned,
        "skipped_old": skipped_old,
        "skipped_human": skipped_human,
        "skipped_receipt": skipped_receipt,
        "findings": findings,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="exec-review-receipt")
    sub = parser.add_subparsers(dest="cmd", required=True)

    check_p = sub.add_parser("check")
    check_p.add_argument("--body", required=True)

    scan_p = sub.add_parser("scan")
    scan_p.add_argument("--prs", required=True)
    scan_p.add_argument("--now", default="")
    scan_p.add_argument("--window-hours", type=float, default=24.0)

    args = parser.parse_args(argv)
    if args.cmd == "check":
        try:
            body = open(args.body, encoding="utf-8").read()
        except OSError as exc:
            print(f"REJECT: cannot read body file: {exc}", file=sys.stderr)
            return 2
        if has_receipt(body):
            print("OK: Verification/run-proof receipt present")
            return 0
        print(
            "REJECT: no run receipt. Add a Verification or Test plan "
            "section carrying a real run-cue (a backticked command, "
            "journalctl, systemctl, URL, exit N, rc=N, a fenced block, "
            "ALL PHASES PASSED, a `$ ` prompt line, `ok: N`, or a "
            "checked `- [x] \\`cmd\\`` box) or a run-proof: line. A "
            "worker that skipped the run is not done.",
            file=sys.stderr,
        )
        return 1

    try:
        raw = open(args.prs, encoding="utf-8").read()
        data = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"BROKEN: cannot parse prs json: {exc}", file=sys.stderr)
        return 2
    if not isinstance(data, list):
        print("BROKEN: prs json must be an array", file=sys.stderr)
        return 2
    prs = [row for row in data if isinstance(row, dict)]
    now = parse_now(args.now or None)
    report = scan_prs(prs, now, args.window_hours)
    json.dump(report, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
