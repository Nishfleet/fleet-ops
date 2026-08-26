#!/usr/bin/env python3
"""Worktree/PR orphan + unanswered-question scan (fleet-ops#528).

Standing rule: nothing sits half-done, and no question dies unanswered.
This helper is pure classification. Filing and Telegram nag live in
bin/fleet-nothing-half-done.

Usage:
  python3 lib/nothing-half-done.py scan \\
      --worktree-root DIR --live-units-file FILE \\
      [--prs-file FILE] [--questions-file FILE] [--nag-state FILE] \\
      [--now ISO] [--idle-hours 24] [--nag-after-hours 24]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any

SLUG_RE = re.compile(r"[^a-z0-9]+")
HOLD_RE = re.compile(r"HOLD\s+until=(\d{4}-\d{2}-\d{2})", re.I)
TABLE_ROW_RE = re.compile(r"^\|(.+)\|$")


def parse_now(value: str | None) -> float:
    if not value:
        return datetime.now(timezone.utc).timestamp()
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    return datetime.fromisoformat(text).timestamp()


def now_dt(now: float) -> datetime:
    return datetime.fromtimestamp(now, tz=timezone.utc)


def slugify(text: str, limit: int = 80) -> str:
    slug = SLUG_RE.sub("-", text.lower()).strip("-")
    return (slug or "item")[:limit]


def git(path: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", path, *args],
        capture_output=True,
        text=True,
        check=False,
    )


def is_git_dir(path: str) -> bool:
    git_path = os.path.join(path, ".git")
    return os.path.isdir(git_path) or os.path.isfile(git_path)


def load_lines(path: str) -> list[str]:
    if not path or not os.path.isfile(path):
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            return [ln.strip() for ln in fh if ln.strip()]
    except OSError:
        return []


def unit_holds(name: str, units: list[str]) -> bool:
    """True when a live unit name is this worktree's worker."""
    variants = {name.lower()}
    if name.lower().startswith("issue-"):
        variants.add(name.lower()[len("issue-") :])
    for unit in units:
        ul = unit.lower()
        for variant in variants:
            if not variant:
                continue
            if ul == variant or ul.startswith(variant + ".") or ul.startswith(variant + "@"):
                return True
            if f"@{variant}." in ul or ul.endswith("@" + variant):
                return True
            if ul.endswith("@" + variant + ".service"):
                return True
    return False


def max_mtime(path: str, now: float) -> float:
    newest = 0.0
    count = 0
    for dirpath, dirnames, filenames in os.walk(path):
        dirnames[:] = [d for d in dirnames if d not in {".git", "node_modules", ".venv"}]
        for name in filenames:
            full = os.path.join(dirpath, name)
            try:
                newest = max(newest, os.path.getmtime(full))
            except OSError:
                continue
            count += 1
            if count >= 4000:
                return newest or now
    if newest <= 0.0:
        try:
            return os.path.getmtime(path)
        except OSError:
            return now
    return newest


def git_dirty(path: str) -> bool:
    result = git(path, "status", "--porcelain", "--untracked-files=all")
    if result.returncode != 0:
        return False
    return bool(result.stdout.strip())


