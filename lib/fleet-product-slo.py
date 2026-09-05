#!/usr/bin/env python3
"""Product delivery SLO metrics (fleet-ops#2755).

Weekly product throughput, median lead time, and revert rate for product
repos enrolled in config/intake-repos.json (minus self-maintenance repos
from config/self-maintenance-repos.json). Gives Nish a mechanized view of
whether the fleet is shipping product — not only whether seats and alerts
are green.

Metric family:

  fleet_product_throughput_weekly{repo="0509"}   non-revert merges / 7d
  fleet_product_lead_time_days{repo="0509"}      median issue→merge days
                                                 (revert PRs excluded)
  fleet_product_revert_rate{repo="0509"}         reverts / merges over 28d
  fleet_product_merged_24h{repo="0509"}          non-revert merges / 24h
                                                 (single source for the
                                                 console shipped_24h tile)
  fleet_product_slo_last_run_seconds             organ heartbeat (always)

Sources:
  - config/intake-repos.json repos[] (product candidates)
  - config/self-maintenance-repos.json (control-plane exclusion)
  - gh GraphQL search of merged PRs (cached, 6h TTL)

Piggybacks fleet-metrics-export.service via
systemd/fleet-metrics-export.service.d/product-slo.conf — no new timer
(house pattern; accept §5's dedicated hourly timer is rejected as a new
organ when the 5-min exporter already runs). Always exits 0 so a fault
cannot fail Prometheus export.

Environment seams (tests):
  FLEET_PRODUCT_SLO_OUT, FLEET_PRODUCT_SLO_NOW, FLEET_PRODUCT_SLO_FIXTURE,
  FLEET_PRODUCT_SLO_GH, FLEET_PRODUCT_SLO_CACHE, FLEET_PRODUCT_SLO_TTL,
  FLEET_PRODUCT_SLO_STALE, FLEET_PRODUCT_SLO_INTAKE,
  FLEET_PRODUCT_SLO_SELF_MAINT, FLEET_PRODUCT_SLO_ORG, HOME
"""
from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

HOME = os.environ.get("HOME", "/home/nish")
AS = Path(os.environ.get("AGENT_STATE", f"{HOME}/workspaces/agent-state"))
OUT = Path(
    os.environ.get(
        "FLEET_PRODUCT_SLO_OUT",
        "/var/lib/prometheus/node-exporter/fleet-product-slo.prom",
    )
)
CACHE = Path(
    os.environ.get(
        "FLEET_PRODUCT_SLO_CACHE",
        str(AS / "fleet-metrics" / "product-slo-cache.json"),
    )
)
# fleet-ops#3519: per-repo rolling-7d quality ceilings live in
# config/quality-ratchet.json (`.ceilings`), seeded from the 2026-09-05
# baseline. The exporter re-exports the committed ceiling alongside each
# gauge so alert rules pair value vs ceiling in one expression.
_QUALITY_RATCHET_CANDIDATES = [
    os.environ.get("FLEET_QUALITY_RATCHET_JSON", ""),
    str(Path(__file__).resolve().parents[1] / "config" / "quality-ratchet.json"),
    f"{HOME}/workspaces/tooling/fleet-ops-deploy-clone/config/quality-ratchet.json",
    f"{HOME}/workspaces/tooling/fleet-ops/config/quality-ratchet.json",
    f"{HOME}/.local/share/fleet-ops/config/quality-ratchet.json",
]
# fleet-ops#3519: per-repo issue-work session dirs. Repo is encoded in the
# dir name (`pi-issue-<repo>-<N>`), so sessions_to_pr_pct is derivable on
# the host without a new data source.
SESSIONS_DIR = Path(
    os.environ.get("FLEET_PRODUCT_SLO_SESSIONS", f"{HOME}/.pi/agent/sessions")
)
FIXTURE = os.environ.get("FLEET_PRODUCT_SLO_FIXTURE", "")
NOW_ISO = os.environ.get("FLEET_PRODUCT_SLO_NOW", "")
GH = os.environ.get("FLEET_PRODUCT_SLO_GH", "gh")
ORG = os.environ.get("FLEET_PRODUCT_SLO_ORG", "Nishfleet")
TTL = int(os.environ.get("FLEET_PRODUCT_SLO_TTL", "21600"))  # 6h
STALE = int(os.environ.get("FLEET_PRODUCT_SLO_STALE", "86400"))  # 24h
GH_TIMEOUT = 60
GH_PAGES = 10

