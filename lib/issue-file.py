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

# close-duplicates: only `agent-ready` issues (unclaimed) are safe to close —
# agent-in-progress has a live worker, agent-blocked is Nish-gated, red-on-main
# is a reserved class. Keep the oldest (lowest number) open issue as canonical.
CLOSE_CAP = 10
CLOSE_OK_ENV = "FLEET_CLOSE_DUPLICATES_OK"
CLOSE_REVIEW_LOG_ENV = "FLEET_CLOSE_DUPLICATES_REVIEW_LOG"
# cluster size above which close-duplicates stops closing and comments only,
# filing one dup-cluster review line (fleet-ops#3161). A large cluster held
# together only by a shared primary signal floor is the known false-positive
# shape; comment-only keeps the marker without risking mass wrong closes.
CLUSTER_CLOSE_MAX = 4
# Issues authored by the repo owner are never auto-closed — comment only
# (fleet-ops#3161). Nish-endorsed critical-path packets must survive a
# bogus duplicate sweep.
OWNER_LOGIN = "nish3451"
PROTECTED_LABELS = frozenset(
    {"agent-in-progress", "agent-blocked", "red-on-main", "critical-path"}
)

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

# --- signal keys -----------------------------------------------------------
# Structured signals survive wording differences.  Explicit `signal:` markers
# are the most reliable; derived signals capture alert names, failure/health
# classes, and the seat-corpse/walled root-cause cluster from fleet-ops#2899.

SIGNAL_BONUS = 0.15
SIGNAL_BONUS_MAX = 0.30
PRIMARY_SIGNAL_FLOOR = 0.70

SIGNAL_RE = re.compile(r"^signal:\s*(\S+)", re.MULTILINE | re.IGNORECASE)
ALERT_RE = re.compile(r"\b(Fleet[A-Z][A-Za-z]+)\b")
FAILURE_MODE_RE = re.compile(r"\bfailure_mode\s*[:=]\s*([A-Za-z0-9_-]+)\b")
HEALTH_CLASS_RE = re.compile(r"\bhealth_class\s*[:=]\s*([A-Za-z0-9_-]+)\b")
SEAT_DEAD_RE = re.compile(r"\bseat_dead\s*[:=]\s*true\b")

COMMON_SIGNALS = frozenset()
PRIMARY_SIGNAL_PREFIXES = ("signal/", "fleet/seat-crisis")


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


def _has_seat_crisis(text: str) -> bool:
    """Detect the fleet-ops#2899 seat-corpse/walled/credentials root cause cluster.

    Requires both a seat context and a failure state/cause.  This is intentionally
    specific: a generic "seat cap" or "healthy seats" mention must not trigger.
    """
    low = (text or "").lower()
    seat = bool(
        re.search(r"\bseats?\b", text)
        or re.search(r"\bfleet(?:slo|dead|seat)", text, re.IGNORECASE)
        or "health_class=corpse" in low
        or "manual_repair_corpse" in low
        or "seat_dead" in low
    )
    cause = bool(
        "corpse" in low
        or "dead" in low
        or "walled" in low
        or "comeback" in low
        or "credentials_bad" in low
        or "credentials bad" in low
        or "manual_repair_corpse" in low
        or "health_class=corpse" in low
        or "seat_dead" in low
    )
    return seat and cause


def signal_keys(text: str) -> set[str]:
    """Return canonical structured signal keys extracted from text."""
    out: set[str] = set()

    # Explicit `signal:` markers (e.g. `signal: scout-futility/foo`) are the most
    # reliable primary signals.  Any two issues carrying the same marker group.
    for m in SIGNAL_RE.finditer(text or ""):
        marker = m.group(1).strip().rstrip(".").lower()
        if marker:
            out.add(f"signal/{marker}")

    # Alert, failure-mode, and health-class fields are noisy but useful as
    # secondary signals; they boost the score without forcing a duplicate.
    for m in ALERT_RE.finditer(text or ""):
        out.add(f"alert/{m.group(1).lower()}")
    for m in FAILURE_MODE_RE.finditer(text or ""):
        out.add(f"failure/{m.group(1).lower()}")
    for m in HEALTH_CLASS_RE.finditer(text or ""):
        out.add(f"health/{m.group(1).lower()}")
    for m in SEAT_DEAD_RE.finditer(text or ""):
        out.add("health/corpse")
        out.add("state/seat-dead")

    # Derived primary signal for the seat-corpse/walled/credentials cluster
    # described in fleet-ops#2899.  Two issues with this signal are treated as
    # duplicates of the same root cause, regardless of wording differences.
    if _has_seat_crisis(text):
        out.add("fleet/seat-crisis")

    return out


