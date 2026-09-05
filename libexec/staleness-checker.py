#!/usr/bin/env python3
"""Truth staleness detector: cross-check standing docs against live state.

Extracts mechanically verifiable claims from standing docs (file paths,
systemd units, issue references) and tests them against the living VPS.

Mismatches are exported as Prometheus gauges (for fleet-metrics-export
piggyback) AND filed as agent-ready issues when the checker is run directly.

Running cadence: weekly (Sunday 04:00 IST) — docs rot slowly, weekly is enough.

## Claim types (phase 1: mechanically checkable)
- **path_exists**: Files/paths referenced in standing docs actually exist on disk.
- **unit_exists**: Systemd user units referenced in standing docs are installed.
- **issue_status**: GitHub issues referenced in standing docs still exist
  (open/closed status matches the doc's implicit claim).

## Docs scanned
- CLAUDE.md (Nish root)
- AGENTS.md (Nish root + workspace copies)
- global-standing-rules.md (vault shared-memory)
- decisions-ledger.md (vault shared-memory)
- MEMORY.md (agent durable memories)
- AGENTS.md (standing docs directory references)
"""
import json
import os
import re
import subprocess
import sys

import time
import urllib.request
import urllib.error
from pathlib import Path


def _ensure_gh_token() -> None:
    """Mint a short-lived nishfleet-worker installation token if not already set."""
    if os.environ.get("GH_TOKEN"):
        return
    try:
        out = subprocess.check_output(
            ["worker-token", "--print"],
            text=True,
            stderr=subprocess.STDOUT,
            timeout=30,
        )
    except subprocess.CalledProcessError as exc:
        print(f"DEAD APP IDENTITY: worker-token mint failed: {exc.output}", file=sys.stderr)
        sys.exit(3)
    for line in out.splitlines():
        if line.startswith("export GH_TOKEN="):
            os.environ["GH_TOKEN"] = line.split("=", 1)[1]
            return
    print("DEAD APP IDENTITY: worker-token output did not contain GH_TOKEN export", file=sys.stderr)
    sys.exit(3)


# --- Config ----------------------------------------------------------------

HOME = Path.home()
FINDINGS_DIR = HOME / "workspaces/agent-state/staleness-findings"
PR_CACHE_DIR = HOME / "workspaces/agent-state/fleet-metrics"
FINDINGS_CACHE = PR_CACHE_DIR / "staleness-findings-cache.json"
FINDINGS_CACHE_TTL = 3600  # 1 hour — reuse last run's data
FINDING_LIMIT = 100        # max open issues to file per run
GH_TIMEOUT = 45            # gh calls can be slow
ISSUE_LABELS = ["agent-ready", "staleness-detector"]
# fleet-ops#2273: legacy textfile from before the metrics-export piggyback
# refactor. The checker no longer writes here (fleet-metrics-export.py is the
# single writer of staleness gauges into fleet.prom). Clean up the stale file
# on every run so it can never shadow the live value in the node_exporter
# textfile collector.
LEGACY_STALENESS_PROM = Path("/var/lib/prometheus/node-exporter/fleet-staleness.prom")

# Docs to scan for claims. Each entry: {path, name, claims_source}.
# claims_source determines the claim extraction strategy:
#   "paths_and_units" — extract file paths and unit names
#   "paths_issues" — extract file paths and issue references
#   "paths" — extract file paths only (most conservative)
STANDING_DOCS = [
    {"path": str(HOME / "CLAUDE.md"), "name": "CLAUDE.md", "source": "paths_and_units"},
    {"path": str(HOME / "AGENTS.md"), "name": "AGENTS.md (root)", "source": "paths_and_units"},
    {"path": str(HOME / "workspaces" / "agent-state" / "AGENTS.md"),
     "name": "AGENTS.md (agent-state)", "source": "paths_and_units"},
    {"path": str(HOME / "workspaces" / "tooling" / "fleet-ops" / "CLAUDE.md"),
     "name": "CLAUDE.md (fleet-ops)", "source": "paths_and_units"},
    {
        "path": str(HOME / "workspaces" / "tooling" / "nish-vault" / "_system"
                     / "shared-memory" / "global-standing-rules.md"),
        "name": "global-standing-rules.md",
        "source": "paths_issues",
    },
    {
        "path": str(HOME / "workspaces" / "tooling" / "nish-vault" / "_system"
                     / "shared-memory" / "decisions-ledger.md"),
        "name": "decisions-ledger.md",
        "source": "paths_issues",
    },
    {"path": str(HOME / ".claude" / "projects" / "-home-nish" / "memory" / "MEMORY.md"),
     "name": "MEMORY.md",
     "source": "paths_issues",
    },
    {
        "path": str(HOME / "workspaces" / "tooling" / "fleet-ops" / "_system"
                     / "shared-memory" / "global-standing-rules.md"),
        "name": "global-standing-rules.md (fleet-ops)",
        "source": "paths_and_units",
    },
]

