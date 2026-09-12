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
  fleet_product_signups_24h                       users created / 24h (0509 D1)
  fleet_product_activated_24h                     signups with first brief ≤5min
  fleet_product_paying_customers_total            users on a non-free plan
  fleet_product_briefs_delivered_24h              sent deliveries / 24h
  fleet_product_table_rows{table="..."}          business-table row census
                                                 (0509 D1, fleet-ops#5000)
  fleet_product_slo_last_run_seconds             organ heartbeat (always)

The last four (fleet-ops#4456) are the product OUTCOME half — merges are
DELIVERY, these are whether a user was actually gained. They are read from
0509's D1 via the sanctioned Cloudflare token (fleet-ops#1166) and are
emitted ABSENT when that source is unreachable — never a fabricated 0
(Prometheus absent() surfaces the gap).

Sources:
  - config/intake-repos.json repos[] (product candidates)
  - config/self-maintenance-repos.json (control-plane exclusion)
  - gh GraphQL search of merged PRs per product repo (cached, 4m TTL)
  - 0509 D1 (fleet-ops#4456): user / user_plan / delivery_attempt via the
    sanctioned Cloudflare token; absent on unreachable

Piggybacks fleet-metrics-export.service via
systemd/fleet-metrics-export.service.d/product-slo.conf — no new timer
(house pattern; accept §5's dedicated hourly timer is rejected as a new
organ when the 5-min exporter already runs). Always exits 0 so a fault
cannot fail Prometheus export.

Environment seams (tests):
  FLEET_PRODUCT_SLO_OUT, FLEET_PRODUCT_SLO_NOW, FLEET_PRODUCT_SLO_FIXTURE,
  FLEET_PRODUCT_SLO_GH, FLEET_PRODUCT_SLO_CACHE, FLEET_PRODUCT_SLO_TTL,
  FLEET_PRODUCT_SLO_STALE, FLEET_PRODUCT_SLO_INTAKE,
  FLEET_PRODUCT_SLO_SELF_MAINT, FLEET_PRODUCT_SLO_ORG, HOME,
  FLEET_PRODUCT_OUTCOME (skip → outcome gauges absent, offline tests),
  FLEET_PRODUCT_CF_FILE / FLEET_PRODUCT_D1_ACCOUNT / FLEET_PRODUCT_D1_DATABASE
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
from urllib.error import HTTPError as _HTTPError
from urllib.request import Request, urlopen

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
# fleet-ops#4456: product OUTCOME (not delivery) metrics come from 0509's D1
# (users, plans, deliveries) read with the sanctioned VPS Cloudflare token
# (fleet-ops#1166 deploy-ci.env). No new organ — same exporter tick, same
# no-fail-open rule: when the source cannot be read the outcome gauges are
# EMITTED ABSENT (a Prometheus absent() surfaces it), never a fabricated 0
# (fleet-ops#4456 required: "no fabricated zeros; UNAVAILABLE, never 0").
D1 = {
    "account": os.environ.get("FLEET_PRODUCT_D1_ACCOUNT",
                              "f670a698e17bf160c8e4679823e68916"),
    "database": os.environ.get("FLEET_PRODUCT_D1_DATABASE",
                                "746c6e3d-782e-443a-82d6-28ca93a16294"),
}
# The sanctioned CF token file (fleet-ops#1166). Same default as
# lib/cf-token-canary.py. Never print the token value.
CF_TOKEN_CANDIDATES = [
    os.environ.get("FLEET_PRODUCT_CF_FILE", ""),
    os.path.expanduser("~/.config/cloudflare/deploy-ci.env"),
]
# Offline/test seam: FLEET_PRODUCT_OUTCOME=skip makes _product_outcome return
# None without any network call (the gauges then stay absent). This keeps the
# offline unit test deterministic and proves the "no fabricated 0" rule.
OUTCOME_SKIP = os.environ.get("FLEET_PRODUCT_OUTCOME", "")
# Hex alphabet for validating the Cloudflare D1 account/database IDs before
# they are interpolated into the fixed api.cloudflare.com URL (fleet-ops#4456).
_HEX = "0123456789abcdefABCDEF"
# fleet-ops#3416: 4m TTL. The shipped_24h tile reads this cache, so a
# stale cache undercounts the trailing-24h window and disputes the console
# verifier's abs<=2 tolerance. 5-min exporter tick refetches gh each tick
# (staleness <=4m, under tile stale_after_s=900), while the per-repo fetch
# stays ~12 refetches/hr x 1-2 pages — trivial vs the 5,000/hr gh budget.
TTL = int(os.environ.get("FLEET_PRODUCT_SLO_TTL", "240"))  # 4m
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

# fleet-ops#3587: a post-merge defect is an issue that REPORTS breakage in
# shipped code, not the original ask a PR was built to solve. The only
# available signal that distinguishes them is the issue's label — timestamps
# cannot (every PR closes an issue filed before it merges). These are the
# defect-class labels the fleet actually uses across product repos (0509:
# bug/design-defect/deploy-regression; fleet-ops: bug/red-on-main). A merge
# counts as a post-merge defect only when it closes an in-week issue carrying
# one of these labels. The old proxy counted ANY in-week closing issue, which
# flagged ~74% of normal throughput (feat/fix/test/docs closing their own
# original issue) as defects — the false-positive top class driving
# QualityPostMergeDefectsCeiling. The broader ceiling redesign (sessions
# proxy, baseline-seeded ceilings, backtest drill) is fleet-ops#3759.
DEFECT_ISSUE_LABELS = frozenset(
    {"bug", "defect", "regression", "design-defect", "deploy-regression", "red-on-main"}
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
    "# HELP fleet_product_quality_post_merge_defects_per_100 Merged PRs that "
    "close an in-week issue carrying a defect-class label (bug / defect / "
    "regression / design-defect / deploy-regression / red-on-main), per 100 "
    "merged PRs in the trailing 7 days per product repo (fleet-ops#3519, "
    "#3587). The label is the only signal that separates a defect report "
    "from the original ask a PR was built to solve."
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
# fleet-ops#4456: product OUTCOME gauges — were signups/activation/paying/
# briefs gained. Merges are delivery, these are the actual user gain. Read
# from 0509 D1 (see _product_outcome). Emitted ABSENT when the source is
# unreachable (never a fabricated 0) so Prometheus absent() stays honest.
HELP_SU = (
    "# HELP fleet_product_signups_24h Users created in 0509 D1 in the "
    "trailing 24h (fleet-ops#4456). Source: 0509 D1 user.createdAt via the "
    "sanctioned Cloudflare token. Absent when the source is unreachable."
)
TYPE_SU = "# TYPE fleet_product_signups_24h gauge"
HELP_AC = (
    "# HELP fleet_product_activated_24h Signups in the trailing 24h whose "
    "first sent brief arrived within 5 minutes of signup (fleet-ops#4456). "
    "Source: 0509 D1 user JOIN delivery_attempt. Absent when unreachable."
)
TYPE_AC = "# TYPE fleet_product_activated_24h gauge"
HELP_PC = (
    "# HELP fleet_product_paying_customers_total Users with a non-free plan "
    "in 0509 D1 (fleet-ops#4456). Source: 0509 D1 user_plan. Absent when "
    "unreachable."
)
TYPE_PC = "# TYPE fleet_product_paying_customers_total gauge"
HELP_BD = (
    "# HELP fleet_product_briefs_delivered_24h Sent deliveries in the "
    "trailing 24h (fleet-ops#4456). Source: 0509 D1 delivery_attempt."
    " Absent when unreachable."
)
TYPE_BD = "# TYPE fleet_product_briefs_delivered_24h gauge"
HELP_TR = (
    "# HELP fleet_product_table_rows Business-table row census from 0509 "
    "D1 (fleet-ops#5000). One series per table: user_plan, watchlist, "
    "delivery_attempt, proof_capture, session. Absent (never 0) when the "
    "D1 read fails."
)
TYPE_TR = "# TYPE fleet_product_table_rows gauge"
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
          nodes { number createdAt labels(first: 20) { nodes { name } } }
        }
      }
    }
  }
}
"""

# fleet-ops#3532: the auto-merge-arm ceiling gate calls --repo-check, which
# needs only one repo's trailing-7d merges — a repo-scoped search is a
# fraction of the org-wide 28d page set.
REPO_MERGED_SEARCH = MERGED_SEARCH.replace(
    'org:{ORG} is:pr', 'repo:{ORG}/{REPO} is:pr'
)

# fleet-ops#4039: the `labels(first: 20) { nodes { name } }` subquery nested
# inside closingIssuesReferences intermittently fails GitHub GraphQL schema
# validation with `Field 'name' doesn't exist on type 'LabelConnection'`
# (a GitHub gateway bug — the query is valid; __type confirms LabelConnection
# has `nodes`, and Label has `name`). Observed ~62% of ticks over 24h on
# 2026-09-06/07. The labels data feeds ONLY defect_issue_created_ts (the
# post-merge-defect quality metric, fleet-ops#3587); merged_24h — the console
# shipped_24h tile source — does not need it. When the error fires, retry the
# page without the labels subquery so the delivery metric keeps flowing and
# the stale-cache drift that disputed the tile (ConsoleLying) cannot happen.
# Stripping this substring leaves `nodes { number createdAt }`, still valid.
#
# fleet-ops#4073: the gateway surfaces the same schema error in TWO shapes:
#   (a) HTTP 200 with {"errors": [...]} in the JSON body (rc=0) — #4102's
#       payload-error retry handles this.
#   (b) a non-2xx HTTP status so `gh api graphql` exits rc!=0 with the error
#       on stderr — observed in production at 2026-09-06T23:15Z
#       (`gh graphql rc=1: gh: Field 'name' doesn't exist on type
#       'LabelConnection'`). The rc!=0 path returned None and served stale
#       cache WITHOUT triggering #4102's retry, so merged_24h drifted and
#       ConsoleLying re-fired. _gh_graphql now raises LabelConnectionError
#       on the rc!=0/stderr variant so _search_merged_prs retries without
#       labels on both shapes.
_LABELS_SUBQUERY = " labels(first: 20) { nodes { name } }"


class LabelConnectionError(Exception):
    """GitHub GraphQL gateway rejected the nested labels subquery (rc!=0).

    The rc=0/payload variant is detected inline in _search_merged_prs; this
    exception covers the rc!=0/stderr variant (fleet-ops#4073).
    """


def _strip_labels(query: str) -> str:
    """Return the query with the closing-issue labels subquery removed."""
    return query.replace(_LABELS_SUBQUERY, "")


@dataclass(frozen=True)
class MergedPR:
    number: int
    repo: str  # short name, e.g. "0509"
    title: str
    head_ref: str
    merged_ts: float
    issue_created_ts: float | None = None  # earliest closing-issue createdAt
    # fleet-ops#3587: earliest createdAt among closing issues that carry a
    # defect-class label (DEFECT_ISSUE_LABELS). None when no closing issue is
    # a defect report — i.e. the merge solved its own original ask, not a
    # post-merge defect. Drives quality_defects_per_100.
    defect_issue_created_ts: float | None = None


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
    # Title conventions must stay symmetric with the console verifier's
    # _is_revert_title (libexec/fleet-console-pi/verify.py, fleet-ops#4061):
    # GitHub's auto-revert `Revert "..."`, the fleet auto-restore bot's
    # lowercase `revert: auto-restore green main (reverts <sha>)`, and the
    # arm's `auto-revert ...`. Matching them all by title means a PR is
    # excluded regardless of which check sees it first.
    tl = title.lstrip().lower()
    return (tl.startswith("revert ")
            or tl.startswith("revert:")
            or tl.startswith("auto-revert"))


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
        stderr_text = (proc.stderr or proc.stdout)[:300]
        # fleet-ops#4073: the LabelConnection schema error can surface as a
        # non-2xx HTTP status (gh exits rc!=0 with the error on stderr),
        # not only as a 200/{"errors":...} payload. Raise so the caller can
        # retry without the labels subquery on both shapes; a non-Label
        # rc!=0 stays a generic None (serves stale cache, next tick retries).
        if "LabelConnection" in stderr_text:
            raise LabelConnectionError(stderr_text[:160])
        print(
            f"product-slo: gh graphql rc={proc.returncode}: "
            f"{stderr_text}",
            file=sys.stderr,
        )
        return None
    try:
        return json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return None


def _search_merged_prs(query: str) -> list[MergedPR] | None:
    out: list[MergedPR] = []
    cursor: str | None = None
    # fleet-ops#4039 / #4073: GitHub's GraphQL gateway intermittently rejects
    # the nested labels subquery with a LabelConnection schema error, in TWO
    # shapes — a 200/{"errors":...} payload (rc=0) and a non-2xx/rc!=0 with
    # the error on stderr. The labels data feeds only defect_issue_created_ts
    # (a quality metric); retry the failing page without labels so merged_24h
    # (the tile source) keeps flowing. Once stripped, stay stripped for the
    # rest of pagination.
    active_query = query
    for _ in range(GH_PAGES):
        try:
            payload = _gh_graphql(active_query, cursor)
        except LabelConnectionError as e:
            # fleet-ops#4073: rc!=0/stderr variant. Retry without labels the
            # same way the payload variant below does; a non-label rc!=0
            # stays a generic None (handled before reaching here).
            if active_query is query:
                stripped = _strip_labels(query)
                if stripped != query:
                    print(
                        "product-slo: GitHub GraphQL LabelConnection error "
                        f"(rc!=0: {e}); retrying without labels subquery "
                        "(defect metric degrades, merged_24h preserved) "
                        "— fleet-ops#4073",
                        file=sys.stderr,
                    )
                    active_query = stripped
                    continue  # retry this page without labels
            print(
                f"product-slo: graphql LabelConnection rc error: {e}",
                file=sys.stderr,
            )
            return None
        if payload is None:
            return None
        if payload.get("errors"):
            err_text = str(payload["errors"][:1])
            if "LabelConnection" in err_text and active_query is query:
                stripped = _strip_labels(query)
                if stripped != query:
                    print(
                        "product-slo: GitHub GraphQL LabelConnection error; "
                        "retrying without labels subquery (defect metric "
                        "degrades, merged_24h preserved) — fleet-ops#4039",
                        file=sys.stderr,
                    )
                    active_query = stripped
                    continue  # retry this page without labels
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
            defect_created: float | None = None
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
                # fleet-ops#3587: a closing issue carrying a defect-class
                # label is a defect report; track its earliest createdAt.
                labels = (ref.get("labels") or {}).get("nodes") or []
                label_names = {
                    str((lab or {}).get("name") or "")
                    for lab in labels
                    if isinstance(lab, dict)
                }
                if label_names & DEFECT_ISSUE_LABELS:
                    if defect_created is None or ts < defect_created:
                        defect_created = ts
            out.append(
                MergedPR(
                    number=int(node.get("number") or 0),
                    repo=short,
                    title=str(node.get("title") or ""),
                    head_ref=str(node.get("headRefName") or ""),
                    merged_ts=merged.timestamp(),
                    issue_created_ts=issue_created,
                    defect_issue_created_ts=defect_created,
                )
            )
        page = conn.get("pageInfo") or {}
        if not page.get("hasNextPage"):
            break
        cursor = page.get("endCursor")
        if not cursor:
            break
    return out


def _fetch_product_merged_prs(
    repos: list[str], cutoff: datetime
) -> list[MergedPR] | None:
    """Fetch the trailing-28d merged PRs per product repo and combine.

    Per-repo, not org-wide: the org-wide search is capped at 1000 results
    (GitHub search API limit), and fleet-ops (self-maintenance) alone
    exceeds that in 28d, silently truncating product repos' older merges
    and undercounting shipped_24h. Each product repo merges well under
    1000 in 28d, so a per-repo search fully covers the window
    (fleet-ops#3984).
    """
    out: list[MergedPR] = []
    for repo in repos:
        repo_prs = _fetch_repo_merged_prs(repo, cutoff)
        if repo_prs is None:
            return None
        out.extend(repo_prs)
    return out


def _fetch_repo_merged_prs(
    repo: str, cutoff: datetime
) -> list[MergedPR] | None:
    cutoff_iso = cutoff.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    query = (
        REPO_MERGED_SEARCH.replace("{ORG}", ORG)
        .replace("{REPO}", repo)
        .replace("{CUTOFF}", cutoff_iso)
    )
    return _search_merged_prs(query)


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
                "defect_issue_created_ts": p.defect_issue_created_ts,
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
                    defect_issue_created_ts=(
                        float(row["defect_issue_created_ts"])
                        if row.get("defect_issue_created_ts") is not None
                        else None
                    ),
                )
            )
        except (KeyError, TypeError, ValueError):
            continue
    return out


def load_merged_prs(now: datetime, repos: list[str]) -> list[MergedPR] | None:
    """Cached merged-PR list covering the trailing 28d, or None on hard miss."""
    cached_rows, fetched_at = _cache_read()
    now_ts = now.timestamp()
    if cached_rows is not None and fetched_at is not None:
        age = now_ts - fetched_at
        if age <= TTL:
            return _rows_to_prs(cached_rows)

    cutoff = now - timedelta(seconds=MONTH_S)
    fresh = _fetch_product_merged_prs(repos, cutoff)
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
    - quality_defects_per_100: 100 * merges that close an in-week issue
      carrying a defect-class label (DEFECT_ISSUE_LABELS) / merges_7d. The
      label separates a defect report from the original ask the PR solved
      (fleet-ops#3587).
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
            # Post-merge defect proxy (fleet-ops#3587): the merge closes an
            # in-week issue carrying a defect-class label — a defect report
            # reacting to shipped code, not the original ask the PR solved.
            # The old "any in-week closing issue" heuristic flagged ~74% of
            # normal throughput as defects; the label is the only signal that
            # separates a defect from the PR's own original issue.
            if (
                pr.defect_issue_created_ts is not None
                and pr.defect_issue_created_ts > week_cut
            ):
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


# fleet-ops#3759: the replay drill. Recomputes the quality proxies over a
# historical merged-PR set (the cached 28d envelope, or a fixture) and prints
# per-repo per-metric JSON so the proxy can be checked against a
# hand-classified sample. This is the issue's termination command — it proves
# the proxy matches manual classification on historical merges without
# touching live alert state.
def backtest(
    repos: list[str],
    prs: list[MergedPR],
    *,
    now: datetime,
) -> dict[str, Any]:
    now_ts = now.timestamp()
    out: dict[str, Any] = {"window": "4w", "now": now.isoformat(), "repos": {}}
    for repo in repos:
        repo_prs = [p for p in prs if p.repo == repo]
        slo = compute_repo_slo(repo, repo_prs, now_ts=now_ts)
        out["repos"][repo] = {
            "merges_7d": slo.merges_7d,
            "reverts_per_100_merges": slo.quality_reverts_per_100,
            "post_merge_defects_per_100": slo.quality_defects_per_100,
            "sessions_to_pr_pct": slo.quality_sessions_to_pr_pct,
        }
    return out


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


def load_repo_ceiling_row(repo: str) -> dict[str, float]:
    """One repo's ceiling row from config/quality-ratchet.json `.ceilings`:
    the repo's own row else `_default`, every committed metric (not limited
    to QUALITY_METRICS — a metric becomes gateable the moment a measurement
    source lands, e.g. red_on_main_minutes via fleet-ops#3534).
    """
    path = _first_existing(_QUALITY_RATCHET_CANDIDATES)
    if path is None:
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        ceilings = data.get("ceilings") if isinstance(data, dict) else None
        if not isinstance(ceilings, dict):
            return {}
    except (OSError, json.JSONDecodeError):
        return {}
    row = ceilings.get(repo)
    if not isinstance(row, dict) or not row:
        row = ceilings.get("_default")
    if not isinstance(row, dict):
        return {}
    out: dict[str, float] = {}
    for metric, val in row.items():
        try:
            out[str(metric)] = float(val)
        except (TypeError, ValueError):
            continue
    return out


# fleet-ops#3532: the auto-merge-arm ceiling gate enforces exactly the two
# metrics the issue names. A metric enforces only when a measurement source
# exists — today that is reverts_per_100_merges (merged-PR data); the rest
# report under `unmeasured` until their exporters land.
GATE_METRICS = ("reverts_per_100_merges", "red_on_main_minutes")


def repo_check(repo: str, now: datetime) -> dict[str, Any]:
    """Quality-ceiling verdict for one repo (--repo-check). Fetches the
    repo's trailing-7d merged PRs, computes the gate metrics through the
    same compute_repo_slo definition the exporter uses, and compares each
    measured metric against the committed ceiling. Prints a single JSON
    verdict; a fetch failure raises so the caller can decide fail-open.
    """
    now_ts = now.timestamp()
    if FIXTURE:
        _, prs = load_fixture(FIXTURE)
    else:
        prs = _fetch_repo_merged_prs(
            repo, now - timedelta(seconds=WEEK_S)
        )
        if prs is None:
            raise RuntimeError("merged-PR fetch failed")
    repo_prs = [p for p in prs if p.repo == repo]
    slo = compute_repo_slo(repo, repo_prs, now_ts=now_ts)
    measured = {"reverts_per_100_merges": slo.quality_reverts_per_100}
    ceilings = load_repo_ceiling_row(repo)
    breached = sorted(
        m
        for m in GATE_METRICS
        if m in measured and m in ceilings and measured[m] > ceilings[m]
    )
    return {
        "repo": repo,
        "merges_7d": slo.merges_7d,
        "measured": measured,
        "ceiling": {m: ceilings[m] for m in GATE_METRICS if m in ceilings},
        "breached": breached,
        "unmeasured": [m for m in GATE_METRICS if m not in measured],
        "ok": not breached,
    }


def _read_cf_token() -> str | None:
    """Return the sanctioned VPS Cloudflare API token, or None.

    fleet-ops#1166: the token file lives at ~/.config/cloudflare/deploy-ci.env
    and holds CLOUDFLARE_API_TOKEN=<value>. The value is NEVER printed or
    logged; only whether one was found. Returns None (source unavailable)
    when no candidate file has a non-empty token.
    """
    for cand in CF_TOKEN_CANDIDATES:
        if not cand:
            continue
        try:
            for line in Path(cand).read_text(
                encoding="utf-8", errors="ignore"
            ).splitlines():
                line = line.strip()
                prefix = "CLOUDFLARE_API_TOKEN="
                if line.startswith(prefix):
                    return line[len(prefix):].strip()
        except (OSError, UnicodeDecodeError):
            continue
    return None


def _is_d1_id(value: str) -> bool:
    """True when value is a Cloudflare D1 ID: hex, optionally dash-separated.
    Strips dashes (UUID form) and requires the remainder be 32 hex chars.
    fleet-ops#4456 — gates the two ID segments before they are interpolated
    into the fixed api.cloudflare.com URL.
    """
    if not isinstance(value, str) or not value:
        return False
    digits = value.replace("-", "")
    return len(digits) == 32 and all(c in _HEX for c in digits)


_D1_QUERIES = {
    "signups_24h": (
        "SELECT COUNT(*) AS n FROM user "
        "WHERE julianday(createdAt) >= julianday('now','-1 day');"
    ),
    # Signups in the trailing 24h whose first SENT brief arrived within 5
    # minutes of signup (the activation definition, fleet-ops#4456 BET 7).
    "activated_24h": (
        "SELECT COUNT(*) AS n FROM ("
        "SELECT u.id FROM user u "
        "JOIN delivery_attempt da ON da.user_id = u.id "
        "WHERE julianday(u.createdAt) >= julianday('now','-1 day') "
        "AND da.status='sent' "
        "AND (julianday(da.sent_at)-julianday(u.createdAt))*1440.0 <= 5.0 "
        "GROUP BY u.id);"
    ),
    "paying_customers": (
        "SELECT COUNT(DISTINCT user_id) AS n FROM user_plan "
        "WHERE plan != 'free';"
    ),
    "briefs_delivered_24h": (
        "SELECT COUNT(*) AS n FROM delivery_attempt "
        "WHERE status='sent' AND julianday(sent_at) >= julianday('now','-1 day');"
    ),
    # fleet-ops#5000 business-table census. One compound select, one row, so
    # the census costs ONE extra Cloudflare API call, not one per table; the
    # five counts come back as named columns of a single result row.
    # Absent-not-zero: if this query fails the census is omitted (see
    # _product_outcome), never reported as 0 rows.
    "table_census": (
        "SELECT (SELECT COUNT(*) FROM user_plan) AS user_plan, "
        "(SELECT COUNT(*) FROM watchlist) AS watchlist, "
        "(SELECT COUNT(*) FROM delivery_attempt) AS delivery_attempt, "
        "(SELECT COUNT(*) FROM proof_capture) AS proof_capture, "
        "(SELECT COUNT(*) FROM session) AS session;"
    ),
}

# fleet-ops#5000: key of the census entry in _D1_QUERIES / product outcome,
# and the tables counted in one row by that entry (order = column order).
CENSUS_KEY = "table_census"
CENSUS_TABLES = (
    "user_plan",
    "watchlist",
    "delivery_attempt",
    "proof_capture",
    "session",
)


def _product_outcome() -> dict[str, int | dict[str, int]] | None:
    """Return {signups_24h, activated_24h, paying_customers,
    briefs_delivered_24h, table_census} from 0509's D1, or None when the
    source is unavailable. The four scalars are ints; table_census is a
    {table: row count} dict over CENSUS_TABLES (fleet-ops#5000). fleet-ops#4456:
    never return a fabricated 0 — Unavailable means the gauges are emitted
    ABSENT (callers must not write a 0). A census-only failure drops just
    table_census and leaves the four scalars intact.
    """
    if OUTCOME_SKIP:
        return None
    token = _read_cf_token()
    if not token:
        print(
            "product-slo: product outcome unavailable: no sanctioned "
            "Cloudflare token (fleet-ops#4456)",
            file=sys.stderr,
        )
        return None
    # Host and path are literals; only the two Cloudflare ID segments come
    # from config. Each is validated as 32 hex chars (dashes, as in a UUID
    # form, allowed for the database id) before the URL is built, so a
    # tampered env value cannot smuggle a scheme/`..`/`//` — the only
    # reachable endpoint is api.cloudflare.com (sgscan
    # dynamic-urllib-use-detected is a confirmed false positive here).
    account = D1["account"]
    database = D1["database"]
    if not _is_d1_id(account):
        print("product-slo: invalid D1 account id (must be hex)", file=sys.stderr)
        return None
    if not _is_d1_id(database):
        print("product-slo: invalid D1 database id (must be hex)", file=sys.stderr)
        return None
    url = (
        "https://api.cloudflare.com/client/v4/accounts/"
        f"{account}/d1/database/{database}/query"
    )
    out: dict[str, int | dict[str, int]] = {}
    for key, sql in _D1_QUERIES.items():
        payload = json.dumps({"sql": sql}).encode("utf-8")
        req = Request(
            url,
            data=payload,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            # Host/path literals; only 32-hex-validated ID segments in the path.
            # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
            with urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except (OSError, ValueError, _HTTPError) as exc:
            print(
                f"product-slo: product outcome {key} unavailable: {exc}",
                file=sys.stderr,
            )
            if key == CENSUS_KEY:
                continue
            return None
        if not data.get("success"):
            print(
                f"product-slo: product outcome {key} unavailable: "
                f"cloudflare errors={data.get('errors')}",
                file=sys.stderr,
            )
            if key == CENSUS_KEY:
                continue
            return None
        rows = (data.get("result") or [{}])[0].get("results") or []
        try:
            if key == CENSUS_KEY:
                # One row of five named counts -> {table: count}.
                out[CENSUS_KEY] = {t: int(rows[0][t]) for t in CENSUS_TABLES}
            else:
                out[key] = int(rows[0]["n"])
        except (IndexError, KeyError, TypeError, ValueError):
            print(
                f"product-slo: product outcome {key} unavailable: "
                f"unexpected shape {rows!r}",
                file=sys.stderr,
            )
            if key == CENSUS_KEY:
                continue
            return None
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
    # fleet-ops#4456: product OUTCOME gauges from 0509 D1. Emitted only when
    # the source is readable; when unavailable they are ABSENT (Prometheus
    # absent() surfaces it) — never a fabricated 0.
    outcome = _product_outcome()
    if outcome is not None:
        lines += ["", HELP_SU, TYPE_SU, f"fleet_product_signups_24h {outcome['signups_24h']}"]
        lines += ["", HELP_AC, TYPE_AC, f"fleet_product_activated_24h {outcome['activated_24h']}"]
        lines += ["", HELP_PC, TYPE_PC, f"fleet_product_paying_customers_total {outcome['paying_customers']}"]
        lines += ["", HELP_BD, TYPE_BD, f"fleet_product_briefs_delivered_24h {outcome['briefs_delivered_24h']}"]
    # fleet-ops#5000: business-table census family. Emitted only when the
    # census dict is present; a failed/absent census omits the whole family
    # (Prometheus absent() surfaces it) — never a fabricated 0.
    if outcome is not None and CENSUS_KEY in outcome:
        census = outcome[CENSUS_KEY]
        lines += ["", HELP_TR, TYPE_TR]
        for table in CENSUS_TABLES:
            lines.append(f'fleet_product_table_rows{{table="{table}"}} {census[table]}')
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
        "       fleet-product-slo.py --repo-check <repo>\n"
        "       fleet-product-slo.py --backtest <window> --repo <repo> [--repo <repo> ...]\n"
        "  Computes product delivery SLOs and writes\n"
        f"  {OUT} (override with FLEET_PRODUCT_SLO_OUT).\n"
        "  --repo-check prints the one-repo quality-ceiling verdict as\n"
        "  JSON (the auto-merge-arm gate input; exit 1 on fetch failure).\n"
        "  --backtest replays the quality proxies over the cached 28d merged-PR\n"
        "  set (or a fixture) and prints per-repo per-metric JSON — the\n"
        "  fleet-ops#3759 termination drill proving the proxy matches manual\n"
        "  classification on historical merges. <window> is 4w (28d).\n"
        "  Offline fixture: FLEET_PRODUCT_SLO_FIXTURE=/path/to.json",
        file=sys.stderr,
    )
    return 2


def main(argv: list[str] | None = None) -> int:
    argv = list(argv if argv is not None else sys.argv[1:])
    to_stdout = False
    repo_check_repo: str | None = None
    backtest_window: str | None = None
    backtest_repos: list[str] = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            return usage()
        if a == "--stdout":
            to_stdout = True
            i += 1
            continue
        if a == "--repo-check":
            if i + 1 >= len(argv):
                print("product-slo: --repo-check needs a repo", file=sys.stderr)
                return usage()
            repo_check_repo = argv[i + 1]
            i += 2
            continue
        if a == "--backtest":
            if i + 1 >= len(argv):
                print("product-slo: --backtest needs a window (4w)", file=sys.stderr)
                return usage()
            backtest_window = argv[i + 1]
            i += 2
            continue
        if a == "--repo":
            if i + 1 >= len(argv):
                print("product-slo: --repo needs a repo name", file=sys.stderr)
                return usage()
            backtest_repos.append(argv[i + 1])
            i += 2
            continue
        print(f"product-slo: unknown flag {a}", file=sys.stderr)
        return usage()

    if repo_check_repo is not None:
        try:
            verdict = repo_check(repo_check_repo, now_dt())
        except Exception as exc:  # noqa: BLE001 — caller decides fail-open
            print(f"product-slo repo-check failed: {exc}", file=sys.stderr)
            return 1
        print(json.dumps(verdict, sort_keys=True))
        return 0

    if backtest_window is not None:
        if backtest_window != "4w":
            print(
                f"product-slo: unsupported backtest window {backtest_window!r} "
                "(only 4w)",
                file=sys.stderr,
            )
            return usage()
        if not backtest_repos:
            print("product-slo: --backtest needs at least one --repo", file=sys.stderr)
            return usage()
        end = now_dt()
        try:
            if FIXTURE:
                _, prs = load_fixture(FIXTURE)
            else:
                prs_or_none = load_merged_prs(end, backtest_repos)
                if prs_or_none is None:
                    raise RuntimeError("merged-PR fetch failed and no usable cache")
                prs = prs_or_none
            result = backtest(backtest_repos, prs, now=end)
        except Exception as exc:  # noqa: BLE001 — caller decides fail-open
            print(f"product-slo backtest failed: {exc}", file=sys.stderr)
            return 1
        print(json.dumps(result, sort_keys=True))
        return 0

    end = now_dt()
    try:
        if FIXTURE:
            repos, prs = load_fixture(FIXTURE)
        else:
            repos = load_product_repos()
            prs_or_none = load_merged_prs(end, repos)
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
