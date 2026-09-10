#!/usr/bin/env python3
"""
dirty-worktree-audit — implements fleet-ops#38.

Reads the weekly dirty-worktrees list and applies the required protocol:

1. After `git fetch origin`, for each worktree's branch:
   a. zero commits ahead of origin/main; else
   b. `git cherry origin/main <branch>` yields no `+` lines; else
   c. a PR for the branch is MERGED and `git merge-base --is-ancestor
      <mergeCommit> origin/main` succeeds.

2. Produces four markdown deliverables:
   - genuinely unlanded branches (pushes them unless --dry-run)
   - UU (unresolved merge conflict) worktrees
   - worktrees proved fully landed and safe to reclaim
   - errors / skipped worktrees

Hard constraints from the issue are honoured:
   - never `git stash`
   - never delete or reuse a worktree
   - never revert or discard uncommitted changes

The only write operations are `git fetch origin` (read-only to refs) and
`git push origin <branch>` for branches the protocol finds genuinely unlanded.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

DEFAULT_INPUT = "/home/nish/.local/state/vps-maintenance/dirty-worktrees.txt"
DEFAULT_REPORT_DIR = "/home/nish/.local/state/vps-maintenance"


def log(msg: str) -> None:
    """Log to stderr so the report can go to a file or stdout."""
    print(f"[{datetime.now(timezone.utc).isoformat()}] {msg}", file=sys.stderr)


def run_git(path: str, *args: str, check: bool = False) -> subprocess.CompletedProcess:
    """Run a git command in `path`; never raises unless check=True."""
    return subprocess.run(
        ["git", "-C", path, *args],
        capture_output=True,
        text=True,
        check=check,
    )


def run_gh(*args: str, check: bool = False) -> subprocess.CompletedProcess:
    """Run gh; never raises unless check=True."""
    return subprocess.run(
        ["gh", *args],
        capture_output=True,
        text=True,
        check=check,
    )


def slugify(s: str) -> str:
    """Make a string safe for a branch name."""
    s = re.sub(r"[^a-zA-Z0-9._-]", "-", s)
    return s.strip("-").lstrip(".")[:50]


def parse_repo(remote_url: str) -> Optional[str]:
    """Extract owner/repo from a GitHub remote URL."""
    if not remote_url:
        return None
    patterns = [
        r"^(?:git@github\.com:|https?://github\.com/)([^/]+)/([^/]+?)(?:\.git)?$",
        r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?(?:\s|$)",
    ]
    for pattern in patterns:
        m = re.search(pattern, remote_url)
        if m:
            return f"{m.group(1)}/{m.group(2)}"
    return None


def resolve_main_ref(path: str) -> Optional[str]:
    """Return the best main ref after fetch, or None if none exists."""
    for ref in ("origin/main", "origin/master", "origin/HEAD"):
        r = run_git(path, "rev-parse", "--verify", ref)
        if r.returncode == 0:
            return ref
    return None


def get_default_branch_name(ref: str) -> str:
    """Return a human-readable default branch name for the resolved ref."""
    if ref == "origin/main":
        return "main"
    if ref == "origin/master":
        return "master"
    if ref == "origin/HEAD":
        return "HEAD"
    return ref


def has_uu(path: str) -> bool:
    """True if the worktree has unresolved merge-conflict (UU) entries."""
    r = run_git(path, "status", "--porcelain")
    if r.returncode != 0:
        return False
    for line in r.stdout.splitlines():
        if line.startswith("UU"):
            return True
    return False


def commits_ahead(path: str, main_ref: str, branch_ref: str) -> Optional[int]:
    """Return the number of commits branch_ref is ahead of main_ref."""
    r = run_git(path, "rev-list", "--count", f"{main_ref}..{branch_ref}")
    if r.returncode != 0:
        return None
    try:
        return int(r.stdout.strip())
    except ValueError:
        return None


def cherry_has_plus(path: str, main_ref: str, branch_ref: str) -> bool:
    """True if `git cherry` reports any `+` line (unmatched patch ids)."""
    r = run_git(path, "cherry", main_ref, branch_ref)
    if r.returncode != 0:
        # Cannot determine; treat as unlanded to avoid a false negative.
        return True
    return re.search(r"^\+", r.stdout, re.MULTILINE) is not None


def find_merged_pr(prs: List[dict], branch_name: str) -> Optional[Tuple[int, str]]:
    """Return (pr_number, merge_commit_sha) for a merged PR matching branch_name."""
    if not branch_name or branch_name == "DETACHED":
        return None
    candidates = []
    for pr in prs:
        if pr.get("state") != "MERGED":
            continue
        merge_commit = pr.get("mergeCommit") or {}
        merge_oid = merge_commit.get("oid")
        if not merge_oid:
            continue
        head = pr.get("headRefName", "")
        # Same repo: just branch name. Fork: owner:branch.
        head_branch = head.split(":")[-1] if ":" in head else head
        if head_branch == branch_name:
            candidates.append((pr["number"], merge_oid))
    if not candidates:
        return None
    # Pick the latest PR number, i.e. the most recent merged PR for this branch.
    candidates.sort(key=lambda x: x[0])
    return candidates[-1]


def merge_base_is_ancestor(path: str, commit: str, main_ref: str) -> bool:
    """True if `commit` is an ancestor of `main_ref`."""
    r = run_git(path, "merge-base", "--is-ancestor", commit, main_ref)
    return r.returncode == 0


def remote_branches_containing(path: str, sha: str) -> List[str]:
    """Return origin/* branch names (excluding HEAD) that contain `sha`."""
    r = run_git(path, "branch", "-r", "--contains", sha)
    if r.returncode != 0:
        return []
    branches = []
    for line in r.stdout.splitlines():
        b = line.strip().lstrip("* ")
        if b and b.startswith("origin/") and b != "origin/HEAD" and " -> " not in b:
            branches.append(b)
    return branches


def prefer_feature_branch(branches: List[str]) -> Optional[str]:
    """Prefer a non-main/master origin branch if one exists."""
    if not branches:
        return None
    for b in branches:
        if not re.fullmatch(r"origin/(main|master)", b):
            return b
    return branches[0]


def last_commit_date(path: str, ref: str) -> Optional[str]:
    """Return ISO-8601 committer date of the ref's tip."""
    r = run_git(path, "log", "-1", "--format=%cI", ref)
    if r.returncode == 0:
        return r.stdout.strip()
    return None


def md_cell(value) -> str:
    """Make a value safe for a markdown table cell."""
    s = str(value).replace("\r", " ").replace("\n", " ").replace("|", "\\|")
    return s.strip()


def record_to_dict(record: List[str]) -> dict:
    """Convert an internal list record into a status dict for reporting."""
    return {
        "path": record[0],
        "repo": record[1],
        "branch": record[2],
        "commits_ahead": record[3],
        "last_commit_date": record[4],
        "status": record[5],
        "reason": record[6],
    }


def parse_dirty_file(path: str) -> List[str]:
    """Return the list of worktree paths from the dirty-worktrees file."""
    if not os.path.isfile(path):
        log(f"ERROR: input file missing: {path}")
        return []
    paths: List[str] = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("### "):
                paths.append(line[4:])
    return paths


def inspect_worktree(path: str) -> dict:
    """Gather metadata for a single worktree without fetching."""
    if not os.path.isdir(path):
        return {"path": path, "error": "path does not exist"}
    if not os.path.exists(os.path.join(path, ".git")):
        return {"path": path, "error": "not a git repository"}

    r = run_git(path, "rev-parse", "--git-common-dir")
    if r.returncode != 0:
        return {"path": path, "error": f"git rev-parse --git-common-dir failed: {r.stderr.strip()}"}
    common_dir = r.stdout.strip()

    r = run_git(path, "remote", "get-url", "origin")
    if r.returncode != 0:
        return {"path": path, "git_common_dir": common_dir, "error": "no origin remote"}
    remote_url = r.stdout.strip()
    repo = parse_repo(remote_url)

    r = run_git(path, "rev-parse", "--abbrev-ref", "HEAD")
    branch = r.stdout.strip() if r.returncode == 0 else ""

    r = run_git(path, "rev-parse", "HEAD")
    head_sha = r.stdout.strip() if r.returncode == 0 else ""

    return {
        "path": path,
        "git_common_dir": common_dir,
        "remote_url": remote_url,
        "repo": repo,
        "branch": branch,
        "head_sha": head_sha,
        "uu": has_uu(path),
    }


def fetch_origin(path: str) -> Tuple[bool, str]:
    """Fetch origin for the git repo that owns this worktree."""
    r = run_git(path, "fetch", "origin")
    if r.returncode != 0:
        return False, r.stderr.strip()
    return True, ""


def load_pr_cache(pr_cache_dir: Path, repo: str, pr_limit: int) -> Tuple[List[dict], str]:
    """Return cached PR list for a repo; fetch once if not cached."""
    safe = re.sub(r"[^a-zA-Z0-9._-]", "-", repo)
    cache_file = pr_cache_dir / f"{safe}.json"
    if cache_file.exists():
        try:
            with open(cache_file, "r", encoding="utf-8") as f:
                return json.load(f), ""
        except json.JSONDecodeError as e:
            return [], f"cache parse error: {e}"

    r = run_gh(
        "pr", "list",
        "-R", repo,
        "--state", "all",
        "--json", "number,state,headRefName,mergeCommit",
        "--limit", str(pr_limit),
    )
    if r.returncode != 0:
        log(f"WARN: gh pr list failed for {repo}: {r.stderr.strip()}")
        with open(cache_file, "w", encoding="utf-8") as f:
            json.dump([], f)
        return [], r.stderr.strip()

    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        log(f"WARN: gh pr list JSON parse failed for {repo}: {e}")
        data = []

    if len(data) == pr_limit:
        log(f"WARN: {repo} may have more than {pr_limit} PRs; results may be incomplete")

    with open(cache_file, "w", encoding="utf-8") as f:
        json.dump(data, f)
    return data, ""


def determine_candidate(
    meta: dict,
    main_ref: str,
) -> Tuple[Optional[str], Optional[str], str]:
    """
    Return (candidate_ref, candidate_name, note) for classification.

    candidate_ref is the git ref to run the protocol against.
    candidate_name is the branch name for PR lookup and reporting.
    """
    branch = meta.get("branch", "")
    head_sha = meta.get("head_sha", "")
    path = meta["path"]

    if branch and branch != "HEAD":
        # Worktree is on a named local branch.
        return branch, branch, ""

    if not head_sha:
        return None, None, "no HEAD"

    # Detached HEAD. If the commit is already in the default branch, use it.
    head_count = commits_ahead(path, main_ref, head_sha)
    if head_count is not None and head_count == 0:
        default_name = get_default_branch_name(main_ref)
        return main_ref, default_name, "detached on default branch"

    # Otherwise try to find the closest origin branch containing the commit.
    remotes = remote_branches_containing(path, head_sha)
    if remotes:
        # Pick the branch with the fewest commits ahead of the default branch;
        # if tied, prefer stable sort order for repeatability.
        best = None
        best_count: Optional[int] = None
        for b in remotes:
            cnt = commits_ahead(path, main_ref, b)
            if cnt is None:
                continue
            if best is None or cnt < best_count or (cnt == best_count and b < best):
                best = b
                best_count = cnt
        if best:
            name = re.sub(r"^origin/", "", best)
            return best, name, "detached on origin branch"

    # Truly detached with no containing origin branch.
    return head_sha, "DETACHED", "detached with no origin branch"


def push_branch(path: str, branch_name: str, dry_run: bool) -> Tuple[bool, str]:
    """Push a local branch to origin."""
    if dry_run:
        return True, "dry-run (would push)"
    r = run_git(path, "push", "--no-verify", "origin", branch_name)
    if r.returncode == 0:
        return True, "pushed"
    return False, r.stderr.strip()


def push_rescue_branch(path: str, repo: str, head_sha: str, worktree_name: str, dry_run: bool) -> Tuple[bool, str]:
    """Push a detached HEAD to a rescue branch on origin."""
    base = slugify(worktree_name) or "orphan"
    short = head_sha[:8]
    branch = f"rescue/{base}-{short}"
    if dry_run:
        return True, f"dry-run (would push to {branch})"
    r = run_git(path, "push", "--no-verify", "origin", f"{head_sha}:refs/heads/{branch}")
    if r.returncode == 0:
        return True, f"pushed to {branch}"
    return False, r.stderr.strip()


def classify_and_act(
    meta: dict,
    pr_cache: Dict[str, List[dict]],
    main_ref_cache: Dict[str, Optional[str]],
    dry_run: bool,
) -> dict:
    """
    Run the required protocol and optionally push unlanded branches.
    Returns a report record dict.
    """
    path = meta["path"]
    repo = meta.get("repo") or ""
    record: dict = {
        "path": path,
        "repo": repo,
        "branch": meta.get("branch", ""),
        "candidate_branch": "",
        "commits_ahead": "",
        "last_commit_date": "",
        "status": "error",
        "reason": "",
        "pushed": "",
        "uu": "yes" if meta.get("uu") else "no",
    }

    if meta.get("error"):
        record["status"] = "error"
        record["reason"] = meta["error"]
        return record

    main_ref = main_ref_cache.get(meta["git_common_dir"])
    if not main_ref:
        record["status"] = "error"
        record["reason"] = "could not resolve origin/main/master/HEAD after fetch"
        return record

    candidate_ref, candidate_name, note = determine_candidate(meta, main_ref)
    if not candidate_ref:
        record["status"] = "error"
        record["reason"] = note
        return record

    record["candidate_branch"] = candidate_name
    raw_branch = meta.get("branch", "")
    if raw_branch and raw_branch != "HEAD":
        record["branch"] = raw_branch
    else:
        record["branch"] = candidate_name or "DETACHED"

    # Unresolved merge-conflict worktrees are broken, not merely dirty.
    if meta.get("uu"):
        record["status"] = "uu"
        record["reason"] = "unresolved merge conflict (UU)"
        return record

    # Check 1: zero commits ahead.
    count = commits_ahead(path, main_ref, candidate_ref)
    if count is None:
        record["status"] = "error"
        record["reason"] = f"git rev-list --count {main_ref}..{candidate_ref} failed"
        return record
    record["commits_ahead"] = str(count)

    if count == 0:
        record["status"] = "landed"
        record["reason"] = f"{count} commits ahead of {main_ref}"
        return record

    # Check 2: git cherry yields no `+` lines.
    if not cherry_has_plus(path, main_ref, candidate_ref):
        record["status"] = "landed"
        record["reason"] = "git cherry found no unmatched `+` lines (squash/rebase merged)"
        return record

    # Check 3: a merged PR whose merge commit is an ancestor of main.
    pr_info = find_merged_pr(pr_cache.get(repo, []), candidate_name)
    if pr_info:
        number, merge_commit = pr_info
        if merge_base_is_ancestor(path, merge_commit, main_ref):
            record["status"] = "landed"
            record["reason"] = f"PR #{number} merged ({merge_commit[:8]} is ancestor of {main_ref})"
            return record

    # Genuinely unlanded.
    record["status"] = "unlanded"
    record["last_commit_date"] = last_commit_date(path, candidate_ref) or ""

    # Decide whether/what to push.
    if candidate_name in ("main", "master"):
        record["pushed"] = "skipped (main/master branch)"
        record["reason"] = f"{record['commits_ahead']} commits ahead; main/master is protected"
    elif candidate_ref.startswith("origin/"):
        # Already visible on origin.
        record["pushed"] = "already on origin"
        record["reason"] = f"{record['commits_ahead']} commits ahead; branch is on origin but not merged"
    elif candidate_name == "DETACHED":
        worktree_name = Path(path).name
        ok, msg = push_rescue_branch(path, repo, meta.get("head_sha", ""), worktree_name, dry_run)
        record["pushed"] = msg
        if not ok and not dry_run:
            record["status"] = "error"
            record["reason"] = f"{record['commits_ahead']} commits ahead; detached push failed: {msg}"
        else:
            record["reason"] = f"{record['commits_ahead']} commits ahead; detached with no merged PR"
    else:
        ok, msg = push_branch(path, candidate_name, dry_run)
        record["pushed"] = msg
        if not ok and not dry_run:
            record["status"] = "error"
            record["reason"] = f"{record['commits_ahead']} commits ahead; push failed: {msg}"
        else:
            record["reason"] = f"{record['commits_ahead']} commits ahead; no merged PR"

    return record


def write_markdown_report(
    report_path: str,
    records: List[dict],
    dry_run: bool,
    input_file: str,
) -> None:
    """Write the four deliverable tables as markdown."""
    unlanded = [r for r in records if r["status"] == "unlanded"]
    uu = [r for r in records if r["status"] == "uu"]
    landed = [r for r in records if r["status"] == "landed"]
    errors = [r for r in records if r["status"] == "error"]

    total = len(records)

    parent = os.path.dirname(report_path)
    if parent:
        os.makedirs(parent, exist_ok=True)

    with open(report_path, "w", encoding="utf-8") as f:
        f.write("# Dirty worktree audit\n\n")
        f.write(f"Generated: {datetime.now(timezone.utc).isoformat()}Z\n")
        f.write(f"Input: `{input_file}`\n")
        f.write(f"Dry run: {dry_run}\n\n")

        f.write("## Summary\n\n")
        f.write(f"- Worktrees inspected: {total}\n")
        f.write(f"- Genuinely unlanded branches: {len(unlanded)}\n")
        f.write(f"- UU (unresolved merge conflict) worktrees: {len(uu)}\n")
        f.write(f"- Proved fully landed / safe to reclaim: {len(landed)}\n")
        f.write(f"- Errors / skipped: {len(errors)}\n\n")

        f.write("## 1. Genuinely unlanded branches\n\n")
        f.write("| Repo | Branch | Commits ahead | Last commit | Pushed | Worktree |\n")
        f.write("|------|--------|--------------|-------------|--------|----------|\n")
        for r in sorted(unlanded, key=lambda x: (x["repo"], x["branch"], x["path"])):
            f.write(
                f"| {md_cell(r['repo'])} | {md_cell(r['branch'])} | {md_cell(r['commits_ahead'])} | "
                f"{md_cell(r['last_commit_date'])} | {md_cell(r['pushed'])} | `{md_cell(r['path'])}` |\n"
            )
        if not unlanded:
            f.write("_No genuinely unlanded branches found._\n")
        f.write("\n")

        f.write("## 2. UU (unresolved merge conflict) worktrees\n\n")
        f.write("| Repo | Branch | Worktree |\n")
        f.write("|------|--------|----------|\n")
        for r in sorted(uu, key=lambda x: (x["repo"], x["branch"], x["path"])):
            f.write(f"| {md_cell(r['repo'])} | {md_cell(r['branch'])} | `{md_cell(r['path'])}` |\n")
        if not uu:
            f.write("_No UU worktrees found._\n")
        f.write("\n")

        f.write("## 3. Worktrees proved fully landed (safe to reclaim)\n\n")
        f.write("| Repo | Branch | Reason | Worktree |\n")
        f.write("|------|--------|--------|----------|\n")
        for r in sorted(landed, key=lambda x: (x["repo"], x["branch"], x["path"])):
            f.write(f"| {md_cell(r['repo'])} | {md_cell(r['branch'])} | {md_cell(r['reason'])} | `{md_cell(r['path'])}` |\n")
        if not landed:
            f.write("_No fully-landed worktrees found._\n")
        f.write("\n")

        f.write("## 4. Errors / skipped\n\n")
        f.write("| Repo | Branch | Reason | Worktree |\n")
        f.write("|------|--------|--------|----------|\n")
        for r in sorted(errors, key=lambda x: (x.get("repo", ""), x.get("branch", ""), x["path"])):
            f.write(f"| {md_cell(r.get('repo', ''))} | {md_cell(r.get('branch', ''))} | {md_cell(r['reason'])} | `{md_cell(r['path'])}` |\n")
        if not errors:
            f.write("_No errors._\n")
        f.write("\n")

        f.write("## Method\n\n")
        f.write("Protocol followed, in order:\n")
        f.write("1. `git rev-list --count origin/main..<branch>` == 0; else\n")
        f.write("2. `git cherry origin/main <branch>` has no `+` lines; else\n")
        f.write("3. A PR for `<branch>` is `MERGED` and `git merge-base --is-ancestor <mergeCommit> origin/main` succeeds.\n")
        f.write("\nThe first passing check proves the branch is fully landed.\n")
        f.write("Branches failing all three are genuinely unlanded and are pushed to origin so they become visible to other agents.\n")
        f.write("No worktree was deleted, stashed, or had changes reverted during this run.\n")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit dirty worktrees for genuinely unlanded branches (fleet-ops#38).",
    )
    parser.add_argument(
        "--input",
        default=DEFAULT_INPUT,
        help="Path to the dirty-worktrees report file (default: %(default)s)",
    )
    parser.add_argument(
        "--report",
        default="",
        help="Path for the markdown report. Defaults to ~/.local/state/vps-maintenance/dirty-worktree-audit-<date>.md",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Do not push branches; only classify and report.",
    )
    parser.add_argument(
        "--pr-limit",
        type=int,
        default=10000,
        help="Max PRs to fetch per repo with `gh pr list` (default: %(default)s)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Log every worktree as it is processed.",
    )
    args = parser.parse_args()

    report_path = args.report
    if not report_path:
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        report_path = f"{DEFAULT_REPORT_DIR}/dirty-worktree-audit-{today}.md"

    if not shutil.which("git"):
        log("ERROR: git is required")
        return 1
    if not shutil.which("gh"):
        log("ERROR: gh is required")
        return 1

    paths = parse_dirty_file(args.input)
    if not paths:
        log("ERROR: no worktree paths found in input")
        return 1

    log(f"Inspecting {len(paths)} worktrees from {args.input}")

    # Phase 1: metadata.
    metas: List[dict] = []
    for i, path in enumerate(paths, 1):
        if args.verbose:
            log(f"[{i}/{len(paths)}] inspecting {path}")
        metas.append(inspect_worktree(path))

    # Phase 2: fetch once per git common dir.
    common_dirs = {m["git_common_dir"] for m in metas if m.get("git_common_dir")}
    for i, cd in enumerate(sorted(common_dirs), 1):
        # Use any worktree that belongs to this common dir.
        path = next(m["path"] for m in metas if m.get("git_common_dir") == cd)
        log(f"[{i}/{len(common_dirs)}] fetching origin for {cd}")
        ok, err = fetch_origin(path)
        if not ok:
            log(f"WARN: fetch failed for {cd}: {err}")

    # Phase 3: resolve main refs.
    main_ref_cache: Dict[str, Optional[str]] = {}
    for m in metas:
        cd = m.get("git_common_dir")
        if cd and cd not in main_ref_cache:
            path = m["path"]
            main_ref_cache[cd] = resolve_main_ref(path)

    # Phase 4: load PR cache per repo.
    repos = {m.get("repo") for m in metas if m.get("repo")}
    pr_cache: Dict[str, List[dict]] = {}
    with tempfile.TemporaryDirectory() as tmp:
        pr_cache_dir = Path(tmp)
        for i, repo in enumerate(sorted(repos), 1):
            log(f"[{i}/{len(repos)}] fetching PR list for {repo}")
            prs, _ = load_pr_cache(pr_cache_dir, repo, args.pr_limit)
            pr_cache[repo] = prs

        # Phase 5: classify and optionally push.
        records: List[dict] = []
        for i, m in enumerate(metas, 1):
            if args.verbose:
                log(f"[{i}/{len(metas)}] classifying {m['path']}")
            record = classify_and_act(m, pr_cache, main_ref_cache, args.dry_run)
            records.append(record)
            if not args.verbose and (i % 50 == 0 or i == len(metas)):
                log(f"{i}/{len(metas)} worktrees classified")

        # Phase 6: report.
        write_markdown_report(report_path, records, args.dry_run, args.input)

    log(f"Report written to {report_path}")
    log(f"Summary: {len([r for r in records if r['status']=='unlanded'])} unlanded, "
        f"{len([r for r in records if r['status']=='uu'])} UU, "
        f"{len([r for r in records if r['status']=='landed'])} landed, "
        f"{len([r for r in records if r['status']=='error'])} errors")

    return 0


if __name__ == "__main__":
    sys.exit(main())
