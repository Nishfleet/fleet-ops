#!/usr/bin/env python3
"""pi-packet-verdict — re-run worker VERIFY blocks and report the real outcome.

VERIFY block format (inside a PR body or packet output):

<!--VERIFY-->
must-run: <shell command>
must-match: <regex pattern that must appear in the command's stdout+stderr>
verdict: PASS
<!--END-VERIFY-->

Every must-run is executed. Each must-match applies to the nearest preceding
must-run output (stdout+stderr combined). A block passes only when ALL its
must-match patterns match.

Worker can optionally include `verdict: PASS` or `verdict: FAIL` — the real
verdict overrides this when they differ.

Modes:
  --body FILE       Check a single PR body or packet output file.
  --live-claims FILE
                    Only run the LIVE-claim gate (fleet-ops#5786): every line
                    containing LIVE / DEPLOYED / live-on-host must cite, on
                    the same line, a SHA proven present on origin/main of a
                    known clone (`git merge-base --is-ancestor`).
  --scan            Scan open nishfleet-worker PRs for VERIFY blocks.
  --scan-prs FILE   Like --scan but reads a pre-fetched gh JSON array.
  --metricsonly     Write zeroed metrics and exit.

Environment seams (for test injection):
  PI_VERDICT_TIMEOUT      per-command timeout seconds (default 30)
  PI_VERDICT_GH           gh binary path
  PI_VERDICT_INTAKE       intake-repos.json path
  PI_VERDICT_ISSUE_REPO   where to file findings (default Nishfleet/fleet-ops)
  PI_VERDICT_FILE         1/0 — auto-file findings (default 1)
  PI_VERDICT_CLOSE        1/0 — observe-to-close (default 1)
  PI_VERDICT_CAP          per-tick auto-file cap (default 5)
  PI_VERDICT_LIST_LIMIT   gh issue list limit (default 1000)
  PI_VERDICT_NOW          ISO timestamp override
  PI_VERDICT_LIVE_REPO_DIRS
                          os.pathsep-separated extra repo checkouts for the
                          LIVE-claim gate (always appended to the default set)
  PI_VERDICT_LIVE_FETCH   1/0 — `git fetch -q origin` before ancestry checks
                          (default 1)
  FLEET_OPS_CHECKOUT      deploy clone path (default live claim repo)
  FLEET_HEARTBEAT_TRIAGE  triage log path
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------

VERIFY_OPEN    = re.compile(r"<!--\s*VERIFY\s*-->\s*$", re.I)
VERIFY_CLOSE   = re.compile(r"<!--\s*END-?VERIFY\s*-->\s*$", re.I)
MUST_RUN       = re.compile(r"^must-run:\s+(.+)$", re.I)
MUST_MATCH     = re.compile(r"^must-match:\s+(.+)$", re.I)
WORKER_VERDICT = re.compile(r"^verdict:\s+(PASS|FAIL)\s*$", re.I)

TIMEOUT    = int(os.environ.get("PI_VERDICT_TIMEOUT", "30"))
GH         = os.environ.get("PI_VERDICT_GH", "gh")
HOME       = Path.home()
TRIAGE     = Path(os.environ.get(
    "FLEET_HEARTBEAT_TRIAGE",
    str(HOME / "workspaces/agent-state/FLEET-HEARTBEAT-TRIAGE.md"),
))
INTAKE     = Path(os.environ.get(
    "PI_VERDICT_INTAKE",
    str(HOME / "workspaces/tooling/fleet-ops/config/intake-repos.json"),
))
if not INTAKE.exists():
    INTAKE = Path(
        "/home/nish/workspaces/products/fleet-ops/config/intake-repos.json"
    )

FILE_FINDINGS = os.environ.get("PI_VERDICT_FILE", "1")
CLOSE_ISSUES  = os.environ.get("PI_VERDICT_CLOSE", "1")
CAP           = int(os.environ.get("PI_VERDICT_CAP", "5"))
LIST_LIMIT    = int(os.environ.get("PI_VERDICT_LIST_LIMIT", "1000"))
ISSUE_REPO    = os.environ.get("PI_VERDICT_ISSUE_REPO", "Nishfleet/fleet-ops")
METRIC_FILE   = Path("/var/lib/prometheus/node-exporter/fleet-verdict.prom")

# ---- LIVE-claim gate (fleet-ops#5786) ---------------------------------------
# A deliverable may only claim LIVE / DEPLOYED / live-on-host when the SAME
# line cites a SHA already present on origin/main of a known clone —
# `git merge-base --is-ancestor`. A fix still on a branch is a PR, not live
# state: the 2026-09-12 incident was an alert-repair worker reporting
# "Live on this host" after inspecting a deploy clone it had left checked out
# on its fix branch while the PR was still open with auto-merge off.
LIVE_CLAIM = re.compile(
    r"\bLIVE\b"                                             # all-caps token
    r"|(?i:\bdeployed\b)"                                   # deployed/DEPLOYED
    r"|(?i:\blive[- ]+on[- ]+(?:(?:this|the)[- ]+)?host\b)" # live on (this|the) host
)
SHA_TOKEN  = re.compile(r"\b[0-9a-f]{7,40}\b", re.I)
LIVE_REFS  = ("origin/main", "main")
LIVE_FETCH = os.environ.get("PI_VERDICT_LIVE_FETCH", "1") == "1"


# ---- helpers --------------------------------------------------------------


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _log(msg):
    print(f"[{_now()}] [pi-packet-verdict] {msg}", file=sys.stderr)


def _loud(tag, msg):
    _log(f"LOUD [{tag}] {msg}")
    try:
        TRIAGE.parent.mkdir(parents=True, exist_ok=True)
        with open(TRIAGE, "a") as f:
            f.write(f"\n[{_now()}] [{tag}] {msg}\n")
    except OSError:
        _log(f"WARN: cannot append to {TRIAGE}")


def _run(cmd):
    """Run a shell command, return (stdout+stderr, exit_code, timed_out)."""
    try:
        r = subprocess.run(
            ["bash", "-c", cmd],
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
            env={**os.environ, "HOME": str(HOME)},
        )
        out = (r.stdout or "") + "\n" + (r.stderr or "")
        return out, r.returncode, False
    except subprocess.TimeoutExpired:
        return "", -1, True
    except OSError as exc:
        return str(exc), -1, False


# ---- parse ----------------------------------------------------------------


def parse_blocks(text):
    """Extract VERIFY blocks from markdown text.

    Returns list of dicts with:
      commands:        list of (cmd, [pattern, ...])
      worker_verdict:  "PASS" | "FAIL" | None
    """
    blocks = []
    in_block = False
    cur_cmds = []
    cur_pats = []  # patterns seen before the first must-run in this block
    cur_wv = None

    for line in text.splitlines():
        ls = line.strip()

        if VERIFY_OPEN.match(ls):
            # Flush any unclosed block.
            if in_block and cur_cmds:
                blocks.append({"commands": cur_cmds, "worker_verdict": cur_wv})
            in_block = True
            cur_cmds = []
            cur_pats = []
            cur_wv = None
            continue

        if not in_block:
            continue

        if VERIFY_CLOSE.match(ls):
            # Attach leftover patterns to last command.
            if cur_pats and cur_cmds:
                cur_cmds[-1] = (cur_cmds[-1][0], cur_cmds[-1][1] + cur_pats)
                cur_pats = []
            if cur_cmds:
                blocks.append({"commands": cur_cmds, "worker_verdict": cur_wv})
            in_block = False
            cur_cmds = []
            cur_pats = []
            cur_wv = None
            continue

        m = MUST_RUN.match(ls)
        if m:
            # Flush accumulated orphan patterns into last command.
            if cur_pats and cur_cmds:
                cur_cmds[-1] = (cur_cmds[-1][0], cur_cmds[-1][1] + cur_pats)
                cur_pats = []
            cur_cmds.append((m.group(1).strip(), []))
            continue

        m = MUST_MATCH.match(ls)
        if m:
            pat = m.group(1).strip()
            if cur_cmds:
                cur_cmds[-1] = (cur_cmds[-1][0], cur_cmds[-1][1] + [pat])
            else:
                cur_pats.append(pat)
            continue

        m = WORKER_VERDICT.match(ls)
        if m:
            cur_wv = m.group(1).upper()

    # EOF — close unclosed block.
    if in_block and cur_cmds:
        if cur_pats and cur_cmds:
            cur_cmds[-1] = (cur_cmds[-1][0], cur_cmds[-1][1] + cur_pats)
        blocks.append({"commands": cur_cmds, "worker_verdict": cur_wv})

    return blocks


# ---- check ----------------------------------------------------------------


def check_block(block):
    """Re-run all commands in a block, check patterns."""
    details = []
    all_ok = True

    for cmd, patterns in block["commands"]:
        out, rc, to = _run(cmd)
        matched = []
        missing = []

        for pat in patterns:
            try:
                rx = re.compile(pat, re.I | re.M)
            except re.error:
                missing.append(f"(invalid regex) {pat}")
                continue
            if rx.search(out):
                matched.append(pat)
            else:
                missing.append(pat)

        if missing:
            all_ok = False

        details.append({
            "command":   cmd,
            "rc":        rc,
            "timed_out": to,
            "output":    out[:2000],
            "matched":   matched,
            "missing":   missing,
        })

    return {"passed": all_ok, "details": details}


def check_body(body_text, repo_dirs=None):
    """Check all VERIFY blocks in a body plus the LIVE-claim gate.

    repo_dirs: pre-resolved repo checkouts for the LIVE-claim gate, or None
    to resolve --repo-dir/PI_VERDICT_LIVE_REPO_DIRS/defaults.
    """
    blocks = parse_blocks(body_text)
    violations = live_claim_violations(body_text, repo_dirs)
    if not blocks:
        return {
            "has_blocks": False,
            "passed": False if violations else None,
            "blocks": [],
            "live_claim_violations": violations,
        }

    results = []
    all_ok = not violations
    for blk in blocks:
        r = check_block(blk)
        r["worker_verdict"] = blk["worker_verdict"]
        results.append(r)
        if not r["passed"]:
            all_ok = False

    return {"has_blocks": True, "passed": all_ok, "blocks": results,
            "live_claim_violations": violations}


# ---- intake repos ----------------------------------------------------------


def enrolled_repos():
    """List of 'Nishfleet/<name>' from intake-repos.json."""
    try:
        data = json.loads(INTAKE.read_text())
    except (OSError, json.JSONDecodeError):
        return []
    repos = data.get("repos") or []
    if not isinstance(repos, list):
        return []
    out = []
    for r in repos:
        name = r.get("name") if isinstance(r, dict) else str(r)
        if name and isinstance(name, str):
            out.append(f"Nishfleet/{name}")
    return out


# ---- scan (gh) ------------------------------------------------------------


def fetch_worker_prs():
    """List open 'nishfleet-worker' PRs across all enrolled repos."""
    repos = enrolled_repos()
    if not repos:
        return []
    all_prs = []
    for repo in repos:
        try:
            r = subprocess.run(
                [GH, "pr", "list", "-R", repo, "--app", "nishfleet-worker",
                 "--state", "open", "--limit", "50",
                 "--json", "number,title,body,createdAt,url,headRefName,repository"],
                capture_output=True,
                text=True,
                timeout=45,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            _log(f"gh pr list failed for {repo}: {exc}")
            continue
        if r.returncode != 0:
            _log(f"gh pr list rc={r.returncode} for {repo}: {r.stderr[:200]}")
            continue
        try:
            rows = json.loads(r.stdout or "[]")
        except json.JSONDecodeError as exc:
            _log(f"gh pr list json: {exc}")
            continue
        for row in rows:
            row["repo"] = repo
            all_prs.append(row)
    return all_prs


def scan():
    """Scan open worker PRs. Returns (findings, scanned_count, passed_count)."""
    prs = fetch_worker_prs()
    findings = []
    scanned = 0
    passed = 0

    for pr in prs:
        body = pr.get("body") or ""
        blocks = parse_blocks(body)
        if not blocks:
            continue
        scanned += 1
        result = check_body(body)

        wvs = [b.get("worker_verdict") for b in result["blocks"]]
        worker_claimed_ok = any(v == "PASS" for v in wvs)

        if not result["passed"]:
            override = worker_claimed_ok
            findings.append({
                "slug":            pr.get("headRefName") or str(pr.get("number", "")),
                "number":          pr.get("number"),
                "url":             pr.get("url", ""),
                "title":           pr.get("title", ""),
                "repo":            pr.get("repo", ""),
                "worker_verdicts": wvs,
                "real_passed":     False,
                "override":        override,
                "details":         result["blocks"],
                "live_claim_violations": result.get("live_claim_violations", []),
            })
        else:
            passed += 1

    return findings, scanned, passed


def scan_prs(prs):
    """Like scan() but with a pre-fetched PR list."""
    findings = []
    scanned = 0
    passed = 0

    for pr in prs:
        body = pr.get("body") or ""
        blocks = parse_blocks(body)
        if not blocks:
            continue
        scanned += 1
        result = check_body(body)

        wvs = [b.get("worker_verdict") for b in result["blocks"]]
        worker_claimed_ok = any(v == "PASS" for v in wvs)

        if not result["passed"]:
            findings.append({
                "slug":            pr.get("headRefName") or str(pr.get("number", "")),
                "number":          pr.get("number"),
                "url":             pr.get("url", ""),
                "title":           pr.get("title", ""),
                "repo":            pr.get("repo", ""),
                "worker_verdicts": wvs,
                "real_passed":     False,
                "override":        worker_claimed_ok,
                "details":         result["blocks"],
                "live_claim_violations": result.get("live_claim_violations", []),
            })
        else:
            passed += 1

    return findings, scanned, passed


# ---- filing ----------------------------------------------------------------


def _existing_signal_issues():
    """Return set of 'signal: pi-packet-verdict/<slug>' markers in open issues."""
    try:
        r = subprocess.run(
            [GH, "issue", "list", "-R", ISSUE_REPO, "--state", "open",
             "--limit", str(LIST_LIMIT), "--json", "body"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        issues = json.loads(r.stdout or "[]")
    except Exception:
        return set()
    prefix = "signal: pi-packet-verdict/"
    sigs = set()
    for iss in issues:
        body = iss.get("body") or ""
        for m in re.finditer(re.escape(prefix) + r"(\S+)", body):
            sigs.add("signal: pi-packet-verdict/" + m.group(1))
    return sigs


def file_findings(findings):
    """Auto-file issues for failed verdicts (observer-to-open)."""
    if FILE_FINDINGS != "1":
        return
    existing = _existing_signal_issues()
    filed = 0

    for f in findings:
        if filed >= CAP:
            _log(f"file cap reached ({CAP}), skipping remaining")
            break

        slug = f["slug"]
        marker = f"signal: pi-packet-verdict/{slug}"

        if marker in existing:
            _log(f"dedup: {slug} already filed")
            continue
        existing.add(marker)

        detail_lines = ""
        for d in f.get("details", []):
            detail_lines += f"\n- `{d.get('command', '')}`"
            if d.get("missing"):
                detail_lines += "\n  missing: " + ", ".join(d["missing"])

        title = f"verdict(verdict-override): {slug} — worker claimed PASS, real verdict FAIL"
        body = (
            "The pi-packet-verdict checker (fleet-ops#1134) re-ran the VERIFY block "
            "and found a mismatch between the worker's claim and reality.\n\n"
            f"- PR:  {f.get('url', '')}\n"
            f"- repo: {f.get('repo', '')}\n"
            f"- worker verdicts: {', '.join(f.get('worker_verdicts', []))}\n"
            f"- real verdict:   FAIL\n\n"
            "Missing deliverables:\n"
            f"{detail_lines}\n\n"
            f"{marker}"
        )

        try:
            r = subprocess.run(
                [GH, "issue", "create", "-R", ISSUE_REPO,
                 "--title", title, "--body", body],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if r.returncode == 0:
                _log(f"filed: {slug}")
                filed += 1
            else:
                _log(f"file failed: {slug}: {r.stderr[:200]}")
        except Exception as exc:
            _log(f"file exception: {slug}: {exc}")


def observe_to_close(current_slugs):
    """Close verdict-override tickets whose slug is no longer failing."""
    if CLOSE_ISSUES != "1":
        return
    try:
        r = subprocess.run(
            [GH, "issue", "list", "-R", ISSUE_REPO, "--state", "open",
             "--limit", str(LIST_LIMIT), "--json", "number,body,title"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        issues = json.loads(r.stdout or "[]")
    except Exception as exc:
        _log(f"observe-to-close: cannot list issues: {exc}")
        return

    prefix = "signal: pi-packet-verdict/"
    closed = 0

    for iss in issues:
        body = iss.get("body") or ""
        title = iss.get("title") or ""
        num = iss.get("number")
        if "verdict(verdict-override)" not in title:
            continue

        m = re.search(re.escape(prefix) + r"(\S+)", body)
        if not m:
            continue
        slug = m.group(1)

        if slug not in current_slugs:
            try:
                r = subprocess.run(
                    [GH, "issue", "close", "-R", ISSUE_REPO, str(num),
                     "--reason", "not planned"],
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                if r.returncode == 0:
                    _log(f"closed: #{num} ({slug}) — verdict now passes")
                    closed += 1
            except Exception as exc:
                _log(f"close failed: #{num}: {exc}")

    if closed:
        _log(f"observe-to-close: closed {closed} resolved verdict tickets")


def write_metrics(pass_cnt, fail_cnt):
    """Write fleet_verdict metrics to node-exporter textfile dir."""
    try:
        METRIC_FILE.parent.mkdir(parents=True, exist_ok=True)
        lines = [
            "# HELP fleet_verdict_pass_total Independent verdict re-runs that passed.",
            "# TYPE fleet_verdict_pass_total gauge",
            f"fleet_verdict_pass_total {pass_cnt}",
            "# HELP fleet_verdict_fail_total Independent verdict re-runs that failed.",
            "# TYPE fleet_verdict_fail_total gauge",
            f"fleet_verdict_fail_total {fail_cnt}",
            "",
        ]
        METRIC_FILE.write_text("\n".join(lines) + "\n")
    except OSError as exc:
        _log(f"cannot write verdict metrics: {exc}")


# ---- LIVE-claim gate implementation (fleet-ops#5786) ------------------------


def _default_live_repo_dirs():
    """Deploy clone + local mirrors + product checkouts — the repos a live
    claim can cite."""
    dirs = [os.environ.get(
        "FLEET_OPS_CHECKOUT",
        str(HOME / "workspaces/tooling/fleet-ops-deploy-clone"),
    )]
    mirrors = HOME / "workspaces/.mirrors"
    if mirrors.is_dir():
        dirs += sorted(str(p) for p in mirrors.glob("*.git"))
    products = HOME / "workspaces/products"
    if products.is_dir():
        dirs += sorted(
            str(p) for p in products.iterdir()
            if p.is_dir() and (p / ".git").exists()
        )
    return dirs


def _live_repo_dirs(explicit=None, no_defaults=False):
    """Resolve claim-gate repos: --repo-dir args, then env extras, then the
    default deploy-clone+mirrors set (unless --no-default-repos)."""
    dirs = list(explicit or [])
    env = os.environ.get("PI_VERDICT_LIVE_REPO_DIRS", "")
    dirs += [d for d in env.split(os.pathsep) if d]
    if no_defaults:
        return dirs
    return dirs + _default_live_repo_dirs()


def _is_git_repo(path):
    try:
        r = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "--git-dir"],
            capture_output=True, timeout=15)
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _sha_on_origin_main(repo_dir, sha):
    """True when `sha` is an ancestor of origin/main (or main) in repo_dir."""
    for ref in LIVE_REFS:
        try:
            r = subprocess.run(
                ["git", "-C", str(repo_dir), "merge-base",
                 "--is-ancestor", sha, ref],
                capture_output=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if r.returncode == 0:
            return True
    return False


def live_claim_violations(text, repo_dirs=None, fetch=None):
    """Lines claiming LIVE/DEPLOYED/live-on-host with no merged SHA cited.

    Returns [{line, text, shas}] — one entry per offending line. A line with
    claim tokens but no SHA, or whose SHAs are all off origin/main in every
    known clone, is a violation. No exception path: unverifiable = rejected.
    """
    claim_lines = [(n, l) for n, l in enumerate(text.splitlines(), 1)
                   if LIVE_CLAIM.search(l)]
    if not claim_lines:
        return []
    if repo_dirs is None:
        repo_dirs = _live_repo_dirs()
    repos = [d for d in repo_dirs if _is_git_repo(d)]
    if fetch is None:
        fetch = LIVE_FETCH
    if fetch:
        for d in repos:
            try:
                subprocess.run(["git", "-C", str(d), "fetch", "-q", "origin"],
                               capture_output=True, timeout=30)
            except (OSError, subprocess.TimeoutExpired):
                pass
    proven = {}
    violations = []
    for lineno, line in claim_lines:
        shas = SHA_TOKEN.findall(line)
        ok = False
        for sha in shas:
            key = sha.lower()
            if key not in proven:
                proven[key] = any(_sha_on_origin_main(d, sha) for d in repos)
            if proven[key]:
                ok = True
                break
        if not ok:
            violations.append({
                "line": lineno,
                "text": line.strip()[:200],
                "shas": shas,
            })
    return violations


# ---- main ----------------------------------------------------------------


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--body", help="Check a single body text file")
    ap.add_argument("--live-claims",
                    help="Run only the LIVE-claim gate on a text file")
    ap.add_argument("--repo-dir", action="append", default=[],
                    help="extra repo checkout for LIVE-claim SHA proof "
                         "(repeatable; appended to the default set)")
    ap.add_argument("--no-default-repos", action="store_true",
                    help="LIVE-claim gate uses only --repo-dir/env dirs")
    ap.add_argument("--scan", action="store_true", help="Scan open worker PRs")
    ap.add_argument("--scan-prs", help="Read pre-fetched JSON array of PRs")
    ap.add_argument("--metricsonly", action="store_true",
                    help="Only write metrics (zero counts = clean state)")
    args = ap.parse_args()

    if args.metricsonly:
        write_metrics(0, 0)
        return

    live_repos = _live_repo_dirs(args.repo_dir,
                                 no_defaults=args.no_default_repos)

    # --live-claims mode: claim gate only
    if args.live_claims:
        violations = live_claim_violations(
            Path(args.live_claims).read_text(errors="replace"), live_repos)
        print(json.dumps(
            {"passed": not violations, "violations": violations}, indent=2))
        sys.exit(1 if violations else 0)

    # --body mode: single check
    if args.body:
        body_text = Path(args.body).read_text(errors="replace")
        result = check_body(body_text, live_repos)
        print(json.dumps(result, indent=2))
        if result["passed"] is False:
            sys.exit(1)
        return

    # --scan / --scan-prs mode
    if args.scan_prs:
        prs = json.loads(Path(args.scan_prs).read_text())
        findings, scanned, passed = scan_prs(prs)
    elif args.scan:
        findings, scanned, passed = scan()
    else:
        ap.print_help()
        sys.exit(0)

    file_findings(findings)
    current_slugs = {f["slug"] for f in findings}
    observe_to_close(current_slugs)

    fail_cnt = len(findings)
    write_metrics(passed, fail_cnt)

    if findings:
        _loud("PI-VERDICT-FAIL", f"real verdict FAIL for {fail_cnt} PRs (scanned={scanned})")
    else:
        _log(f"all VERIFY blocks pass (scanned={scanned})")

    print(json.dumps({
        "scanned": scanned,
        "passed": passed,
        "failed": fail_cnt,
        "findings": findings,
    }))


if __name__ == "__main__":
    main()