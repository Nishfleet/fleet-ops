#!/usr/bin/env python3
"""Write fleet facts to node_exporter textfile collector (stdlib only).

Discovers fleet-* and pi-* timers dynamically from `systemctl --user
list-timers`. Never hardcodes a unit list — deleted timers disappear from
the export automatically.
"""
import calendar
import fnmatch
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path

# --- Config ----------------------------------------------------------------

OUT = Path("/var/lib/prometheus/node-exporter/fleet.prom")
SEAT_HEALTH = Path(
    "/home/nish/workspaces/agent-state/lanes/pi-seat-health.json"
)
# Per-seat health ledger written by the pi seat-health extension. Each file is
# <sanitised-provider>__<sanitised-model>.json. We scan it to surface
# dead-credential seats (seat_dead=true, health_class=credentials_bad) as a
# distinct heartbeat signal (fleet-ops#1445) instead of them being buried in
# pick_seat's per-pick cap/dead fold or silently re-logged every cycle.
SEAT_LEDGER = Path(
    "/home/nish/workspaces/agent-state/lanes/seats"
)
HC_URL_FILE = Path(
    "/home/nish/.config/fleet-healthchecks/fleet-timer-liveness.url"
)
XDG = f"/run/user/{os.getuid()}"

# Prefix filter — any timer whose unit name starts with one of these is
# exported. No hardcoded list of individual units.
TIMER_PREFIXES = ("fleet-", "pi-")

HELP_LT = "# HELP fleet_timer_last_trigger_seconds Epoch (s) of the last trigger for a fleet/pi timer."
TYPE_LT = "# TYPE fleet_timer_last_trigger_seconds gauge"
HELP_ACT = "# HELP fleet_timer_active 1 if the timer is active, else 0."
TYPE_ACT = "# TYPE fleet_timer_active gauge"
HELP_HEALTH = "# HELP fleet_pi_seat_healthy 1 if the Pi seat is healthy, else 0."
TYPE_HEALTH = "# TYPE fleet_pi_seat_healthy gauge"
HELP_OBS = "# HELP fleet_pi_seat_observed_seconds Epoch (s) when the Pi seat was last observed."
TYPE_OBS = "# TYPE fleet_pi_seat_observed_seconds gauge"
HELP_DCT = "# HELP fleet_pi_seat_dead_credential_total Number of seats with seat_dead=true and health_class=credentials_bad (HTTP 401/403) that need re-auth and will not recover until re-authenticated (fleet-ops#1445)."
TYPE_DCT = "# TYPE fleet_pi_seat_dead_credential_total gauge"
HELP_DC = "# HELP fleet_pi_seat_dead_credential 1 for each dead-credential seat needing re-auth (fleet-ops#1445)."
TYPE_DC = "# TYPE fleet_pi_seat_dead_credential gauge"
HELP_TEST = "# HELP fleet_test_alert 1 if the synthetic test alert file exists, else 0."
TYPE_TEST = "# TYPE fleet_test_alert gauge"
TEST_ALERT_FILE = Path(f"/run/user/{os.getuid()}/fleet-test-alert")

# Self-observation metrics (Task 2). All stdlib; gh is cached to <=1 call/30min.
HELP_MPR = "# HELP fleet_merged_prs_24h Merged PR count per repo in the trailing 24h."
TYPE_MPR = "# TYPE fleet_merged_prs_24h gauge"
HELP_ESC = "# HELP fleet_escalations_24h Count of unit-escalation@ instances in the last 24h (top 20)."
TYPE_ESC = "# TYPE fleet_escalations_24h gauge"
HELP_RDISP = "# HELP fleet_repair_dispatch_24h DISPATCH lines in alert-repair actions.log within 24h."
TYPE_RDISP = "# TYPE fleet_repair_dispatch_24h gauge"
HELP_RSKIP = "# HELP fleet_repair_skip_24h SKIP lines in alert-repair actions.log within 24h."
TYPE_RSKIP = "# TYPE fleet_repair_skip_24h gauge"
HELP_OPEN = "# HELP fleet_open_prs Open pull-request count per repo from a cached org snapshot."
TYPE_OPEN = "# TYPE fleet_open_prs gauge"
HELP_CI = "# HELP fleet_main_ci_green 1 if default-branch CI is green, 0 if red. PENDING rollup resolved from latest completed CI run; repos with no CI omitted."
TYPE_CI = "# TYPE fleet_main_ci_green gauge"
HELP_FRESH = "# HELP fleet_gh_cache_fresh 1 if this gh-derived family is served from a cache younger than 2h."
TYPE_FRESH = "# TYPE fleet_gh_cache_fresh gauge"

# Undersaturation-guard metrics (2026-08-27, fleet-ops UNDERSATURATED — the
# deleted fleet1 watchdog's Pi-era reincarnation on stock machinery).
# `fleet_pi_workers_active{kind="unit"|"process"|"sum"}` — live pi work.
#   kind=unit    : active+activating user services matching pi-* / alert-repair-*
#                  (pi-issue@* workers live their whole life in SubState=start,
#                   so `activating` MUST be counted — `--state=running` sees 0).
#   kind=process : standalone `pi --print` PIDs NOT inside a counted unit
#                  (cgroup dedup so a unit's child pi proc is not double-counted).
#   kind=sum     : unit + process — the value FleetUndersaturated consumes.
HELP_WACT = "# HELP fleet_pi_workers_active Live pi work in flight by source. kind=unit: active+activating pi-*/alert-repair-* user services. kind=process: standalone 'pi --print' PIDs not inside a counted unit (cgroup-deduped). kind=sum: unit + process (the rule's input)."
TYPE_WACT = "# TYPE fleet_pi_workers_active gauge"
# `fleet_ready_work` — open agent-ready issues across enrolled Nishfleet repos
# (intake-repos.json is the source of truth). One gh call, cached 30 min like
# merged-prs. If gh is unhealthy and the cache is >2h stale, the exporter FAILS
# LOUD (exits non-zero) instead of omitting the family, so the frozen-queue gate
# never receives a null/frozen value (fleet-ops#1772).
HELP_READY = "# HELP fleet_ready_work Open agent-ready issues across enrolled Nishfleet repos (intake-repos.json). The exporter fails loud when the value cannot be determined, so this family is never silently null or stale."
TYPE_READY = "# TYPE fleet_ready_work gauge"
# `fleet_maintenance_quiescing` — 1 during the weekly maintenance window (or
# any manual quiesce), else 0. Gates FleetUndersaturated so the window's
# drained workers don't page. Reads agent-state/maintenance.json — the SAME
# flag vps-maintenance-quiesce sets — not a hardcoded schedule. Missing file
# → 0 (fail SAFE toward alerting; never silently suppress the guard).
HELP_MAINT = "# HELP fleet_maintenance_quiescing 1 during the weekly maintenance window (or manual quiesce), else 0. Gates FleetUndersaturated. Missing flag -> 0 (fail-safe toward alerting)."
TYPE_MAINT = "# TYPE fleet_maintenance_quiescing gauge"

# Queue composition metrics (2026-08-29, fleet-ops#1136 scope addition).
# fleet2 died at 64% self-maintenance; the queue composition was unmeasured.
# Two queues: "agent-ready" (ALL agent-ready issues across Nishfleet) and
# "ready-work" (agent-ready issues in enrolled repos only — what intake
# actually processes). We export:
#   fleet_queue_total{queue="agent-ready"|"ready-work"} — total open issues
#   fleet_queue_self_maintenance_total{queue="agent-ready"|"ready-work"} — self-maintenance issues
#   fleet_queue_self_maintenance_ratio{queue="agent-ready"|"ready-work"} — ratio 0..1 (omitted when total=0)
# The 64% tripwire (fleet2 death-number) is enforced by a TREND alert on the
# 7-day window (offset 7d), not a level — levels are Nish's policy.
HELP_QT = "# HELP fleet_queue_total Open agent-ready issues by queue. queue=agent-ready: all Nishfleet repos. queue=ready-work: enrolled repos only (intake-repos.json)."
TYPE_QT = "# TYPE fleet_queue_total gauge"
HELP_QSM = "# HELP fleet_queue_self_maintenance_total Self-maintenance agent-ready issues by queue. Self-maintenance = repos in config/self-maintenance-repos.json (default fleet-ops)."
TYPE_QSM = "# TYPE fleet_queue_self_maintenance_total gauge"
HELP_QSMR = "# HELP fleet_queue_self_maintenance_ratio Self-maintenance / total agent-ready issues by queue. 0..1. Omitted when total=0."
TYPE_QSMR = "# TYPE fleet_queue_self_maintenance_ratio gauge"

# Self-maintenance + PR-quality metrics (2026-08-27, fleet-ops#1136).
# fleet2 died at 64% self-maintenance; the fleet-ops:product merge split was
# unmeasured. These make it a live number and classify merged PRs by title
# prefix (feat->upgrade, fix/test->repair, chore->churn; refine later).
# `fleet_self_maintenance_merges{kind="self|product|total"}` — always emitted
# (the organ heartbeat; absent() fires if this family disappears).
# `fleet_self_maintenance_ratio` — self/total, 0..1; emitted only when total>0
# so a no-merge day does not paint a false 0% (the absent rule keys on the
# always-emitted `kind="total"` gauge, not the ratio).
# `fleet_pr_quality_24h{class="upgrade|repair|churn"}` — merged-PR counts.
# `fleet_pr_quality_share{class="upgrade|repair|churn"}` — class/total, 0..1;
# emitted only when total>0. Trend alerts ride the 24h-offset delta, never a
# level threshold (levels are Nish's policy; trends are physics).
HELP_SM = "# HELP fleet_self_maintenance_merges Merged-PR count in the trailing 24h by self-maintenance kind. kind=self: fleet-infra repos (config/self-maintenance-repos.json). kind=product: every other Nishfleet repo. kind=total: self+product. Always emitted (organ heartbeat)."
TYPE_SM = "# TYPE fleet_self_maintenance_merges gauge"
HELP_SMR = "# HELP fleet_self_maintenance_ratio self-maintenance merges / total merges, trailing 24h. 0..1. Omitted when total=0 (no-merge day) so a quiet day is not a false 0%."
TYPE_SMR = "# TYPE fleet_self_maintenance_ratio gauge"
HELP_PQ = "# HELP fleet_pr_quality_24h Merged-PR count in the trailing 24h by quality class (title-prefix heuristic: feat->upgrade, fix/test->repair, chore->churn; unclassified->churn). Refine later (fleet-ops#1136)."
TYPE_PQ = "# TYPE fleet_pr_quality_24h gauge"
HELP_PQS = "# HELP fleet_pr_quality_share class count / total merged PRs, trailing 24h. 0..1. Omitted when total=0. Trend alerts ride the 24h-offset delta, never a level."
TYPE_PQS = "# TYPE fleet_pr_quality_share gauge"