WEEK_S = 7 * 86400
MONTH_S = 28 * 86400
DAY_S = 86400

# fleet-ops#3519: the per-repo, rolling-7d quality metric names. Each is a
# "ceiling" metric — the only enforcement lever this ratchet owns. The
# rework/red-on-main/act-on rate families are deferred (separate issues:
# file-overlap data, ci-watch source, #3264 dependency) and are NOT measured
# yet, though their ceilings are seeded in quality-ratchet.json so the config
# shape stays complete.
QUALITY_METRICS = (
    "reverts_per_100_merges",
    "post_merge_defects_per_100",
    "sessions_to_pr_pct",
)

_INTAKE_CANDIDATES = [
    os.environ.get("FLEET_PRODUCT_SLO_INTAKE", ""),
    str(Path(__file__).resolve().parents[1] / "config" / "intake-repos.json"),
    f"{HOME}/workspaces/tooling/fleet-ops-deploy-clone/config/intake-repos.json",
    f"{HOME}/workspaces/tooling/fleet-ops/config/intake-repos.json",
    f"{HOME}/.local/share/fleet-ops/config/intake-repos.json",
]
_SELF_CANDIDATES = [
    os.environ.get("FLEET_PRODUCT_SLO_SELF_MAINT", ""),
    str(Path(__file__).resolve().parents[1] / "config" / "self-maintenance-repos.json"),
    f"{HOME}/workspaces/tooling/fleet-ops-deploy-clone/config/self-maintenance-repos.json",
    f"{HOME}/workspaces/tooling/fleet-ops/config/self-maintenance-repos.json",
]

HELP_TP = (
    "# HELP fleet_product_throughput_weekly Non-revert merged PRs in the "
    "trailing 7 days per product repo (fleet-ops#2755)."
)
TYPE_TP = "# TYPE fleet_product_throughput_weekly gauge"
HELP_LT = (
    "# HELP fleet_product_lead_time_days Median issue-creation → merge lead "
    "time in days for non-revert merges in the trailing 7 days per product "
    "repo. 0 when no timed merges. (fleet-ops#2755)."
)
TYPE_LT = "# TYPE fleet_product_lead_time_days gauge"
HELP_RR = (
    "# HELP fleet_product_revert_rate Revert PRs / all merged PRs over the "
    "trailing 28 days per product repo. 0 when no merges. (fleet-ops#2755)."
)
TYPE_RR = "# TYPE fleet_product_revert_rate gauge"
HELP_24 = (
    "# HELP fleet_product_merged_24h Non-revert merged PRs in the trailing "
    "24h per product repo. Single source of truth for the console "
    "shipped_24h tile (fleet-ops#2755 / #2690)."
)
TYPE_24 = "# TYPE fleet_product_merged_24h gauge"
# fleet-ops#3519: per-repo rolling-7d quality gauges + committed ceilings.
HELP_QRV = (
    "# HELP fleet_product_quality_reverts_per_100 Revert PRs per 100 merged "
    "PRs in the trailing 7 days per product repo (fleet-ops#3519)."
)
TYPE_QRV = "# TYPE fleet_product_quality_reverts_per_100 gauge"
HELP_QDF = (
    "# HELP fleet_product_quality_post_merge_defects_per_100 Merged PRs tied "
    "to an issue filed within the trailing 7 days, per 100 merged PRs "
    "(desk-triage / red-on-main / customer-facing defects), per product repo "
    "(fleet-ops#3519)."
)
TYPE_QDF = "# TYPE fleet_product_quality_post_merge_defects_per_100 gauge"
HELP_QSP = (
    "# HELP fleet_product_quality_sessions_to_pr_pct Issue-work sessions in "
    "the trailing 7 days per 100 merged PRs per product repo (fleet-ops#3519)."
)
TYPE_QSP = "# TYPE fleet_product_quality_sessions_to_pr_pct gauge"
HELP_QCEIL = (
    "# HELP fleet_product_quality_ceiling Committed quality ceiling per repo "
    "per metric from config/quality-ratchet.json (fleet-ops#3519). "
    "Alert rules pair the gauge above against this by (repo, metric)."
)
TYPE_QCEIL = "# TYPE fleet_product_quality_ceiling gauge"
HELP_HB = (
    "# HELP fleet_product_slo_last_run_seconds Epoch of the last "
    "product-slo export tick (organ heartbeat, fleet-ops#2755)."
)
TYPE_HB = "# TYPE fleet_product_slo_last_run_seconds gauge"

