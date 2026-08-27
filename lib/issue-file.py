#!/usr/bin/env python3
"""Filing-time same-problem dedupe (fleet-ops#1212).

Same-issue claims are already mutexed (markers, labels, hashes). This helper
is the same-PROBLEM gate: cheap title+body token overlap plus key-path and
unit-name match. No ML.

  above DUP_THRESHOLD     -> comment-link the existing issue, do not file
  BORDERLINE..DUP         -> file with a possible-duplicate-of marker
  below BORDERLINE        -> file clean

All auto-filers route through this instead of raw `gh issue create`.

Usage:
  issue-file.py file --repo OWNER/NAME --title T (--body B | --body-file F)
                 [--label L ...] [--from-json PATH] [--dry-run] [--json]
  issue-file.py sweep [--repo OWNER/NAME ...] [--from-json PATH] [--json]
  issue-file.py score --title T --body B --against-json PATH
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DUP_THRESHOLD = 0.65
BORDERLINE_THRESHOLD = 0.40
KEY_BONUS = 0.10
LIST_LIMIT = 200

# Common key paths that appear in many unrelated issues and therefore
# carry no duplicate signal. Filtered from the shared-key bonus so the
# sweep does not collapse 30 unrelated "edit ci.yml" issues into one
# cluster. Anything not in this set is treated as specific.
COMMON_KEY_PATHS = frozenset(
    """
    .github/workflows/ci.yml
    .github/workflows/ci.yaml
    .github/workflows
    .github
    ci.yml
    ci.yaml
    workflows
    src/index.ts
    src/main.ts
    package.json
    readme.md
    """.split()
)

STOPWORDS = frozenset(
    """
    a an the to of and or in on for with this that is are be as at by from
    it its not no yes if then than so such into over after before between
    through during without vs via per our your we they you i but also just
    more most other some any all each every both same own too very about
    up out off down new old issue issues pr prs repo repos must should
    will can could may might do does did has have had been being was were
    """.split()
)

PATH_RE = re.compile(
    r"(?:(?:\./)?[A-Za-z0-9_.-]+/){1,}[A-Za-z0-9_.-]+(?:\.[A-Za-z0-9]+)?"
)
UNIT_RE = re.compile(
    r"\b[A-Za-z0-9_@.:-]+\.(?:service|timer|socket|target|path|slice)\b"
)
INSTANCE_RE = re.compile(
    r"\b(?:pi-issue|pi-intake|pi-scout|pi-packet|unit-escalation|fleet-heartbeat"
    r"|siterep-deploy|siterep-uptime)@[A-Za-z0-9_.-]+\b"
)

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent
DEFAULT_INTAKE = REPO_ROOT / "config" / "intake-repos.json"
MARKER_RE = re.compile(
    r"<!-- possible-duplicate-of: ([^\s]+) score=([0-9.]+) -->"
)


def gh_bin() -> str:
    return os.environ.get("GH", "gh")


def norm(text: str) -> str:
    return re.sub(r"[^a-z0-9./@_-]+", " ", (text or "").lower()).strip()


def tokens(text: str) -> set[str]:
    out: set[str] = set()
    for raw in norm(text).split():
        if len(raw) < 2 or raw in STOPWORDS:
            continue
        out.add(raw)
    return out


def overlap(a: str, b: str) -> float:
    sa, sb = tokens(a), tokens(b)
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / min(len(sa), len(sb))


def key_paths(text: str) -> set[str]:
    found = set(PATH_RE.findall(text or ""))
    found |= set(UNIT_RE.findall(text or ""))
    found |= set(INSTANCE_RE.findall(text or ""))
    return {p.lower() for p in found}


def score_pair(
    title_a: str,
    body_a: str,
    title_b: str,
    body_b: str,
) -> dict:
    """Return {score, title_overlap, body_overlap, shared_keys}."""
    t = overlap(title_a, title_b)
    combined_a = f"{title_a}\n{body_a}"
    combined_b = f"{title_b}\n{body_b}"
    b = overlap(combined_a, combined_b)
    shared = key_paths(combined_a) & key_paths(combined_b)
    specific_shared = {k for k in shared if k not in COMMON_KEY_PATHS}
    bonus = KEY_BONUS if specific_shared else 0.0
    score = min(1.0, max(t, b) + bonus)
    return {
        "score": round(score, 4),
        "title_overlap": round(t, 4),
        "body_overlap": round(b, 4),
        "shared_keys": sorted(shared),
        "specific_shared_keys": sorted(specific_shared),
    }


def classify(score: float) -> str:
    if score >= DUP_THRESHOLD:
        return "duplicate"
    if score >= BORDERLINE_THRESHOLD:
        return "borderline"
    return "new"


def enrolled_repos(intake_path: str | None = None) -> list[str]:
    path = Path(
        intake_path
        or os.environ.get("FLEET_INTAKE_REPOS_JSON", str(DEFAULT_INTAKE))
    )
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    names = []
    for row in data.get("repos") or []:
        name = (row or {}).get("name")
        if name:
            names.append(f"Nishfleet/{name}")
    return names


def issue_ref(issue: dict) -> str:
    repo = issue.get("repository") or ""
    number = issue.get("number")
    if repo and number:
        return f"{repo}#{number}"
    if issue.get("url"):
        return str(issue["url"])
    return str(number or "?")


def load_open_from_json(path: str) -> list[dict]:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        raw = raw.get("issues") or raw.get("open_issues") or []
    out = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        number = item.get("number")
        if not isinstance(number, int):
            continue
        out.append(
            {
                "number": number,
                "title": item.get("title") or "",
                "body": item.get("body") or "",
                "url": item.get("url") or "",
                "repository": item.get("repository") or item.get("repo") or "",
            }
        )
    return out


def gh_list_open(repo: str) -> list[dict]:
    proc = subprocess.run(
        [
            gh_bin(),
            "issue",
            "list",
            "-R",
            repo,
            "--state",
            "open",
            "--limit",
            str(LIST_LIMIT),
            "--json",
            "number,title,body,url",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or not (proc.stdout or "").strip():
        return []
    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return []
    out = []
    for item in rows if isinstance(rows, list) else []:
        if not isinstance(item, dict):
            continue
        number = item.get("number")
        if not isinstance(number, int):
            continue
        out.append(
            {
                "number": number,
                "title": item.get("title") or "",
                "body": item.get("body") or "",
                "url": item.get("url") or "",
                "repository": repo,
            }
        )
    return out


def collect_open(
    target_repo: str,
    from_json: str,
    cross_repo: bool,
    extra_repos: list[str],
) -> list[dict]:
    if from_json:
        issues = load_open_from_json(from_json)
        if not any(i.get("repository") for i in issues):
            for i in issues:
                i["repository"] = target_repo
        return issues
    repos = [target_repo]
    if cross_repo:
        for r in enrolled_repos() + extra_repos:
            if r not in repos:
                repos.append(r)
    seen: set[tuple[str, int]] = set()
    out: list[dict] = []
    for repo in repos:
        for issue in gh_list_open(repo):
            key = (issue["repository"], issue["number"])
            if key in seen:
                continue
            seen.add(key)
            out.append(issue)
    return out


def best_match(title: str, body: str, issues: list[dict]) -> dict | None:
    best = None
    best_score = -1.0
    for issue in issues:
        detail = score_pair(title, body, issue.get("title") or "", issue.get("body") or "")
        if detail["score"] > best_score:
            best_score = detail["score"]
            best = {"issue": issue, **detail}
    return best


def comment_body(title: str, body: str, score: float, repo: str) -> str:
    excerpt = (body or "").strip()
    if len(excerpt) > 1200:
        excerpt = excerpt[:1200].rstrip() + "\n…"
    return (
        f"Same-problem duplicate suppressed by the fleet-ops#1212 filing gate "
        f"(score={score:.2f}).\n\n"
        f"Would have filed in `{repo}`:\n\n"
        f"**{title}**\n\n"
        f"{excerpt}\n"
    )


def duplicate_marker(ref: str, score: float) -> str:
    return (
        f"<!-- possible-duplicate-of: {ref} score={score:.2f} -->\n"
        f"Possible duplicate of {ref} (score {score:.2f}). "
        f"Weekly Review: confirm or close as duplicate.\n\n"
    )


def gh_comment(repo: str, number: int, body: str) -> tuple[int, str]:
    proc = subprocess.run(
        [gh_bin(), "issue", "comment", str(number), "--repo", repo, "--body", body],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, (proc.stdout or "").strip() or (proc.stderr or "").strip()


def gh_create(repo: str, title: str, body: str, labels: list[str], body_file: str) -> tuple[int, str]:
    cmd = [gh_bin(), "issue", "create", "--repo", repo, "--title", title]
    tmp = None
    if body_file:
        cmd += ["--body-file", body_file]
    else:
        cmd += ["--body", body]
    for label in labels:
        cmd += ["--label", label]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    text = (proc.stdout or "").strip() or (proc.stderr or "").strip()
    return proc.returncode, text


def parse_created_url(text: str) -> tuple[str, int | None]:
    url = ""
    for token in (text or "").split():
        if "github.com/" in token and "/issues/" in token:
            url = token.strip()
            break
    if not url:
        return text, None
    try:
        number = int(url.rstrip("/").rsplit("/", 1)[-1])
    except ValueError:
        number = None
    return url, number


def emit(payload: dict, as_json: bool, url: str) -> None:
    if as_json:
        print(json.dumps(payload, sort_keys=True))
        return
    if url:
        print(url)
    else:
        print(json.dumps(payload, sort_keys=True))


def cmd_score(args: argparse.Namespace) -> int:
    issues = load_open_from_json(args.against_json)
    match = best_match(args.title, args.body or "", issues)
    if not match:
        print(json.dumps({"score": 0, "kind": "new"}))
        return 0
    match["kind"] = classify(match["score"])
    match["existing"] = issue_ref(match.pop("issue"))
    print(json.dumps(match, sort_keys=True))
    return 0


def cmd_file(args: argparse.Namespace) -> int:
    title = args.title
    if args.body_file:
        body = Path(args.body_file).read_text(encoding="utf-8")
    else:
        body = args.body or ""
    labels = list(args.label or [])
    issues = collect_open(
        args.repo,
        args.from_json,
        cross_repo=not args.no_cross_repo,
        extra_repos=args.search_repo or [],
    )
    match = best_match(title, body, issues) if issues else None
    score = match["score"] if match else 0.0
    kind = classify(score) if match else "new"
    existing = match["issue"] if match else None

    payload = {
        "action": "filed",
        "score": score,
        "kind": kind,
        "existing": issue_ref(existing) if existing else None,
        "url": "",
        "number": None,
        "repo": args.repo,
    }

    if kind == "duplicate" and existing:
        payload["action"] = "commented"
        repo = existing.get("repository") or args.repo
        number = existing["number"]
        payload["number"] = number
        payload["url"] = existing.get("url") or f"https://github.com/{repo}/issues/{number}"
        if args.dry_run:
            print(f"[issue-file] dry-run comment {payload['existing']} score={score:.2f}", file=sys.stderr)
            emit(payload, args.json, payload["url"])
            return 0
        rc, out = gh_comment(repo, number, comment_body(title, body, score, args.repo))
        if rc != 0:
            print(f"[issue-file] comment failed on {payload['existing']}: {out}", file=sys.stderr)
            return 1
        print(f"[issue-file] commented {payload['existing']} score={score:.2f}", file=sys.stderr)
        emit(payload, args.json, payload["url"])
        return 0

    file_body = body
    if kind == "borderline" and existing:
        payload["action"] = "filed-borderline"
        file_body = duplicate_marker(issue_ref(existing), score) + body

    if args.dry_run:
        print(f"[issue-file] dry-run {payload['action']} score={score:.2f}", file=sys.stderr)
        emit(payload, args.json, "")
        return 0

    body_file = args.body_file
    tmp_path = None
    if kind == "borderline" and existing:
        import tempfile

        tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False, suffix=".md")
        tmp.write(file_body)
        tmp.close()
        tmp_path = tmp.name
        body_file = tmp_path
        file_body_arg = file_body
    else:
        file_body_arg = file_body

    try:
        rc, out = gh_create(
            args.repo,
            title,
            file_body_arg,
            labels,
            body_file or "",
        )
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    if rc != 0:
        print(f"[issue-file] create failed: {out}", file=sys.stderr)
        return 1
    url, number = parse_created_url(out)
    payload["url"] = url
    payload["number"] = number
    print(f"[issue-file] {payload['action']} {url or out} score={score:.2f}", file=sys.stderr)
    emit(payload, args.json, url or out)
    return 0


def cmd_sweep(args: argparse.Namespace) -> int:
    repos = list(args.repo or [])
    if not repos and not args.from_json:
        repos = enrolled_repos()
    issues: list[dict] = []
    if args.from_json:
        issues = load_open_from_json(args.from_json)
    else:
        seen: set[tuple[str, int]] = set()
        for repo in repos:
            for issue in gh_list_open(repo):
                key = (issue["repository"], issue["number"])
                if key in seen:
                    continue
                seen.add(key)
                issues.append(issue)

    n = len(issues)
    parent = list(range(n))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    # Compute every pair score. The sweep clusters only by DUP_THRESHOLD so a
    # cluster means "each member has at least one strongly similar peer", not
    # "transitively reachable through a chain of borderline matches". The
    # file-time decision is still pair-wise (best_match) and uses the lower
    # BORDERLINE_THRESHOLD, so this only affects the backlog report.
    pair_scores: dict[tuple[int, int], float] = {}
    for i in range(n):
        for j in range(i + 1, n):
            detail = score_pair(
                issues[i].get("title") or "",
                issues[i].get("body") or "",
                issues[j].get("title") or "",
                issues[j].get("body") or "",
            )
            if detail["score"] >= DUP_THRESHOLD:
                union(i, j)
            if detail["score"] >= BORDERLINE_THRESHOLD:
                pair_scores[(i, j)] = detail["score"]

    groups: dict[int, list[int]] = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(i)

    clusters = []
    for members in groups.values():
        if len(members) < 2:
            continue
        # Require at least half the cluster to have a strong peer inside the
        # cluster. A transitive chain (A-B, B-C, A-C low) would still cluster
        # under union-find, but the per-member peer count would be 1; this
        # rule trims those so the report shows actionable peer groups.
        peer_count: dict[int, int] = {i: 0 for i in members}
        max_s = 0.0
        for a in range(len(members)):
            for b in range(a + 1, len(members)):
                i, j = members[a], members[b]
                key = (min(i, j), max(i, j))
                s = pair_scores.get(key, 0.0)
                if s >= DUP_THRESHOLD:
                    peer_count[i] += 1
                    peer_count[j] += 1
                max_s = max(max_s, s)
        min_peers = max(1, len(members) // 2)
        kept = [i for i in members if peer_count[i] >= min_peers]
        if len(kept) < 2:
            continue
        kind = "duplicate" if max_s >= DUP_THRESHOLD else "borderline"
        clusters.append(
            {
                "kind": kind,
                "max_score": round(max_s, 4),
                "size": len(kept),
                "issues": [
                    {
                        "repository": issues[i].get("repository") or "",
                        "number": issues[i]["number"],
                        "title": issues[i].get("title") or "",
                        "url": issues[i].get("url") or "",
                    }
                    for i in sorted(kept, key=lambda k: (issues[k].get("repository") or "", issues[k]["number"]))
                ],
            }
        )
    clusters.sort(key=lambda c: (-c["max_score"], -c["size"]))
    report = {
        "open_count": n,
        "repos": repos,
        "threshold_duplicate": DUP_THRESHOLD,
        "threshold_borderline": BORDERLINE_THRESHOLD,
        "cluster_count": len(clusters),
        "clusters": clusters,
    }
    text = json.dumps(report, indent=2, sort_keys=True)
    print(text)
    if args.output_json:
        Path(args.output_json).write_text(text + "\n", encoding="utf-8")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="fleet-ops#1212 filing-time same-problem dedupe")
    sub = p.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("file", help="score against open issues, then comment or create")
    f.add_argument("--repo", "-R", required=True)
    f.add_argument("--title", required=True)
    f.add_argument("--body", default="")
    f.add_argument("--body-file", default="")
    f.add_argument("--label", action="append", default=[])
    f.add_argument("--from-json", default="")
    f.add_argument("--search-repo", action="append", default=[])
    f.add_argument("--no-cross-repo", action="store_true")
    f.add_argument("--dry-run", action="store_true")
    f.add_argument("--json", action="store_true")
    f.set_defaults(func=cmd_file)

    s = sub.add_parser("sweep", help="cluster the current open queue")
    s.add_argument("--repo", "-R", action="append", default=[])
    s.add_argument("--from-json", default="")
    s.add_argument("--output-json", default="")
    s.set_defaults(func=cmd_sweep)

    sc = sub.add_parser("score", help="score one candidate against a JSON issue list")
    sc.add_argument("--title", required=True)
    sc.add_argument("--body", default="")
    sc.add_argument("--against-json", required=True)
    sc.set_defaults(func=cmd_score)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