# Verified-merges numerator (fleet-ops#1136 objective decision, 2026-08-28).
# The fleet's single optimization target is max quality-throughput: verified,
# live-proven merged product work per day. A merged PR counts as "verified" when
# it passes BOTH gates the objective named:
#   (a) non-null effective diff  — additions+deletions > 0 (a squash that landed
#       no net change is a null diff; the merge-trample gate's null-diff class).
#   (b) delivery evidence on closure — a `run-proof:` line OR a Verification:
#       section carrying a run-cue (journalctl/systemctl/url/exit/rc/fence/
#       ALL PHASES PASSED/$ prompt/ok: N). Same cues as lib/exec-review-receipt.py
#       (the closure-evidence detector from 0509#1365's fixes); inlined here so
#       the exporter stays stdlib-only with no repo-checkout import dependency.
# `fleet_verified_merges_24h{kind="verified|unverified|total"}` — counts.
# `fleet_verified_merge_ratio` — verified/total, 0..1; omitted when total=0.
# Raw merge counts (fleet_merged_prs_24h) stay on the console; the WFR ratchets
# against THIS verified number. Baseline established on the first instrumented
# week. Trend alert on the 24h-offset delta, never a level (levels are policy).
HELP_VM = "# HELP fleet_verified_merges_24h Merged-PR count in the trailing 24h by verification kind. kind=verified: non-null effective diff AND delivery evidence (run-proof:/Verification: run-cue). kind=unverified: failed one or both gates. kind=total: verified+unverified. Always emitted when the merged-PR fetch succeeded."
TYPE_VM = "# TYPE fleet_verified_merges_24h gauge"
HELP_VMR = "# HELP fleet_verified_merge_ratio verified merges / total merges, trailing 24h. 0..1. Omitted when total=0. The WFR ratchets against this number, not raw merge counts."
TYPE_VMR = "# TYPE fleet_verified_merge_ratio gauge"

# Keystone routing metrics (fleet-ops#1133: reliability-first routing for
# keystone builds). seat-lib pick_seat appends a `routed` event when it sends
# a keystone packet to a strong seat; pi-packet-run / pi-issue-run append an
# `escalated` event on two-strike escalation. The ledger is JSONL under the
# pi-packet state dir. We export:
#   fleet_keystone_routed_total    — cumulative routed events (counter)
#   fleet_keystone_escalated_total — cumulative escalated events (counter)
#   fleet_keystone_routing_heartbeat_seconds — mtime of the ledger (gauge)
# The FleetKeystoneRoutingAbsent absent() rule watches the heartbeat gauge;
# if pick_seat stops routing keystone packets (or the ledger is wiped), the
# gauge disappears and the alert fires. Mirrors the FleetMetricsExportMissing
# pattern: the metric's PRESENCE is the health signal, not its value.
HELP_KROUTE = "# HELP fleet_keystone_routed_total Cumulative keystone packets routed to a strong seat by pick_seat (fleet-ops#1133)."
TYPE_KROUTE = "# TYPE fleet_keystone_routed_total counter"
HELP_KESC = "# HELP fleet_keystone_escalated_total Cumulative keystone packets escalated to a senior conference after two strikes (fleet-ops#1133)."
TYPE_KESC = "# TYPE fleet_keystone_escalated_total counter"
HELP_KHB = "# HELP fleet_keystone_routing_heartbeat_seconds mtime (epoch s) of the keystone routing ledger. Its presence is the health signal for the routing organ; absent() fires FleetKeystoneRoutingAbsent."
TYPE_KHB = "# TYPE fleet_keystone_routing_heartbeat_seconds gauge"
# The ledger lives in the pi-packet state dir. The state dir is the same one
# seat-lib.sh uses (PI_PACKET_STATE / $STATE_DIR); production path is fixed.
KEYSTONE_LEDGER = Path(
    "/home/nish/.local/state/pi-packet/keystone-routing.jsonl"
)

# Truth staleness metrics (fleet-ops#1137: cross-check standing docs vs live
# state). The staleness checker exports fleet_truth_staleness_last_run_seconds,
# fleet_truth_staleness_total_claims, and
# fleet_truth_staleness_mismatches_by_kind{kind="path"|"unit"|"issue"} to the
# same fleet.prom textfile. The absent() rule in fleet_rules.yml watches the
# last_run_seconds gauge; if the checker is dead or removed, the metric
# disappears and TruthStalenessAbsent fires. This is the organ heartbeat
# per fleet-ops#1010 standing pattern.
HELP_TS_LRUN = (
    "# HELP fleet_truth_staleness_last_run_seconds "
    "Epoch (s) of the last truth-staleness-checker run."
)
TYPE_TS_LRUN = "# TYPE fleet_truth_staleness_last_run_seconds gauge"
HELP_TS_CLAIMS = (
    "# HELP fleet_truth_staleness_total_claims "
    "Total verifiable claims extracted this run."
)
TYPE_TS_CLAIMS = "# TYPE fleet_truth_staleness_total_claims gauge"
HELP_TS_MISS = (
    "# HELP fleet_truth_staleness_mismatches_by_kind "
    "Count of mismatches found, by claim kind."
)
TYPE_TS_MISS = "# TYPE fleet_truth_staleness_mismatches_by_kind gauge"

ACTIONS_LOG = Path(
    "/home/nish/workspaces/agent-state/alert-repair/actions.log"
)
PR_CACHE_DIR = Path("/home/nish/workspaces/agent-state/fleet-metrics")
STALENESS_CACHE = PR_CACHE_DIR / "staleness-findings-cache.json"
PR_CACHE = PR_CACHE_DIR / "merged-prs-cache.json"
# fleet-ops#1136: detailed merged-PR records (repo+title) power the
# self-maintenance ratio and the upgrade/repair/churn classification. Separate
# cache file from PR_CACHE so the old {repo:count} shape is not misread.
DETAIL_CACHE = PR_CACHE_DIR / "merged-prs-detail-cache.json"
SNAPSHOT_CACHE = PR_CACHE_DIR / "repo-snapshot-cache.json"
PR_CACHE_TTL = 1800      # 30 min — refresh gh at most this often
PR_CACHE_STALE = 7200    # 2 h — beyond this, omit the metric family
GH_OWNER = "Nishfleet"
GH_TIMEOUT = 45          # gh can be slow; exporter must finish < 60s
JOURNAL_TIMEOUT = 20
GH_PAGES = 10

# GitHub API rate-limit metrics (fleet-ops#1350). The 5000/hr core budget is
# the next binding constraint past RAM (Nish 2026-08-27 #1167 ceiling addendum),
# so the exporter pulls `gh api rate_limit` once per run and emits the
# remaining/limit/reset for the three resources the fleet actually consumes:
# core (REST), search (REST search), graphql (the merged-PR / repo-snapshot
# path). reset is an epoch-seconds gauge so a dashboard can plot "time
# until next reset" with time() - fleet_gh_rate_limit_reset{resource=...}.
# The `fleet_gh_rate_limit_fetched_seconds` gauge is the organ heartbeat
# (fleet-ops#1010): the absent() rule in fleet_rules.yml fires when the
# exporter stops pulling the limit. fleet_gh_rate_limit_low{resource=...} is
# 1 when remaining < 20% of limit, the threshold pi-intake-tick.sh uses to
# hold claims this tick. A failing gh call OMITS the family (no frozen
# "0 remaining" that would falsely trigger the throttle).
HELP_GHRL = (
    "# HELP fleet_gh_rate_limit_remaining "
    "GitHub API requests remaining in the current window per resource. "
    "Omitted when the rate_limit fetch fails (never a frozen value)."
)
TYPE_GHRL = "# TYPE fleet_gh_rate_limit_remaining gauge"
HELP_GHRLIM = (
    "# HELP fleet_gh_rate_limit_limit "
    "GitHub API requests limit per resource (the window maximum)."
)
TYPE_GHRLIM = "# TYPE fleet_gh_rate_limit_limit gauge"
HELP_GHRSET = (
    "# HELP fleet_gh_rate_limit_reset "
    "Epoch (s) when the GitHub API window resets for the resource. "
    "time() - fleet_gh_rate_limit_reset is the seconds-to-reset."
)
TYPE_GHRSET = "# TYPE fleet_gh_rate_limit_reset gauge"
HELP_GHLOW = (
    "# HELP fleet_gh_rate_limit_low "
    "1 when remaining < 20% of limit (the throttle threshold in "
    "pi-intake-tick.sh, fleet-ops#1350). 0 when remaining >= 20%. "
    "Omitted when the rate_limit fetch fails."
)
TYPE_GHLOW = "# TYPE fleet_gh_rate_limit_low gauge"
HELP_GHFT = (
    "# HELP fleet_gh_rate_limit_fetched_seconds "
    "Epoch (s) of the last successful gh rate_limit fetch. Organ "
    "heartbeat (fleet-ops#1010): the FleetGhRateLimitAbsent absent() rule "
    "fires when this gauge disappears, not when it goes stale-by-value."
)
TYPE_GHFT = "# TYPE fleet_gh_rate_limit_fetched_seconds gauge"
# Cache file for the rate_limit family. Separate from PR_CACHE so the
# exporter can serve a stale value up to GH_RATE_LIMIT_STALE (2h) on a gh
# hiccup; the heartbeat gauge is omitted when the cache itself is missing
# (the FleetGhRateLimitAbsent rule fires). 60s TTL is a balance: the
# resource counters move every minute at most, and the throttle wants
# fresh data but a runaway exporter must not melt the API budget.
GH_RATE_LIMIT_CACHE = PR_CACHE_DIR / "gh-rate-limit-cache.json"
GH_RATE_LIMIT_TTL = 60
GH_RATE_LIMIT_STALE = 7200
# The throttle threshold: when any resource's remaining < 20% of its limit,
# pi-intake-tick.sh holds claims this tick. Documented in the help text
# above so the metric's value and the tick gate stay in lock-step.
GH_RATE_LIMIT_LOW_PCT = 0.20
# The three resources the fleet actually consumes. `core` is REST, `search`
# is the gh search issues / search prs family, `graphql` is the merged-PR
# / repo-snapshot path. Other resources (scim, audit_log, etc.) are not
# used by the fleet and are omitted to keep the family small.
GH_RATE_LIMIT_RESOURCES = ("core", "search", "graphql")
# Side-car state file for pi-intake-tick.sh (fleet-ops#1350). The tick
# runs from a fleet-ops worker unit and may not have a Prometheus client
# handy; a JSON file with {low: 0|1, remaining, limit, reset, fetched_at}
# is the minimum it needs. The path is fixed (not a fleet variable) so
# the tick script can `cat` it without an env dance.
GH_RATE_LIMIT_STATE = Path(
    "/home/nish/workspaces/agent-state/pi-intake/gh-rate-limit.json"
)