# closingIssuesReferences on the PR; GraphQL search PullRequest fragment.
MERGED_SEARCH = """
query($cursor: String) {
  search(query: "org:{ORG} is:pr is:merged merged:>={CUTOFF} sort:merged-desc", type: ISSUE, first: 100, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number
        title
        headRefName
        mergedAt
        repository { nameWithOwner }
        closingIssuesReferences(first: 5) {
          nodes { number createdAt }
        }
      }
    }
  }
}
"""


@dataclass(frozen=True)
class MergedPR:
    number: int
    repo: str  # short name, e.g. "0509"
    title: str
    head_ref: str
    merged_ts: float
    issue_created_ts: float | None = None  # earliest closing-issue createdAt


@dataclass
class RepoSLO:
    repo: str
    throughput_weekly: int = 0
    lead_time_days: float = 0.0
    revert_rate: float = 0.0
    merged_24h: int = 0
    merges_28d: int = 0
    reverts_28d: int = 0
    lead_samples: list[float] = field(default_factory=list)
    # fleet-ops#3519: per-repo rolling-7d quality metrics (per 100 merges).
    quality_reverts_per_100: float = 0.0
    quality_defects_per_100: float = 0.0
    quality_sessions_to_pr_pct: float = 0.0
    merges_7d: int = 0
    sessions_7d: int = 0


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


def is_revert(pr: MergedPR) -> bool:
    title = pr.title or ""
    head = pr.head_ref or ""
    if head.startswith("revert/"):
        return True
    if title.startswith("Revert "):
        return True
    if title.lower().startswith("auto-revert"):
        return True
    return False


def _first_existing(paths: list[str]) -> Path | None:
    for p in paths:
        if not p:
            continue
        path = Path(p)
        if path.is_file():
            return path
    return None


def load_product_repos(
    intake_path: Path | None = None,
    self_path: Path | None = None,
) -> list[str]:
    """Short repo names: intake repos[] minus self-maintenance.

    Respects intake-repos.json as the product-candidate list (accept §6d).
    fleet-ops is enrolled for intake but is self-maintenance, so it drops.
    """
    intake = intake_path or _first_existing(_INTAKE_CANDIDATES)
    self_maint = self_path or _first_existing(_SELF_CANDIDATES)
    if intake is None:
        print("product-slo: intake-repos.json not found", file=sys.stderr)
        return []
    try:
        data = json.loads(intake.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"product-slo: intake read failed: {exc}", file=sys.stderr)
        return []
    enrolled = [
        str(row.get("name") or "").strip()
        for row in (data.get("repos") or [])
        if isinstance(row, dict) and row.get("name")
    ]
    self_set: set[str] = set()
    if self_maint is not None:
        try:
            sdata = json.loads(self_maint.read_text(encoding="utf-8"))
            self_set = {
                str(name).strip()
                for name in (sdata.get("repos") or [])
                if str(name).strip()
            }
        except (OSError, json.JSONDecodeError) as exc:
            print(f"product-slo: self-maint read failed: {exc}", file=sys.stderr)
    return [name for name in enrolled if name and name not in self_set]


# --- gh / cache ------------------------------------------------------------