def _is_primary_signal(signal: str) -> bool:
    return signal.startswith(PRIMARY_SIGNAL_PREFIXES)


def score_pair(
    title_a: str,
    body_a: str,
    title_b: str,
    body_b: str,
) -> dict:
    """Return scoring details including token overlap, key paths, and signals."""
    t = overlap(title_a, title_b)
    combined_a = f"{title_a}\n{body_a}"
    combined_b = f"{title_b}\n{body_b}"
    b = overlap(combined_a, combined_b)
    shared = key_paths(combined_a) & key_paths(combined_b)
    specific_shared = {k for k in shared if k not in COMMON_KEY_PATHS}
    key_bonus = KEY_BONUS if specific_shared else 0.0

    signals_a = signal_keys(combined_a)
    signals_b = signal_keys(combined_b)
    shared_signals = signals_a & signals_b
    primary_shared = {s for s in shared_signals if _is_primary_signal(s)}
    secondary_shared = shared_signals - primary_shared - COMMON_SIGNALS
    secondary_bonus = min(SIGNAL_BONUS * len(secondary_shared), SIGNAL_BONUS_MAX)

    score = min(1.0, max(t, b) + key_bonus + secondary_bonus)
    if primary_shared:
        score = max(score, PRIMARY_SIGNAL_FLOOR)

    return {
        "score": round(score, 4),
        "title_overlap": round(t, 4),
        "body_overlap": round(b, 4),
        # max(t, b) is the pairwise token-overlap signal a close-duplicates
        # CLOSE must clear on its own (fleet-ops#3161). Primary/secondary
        # signal floors may raise `score` to a duplicate-class cluster, but
        # they can never authorise a close — only token overlap can.
        "token_overlap_max": round(max(t, b), 4),
        "shared_keys": sorted(shared),
        "specific_shared_keys": sorted(specific_shared),
        "shared_signals": sorted(shared_signals),
        "primary_shared_signals": sorted(primary_shared),
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
                "labels": list(item.get("labels") or []),
                "author": _author_login(item.get("author")),
            }
        )
    return out