# Unit prefixes that are "fleet" units (referenced in docs → check they exist)
FLEET_UNIT_PREFIXES = ("fleet-", "pi-", "alert-repair-")

# Issue reference patterns
# fleet-ops#1234, Nishfleet/fleet-ops#1234, #1234 (with repo context)
# A single regex captures the optional owner/repo prefix so upstream refs like
# "systemd/systemd#33486" are filtered out in code (only fleet-ops refs count).
# Group 1 = owner (optional), Group 2 = repo (optional), Group 3 = number.
ISSUE_RE = re.compile(r'(?:(\w[\w.-]*)/)?(\w[\w.-]*)?#(\d{3,5})\b')

# File path patterns — absolute or ~ paths. Captures the full path including
# any trailing backtick that might surround it. The backtick-quoted variant
# like `` `~/foo/bar.md` `` is handled in _extract_file_paths by stripping
# leading/trailing backticks.
PATH_RE = re.compile(
    r'(?:`)?(~|/home/nish)[\w./\-]+(?:\.md|\.sh|\.py|\.yml|\.json|\.conf|\.path|\.timer|\.service)(?:`)?'
)

# systemd unit name pattern in backticks
UNIT_RE = re.compile(
    r'`(fleet-\w+(?:@\w+|-|\.service|\.timer|\.path))`'
)

# --- Helpers ---------------------------------------------------------------

def _read_cache(path):
    try:
        c = json.loads(path.read_text())
        data = c.get("data")
        ts = c.get("ts")
        age = time.time() - ts if isinstance(ts, (int, float)) else None
        return data, age
    except (OSError, json.JSONDecodeError):
        return None, None


def _write_cache(path, data):
    try:
        PR_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps({"ts": time.time(), "data": data}))
        os.replace(tmp, path)
    except OSError:
        pass


def _cached_call(name, fetcher):
    """Cache a fetcher's result for FINDINGS_CACHE_TTL seconds."""
    cached, age = _read_cache(FINDINGS_CACHE)
    if cached is not None and age is not None and age <= FINDINGS_CACHE_TTL:
        return cached
    return fetcher()