def _gh_graphql(query: str, cursor: str | None) -> dict[str, Any] | None:
    payload = {"query": query, "variables": {"cursor": cursor}}
    env = os.environ.copy()
    env.setdefault("HOME", HOME)
    try:
        proc = subprocess.run(
            [GH, "api", "graphql", "--input", "-"],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            timeout=GH_TIMEOUT,
            env=env,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"product-slo: gh graphql failed: {exc}", file=sys.stderr)
        return None
    if proc.returncode != 0:
        print(
            f"product-slo: gh graphql rc={proc.returncode}: "
            f"{(proc.stderr or proc.stdout)[:300]}",
            file=sys.stderr,
        )
        return None
    try:
        return json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return None


def _fetch_merged_prs(cutoff: datetime) -> list[MergedPR] | None:
    cutoff_iso = cutoff.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    query = (
        MERGED_SEARCH.replace("{ORG}", ORG).replace("{CUTOFF}", cutoff_iso)
    )
    out: list[MergedPR] = []
    cursor: str | None = None
    for _ in range(GH_PAGES):
        payload = _gh_graphql(query, cursor)
        if payload is None:
            return None
        if payload.get("errors"):
            print(
                f"product-slo: graphql errors: {payload['errors'][:1]}",
                file=sys.stderr,
            )
            return None
        conn = ((payload.get("data") or {}).get("search") or {})
        for node in conn.get("nodes") or []:
            if not isinstance(node, dict):
                continue
            repo_full = (node.get("repository") or {}).get("nameWithOwner") or ""
            if not repo_full.startswith(f"{ORG}/"):
                continue
            short = repo_full.split("/", 1)[1]
            merged = parse_iso(node.get("mergedAt"))
            if merged is None:
                continue
            issue_created: float | None = None
            refs = ((node.get("closingIssuesReferences") or {}).get("nodes")) or []
            for ref in refs:
                if not isinstance(ref, dict):
                    continue
                created = parse_iso(ref.get("createdAt"))
                if created is None:
                    continue
                ts = created.timestamp()
                if issue_created is None or ts < issue_created:
                    issue_created = ts
            out.append(
                MergedPR(
                    number=int(node.get("number") or 0),
                    repo=short,
                    title=str(node.get("title") or ""),
                    head_ref=str(node.get("headRefName") or ""),
                    merged_ts=merged.timestamp(),
                    issue_created_ts=issue_created,
                )
            )
        page = conn.get("pageInfo") or {}
        if not page.get("hasNextPage"):
            break
        cursor = page.get("endCursor")
        if not cursor:
            break
    return out


