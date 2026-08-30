#!/usr/bin/env python3
"""Merge-trample gate (fleet-ops#1229).

A PR is REJECT when its effective diff-to-main deletes or reverts paths
that its own commits never modified (ghost / HEAD-tree squash), or when
it deletes files its merge-base commit just added while also changing
other files (worktree-gap — the live #1228 class).

#1228's squash parent was a post-#1215 main. The PR commit itself was
parented on #1215 and deleted bin/pi-salvage-worktree. That is a commit
made from a working tree that never contained files HEAD already had
(git add -A / commit -a after retargeting onto a newer main). GitHub
squash applied that tree; salvage vanished. Restored by #1230.

Pure evaluator: no dispatch, no GitHub writes, no retry.

Subcommands:
  evaluate (default)  git repo / --input fixture → verdict JSON
  sweep               first-parent commits since a cutoff → hits JSON
  --ledger-line       print the decisions-ledger line verbatim
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Any

PROG = "fleet-merge-trample-gate"

LEDGER_LINE = (
    "STANDING, NON-NEGOTIABLE: a PR must not merge if its effective "
    "diff-to-main deletes or reverts files that its own commits never "
    "modified (ghost: merge diff minus per-commit diff-tree paths), or "
    "if it deletes files its merge-base commit just added while also "
    "changing other files (worktree-gap). Origin: 08-27. PR #1228 "
    "squash-merged a decisions-ledger fix whose single commit also "
    "deleted bin/pi-salvage-worktree, landed two minutes earlier in "
    "#1215. GitHub squash applied that tree; salvage vanished. "
    "Restored by #1230. (fleet-ops #1229)."
)

def _die(msg: str, code: int = 2) -> None:
    print(f"{PROG}: {msg}", file=sys.stderr)
    raise SystemExit(code)


def git(repo: str, *args: str, check: bool = True) -> str:
    try:
        proc = subprocess.run(
            ["git", "-C", repo, *args],
            check=check,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        _die(f"git not found: {exc}")
    if check and proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip()
        _die(f"git {' '.join(args)} failed: {err[:400]}")
    return proc.stdout


def parse_name_status(text: str) -> dict[str, str]:
    """Parse `git diff --name-status` / `git diff-tree --name-status`."""
    out: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip("\n")
        if not line:
            continue
        parts = line.split("\t")
        status = parts[0].split(" ", 1)[0]
        if status.startswith("R") or status.startswith("C"):
            if len(parts) >= 3:
                out[parts[1]] = status
                out[parts[2]] = status
            elif len(parts) == 2:
                out[parts[1]] = status
            continue
        if len(parts) >= 2:
            out[parts[-1]] = status
    return out


def is_delete(status: str) -> bool:
    return status.startswith("D")


def is_allowed(title: str, body: str, head_ref: str) -> str:
    """Return the allow reason, or empty if the gate still applies."""
    t = title.strip()
    if t.lower().startswith("revert"):
        return "revert-title"
    if head_ref.startswith("revert/"):
        return "revert-branch"
    for line in body.splitlines():
        if line.lower().startswith("trample-ok:"):
            return "trample-ok"
    return ""


def classify(
    merge_diff: dict[str, str],
    touched: set[str],
    added_by_merge_base: set[str],
    *,
    title: str = "",
    body: str = "",
    head_ref: str = "",
) -> dict[str, Any]:
    """Decide PASS/REJECT from already-computed path sets."""
    ghost = sorted(path for path in merge_diff if path not in touched)
    deleted = {path for path, status in merge_diff.items() if is_delete(status)}
    gap = sorted(path for path in deleted if path in added_by_merge_base)
    other = sorted(path for path in merge_diff if path not in gap)
    worktree_gap = bool(gap) and bool(other)

    allow = is_allowed(title, body, head_ref)
    classes: list[str] = []
    if ghost:
        classes.append("ghost")
    if worktree_gap:
        classes.append("worktree_gap")

    if allow:
        verdict = "PASS"
        reason = allow
    elif classes:
        verdict = "REJECT"
        reason = ",".join(classes)
    else:
        verdict = "PASS"
        reason = "clean"

    return {
        "verdict": verdict,
        "reason": reason,
        "rule": LEDGER_LINE,
        "classes": classes,
        "ghost_paths": ghost,
        "worktree_gap_paths": gap,
        "commit_touched": sorted(touched),
        "merge_diff_paths": sorted(merge_diff),
    }


def unique_commits(repo: str, base: str, head: str) -> list[str]:
    text = git(repo, "rev-list", "--reverse", f"{base}..{head}").strip()
    return [line for line in text.splitlines() if line]


def commit_touched_paths(repo: str, shas: list[str]) -> set[str]:
    touched: set[str] = set()
    for sha in shas:
        # -r: recursive tree. -M: keep renames as R, not D+A.
        blob = git(
            repo,
            "diff-tree",
            "--no-commit-id",
            "--name-status",
            "-r",
            "-M",
            sha,
        )
        touched.update(parse_name_status(blob))
    return touched


def files_added_by_commit(repo: str, sha: str) -> set[str]:
    blob = git(
        repo,
        "diff-tree",
        "--no-commit-id",
        "--name-status",
        "-r",
        "-M",
        sha,
    )
    return {
        path
        for path, status in parse_name_status(blob).items()
        if status.startswith("A")
    }


def files_added_on_first_parent(repo: str, tip: str, n: int = 20) -> set[str]:
    """Files added by the last n first-parent commits ending at tip."""
    text = git(repo, "log", "--first-parent", "-n", str(n), "--format=%H", tip).strip()
    added: set[str] = set()
    for sha in text.splitlines():
        if sha:
            added |= files_added_by_commit(repo, sha)
    return added


def resolve_merge_base(repo: str, base: str, head: str) -> str:
    mb = git(repo, "merge-base", base, head).strip()
    if not mb:
        _die(f"no merge-base for {base} {head}")
    return mb


def evaluate_git(
    repo: str,
    base: str,
    head: str,
    *,
    diff_base: str | None = None,
    touched_commits: list[str] | None = None,
    title: str = "",
    body: str = "",
    head_ref: str = "",
) -> dict[str, Any]:
    mb = resolve_merge_base(repo, base, head)
    shas = touched_commits if touched_commits is not None else unique_commits(
        repo, base, head
    )
    if not shas:
        shas = unique_commits(repo, mb, head)
    touched = commit_touched_paths(repo, shas)
    added = files_added_by_commit(repo, mb) | files_added_on_first_parent(
        repo, base, n=20
    )
    against = diff_base or mb
    merge_diff = parse_name_status(
        git(repo, "diff", "--name-status", "-M", against, head)
    )
    result = classify(
        merge_diff,
        touched,
        added,
        title=title,
        body=body,
        head_ref=head_ref,
    )
    result["merge_base"] = mb
    result["base"] = base
    result["head"] = head
    result["diff_base"] = against
    result["touched_commits"] = shas
    return result


def evaluate_fixture(payload: dict[str, Any]) -> dict[str, Any]:
    merge_diff = payload.get("merge_diff") or {}
    if not isinstance(merge_diff, dict):
        _die("fixture merge_diff must be an object of path → status")
    touched = set(payload.get("commit_touched") or [])
    added = set(payload.get("added_by_merge_base") or [])
    result = classify(
        {str(k): str(v) for k, v in merge_diff.items()},
        {str(p) for p in touched},
        {str(p) for p in added},
        title=str(payload.get("title") or ""),
        body=str(payload.get("body") or ""),
        head_ref=str(payload.get("headRefName") or payload.get("head_ref") or ""),
    )
    result["merge_base"] = payload.get("merge_base") or ""
    return result


def load_json(path: str) -> dict[str, Any]:
    if path == "-":
        raw = sys.stdin.read()
    else:
        try:
            raw = open(path, encoding="utf-8").read()
        except OSError as exc:
            _die(f"cannot read {path}: {exc}")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        _die(f"invalid JSON: {exc}")
    if not isinstance(data, dict):
        _die("JSON root must be an object")
    return data


def first_parent_since(repo: str, since: str, *, deletes_only: bool = False) -> list[tuple[str, str]]:
    args = ["log", "--first-parent", "--format=%H\t%s", f"--since={since}"]
    if deletes_only:
        args[1:1] = ["--diff-filter=D"]
    text = git(repo, *args)
    rows: list[tuple[str, str]] = []
    for line in text.splitlines():
        sha, _, subject = line.partition("\t")
        if sha:
            rows.append((sha, subject))
    return rows


def sweep_git(repo: str, since: str) -> list[dict[str, Any]]:
    """Scan first-parent commits. A squash merge is one parent + (#N)."""
    hits: list[dict[str, Any]] = []
    for sha, subject in first_parent_since(repo, since, deletes_only=True):
        parents = git(repo, "rev-list", "--parents", "-n", "1", sha).split()
        if len(parents) != 2:
            # True merge (2+ parents) or root. Skip.
            continue
        parent = parents[1]
        result = evaluate_git(repo, parent, sha, title=subject)
        if result["verdict"] != "REJECT":
            continue
        hit = {
            "sha": sha,
            "subject": subject,
            "parent": parent,
            **{k: result[k] for k in (
                "verdict",
                "reason",
                "classes",
                "ghost_paths",
                "worktree_gap_paths",
                "merge_base",
            )},
        }
        hits.append(hit)
    return hits


def emit(result: dict[str, Any], reject_exit: int = 1) -> None:
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    if result.get("verdict") == "REJECT":
        raise SystemExit(reject_exit)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=PROG,
        description=(
            "Merge-trample gate (fleet-ops#1229). Pure evaluator: "
            "REJECT a PR whose merge diff deletes paths its commits "
            "never modified, or the #1228 worktree-gap class."
        ),
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="evaluate",
        choices=["evaluate", "sweep"],
        help="evaluate a PR (default) or sweep recent first-parent commits",
    )
    parser.add_argument("--input", "-i", help="fixture JSON (default: stdin when no --repo)")
    parser.add_argument("--repo", help="git repository path")
    parser.add_argument("--base", help="base ref (usually main / merge parent)")
    parser.add_argument("--head", help="head ref (PR tip or squash commit)")
    parser.add_argument(
        "--diff-base",
        help="ref to diff head against (default: merge-base = three-dot). "
        "Pass current main to compute two-dot (HEAD-tree squash drill).",
    )
    parser.add_argument(
        "--touched-commits",
        help="comma-separated SHAs that count as the PR's own commits "
        "(HEAD-tree squash drill: original PR commits, not the squash).",
    )
    parser.add_argument("--title", default="", help="PR / commit title for allow rules")
    parser.add_argument("--body", default="", help="PR body for trample-ok:")
    parser.add_argument("--head-ref", default="", help="PR head ref (revert/ allow)")
    parser.add_argument("--since", default="7 days ago", help="sweep cutoff (git --since)")
    parser.add_argument(
        "--ledger-line",
        action="store_true",
        help="print the decisions-ledger line verbatim and exit 0",
    )
    return parser


def main(argv: list[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.ledger_line:
        print(LEDGER_LINE)
        return

    if args.command == "sweep":
        if not args.repo:
            _die("sweep requires --repo")
        hits = sweep_git(args.repo, args.since)
        json.dump({"hits": hits, "rule": LEDGER_LINE}, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return

    if args.repo:
        if not args.base or not args.head:
            _die("evaluate --repo requires --base and --head")
        touched = None
        if args.touched_commits:
            touched = [s for s in args.touched_commits.split(",") if s]
        result = evaluate_git(
            args.repo,
            args.base,
            args.head,
            diff_base=args.diff_base,
            touched_commits=touched,
            title=args.title,
            body=args.body,
            head_ref=args.head_ref,
        )
        emit(result)
        return

    path = args.input
    if path is None:
        if sys.stdin.isatty():
            _die("evaluate needs --repo or --input (or stdin JSON)")
        path = "-"
    emit(evaluate_fixture(load_json(path)))


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except OSError:
            pass
        raise SystemExit(0)
    except KeyboardInterrupt:
        raise SystemExit(130)
