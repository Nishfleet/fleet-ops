#!/usr/bin/env python3
"""Scout effectiveness metrics (fleet-ops#2756).

Measures whether pi-scout@0509 produces mergeable product work, not just
green runs. The existing scout-futility-check (fleet-ops#454/#2468) detects
green-and-empty + provider-wall futility; this module quantifies the
per-issue pipeline: filed -> survive intake dedup -> agent-ready -> merged.

Metric family (trailing 14d window unless noted):

  fleet_scout_runs_total{repo="0509"}
  fleet_scout_issues_filed{repo="0509"}
  fleet_scout_issues_survive_intake{repo="0509"}
  fleet_scout_issues_agent_ready{repo="0509"}
  fleet_scout_issues_claimed{repo="0509"}
  fleet_scout_issues_merged_14d{repo="0509"}
  fleet_scout_effectiveness_ratio{repo="0509"}   merged_14d / runs
  fleet_scout_effectiveness_last_run_seconds     heartbeat (always)

Pipeline attribution (issue accept §1):
  filed           scout-candidate issue created inside the window
  survive_intake  NOT closed as duplicate within 1h of creation
  agent_ready     carries (or carried) the agent-ready label
  claimed         carries (or carried) the agent-in-progress label —
                  the claim gate between agent-ready and merged; GitHub
                  labels are sticky across close, so a claimed-then-
                  merged issue still carries agent-in-progress and counts
                  (fleet-ops#3123)
  merged_14d      a merged PR referencing the issue landed within 14d
                  of the issue's creation

Sources:
  - Prometheus query_range for fleet_scout_last_run_seconds (each value
    change = one actual scout run where ExecCondition passed; written by
    scout-futility-check ExecStartPre begin, fleet-ops#1277)
  - `gh issue list` for scout-candidate issues in the product repo
  - `gh pr list --state merged` for PR bodies referencing issue numbers

Piggybacks fleet-metrics-export.service via
systemd/fleet-metrics-export.service.d/scout-effectiveness.conf — no new
timer. Always exits 0 so a fault cannot fail Prometheus export.

Environment seams (tests):
  FLEET_SCOUT_EFF_OUT, FLEET_SCOUT_EFF_NOW, FLEET_SCOUT_EFF_FIXTURE,
  FLEET_SCOUT_EFF_PROM_URL, FLEET_SCOUT_EFF_GH,
  FLEET_SCOUT_EFF_WINDOW_DAYS, FLEET_SCOUT_EFF_REPO,
  FLEET_SCOUT_EFF_DUPE_HOURS, FLEET_SCOUT_EFF_READY_HOURS,
  FLEET_SCOUT_EFF_MERGE_DAYS, XDG_RUNTIME_DIR, HOME
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

HOME = os.environ.get("HOME", "/home/nish")
OUT = Path(
    os.environ.get(
        "FLEET_SCOUT_EFF_OUT",
        "/var/lib/prometheus/node-exporter/fleet-scout-effectiveness.prom",
    )
)
PROM_URL = os.environ.get(
    "FLEET_SCOUT_EFF_PROM_URL", "http://127.0.0.1:9090"
).rstrip("/")
GH = os.environ.get("FLEET_SCOUT_EFF_GH", "gh")
FIXTURE = os.environ.get("FLEET_SCOUT_EFF_FIXTURE", "")
NOW_ISO = os.environ.get("FLEET_SCOUT_EFF_NOW", "")
WINDOW_DAYS = int(os.environ.get("FLEET_SCOUT_EFF_WINDOW_DAYS", "14"))
REPO = os.environ.get("FLEET_SCOUT_EFF_REPO", "0509")
DUPE_HOURS = float(os.environ.get("FLEET_SCOUT_EFF_DUPE_HOURS", "1"))
READY_HOURS = float(os.environ.get("FLEET_SCOUT_EFF_READY_HOURS", "24"))
MERGE_DAYS = int(os.environ.get("FLEET_SCOUT_EFF_MERGE_DAYS", "14"))
PROM_TIMEOUT = 20
GH_TIMEOUT = 30

HELP_RUNS = (
    "# HELP fleet_scout_runs_total Actual pi-scout executions (ExecCondition "
    "passed) observed in the trailing effectiveness window, per repo "
    "(fleet-ops#2756)."
)
TYPE_RUNS = "# TYPE fleet_scout_runs_total gauge"
HELP_FILED = (
    "# HELP fleet_scout_issues_filed Scout-candidate issues created inside "
    "the trailing effectiveness window, per repo (fleet-ops#2756)."
)
TYPE_FILED = "# TYPE fleet_scout_issues_filed gauge"
HELP_SURVIVE = (
    "# HELP fleet_scout_issues_survive_intake Filed scout issues NOT closed "
    "as duplicate within the intake dedup window, per repo (fleet-ops#2756)."
)
TYPE_SURVIVE = "# TYPE fleet_scout_issues_survive_intake gauge"
HELP_READY = (
    "# HELP fleet_scout_issues_agent_ready Filed scout issues that carry the "
    "agent-ready label (promoted to actionable), per repo (fleet-ops#2756)."
)
TYPE_READY = "# TYPE fleet_scout_issues_agent_ready gauge"
HELP_CLAIMED = (
    "# HELP fleet_scout_issues_claimed Filed scout issues that carry the "
    "agent-in-progress label (claimed by a worker), per repo. GitHub labels "
    "survive close, so merged claims stay counted (fleet-ops#3123)."
)
TYPE_CLAIMED = "# TYPE fleet_scout_issues_claimed gauge"
HELP_MERGED = (
    "# HELP fleet_scout_issues_merged_14d Filed scout issues whose closing "
    "PR merged within the merge window of the issue creation, per repo "
    "(fleet-ops#2756)."
)
TYPE_MERGED = "# TYPE fleet_scout_issues_merged_14d gauge"
HELP_RATIO = (
    "# HELP fleet_scout_effectiveness_ratio merged_14d / runs over the "
    "trailing window, per repo. 0 when no runs. (fleet-ops#2756)."
)
TYPE_RATIO = "# TYPE fleet_scout_effectiveness_ratio gauge"
HELP_HB = (
    "# HELP fleet_scout_effectiveness_last_run_seconds Epoch of the last "
    "scout-effectiveness export tick (organ heartbeat, fleet-ops#2756)."
)
TYPE_HB = "# TYPE fleet_scout_effectiveness_last_run_seconds gauge"


@dataclass(frozen=True)
class ScoutIssue:
    number: int
    repo: str
    created_ts: float
    labels: tuple[str, ...] = ()
    state: str = "open"  # open / closed
    state_reason: str = ""  # completed / duplicate / not_planned
    closed_ts: float | None = None
    merged_ts: float | None = None  # closing-PR merge time, if any


@dataclass
class RepoStats:
    repo: str
    runs: int = 0
    filed: int = 0
    survive_intake: int = 0
    agent_ready: int = 0
    claimed: int = 0
    merged_14d: int = 0

    @property
    def effectiveness_ratio(self) -> float:
        if self.runs == 0:
            return 0.0
        return self.merged_14d / self.runs


# --- helpers ---------------------------------------------------------------


def prom_label(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    s = s.strip()
    if not s:
        return None
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def now_dt() -> datetime:
    if NOW_ISO:
        dt = parse_iso(NOW_ISO)
        if dt is not None:
            return dt
    return datetime.now(timezone.utc)


def _http_json(base: str, path: str, params: dict[str, str]) -> dict[str, Any]:
    url = base + path + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=PROM_TIMEOUT) as resp:  # nosemgrep
        return json.loads(resp.read().decode())


def _query_range(
    query: str,
    start: float,
    end: float,
    step: int = 300,
) -> list[tuple[float, float]]:
    """Return [(ts, value), ...] for the first matching series."""
    try:
        payload = _http_json(
            PROM_URL,
            "/api/v1/query_range",
            {
                "query": query,
                "start": str(start),
                "end": str(end),
                "step": str(step),
            },
        )
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, json.JSONDecodeError) as exc:
        print(f"scout-effectiveness: query_range failed: {exc}", file=sys.stderr)
        return []
    if payload.get("status") != "success":
        return []
    result = (payload.get("data") or {}).get("result") or []
    if not result:
        return []
    values = result[0].get("values") or []
    out: list[tuple[float, float]] = []
    for ts, val in values:
        try:
            out.append((float(ts), float(val)))
        except (TypeError, ValueError):
            continue
    return out


def count_runs_from_prometheus(repo: str, start: float, end: float) -> int:
    """Count actual scout runs as value changes of fleet_scout_last_run_seconds.

    scout-futility-check writes this gauge on ExecStartPre begin (only when
    ExecCondition passed), so each value change is one real run. A leading
    non-zero sample counts as one run (the run that produced it).
    """
    pts = _query_range(
        f'fleet_scout_last_run_seconds{{repo="{repo}"}}', start, end
    )
    if not pts:
        return 0
    runs = 0
    prev: float | None = None
    for _ts, val in pts:
        if val <= 0:
            prev = val
            continue
        if prev is None or val != prev:
            runs += 1
        prev = val
    return runs


# --- gh issue / pr collection ---------------------------------------------


def _gh_json(args: list[str]) -> Any:
    env = os.environ.copy()
    env.setdefault("HOME", HOME)
    try:
        proc = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT,
            env=env,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"scout-effectiveness: gh failed: {exc}", file=sys.stderr)
        return None
    if proc.returncode != 0:
        print(
            f"scout-effectiveness: gh rc={proc.returncode}: "
            f"{proc.stderr.strip()[:200]}",
            file=sys.stderr,
        )
        return None
    try:
        return json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        return None


_REF_RE = re.compile(r"(?:clos(?:e[sd]?|ing)|fix(?:e[sd]?|ing)|resolv(?:e[sd]?|ing))\s+#(\d+)", re.I)


def _issue_refs_in_body(body: str) -> set[int]:
    return {int(m) for m in _REF_RE.findall(body or "")}


def load_issues_gh(repo_full: str, label: str) -> list[ScoutIssue]:
    rows = _gh_json(
        [
            GH,
            "issue",
            "list",
            "-R",
            repo_full,
            "--state",
            "all",
            "--label",
            label,
            "--limit",
            "200",
            "--json",
            "number,createdAt,labels,state,stateReason,closedAt",
        ]
    )
    if not isinstance(rows, list):
        return []
    issues: list[ScoutIssue] = []
    for row in rows:
        created = parse_iso(row.get("createdAt"))
        if created is None:
            continue
        closed = parse_iso(row.get("closedAt"))
        labels = tuple(
            (lab.get("name") if isinstance(lab, dict) else str(lab))
            for lab in (row.get("labels") or [])
        )
        issues.append(
            ScoutIssue(
                number=int(row.get("number") or 0),
                repo=repo_full,
                created_ts=created.timestamp(),
                labels=labels,
                state=str(row.get("state") or "open"),
                state_reason=str(row.get("stateReason") or ""),
                closed_ts=closed.timestamp() if closed else None,
            )
        )
    return issues


def load_merges_gh(repo_full: str) -> dict[int, float]:
    """Return {issue_number: merged_ts} from merged PRs that close issues."""
    rows = _gh_json(
        [
            GH,
            "pr",
            "list",
            "-R",
            repo_full,
            "--state",
            "merged",
            "--limit",
            "200",
            "--json",
            "number,body,mergedAt",
        ]
    )
    if not isinstance(rows, list):
        return {}
    out: dict[int, float] = {}
    for row in rows:
        merged = parse_iso(row.get("mergedAt"))
        if merged is None:
            continue
        for num in _issue_refs_in_body(str(row.get("body") or "")):
            # Earliest merge wins if multiple PRs reference the same issue.
            ts = merged.timestamp()
            if num not in out or ts < out[num]:
                out[num] = ts
    return out


# --- fixture ---------------------------------------------------------------


def load_fixture(path: str) -> tuple[list[float], list[ScoutIssue]]:
    """Offline fixture: {runs:[ts,...], issues:[{number,repo,created_ts,
    labels,state,state_reason,closed_ts,merged_ts}]}."""
    data = json.loads(Path(path).read_text())
    runs = [float(r) for r in (data.get("runs") or [])]
    issues: list[ScoutIssue] = []
    for row in (data.get("issues") or []):
        issues.append(
            ScoutIssue(
                number=int(row.get("number") or 0),
                repo=str(row.get("repo") or REPO),
                created_ts=float(row.get("created_ts") or 0),
                labels=tuple(row.get("labels") or ()),
                state=str(row.get("state") or "open"),
                state_reason=str(row.get("state_reason") or ""),
                closed_ts=float(row["closed_ts"]) if row.get("closed_ts") is not None else None,
                merged_ts=float(row["merged_ts"]) if row.get("merged_ts") is not None else None,
            )
        )
    return runs, issues


# --- compute ---------------------------------------------------------------


def compute_stats(
    repo: str,
    runs: list[float],
    issues: list[ScoutIssue],
    *,
    start_ts: float,
    end_ts: float,
    dupe_hours: float = DUPE_HOURS,
    merge_days: int = MERGE_DAYS,
) -> RepoStats:
    s = RepoStats(repo=repo)
    dupe_window = dupe_hours * 3600.0
    merge_window = merge_days * 86400.0
    for r in runs:
        if start_ts <= r <= end_ts:
            s.runs += 1
    for iss in issues:
        if iss.repo != repo and not iss.repo.endswith("/" + repo):
            continue
        if not (start_ts <= iss.created_ts <= end_ts):
            continue
        s.filed += 1
        # survive_intake: not closed as duplicate within the dupe window
        closed_as_dupe_quick = (
            iss.state_reason.lower() == "duplicate"
            and iss.closed_ts is not None
            and (iss.closed_ts - iss.created_ts) <= dupe_window
        )
        if not closed_as_dupe_quick:
            s.survive_intake += 1
        # agent_ready: carries the agent-ready label
        if "agent-ready" in iss.labels:
            s.agent_ready += 1
        # claimed: carries the agent-in-progress label (claim gate between
        # agent-ready and merged). GitHub labels are sticky across close, so a
        # claimed-then-merged issue still counts — claimed is "handled by a
        # worker", not "currently in flight" (fleet-ops#3123).
        if "agent-in-progress" in iss.labels:
            s.claimed += 1
        # merged_14d: closing PR merged within merge window of creation
        if iss.merged_ts is not None:
            if 0 <= (iss.merged_ts - iss.created_ts) <= merge_window:
                s.merged_14d += 1
    return s


# --- export ----------------------------------------------------------------


def export_prom(stats: list[RepoStats], *, now: datetime) -> str:
    lines: list[str] = [HELP_RUNS, TYPE_RUNS]
    for s in stats:
        lines.append(
            f'fleet_scout_runs_total{{repo="{prom_label(s.repo)}"}} {s.runs}'
        )
    lines += ["", HELP_FILED, TYPE_FILED]
    for s in stats:
        lines.append(
            f'fleet_scout_issues_filed{{repo="{prom_label(s.repo)}"}} {s.filed}'
        )
    lines += ["", HELP_SURVIVE, TYPE_SURVIVE]
    for s in stats:
        lines.append(
            f'fleet_scout_issues_survive_intake{{repo="{prom_label(s.repo)}"}} '
            f"{s.survive_intake}"
        )
    lines += ["", HELP_READY, TYPE_READY]
    for s in stats:
        lines.append(
            f'fleet_scout_issues_agent_ready{{repo="{prom_label(s.repo)}"}} '
            f"{s.agent_ready}"
        )
    lines += ["", HELP_CLAIMED, TYPE_CLAIMED]
    for s in stats:
        lines.append(
            f'fleet_scout_issues_claimed{{repo="{prom_label(s.repo)}"}} '
            f"{s.claimed}"
        )
    lines += ["", HELP_MERGED, TYPE_MERGED]
    for s in stats:
        lines.append(
            f'fleet_scout_issues_merged_14d{{repo="{prom_label(s.repo)}"}} '
            f"{s.merged_14d}"
        )
    lines += ["", HELP_RATIO, TYPE_RATIO]
    for s in stats:
        lines.append(
            f'fleet_scout_effectiveness_ratio{{repo="{prom_label(s.repo)}"}} '
            f"{s.effectiveness_ratio:.6f}"
        )
    lines += [
        "",
        HELP_HB,
        TYPE_HB,
        f"fleet_scout_effectiveness_last_run_seconds {int(now.timestamp())}",
        "",
    ]
    body = "\n".join(lines)
    _atomic_write(OUT, body)
    return body


def _atomic_write(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(body)
            if not body.endswith("\n"):
                fh.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def usage() -> int:
    print(
        "usage: scout-effectiveness.py [--stdout] [--help]\n"
        "  Computes scout effectiveness metrics and writes\n"
        f"  {OUT} (override with FLEET_SCOUT_EFF_OUT).\n"
        "  Offline fixture: FLEET_SCOUT_EFF_FIXTURE=/path/to.json",
        file=sys.stderr,
    )
    return 2


def main(argv: list[str] | None = None) -> int:
    argv = list(argv if argv is not None else sys.argv[1:])
    to_stdout = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            return usage()
        if a == "--stdout":
            to_stdout = True
            i += 1
            continue
        print(f"scout-effectiveness: unknown flag {a}", file=sys.stderr)
        return usage()

    end = now_dt()
    start = end - timedelta(days=WINDOW_DAYS)
    try:
        if FIXTURE:
            runs, issues = load_fixture(FIXTURE)
        else:
            repo_full = f"Nishfleet/{REPO}"
            runs_count = count_runs_from_prometheus(
                REPO, start.timestamp(), end.timestamp()
            )
            runs = []
            if runs_count:
                # Spread run timestamps evenly across the window so the
                # count is faithful; the exact per-run timestamp is not
                # needed for the aggregate metrics (only the count is).
                span = end.timestamp() - start.timestamp()
                step = span / runs_count if runs_count else 0
                for k in range(runs_count):
                    runs.append(start.timestamp() + step * (k + 0.5))
            issues = load_issues_gh(repo_full, "scout-candidate")
            merges = load_merges_gh(repo_full)
            issues = [
                ScoutIssue(
                    number=iss.number,
                    repo=iss.repo,
                    created_ts=iss.created_ts,
                    labels=iss.labels,
                    state=iss.state,
                    state_reason=iss.state_reason,
                    closed_ts=iss.closed_ts,
                    merged_ts=merges.get(iss.number, iss.merged_ts),
                )
                for iss in issues
            ]
        stats = [
            compute_stats(
                REPO,
                runs,
                issues,
                start_ts=start.timestamp(),
                end_ts=end.timestamp(),
            )
        ]
        body = export_prom(stats, now=end)
        if to_stdout:
            sys.stdout.write(body if body.endswith("\n") else body + "\n")
        print(
            f"scout-effectiveness: wrote {OUT} "
            f"(repo={REPO}, runs={stats[0].runs}, "
            f"filed={stats[0].filed}, survive={stats[0].survive_intake}, "
            f"agent_ready={stats[0].agent_ready}, "
            f"claimed={stats[0].claimed}, "
            f"merged_14d={stats[0].merged_14d}, "
            f"ratio={stats[0].effectiveness_ratio:.4f})",
            file=sys.stderr,
        )
        return 0
    except Exception as exc:  # noqa: BLE001 — never fail the parent exporter
        print(f"scout-effectiveness failed: {exc}", file=sys.stderr)
        try:
            zeros = [RepoStats(repo=REPO)]
            export_prom(zeros, now=end)
        except Exception as write_exc:  # noqa: BLE001
            print(
                f"scout-effectiveness zero-write failed: {write_exc}",
                file=sys.stderr,
            )
        return 0


if __name__ == "__main__":
    sys.exit(main())