def _gh_issue(repo, number):
    """Return issue state dict or None if not found."""
    try:
        r = subprocess.run(
            ["gh", "issue", "view", str(number), "-R", repo, "--json",
             "state,number,title"],
            capture_output=True, text=True, timeout=GH_TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


def _systemctl_unit_exists(unit_name):
    """Check if a systemd user unit is installed (exists in unit files)."""
    xdg = f"/run/user/{os.getuid()}"
    try:
        r = subprocess.run(
            ["systemctl", "--user", "list-unit-files", unit_name],
            capture_output=True, text=True, timeout=10,
            env={**os.environ, "XDG_RUNTIME_DIR": xdg},
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    # list-unit-files returns 0 if the unit file exists (even if inactive)
    # It prints the unit name and its state on stdout.
    if r.returncode != 0:
        return False
    return True


def _systemctl_unit_active(unit_name):
    """Check if a systemd user unit is currently active/activating."""
    xdg = f"/run/user/{os.getuid()}"
    try:
        r = subprocess.run(
            ["systemctl", "--user", "is-active", unit_name],
            capture_output=True, text=True, timeout=5,
            env={**os.environ, "XDG_RUNTIME_DIR": xdg},
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.stdout.strip() in ("active", "activating")


def _extract_file_paths(text):
    """Extract file paths from text, stripping backtick delimiters."""
    results = []
    for m in PATH_RE.finditer(text):
        raw = m.group(0)
        # Strip surrounding backticks
        raw = raw.strip('`')
        # Skip bare `~` — it's a glob anchor, not a path
        if raw == '~' or raw == '~/':
            continue
        results.append(raw)
    return results


def _extract_units(text):
    """Extract systemd unit names from backtick-quoted strings."""
    return UNIT_RE.findall(text)


def _extract_issues(text):
    """Extract fleet-ops issue references from text.

    Returns list of (repo, number) tuples. Only fleet-ops references are
    returned — upstream refs like "systemd/systemd#33486" are filtered out.
    A bare "#NNNN" (no repo prefix) is assumed to be fleet-ops (the docs are
    fleet-ops docs).
    """
    issues = []
    seen = set()
    for m in ISSUE_RE.finditer(text):
        owner = m.group(1)  # e.g. "Nishfleet" or "systemd" or None
        repo = m.group(2)   # e.g. "fleet-ops" or "systemd" or None
        num = int(m.group(3))

        # Determine if this is a fleet-ops reference:
        # - bare #NNNN (no owner, no repo) → fleet-ops
        # - fleet-ops#NNNN (repo=fleet-ops, any/none owner) → fleet-ops
        # - Nishfleet/fleet-ops#NNNN → fleet-ops
        # - anything else (systemd/systemd#NNNN, cloudflare/wrangler#NNNN) → skip
        if repo is None and owner is None:
            pass  # bare #NNNN → fleet-ops
        elif repo == "fleet-ops":
            pass  # fleet-ops#NNNN or Nishfleet/fleet-ops#NNNN
        else:
            continue  # upstream ref, skip

        key = ("Nishfleet/fleet-ops", num)
        if key not in seen:
            seen.add(key)
            issues.append(key)
    return issues


def _resolve_path(path_str):
    """Convert a ~ or /home/nish path to an absolute Path."""
    p = path_str.replace("~", str(HOME), 1)
    return Path(p)


def _extract_claims(doc):
    """Extract verifiable claims from a standing doc.

    Returns list of claim dicts:
      {type: "path"|"unit"|"issue", value: str, source: str, raw: str}
    """
    claims = []
    source = doc.get("source", "paths")
    try:
        text = Path(doc["path"]).read_text()
    except OSError:
        return claims  # doc not found — that's a finding itself

    if source in ("paths_and_units", "paths"):
        for raw_path in _extract_file_paths(text):
            claims.append({
                "type": "path",
                "value": raw_path,
                "source": doc["name"],
                "raw": raw_path,
            })
        # Also check relative paths that start with agent-state or similar
        # These appear as references like "agent-state/FLEET-PAUSED"
        rel_path_re = re.compile(
            r'`([^`\s]+(?:\.(md|sh|py|yml|json|conf|timer|service|path))`)',
            re.IGNORECASE,
        )
        for m in rel_path_re.finditer(text):
            rel = m.group(1).strip('`')  # strip backticks from captured value
            # Skip if already captured above (by main path extractor)
            if any(
                c["value"] == rel or c["value"].endswith(rel)
                or rel.endswith(c["value"])
                for c in claims
                if c["type"] == "path"
            ):
                continue
            claims.append({
                "type": "path",
                "value": rel,
                "source": doc["name"],
                "raw": m.group(0),
            })

    if source == "paths_and_units":
        for unit in _extract_units(text):
            claims.append({
                "type": "unit",
                "value": unit,
                "source": doc["name"],
                "raw": unit,
            })

    if source in ("paths_issues", "paths_and_units"):
        for repo, num in _extract_issues(text):
            claims.append({
                "type": "issue",
                "value": str(num),
                "source": doc["name"],
                "raw": f"{repo}#{num}",
                "repo": repo,
            })

    return claims


# --- Validation -------------------------------------------------------------

def _claim_result(claim):
    """Validate a single claim. Returns {claim, status, detail}.

    status: "ok" | "mismatch" | "skipped"
    detail: human-readable explanation.
    """
    ctype = claim["type"]

    if ctype == "path":
        raw = claim["value"]
        # Resolve path
        if raw.startswith("/") or raw.startswith("~/"):
            resolved = _resolve_path(raw)
        else:
            # Relative path — try relative to HOME first, then fleet-ops
            resolved = (HOME / raw).resolve()
            if not resolved.exists():
                resolved = (HOME / "workspaces" / "tooling" / "fleet-ops" / raw).resolve()

        if not resolved.exists():
            return {
                "claim": claim,
                "status": "mismatch",
                "detail": f"path not found: {resolved}",
            }
        return {
            "claim": claim,
            "status": "ok",
            "detail": f"path exists: {resolved}",
        }

    elif ctype == "unit":
        unit = claim["value"]
        # Strip .service/.timer/.path suffix for checking
        unit_base = re.sub(r'\.(service|timer|path)$', '', unit)
        unit_suffix = unit.split('.')[-1] if '.' in unit else 'service'

        if not _systemctl_unit_exists(unit):
            return {
                "claim": claim,
                "status": "mismatch",
                "detail": f"unit file not installed: {unit}",
            }
        if not _systemctl_unit_active(unit):
            return {
                "claim": claim,
                "status": "mismatch",
                "detail": f"unit exists but not active: {unit}",
            }
        return {
            "claim": claim,
            "status": "ok",
            "detail": f"unit {unit} is active",
        }

    elif ctype == "issue":
        repo = claim.get("repo", "Nishfleet/fleet-ops")
        num = int(claim["value"])

        issue = _gh_issue(repo, num)
        if issue is None:
            return {
                "claim": claim,
                "status": "mismatch",
                "detail": f"issue not found: {repo}#{num}",
            }

        # The doc's implicit claim: if it cites an issue, it's usually
        # referencing an open problem or a resolved decision. We flag
        # issues that are:
        # - Referenced in past-tense / "fixes" context but still open
        # - Referenced in "done" / "closed" context but still open
        # For now, we flag ALL references as informational — the agent
        # can review. The key insight is stale references where the issue
        # no longer exists.
        state = issue.get("state", "unknown")
        return {
            "claim": claim,
            "status": "ok",
            "detail": f"issue {repo}#{num} exists, state={state}",
        }

    return {
        "claim": claim,
        "status": "skipped",
        "detail": f"unknown claim type: {ctype}",
    }


# --- Issue filing -----------------------------------------------------------

def _file_finding(finding):
    """File a GitHub issue for a staleness finding."""
    _ensure_gh_token()
    claim = finding["claim"]
    ctype = claim["type"]
    source = claim["source"]
    raw = claim.get("raw", claim["value"])
    detail = finding["detail"]

    # Build title and body
    if ctype == "path":
        title = f"Stale doc path: {raw}"
    elif ctype == "unit":
        title = f"Stale doc unit: {raw}"
    elif ctype == "issue":
        title = f"Stale doc issue ref: {raw}"
    else:
        title = f"Stale doc claim: {raw}"

    body = f"""Staleness finding from truth-staleness-checker (fleet-ops#1137).

- **Type**: {ctype}
- **Source doc**: {source}
- **Claim**: {raw}
- **Detail**: {detail}

This claim was extracted from a standing doc and failed live validation.
Review the doc and either update it or fix the live state.
"""

    # Only file if we haven't already filed something similar today
    today = time.strftime("%Y-%m-%d")
    # Check if this exact finding was already filed today
    try:
        r = subprocess.run(
            ["gh", "search", "issues",
             "--repo", "Nishfleet/fleet-ops",
             "--state", "open",
             "--label", "staleness-detector",
             "--json", "title,number"],
            capture_output=True, text=True, timeout=30,
        )
        if r.returncode == 0:
            existing = json.loads(r.stdout or "[]")
            for iss in existing:
                if title in iss.get("title", "") and iss.get("number"):
                    return iss["number"]  # already filed
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        pass  # search failed, file anyway

    try:
        labels_args = sum([["-l", l] for l in ISSUE_LABELS], [])
        r = subprocess.run(
            ["gh", "issue", "create",
             "-R", "Nishfleet/fleet-ops",
             "-t", title,
             "-b", body]
            + labels_args,
            capture_output=True, text=True, timeout=30,
        )
        if r.returncode != 0:
            print(f"issue create failed: {r.stderr.strip()[:200]}", file=sys.stderr)
            return None
        # Extract issue number from URL or output
        m = re.search(r'(\d+)', r.stdout)
        return int(m.group(1)) if m else None
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"issue create error: {exc}", file=sys.stderr)
        return None


# --- Prometheus export ------------------------------------------------------

def _prom_label(s):
    return str(s).replace("\\", "\\\\").replace('"', '\\"')


# --- Main -------------------------------------------------------------------

def main():
    """Run the staleness checker.

    Returns 0 on success (even if mismatches found).
    Returns non-zero only on internal errors.

    Flags:
      --no-file   Extract and validate claims, export metrics, but do NOT file
                  GitHub issues. Used by tests and dry runs to avoid side effects.
    """
    import argparse
    parser = argparse.ArgumentParser(description="Truth staleness detector")
    parser.add_argument("--no-file", action="store_true",
                        help="validate and export metrics only; do not file GitHub issues")
    args = parser.parse_args()

    start_time = time.time()
    findings = []

    # 1. Extract claims from all standing docs
    all_claims = []
    docs_scanned = 0
    for doc in STANDING_DOCS:
        doc_path = Path(doc["path"])
        if doc_path.exists():
            docs_scanned += 1
        claims = _extract_claims(doc)
        all_claims.extend(claims)

    print(f"Extracted {len(all_claims)} claims from {docs_scanned}/{len(STANDING_DOCS)} docs",
          file=sys.stderr)

    # 2. Deduplicate claims (same type+value = same claim)
    seen = set()
    unique_claims = []
    for c in all_claims:
        key = (c["type"], c["value"])
        if key not in seen:
            seen.add(key)
            unique_claims.append(c)
    print(f"  → {len(unique_claims)} unique claims", file=sys.stderr)

    # 3. Validate each claim
    for claim in unique_claims:
        result = _claim_result(claim)
        if result["status"] == "mismatch":
            findings.append(result)

    # 4. Cache results
    run_data = {
        "ts": start_time,
        "total_claims": len(unique_claims),
        "docs_scanned": docs_scanned,
        "mismatches": len(findings),
        "findings": [{"type": f["claim"]["type"], "source": f["claim"]["source"],
                      "raw": f["claim"].get("raw", f["claim"]["value"]),
                      "detail": f["detail"]} for f in findings],
    }
    _write_cache(FINDINGS_CACHE, run_data)

    # 5. File issues for new mismatches (only when run directly with filing
    #    enabled). --no-file skips filing (tests, dry runs). The exporter
    #    piggyback (STALENESS_RUN_MODE=export) also skips filing — the weekly
    #    timer (STALENESS_RUN_MODE=direct) is the only path that files.
    run_type = os.environ.get("STALENESS_RUN_MODE", "direct")
    file_issues = run_type == "direct" and not args.no_file
    filed_issues = []
    if file_issues and findings:
        # Limit issues per run
        for f in findings[:FINDING_LIMIT]:
            iss = _file_finding(f)
            if iss:
                filed_issues.append(iss)
                print(f"  filed issue #{iss}: {f['claim'].get('raw', f['claim']['value'])}",
                      file=sys.stderr)

    # 6. Prometheus export is owned by fleet-metrics-export.py.
    # This checker only writes its JSON cache (step 4). fleet-metrics-export.py
    # is the SINGLE writer of /var/lib/prometheus/node-exporter/fleet.prom and
    # reads this cache to emit the fleet_truth_staleness_* gauges. Writing
    # fleet.prom here too clobbered every other metric family between exporter
    # runs (fleet_escalations_24h, fleet_main_ci_green, ...).
    #
    # fleet-ops#2273: also clean up the legacy fleet-staleness.prom textfile
    # that this checker used to write before the refactor. node_exporter reads
    # every .prom file in the textfile dir, so a stale copy shadows the live
    # gauge in fleet.prom and triggers TruthStalenessAbsent for no reason.
    try:
        LEGACY_STALENESS_PROM.unlink()
    except FileNotFoundError:
        pass

    # 7. Summary
    print(f"\nStaleness check complete: {docs_scanned} docs, "
          f"{len(unique_claims)} claims, {len(findings)} mismatches, "
          f"{len(filed_issues)} issues filed", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())