# Undersaturation-guard config.
WORKER_UNIT_PREFIXES = ("pi-", "alert-repair-")
MAINTENANCE_FLAG = Path(
    "/home/nish/workspaces/agent-state/maintenance.json"
)
INTAKE_JSON_DEFAULT = Path(
    "/home/nish/workspaces/tooling/fleet-ops/config/intake-repos.json"
)
INTAKE_JSON_FALLBACK = Path(
    "/home/nish/workspaces/products/fleet-ops/config/intake-repos.json"
)
READY_CACHE = PR_CACHE_DIR / "ready-work-cache.json"
READY_GH_TIMEOUT = 45

# Queue composition caches (fleet-ops#1136 scope addition). Separate from
# READY_CACHE so the old int shape is not misread.
QUEUE_CACHE = PR_CACHE_DIR / "queue-composition-cache.json"
ALL_AGENT_READY_CACHE = PR_CACHE_DIR / "all-agent-ready-cache.json"

# Self-maintenance repo set (fleet-ops#1136). PR-tunable; never hardcoded in
# the classifier. Default ["fleet-ops"] when the file is missing/unparseable
# (fleet-ops IS the tooling/control-plane repo — there is no separate
# 'tooling' repo in Nishfleet). Multiple search paths so a worktree install
# and the products/ checkout both resolve.
SELF_MAINT_JSON_DEFAULT = Path(
    "/home/nish/workspaces/tooling/fleet-ops/config/self-maintenance-repos.json"
)
SELF_MAINT_JSON_FALLBACK = Path(
    "/home/nish/workspaces/products/fleet-ops/config/self-maintenance-repos.json"
)
SELF_MAINT_DEFAULT_SET = ("fleet-ops",)

REPO_SNAPSHOT_QUERY = """
query($cursor: String) {
  organization(login: "Nishfleet") {
    repositories(first: 50, after: $cursor, isArchived: false) {
      pageInfo { hasNextPage endCursor }
      nodes {
        nameWithOwner
        pullRequests(states: OPEN) { totalCount }
        defaultBranchRef {
          name
          target {
            ... on Commit {
              statusCheckRollup { state }
            }
          }
        }
      }
    }
  }
}
"""

# fleet-ops#1136: one paginated GraphQL `search` call fetches every PR merged
# across the org in one pass with the fields the self-maintenance ratio, the
# upgrade/repair/churn classification, AND the verified-merges numerator all
# need (repo, title, body, additions, deletions, changedFiles, mergedAt). The
# REST `gh search prs --json` surface omits additions/deletions/changedFiles,
# so the non-null-diff gate cannot be evaluated from it. GraphQL search returns
# PullRequest nodes for an ISSUE-typed query; `sort:updated-desc` + a 24h
# mergedAt cutoff in the client keeps the page count bounded (a busy day is
# ~50-100 merges; GH_PAGES=10 × first=100 covers 1000).
MERGED_PRS_SEARCH_QUERY = """
query($cursor: String) {
  search(query: "org:Nishfleet is:pr is:merged sort:updated-desc", type: ISSUE, first: 100, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        title
        body
        additions
        deletions
        changedFiles
        mergedAt
        repository { nameWithOwner }
      }
    }
  }
}
"""


# --- Helpers ---------------------------------------------------------------

def _list_timers():
    """Return list of {unit, last_usec} dicts for fleet/pi timers.

    Skips inactive/invalid entries; `last` may be 0 or null for timers that
    have never fired.
    """
    try:
        r = subprocess.run(
            [
                "systemctl",
                "--user",
                "list-timers",
                "--all",
                "--output=json",
            ],
            capture_output=True,
            text=True,
            timeout=15,
            env={**os.environ, "XDG_RUNTIME_DIR": XDG},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"list-timers failed: {exc}", file=sys.stderr)
        return []
    if r.returncode != 0:
        print(f"list-timers rc={r.returncode}: {r.stderr}", file=sys.stderr)
        return []
    try:
        rows = json.loads(r.stdout)
    except json.JSONDecodeError as exc:
        print(f"list-timers json: {exc}", file=sys.stderr)
        return []
    out = []
    for row in rows:
        unit = (row.get("unit") or "").strip()
        if not unit.startswith(TIMER_PREFIXES):
            continue
        # `last` is microseconds since epoch, or null / 0.
        last_raw = row.get("last")
        last_usec = 0
        if isinstance(last_raw, (int, float)) and last_raw > 0:
            last_usec = int(last_raw)
        out.append({"unit": unit, "last_usec": last_usec})
    return out


def _timer_active(unit):
    try:
        r = subprocess.run(
            ["systemctl", "--user", "is-active", unit],
            capture_output=True,
            text=True,
            timeout=5,
            env={**os.environ, "XDG_RUNTIME_DIR": XDG},
        )
    except (OSError, subprocess.TimeoutExpired):
        return 0
    return 1 if r.stdout.strip() == "active" else 0


def _read_seat():
    """Return (healthy 0/1, observed_epoch_or_none)."""
    try:
        data = json.loads(SEAT_HEALTH.read_text())
    except (OSError, json.JSONDecodeError):
        return 0, None
    healthy = 1 if data.get("health_class") == "healthy" else 0
    obs = data.get("observed_at")
    epoch = None
    if isinstance(obs, str):
        try:
            # RFC3339 / ISO-8601 with trailing 'Z' for UTC.
            ts = obs.replace("Z", "+00:00")
            epoch = int(
                time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
            )
        except ValueError:
            epoch = None
    return healthy, epoch