def _author_login(author) -> str:
    """Normalise the gh `author` field (object {login: ...} or a bare string)
    to a login. Missing/unknown authors resolve to "" so close-duplicates can
    treat only a confirmed OWNER_LOGIN as owner-authored (fleet-ops#3161)."""
    if not author:
        return ""
    if isinstance(author, dict):
        return (author.get("login") or "").strip()
    return str(author).strip()


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
            "number,title,body,url,labels,author",
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
        labels = []
        for lab in item.get("labels") or []:
            if isinstance(lab, dict) and lab.get("name"):
                labels.append(lab["name"])
            elif isinstance(lab, str):
                labels.append(lab)
        out.append(
            {
                "number": number,
                "title": item.get("title") or "",
                "body": item.get("body") or "",
                "url": item.get("url") or "",
                "repository": repo,
                "labels": labels,
                "author": _author_login(item.get("author")),
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


def gh_close(repo: str, number: int, comment: str) -> tuple[int, str]:
    proc = subprocess.run(
        [gh_bin(), "issue", "close", str(number), "--repo", repo, "--comment", comment],
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


def cluster_issues(issues: list[dict]) -> list[dict]:
    """Cluster open issues by same-problem similarity (fleet-ops#1212 sweep).

    Returns a list of cluster dicts (sorted by descending max_score then size):
      {"kind": "duplicate"|"borderline", "max_score": float, "size": int,
       "issues": [{"repository","number","title","url","labels"}, ...]}
    Only clusters with >=2 members are returned. Each member carries its
    labels so callers (close-duplicates) can filter by claim state.
    """
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
                        "labels": list(issues[i].get("labels") or []),
                    }
                    for i in sorted(kept, key=lambda k: (issues[k].get("repository") or "", issues[k]["number"]))
                ],
            }
        )
    clusters.sort(key=lambda c: (-c["max_score"], -c["size"]))
    return clusters


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

    clusters = cluster_issues(issues)
    report = {
        "open_count": len(issues),
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


def _closeable(issue: dict) -> bool:
    """An issue is safe to auto-close as a duplicate only when it is
    agent-ready (unclaimed, in the dispatch queue), not carrying a protected
    label, and not authored by the repo owner. agent-in-progress has a live
    worker; agent-blocked is Nish-gated; red-on-main is a reserved escalation
    class; critical-path is an intake priority; owner-authored issues are
    Nish-endorsed packets (fleet-ops#3161). All of these get a comment only."""
    labels = set(issue.get("labels") or [])
    if "agent-ready" not in labels:
        return False
    if labels & PROTECTED_LABELS:
        return False
    if (issue.get("author") or "") == OWNER_LOGIN:
        return False
    return True


def _dup_comment_body(ref: str, canon_ref: str, score: float, reason: str, kind: str) -> str:
    """Build the duplicate marker comment body.

    kind="close"  -> a `duplicate-of` close comment (same-repo canonical,
                     pairwise token overlap cleared DUP_THRESHOLD).
    kind="comment" -> a `possible-duplicate-of` comment that does NOT close;
                     reason explains why (protected / low-overlap /
                     cluster-size). Never cites a cross-repo canonical in a
                     close comment because cross-repo never reaches kind=close.
    """
    if kind == "close":
        return (
            f"<!-- duplicate-of: {canon_ref} score={score:.2f} -->\n"
            f"Closing as duplicate of {canon_ref} "
            f"(fleet-issue-file close-duplicates, pairwise score={score:.2f}). "
            f"The oldest open issue in this repo's cluster is the canonical.\n"
        )
    return (
        f"<!-- possible-duplicate-of: {canon_ref} score={score:.2f} reason={reason} -->\n"
        f"Possible duplicate of {canon_ref} (score {score:.2f}). "
        f"Not auto-closed: {reason}.\n"
    )


def _closes_by_label_zero() -> dict:
    return {
        "cross_repo=true,protected=true": 0,
        "cross_repo=true,protected=false": 0,
        "cross_repo=false,protected=true": 0,
        "cross_repo=false,protected=false": 0,
    }


def cmd_close_duplicates(args: argparse.Namespace) -> int:
    """Drain the duplicate backlog the sweep identifies (fleet-ops#2762).

    Close rules (fleet-ops#3161 — the primary-signal floor + cross-repo
    canonical once closed 18 issues incl. two Nish-endorsed critical-path
    packets as score=1.00 duplicates of an unrelated 0509 CI issue):
      - A CLOSE requires pairwise token overlap max(t,b) >= DUP_THRESHOLD
        on its own. Primary/secondary signal floors may cluster issues and
        produce a possible-duplicate COMMENT, never a close.
      - The canonical is the oldest open issue IN THE SAME REPO. Cross-repo
        similarity is comment-only; a close comment never cites a cross-repo
        canonical.
      - PROTECTED_LABELS includes critical-path; issues authored by the repo
        owner (nish3451) are never auto-closed — comment only.
      - A close cites the pairwise score to the canonical, not a transitive
        cluster max score. Clusters larger than CLUSTER_CLOSE_MAX are
        comment-only and file one dup-cluster review line.
    Capped per run. Fail-closed: FLEET_CLOSE_DUPLICATES_OK=1 required to
    actually close (one-off tests cannot phantom-close)."""
    ok = os.environ.get(CLOSE_OK_ENV, "0") == "1"
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

    clusters = [c for c in cluster_issues(issues) if c["kind"] == "duplicate"]
    cap = args.cap if args.cap is not None else CLOSE_CAP
    # Full issue index (cluster members carry labels but not body/author, so
    # look up the source issue for pairwise scoring and the owner check).
    index = {(i.get("repository") or "", i["number"]): i for i in issues}
    review_log = os.environ.get(CLOSE_REVIEW_LOG_ENV, "")

    closed = 0
    commented = 0
    skipped = 0
    actions = []
    cluster_reviews = []
    closes_by_label = _closes_by_label_zero()

    for cluster in clusters:
        members = sorted(
            cluster["issues"],
            key=lambda i: (i.get("repository") or "", i["number"]),
        )
        size = len(members)
        too_big = size > CLUSTER_CLOSE_MAX
        # Canonical is per-repo: the oldest (lowest number) open issue in
        # the SAME repo. A member that is its repo's canonical is never
        # acted on; a member with no same-repo peer is its own canonical.
        by_repo: dict[str, list[dict]] = {}
        for m in members:
            by_repo.setdefault(m.get("repository") or "", []).append(m)
        repo_canon = {
            repo: sorted(ms, key=lambda i: i["number"])[0]
            for repo, ms in by_repo.items()
        }

        if too_big:
            canon_refs = sorted(
                issue_ref({"repository": r, "number": c["number"]})
                for r, c in repo_canon.items()
            )
            review = (
                f"dup-cluster review: cluster of {size} issues across "
                f"{len(by_repo)} repo(s) — comment-only "
                f"(size > {CLUSTER_CLOSE_MAX}); canonicals: "
                f"{', '.join(canon_refs)}"
            )
            cluster_reviews.append(review)
            if review_log:
                try:
                    with open(review_log, "a", encoding="utf-8") as fh:
                        fh.write(review + "\n")
                except OSError:
                    pass

        for m in members:
            repo = m.get("repository") or ""
            ref = issue_ref({"repository": repo, "number": m["number"]})
            canon = repo_canon.get(repo)
            if canon is None or canon["number"] == m["number"]:
                # This member is its repo's canonical — never acted on.
                continue
            canon_ref = issue_ref({"repository": repo, "number": canon["number"]})
            mi = index.get((repo, m["number"]), m)
            ci = index.get((repo, canon["number"]), canon)
            pair = score_pair(
                mi.get("title") or "",
                mi.get("body") or "",
                ci.get("title") or "",
                ci.get("body") or "",
            )
            score = pair["score"]
            token_max = pair["token_overlap_max"]
            protected = not _closeable(mi)

            reason = None
            if too_big:
                reason = "cluster-size"
            elif protected:
                reason = "protected"
            elif token_max < DUP_THRESHOLD:
                # The pair only reached duplicate-class via a signal floor,
                # not token overlap. Comment only (fleet-ops#3161).
                reason = "low-overlap"

            if reason is not None:
                body = _dup_comment_body(ref, canon_ref, score, reason, "comment")
                if args.dry_run:
                    print(
                        f"[close-duplicates] dry-run comment {ref} -> {canon_ref} ({reason})",
                        file=sys.stderr,
                    )
                    actions.append(
                        {"ref": ref, "canonical": canon_ref, "action": "comment",
                         "reason": reason, "score": score}
                    )
                    commented += 1
                    continue
                rc, out = gh_comment(repo, m["number"], body)
                if rc == 0:
                    print(
                        f"[close-duplicates] commented {ref} -> {canon_ref} ({reason})",
                        file=sys.stderr,
                    )
                    actions.append(
                        {"ref": ref, "canonical": canon_ref, "action": "comment",
                         "reason": reason, "score": score}
                    )
                    commented += 1
                else:
                    print(f"[close-duplicates] comment failed {ref}: {out}", file=sys.stderr)
                    skipped += 1
                continue

            # Close path: same-repo canonical, token overlap cleared, closeable.
            if closed >= cap:
                print(f"[close-duplicates] cap reached ({cap}); skip close {ref}", file=sys.stderr)
                skipped += 1
                continue
            body = _dup_comment_body(ref, canon_ref, score, "duplicate", "close")
            if args.dry_run or not ok:
                label = "dry-run close" if args.dry_run else "close-blocked (OK!=1)"
                print(f"[close-duplicates] {label} {ref} -> {canon_ref}", file=sys.stderr)
                actions.append(
                    {"ref": ref, "canonical": canon_ref,
                     "action": "close" if args.dry_run else "noop",
                     "reason": label, "score": score}
                )
                if args.dry_run:
                    closed += 1
                    closes_by_label["cross_repo=false,protected=false"] += 1
                else:
                    skipped += 1
                continue
            rc, out = gh_close(repo, m["number"], body)
            if rc == 0:
                print(f"[close-duplicates] CLOSED {ref} -> {canon_ref}", file=sys.stderr)
                actions.append(
                    {"ref": ref, "canonical": canon_ref, "action": "close",
                     "reason": "duplicate", "score": score}
                )
                closed += 1
                closes_by_label["cross_repo=false,protected=false"] += 1
            else:
                print(f"[close-duplicates] close failed {ref}: {out}", file=sys.stderr)
                skipped += 1

    summary = {
        "open_count": len(issues),
        "duplicate_clusters": len(clusters),
        "closed": closed,
        "commented": commented,
        "skipped": skipped,
        "cap": cap,
        "ok": ok,
        "dry_run": args.dry_run,
        "actions": actions,
        "cluster_reviews": cluster_reviews,
        "closes_by_label": closes_by_label,
    }
    text = json.dumps(summary, indent=2, sort_keys=True)
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

    cd = sub.add_parser(
        "close-duplicates",
        help="close agent-ready duplicate-cluster members, keeping the oldest (fleet-ops#2762)",
    )
    cd.add_argument("--repo", "-R", action="append", default=[])
    cd.add_argument("--from-json", default="")
    cd.add_argument("--output-json", default="")
    cd.add_argument("--cap", type=int, default=None)
    cd.add_argument("--dry-run", action="store_true")
    cd.set_defaults(func=cmd_close_duplicates)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