def _cache_read() -> tuple[list[dict[str, Any]] | None, float | None]:
    try:
        raw = json.loads(CACHE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None, None
    if not isinstance(raw, dict):
        return None, None
    fetched = raw.get("fetched_at")
    rows = raw.get("prs")
    if not isinstance(rows, list):
        return None, None
    try:
        age_anchor = float(fetched)
    except (TypeError, ValueError):
        return None, None
    return rows, age_anchor


def _cache_write(prs: list[MergedPR], fetched_at: float) -> None:
    payload = {
        "fetched_at": fetched_at,
        "prs": [
            {
                "number": p.number,
                "repo": p.repo,
                "title": p.title,
                "head_ref": p.head_ref,
                "merged_ts": p.merged_ts,
                "issue_created_ts": p.issue_created_ts,
            }
            for p in prs
        ],
    }
    try:
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        tmp = CACHE.with_suffix(CACHE.suffix + ".tmp")
        tmp.write_text(json.dumps(payload), encoding="utf-8")
        tmp.replace(CACHE)
    except OSError as exc:
        print(f"product-slo: cache write failed: {exc}", file=sys.stderr)


def _rows_to_prs(rows: list[dict[str, Any]]) -> list[MergedPR]:
    out: list[MergedPR] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        try:
            out.append(
                MergedPR(
                    number=int(row.get("number") or 0),
                    repo=str(row.get("repo") or ""),
                    title=str(row.get("title") or ""),
                    head_ref=str(row.get("head_ref") or ""),
                    merged_ts=float(row["merged_ts"]),
                    issue_created_ts=(
                        float(row["issue_created_ts"])
                        if row.get("issue_created_ts") is not None
                        else None
                    ),
                )
            )
        except (KeyError, TypeError, ValueError):
            continue
    return out


def load_merged_prs(now: datetime) -> list[MergedPR] | None:
    """Cached merged-PR list covering the trailing 28d, or None on hard miss."""
    cached_rows, fetched_at = _cache_read()
    now_ts = now.timestamp()
    if cached_rows is not None and fetched_at is not None:
        age = now_ts - fetched_at
        if age <= TTL:
            return _rows_to_prs(cached_rows)

    cutoff = now - timedelta(seconds=MONTH_S)
    fresh = _fetch_merged_prs(cutoff)
    if fresh is not None:
        _cache_write(fresh, now_ts)
        return fresh

    # gh failed — serve stale cache up to STALE.
    if cached_rows is not None and fetched_at is not None:
        age = now_ts - fetched_at
        if age <= STALE:
            print(
                f"product-slo: serving stale cache age={int(age)}s",
                file=sys.stderr,
            )
            return _rows_to_prs(cached_rows)
    return None


def load_fixture(path: str) -> tuple[list[str], list[MergedPR]]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    repos = [str(r) for r in (data.get("repos") or [])]
    prs = _rows_to_prs(list(data.get("prs") or []))
    return repos, prs


# --- compute ---------------------------------------------------------------


def compute_repo_slo(
    repo: str,
    prs: list[MergedPR],
    *,
    now_ts: float,
) -> RepoSLO:
    """Compute weekly throughput, lead time, revert rate, 24h merges, and
    the per-repo rolling-7d quality metrics (fleet-ops#3519).

    - throughput_weekly: non-revert merges with merged_ts in (now-7d, now]
    - lead_time_days: median of (merged - issue_created) days for those
      non-revert weekly merges that have a closing-issue timestamp.
      Revert PRs are excluded (accept §6b).
    - revert_rate: reverts_28d / merges_28d (0 when no merges)
    - merged_24h: non-revert merges in trailing 24h
    - quality_reverts_per_100: 100 * reverts_7d / merges_7d (reverts count in
      the denominator too — it is "reverts per 100 merges")
    - quality_defects_per_100: 100 * merges tied to an issue filed within the
      week / merges_7d (desk-triage / red-on-main / customer-facing issues
      tied to a merged PR)
    - quality_sessions_to_pr_pct: 100 * sessions_7d / merges_7d from the
      host session dir (`pi-issue-<repo>-*`)
    """
    slo = RepoSLO(repo=repo)
    week_cut = now_ts - WEEK_S
    month_cut = now_ts - MONTH_S
    day_cut = now_ts - DAY_S
    lead_samples: list[float] = []
    defect_merges: int = 0

    for pr in prs:
        if pr.repo != repo:
            continue
        if pr.merged_ts > now_ts or pr.merged_ts <= month_cut:
            # Outside the 28d envelope we fetched for (or future).
            if pr.merged_ts <= month_cut:
                continue
        revert = is_revert(pr)
        # 28d envelope (inclusive of week/day).
        if month_cut < pr.merged_ts <= now_ts:
            slo.merges_28d += 1
            if revert:
                slo.reverts_28d += 1
        if week_cut < pr.merged_ts <= now_ts:
            slo.merges_7d += 1
            # Post-merge defect proxy: the merge is tied to an issue filed
            # within the week (fresh desk-triage / red-on-main / customer
            # issue). Reverts count too — a revert of a fresh PR is a defect.
            if pr.issue_created_ts is not None and pr.issue_created_ts > week_cut:
                defect_merges += 1
        if revert:
            continue
        if day_cut < pr.merged_ts <= now_ts:
            slo.merged_24h += 1
        if week_cut < pr.merged_ts <= now_ts:
            slo.throughput_weekly += 1
            if pr.issue_created_ts is not None and pr.issue_created_ts <= pr.merged_ts:
                lead_samples.append(
                    (pr.merged_ts - pr.issue_created_ts) / DAY_S
                )

    # Reverts in the 7d window are counted again here (independent of the
    # revert-rate 28d path) so the per-100 number is exact for the window.
    reverts_7d = sum(
        1
        for pr in prs
        if pr.repo == repo
        and is_revert(pr)
        and week_cut < pr.merged_ts <= now_ts
    )

    slo.quality_defects_per_100 = _ratio100(defect_merges, slo.merges_7d)
    if slo.merges_28d > 0:
        slo.revert_rate = slo.reverts_28d / slo.merges_28d
    if lead_samples:
        slo.lead_time_days = float(statistics.median(lead_samples))
        slo.lead_samples = lead_samples

    # fleet-ops#3519 quality metrics (after merges_7d is known).
    slo.quality_reverts_per_100 = _ratio100(reverts_7d, slo.merges_7d)
    slo.sessions_7d = _count_recent_sessions(repo, week_cut)
    # fleet-ops#3519: sessions per 100 merges — the HELP/name/alert contract
    # is sessions_7d / merges_7d (higher = more churn). The inverted form
    # (merges/sessions, a yield%) made the ceiling alert fire when churn was
    # LOW and go quiet as churn grew — and made the committed ceiling seed
    # land on the wrong scale.
    slo.quality_sessions_to_pr_pct = _ratio100(slo.sessions_7d, slo.merges_7d)
    return slo


def _ratio100(numerator: int, denominator: int) -> float:
    """100 * numerator / denominator, 0 when the denominator is 0."""
    if denominator <= 0:
        return 0.0
    return round(100.0 * numerator / denominator, 6)


def _count_recent_sessions(repo: str, week_cut: float) -> int:
    """Count issue-work session records (one per jsonl in a
    `pi-issue-<repo>-*` dir, mtime within the week) for sessions_to_pr_pct.
    """
    if not SESSIONS_DIR.is_dir():
        return 0
    try:
        session_dirs = sorted(SESSIONS_DIR.glob(f"pi-issue-{repo}-*"))
    except OSError:
        return 0
    count = 0
    for d in session_dirs:
        if not d.is_dir():
            continue
        try:
            for f in d.iterdir():
                try:
                    if f.is_file() and f.stat().st_mtime > week_cut:
                        count += 1
                        break
                except OSError:
                    continue
        except OSError:
            continue
    return count


def compute_all(
    repos: list[str],
    prs: list[MergedPR],
    *,
    now: datetime,
) -> list[RepoSLO]:
    now_ts = now.timestamp()
    return [compute_repo_slo(repo, prs, now_ts=now_ts) for repo in repos]


# --- export ----------------------------------------------------------------


def load_ceilings(repos: list[str]) -> dict[str, dict[str, float]]:
    """Per-repo, per-metric quality ceilings from config/quality-ratchet.json
    `.ceilings`. Returns {} when the file/corpus is absent or malformed so a
    config fault never fails the exporter — the gauges still export with no
    ceiling series and the ceiling alert rules simply stay silent.
    """
    path = _first_existing(_QUALITY_RATCHET_CANDIDATES)
    if path is None:
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return {}
        ceilings = data.get("ceilings")
        if not isinstance(ceilings, dict):
            return {}
    except (OSError, json.JSONDecodeError):
        return {}
    out: dict[str, dict[str, float]] = {}
    defaults: dict[str, float] = {}
    drow = ceilings.get("_default")
    if isinstance(drow, dict):
        for metric in QUALITY_METRICS:
            try:
                defaults[metric] = float(drow.get(metric))
            except (TypeError, ValueError):
                continue
    for repo in repos:
        repo_c = ceilings.get(repo)
        row: dict[str, float] = {}
        if isinstance(repo_c, dict):
            for metric in QUALITY_METRICS:
                val = repo_c.get(metric)
                try:
                    row[metric] = float(val)
                except (TypeError, ValueError):
                    continue
        # A repo without its own row inherits the _default seed so the
        # ceiling alert is armed from day one; the ratchet then tightens it.
        if not row:
            row = dict(defaults)
        if row:
            out[repo] = row
    return out


def export_prom(slos: list[RepoSLO], *, now: datetime) -> str:
    lines: list[str] = [HELP_TP, TYPE_TP]
    for s in slos:
        lines.append(
            f'fleet_product_throughput_weekly{{repo="{prom_label(s.repo)}"}} '
            f"{s.throughput_weekly}"
        )
    lines += ["", HELP_LT, TYPE_LT]
    for s in slos:
        lines.append(
            f'fleet_product_lead_time_days{{repo="{prom_label(s.repo)}"}} '
            f"{s.lead_time_days:.6f}"
        )
    lines += ["", HELP_RR, TYPE_RR]
    for s in slos:
        lines.append(
            f'fleet_product_revert_rate{{repo="{prom_label(s.repo)}"}} '
            f"{s.revert_rate:.6f}"
        )
    lines += ["", HELP_24, TYPE_24]
    for s in slos:
        lines.append(
            f'fleet_product_merged_24h{{repo="{prom_label(s.repo)}"}} '
            f"{s.merged_24h}"
        )
    # fleet-ops#3519: per-repo rolling-7d quality gauges + committed ceilings.
    lines += ["", HELP_QRV, TYPE_QRV]
    for s in slos:
        lines.append(
            f'fleet_product_quality_reverts_per_100{{repo="{prom_label(s.repo)}"}} '
            f"{s.quality_reverts_per_100:.6f}"
        )
    lines += ["", HELP_QDF, TYPE_QDF]
    for s in slos:
        lines.append(
            f'fleet_product_quality_post_merge_defects_per_100{{repo="{prom_label(s.repo)}"}} '
            f"{s.quality_defects_per_100:.6f}"
        )
    lines += ["", HELP_QSP, TYPE_QSP]
    for s in slos:
        lines.append(
            f'fleet_product_quality_sessions_to_pr_pct{{repo="{prom_label(s.repo)}"}} '
            f"{s.quality_sessions_to_pr_pct:.6f}"
        )
    lines += ["", HELP_QCEIL, TYPE_QCEIL]
    for repo, row in sorted(load_ceilings([s.repo for s in slos]).items()):
        for metric, val in sorted(row.items()):
            lines.append(
                f'fleet_product_quality_ceiling{{repo="{prom_label(repo)}",'
                f'metric="{prom_label(metric)}"}} {val:.6f}'
            )
    lines += [
        "",
        HELP_HB,
        TYPE_HB,
        f"fleet_product_slo_last_run_seconds {int(now.timestamp())}",
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
        "usage: fleet-product-slo.py [--stdout] [--help]\n"
        "  Computes product delivery SLOs and writes\n"
        f"  {OUT} (override with FLEET_PRODUCT_SLO_OUT).\n"
        "  Offline fixture: FLEET_PRODUCT_SLO_FIXTURE=/path/to.json",
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
        print(f"product-slo: unknown flag {a}", file=sys.stderr)
        return usage()

    end = now_dt()
    try:
        if FIXTURE:
            repos, prs = load_fixture(FIXTURE)
        else:
            repos = load_product_repos()
            prs_or_none = load_merged_prs(end)
            if prs_or_none is None:
                raise RuntimeError("merged-PR fetch failed and no usable cache")
            prs = prs_or_none
        if not repos:
            # Still emit heartbeat so absent() does not fire on an empty
            # product set (misconfig); zeros for no repos is fine.
            print("product-slo: no product repos resolved", file=sys.stderr)
        slos = compute_all(repos, prs, now=end)
        body = export_prom(slos, now=end)
        if to_stdout:
            sys.stdout.write(body if body.endswith("\n") else body + "\n")
        summary = ", ".join(
            f"{s.repo}:tp={s.throughput_weekly},lt={s.lead_time_days:.2f},"
            f"rr={s.revert_rate:.3f},24h={s.merged_24h}"
            for s in slos
        ) or "(no repos)"
        print(f"product-slo: wrote {OUT} ({summary})", file=sys.stderr)
        return 0
    except Exception as exc:  # noqa: BLE001 — never fail the parent exporter
        print(f"product-slo failed: {exc}", file=sys.stderr)
        try:
            repos = load_product_repos() if not FIXTURE else []
            if FIXTURE:
                try:
                    repos, _ = load_fixture(FIXTURE)
                except Exception:  # noqa: BLE001
                    repos = ["0509"]
            if not repos:
                repos = ["0509"]
            export_prom([RepoSLO(repo=r) for r in repos], now=end)
        except Exception as write_exc:  # noqa: BLE001
            print(f"product-slo zero-write failed: {write_exc}", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())