def _read_dead_credentials():
    """Scan the per-seat health ledger for dead-credential seats.

    A dead-credential seat is seat_dead=true with health_class=credentials_bad
    (HTTP 401/403): it will never recover until the provider credential is
    re-authenticated (fleet-ops#1445). These are surfaced once per 5-min export
    tick as a distinct metric + alert, rather than being buried in pick_seat's
    per-pick "excluded ... dead: D" fold or re-logged every cycle by the seat
    loop.

    Returns (count, [ {provider, model, http_status}, ... ]). Always a
    (count, list) pair — never raises on a missing/unreadable ledger.
    """
    seats = []
    if not SEAT_LEDGER.is_dir():
        return 0, seats
    try:
        for f in sorted(SEAT_LEDGER.iterdir()):
            if not f.is_file() or "__" not in f.name or not f.name.endswith(".json"):
                continue
            try:
                data = json.loads(f.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(data, dict):
                continue
            if data.get("seat_dead") is True and data.get("health_class") == "credentials_bad":
                seats.append({
                    "provider": data.get("provider", ""),
                    "model": data.get("model", ""),
                    "http_status": data.get("http_status"),
                })
    except OSError:
        return 0, []
    return len(seats), seats


def _atomic_write(path, text):
    """Write atomically: tmp in same dir, fsync, os.replace."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=str(path.parent)
    )
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    # node_exporter (different uid) needs to read the textfile.
    os.chmod(path, 0o644)


def _watchdog_firing():
    """Return True if a Watchdog alert is firing in Prometheus.

    A dead Prometheus/Alertmanager (or any failure to query) returns False,
    which makes the caller ping the dead-man ``<url>/fail`` endpoint instead
    of silently passing.
    """
    try:
        # Hardcoded localhost URL (not user-controlled); false positive.
        with urllib.request.urlopen("http://127.0.0.1:9090/api/v1/alerts", timeout=10) as r:  # nosemgrep
            payload = json.load(r)
    except (urllib.error.URLError, urllib.error.HTTPError,
            OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"watchdog check: {exc}", file=sys.stderr)
        return False
    for a in (payload.get("data") or {}).get("alerts", []) or []:
        if a.get("labels", {}).get("alertname") == "Watchdog" and \
                a.get("state") == "firing":
            return True
    return False


def _ping_healthcheck():
    try:
        url = HC_URL_FILE.read_text().strip()
    except OSError as exc:
        print(f"hc url read: {exc}", file=sys.stderr)
        return None
    if not url:
        return None
    # Watchdog-gated dead-man: only ping the success URL when a Watchdog
    # alert is firing in Prometheus. Otherwise (or if the query failed)
    # ping <url>/fail so the external dead-man trips.
    if _watchdog_firing():
        target = url
        branch = "healthy"
    else:
        target = url.rstrip("/") + "/fail"
        branch = "dead-man"
    try:
        req = urllib.request.Request(target, method="GET")
        # target is a healthcheck URL from a config file (not user input).
        with urllib.request.urlopen(req, timeout=10) as r:  # nosemgrep
            print(f"hc ping branch={branch} status={r.status}", file=sys.stderr)
            return r.status
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as exc:
        print(f"hc ping branch={branch}: {exc}", file=sys.stderr)
        return None


# --- Self-observation (Task 2) ---------------------------------------------

_TS_RE = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z\]")


def _parse_iso_utc(s):
    """Parse YYYY-MM-DDTHH:MM:SS (UTC) → epoch seconds, or None."""
    try:
        return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        return None


def _prom_label(s):
    return str(s).replace("\\", "\\\\").replace('"', '\\"')


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
    except OSError as exc:
        print(f"cache write {path}: {exc}", file=sys.stderr)


_GH_FETCHED_THIS_RUN = False


def _cached_json(path, fetcher, name):
    """Return fetched/cached data, or None to omit the metric family.

    Fresh cache (≤30 min) skips gh. On gh failure, serve cache up to 2h.
    Beyond 2h the family is omitted — never a frozen value.

    At most one gh fetch per exporter run so the 5-min oneshot stays under
    60s (gh can take ~45s). The other family waits 5 min for the next run.
    """
    global _GH_FETCHED_THIS_RUN
    cached, cache_age = _read_cache(path)
    if cache_age is not None and cache_age <= PR_CACHE_TTL and cached is not None:
        return cached
    if _GH_FETCHED_THIS_RUN:
        if cached is not None and cache_age is not None and cache_age <= PR_CACHE_STALE:
            return cached
        return None
    data = fetcher()
    _GH_FETCHED_THIS_RUN = True
    if data is not None:
        _write_cache(path, data)
        return data
    if cached is not None and cache_age is not None and cache_age <= PR_CACHE_STALE:
        print(f"{name} gh failed, serving stale cache (age={int(cache_age)}s)",
              file=sys.stderr)
        return cached
    return None


def _merged_prs_24h():
    """Return dict {repo: count} for PRs merged in the trailing 24h, or None.

    Derived from the detailed fetch (_merged_prs_detail) so the per-repo
    family and the #1136 self-maintenance/quality families share ONE gh call.
    """
    detail = _merged_prs_detail()
    if detail is None:
        return None
    counts = Counter(r["repo"] for r in detail)
    return dict(counts)


def _merged_prs_detail():
    """Cached list of merged-PR records for the trailing 24h, or None.

    One GraphQL `search` call fetches repository + mergedAt + title + body +
    additions + deletions + changedFiles. The per-repo fleet_merged_prs_24h
    family, the self-maintenance ratio, the upgrade/repair/churn
    classification, AND the verified-merges numerator all derive from this
    single fetch (fleet-ops#1136) — no extra gh call per exporter run.
    """
    detail = _cached_json(DETAIL_CACHE, _gh_merged_prs_raw, "merged_prs_detail")
    # Shape guard: a cache written by the pre-#1136-verified exporter has only
    # {repo, title} (no body/additions/deletions/changed_files). The verified-
    # merges numerator would see all-zero diff stats and classify every PR as
    # unverified. Delete the stale-shape cache and re-fetch with the full field
    # set (one-time transition on deploy; the _GH_FETCHED_THIS_RUN guard is
    # reset so the re-fetch is allowed this run).
    if detail and not any("additions" in r for r in detail):
        print("merged_prs_detail: cache has pre-verified-merges shape; re-fetching",
              file=sys.stderr)
        global _GH_FETCHED_THIS_RUN
        _GH_FETCHED_THIS_RUN = False
        try:
            DETAIL_CACHE.unlink()
        except OSError:
            pass
        detail = _cached_json(DETAIL_CACHE, _gh_merged_prs_raw, "merged_prs_detail")
    return detail


def _gh_merged_prs():
    """Back-compat alias for callers expecting {repo: count}."""
    return _merged_prs_24h()


def _gh_merged_prs_raw():
    """One paginated GraphQL search call across all Nishfleet repos.

    Returns a list of {"repo", "title", "body", "additions", "deletions",
    "changed_files"} for PRs merged in the trailing 24h, or None on failure.
    The diff-stat + body fields power the verified-merges numerator
    (fleet-ops#1136 objective decision); the REST `gh search prs --json`
    surface omits additions/deletions/changedFiles, so GraphQL search is
    required.
    """
    cutoff_epoch = time.time() - 86400
    out = []
    cursor = None
    for _ in range(GH_PAGES):
        payload = _gh_graphql(MERGED_PRS_SEARCH_QUERY, cursor)
        if payload is None:
            return None
        if payload.get("errors"):
            print(f"gh graphql errors: {payload['errors'][:1]}", file=sys.stderr)
            return None
        conn = ((payload.get("data") or {}).get("search") or {})
        for node in conn.get("nodes") or []:
            repo = (node.get("repository") or {}).get("nameWithOwner") or ""
            if not repo:
                continue
            merged = node.get("mergedAt") or ""
            ep = _parse_iso_utc(merged)
            if ep is None or ep < cutoff_epoch:
                continue
            out.append({
                "repo": repo,
                "title": node.get("title") or "",
                "body": node.get("body") or "",
                "additions": int(node.get("additions") or 0),
                "deletions": int(node.get("deletions") or 0),
                "changed_files": int(node.get("changedFiles") or 0),
            })
        page = conn.get("pageInfo") or {}
        if not page.get("hasNextPage"):
            return out
        cursor = page.get("endCursor")
        if not cursor:
            return out
    print("gh merged-prs search: hit page cap", file=sys.stderr)
    return out


def _gh_graphql(query, cursor=None):
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    if cursor:
        cmd.extend(["-f", f"cursor={cursor}"])
    try:
        r = subprocess.run(
            cmd, capture_output=True, text=True, timeout=GH_TIMEOUT,
            env={**os.environ, "GH": "/usr/bin/gh"},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"gh graphql failed: {exc}", file=sys.stderr)
        return None
    if r.returncode != 0:
        print(f"gh graphql rc={r.returncode}: {r.stderr.strip()[:200]}",
              file=sys.stderr)
        return None
    try:
        return json.loads(r.stdout or "{}")
    except json.JSONDecodeError as exc:
        print(f"gh graphql json: {exc}", file=sys.stderr)
        return None


# --- GitHub rate limit (fleet-ops#1350) -----------------------------------
# One `gh api rate_limit` per run, cached to GH_RATE_LIMIT_TTL. A failing
# call serves the cache up to GH_RATE_LIMIT_STALE; beyond that, the family
# is omitted so the throttle never freezes on a stale "0 remaining".
# `_gh_rate_limit_now` does the live fetch. `_gh_rate_limit` is the
# caller-facing wrapper that handles the TTL/stale envelope.
def _gh_rate_limit_now():
    """Return parsed JSON from `gh api rate_limit` or None on failure."""
    try:
        r = subprocess.run(
            ["gh", "api", "rate_limit"],
            capture_output=True, text=True, timeout=GH_TIMEOUT,
            env={**os.environ, "GH": "/usr/bin/gh"},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"gh rate_limit failed: {exc}", file=sys.stderr)
        return None
    if r.returncode != 0:
        print(f"gh rate_limit rc={r.returncode}: {r.stderr.strip()[:200]}",
              file=sys.stderr)
        return None
    try:
        return json.loads(r.stdout or "{}")
    except json.JSONDecodeError as exc:
        print(f"gh rate_limit json: {exc}", file=sys.stderr)
        return None


def _gh_rate_limit():
    """Return dict[resource] = {remaining, limit, reset, low} or None.

    `low` is the precomputed throttle boolean (remaining < 20% of limit) so
    the throttle and the metric stay in lock-step — a single source of
    truth for the 20% threshold.

    Fresh cache (≤60s) skips gh. A failing call serves the cache up to 2h.
    Beyond 2h, the family is omitted (caller treats None as "throttle gate
    undecided, do not block on it"). The cache is NOT a slot in the global
    `_GH_FETCHED_THIS_RUN` gate because rate_limit is a cheap 1-call-per-
    minute read, not the multi-second paginated GraphQL fetch those
    families do — and a stuck exporter can still write the heartbeat
    gauge on a TTL miss.
    """
    cached, cache_age = _read_cache(GH_RATE_LIMIT_CACHE)
    if cache_age is not None and cache_age <= GH_RATE_LIMIT_TTL and cached is not None:
        return _shape_rate_limit(cached)
    data = _gh_rate_limit_now()
    if data is not None:
        _write_cache(GH_RATE_LIMIT_CACHE, data)
        return _shape_rate_limit(data)
    if cached is not None and cache_age is not None and cache_age <= GH_RATE_LIMIT_STALE:
        print(f"gh_rate_limit gh failed, serving stale cache (age={int(cache_age)}s)",
              file=sys.stderr)
        return _shape_rate_limit(cached)
    return None


def _shape_rate_limit(payload):
    """Project the gh `rate_limit` payload to the three resources the
    fleet consumes (core/search/graphql). Other resources are dropped to
    keep the metric family small — the fleet never hits scim, audit_log,
    etc. Returns {resource: {remaining, limit, reset, low}} or None when
    the payload is missing the resources section.
    """
    if not isinstance(payload, dict):
        return None
    resources = payload.get("resources")
    if not isinstance(resources, dict):
        return None
    out = {}
    for r in GH_RATE_LIMIT_RESOURCES:
        row = resources.get(r)
        if not isinstance(row, dict):
            continue
        try:
            remaining = int(row.get("remaining", 0))
            limit = int(row.get("limit", 0))
            reset = int(row.get("reset", 0))
        except (TypeError, ValueError):
            continue
        # The low flag is the throttle threshold (fleet-ops#1350). Compute
        # here, not in the exporter loop, so the metric value and the
        # tick gate can never drift.
        low = 1 if (limit > 0 and remaining < limit * GH_RATE_LIMIT_LOW_PCT) else 0
        out[r] = {
            "remaining": remaining,
            "limit": limit,
            "reset": reset,
            "low": low,
        }
    return out or None


def _write_gh_rate_limit_state(rl):
    """Write the side-car state file pi-intake-tick.sh reads (fleet-ops#1350).

    Aggregates across the three consumed resources to a single
    {low, remaining, limit, reset, fetched_at} so the tick gate has ONE
    decision to make, not three. `low` is the OR of per-resource low
    flags (any resource below threshold → throttle). `remaining` /
    `limit` are the MIN of the three (the binding floor — the fleet is
    as exhausted as its tightest resource). `reset` is the MAX of the
    three reset epochs (the longest wait until all resources recover).

    Atomic write (temp + rename, fsync) so a concurrent tick never reads
    a half-written file. The state dir lives in agent-state/pi-intake so
    it survives across worktrees; the parent dir is created on demand.
    A write failure logs and returns — the metric family has already
    succeeded, and the throttle is a soft gate, not a blocker.
    """
    if not rl:
        return
    low = 0
    remaining_min = None
    limit_floor = None
    reset_max = 0
    for r in GH_RATE_LIMIT_RESOURCES:
        row = rl.get(r)
        if row is None:
            continue
        if row.get("low"):
            low = 1
        rem = int(row.get("remaining", 0))
        lim = int(row.get("limit", 0))
        rst = int(row.get("reset", 0))
        if remaining_min is None or rem < remaining_min:
            remaining_min = rem
        if limit_floor is None or (lim > 0 and lim < limit_floor):
            limit_floor = lim
        if rst > reset_max:
            reset_max = rst
    state = {
        "low": low,
        "remaining": remaining_min if remaining_min is not None else 0,
        "limit": limit_floor if limit_floor is not None else 0,
        "reset": reset_max,
        "fetched_at": time.time(),
        "resources": {r: rl[r] for r in GH_RATE_LIMIT_RESOURCES if r in rl},
    }
    try:
        GH_RATE_LIMIT_STATE.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(
            prefix=GH_RATE_LIMIT_STATE.name + ".",
            suffix=".tmp",
            dir=str(GH_RATE_LIMIT_STATE.parent),
        )
        with os.fdopen(fd, "w") as f:
            json.dump(state, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_name, GH_RATE_LIMIT_STATE)
        os.chmod(GH_RATE_LIMIT_STATE, 0o644)
    except OSError as exc:
        print(f"gh_rate_limit state write: {exc}", file=sys.stderr)


def _gh_latest_ci_verdict(repo_full, branch):
    """Latest completed 'CI' workflow run on branch → 1 (green) / 0 (red) / None.

    Used to resolve a PENDING statusCheckRollup: the rollup is pending while a
    fresh CI run is in flight, so we fall back to the most recent COMPLETED CI
    run on the default branch (the same signal `gh run list -w CI` gives).
    Skipped/neutral runs don't count; if none completed, return None (omit).
    """
    try:
        r = subprocess.run(
            ["gh", "run", "list", "-R", repo_full, "-b", branch,
             "-w", "CI", "--limit", "5",
             "--json", "status,conclusion"],
            capture_output=True, text=True, timeout=GH_TIMEOUT,
            env={**os.environ, "GH": "/usr/bin/gh"},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"gh run list failed: {exc}", file=sys.stderr)
        return None
    if r.returncode != 0:
        # No 'CI' workflow on this repo, or call failed → omit.
        return None
    try:
        rows = json.loads(r.stdout or "[]")
    except json.JSONDecodeError as exc:
        print(f"gh run list json: {exc}", file=sys.stderr)
        return None
    for row in rows:
        if (row.get("status") or "").lower() != "completed":
            continue
        concl = (row.get("conclusion") or "").lower()
        if concl == "success":
            return 1
        if concl in ("failure", "cancelled", "timed_out",
                     "action_required", "startup_failure"):
            return 0
        # skipped / neutral → not a verdict, keep looking
    return None


def _gh_repo_snapshot():
    """One paginated GraphQL call-set: open PRs + default-branch CI per repo.

    Returns {"open_prs": {repo: n}, "main_ci": {repo: 0|1}} or None.
    """
    open_prs = {}
    main_ci = {}
    cursor = None
    for _ in range(GH_PAGES):
        payload = _gh_graphql(REPO_SNAPSHOT_QUERY, cursor)
        if payload is None:
            return None
        if payload.get("errors"):
            print(f"gh graphql errors: {payload['errors'][:1]}", file=sys.stderr)
            return None
        conn = (((payload.get("data") or {}).get("organization") or {})
                .get("repositories") or {})
        for node in conn.get("nodes") or []:
            repo = node.get("nameWithOwner") or ""
            if not repo:
                continue
            prs = (node.get("pullRequests") or {}).get("totalCount")
            if isinstance(prs, int):
                open_prs[repo] = prs
            rollup = ((((node.get("defaultBranchRef") or {}).get("target")
                        or {}).get("statusCheckRollup")) or {})
            state = (rollup.get("state") or "").upper()
            if state == "SUCCESS":
                main_ci[repo] = 1
            elif state in ("FAILURE", "ERROR"):
                main_ci[repo] = 0
            elif state == "PENDING":
                # Rollup is in-flight; resolve from the latest completed CI
                # run on the default branch so a perpetually-re-running red
                # trunk still reports 0 instead of vanishing from the family.
                branch = (node.get("defaultBranchRef") or {}).get("name") \
                    or "main"
                verdict = _gh_latest_ci_verdict(repo, branch)
                if verdict is not None:
                    main_ci[repo] = verdict
        page = conn.get("pageInfo") or {}
        if not page.get("hasNextPage"):
            return {"open_prs": open_prs, "main_ci": main_ci}
        cursor = page.get("endCursor")
        if not cursor:
            return {"open_prs": open_prs, "main_ci": main_ci}
    print("gh graphql: hit page cap", file=sys.stderr)
    return {"open_prs": open_prs, "main_ci": main_ci}


def _repo_snapshot():
    """Cached org snapshot or None to omit both open_prs and main_ci families."""
    return _cached_json(SNAPSHOT_CACHE, _gh_repo_snapshot, "repo_snapshot")


def _escalations_24h():
    """Count unit-escalation@<instance> starts in the last 24h (top 20).

    Excludes the same units unit-escalation-write refuses (no self-trigger /
    feedback-loop units), plus canary / recovery units whose escalations are
    not a "unit flapping" signal. Mirrors the case list in
    /home/nish/.local/bin/unit-escalation-write, extended for this metric.
    """
    # Patterns match the FAILED unit name (the template instance). The journal
    # regex below strips a trailing .service, so we test both the stripped name
    # and the reconstructed full name against each glob.
    excluded = (
        "unit-escalation@*",
        "stop-escalation.service",
        "stop-escalation.path",
        "ready-work.service",
        "escalation-daily-sweep.service",
        "escalation-daily-sweep.timer",
        "resilience-drill-stub*",
        # Canaries / orchestrator organs: their deliberate fail-loud escalations
        # are expected, not a flapping worker.
        "fleet-heartbeat*",
        "pi-intake@fleet-ops-canary*",
        # OnFailure repair units are recovery machinery; counting them in the
        # storm metric double-counts the original failure.
        "*-repair@*",
    )

    def _is_excluded(name):
        full = name if name.endswith((".service", ".timer", ".path")) else name + ".service"
        return any(fnmatch.fnmatch(name, p) or fnmatch.fnmatch(full, p) for p in excluded)

    try:
        r = subprocess.run(
            [
                "journalctl", "--user",
                "-u", "unit-escalation@*",
                "--since", "24 hours ago",
                "--no-pager",
                "--output=cat",
            ],
            capture_output=True, text=True, timeout=JOURNAL_TIMEOUT,
            env={**os.environ, "XDG_RUNTIME_DIR": XDG},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"escalation journalctl failed: {exc}", file=sys.stderr)
        return {}
    if r.returncode != 0:
        print(f"escalation journalctl rc={r.returncode}", file=sys.stderr)
        return {}
    # systemd logs "Starting unit-escalation@<instance>.service - ...".
    # With --output=cat we get just the message line.
    counts = Counter()
    for line in r.stdout.splitlines():
        m = re.search(r"Starting unit-escalation@(.+?)\.service", line)
        if m and not _is_excluded(m.group(1)):
            counts[m.group(1)] += 1
    return dict(counts.most_common(20))


def _repair_log_counts_24h():
    """Return (dispatch_count, skip_count) from actions.log within 24h."""
    if not ACTIONS_LOG.exists():
        return 0, 0
    cutoff = time.time() - 86400
    disp = skip = 0
    try:
        with ACTIONS_LOG.open("r") as f:
            for line in f:
                m = _TS_RE.match(line)
                if not m:
                    continue
                ep = _parse_iso_utc(m.group(1))
                if ep is None or ep < cutoff:
                    continue
                rest = line[m.end():].lstrip()
                if rest.startswith("DISPATCH "):
                    disp += 1
                elif rest.startswith("SKIP "):
                    skip += 1
    except OSError as exc:
        print(f"actions.log read: {exc}", file=sys.stderr)
        return 0, 0
    return disp, skip


# --- Undersaturation guard (2026-08-27) ------------------------------------

def _enrolled_repos():
    """Return list of 'Nishfleet/<name>' slugs from intake-repos.json.

    intake-repos.json is the single source of truth for which repos run
    intake (fleet-ops#32). Empty list on missing/unparseable file — the
    rule then never fires because ready_work is omitted, which is the
    correct answer for an unenrolled fleet.
    """
    for path in (INTAKE_JSON_DEFAULT, INTAKE_JSON_FALLBACK):
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        repos = data.get("repos") or []
        if not isinstance(repos, list):
            continue
        out = []
        for r in repos:
            name = r.get("name") if isinstance(r, dict) else r
            if isinstance(name, str) and name:
                out.append("Nishfleet/" + name)
        if out:
            return out
    return []


def _gh_ready_work():
    """One cheap `gh search issues --label agent-ready --state open --owner
    Nishfleet` call → dict with total and self-maintenance counts of open
    agent-ready issues across enrolled repos. Returns {"total": int, "self": int},
    or None to omit the family.

    Owner-scoped (one call); results are filtered to enrolled repos so a
    non-enrolled Nishfleet repo's agent-ready issues don't inflate depth.
    None when no repos are enrolled (no work concept → rule must not fire).
    """
    repos = _enrolled_repos()
    if not repos:
        return None
    enrolled = set(repos)
    self_repos = _self_maintenance_repos()
    try:
        r = subprocess.run(
            ["gh", "search", "issues",
             "--owner", GH_OWNER,
             "--label", "agent-ready",
             "--state", "open",
             "--json", "number,repository",
             "--limit", "500"],
            capture_output=True, text=True, timeout=READY_GH_TIMEOUT,
            env={**os.environ, "GH": "/usr/bin/gh"},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"gh search issues failed: {exc}", file=sys.stderr)
        return None
    if r.returncode != 0:
        print(f"gh search issues rc={r.returncode}: {r.stderr.strip()[:200]}",
              file=sys.stderr)
        return None
    try:
        rows = json.loads(r.stdout or "[]")
    except json.JSONDecodeError as exc:
        print(f"gh search issues json: {exc}", file=sys.stderr)
        return None
    total = 0
    self_n = 0
    for row in rows:
        repo = row.get("repository")
        nwo = ""
        if isinstance(repo, dict):
            nwo = repo.get("nameWithOwner") or ""
        elif isinstance(repo, str):
            nwo = repo
        if nwo and nwo not in enrolled:
            continue
        total += 1
        if nwo in self_repos:
            self_n += 1
    return {"total": total, "self": self_n}


def _gh_all_agent_ready():
    """One cheap `gh search issues --label agent-ready --state open --owner
    Nishfleet` call → dict with total and self-maintenance counts of open
    agent-ready issues across ALL Nishfleet repos (not just enrolled).
    Returns {"total": int, "self": int}, or None to omit the family.
    """
    self_repos = _self_maintenance_repos()
    try:
        r = subprocess.run(
            ["gh", "search", "issues",
             "--owner", GH_OWNER,
             "--label", "agent-ready",
             "--state", "open",
             "--json", "number,repository",
             "--limit", "500"],
            capture_output=True, text=True, timeout=READY_GH_TIMEOUT,
            env={**os.environ, "GH": "/usr/bin/gh"},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"gh search issues (all) failed: {exc}", file=sys.stderr)
        return None
    if r.returncode != 0:
        print(f"gh search issues (all) rc={r.returncode}: {r.stderr.strip()[:200]}",
              file=sys.stderr)
        return None
    try:
        rows = json.loads(r.stdout or "[]")
    except json.JSONDecodeError as exc:
        print(f"gh search issues (all) json: {exc}", file=sys.stderr)
        return None
    total = 0
    self_n = 0
    for row in rows:
        repo = row.get("repository")
        nwo = ""
        if isinstance(repo, dict):
            nwo = repo.get("nameWithOwner") or ""
        elif isinstance(repo, str):
            nwo = repo
        if not nwo:
            continue
        total += 1
        if nwo in self_repos:
            self_n += 1
    return {"total": total, "self": self_n}


def _queue_composition():
    """Cached queue composition for both queues.
    Returns {"ready-work": {"total": int, "self": int},
             "agent-ready": {"total": int, "self": int}} or None.
    """
    return _cached_json(QUEUE_CACHE, _fetch_queue_composition, "queue_composition")


def _fetch_queue_composition():
    """Fetch both queue compositions in one gh call each.
    Returns dict or None if either fetch fails.
    """
    ready_work = _gh_ready_work()
    all_agent_ready = _gh_all_agent_ready()
    if ready_work is None or all_agent_ready is None:
        return None
    return {
        "ready-work": ready_work,
        "agent-ready": all_agent_ready,
    }


def _worker_units():
    """Return list of active+activating user service units matching pi-* /
    alert-repair-*.

    `activating` is included because pi-issue@* workers live their whole
    life in SubState=start (the readiness notification never arrives), so
    `--state=running` alone reports ZERO workers — a false undersaturation.
    These are the transient worker slots: pi-issue@* (the real workers),
    alert-repair-* (dispatched repair workers), and pi-intake@*/pi-scout@*
    ticks while they hold a seat.
    """
    try:
        r = subprocess.run(
            ["systemctl", "--user", "list-units",
             "--state=active,activating", "--no-legend", "--plain",
             "--type=service",
             "pi-*.service", "alert-repair-*.service"],
            capture_output=True, text=True, timeout=10,
            env={**os.environ, "XDG_RUNTIME_DIR": XDG},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"workers: list-units failed: {exc}", file=sys.stderr)
        return []
    # systemctl returns non-zero when no units match the patterns; treat as
    # empty (the metric is still emitted as 0) rather than a hard fault.
    if r.returncode != 0:
        return []
    out = []
    for line in r.stdout.splitlines():
        cols = line.split()
        if not cols:
            continue
        name = cols[0]
        if name.startswith(WORKER_UNIT_PREFIXES):
            out.append(name)
    return out


def _standalone_pi_print_count(unit_names):
    """Count `pi --print` processes NOT inside a counted worker unit.

    Reads /proc directly (stdlib) to avoid pgrep false-positives: a process
    counts when one of its argv elements is the `pi` binary (ends in '/pi'
    or is 'pi') AND argv contains both `--print` and `--provider`. That
    precisely matches the fleet's `timeout ... /home/nish/.local/bin/pi
    --print --provider <p> --model <m>` worker shape and EXCLUDES the
    devin-CLI / `bash -c` processes whose command text merely mentions
    "pi --print" (e.g. a devin -p prompt, or a test one-liner).

    Dedup: a pi --print process whose /proc/<pid>/cgroup contains any
    unit_name is already represented by that unit (counted as a unit, not
    again here). The cgroup substring match is safe — unit names are
    specific (e.g. `pi-issue@fleet-ops-957.service`) and appear verbatim in
    the cgroup path. MainPID-only dedup would miss these because the pi
    proc is a CHILD of the unit's `timeout` MainPID, not the MainPID itself.
    """
    pids = []
    try:
        entries = os.listdir("/proc")
    except OSError:
        return 0
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            raw = Path(f"/proc/{entry}/cmdline").read_bytes()
        except OSError:
            continue
        if not raw:
            continue
        argv = raw.split(b"\x00")
        if argv and argv[-1] == b"":
            argv = argv[:-1]
        argv_s = [a.decode("utf-8", "replace") for a in argv]
        if "--print" not in argv_s or "--provider" not in argv_s:
            continue
        if not any(a == "pi" or a.endswith("/pi") for a in argv_s):
            continue
        pids.append(entry)
    if not pids:
        return 0
    standalone = 0
    for pid in pids:
        try:
            cg = Path(f"/proc/{pid}/cgroup").read_text()
        except OSError:
            cg = ""
        in_unit = any(u and u in cg for u in unit_names)
        if not in_unit:
            standalone += 1
    return standalone


def _maintenance_quiescing():
    """1 during the weekly maintenance window (or any manual quiesce), else 0.

    Reads agent-state/maintenance.json — the SAME flag vps-maintenance-quiesce
    sets (status "quiescing") and the resume/deadman clears (status "clear").
    This is the authoritative window signal, not a hardcoded schedule: it
    tracks the real window including dead-man extensions or manual windows.

    The weekly window (Sun 03:15 IST, flag expiry +75 min) stops timers but
    leaves in-flight workers running, so workers drain below 2 for well over
    30 min — the `for: 30m` alone does NOT absorb it. This gate does.

    Missing/unparseable file → 0 (NOT quiescing). That fails SAFE toward
    alerting: a missing flag must never silently suppress the guard. The
    30m `for` absorbs the exporter's 5-min tick lag at window open.
    """
    try:
        d = json.loads(MAINTENANCE_FLAG.read_text())
    except (OSError, json.JSONDecodeError):
        return 0
    return 0 if (d.get("status") == "clear") else 1


def _keystone_routing_counts():
    """Cumulative routed/escalated counts + ledger mtime (fleet-ops#1133).

    The keystone routing ledger is JSONL written by seat-lib's
    keystone_record_event. Each line is one event. We count by `event`
    field so the counters are cumulative across the whole ledger life.

    Returns (routed, escalated, mtime_epoch) or (0, 0, None) if the ledger
    is missing/unreadable. A None mtime is the absent() signal — the
    heartbeat gauge is omitted entirely so FleetKeystoneRoutingAbsent fires.
    """
    try:
        st = KEYSTONE_LEDGER.stat()
        text = KEYSTONE_LEDGER.read_text()
    except OSError:
        return 0, 0, None
    routed = 0
    escalated = 0
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line).get("event")
        except json.JSONDecodeError:
            continue
        if ev == "routed":
            routed += 1
        elif ev == "escalated":
            escalated += 1
    return routed, escalated, st.st_mtime


# --- Self-maintenance + PR quality (fleet-ops#1136) ------------------------

# Conventional-commit prefix -> quality class. The issue's "to start" heuristic:
#   feat       -> upgrade  (new forward capability)
#   fix, test  -> repair   (fixing / bulletproofing existing behaviour)
#   chore      -> churn    (no forward value)
#   everything else -> churn (refine later; churn is the safe catch-all so an
#                       unclassified merge never inflates 'upgrade').
# A bare title with no prefix (e.g. "Update foo.py") also lands in churn.
_QUALITY_PREFIX = {
    "feat": "upgrade",
    "fix": "repair",
    "test": "repair",
    "chore": "churn",
}
# Match the leading type token of a conventional-commit title:
#   "feat(scope): ...", "fix!: ...", "chore: ...", "Feat: ..." (case-insensitive).
# An optional scope in parens and a '!' for a breaking change are tolerated.
_PREFIX_RE = re.compile(r"^\s*([A-Za-z]+)(?:\([^)]*\))?\s*!?\s*:")


def _classify_title(title):
    """Return 'upgrade' | 'repair' | 'churn' for a merged-PR title."""
    m = _PREFIX_RE.match(title or "")
    if not m:
        return "churn"
    return _QUALITY_PREFIX.get(m.group(1).lower(), "churn")


def _self_maintenance_repos():
    """Return a set of 'Nishfleet/<name>' slugs that count as self-maintenance.

    Reads config/self-maintenance-repos.json (PR-tunable). Falls back to
    {"Nishfleet/fleet-ops"} when the file is missing/unparseable — fleet-ops
    IS the tooling/control-plane repo, so the default is never an empty set
    (an empty set would silently report 0% self-maintenance).
    """
    for path in (SELF_MAINT_JSON_DEFAULT, SELF_MAINT_JSON_FALLBACK):
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        repos = data.get("repos") or []
        if not isinstance(repos, list):
            continue
        out = set()
        for name in repos:
            if isinstance(name, str) and name:
                out.add("Nishfleet/" + name)
        if out:
            return out
    return {"Nishfleet/" + r for r in SELF_MAINT_DEFAULT_SET}


def _self_maintenance_and_quality(detail):
    """Derive self-maintenance counts + ratio and quality counts + shares.

    Input: list of {"repo": "Nishfleet/<name>", "title": "..."} from
    _merged_prs_detail(). Returns a dict:
      {"self": n, "product": n, "total": n, "ratio": float|None,
       "quality": {"upgrade": n, "repair": n, "churn": n},
       "share":   {"upgrade": f|None, "repair": f|None, "churn": f|None}}
    ratio/share are None when total == 0 (caller omits those gauges).
    """
    self_repos = _self_maintenance_repos()
    self_n = product_n = 0
    quality = {"upgrade": 0, "repair": 0, "churn": 0}
    for row in detail or []:
        repo = row.get("repo") or ""
        if repo in self_repos:
            self_n += 1
        else:
            product_n += 1
        quality[_classify_title(row.get("title") or "")] += 1
    total = self_n + product_n
    ratio = (self_n / total) if total > 0 else None
    share = {}
    for cls in ("upgrade", "repair", "churn"):
        share[cls] = (quality[cls] / total) if total > 0 else None
    return {
        "self": self_n,
        "product": product_n,
        "total": total,
        "ratio": ratio,
        "quality": quality,
        "share": share,
    }


# --- Verified-merges numerator (fleet-ops#1136 objective decision) ---------

# Delivery-evidence detection — SAME cues as lib/exec-review-receipt.py
# (the closure-evidence detector whose fixes 0509#1365 landed). Inlined here
# so the exporter stays stdlib-only with no repo-checkout import dependency;
# the canonical detector remains lib/exec-review-receipt.py and these regexes
# are kept in lock-step with it. A body has a receipt when EITHER:
#   1. a `run-proof:` line with a non-empty value, OR
#   2. a Verification: section (heading / bold / inline) carrying a run-cue:
#      journalctl, systemctl, http(s)://, exit N, rc=N, a fenced code block,
#      ALL PHASES PASSED, a `$ ` prompt line, or `ok: N`.
_RUN_PROOF_RE = re.compile(r"^[\t ]*run-proof:[\t ]+\S+", re.M)
_VERIFICATION_RE = re.compile(
    r"(?:^#+\s+[Vv]erification:?[\t ]*\*?[\t ]*$"
    r"|\*{2}[\t ]*[Vv]erification:?[\t ]*\*{0,2}[\t ]*$"
    r"|(?:^|[\t ])[Vv]erification:[\t ]*)"
)
_JOURNALCTL_RE = re.compile(r"(^|[^A-Za-z0-9_])journalctl([^A-Za-z0-9_]|$)")
_SYSTEMCTL_RE = re.compile(r"(^|[^A-Za-z0-9_])systemctl([^A-Za-z0-9_]|$)")
_EXIT_RE = re.compile(r"exit[\t ]+[0-9]")
_RC_RE = re.compile(r"rc=[0-9]")
_PROMPT_RE = re.compile(r"^[\t ]*\$ ")
_OK_N_RE = re.compile(r"ok: [0-9]")


def _has_delivery_evidence(body):
    """True when a PR body carries a run-proof: line or a Verification: run-cue.

    Mirrors lib/exec-review-receipt.py:has_receipt exactly (fleet-ops#1136
    objective decision: delivery evidence on closure, per 0509#1365's fixes).
    """
    text = body or ""
    if _RUN_PROOF_RE.search(text):
        return True
    in_v = False
    for line in text.splitlines():
        if _VERIFICATION_RE.search(line):
            in_v = True
        if not in_v:
            continue
        if (
            _JOURNALCTL_RE.search(line)
            or _SYSTEMCTL_RE.search(line)
            or "http://" in line
            or "https://" in line
            or _EXIT_RE.search(line)
            or _RC_RE.search(line)
            or "```" in line
            or "ALL PHASES PASSED" in line
            or _PROMPT_RE.match(line)
            or _OK_N_RE.search(line)
        ):
            return True
    return False


def _verified_merges(detail):
    """Derive the verified-merges numerator (fleet-ops#1136 objective decision).

    A merged PR is "verified" when it passes BOTH gates:
      (a) non-null effective diff — additions + deletions > 0 (a squash that
          landed no net change is a null diff).
      (b) delivery evidence on closure — _has_delivery_evidence(body).
    Input: list of {"repo", "title", "body", "additions", "deletions",
    "changed_files"} from _merged_prs_detail(). Returns:
      {"verified": n, "unverified": n, "total": n, "ratio": float|None}
    ratio is None when total == 0 (caller omits the gauge).
    """
    verified = unverified = 0
    for row in detail or []:
        adds = int(row.get("additions") or 0)
        dels = int(row.get("deletions") or 0)
        non_null_diff = (adds + dels) > 0
        evidence = _has_delivery_evidence(row.get("body") or "")
        if non_null_diff and evidence:
            verified += 1
        else:
            unverified += 1
    total = verified + unverified
    ratio = (verified / total) if total > 0 else None
    return {
        "verified": verified,
        "unverified": unverified,
        "total": total,
        "ratio": ratio,
    }


# --- Main ------------------------------------------------------------------

def main():
    timers = _list_timers()
    healthy, observed_epoch = _read_seat()

    lines = [HELP_LT, TYPE_LT]
    for t in timers:
        unit = t["unit"]
        if t["last_usec"] > 0:
            sec = t["last_usec"] // 1_000_000
            lines.append(
                f'fleet_timer_last_trigger_seconds{{timer="{unit}"}} {sec}'
            )
    lines.append("")
    lines.append(HELP_ACT)
    lines.append(TYPE_ACT)
    for t in timers:
        unit = t["unit"]
        lines.append(
            f'fleet_timer_active{{timer="{unit}"}} {_timer_active(unit)}'
        )
    lines.append("")
    lines.append(HELP_HEALTH)
    lines.append(TYPE_HEALTH)
    lines.append(f"fleet_pi_seat_healthy {healthy}")
    if observed_epoch is not None:
        lines.append("")
        lines.append(HELP_OBS)
        lines.append(TYPE_OBS)
        lines.append(
            f"fleet_pi_seat_observed_seconds {observed_epoch}"
        )
    # fleet-ops#1445: surface dead-credential seats once per tick as a distinct
    # signal. These seats are seat_dead=true + credentials_bad (HTTP 401/403)
    # and need human re-auth; the total gauge drives the alert rule and the
    # per-seat series names each seat needing re-auth.
    _dc_n, _dc = _read_dead_credentials()
    lines.append("")
    lines.append(HELP_DCT)
    lines.append(TYPE_DCT)
    lines.append(f"fleet_pi_seat_dead_credential_total {_dc_n}")
    lines.append("")
    lines.append(HELP_DC)
    lines.append(TYPE_DC)
    for _s in _dc:
        _seat_label = _prom_label(
            "{}__{}".format(_s["provider"], _s["model"]).strip("_") or "unknown"
        )
        _st = _prom_label(str(_s.get("http_status") or ""))
        lines.append(
            f'fleet_pi_seat_dead_credential{{seat="{_seat_label}",http_status="{_st}"}} 1'
        )
    lines.append("")
    lines.append(HELP_TEST)
    lines.append(TYPE_TEST)
    lines.append(
        f"fleet_test_alert {1 if TEST_ALERT_FILE.exists() else 0}"
    )

    # --- GitHub rate limit (fleet-ops#1350) ---
    # Emitted BEFORE the merged-PR family so the throttle (which gates
    # pi-intake-tick.sh claims) has a fresh value when the next tick fires.
    # The family is omitted entirely on failure; the heartbeat gauge is
    # always emitted when the family emits, so FleetGhRateLimitAbsent
    # catches a dead path, not a quiet day.
    rl = _gh_rate_limit()
    if rl is not None:
        lines.append("")
        lines.append(HELP_GHRL)
        lines.append(TYPE_GHRL)
        lines.append(HELP_GHRLIM)
        lines.append(TYPE_GHRLIM)
        lines.append(HELP_GHRSET)
        lines.append(TYPE_GHRSET)
        lines.append(HELP_GHLOW)
        lines.append(TYPE_GHLOW)
        for r in GH_RATE_LIMIT_RESOURCES:
            row = rl.get(r)
            if row is None:
                continue
            lines.append(
                f'fleet_gh_rate_limit_remaining{{resource="{_prom_label(r)}"}} {row["remaining"]}'
            )
            lines.append(
                f'fleet_gh_rate_limit_limit{{resource="{_prom_label(r)}"}} {row["limit"]}'
            )
            lines.append(
                f'fleet_gh_rate_limit_reset{{resource="{_prom_label(r)}"}} {row["reset"]}'
            )
            lines.append(
                f'fleet_gh_rate_limit_low{{resource="{_prom_label(r)}"}} {row["low"]}'
            )
        lines.append("")
        lines.append(HELP_GHFT)
        lines.append(TYPE_GHFT)
        lines.append(f"fleet_gh_rate_limit_fetched_seconds {time.time():.3f}")
        # Side-car state file for pi-intake-tick.sh throttle (fleet-ops#1350).
        # The throttle needs a non-Prometheus-readable view: a single bool
        # and the smallest of remaining/limit across the consumed resources.
        # Written atomically (temp + rename) so a concurrent tick never
        # reads a half-written JSON. Missing or unparseable → tick treats
        # the gate as undecided and proceeds (fail-open), never blocking
        # the fleet on a stale file.
        _write_gh_rate_limit_state(rl)

    # --- Self-observation ---
    # gh-derived families are omitted entirely if gh fails AND cache is >2h.
    fresh_kinds = []
    # fleet-ops#1136: fetch the detailed merged-PR records ONCE; the per-repo
    # family, the self-maintenance ratio, and the upgrade/repair/churn
    # classification all derive from this single fetch (one gh call/run).
    detail = _merged_prs_detail()
    pr_counts = None
    if detail is not None:
        pr_counts = dict(Counter(r["repo"] for r in detail))
    if pr_counts is not None:
        lines.append("")
        lines.append(HELP_MPR)
        lines.append(TYPE_MPR)
        for repo in sorted(pr_counts):
            lines.append(
                f'fleet_merged_prs_24h{{repo="{_prom_label(repo)}"}} {pr_counts[repo]}'
            )
        fresh_kinds.append("merged_prs")

        # --- Self-maintenance + PR quality (fleet-ops#1136) ---
        # Always emitted when the merged-PR fetch succeeded (even on a
        # no-merge day: counts are 0, ratio/share omitted). The
        # kind="total" gauge is the organ heartbeat for FleetSelfMaintenanceAbsent.
        sm = _self_maintenance_and_quality(detail)
        lines.append("")
        lines.append(HELP_SM)
        lines.append(TYPE_SM)
        lines.append(f'fleet_self_maintenance_merges{{kind="self"}} {sm["self"]}')
        lines.append(f'fleet_self_maintenance_merges{{kind="product"}} {sm["product"]}')
        lines.append(f'fleet_self_maintenance_merges{{kind="total"}} {sm["total"]}')
        if sm["ratio"] is not None:
            lines.append("")
            lines.append(HELP_SMR)
            lines.append(TYPE_SMR)
            lines.append(f"fleet_self_maintenance_ratio {sm['ratio']:.6f}")
        lines.append("")
        lines.append(HELP_PQ)
        lines.append(TYPE_PQ)
        for cls in ("upgrade", "repair", "churn"):
            lines.append(
                f'fleet_pr_quality_24h{{class="{cls}"}} {sm["quality"][cls]}'
            )
        if sm["total"] > 0:
            lines.append("")
            lines.append(HELP_PQS)
            lines.append(TYPE_PQS)
            for cls in ("upgrade", "repair", "churn"):
                lines.append(
                    f'fleet_pr_quality_share{{class="{cls}"}} {sm['share'][cls]:.6f}'
                )

        # --- Verified-merges numerator (fleet-ops#1136 objective decision) ---
        # A merged PR is verified when it has a non-null effective diff AND
        # delivery evidence on closure. Raw merge counts stay on the console;
        # the WFR ratchets against this verified number. Always emitted when
        # the merged-PR fetch succeeded (counts 0 on a no-merge day; ratio
        # omitted). kind="total" mirrors the self-maintenance heartbeat shape.
        vm = _verified_merges(detail)
        lines.append("")
        lines.append(HELP_VM)
        lines.append(TYPE_VM)
        lines.append(f'fleet_verified_merges_24h{{kind="verified"}} {vm["verified"]}')
        lines.append(f'fleet_verified_merges_24h{{kind="unverified"}} {vm["unverified"]}')
        lines.append(f'fleet_verified_merges_24h{{kind="total"}} {vm["total"]}')
        if vm["ratio"] is not None:
            lines.append("")
            lines.append(HELP_VMR)
            lines.append(TYPE_VMR)
            lines.append(f"fleet_verified_merge_ratio {vm['ratio']:.6f}")

    snap = _repo_snapshot()
    if snap is not None:
        open_prs = snap.get("open_prs") or {}
        main_ci = snap.get("main_ci") or {}
        lines.append("")
        lines.append(HELP_OPEN)
        lines.append(TYPE_OPEN)
        for repo in sorted(open_prs):
            lines.append(
                f'fleet_open_prs{{repo="{_prom_label(repo)}"}} {open_prs[repo]}'
            )
        lines.append("")
        lines.append(HELP_CI)
        lines.append(TYPE_CI)
        for repo in sorted(main_ci):
            lines.append(
                f'fleet_main_ci_green{{repo="{_prom_label(repo)}"}} {main_ci[repo]}'
            )
        fresh_kinds.append("repo_snapshot")

    # --- Ready work + queue composition (fleet-ops#1136, #1772) ---
    # Both share one cached gh call. If we cannot determine the open
    # agent-ready count, fail loud instead of writing a fleet.prom that
    # omits fleet_ready_work and makes the frozen-queue gate see null.
    qc = _queue_composition()
    if qc is None:
        print(
            f"ready_work: cannot determine open agent-ready issue count; "
            f"refusing to write {OUT} so the frozen-queue gate does not see a "
            f"null/frozen value",
            file=sys.stderr,
        )
        return 1

    ready = qc["ready-work"]["total"]
    lines.append("")
    lines.append(HELP_READY)
    lines.append(TYPE_READY)
    lines.append(f"fleet_ready_work {ready}")
    fresh_kinds.append("ready_work")

    # Queue composition: "agent-ready" (all Nishfleet repos) and "ready-work"
    # (enrolled repos only). Both export total, self-maintenance count, and
    # ratio (omitted when total=0). The 64% fleet2 death-number tripwire
    # is a TREND alert (offset 7d), not a level.
    # HELP/TYPE is emitted once per metric name; the per-queue samples
    # follow. Duplicate HELP/TYPE lines make the textfile unparseable
    # (promtool rejects them), so they must stay outside the loop.
    lines.append("")
    lines.append(HELP_QT)
    lines.append(TYPE_QT)
    for queue in ("agent-ready", "ready-work"):
        lines.append(
            f'fleet_queue_total{{queue="{queue}"}} {qc[queue]["total"]}'
        )
    lines.append("")
    lines.append(HELP_QSM)
    lines.append(TYPE_QSM)
    for queue in ("agent-ready", "ready-work"):
        lines.append(
            f'fleet_queue_self_maintenance_total{{queue="{queue}"}} {qc[queue]["self"]}'
        )
    ratio_lines = []
    for queue in ("agent-ready", "ready-work"):
        q = qc[queue]
        total = q["total"]
        if total > 0:
            ratio = q["self"] / total
            ratio_lines.append(
                f'fleet_queue_self_maintenance_ratio{{queue="{queue}"}} {ratio:.6f}'
            )
    if ratio_lines:
        lines.append("")
        lines.append(HELP_QSMR)
        lines.append(TYPE_QSMR)
        lines.extend(ratio_lines)
    fresh_kinds.append("queue_composition")

    if fresh_kinds:
        lines.append("")
        lines.append(HELP_FRESH)
        lines.append(TYPE_FRESH)
        for kind in fresh_kinds:
            lines.append(f'fleet_gh_cache_fresh{{kind="{kind}"}} 1')

    # Escalations per unit (top 20).
    esc_counts = _escalations_24h()
    lines.append("")
    lines.append(HELP_ESC)
    lines.append(TYPE_ESC)
    for unit in sorted(esc_counts):
        lines.append(
            f'fleet_escalations_24h{{unit="{unit}"}} {esc_counts[unit]}'
        )

    # Repair dispatch / skip counts.
    disp_count, skip_count = _repair_log_counts_24h()
    lines.append("")
    lines.append(HELP_RDISP)
    lines.append(TYPE_RDISP)
    lines.append(f"fleet_repair_dispatch_24h {disp_count}")
    lines.append("")
    lines.append(HELP_RSKIP)
    lines.append(TYPE_RSKIP)
    lines.append(f"fleet_repair_skip_24h {skip_count}")

    # --- Undersaturation guard (2026-08-27) ---
    # fleet_pi_workers_active{kind=...} — always exported (no gh, no journal).
    # unit = active+activating pi-*/alert-repair-* services; process =
    # standalone `pi --print` PIDs not inside one of those units (cgroup
    # dedup); sum = unit + process (the FleetUndersaturated rule's input).
    wunits = _worker_units()
    unit_count = len(wunits)
    process_count = _standalone_pi_print_count(wunits)
    sum_count = unit_count + process_count
    lines.append("")
    lines.append(HELP_WACT)
    lines.append(TYPE_WACT)
    lines.append(f'fleet_pi_workers_active{{kind="unit"}} {unit_count}')
    lines.append(f'fleet_pi_workers_active{{kind="process"}} {process_count}')
    lines.append(f'fleet_pi_workers_active{{kind="sum"}} {sum_count}')

    # fleet_maintenance_quiescing — gates FleetUndersaturated during the
    # weekly maintenance window (see _maintenance_quiescing).
    lines.append("")
    lines.append(HELP_MAINT)
    lines.append(TYPE_MAINT)
    lines.append(f"fleet_maintenance_quiescing {_maintenance_quiescing()}")

    # --- Keystone routing (fleet-ops#1133) ---
    # Counters are always exported (0 when the ledger is empty/missing — a
    # brand-new install has routed nothing yet, and that is a valid 0). The
    # heartbeat gauge is OMITTED when the ledger is missing so the
    # FleetKeystoneRoutingAbsent absent() rule fires: the metric's PRESENCE
    # is the health signal, not its value. Mirrors FleetMetricsExportMissing.
    k_routed, k_escalated, k_mtime = _keystone_routing_counts()
    lines.append("")
    lines.append(HELP_KROUTE)
    lines.append(TYPE_KROUTE)
    lines.append(f"fleet_keystone_routed_total {k_routed}")
    lines.append("")
    lines.append(HELP_KESC)
    lines.append(TYPE_KESC)
    lines.append(f"fleet_keystone_escalated_total {k_escalated}")
    if k_mtime is not None:
        lines.append("")
        lines.append(HELP_KHB)
        lines.append(TYPE_KHB)
        lines.append(f"fleet_keystone_routing_heartbeat_seconds {k_mtime:.3f}")

    # --- Truth staleness (fleet-ops#1137) ---
    # Read the staleness checker's cached results and re-export as Prometheus
    # gauges so the absent() rule in fleet_rules.yml can watch them. The
    # checker writes to the same fleet.prom textfile via ExecStartPost; we
    # re-read it for completeness (idempotent — duplicate gauges are OK
    # because they have identical values).
    try:
        stale_data, stale_age = _read_cache(STALENESS_CACHE)
        if stale_data is not None:
            ts_run = stale_data.get("ts", 0)
            total_claims = stale_data.get("total_claims", 0)
            lines.append("")
            lines.append(HELP_TS_LRUN)
            lines.append(TYPE_TS_LRUN)
            lines.append(f"fleet_truth_staleness_last_run_seconds {ts_run:.3f}")
            lines.append("")
            lines.append(HELP_TS_CLAIMS)
            lines.append(TYPE_TS_CLAIMS)
            lines.append(f"fleet_truth_staleness_total_claims {total_claims}")
            lines.append("")
            lines.append(HELP_TS_MISS)
            lines.append(TYPE_TS_MISS)
            kind_counts = Counter(
                f.get("type", "unknown")
                for f in (stale_data.get("findings") or [])
            )
            for kind in ("path", "unit", "issue"):
                lines.append(
                    f'fleet_truth_staleness_mismatches_by_kind{{kind="{_prom_label(kind)}"}} '
                    f'{kind_counts.get(kind, 0)}'
                )
    except OSError as exc:
        print(f"staleness cache read: {exc}", file=sys.stderr)

    body = "\n".join(lines) + "\n"
    _atomic_write(OUT, body)
    print(
        f"wrote {OUT} ({len(timers)} timers, seat_healthy={healthy})",
        file=sys.stderr,
    )

    # Healthcheck ping is watchdog-gated (see _ping_healthcheck). Ping
    # failures are non-fatal to the metric write — the branch/status is
    # logged inside _ping_healthcheck.
    _ping_healthcheck()

    return 0


if __name__ == "__main__":
    sys.exit(main())