def git_unpushed(path: str) -> bool:
    branch = git(path, "rev-parse", "--abbrev-ref", "HEAD")
    if branch.returncode != 0:
        return False
    name = (branch.stdout or "").strip()
    if name in {"main", "master", "HEAD"}:
        ahead = git(path, "rev-list", "--count", "origin/main..HEAD")
        if ahead.returncode != 0:
            ahead = git(path, "rev-list", "--count", "origin/master..HEAD")
        if ahead.returncode != 0:
            return False
        try:
            return int((ahead.stdout or "0").strip() or "0") > 0
        except ValueError:
            return False
    upstream = git(path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    if upstream.returncode != 0:
        return True
    ahead = git(path, "rev-list", "--count", "@{upstream}..HEAD")
    if ahead.returncode != 0:
        return True
    try:
        return int((ahead.stdout or "0").strip() or "0") > 0
    except ValueError:
        return True


def scan_worktrees(
    root: str,
    now: float,
    idle_hours: float,
    units: list[str],
) -> tuple[list[dict[str, str]], int]:
    findings: list[dict[str, str]] = []
    scanned = 0
    if not os.path.isdir(root):
        return findings, scanned
    idle_s = max(0.0, float(idle_hours)) * 3600.0
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return findings, scanned
    for name in names:
        path = os.path.join(root, name)
        if not os.path.isdir(path) or not is_git_dir(path):
            continue
        scanned += 1
        if unit_holds(name, units):
            continue
        age = now - max_mtime(path, now)
        if age < idle_s:
            continue
        dirty = git_dirty(path)
        unpushed = git_unpushed(path)
        if not dirty and not unpushed:
            continue
        reasons = []
        if dirty:
            reasons.append("dirty")
        if unpushed:
            reasons.append("unpushed")
        hours = int(age // 3600)
        findings.append(
            {
                "kind": "worktree",
                "slug": slugify(f"worktree-{name}"),
                "path": path,
                "reason": f"{', '.join(reasons)}, idle {hours}h",
            }
        )
    return findings, scanned


def parse_iso(value: str) -> float | None:
    text = (value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def classify_prs(
    prs: list[dict[str, Any]],
    now: float,
    idle_hours: float,
) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    idle_s = max(0.0, float(idle_hours)) * 3600.0
    for pr in prs:
        if not isinstance(pr, dict):
            continue
        if pr.get("isDraft") is True:
            continue
        created = parse_iso(str(pr.get("createdAt") or ""))
        if created is None or (now - created) < idle_s:
            continue
        mergeable = str(pr.get("mergeable") or "").upper()
        if mergeable and mergeable != "MERGEABLE":
            continue
        auto = pr.get("autoMergeRequest")
        if auto:
            continue
        number = pr.get("number")
        repo = str(pr.get("repository") or pr.get("repo") or "repo")
        url = str(pr.get("url") or "")
        title = str(pr.get("title") or "")
        slug = slugify(f"pr-{repo}-{number}")
        hours = int((now - created) // 3600)
        findings.append(
            {
                "kind": "pr",
                "slug": slug,
                "path": url or f"{repo}#{number}",
                "reason": f"green unmerged PR #{number} idle {hours}h, auto-merge off — {title}"[:240],
            }
        )
    return findings


def load_nag_state(path: str) -> dict[str, str]:
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}
    nags = data.get("nags") if isinstance(data, dict) else None
    if not isinstance(nags, dict):
        return {}
    out: dict[str, str] = {}
    for key, value in nags.items():
        if isinstance(key, str) and isinstance(value, str):
            out[key] = value
    return out


def parse_questions(text: str, now: float, nag_after_hours: float, nags: dict[str, str]) -> list[dict[str, str]]:
    findings: list[dict[str, str]] = []
    nag_s = max(0.0, float(nag_after_hours)) * 3600.0
    today = now_dt(now).date().isoformat()
    for raw in text.splitlines():
        line = raw.strip()
        if not line.startswith("|"):
            continue
        match = TABLE_ROW_RE.match(line)
        if not match:
            continue
        cells = [c.strip() for c in match.group(1).split("|")]
        if len(cells) < 4:
            continue
        asked, question, _asked_by, status = cells[0], cells[1], cells[2], cells[3]
        if asked.lower() in {"asked", "---"} or set(asked) <= {"-"}:
            continue
        if not question or question.lower() == "question":
            continue
        status_u = status.strip()
        due = False
        if status_u.upper().startswith("OPEN"):
            due = True
        else:
            hold = HOLD_RE.search(status_u)
            if hold and hold.group(1) <= today:
                due = True
        if not due:
            continue
        slug = slugify(f"question-{asked}-{question}")
        last = parse_iso(nags.get(slug, ""))
        if last is not None and (now - last) < nag_s:
            continue
        findings.append(
            {
                "kind": "question",
                "slug": slug,
                "path": asked,
                "reason": question[:240],
            }
        )
    return findings


def scan(
    worktree_root: str,
    live_units_file: str,
    prs_file: str,
    questions_file: str,
    nag_state_file: str,
    now: float,
    idle_hours: float,
    nag_after_hours: float,
) -> dict[str, Any]:
    units = load_lines(live_units_file)
    worktrees, scanned = scan_worktrees(worktree_root, now, idle_hours, units)
    prs: list[dict[str, str]] = []
    if prs_file and os.path.isfile(prs_file):
        try:
            with open(prs_file, encoding="utf-8") as fh:
                payload = json.load(fh)
            if isinstance(payload, list):
                prs = classify_prs(payload, now, idle_hours)
        except (OSError, json.JSONDecodeError):
            prs = []
    questions: list[dict[str, str]] = []
    if questions_file and os.path.isfile(questions_file):
        try:
            with open(questions_file, encoding="utf-8") as fh:
                qtext = fh.read()
        except OSError:
            qtext = ""
        questions = parse_questions(
            qtext, now, nag_after_hours, load_nag_state(nag_state_file)
        )
    return {
        "worktrees": worktrees,
        "prs": prs,
        "questions": questions,
        "scanned_worktrees": scanned,
        "worktree_root": worktree_root,
    }


def record_nag(state_path: str, slug: str, when_iso: str) -> None:
    nags = load_nag_state(state_path)
    nags[slug] = when_iso
    directory = os.path.dirname(state_path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = state_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump({"nags": nags}, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp, state_path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    scan_p = sub.add_parser("scan", help="scan worktrees, PRs, and QUESTIONS.md")
    scan_p.add_argument("--worktree-root", default="")
    scan_p.add_argument("--live-units-file", default="")
    scan_p.add_argument("--prs-file", default="")
    scan_p.add_argument("--questions-file", default="")
    scan_p.add_argument("--nag-state", default="")
    scan_p.add_argument("--now", default="")
    scan_p.add_argument("--idle-hours", type=float, default=24.0)
    scan_p.add_argument("--nag-after-hours", type=float, default=24.0)
    rec = sub.add_parser("record-nag", help="stamp a successful question nag")
    rec.add_argument("--nag-state", required=True)
    rec.add_argument("--slug", required=True)
    rec.add_argument("--at", required=True)
    args = parser.parse_args(argv)

    if args.cmd == "scan":
        report = scan(
            worktree_root=args.worktree_root,
            live_units_file=args.live_units_file,
            prs_file=args.prs_file,
            questions_file=args.questions_file,
            nag_state_file=args.nag_state,
            now=parse_now(args.now or None),
            idle_hours=args.idle_hours,
            nag_after_hours=args.nag_after_hours,
        )
        json.dump(report, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0
    if args.cmd == "record-nag":
        record_nag(args.nag_state, args.slug, args.at)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
