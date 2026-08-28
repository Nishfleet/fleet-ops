#!/usr/bin/env python3
"""Loose-ends detector for sr-nothing-half-done (fleet-ops#528).

Standing rule: nothing sits half-done, and no question dies unanswered
(Nish, 2026-08-20). Three detection classes:

  1. Unanswered questions — QUESTIONS.md rows in OPEN status, or HOLD
     past its return date. Either is a question the rule says must be
     re-asked every 24h.
  2. Half-done PRs — open MERGEABLE PRs on enrolled repos whose
     createdAt is older than the idle window. The branch is green but
     not landing; either it gets auto-merge armed or the worker is
     missing in action.
  3. Half-done worktrees — agent-worktrees whose HEAD is older than
     the idle window AND no live claim worker unit is running against
     them. Either complete or discard; an idle dirty tree is not a
     resting state.

Pure logic. JSON in, JSON out. gh + git + systemd live in bash; tests
import these functions and the bash wrapper invokes them as a CLI.

Usage:
  python3 lib/loose-ends.py questions --questions PATH [--now ISO]
  python3 lib/loose-ends.py prs --prs PATH [--now ISO] [--window-hours 24]
  python3 lib/loose-ends.py worktrees --worktrees PATH --live-units PATH
      [--now ISO] [--window-hours 24]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from typing import Any


# --- QUESTIONS.md parser ---------------------------------------------------

# A row in the QUESTIONS.md ledger table. Pipes (`|`) are the column
# separator — the rule text says so explicitly and embedded pipes break
# the parse. We keep this strict so a malformed row is loud, not silent.
QUESTION_ROW_RE = re.compile(
    r"^\|\s*(?P<date>\d{4}-\d{2}-\d{2})\s*\|\s*(?P<question>[^|]+?)\s*"
    r"\|\s*(?P<askedby>[^|]+?)\s*\|\s*(?P<status>[^|]+?)\s*\|\s*$"
)
HOLD_UNTIL_RE = re.compile(r"^\s*HOLD\s+until=(\d{4}-\d{2}-\d{2})\s*$", re.I)
# The rule spec is "ANSWERED <YYYY-MM-DD>"; live rows use a free-text
# suffix after the date (e.g. "ANSWERED 2026-08-20 (proof run, telegram
# receipt logged)"). We accept the date prefix and ignore the rest so
# a parenthetical reason does not push a resolved row into nag-targets.
ANSWERED_RE = re.compile(r"^\s*ANSWERED(?:\s+(\d{4}-\d{2}-\d{2}))?(?:\s.*)?$", re.I)
WITHDRAWN_RE = re.compile(r"^\s*WITHDRAWN(?:\s+(\d{4}-\d{2}-\d{2}))?(?:\s.*)?$", re.I)
STATUS_OPEN_RE = re.compile(r"^\s*OPEN\s*$", re.I)
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def parse_questions(text: str, now: float) -> dict[str, Any]:
    """Parse QUESTIONS.md and return nag-targets (OPEN / expired HOLD)."""
    rows = []
    open_rows = []
    expired_holds = []
    answered = 0
    withdrawn = 0
    parse_errors: list[str] = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if not line.startswith("|"):
            continue
        # Skip the header and separator rows.
        if "Question" in line and "Asked-by" in line and "Status" in line:
            continue
        if re.match(r"^\|[-\s|]+\|$", line):
            continue
        m = QUESTION_ROW_RE.match(line)
        if not m:
            # A pipe row that does not match the four-column shape. Surface
            # the line number in parse_errors so a malformed ledger is not
            # silently classified as "no nag targets".
            if line.count("|") >= 3:
                parse_errors.append(f"line {lineno}: malformed row")
            continue
        asked = m.group("date").strip()
        question = m.group("question").strip()
        askedby = m.group("askedby").strip()
        status = m.group("status").strip()
        rows.append(
            {
                "lineno": lineno,
                "asked": asked,
                "question": question,
                "asked_by": askedby,
                "status_raw": status,
            }
        )
        if STATUS_OPEN_RE.match(status):
            open_rows.append(
                {
                    "lineno": lineno,
                    "asked": asked,
                    "question": question,
                    "asked_by": askedby,
                    "status": "OPEN",
                    "kind": "open-question",
                    "slug": f"questions.md:L{lineno}:{asked}",
                }
            )
            continue
        hold = HOLD_UNTIL_RE.match(status)
        if hold:
            until = hold.group(1)
            if DATE_RE.match(until):
                until_ts = datetime.fromisoformat(until).replace(
                    tzinfo=timezone.utc
                ).timestamp()
                if until_ts < now:
                    expired_holds.append(
                        {
                            "lineno": lineno,
                            "asked": asked,
                            "question": question,
                            "asked_by": askedby,
                            "status": f"HOLD until={until}",
                            "kind": "expired-hold",
                            "hold_until": until,
                            "slug": f"questions.md:L{lineno}:{asked}",
                        }
                    )
                continue
            parse_errors.append(
                f"line {lineno}: HOLD until= must be YYYY-MM-DD, got {until!r}"
            )
            continue
        if ANSWERED_RE.match(status):
            answered += 1
            continue
        if WITHDRAWN_RE.match(status):
            withdrawn += 1
            continue
        parse_errors.append(
            f"line {lineno}: status must be OPEN, ANSWERED, "
            f"WITHDRAWN, or HOLD until=YYYY-MM-DD, got {status!r}"
        )
    return {
        "rows_total": len(rows),
        "answered": answered,
        "withdrawn": withdrawn,
        "nag_targets": open_rows + expired_holds,
        "parse_errors": parse_errors,
    }


# --- PR classifier ---------------------------------------------------------

# Branch prefixes that mark a worker-owned, claim-scoped PR. The rule
# says "no half-done work sits around" — worker PRs >24h old that are
# still open are the loudest class. Non-worker PRs (human-authored,
# scheduled, security) stay quiet unless explicitly enrolled.
WORKER_BRANCH_PREFIXES = ("claim/issue-", "claim/fix-", "claim/feat-")


def _branch_is_worker(head_ref: str, author_login: str) -> bool:
    if author_login.startswith("nishfleet-worker") or "nishfleet-worker" in author_login:
        return True
    return any(head_ref.startswith(p) for p in WORKER_BRANCH_PREFIXES)


def classify_prs(
    prs: list[dict[str, Any]], now: float, window_hours: float
) -> dict[str, Any]:
    """Return worker-owned open PRs older than the idle window."""
    window_s = max(window_hours, 0) * 3600
    findings = []
    skipped_human = 0
    skipped_fresh = 0
    skipped_draft = 0
    scanned = 0
    for pr in prs:
        if not isinstance(pr, dict):
            continue
        scanned += 1
        head_ref = str(pr.get("headRefName") or "")
        author = pr.get("author") or {}
        if isinstance(author, dict):
            author_login = str(author.get("login") or "")
        else:
            author_login = str(author or "")
        if not _branch_is_worker(head_ref, author_login):
            skipped_human += 1
            continue
        created = str(pr.get("createdAt") or "").strip()
        if not created:
            skipped_fresh += 1
            continue
        if created.endswith("Z"):
            created = created[:-1] + "+00:00"
        try:
            created_ts = datetime.fromisoformat(created).timestamp()
        except ValueError:
            skipped_fresh += 1
            continue
        age_h = (now - created_ts) / 3600.0
        if age_h < 0:
            # Clock skew — treat as fresh, do not nag on future-dated rows.
            skipped_fresh += 1
            continue
        if age_h < window_hours:
            skipped_fresh += 1
            continue
        if bool(pr.get("isDraft")):
            skipped_draft += 1
            continue
        # autoMerge.enabled is the loudest "landed or landing" signal.
        # A worker PR that is older than the window AND still has autoMerge
        # off is the live half-done class. autoMerge on is green in flight.
        am = pr.get("autoMergeRequest") or pr.get("autoMerge") or {}
        if isinstance(am, dict) and am.get("enabled"):
            continue
        number = pr.get("number")
        repo = str(pr.get("repo") or "")
        url = str(pr.get("url") or "")
        slug = f"{repo}#{number}" if repo and number is not None else str(number)
        findings.append(
            {
                "slug": slug,
                "repo": repo,
                "number": number,
                "url": url,
                "headRefName": head_ref,
                "title": str(pr.get("title") or ""),
                "createdAt": pr.get("createdAt"),
                "age_hours": round(age_h, 1),
                "kind": "stale-worker-pr",
            }
        )
    return {
        "scanned": scanned,
        "skipped_human": skipped_human,
        "skipped_fresh": skipped_fresh,
        "skipped_draft": skipped_draft,
        "findings": findings,
    }


# --- Worktree classifier ---------------------------------------------------

# Worker unit names that match the worker's claim surface. A live unit
# against a worktree means the worker is actively running, even if HEAD
# is stale (e.g. mid-rebase). A stale worktree with NO live unit is the
# half-done class.
WORKER_UNIT_RE = re.compile(
    r"^(?:pi-issue-[a-z0-9._-]+|pi-packet-[a-z0-9._-]+|pi-scout-[a-z0-9._-]+"
    r"|pi-intake-repair-[a-z0-9._-]+|pi-audit-[a-z0-9._-]+|pi-researcher-[a-z0-9._-]+)$"
)


def parse_live_units(text: str) -> set[str]:
    """Return worktree paths referenced by currently active worker units.

    systemd's `systemctl --user list-units --type=service --state=running
    --no-legend` style output is two columns: NAME + LOAD/ACTIVE/SUB. The
    unit name carries the worktree identifier when it is per-worktree.
    """
    live: set[str] = set()
    if not text.strip():
        return live
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        # Bare unit name on each line — match the worker pattern and
        # surface any path suffix the unit-name convention uses. The
        # current convention keeps the worktree path implicit in the
        # cwd of the worker, so the live set here is keyed on unit
        # name. The shell wrapper joins unit name <-> worktree path
        # via a fixture so we only need the unit NAME here.
        m = WORKER_UNIT_RE.match(line)
        if m:
            live.add(line)
    return live


def classify_worktrees(
    worktree_records: list[dict[str, Any]],
    live_units: set[str],
    now: float,
    window_hours: float,
) -> dict[str, Any]:
    """Return dirty/stale worktrees with no live worker unit.

    Each record carries:
      path, branch, last_commit_ts (epoch seconds), dirty (bool), live
      (bool — whether any worker unit name carries the branch), unit
      (the unit name when live).
    """
    window_s = max(window_hours, 0) * 3600
    findings = []
    skipped_clean = 0
    skipped_fresh = 0
    skipped_live = 0
    scanned = 0
    for rec in worktree_records:
        if not isinstance(rec, dict):
            continue
        scanned += 1
        path = str(rec.get("path") or "")
        branch = str(rec.get("branch") or "")
        last_commit_ts = rec.get("last_commit_ts")
        dirty = bool(rec.get("dirty"))
        live = bool(rec.get("live"))
        unit = str(rec.get("unit") or "")
        if not dirty and not (isinstance(last_commit_ts, (int, float))
                              and now - last_commit_ts > window_s):
            skipped_clean += 1
            continue
        # A worktree that is dirty OR whose last commit is older than the
        # window is the half-done class, BUT only if no live worker unit
        # is touching it. A worker mid-rebase has a stale HEAD and dirty
        # state — that is allowed.
        if live or (unit and unit in live_units):
            skipped_live += 1
            continue
        age_h = None
        if isinstance(last_commit_ts, (int, float)):
            age_h = round((now - last_commit_ts) / 3600.0, 1)
        if age_h is None or age_h < window_hours:
            skipped_fresh += 1
            continue
        slug = branch or path or "unknown-worktree"
        findings.append(
            {
                "slug": slug,
                "path": path,
                "branch": branch,
                "dirty": dirty,
                "last_commit_ts": last_commit_ts,
                "age_hours": age_h,
                "kind": "stale-worktree",
            }
        )
    return {
        "scanned": scanned,
        "skipped_clean": skipped_clean,
        "skipped_fresh": skipped_fresh,
        "skipped_live": skipped_live,
        "findings": findings,
    }


def parse_now(value: str | None) -> float:
    if not value:
        return datetime.now(timezone.utc).timestamp()
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    return datetime.fromisoformat(text).timestamp()


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="loose-ends")
    sub = parser.add_subparsers(dest="cmd", required=True)

    q = sub.add_parser("questions")
    q.add_argument("--questions", required=True)
    q.add_argument("--now", default="")

    p = sub.add_parser("prs")
    p.add_argument("--prs", required=True)
    p.add_argument("--now", default="")
    p.add_argument("--window-hours", type=float, default=24.0)

    w = sub.add_parser("worktrees")
    w.add_argument("--worktrees", required=True,
                   help="JSON array of worktree records (path/branch/"
                        "last_commit_ts/dirty/live/unit)")
    w.add_argument("--live-units", required=True,
                   help="Plain-text list of active worker unit names")
    w.add_argument("--now", default="")
    w.add_argument("--window-hours", type=float, default=24.0)

    args = parser.parse_args(argv)
    try:
        now = parse_now(args.now or None)
    except ValueError as exc:
        print(f"BROKEN: invalid --now timestamp: {exc}", file=sys.stderr)
        return 2

    if args.cmd == "questions":
        try:
            text = _read(args.questions)
        except OSError as exc:
            print(f"BROKEN: cannot read questions file: {exc}",
                  file=sys.stderr)
            return 2
        report = parse_questions(text, now)
        json.dump(report, sys.stdout)
        sys.stdout.write("\n")
        return 0

    if args.cmd == "prs":
        try:
            raw = _read(args.prs)
        except OSError as exc:
            print(f"BROKEN: cannot read prs file: {exc}", file=sys.stderr)
            return 2
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            print(f"BROKEN: prs file is not JSON: {exc}", file=sys.stderr)
            return 2
        if not isinstance(data, list):
            print("BROKEN: prs file must be a JSON array", file=sys.stderr)
            return 2
        report = classify_prs(data, now, args.window_hours)
        json.dump(report, sys.stdout)
        sys.stdout.write("\n")
        return 0

    if args.cmd == "worktrees":
        try:
            raw = _read(args.worktrees)
        except OSError as exc:
            print(f"BROKEN: cannot read worktrees file: {exc}",
                  file=sys.stderr)
            return 2
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            print(f"BROKEN: worktrees file is not JSON: {exc}",
                  file=sys.stderr)
            return 2
        if not isinstance(data, list):
            print("BROKEN: worktrees file must be a JSON array",
                  file=sys.stderr)
            return 2
        try:
            live_text = _read(args.live_units)
        except OSError as exc:
            print(f"BROKEN: cannot read live-units file: {exc}",
                  file=sys.stderr)
            return 2
        live = parse_live_units(live_text)
        report = classify_worktrees(data, live, now, args.window_hours)
        json.dump(report, sys.stdout)
        sys.stdout.write("\n")
        return 0

    return 2


if __name__ == "__main__":
    sys.exit(main())