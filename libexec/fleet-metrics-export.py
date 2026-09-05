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
import urllib.parse
import urllib.request
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

# --- Config ----------------------------------------------------------------

def _ensure_worker_token() -> None:
    """Use the nishfleet-worker App token for any GitHub write (fleet-ops#3445).

    Fail closed if the App cannot mint and no token was inherited from a parent
    organ, so a dead App never falls through to the human gh identity. Human gh
    is read-only for organs. GH Actions (tests) has no App creds and stubs gh
    as read-only, so skip minting there.
    """
    if os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_ACTIONS") == "true":
        return
    wt = os.environ.get(
        "NISHFLEET_WORKER_TOKEN_BIN",
        f"{os.environ.get('HOME', '/home/nish')}/.local/bin/worker-token",
    )
    try:
        out = subprocess.run(
            [wt, "--print"], capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("fleet-ops#3445: worker-token --print failed - refusing human-gh writes: %s" % exc, file=sys.stderr)
        sys.exit(1)
    if out.returncode != 0:
        print("fleet-ops#3445: worker-token --print rc=%s - refusing human-gh writes: %s" % (out.returncode, out.stderr.strip()[:200]), file=sys.stderr)
        sys.exit(1)
    for line in out.stdout.splitlines():
        if line.startswith("export GH_TOKEN="):
            os.environ["GH_TOKEN"] = line[len("export GH_TOKEN="):].strip()
            return
    print("fleet-ops#3445: worker-token --print output not an export GH_TOKEN line - refusing human-gh writes", file=sys.stderr)
    sys.exit(1)

# --- Config ----------------------------------------------------------------

OUT = Path("/var/lib/prometheus/node-exporter/fleet.prom")
# fleet-ops#2273: legacy stale textfile left behind when staleness-checker.py
# was refactored (a639520) to stop writing fleet-staleness.prom. node_exporter
# reads ALL .prom files in the textfile dir, so the stale file's duplicate
# fleet_truth_staleness_* metrics shadow the fresh values in fleet.prom.
# This path is the cleanup target — removed atomically when fleet.prom is
# (re)written, so the duplicate can never reappear.
LEGACY_STALENESS_PROM = OUT.parent / "fleet-staleness.prom"
SEAT_HEALTH = Path(
    "/home/nish/workspaces/agent-state/lanes/pi-seat-health.json"
)
# Per-seat health ledger written by the pi seat-health extension. Each file is
# <sanitised-provider>__<sanitised-model>.json. We scan it to surface
# dead-credential seats (seat_dead=true, credentials_bad) as a distinct
# heartbeat signal (fleet-ops#1445) instead of them being buried in
# pick_seat's per-pick cap/dead fold or silently re-logged every cycle.
# fleet-ops#2667: the credentials_bad signal lives in health_class OR in
# failure_mode — see _read_dead_credentials for why both must be read.
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
# fleet-ops#3111: a stale pi-seat-health.json must read as UNKNOWN, never
# "healthy". The 2026-09-03 incident left the console tile saying "seat
# healthy" from a 2-day-old observation while the transport was down 33h.
# Age in seconds since observed_at; absent/unparseable -> -1 (UNKNOWN). The
# alert rule fires >1800 (30 min) so a stale feed can never mask an outage.
HELP_AGE = "# HELP fleet_pi_seat_health_age_seconds Seconds since the Pi seat was last observed (-1 if the observation is absent/unparseable). fleet-ops#3111."
TYPE_AGE = "# TYPE fleet_pi_seat_health_age_seconds gauge"
HELP_SEAT_TOTAL = "# HELP fleet_pi_seat_total Number of enrolled seats (providers with cap>0 in seat-caps.json). Denominator for the seat_availability SLO (fleet-ops#1291)."
TYPE_SEAT_TOTAL = "# TYPE fleet_pi_seat_total gauge"
HELP_DCT = "# HELP fleet_pi_seat_dead_credential_total Number of enrolled (model cap>0) seats with seat_dead=true carrying a credentials_bad signal in health_class or failure_mode (HTTP 401/403) that will not recover on their own (fleet-ops#1445, fleet-ops#2667, fleet-ops#3301)."
TYPE_DCT = "# TYPE fleet_pi_seat_dead_credential_total gauge"
HELP_DC = "# HELP fleet_pi_seat_dead_credential 1 for each dead-credential seat; health_class=credentials_bad means re-auth may help, health_class=corpse means the seat is terminal and must be retired from config/seat-caps.json (fleet-ops#1445, fleet-ops#2667)."
TYPE_DC = "# TYPE fleet_pi_seat_dead_credential gauge"
HELP_CB = "# HELP fleet_seat_comeback_overdue_total Number of seats still classed non-healthy whose wall clock (usable_at/bench_until) has passed — released by the router but not re-observed since (fleet-ops#2407)."
TYPE_CB = "# TYPE fleet_seat_comeback_overdue_total gauge"
HELP_CBP = "# HELP fleet_seat_comeback_overdue 1 for each seat whose wall clock has passed but is still classed non-healthy (fleet-ops#2407)."
TYPE_CBP = "# TYPE fleet_seat_comeback_overdue gauge"
# fleet-ops#2638: never-probed comeback visibility. Counts seats the prober
# has been failing on (consecutive_failure_count >= 10) without yet reaching
# the corpse threshold (default 25). Sustained > 0 here is the loud signal
# that the release path is firing but the seat still cannot recover — the
# next sweep should corpse it. Combined with fleet_seat_comeback_overdue_total
# it tells the repair worker which overdue seats are approaching the corpse
# boundary before the bin has actually written the corpse.
HELP_NRT = "# HELP fleet_seat_comeback_never_released_total Number of seats the comeback-release prober has been failing on (consecutive_failure_count in [10, SEAT_DEAD_CONSECUTIVE_THRESHOLD)) that are not yet corpse — the never-probed comeback visibility (fleet-ops#2638)."
TYPE_NRT = "# TYPE fleet_seat_comeback_never_released_total gauge"
HELP_NRP = "# HELP fleet_seat_comeback_never_released 1 for each seat whose consecutive_failure_count is in the never-released window (fleet-ops#2638)."
TYPE_NRP = "# TYPE fleet_seat_comeback_never_released gauge"
# fleet-ops#2712: provider-level (account-level) quota exhaustion. A
# provider counts when >=2 of its seats report HTTP 402/health_class=
# quota_exhausted within a 1h window — one billing wall, many seats.
# Sustained > 0 here means the seat_availability SLO burn is account-
# level, not 3 independent seat faults.
HELP_PQE = "# HELP fleet_provider_quota_exhausted_total Number of providers with >=2 quota_exhausted seats observed in the last 1h — account-level quota exhaustion (fleet-ops#2712)."
TYPE_PQE = "# TYPE fleet_provider_quota_exhausted_total gauge"
HELP_PQEP = "# HELP fleet_provider_quota_exhausted 1 for each provider whose seats are account-level quota exhausted (fleet-ops#2712)."
TYPE_PQEP = "# TYPE fleet_provider_quota_exhausted gauge"
# fleet-ops#2738: healthy-but-parked visibility. A seat whose ledger reports
# health_class=healthy + seat_dead=false (the seat works) but whose model cap
# in seat-caps.json is 0 is silently costing throughput — pick_seat skips it
# every tick while the seat-availability SLO burns. The devin/glm-5-2 restore
# lapsed exactly this way: the ledger came back healthy, the cap stayed 0 for
# 3+ days. This gauge counts those seats so the WFR lens and the next
# blind-audit see them instead of a quiet depressed rollup. Sustained > 0
# here is the loud signal that a restore was forgotten.
HELP_HCAP0 = "# HELP fleet_seat_healthy_cap0_total Number of seats whose ledger is healthy (health_class=healthy, seat_dead=false) but whose model cap in seat-caps.json is 0 — healthy-but-parked, silently costing throughput (fleet-ops#2738)."
TYPE_HCAP0 = "# TYPE fleet_seat_healthy_cap0_total gauge"
HELP_HCAP0P = "# HELP fleet_seat_healthy_cap0 1 for each healthy-but-parked seat (health_class=healthy, seat_dead=false, model cap=0) so the repair worker knows which cap to restore (fleet-ops#2738)."
TYPE_HCAP0P = "# TYPE fleet_seat_healthy_cap0 gauge"
# fleet-ops#3111: stale cap=0 seats (intentional_cap_zero="stale") that have
# not been re-auditioned. The 2026-09-03 incident showed groq/inferx/orcarouter
# lingering at cap=0 for weeks while the fleet starved. The age is parsed from
# the first YYYY-MM-DD in the reason; -1 if no date (undated = expires first).
# seat-lib's _expire_stale_cap0_seats re-admits them at cap=1 after 14d; this
# metric makes them visible BEFORE the expiry so the operator can re-audition
# or re-date the reason.
HELP_SC0T = "# HELP fleet_seat_cap0_stale_total Number of cap=0 seats classified stale (intentional_cap_zero=stale) — need re-audition or will auto-expire to cap=1 after 14d (fleet-ops#3111)."
TYPE_SC0T = "# TYPE fleet_seat_cap0_stale_total gauge"
HELP_SC0 = "# HELP fleet_seat_cap0_stale 1 for each stale cap=0 seat, with age_seconds since the reason date (-1 if undated) so the repair worker knows which to re-audition first (fleet-ops#3111)."
TYPE_SC0 = "# TYPE fleet_seat_cap0_stale gauge"
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
HELP_AD = "# HELP fleet_alert_outcome_24h Per-alertname repair outcomes in the trailing 24h (fleet-ops#1291 alert-quality). kind=dispatch|resolved|failed|skipped|phantom_resolved. phantom_resolved = RESOLVED entries whose root_cause starts with PHANTOM_ALERT (drill fixtures, not real repair work) — the WFR alert-quality lens reads phantom_resolved>5/24h as phantom-drift regression (fleet-ops#2694). Feeds the WFR alert-quality lens."
TYPE_AD = "# TYPE fleet_alert_outcome_24h gauge"
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
# The 64% tripwire (fleet2 death-number) is a LEVEL held above 0.64,
# smoothed over the trailing 7 days (avg_over_time[7d]) so momentary dips
# and export gaps cannot reset it (fleet-ops#2171).
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
# fleet-ops#1291: SLO definitions (single source of truth for targets,
# windows, ratchet params, metric sources). The exporter reads this and
# emits fleet_slo_* gauges; lib/slo_budget.py does the budget math.
SLO_DEFS_DEFAULT = Path(
    "/home/nish/workspaces/tooling/fleet-ops/config/slo-definitions.json"
)
SLO_DEFS_FALLBACK = Path(
    "/home/nish/workspaces/products/fleet-ops/config/slo-definitions.json"
)
# fleet-ops#3367: fallback SLO IDs used when slo-definitions.json is
# missing/unparseable. _emit_slo_metrics MUST emit a fresh
# fleet_slo_instrumented=0 for every known SLO on a config failure so
# Prometheus does not retain stale instrumented=1 + compliance gauges from
# the previous run — a stale SLO gauge alongside a fresh fleet_main_ci_green
# is the real disagreement source (the docstring already promised this but
# the code returned without emitting any gauges). Keep in sync with the
# "slos" array in config/slo-definitions.json.
_KNOWN_SLO_IDS = (
    "main_green",
    "chain_repair_latency",
    "0509_user_journey",
    "digest_delivery",
    "waste_ratio",
    "seat_availability",
    "gh_rate_limit_headroom",
)
# fleet-waste-export writes fleet_waste_ratio here; the SLO emitter reads
# the live value rather than recomputing it (single source of truth).
WASTE_PROM = Path(
    os.environ.get(
        "FLEET_WASTE_OUT",
        "/var/lib/prometheus/node-exporter/fleet-waste.prom",
    )
)
# fleet-completion-canary writes fleet_chain_repair_duration_seconds here;
# the SLO emitter reads the live p95 value for chain_repair_latency.
CHAIN_PROM = Path(
    os.environ.get(
        "FLEET_CHAIN_PROM",
        "/var/lib/prometheus/node-exporter/fleet-chains.prom",
    )
)
# seat-caps.json is the source of truth for enrolled-seat count
# (fleet_pi_seat_total) — providers with cap>0 are enrolled.
SEAT_CAPS_DEFAULT = Path(
    "/home/nish/workspaces/tooling/fleet-ops/config/seat-caps.json"
)
SEAT_CAPS_FALLBACK = Path(
    "/home/nish/workspaces/products/fleet-ops/config/seat-caps.json"
)
READY_CACHE = PR_CACHE_DIR / "ready-work-cache.json"
READY_GH_TIMEOUT = 45

# Queue composition caches (fleet-ops#1136 scope addition). Separate from
# READY_CACHE so the old int shape is not misread.
QUEUE_CACHE = PR_CACHE_DIR / "queue-composition-cache.json"
ALL_AGENT_READY_CACHE = PR_CACHE_DIR / "all-agent-ready-cache.json"

# --- Seat yield ledger (fleet-ops#3250) ---
# Pi issue-work sessions live here. Only pi-issue-* directories carry product
# work; scout/canary/audit roles use other dirs and keep their own routing.
SESSIONS_DIR = Path(
    os.environ.get("FLEET_SESSIONS_DIR", str(Path.home() / ".pi" / "agent" / "sessions"))
)
# Per-file parse cache so re-export ticks are cheap; keyed on file mtime seconds.
SEAT_YIELD_CACHE = PR_CACHE_DIR / "seat-yield-sessions-cache.json"
# JSON sidecar consumed by lib/seat-lib.sh pick_seat. Not a new organ; just a
# state file written by the existing fleet-metrics-export tick.
SEAT_YIELD_JSON = Path(
    os.environ.get(
        "FLEET_SEAT_YIELD_JSON",
        str(Path.home() / ".local" / "state" / "pi-packet" / "seat-yield.json"),
    )
)
SEAT_YIELD_WINDOW = 20
SEAT_YIELD_PROVISIONAL = 0.5
# Final assistant text contains a Nishfleet PR URL (http/s optional).
PR_URL_RE = re.compile(
    r"(?:https?://)?github\.com/Nishfleet/[^/\s\"]+/pull/\d+", re.IGNORECASE
)
HELP_SY = (
    "# HELP fleet_seat_yield Rolling last-20 issue-work sessions PR yield "
    "per seat (0..1). Seats with <20 sessions report a provisional 0.5 "
    "yield so new seats are tried (fleet-ops#3250)."
)
TYPE_SY = "# TYPE fleet_seat_yield gauge"
HELP_SNPR = (
    "# HELP fleet_sessions_no_pr_total Number of issue-work sessions in the "
    "last-20 window that did not produce a PR URL, per seat (fleet-ops#3250)."
)
TYPE_SNPR = "# TYPE fleet_sessions_no_pr_total gauge"

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
# fleet-ops#2690: push the 24h time filter into the search query and sort by
# merge time. The previous `sort:updated-desc` + client-side cutoff could
# exhaust the GH_PAGES×first=1000 pagination cap on stale-but-recently-updated
# PRs (issues that were merged > 24h ago but received any update activity —
# comments, labels, references — bubble to the top), which silently under-
# counts the 24h window. The console tile (sum(fleet_merged_prs_24h)) then
# disagreed with the verifier's spot gh search (REST `is:merged merged:>=`
# filter) and ConsoleLying fired on a lying tile that was actually a lying
# GraphQL. `merged:>=$cutoff sort:merged-desc` lets GitHub do the filtering
# and ordering so the result is bounded by the 24h window.
#
# The cutoff is interpolated as a literal in the search query STRING by
# _gh_merged_prs_raw — GraphQL does not expand variables inside the
# `search(query: "...")` string field, so passing it as a $-variable would
# not reach the GitHub search engine. cutoff_iso is generated server-side
# from a trusted system value, never user input.
MERGED_PRS_SEARCH_QUERY_TEMPLATE = """
query($cursor: String) {
  search(query: "org:Nishfleet is:pr is:merged merged:>={CUTOFF} sort:merged-desc", type: ISSUE, first: 100, after: $cursor) {
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
            # time.mktime interprets the tuple in the process local timezone,
            # so on a +05:30 host a fresh UTC observed_at parses ~5.5h in the
            # past and fires FleetPiSeatHealthStale (fleet-ops#3329). observed_at
            # is UTC: use calendar.timegm (the same pattern _parse_iso_utc and
            # the comeback-clock path already use) so the epoch is correct
            # regardless of TZ.
            epoch = int(
                calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
            )
        except ValueError:
            epoch = None
    return healthy, epoch


def _read_dead_credentials():
    """Scan the per-seat health ledger for dead-credential seats.

    A dead-credential seat is seat_dead=true carrying a credentials_bad signal
    (HTTP 401/403): it will never recover on its own (fleet-ops#1445). These are
    surfaced once per 5-min export tick as a distinct metric + alert, rather than
    being buried in pick_seat's per-pick "excluded ... dead: D" fold or re-logged
    every cycle by the seat loop.

    fleet-ops#2667: the credentials_bad signal lives in TWO fields, and matching
    only health_class made this metric blind exactly when it mattered most.
    seat-health.ts classifyHttpStatus maps 401/403 -> health_class
    "credentials_bad", but the fleet-ops#2327 corpse escalation then REWRITES
    health_class to the terminal "corpse" class while leaving
    failure_mode="credentials_bad" in place. A seat that has fully earned the
    alert — terminally dead on a 401/403 — therefore dropped out of a
    health_class-only match. Live proof 2026-09-02: the ledger held
    commandcode/minimax-m3-free (403) and opencode/hy3-free (401), both
    seat_dead=true + failure_mode=credentials_bad + health_class=corpse, while
    fleet_pi_seat_dead_credential_total read 0 and PiSeatDeadCredential could
    not fire. Four such seats accumulated unseen until a human noticed. Match
    EITHER field so the terminal class is visible, and carry health_class /
    failure_mode through to the caller for the per-seat series.

    fleet-ops#3301: only ENROLLED seats (model cap>0 in seat-caps.json) count.
    A cap=0 row is never picked, so a 401 on it is not a re-auth action — the
    2026-09-04T16:30Z snapshot paged FleetDeadCredentialSeats on
    opencode/hy3-free and opencode/x-preview-f-free, both already retired at
    cap=0, while the control seat (ling-3.0-flash-fin-free) was healthy. Fail
    open (count all) when seat-caps.json is unreadable so a genuinely dead
    enrolled seat still alerts.

    Returns (count, [ {provider, model, http_status, health_class,
    failure_mode}, ... ]). Always a (count, list) pair — never raises on a
    missing/unreadable ledger.
    """
    seats = []
    caps = _seat_caps_model_cap_map()
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
            if data.get("seat_dead") is not True:
                continue
            # fleet-ops#2667: EITHER field carries the credentials_bad signal.
            if "credentials_bad" not in (
                data.get("health_class"),
                data.get("failure_mode"),
            ):
                continue
            provider = data.get("provider", "") or ""
            model = data.get("model", "") or ""
            if caps is not None:
                cap = caps.get(f"{provider}/{model}", 0)
                if not (isinstance(cap, (int, float)) and not isinstance(cap, bool) and cap > 0):
                    continue
            seats.append({
                "provider": provider,
                "model": model,
                "http_status": data.get("http_status"),
                "health_class": data.get("health_class") or "",
                "failure_mode": data.get("failure_mode") or "",
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


def _extract_text(content):
    """Flatten assistant message content to plain text.

    Content may be a raw string or a list of objects. Only text objects
    are extracted; reasoning/thinking blocks are ignored.
    """
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for item in content or []:
        if isinstance(item, dict) and item.get("type") == "text" and isinstance(item.get("text"), str):
            parts.append(item["text"])
    return "".join(parts)


def _parse_session_file(path):
    """Return {seat, timestamp, has_pr_url} for a pi-issue session .jsonl.

    Seat is taken from the first model_change event; the timestamp is the
    session start time. A session counts as PR-producing if the final
    assistant message text contains a Nishfleet PR URL.
    """
    session_ts = None
    model_seat = None
    last_assistant_line = None
    fallback_ts = None
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                if session_ts is None and re.search(r'"type"\s*:\s*"session"', line):
                    try:
                        data = json.loads(line)
                        session_ts = data.get("timestamp")
                        # id is a fallback sort key; timestamps should be unique
                        # enough, but a stable id prevents ties.
                        fallback_ts = data.get("id", "")
                    except json.JSONDecodeError:
                        pass
                    continue
                if model_seat is None and re.search(r'"type"\s*:\s*"model_change"', line):
                    try:
                        data = json.loads(line)
                        provider = data.get("provider")
                        model = data.get("modelId")
                        if provider and model:
                            model_seat = f"{provider}/{model}"
                    except json.JSONDecodeError:
                        pass
                    continue
                if re.search(r'"role"\s*:\s*"assistant"', line):
                    last_assistant_line = line
    except OSError:
        return None
    if not model_seat:
        return None
    has_pr = False
    if last_assistant_line:
        try:
            data = json.loads(last_assistant_line)
            msg = data.get("message") or {}
            content = msg.get("content")
            text = _extract_text(content)
            if PR_URL_RE.search(text):
                has_pr = True
        except json.JSONDecodeError:
            pass
    ts_epoch = _parse_iso_utc(session_ts) if session_ts else None
    if ts_epoch is None:
        # If we cannot parse the ISO timestamp, keep ordering stable by falling
        # back to 0. This is rare (malformed session line) and safe: a bogus
        # session floats to the start of the window and is quickly evicted.
        ts_epoch = 0
    return {
        "seat": model_seat,
        "timestamp": ts_epoch,
        "has_pr_url": has_pr,
    }


def _compute_seat_yield():
    """Compute per-seat rolling last-20 issue-work session PR yield.

    Scans FLEET_SESSIONS_DIR/pi-issue-*/**/*.jsonl, caches per-file results
    by mtime, and returns {seat: {yield, sessions, pr_count, provisional}}.
    Also writes the JSON sidecar used by lib/seat-lib.sh pick_seat.
    """
    sessions_dir = Path(SESSIONS_DIR)
    if not sessions_dir.is_dir():
        return {}

    cache = {}
    try:
        data, _age = _read_cache(SEAT_YIELD_CACHE)
        if isinstance(data, dict) and data.get("v") == 1:
            cache = data.get("entries") or {}
    except (OSError, json.JSONDecodeError):
        pass

    new_cache = {}
    sessions = []
    for path in sessions_dir.glob("pi-issue-*/*.jsonl"):
        try:
            mtime_s = int(path.stat().st_mtime)
        except OSError:
            continue
        key = str(path)
        cached = cache.get(key)
        if isinstance(cached, dict) and cached.get("mtime_s") == mtime_s:
            entry = {
                "seat": cached["seat"],
                "timestamp": cached["timestamp"],
                "has_pr_url": cached["has_pr_url"],
            }
        else:
            entry = _parse_session_file(path)
            if entry is None:
                continue
        new_cache[key] = {
            "mtime_s": mtime_s,
            "seat": entry["seat"],
            "timestamp": entry["timestamp"],
            "has_pr_url": entry["has_pr_url"],
        }
        sessions.append(entry)

    try:
        _write_cache(SEAT_YIELD_CACHE, {"v": 1, "entries": new_cache})
    except OSError:
        pass

    # Group by seat, then fold in the cap-map allowlist so new/idle seats get
    # a provisional 0.5 entry in the JSON/metrics.
    by_seat = {}
    for e in sessions:
        by_seat.setdefault(e["seat"], []).append(e)

    known_caps = _seat_caps_model_cap_map()
    if known_caps:
        for seat, cap in known_caps.items():
            if cap > 0 and seat not in by_seat:
                by_seat[seat] = []

    result = {}
    for seat, entries in by_seat.items():
        entries.sort(key=lambda x: x["timestamp"], reverse=True)
        window = entries[:SEAT_YIELD_WINDOW]
        total = len(window)
        pr_count = sum(1 for e in window if e["has_pr_url"])
        no_pr = total - pr_count
        if total < SEAT_YIELD_WINDOW:
            y = SEAT_YIELD_PROVISIONAL
            provisional = True
        else:
            y = pr_count / total if total > 0 else 0.0
            provisional = False
        result[seat] = {
            "yield": y,
            "sessions": total,
            "pr_count": pr_count,
            "no_pr_count": no_pr,
            "provisional": provisional,
        }

    try:
        _atomic_write(SEAT_YIELD_JSON, json.dumps(result, sort_keys=True))
    except OSError as exc:
        print(f"seat-yield json write: {exc}", file=sys.stderr)

    return result


def _emit_seat_yield(lines, seat_yield):
    """Append fleet_seat_yield and fleet_sessions_no_pr_total families.

    The two metric families share the same per-seat loop. HELP/TYPE are
    emitted once per family so the node_exporter textfile stays parseable.
    """
    if not seat_yield:
        return
    lines.append("")
    lines.append(HELP_SY)
    lines.append(TYPE_SY)
    lines.append("")
    lines.append(HELP_SNPR)
    lines.append(TYPE_SNPR)
    for seat in sorted(seat_yield):
        y = seat_yield[seat]
        lbl = _prom_label(seat)
        lines.append(f'fleet_seat_yield{{seat="{lbl}"}} {y["yield"]:.6f}')
        lines.append(
            f'fleet_sessions_no_pr_total{{seat="{lbl}"}} {y["no_pr_count"]}'
        )


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

    fleet-ops#2690: the search query itself carries the 24h filter and
    sort:merged-desc. Pagination now terminates naturally (the result set
    is bounded by the window) — `merged:>=$cutoff` lets GitHub do the
    filtering and `sort:merged-desc` orders by merge time so the most
    recent merges come first. The GH_PAGES cap is still defended as a
    safety net; hitting it on a 24h window means >GH_PAGES×100 PRs merged
    in 24h across the org, which is the operational alarm to investigate.
    """
    cutoff_epoch = time.time() - 86400
    cutoff_iso = datetime.fromtimestamp(
        cutoff_epoch, tz=timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    query = MERGED_PRS_SEARCH_QUERY_TEMPLATE.replace("{CUTOFF}", cutoff_iso)
    out = []
    cursor = None
    for _ in range(GH_PAGES):
        payload = _gh_graphql(query, cursor)
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
                # Defensive backstop — the query already filtered, but if
                # GitHub's window edge drifted by a second a row could leak
                # through. Drop it; do not emit a false 24h merge.
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
    # (the 24h-windowed query should never exhaust the page cap at fleet
    # volume; if it does, that is the operational alarm — the print is
    # the existing loud signal picked up by alerting.)
    print("gh merged-prs search: hit page cap", file=sys.stderr)
    return out


def _gh_graphql(query, cursor=None):
    """Run `gh api graphql` with the query plus optional cursor.

    Note (fleet-ops#2690): earlier drafts of the #2690 fix passed the 24h
    cutoff as a $-variable via `-f cutoff=<iso>`. That does NOT work —
    GraphQL does not expand variables inside the `search(query: "...")`
    string field, only at the top level of the query body. The cutoff is
    interpolated into the search string by the caller (see
    MERGED_PRS_SEARCH_QUERY_TEMPLATE and _gh_merged_prs_raw).
    """
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


# fleet-ops#1291: per-alertname repair-outcome counts for the WFR
# alert-quality lens. The dispatcher writes one line per outcome with an
# `alertname=` token; this counts DISPATCH / RESOLVED / FAILED /
# SKIPPED-CLAIMED per alertname in the trailing 24h. The WFR computes
# action_rate = dispatch/(dispatch+skipped) and reads the RESOLVED text to
# judge false-positives — the stats feed the review, the review judges.
# Handles both bracketed `[YYYY-..Z]` and bare `YYYY-..Z` timestamps (the
# dispatcher's FAILED/RESOLVED lines use the bare form).
_BARE_TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z")
_ALERTNAME_RE = re.compile(r"alertname=(\S+)")
# fleet-ops#2694: phantom resolutions carry root_cause=PHANTOM_ALERT...
# (the value is underscore-joined; the first whitespace-delimited token is
# the signal). Real resolutions have transient_npm_.../no root_cause token.
_ROOT_CAUSE_RE = re.compile(r"root_cause=(\S+)")


def _repair_log_per_alertname_24h():
    """Return dict[alertname] = {dispatch, resolved, failed, skipped,
    phantom_resolved} for the trailing 24h, or {} when actions.log is
    missing. RESOLVED entries whose root_cause starts with PHANTOM_ALERT
    count as phantom_resolved, not resolved — drill fixtures are not
    repair work (fleet-ops#2694)."""
    if not ACTIONS_LOG.exists():
        return {}
    cutoff = time.time() - 86400
    out: dict = {}
    try:
        with ACTIONS_LOG.open("r") as f:
            for line in f:
                # Try bracketed then bare timestamp.
                m = _TS_RE.match(line)
                off = m.end() if m else None
                if off is None:
                    m = _BARE_TS_RE.match(line)
                    off = m.end() if m else None
                if off is None:
                    continue
                ep = _parse_iso_utc(m.group(1))
                if ep is None or ep < cutoff:
                    continue
                rest = line[off:].lstrip()
                kind = None
                if rest.startswith("DISPATCH "):
                    kind = "dispatch"
                elif rest.startswith("RESOLVED "):
                    # fleet-ops#2694: PHANTOM_ALERT root_cause = drill
                    # fixture, not a real fix; keep it out of "resolved"
                    # so the WFR lens can flag phantom drift.
                    rc = _ROOT_CAUSE_RE.search(rest)
                    if rc and rc.group(1).startswith("PHANTOM_ALERT"):
                        kind = "phantom_resolved"
                    else:
                        kind = "resolved"
                elif rest.startswith("FAILED "):
                    kind = "failed"
                elif rest.startswith("SKIPPED-CLAIMED "):
                    kind = "skipped"
                if kind is None:
                    continue
                am = _ALERTNAME_RE.search(rest)
                if not am:
                    continue
                name = am.group(1)
                d = out.setdefault(name, {"dispatch": 0, "resolved": 0,
                                          "failed": 0, "skipped": 0,
                                          "phantom_resolved": 0})
                d[kind] += 1
    except OSError as exc:
        print(f"actions.log per-alertname read: {exc}", file=sys.stderr)
        return {}
    return out


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


# --- SLO error budgets (fleet-ops#1291) ------------------------------------
# Google SRE Workbook Ch.5 canon. config/slo-definitions.json is the single
# source of truth; lib/slo_budget.py does the budget math (loaded lazily so
# the exporter stays a standalone script with no sys.path games at import
# time). The exporter computes compliance for each INSTRUMENTED SLO from
# data it already gathers in main() (CI green rollup, seat health, rate
# limit) plus the live fleet_waste_ratio from fleet-waste.prom, then emits
# the fleet_slo_* gauge family. Burn-rate ALERTS live in
# config/fleet_rules.yml as multiwindow avg_over_time() queries over
# fleet_slo_compliance (ratio SLOs) or threshold-window alerts (gauge SLOs)
# — Prometheus owns the canon, not Python. Uninstrumented SLOs (source
# metric pending a follow-up) emit fleet_slo_instrumented=0 and zero budget
# burn so their alert rules (gated on instrumented=1) never fire on a
# metric they cannot measure.

_SLO_BUDGET_MOD = None


def _slo_budget_mod():
    """Lazily load lib/slo_budget.py from ../lib/ relative to this script."""
    global _SLO_BUDGET_MOD
    if _SLO_BUDGET_MOD is not None:
        return _SLO_BUDGET_MOD
    import importlib.util
    lib_path = Path(__file__).resolve().parent.parent / "lib" / "slo_budget.py"
    spec = importlib.util.spec_from_file_location("slo_budget", lib_path)
    mod = importlib.util.module_from_spec(spec)
    # Register in sys.modules so dataclass's _is_type can resolve the module
    # (frozen dataclasses look up cls.__module__ in sys.modules at class-build time).
    sys.modules["slo_budget"] = mod
    spec.loader.exec_module(mod)
    _SLO_BUDGET_MOD = mod
    return mod


def _load_slo_defs():
    """Return the parsed slo-definitions.json, or None if missing/unparseable."""
    for path in (SLO_DEFS_DEFAULT, SLO_DEFS_FALLBACK):
        try:
            return json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
    return None


def _read_waste_ratio():
    """Read the live fleet_waste_ratio gauge from fleet-waste.prom, or None.

    fleet-waste-export is the single source of truth for the waste ratio;
    the SLO emitter reads its published value rather than recomputing it.
    Returns None when the prom file is missing or the gauge is absent
    (e.g., a fresh install before the waste exporter has run once) — the
    waste_ratio SLO then reports instrumented=0 for this tick.
    """
    try:
        text = WASTE_PROM.read_text()
    except OSError:
        return None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("fleet_waste_ratio "):
            try:
                return float(line.split()[-1])
            except (ValueError, IndexError):
                return None
    return None


def _read_chain_repair_duration():
    """Read the live fleet_chain_repair_duration_seconds gauge from fleet-chains.prom, or None.

    fleet-completion-canary emits the p95 chain duration; the SLO emitter reads
    its published value rather than recomputing it. Returns None when the prom
    file is missing or the gauge is absent (e.g., a fresh install before the
    completion canary has run once) — the chain_repair_latency SLO then reports
    instrumented=0 for this tick.
    """
    try:
        text = CHAIN_PROM.read_text()
    except OSError:
        return None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("fleet_chain_repair_duration_seconds "):
            try:
                return float(line.split()[-1])
            except (ValueError, IndexError):
                return None
    return None


def _enrolled_seat_providers():
    """Return the set of enrolled provider names (cap > 0 in seat-caps.json).

    Enrollment is per-provider: a provider whose cap is 0 (dead decoys,
    deliberately-capped, money-only rows) is not a seat the fleet routes
    to, so it must not count in the seat_availability SLO numerator or
    denominator family. Returns None when the config is missing/unparseable
    (callers then report source-unavailable rather than guessing).
    """
    for path in (SEAT_CAPS_DEFAULT, SEAT_CAPS_FALLBACK):
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        providers = data.get("providers") or {}
        if not isinstance(providers, dict):
            continue
        enrolled = set()
        for prov, cfg in providers.items():
            if not isinstance(cfg, dict):
                continue
            cap = cfg.get("cap", 0)
            if isinstance(cap, (int, float)) and cap > 0:
                enrolled.add(prov)
        return enrolled if enrolled else None
    return None


def _enrolled_seat_total():
    """Count enrolled seats (providers with cap>0) from seat-caps.json.

    fleet_pi_seat_total is the denominator for the seat_availability SLO.
    Returns None when the config is missing/unparseable so the SLO reports
    instrumented=0 rather than dividing by zero.
    """
    enrolled = _enrolled_seat_providers()
    return len(enrolled) if enrolled else None


# fleet-ops#2407: release-at-usable_at classes — the classes whose router
# (lib/seat-lib.sh seat_usable) FAIL-OPENS the seat once its wall clock
# (bench_until ?? usable_at) has passed. quota_exhausted / credentials_bad /
# corpse are held unconditionally until a healthy observation (billing/
# credential repair or a corpse re-probe), so they are never release-at-expiry.
# Keep this list in lock-step with seat_usable's branches.
_SEAT_RELEASE_AT_EXPIRY_CLASSES = frozenset(
    {
        "overload_bench",
        "quota_bench",
        "hang_bench",
        "transient_fault",
        "rate_limited",
    }
)

# fleet-ops#2806: one probe interval. The releaser
# (bin/fleet-seat-comeback-release) re-probes a walled seat within this
# window of its wall clock passing (seat-caps.json
# walled_comeback.min_probe_interval_s=900). A seat whose wall passed more
# than this many seconds ago while still walled means the releaser had a
# full probe cycle and did not act — overdue by more than one probe
# interval. The comeback-overdue metric and the thorough gather's
# usable_at_overdue grace on this boundary so a mid-cycle seat (a few
# minutes past, releaser about to re-probe) is not flagged.
COMEBACK_OVERDUE_GRACE_S = 900


def _seat_wall_end_epoch(data):
    """Epoch (s) of a ledger's wall clock, or None when not held by a clock.

    Bash-written bench markers (overload_bench / quota_bench / hang_bench)
    carry bench_until (usable_at aliases it); extension-written classes carry
    usable_at. seat_usable prefers bench_until and falls back to usable_at,
    so this helper mirrors that. Returns None for an unparseable/absent clock
    (treated as held, the defensive block).
    """
    raw = data.get("bench_until") or data.get("usable_at")
    if not isinstance(raw, str) or not raw:
        return None
    ts = raw.strip().rstrip("Z")
    try:
        return calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None


def _seat_is_released(data, now=None):
    """True when the router would (re)admit this seat at this instant.

    fleet-ops#2407: a walled seat is RELEASED the moment now >= usable_at for
    the release-at-expiry classes — seat_usable fail-opens it then, and the
    census/availability split must not keep counting a released seat as
    walled until the next observation happens to reclassify it. A non-healthy
    seat with a wall clock that has passed is available; one that is held
    (future clock) or has no clock (defensive hold) stays walled.
    """
    if data.get("seat_dead") is True:
        return False
    if data.get("health_class") not in _SEAT_RELEASE_AT_EXPIRY_CLASSES:
        return False
    end = _seat_wall_end_epoch(data)
    if end is None:
        return False
    return end < (now if now is not None else time.time())


def _read_comeback_overdue():
    """Seats still classed non-healthy whose wall clock has already passed.

    fleet-ops#2407: the wall-release path only clears on the NEXT observation
    (a healthy write reclassifies; a failure re-anchors usable_at), so a seat
    whose wall expired and nothing re-probed it lingers classed walled. Those
    seats are comeback-OVERDUE: the router has fail-opened them but they were
    not re-observed since. Exported once per tick (total + per-seat series) so
    the state fails loud instead of silently depressing the seat_availability
    rollup. seat_dead=true corpses are excluded here (they are deliberately
    terminal — FleetDeadCredentialSeats owns them); a quota/credential hold
    counts only once its own wall clock has passed (a hard billing wall whose
    reset window elapsed is exactly an overdue comeback).

    fleet-ops#2806: the RELEASER (bin/fleet-seat-comeback-release) re-probes a
    walled seat within one probe interval (walled_comeback.
    min_probe_interval_s, ~900s) of its wall clock passing — the seat returns
    to the healthy pool at usable_at (the router fail-opens it and this
    rollup already releases it, fleet-ops#2407). A seat whose wall passed only
    seconds ago is therefore mid-cycle, NOT overdue; the metric must not
    flag the releaser for a state it is about to act on (the lived
    2026-09-02T09:45Z case: two seats 6-14min past usable_at, releaser firing
    in the same tick, FleetSeatComebackOverdue pending at value=2). The
    overdue flag is graced by one probe interval: only a seat whose wall
    clock is past by MORE than COMEBACK_OVERDUE_GRACE_S (default 900) counts
    — the releaser had a full probe cycle to re-probe (re-anchor or unwall)
    and did not. This is the "overdue by more than one probe interval"
    boundary; the release organ's own interval-breach loud check
    (fleet_seat_comeback_release_interval_breached, fleet-ops#2806) fires on
    the same boundary from inside the sweep.

    Returns (count, [ {provider, model, health_class, usable_at, bench_until} ]).
    Never raises on a missing/unreadable ledger.
    """
    seats = []
    if not SEAT_LEDGER.is_dir():
        return 0, seats
    now = time.time()
    try:
        for f in sorted(SEAT_LEDGER.iterdir()):
            if not f.is_file() or "__" not in f.name or not f.name.endswith(".json"):
                continue
            if ".spawn-bench" in f.name:
                continue
            try:
                data = json.loads(f.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(data, dict):
                continue
            if data.get("provider") == "test":
                continue
            if data.get("seat_dead") is True:
                continue
            if data.get("health_class") == "healthy":
                continue
            end = _seat_wall_end_epoch(data)
            # No wall clock: nothing to come back from — not an overdue
            # comeback (the class is a defensive hold or legacy garbage; the
            # census still counts it walled). Only expired clocks alarm.
            if end is None:
                continue
            # fleet-ops#2806: grace of one probe interval. A seat whose wall
            # passed within the grace window is mid-cycle — the releaser
            # re-probes it on the next 15-min tick (re-anchor or unwall).
            # Only a wall past by more than one probe interval is OVERDUE.
            if now - end <= COMEBACK_OVERDUE_GRACE_S:
                continue
            seats.append(
                {
                    "provider": data.get("provider", ""),
                    "model": data.get("model", ""),
                    "health_class": data.get("health_class", ""),
                    "usable_at": data.get("usable_at"),
                    "bench_until": data.get("bench_until"),
                }
            )
    except OSError:
        return 0, []
    return len(seats), seats


# fleet-ops#2712: provider-level (account-level) quota exhaustion. Three
# seats from the same provider all returning HTTP 402 inside a 1h window
# points at the provider's account being out of quota, not at three
# independent seat faults — the per-seat health_class=quota_exhausted
# signal alone collapses three failures into one root cause. Surface
# that pattern here so the operator (and the alert below) can tell
# "account billing wall" from "lone seat quota hold". A provider only
# counts when it has at least MIN_PROVIDER_QUOTA_SEATS (default 2) seats
# observed as quota_exhausted within PROVIDER_QUOTA_WINDOW_S (default
# 3600s); one seat alone is an isolated hold, not account exhaustion.
MIN_PROVIDER_QUOTA_SEATS = 2
PROVIDER_QUOTA_WINDOW_S = 3600


def _read_provider_quota_exhausted():
    """Group quota_exhausted seats by provider within the last 1h.

    fleet-ops#2712: a single 402 may be one seat's per-model quota (cheap,
    isolated). Multiple 402s from one provider in a tight window is the
    account-level signal — one billing wall, many seats. Scan the ledger
    for quota_exhausted seats whose observed_at is within
    PROVIDER_QUOTA_WINDOW_S (default 3600s), group by provider, and return
    the providers whose seat count is >= MIN_PROVIDER_QUOTA_SEATS
    (default 2). Seat_dead corpses are skipped (terminal, owned by
    FleetDeadCredentialSeats). test__ fixtures are skipped (synthetic).
    The .spawn-bench sibling files are skipped (not seat observations).

    Returns (count, [ {provider, seats, models} ]). Never raises on a
    missing/unreadable ledger.
    """
    if not SEAT_LEDGER.is_dir():
        return 0, []
    now = time.time()
    # provider -> { "seats": int, "models": [ (model, observed_at), ... ] }
    grouped = {}
    try:
        for f in sorted(SEAT_LEDGER.iterdir()):
            if not f.is_file() or "__" not in f.name or not f.name.endswith(".json"):
                continue
            if ".spawn-bench" in f.name:
                continue
            try:
                data = json.loads(f.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(data, dict):
                continue
            if data.get("provider") == "test":
                continue
            if data.get("seat_dead") is True:
                continue
            # The HTTP-402 + health_class=quota_exhausted combination is
            # the seat-health extension's classifier output. A seat that
            # is in some other failure mode (transient_http, rate_limit)
            # is NOT an account-quota signal even if the model is hosted
            # by the same provider.
            if data.get("http_status") != 402:
                continue
            if data.get("health_class") != "quota_exhausted":
                continue
            observed = data.get("observed_at")
            if not isinstance(observed, str) or not observed:
                continue
            ts = observed.strip().rstrip("Z")
            try:
                epoch = calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
            except ValueError:
                continue
            if (now - epoch) > PROVIDER_QUOTA_WINDOW_S:
                continue
            prov = data.get("provider")
            if not isinstance(prov, str) or not prov:
                continue
            entry = grouped.setdefault(prov, {"seats": 0, "models": []})
            entry["seats"] += 1
            entry["models"].append((data.get("model", ""), observed))
    except OSError:
        return 0, []
    providers = [
        {"provider": p, "seats": v["seats"], "models": v["models"]}
        for p, v in sorted(grouped.items())
        if v["seats"] >= MIN_PROVIDER_QUOTA_SEATS
    ]
    return len(providers), providers


def _seat_caps_model_cap_map():
    """Build a {provider/model: cap} map from seat-caps.json.

    Mirrors lib/seat-lib.sh load_seat_caps model-cap parsing: a model value
    may be a bare int (the cap) or an object {cap, class, ...}; the cap is
    `.cap // 0` for objects. Unlisted models default to 0 (seat-lib's
    model_cap returns 0 for unlisted, and pick_seat skips cap=0 models).
    Returns None when the config is missing/unparseable so callers can
    report source-unavailable instead of guessing.
    """
    for path in (SEAT_CAPS_DEFAULT, SEAT_CAPS_FALLBACK):
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        providers = data.get("providers") or {}
        if not isinstance(providers, dict):
            continue
        caps = {}
        for prov, cfg in providers.items():
            if not isinstance(cfg, dict):
                continue
            models = cfg.get("models") or {}
            if not isinstance(models, dict):
                continue
            for model, val in models.items():
                if isinstance(val, bool):
                    cap = 0
                elif isinstance(val, (int, float)):
                    cap = int(val)
                elif isinstance(val, dict):
                    raw = val.get("cap", 0)
                    cap = int(raw) if isinstance(raw, (int, float)) and not isinstance(raw, bool) else 0
                else:
                    cap = 0
                caps[f"{prov}/{model}"] = cap
        return caps
    return None


def _read_healthy_cap0():
    """Healthy-but-parked seats: ledger healthy, model cap in seat-caps is 0.

    fleet-ops#2738: a seat whose ledger reports health_class=healthy and
    seat_dead=false (the seat works — proven by a 200 observation) but whose
    model cap in seat-caps.json is 0 is silently parked: pick_seat skips it
    every tick while the seat-availability SLO burns. The devin/glm-5-2
    restore lapsed exactly this way — the ledger came back healthy on
    2026-09-01, the cap stayed 0 for 3+ days, and no metric surfaced it.
    This gauge counts those seats (total + per-seat series) so the WFR lens
    and the next blind-audit see a healthy-but-parked seat instead of a
    quiet depressed rollup. Sustained > 0 here is the loud signal that a
    restore was forgotten.

    A held wrapper spawn-bench (fleet-ops#2493) outranks a later healthy
    observation, so a spawn-bench-active seat is NOT counted as healthy
    here (it is not actually healthy — the wrapper benched it). test__
    fixtures and .spawn-bench sibling markers are skipped. Never raises on
    a missing/unreadable ledger or config; returns (0, []) when the config
    is unavailable so the metric fails safe (no false healthy-parked alarm
    from a missing config).

    Returns (count, [ {provider, model} ]).
    """
    caps = _seat_caps_model_cap_map()
    if caps is None:
        return 0, []
    seats = []
    if not SEAT_LEDGER.is_dir():
        return 0, seats
    try:
        for f in sorted(SEAT_LEDGER.iterdir()):
            if not f.is_file() or "__" not in f.name or not f.name.endswith(".json"):
                continue
            if ".spawn-bench" in f.name:
                continue
            try:
                data = json.loads(f.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(data, dict):
                continue
            if data.get("provider") == "test":
                continue
            if data.get("seat_dead") is True:
                continue
            if data.get("health_class") != "healthy":
                continue
            # fleet-ops#2493: a held wrapper spawn-bench outranks a later
            # healthy observation — the seat is not actually healthy.
            if _spawn_bench_active(f):
                continue
            prov = data.get("provider")
            model = data.get("model")
            if not isinstance(prov, str) or not isinstance(model, str):
                continue
            if not prov or not model:
                continue
            # seat-lib model_cap returns 0 for unlisted models; mirror that
            # so a healthy ledger for a removed model still flags (the cap
            # is effectively 0 — pick_seat will not route to it).
            if caps.get(f"{prov}/{model}", 0) == 0:
                seats.append({"provider": prov, "model": model})
    except OSError:
        return 0, []
    return len(seats), seats


def _read_cap0_stale():
    """Stale cap=0 seats (intentional_cap_zero=stale) with age from the reason date.

    fleet-ops#3111: a stale cap=0 seat has a dated reason ("2026-08-28
    re-audition: endpoint 404"). The 2026-09-03 incident showed groq, inferx,
    and orcarouter lingering at cap=0 for weeks while the fleet starved.
    seat-lib's _expire_stale_cap0_seats re-admits them at cap=1 after 14d;
    this metric makes them visible BEFORE the expiry so the operator can
    re-audition or re-date the reason. Age is seconds since the first
    YYYY-MM-DD in the reason; -1 if undated (undated = expires first).

    Returns (count, [ {provider, model, age_seconds} ]).
    """
    seats = []
    data = None
    for path in (SEAT_CAPS_DEFAULT, SEAT_CAPS_FALLBACK):
        try:
            data = json.loads(path.read_text())
            break
        except (OSError, json.JSONDecodeError):
            continue
    if not isinstance(data, dict):
        return 0, []
    now = int(time.time())
    providers = data.get("providers", {})
    if not isinstance(providers, dict):
        return 0, []

    def _age_from_reason(reason):
        if not isinstance(reason, str):
            return -1
        m = re.search(r"(\d{4})-(\d{2})-(\d{2})", reason)
        if not m:
            return -1
        try:
            ds = int(time.mktime(time.strptime(
                f"{m.group(1)}-{m.group(2)}-{m.group(3)}", "%Y-%m-%d")))
            return now - ds
        except ValueError:
            return -1

    for prov, pv in providers.items():
        if isinstance(pv, dict):
            icz = pv.get("intentional_cap_zero", "")
            cap = pv.get("cap", 0)
            if icz == "stale" and cap == 0:
                seats.append({
                    "provider": prov, "model": "",
                    "age_seconds": _age_from_reason(pv.get("reason", "")),
                })
            models = pv.get("models", {})
            if isinstance(models, dict):
                for model, mv in models.items():
                    if isinstance(mv, dict):
                        micz = mv.get("intentional_cap_zero", "")
                        mcap = mv.get("cap", 0)
                        if micz == "stale" and mcap == 0:
                            seats.append({
                                "provider": prov, "model": model,
                                "age_seconds": _age_from_reason(mv.get("reason", "")),
                            })
    return len(seats), seats


# fleet-ops#2638: SEAT_DEAD_CONSECUTIVE_THRESHOLD mirror — the bash writer
# (lib/seat-lib.sh) corpses quota_cap at this count; the prober
# (bin/fleet-seat-comeback-release) corpses the same way on the overload/
# transient/rate classes. Used by _read_never_released to define the
# "stuck" window: a seat that has failed >= half-threshold times under
# the prober and is NOT yet corpse is a never-probed comeback — the bin
# has fired on it and the seat still won't recover. Exporting this as
# a per-tick gauge makes the stuck state visible before it crosses into
# the corpse path.
NEVER_RELEASED_MIN_COUNT = 10  # floor for "stuck" so a healthy probe cycle
                                # doesn't render every wall as stuck


def _read_never_released():
    """Seats that the prober has been failing on for a while without corpse.

    fleet-ops#2638: the lived poolside/laguna (23x 503s) and opencode/mimo
    (42x 429s) cases both sat at health_class != healthy with the prober
    re-benching every 15 min, count climbing, the seat never recovering.
    These are NEVER-PROBED COMEBACKS — the bin fires on them but the seat
    never releases. The prober's corpse path (at SEAT_DEAD_CONSECUTIVE_THRESHOLD,
    default 25) converts them to terminal corpses, but the stuck state
    between "high count" and "corpse" was invisible. This gauge makes
    that window visible: seats with consecutive_failure_count in
    [NEVER_RELEASED_MIN_COUNT, SEAT_DEAD_CONSECUTIVE_THRESHOLD) that are
    NOT corpses. Sustained > 0 here is the loud signal that the release
    path is operating but the seat still cannot recover — the next
    corpse write should fire. Combined with fleet_seat_comeback_overdue_total
    it tells the repair worker which overdue seats are approaching the
    corpse boundary.

    The threshold env var defaults to 25 (matching SEAT_DEAD_CONSECUTIVE_THRESHOLD
    in lib/seat-lib.sh, fleet-ops#2594) so the corpus threshold and the
    stuck-window upper bound stay in lock-step.

    Returns (count, [ {provider, model, health_class, count} ]).
    Never raises on a missing/unreadable ledger.
    """
    seats = []
    if not SEAT_LEDGER.is_dir():
        return 0, seats
    now = time.time()
    try:
        threshold = int(os.environ.get("SEAT_DEAD_CONSECUTIVE_THRESHOLD", "25"))
    except (TypeError, ValueError):
        threshold = 25
    if threshold < 1:
        threshold = 25
    try:
        for f in sorted(SEAT_LEDGER.iterdir()):
            if not f.is_file() or "__" not in f.name or not f.name.endswith(".json"):
                continue
            if ".spawn-bench" in f.name:
                continue
            try:
                data = json.loads(f.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(data, dict):
                continue
            if data.get("provider") == "test":
                continue
            if data.get("seat_dead") is True:
                continue  # corpses are counted elsewhere (FleetDeadCredentialSeats)
            if data.get("health_class") == "healthy":
                continue  # recovered
            # fleet-ops#2752: a seat whose wall clock (bench_until ??
            # usable_at) is still in the FUTURE is legitimately walled —
            # it will self-release when the wall passes (the comeback-
            # release prober re-probes it at that point). It is NOT a
            # never-released corpse: the cline/cline-pass_minimax-m3
            # corpse was written by repair-dispatch because this window
            # counted a 17-day-future-walled quota seat as "stuck" (count
            # 19, threshold 25 — the natural corpse path could never fire
            # while the wall kept the seat benched), FleetSeatComebackNeverReleased
            # fired, and the repair worker manually corpse'd a VALID
            # subscription seat whose monthly cap resets 16d14h out. Only
            # a seat whose wall has PASSED (or that never had one) can be
            # a never-probed comeback — a future-walled seat is not owed a
            # comeback yet.
            _wall = _seat_wall_end_epoch(data)
            if _wall is not None and _wall >= now:
                continue
            try:
                count = int(data.get("consecutive_failure_count") or 0)
            except (TypeError, ValueError):
                count = 0
            # "Stuck" = close to but below the corpse threshold. The lower
            # bound (NEVER_RELEASED_MIN_COUNT, default 10) prevents the gauge
            # from spiking on a single fresh failure; the upper bound is the
            # corpse boundary (seat at threshold will be corpse on the next
            # sweep and disappear from this gauge).
            if count < NEVER_RELEASED_MIN_COUNT or count >= threshold:
                continue
            seats.append(
                {
                    "provider": data.get("provider", ""),
                    "model": data.get("model", ""),
                    "health_class": data.get("health_class", ""),
                    "count": count,
                }
            )
    except OSError:
        return 0, []
    return len(seats), seats


def _spawn_bench_active(ledger_path: Path) -> bool:
    """True if the per-seat spawn-bench marker is fresh and in the future.

    fleet-ops#1512: the wrapper writes a `.<base>.spawn-bench.json` file
    next to the per-seat ledger whenever mark_seat_spawn_fail /
    mark_seat_empty_run benches a seat. seat_usable checks it FIRST, so
    the router already excludes the seat while the bench is held. The
    metrics export used to ignore it — a seat whose ledger shows
    health_class=healthy (the seat-health extension's after_provider_response
    re-wrote it on a later 200 OK) but whose spawn-bench is still in the
    future was counted as healthy in the seat_availability SLO, even
    though the router refused to route work to it. The census said
    "healthy" while pick_seat said "no usable seat" — fleet-ops#2493
    closed that gap: read the spawn-bench and treat a held bench as
    non-healthy (an active wrapper bench is always operator- or wrapper-
    authored and is more authoritative than a later healthy observation
    on the same seat).

    Returns False on a missing / unreadable / past-due marker; never
    raises. The path argument is the per-seat ledger file; the spawn-
    bench sibling is `<base>.spawn-bench.json` in the same directory.
    """
    if not ledger_path.is_file():
        return False
    # Per lib/seat-lib.sh seat_spawn_bench_path, the spawn-bench file lives
    # beside the ledger as `<provider>__<model>.spawn-bench.json` — i.e.
    # the same base name as the ledger with the .json suffix replaced by
    # `.spawn-bench.json`, NOT a separate suffix appended to the full
    # ledger filename. Construct it via stem + suffix so a ledger like
    # `opencode__nemotron-3-ultra-free.json` maps to
    # `opencode__nemotron-3-ultra-free.spawn-bench.json` (matching the
    # live state at /home/nish/workspaces/agent-state/lanes/seats/).
    spawn_bench = ledger_path.with_name(ledger_path.stem + ".spawn-bench.json")
    if not spawn_bench.is_file():
        return False
    try:
        marker = json.loads(spawn_bench.read_text())
    except (OSError, json.JSONDecodeError):
        return False
    if not isinstance(marker, dict):
        return False
    usable_at = marker.get("usable_at")
    if not isinstance(usable_at, str) or not usable_at:
        return False
    try:
        # Parse the ISO timestamp as UTC (the seat ledger is always
        # UTC-Z). time.mktime is local-timezone-dependent and would
        # give a wrong epoch on a non-UTC host (the live VPS runs
        # IST, +5:30; a future-Z timestamp would parse to a
        # past-local epoch and the helper would incorrectly return
        # False). Use calendar.timegm to treat the parsed tuple as
        # UTC, then compare to the UTC wall clock.
        from calendar import timegm
        usable_epoch = timegm(time.strptime(usable_at.replace("Z", "")[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return False
    return usable_epoch > int(time.time())


def _healthy_enrolled_seat_count():
    """Count enrolled providers with >=1 healthy or released, non-dead ledger.

    Rollup for the seat_availability SLO (fleet-ops#1291): the spec says
    "Fraction of enrolled seats that are healthy (rollup)" — i.e. a
    per-seat healthy/not tally over the whole fleet, not one provider's
    single 0/1. Each per-seat health ledger file under SEAT_LEDGER is one
    (provider, model) observation; a provider counts healthy when ANY of
    its model ledgers reports health_class=healthy and seat_dead != true
    (a provider with a live model is an enrolled seat that is healthy).

    fleet-ops#2407: a ledger whose wall clock has EXPIRED is released — the
    router (seat_usable) fail-opens it at now >= usable_at, so it is
    available capacity and counts toward the rollup even though no fresh
    observation has reclassified it yet. Without this, an overload_bench /
    transient_fault seat whose wall passed sat "walled" in the rollup until
    the next probe, depressing seat availability for the whole window
    (2026-08-30: three such seats past usable_at still counted walled).
    The comeback-overdue metric above fails loud when that release is
    unobserved, so no dead seat hides behind this relaxation.

    fleet-ops#2493: a held wrapper spawn-bench is operator- or wrapper-
    authored and is MORE authoritative than a later healthy observation
    on the same seat. The seat-health extension's after_provider_response
    re-writes the ledger as health_class=healthy on a 200 OK, but the
    wrapper's spawn-bench marker (written for an empty run / no-op /
    spawn-fail) persists in the same directory. Without this check the
    census says "healthy" while pick_seat says "no usable seat" — a
    silent mismatch that pinned opencode/nemotron-3-ultra-free as
    "healthy" across 6 empty runs in 2h (fleet-ops#2493 lived snapshot).
    Read the spawn-bench sibling; if it is in the future, the seat is
    NOT healthy for the rollup.

    Providers with no ledger file at all are counted unhealthy (not proven
    healthy — fail-safe toward the alert). Returns None when the ledger
    directory is missing/unreadable so the SLO reports instrumented=0.
    """
    enrolled = _enrolled_seat_providers()
    if not enrolled:
        return None
    if not SEAT_LEDGER.is_dir():
        return None
    healthy = set()
    try:
        for f in SEAT_LEDGER.iterdir():
            if not f.is_file() or "__" not in f.name or not f.name.endswith(".json"):
                continue
            try:
                data = json.loads(f.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(data, dict):
                continue
            if data.get("seat_dead") is True:
                continue
            # fleet-ops#2493: a held wrapper spawn-bench outranks a later
            # healthy observation. The wrapper wrote the bench for an
            # empty run / no-op / spawn-fail; the seat-health extension
            # then re-wrote the ledger as healthy on a 200 OK. The bench
            # is the more recent operational truth — count the seat as
            # non-healthy until the bench expires.
            if _spawn_bench_active(f):
                continue
            if data.get("health_class") != "healthy" and not _seat_is_released(data):
                continue
            prov = data.get("provider")
            if isinstance(prov, str) and prov in enrolled:
                healthy.add(prov)
    except OSError:
        return None
    return len(healthy)


def _slo_compliance(slo, main_ci, healthy, rate_limit, waste_ratio, seat_total):
    """Compute live compliance (0..1 ratio or value/target gauge) for one SLO.

    Returns (compliance_or_None, instrumented_bool). None compliance means
    the source metric is not available this tick (SLO emits instrumented=0).
    """
    sid = slo["id"]
    if not slo.get("instrumented", False):
        return None, False
    if sid == "main_green":
        # Fraction of enrolled repos with green CI this scrape.
        if not main_ci:
            return None, False
        vals = list(main_ci.values())
        return sum(vals) / len(vals), True
    if sid == "seat_availability":
        # Rollup over the per-seat health ledger (fleet-ops#1291): healthy
        # enrolled providers / enrolled providers. The old code divided the
        # SINGLE pi-seat-health 0/1 gauge by the enrolled-provider count,
        # pinning compliance at 0/13 or 1/13 forever — a metric bug that
        # kept this SLO in permanent slow burn regardless of real seat
        # health (alert-repair diagnosis 2026-08-30, 05:57/07:44Z). The
        # single-seat gauge stays exported as fleet_pi_seat_healthy for the
        # FleetPiSeatUnhealthy alert; this SLO now computes the rollup.
        if seat_total is None or seat_total <= 0:
            return None, False
        healthy_count = _healthy_enrolled_seat_count()
        if healthy_count is None:
            return None, False
        return healthy_count / seat_total, True
    if sid == "gh_rate_limit_headroom":
        # min(remaining/limit) across the consumed resources, as a fraction.
        if not rate_limit:
            return None, False
        fracs = []
        for r in slo.get("resources", ("core", "search", "graphql")):
            row = rate_limit.get(r)
            if not row or row.get("limit", 0) <= 0:
                continue
            fracs.append(row["remaining"] / row["limit"])
        if not fracs:
            return None, False
        return min(fracs), True
    if sid == "waste_ratio":
        # Gauge "below" SLO: compliance = actual/target (>1 means over budget).
        if waste_ratio is None:
            return None, False
        target = slo["target"]
        return (waste_ratio / target) if target > 0 else None, True
    if sid == "chain_repair_latency":
        # Gauge "below" SLO: compliance = p95_duration / target (>1 means over budget).
        # Target is 1800 seconds (30 min). p95 comes from fleet-completion-canary.
        chain_duration = _read_chain_repair_duration()
        if chain_duration is None:
            return None, False
        target = slo["target"]
        return (chain_duration / target) if target > 0 else None, True
    # 0509_user_journey / digest_delivery: source metrics pending instrumentation
    # (follow-up issues). Even if flagged instrumented=true in config, no live
    # reader exists yet → not instrumented.
    return None, False


def _emit_slo_metrics(lines, main_ci, healthy, rate_limit):
    """Append the fleet_slo_* gauge family for every SLO in the config.

    Called from main() with the data it has already gathered. Reads
    fleet-waste.prom, fleet-chains.prom, and seat-caps.json for the SLOs
    whose sources live outside this exporter. Always emits the family (even
    on a missing config — zeros with instrumented=0) so FleetSloMetricsAbsent
    never false-fires on a config glitch; a missing config is logged to
    stderr.
    """
    sb = _slo_budget_mod()
    defs = _load_slo_defs()
    waste_ratio = _read_waste_ratio()
    seat_total = _enrolled_seat_total()
    lines.append("")
    lines.extend(sb.format_prometheus_help_type())
    if defs is None:
        # fleet-ops#3367: emit instrumented=0 for every known SLO so
        # Prometheus overwrites any stale instrumented=1 from the previous
        # run. Without this, a config glitch leaves stale compliance +
        # instrumented=1 gauges in Prometheus while fleet_main_ci_green
        # keeps updating — a real SLO-vs-green-map disagreement that keeps
        # the burn alerts firing on frozen data.
        print("slo: config/slo-definitions.json missing/unparseable; "
              "emitting instrumented=0 for all known SLOs", file=sys.stderr)
        for sid in _KNOWN_SLO_IDS:
            lines.append(f'fleet_slo_instrumented{{slo="{_prom_label(sid)}"}} 0')
        return
    slos = defs.get("slos") or []
    for slo in slos:
        sid = slo["id"]
        target = slo["target"]
        window_s = slo.get("window_seconds", defs.get("default_window_seconds", 604800))
        direction = slo.get("direction", "above")
        compliance, instrumented = _slo_compliance(
            slo, main_ci, healthy, rate_limit, waste_ratio, seat_total
        )
        if not instrumented or compliance is None:
            # Uninstrumented or source unavailable this tick: emit zero
            # budget burn + instrumented=0 so the burn alerts (gated on
            # instrumented=1) cannot fire on a metric they cannot measure.
            lines.append(f'fleet_slo_instrumented{{slo="{_prom_label(sid)}"}} 0')
            continue
        # Elapsed = full window this scrape (compliance is a point-in-time
        # rollup over the trailing window, so the whole window is "elapsed"
        # for budget-consumption purposes). Burn-rate alerts derive the
        # time dimension themselves via increase() over the consumed gauge.
        budget = sb.compute_budget(sid, target, window_s, compliance, window_s, direction)
        lines.extend(sb.format_prometheus(budget))
        lines.append(f'fleet_slo_instrumented{{slo="{_prom_label(sid)}"}} 1')


# --- Deployment quality SLOs (fleet-ops#2758) -----------------------------
# lib/fleet-deploy-quality.py computes the deployment-quality SLO family
# (latency, rollback rate, time-to-detect, success rate, blocked-duration)
# from gh merged/revert lists, the fleet-deploy-check journal, and the
# alert-repair actions.log. Loaded lazily (same pattern as slo_budget) so
# this exporter stays a standalone script; the module never raises out of
# here — a hard failure emits NaN gauges + fleet_deployment_quality_up 0 so
# the DeploymentQualityStale rule stays loud instead of serving a frozen or
# zero value (a 0 blocked-duration during a real 40-min block is exactly
# the silent drift the rule family exists to kill).

_DEPLOY_QUALITY_MOD = None


def _deploy_quality_mod():
    """Lazily load lib/fleet-deploy-quality.py from ../lib/."""
    global _DEPLOY_QUALITY_MOD
    if _DEPLOY_QUALITY_MOD is not None:
        return _DEPLOY_QUALITY_MOD
    import importlib.util
    lib_path = Path(__file__).resolve().parent.parent / "lib" / "fleet-deploy-quality.py"
    spec = importlib.util.spec_from_file_location("fleet_deploy_quality", lib_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["fleet_deploy_quality"] = mod
    spec.loader.exec_module(mod)
    _DEPLOY_QUALITY_MOD = mod
    return mod


_DQ_GAUGES = (
    "fleet_deployment_latency_seconds",
    "fleet_deployment_rollback_rate",
    "fleet_deployment_time_to_detect_seconds",
    "fleet_deployment_success_rate",
    "fleet_deploy_blocked_duration_seconds",
)


# --- blocked-reconcile nish-decision lint (fleet-ops#3312) -----------------
# blocked-reconcile writes its last sweep summary to
# /home/nish/.local/state/fleet-heartbeat/blocked-queue.json. We export the
# count of rejected `blocked-on: nish-decision` lines that were rewritten to
# `blocked-on: orchestrator` and labelled `needs-orchestrator`.
BLOCKED_QUEUE_JSON = Path(
    os.environ.get(
        "FLEET_BLOCKED_QUEUE_JSON",
        "/home/nish/.local/state/fleet-heartbeat/blocked-queue.json",
    )
)
HELP_NBR = "# HELP fleet_nish_decision_rejected_total Number of `blocked-on: nish-decision` lines rejected and rewritten to `blocked-on: orchestrator` in the last blocked-reconcile sweep (fleet-ops#3312)."
TYPE_NBR = "# TYPE fleet_nish_decision_rejected_total gauge"


def _emit_blocked_reconcile(lines):
    """Append fleet_nish_decision_rejected_total.

    Reads the last blocked-reconcile sweep summary. A missing or
    unparseable file emits 0 so the metric family is always present.
    """
    count = 0
    try:
        data = json.loads(BLOCKED_QUEUE_JSON.read_text(encoding="utf-8"))
        raw = data.get("rejected_nish_decisions")
        if isinstance(raw, (int, float)):
            count = int(raw)
    except (OSError, json.JSONDecodeError):
        pass
    lines.append("")
    lines.append(HELP_NBR)
    lines.append(TYPE_NBR)
    lines.append(f"fleet_nish_decision_rejected_total {count}")


# --- close-duplicates close guard (fleet-ops#3161) ------------------------
# The heartbeat writes lib/issue-file.py close-duplicates summary to
# $FLEET_HEARTBEAT_LOG_DIR/close-duplicates.json every tick. We emit the
# per-tick close count by label so an alert can fire the instant a
# cross-repo or protected (critical-path / owner-authored) issue is closed.
# Both labelled series must stay 0; only cross_repo=false,protected=false
# may increment. The family is always emitted (zeros when the file is
# missing) so FleetCloseDuplicatesClosesAbsent never false-fires on a
# skipped tick.
CLOSE_DUP_JSON = Path(
    os.environ.get(
        "FLEET_CLOSE_DUPLICATES_JSON",
        "/home/nish/.local/state/fleet-heartbeat/close-duplicates.json",
    )
)
HELP_CD = (
    "# HELP fleet_close_duplicates_closes_total Duplicate issues auto-closed "
    "by fleet-issue-file close-duplicates in the last run, by label "
    "(fleet-ops#3161). cross_repo and protected must always be 0; an alert "
    "on either > 0 catches a wrong close of a cross-repo or protected issue."
)
TYPE_CD = "# TYPE fleet_close_duplicates_closes_total gauge"
_CLOSE_DUP_LABELS = (
    ("false", "false"),
    ("false", "true"),
    ("true", "false"),
    ("true", "true"),
)


def _emit_close_duplicates(lines):
    """Append fleet_close_duplicates_closes_total{cross_repo,protected}.

    Reads the last close-duplicates summary's closes_by_label map. Never
    raises: a missing/unparseable file emits all four series as 0 so the
    family is always present and the absent rule stays quiet.
    """
    counts = {f"cross_repo={cr},protected={pr}": 0 for cr, pr in _CLOSE_DUP_LABELS}
    try:
        data = json.loads(CLOSE_DUP_JSON.read_text(encoding="utf-8"))
        raw = data.get("closes_by_label") or {}
        if isinstance(raw, dict):
            for k, v in raw.items():
                if k in counts and isinstance(v, (int, float)):
                    counts[k] = int(v)
    except (OSError, json.JSONDecodeError):
        pass
    lines.append("")
    lines.append(HELP_CD)
    lines.append(TYPE_CD)
    for cr, pr in _CLOSE_DUP_LABELS:
        lines.append(
            f'fleet_close_duplicates_closes_total{{cross_repo="{cr}",protected="{pr}"}} '
            f"{counts[f'cross_repo={cr},protected={pr}']}"
        )


# --- observe-to-close close guard (fleet-ops#3231) ---------------------
# The heartbeat writes bin/fleet-merged-pr-close's per-tick summary to
# $FLEET_HEARTBEAT_LOG_DIR/merged-pr-close.json every tick. We emit the
# close count by reason so an alert can fire the instant a close happens on
# a bare mention or on a protected (critical-path / owner-authored) issue —
# the PR #3205 regression that wrongly closed #3140/#3146. Both labelled
# series must stay 0; only claim-branch and closes-trailer may increment.
# The family is always emitted (zeros when the file is missing) so the
# absent rule never false-fires on a skipped tick.
MERGED_PR_CLOSE_JSON = Path(
    os.environ.get(
        "FLEET_MERGED_PR_CLOSE_JSON",
        "/home/nish/.local/state/fleet-heartbeat/merged-pr-close.json",
    )
)
HELP_MPC = (
    "# HELP fleet_observe_to_close_total Issues auto-closed by observe-to-close "
    "in the last heartbeat tick, by reason (fleet-ops#3231). Legal close "
    "reasons are claim-branch (delivery PR head) and closes-trailer (explicit "
    "Closes/Fixes/Resolves trailer). bare-mention and protected must always "
    "be 0; an alert on either > 0 catches a wrong close of a mentioned or "
    "critical-path/owner-authored issue."
)
TYPE_MPC = "# TYPE fleet_observe_to_close_total gauge"
_MPC_REASONS = ("claim-branch", "closes-trailer", "bare-mention", "protected")


def _emit_observe_to_close(lines):
    """Append fleet_observe_to_close_total{reason}.

    Reads the last observe-to-close summary's closes_by_reason map. Never
    raises: a missing/unparseable file emits all four series as 0 so the
    family is always present and the absent rule stays quiet.
    """
    counts = {r: 0 for r in _MPC_REASONS}
    try:
        data = json.loads(MERGED_PR_CLOSE_JSON.read_text(encoding="utf-8"))
        raw = data.get("closes_by_reason") or {}
        if isinstance(raw, dict):
            for k, v in raw.items():
                if k in counts and isinstance(v, (int, float)):
                    counts[k] = int(v)
    except (OSError, json.JSONDecodeError):
        pass
    lines.append("")
    lines.append(HELP_MPC)
    lines.append(TYPE_MPC)
    for reason in _MPC_REASONS:
        lines.append(f'fleet_observe_to_close_total{{reason="{reason}"}} {counts[reason]}')


def _emit_deploy_quality(lines):
    """Append the fleet_deployment_* family from lib/fleet-deploy-quality.py.

    Never fails the exporter: on any module failure the issue's five named
    gauges are emitted as NaN with fleet_deployment_quality_up 0 (the
    DeploymentQualityStale rule makes that loud) and the fault is logged to
    stderr. NaN keeps the threshold rules (latency>1800, blocked>900, ...)
    silent on a data outage — a comparison against NaN is false — while the
    up=0 says the family is unhealthy, not healthy.
    """
    try:
        out = _deploy_quality_mod().prom_lines()
        if not out or not any(l.startswith("fleet_deployment_")
                              for l in out if not l.startswith("#")):
            raise ValueError("empty deploy-quality family")
        lines.append("")
        lines.extend(out)
    except Exception as exc:  # noqa: BLE001 - the exporter must stay green
        print(f"deploy-quality: {exc}", file=sys.stderr)
        label = 'repo="fleet-ops"'
        lines.append("")
        for gauge in _DQ_GAUGES:
            lines.append(f"# HELP {gauge} deploy-quality SLO (fleet-ops#2758); NaN when the computation failed this scrape.")
            lines.append(f"# TYPE {gauge} gauge")
            lines.append(f"{gauge}{{{label}}} NaN")
        lines.append("# HELP fleet_deployment_quality_up 1 when the deploy-quality computation succeeded, 0 when it failed (values are NaN).")
        lines.append("# TYPE fleet_deployment_quality_up gauge")
        lines.append(f"fleet_deployment_quality_up{{{label}}} 0")


# --- Week-later revert check (fleet-ops#3124 part 4/4) ---------------------
# Self-maintenance budget: a fleet-ops PR that carries a `moves:` metric is
# expected to move that metric. Seven days after the PR merges, compare the
# metric's 7d value before vs after the merge; if it did not improve, file
# ONE revert-candidate issue ("revert candidate: #N did not move <metric>",
# labeled agent-ready, `termination:` = the revert PR merged). One issue per
# PR, never re-filed. Runs on the existing fleet-metrics-export tick (no new
# timer).
#
# The `moves:` line is the sibling part 2/4 (fleet-ops#3255) spec-gate
# requirement; this part consumes it. A PR body carries `moves: <metric>`
# naming one of the product metrics. Only metrics with a mapped Prometheus
# expression are comparable; unmapped metrics are skipped (not filed).

# ±6h around the 7-day mark: a PR merged exactly 7 days ago is in the window
# for 12h, so a tick that misses it (gh hiccup, exporter down) catches it on
# a later tick. The PR list is cached to WEEK_LATER_CACHE_TTL so the gh
# search runs at most ~4x/day, not every 5-min tick.
WEEK_LATER_WINDOW_S = 6 * 3600
WEEK_LATER_CACHE_TTL = 6 * 3600
WEEK_LATER_CACHE = PR_CACHE_DIR / "week-later-prs-cache.json"
# Per-PR evaluation ledger: once a PR is evaluated (improved / already-filed /
# filed) it is never re-evaluated, so the gh dedup/create calls are bounded to
# one per PR, not one per tick. Pruned after WEEK_LATER_STATE_TTL.
WEEK_LATER_STATE = PR_CACHE_DIR / "week-later-state.json"
WEEK_LATER_STATE_TTL = 14 * 86400
WEEK_LATER_PROM_URL = "http://127.0.0.1:9090/api/v1/query"
WEEK_LATER_PROM_TIMEOUT = 10

# moves: metric -> Prometheus expression for the metric's value. The 7d value
# is the avg_over_time of this expression over a 7d window. Only metrics with
# a mapping here are comparable; add mappings as the sibling parts land.
_MOVES_METRIC_QUERIES = {
    "product_merges_per_day": 'sum(fleet_self_maintenance_merges{kind="product"})',
}

# Line-anchored `moves:` field (the sibling spec-gate's body line). Leading
# list markers allowed so a `- moves: ...` body line counts, mirroring the
# spec-gate's FIELD_RE.
_MOVES_RE = re.compile(r"(?im)^(?:[-*]\s+)*moves\s*:\s*(\S+)")


def _week_later_prs():
    """Cached list of fleet-ops PRs merged ~7 days ago with a moves: line.

    Returns a list of {"number", "title", "moves", "merged_at"} or [] on
    failure. The gh search is cached to WEEK_LATER_CACHE_TTL so the exporter
    does not hammer the API every 5-min tick; a stale cache is served on a
    gh failure (the window is wide enough that a missed tick is caught later).
    """
    cached, age = _read_cache(WEEK_LATER_CACHE)
    if age is not None and age <= WEEK_LATER_CACHE_TTL and cached is not None:
        return cached
    data = _gh_week_later_prs()
    if data is not None:
        _write_cache(WEEK_LATER_CACHE, data)
        return data
    if cached is not None:
        print("week-later: gh failed, serving stale PR list", file=sys.stderr)
        return cached
    return []


def _gh_week_later_prs():
    """Query GitHub for fleet-ops PRs merged ~7 days ago with a moves: line.

    One paginated GraphQL search across Nishfleet/fleet-ops for PRs merged in
    [now-7d-WINDOW, now-7d+WINDOW]. Returns a list of {"number", "title",
    "moves", "merged_at"} for PRs whose body carries a `moves:` line, or None
    on failure. The cutoff is interpolated as a literal in the search string
    (GraphQL does not expand variables inside `search(query: ...)`).
    """
    now = time.time()
    start = now - 7 * 86400 - WEEK_LATER_WINDOW_S
    end = now - 7 * 86400 + WEEK_LATER_WINDOW_S
    start_iso = datetime.fromtimestamp(start, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    end_iso = datetime.fromtimestamp(end, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    query = (
        "query($cursor: String) {\n"
        '  search(query: "repo:Nishfleet/fleet-ops is:pr is:merged '
        f"merged:>={start_iso} merged:<={end_iso} sort:merged-desc\"" "\n"
        "    type: ISSUE, first: 100, after: $cursor) {\n"
        "    pageInfo { hasNextPage endCursor }\n"
        "    nodes {\n"
        "      ... on PullRequest {\n"
        "        number\n"
        "        title\n"
        "        body\n"
        "        mergedAt\n"
        "      }\n"
        "    }\n"
        "  }\n"
        "}\n"
    )
    out = []
    cursor = None
    for _ in range(GH_PAGES):
        payload = _gh_graphql(query, cursor)
        if payload is None:
            return None
        if payload.get("errors"):
            print(f"week-later gh graphql errors: {payload['errors'][:1]}", file=sys.stderr)
            return None
        conn = ((payload.get("data") or {}).get("search") or {})
        for node in conn.get("nodes") or []:
            number = node.get("number")
            if not isinstance(number, int):
                continue
            body = node.get("body") or ""
            m = _MOVES_RE.search(body)
            if not m:
                continue
            out.append({
                "number": number,
                "title": node.get("title") or "",
                "moves": m.group(1).strip(),
                "merged_at": node.get("mergedAt") or "",
            })
        page = conn.get("pageInfo") or {}
        if not page.get("hasNextPage"):
            return out
        cursor = page.get("endCursor")
        if not cursor:
            return out
    print("week-later gh search: hit page cap", file=sys.stderr)
    return out


def _prom_query_value(expr, time_epoch):
    """Return the value of a Prometheus instant query at time_epoch, or None."""
    params = urllib.parse.urlencode({"query": expr, "time": str(time_epoch)})
    url = f"{WEEK_LATER_PROM_URL}?{params}"
    try:
        with urllib.request.urlopen(url, timeout=WEEK_LATER_PROM_TIMEOUT) as r:  # nosemgrep
            payload = json.load(r)
    except (urllib.error.URLError, urllib.error.HTTPError, OSError,
            json.JSONDecodeError) as exc:
        print(f"week-later prom query failed: {exc}", file=sys.stderr)
        return None
    if payload.get("status") != "success":
        return None
    result = (payload.get("data") or {}).get("result") or []
    if not result:
        return None
    try:
        return float(result[0].get("value")[1])
    except (TypeError, ValueError, IndexError):
        return None


def _metric_7d_value(metric, time_epoch):
    """Return the metric's 7d average value at time_epoch, or None.

    The 7d value is avg_over_time(<metric expr>[7d:1d]) evaluated at
    time_epoch — the average daily value over the 7 days ending there. None
    when the metric has no mapped expression or Prometheus cannot answer.
    """
    expr = _MOVES_METRIC_QUERIES.get(metric)
    if not expr:
        return None
    return _prom_query_value(f"avg_over_time({expr}[7d:1d])", time_epoch)


def _revert_candidate_exists(pr_number, metric):
    """True when an open revert-candidate issue for this PR already exists.

    Dedup by exact title match against open issues whose title contains
    "revert candidate". Fail-safe: on any gh failure return True so a PR is
    never double-filed (a transient gh error must not create a duplicate).
    """
    target = f"revert candidate: #{pr_number} did not move {metric}"
    try:
        r = subprocess.run(
            ["gh", "issue", "list", "-R", "Nishfleet/fleet-ops",
             "--state", "open", "--search", "revert candidate in:title",
             "--json", "number,title", "--limit", "50"],
            capture_output=True, text=True, timeout=GH_TIMEOUT,
            env={**os.environ, "GH": "/usr/bin/gh"},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"week-later dedup gh issue list failed: {exc}", file=sys.stderr)
        return True
    if r.returncode != 0:
        print(f"week-later dedup gh issue list rc={r.returncode}", file=sys.stderr)
        return True
    try:
        rows = json.loads(r.stdout or "[]")
    except json.JSONDecodeError:
        return True
    return any((row.get("title") or "") == target for row in rows)


def _file_revert_candidate(pr_number, metric, before, after, merged_at):
    """File one revert-candidate issue. Returns True on success."""
    title = f"revert candidate: #{pr_number} did not move {metric}"
    marker = f"signal: revert-candidate/{pr_number}/{metric}"
    body = (
        f"Revert candidate: PR #{pr_number} (merged {merged_at}) carried "
        f"`moves: {metric}` but the metric's 7d value did not improve after "
        f"merge.\n\n"
        f"before: {before}\n"
        f"after: {after}\n\n"
        f"termination: revert PR for #{pr_number} merged\n\n"
        f"{marker}\n"
    )
    try:
        r = subprocess.run(
            ["gh", "issue", "create", "-R", "Nishfleet/fleet-ops",
             "--title", title, "--label", "agent-ready", "--body", body],
            capture_output=True, text=True, timeout=GH_TIMEOUT,
            env={**os.environ, "GH": "/usr/bin/gh"},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"week-later gh issue create failed: {exc}", file=sys.stderr)
        return False
    if r.returncode != 0:
        print(f"week-later gh issue create rc={r.returncode}: {r.stderr.strip()[:200]}",
              file=sys.stderr)
        return False
    return True


def _read_week_later_state():
    """Return the per-PR evaluation ledger dict, or {} on failure."""
    try:
        data = json.loads(WEEK_LATER_STATE.read_text())
        if isinstance(data, dict):
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return {}


def _write_week_later_state(state, now):
    """Persist the ledger, pruning entries older than WEEK_LATER_STATE_TTL."""
    pruned = {
        k: v for k, v in state.items()
        if isinstance(v, dict) and (now - (v.get("checked_at") or 0)) <= WEEK_LATER_STATE_TTL
    }
    try:
        _atomic_write(WEEK_LATER_STATE, json.dumps(pruned, sort_keys=True))
    except OSError as exc:
        print(f"week-later state write: {exc}", file=sys.stderr)


def _week_later_revert_check():
    """Run the week-later revert-candidate check. Returns a summary string.

    Never raises and never fails the exporter: every gh/Prometheus failure is
    logged and the PR is left unevaluated (retried on a later tick). A PR is
    evaluated at most once (the state ledger), so the gh dedup/create calls
    are bounded to one per PR.
    """
    prs = _week_later_prs()
    if not prs:
        return "week-later: no fleet-ops PRs merged ~7d ago with a moves: line"
    state = _read_week_later_state()
    now = time.time()
    filed = 0
    skipped = 0
    for pr in prs:
        number = pr["number"]
        metric = pr["moves"]
        if metric not in _MOVES_METRIC_QUERIES:
            continue  # metric not yet mapped to a Prometheus query
        if str(number) in state:
            skipped += 1
            continue
        merged_epoch = _parse_iso_utc(pr["merged_at"])
        if merged_epoch is None:
            continue
        before = _metric_7d_value(metric, merged_epoch)
        after = _metric_7d_value(metric, now)
        if before is None or after is None:
            continue  # Prometheus unavailable; retry on a later tick
        if after > before:
            state[str(number)] = {"checked_at": now, "verdict": "improved"}
            continue
        if _revert_candidate_exists(number, metric):
            state[str(number)] = {"checked_at": now, "verdict": "already-filed"}
            skipped += 1
            continue
        if _file_revert_candidate(number, metric, before, after, pr["merged_at"]):
            state[str(number)] = {"checked_at": now, "verdict": "filed"}
            filed += 1
    _write_week_later_state(state, now)
    return f"week-later: filed={filed} skipped={skipped}"


# --- Main ------------------------------------------------------------------

def _ensure_worker_token() -> None:
    """Use the nishfleet-worker App token for any GitHub write (fleet-ops#3445).

    Fail closed if the App cannot mint and no token was inherited from a parent
    organ, so a dead App never falls through to the human gh identity. Human gh
    is read-only for organs. GH Actions (tests) has no App creds and stubs gh
    as read-only, so skip minting there.
    """
    if os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_ACTIONS") == "true":
        return
    wt = os.environ.get(
        "NISHFLEET_WORKER_TOKEN_BIN",
        f"{os.environ.get('HOME', '/home/nish')}/.local/bin/worker-token",
    )
    try:
        out = subprocess.run(
            [wt, "--print"], capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("fleet-ops#3445: worker-token --print failed - refusing human-gh writes: %s" % exc, file=sys.stderr)
        sys.exit(1)
    if out.returncode != 0:
        print("fleet-ops#3445: worker-token --print rc=%s - refusing human-gh writes: %s" % (out.returncode, out.stderr.strip()[:200]), file=sys.stderr)
        sys.exit(1)
    for line in out.stdout.splitlines():
        if line.startswith("export GH_TOKEN="):
            os.environ["GH_TOKEN"] = line[len("export GH_TOKEN="):].strip()
            return
    print("fleet-ops#3445: worker-token --print output not an export GH_TOKEN line - refusing human-gh writes", file=sys.stderr)
    sys.exit(1)


def main():
    _ensure_worker_token()
    # fleet-ops#2273: remove the legacy fleet-staleness.prom textfile at the
    # start of every run. The staleness checker used to write there directly;
    # it now emits through this exporter into fleet.prom via the JSON cache.
    # node_exporter reads every .prom file in the textfile dir, so a stale
    # copy's duplicate fleet_truth_staleness_* metrics shadow the fresh values.
    # Do this first so the cleanup runs even on a fail-loud early return.
    try:
        LEGACY_STALENESS_PROM.unlink()
    except FileNotFoundError:
        pass

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
    # fleet-ops#3111: seat-health age. A stale feed (>30 min) is UNKNOWN, never
    # "healthy". -1 when observed_at is absent/unparseable so the alert rule can
    # distinguish "no data" from "fresh". Drives FleetPiSeatHealthStale.
    age = -1
    if observed_epoch is not None:
        age = int(time.time()) - observed_epoch
    lines.append("")
    lines.append(HELP_AGE)
    lines.append(TYPE_AGE)
    lines.append(f"fleet_pi_seat_health_age_seconds {age}")
    # fleet-ops#1445: surface dead-credential seats once per tick as a distinct
    # signal. These seats are seat_dead=true + credentials_bad (HTTP 401/403);
    # the total gauge drives the alert rule and the per-seat series names each
    # seat. fleet-ops#2667: the per-seat series carries health_class so the
    # reader can tell a re-authable seat (credentials_bad) from a terminal
    # corpse that must be retired from the seat map instead.
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
        _hcl = _prom_label(str(_s.get("health_class") or ""))
        lines.append(
            f'fleet_pi_seat_dead_credential{{seat="{_seat_label}",http_status="{_st}",health_class="{_hcl}"}} 1'
        )
    # fleet-ops#2407: surface comeback-overdue seats (still classed non-healthy
    # past their usable_at/bench_until — released by the router's fail-open but
    # never re-observed since). The total gauge drives the alert rule; the
    # per-seat series names each lingering seat so the repair worker knows who
    # to probe. .spawn-bench markers and test__ fixtures are synthetic, and
    # seat_dead corpses are deliberately terminal (FleetDeadCredentialSeats
    # owns them) — none of them appear here.
    _cb_n, _cb = _read_comeback_overdue()
    lines.append("")
    lines.append(HELP_CB)
    lines.append(TYPE_CB)
    lines.append(f"fleet_seat_comeback_overdue_total {_cb_n}")
    lines.append("")
    lines.append(HELP_CBP)
    lines.append(TYPE_CBP)
    for _s in _cb:
        _seat_label = _prom_label(
            "{}__{}".format(_s["provider"], _s["model"]).strip("_") or "unknown"
        )
        _hc = _prom_label(str(_s.get("health_class") or ""))
        lines.append(
            f'fleet_seat_comeback_overdue{{seat="{_seat_label}",health_class="{_hc}"}} 1'
        )
    # fleet-ops#2638: never-probed comeback visibility. A seat in this gauge
    # means the comeback-release prober has fired on it >=10 times, the seat
    # has not recovered, and the next sweep will corpse it. Sustained > 0 here
    # is the loud signal that the release path is operating on a chronically
    # failing seat — the repair worker should expect a fleet_seat_comeback_release_corpse_total
    # increment on the next sweep and may want to inspect the provider before
    # the next bench window. Per-seat series names each stuck seat.
    _nr_n, _nr = _read_never_released()
    lines.append("")
    lines.append(HELP_NRT)
    lines.append(TYPE_NRT)
    lines.append(f"fleet_seat_comeback_never_released_total {_nr_n}")
    lines.append("")
    lines.append(HELP_NRP)
    lines.append(TYPE_NRP)
    for _s in _nr:
        _seat_label = _prom_label(
            "{}__{}".format(_s["provider"], _s["model"]).strip("_") or "unknown"
        )
        _hc = _prom_label(str(_s.get("health_class") or ""))
        _count = int(_s.get("count") or 0)
        lines.append(
            f'fleet_seat_comeback_never_released{{seat="{_seat_label}",health_class="{_hc}",count="{_count}"}} 1'
        )
    # fleet-ops#2712: provider-level (account-level) quota exhaustion.
    # Group quota_exhausted seats by provider; emit a 1-row per affected
    # provider with the seat count so the repair worker can see the burst
    # size, and a total gauge for the alert rule. The alert rule
    # (FleetProviderQuotaExhausted, config/fleet_rules.yml) catches the
    # "one billing wall, many seats" pattern that the per-seat
    # health_class=quota_exhausted signal alone cannot.
    _pqe_n, _pqe = _read_provider_quota_exhausted()
    lines.append("")
    lines.append(HELP_PQE)
    lines.append(TYPE_PQE)
    lines.append(f"fleet_provider_quota_exhausted_total {_pqe_n}")
    lines.append("")
    lines.append(HELP_PQEP)
    lines.append(TYPE_PQEP)
    for _s in _pqe:
        _prov = _prom_label(str(_s.get("provider") or ""))
        _seats = int(_s.get("seats") or 0)
        lines.append(
            f'fleet_provider_quota_exhausted{{provider="{_prov}",seats="{_seats}"}} 1'
        )
    # fleet-ops#2738: healthy-but-parked visibility. A seat whose ledger is
    # healthy (health_class=healthy, seat_dead=false) but whose model cap in
    # seat-caps.json is 0 is silently costing throughput — pick_seat skips it
    # every tick while the seat-availability SLO burns. The total gauge drives
    # the alert/WFR lens; the per-seat series names each parked seat so the
    # repair worker knows which cap to restore. Sustained > 0 here is the loud
    # signal that a restore was forgotten (the devin/glm-5-2 lapse lived here
    # for 3+ days with no metric surfacing it).
    _hc0_n, _hc0 = _read_healthy_cap0()
    lines.append("")
    lines.append(HELP_HCAP0)
    lines.append(TYPE_HCAP0)
    lines.append(f"fleet_seat_healthy_cap0_total {_hc0_n}")
    lines.append("")
    lines.append(HELP_HCAP0P)
    lines.append(TYPE_HCAP0P)
    for _s in _hc0:
        _seat_label = _prom_label(
            "{}__{}".format(_s["provider"], _s["model"]).strip("_") or "unknown"
        )
        lines.append(
            f'fleet_seat_healthy_cap0{{seat="{_seat_label}"}} 1'
        )
    # fleet-ops#3111: stale cap=0 seats. A stale cap=0 seat
    # (intentional_cap_zero=stale) has a dated reason and should be
    # re-auditioned; seat-lib auto-expires it to cap=1 after 14d. This metric
    # surfaces them BEFORE the expiry so the operator can re-audition or
    # re-date the reason. age_seconds=-1 means undated (expires first).
    _sc0_n, _sc0 = _read_cap0_stale()
    lines.append("")
    lines.append(HELP_SC0T)
    lines.append(TYPE_SC0T)
    lines.append(f"fleet_seat_cap0_stale_total {_sc0_n}")
    lines.append("")
    lines.append(HELP_SC0)
    lines.append(TYPE_SC0)
    for _s in _sc0:
        _seat_label = _prom_label(
            "{}__{}".format(_s["provider"], _s["model"]).strip("_") or "unknown"
        )
        _age = int(_s.get("age_seconds", -1))
        lines.append(
            f'fleet_seat_cap0_stale{{seat="{_seat_label}",age_seconds="{_age}"}} 1'
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
    main_ci = {}
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
    # is a 7d-smoothed level (avg_over_time[7d] > 0.64) — see
    # config/fleet_rules.yml FleetQueueSelfMaintenanceRatioHigh
    # (fleet-ops#2171).
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

    # --- Per-alertname repair outcomes (fleet-ops#1291 alert-quality) ---
    # Feeds the WFR alert-quality lens: dispatch vs skipped = action rate,
    # resolved vs failed = success rate, repeated failed = noisy/unactionable.
    # fleet-ops#2694: phantom_resolved counts RESOLVED entries whose
    # root_cause starts with PHANTOM_ALERT (drill fixtures, no real defect)
    # so the lens can flag phantom drift without conflating it with real
    # fixes.
    per_alert = _repair_log_per_alertname_24h()
    if per_alert:
        lines.append("")
        lines.append(HELP_AD)
        lines.append(TYPE_AD)
        for name in sorted(per_alert):
            counts = per_alert[name]
            lbl = _prom_label(name)
            for kind in ("dispatch", "resolved", "failed", "skipped",
                         "phantom_resolved"):
                lines.append(
                    f'fleet_alert_outcome_24h{{alertname="{lbl}",kind="{kind}"}} '
                    f'{counts[kind]}'
                )

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

    # --- Seat yield ledger (fleet-ops#3250) ---
    # Computed from the agent's own pi-issue session files. Per-seat rolling
    # last-20-sessions PR yield; new/idle seats get a provisional 0.5 yield
    # so they are tried, not starved. Emits the family and writes a JSON
    # sidecar for lib/seat-lib.sh pick_seat to consume.
    seat_yield = _compute_seat_yield()
    _emit_seat_yield(lines, seat_yield)

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

    # --- SLO error budgets (fleet-ops#1291) ---
    # Emitted last so every source the SLOs read (CI rollup, seat health,
    # rate limit, waste ratio) has been gathered this tick. fleet_pi_seat_total
    # is the seat_availability denominator; published here so the SLO's
    # compliance is auditable from the raw gauges alone.
    _seat_total = _enrolled_seat_total()
    if _seat_total is not None:
        lines.append("")
        lines.append(HELP_SEAT_TOTAL)
        lines.append(TYPE_SEAT_TOTAL)
        lines.append(f"fleet_pi_seat_total {_seat_total}")
    _emit_slo_metrics(lines, main_ci, healthy, rl)

    # --- Deployment quality SLOs (fleet-ops#2758) ---
    # Emitted after the SLO family so every data source this module reads
    # (gh, journal, actions log) is complete for the tick; a module fault
    # degrades to NaN + up 0 (see _emit_deploy_quality) and never fails
    # the exporter oneshot.
    _emit_deploy_quality(lines)

    # --- blocked-reconcile nish-decision lint (fleet-ops#3312) ---
    # Per-sweep count of rejected `blocked-on: nish-decision` lines.
    _emit_blocked_reconcile(lines)

    # --- close-duplicates close guard (fleet-ops#3161) ---
    # Per-tick close count by label; cross_repo and protected must stay 0.
    _emit_close_duplicates(lines)

    # --- observe-to-close close guard (fleet-ops#3231) ---
    # Per-tick close count by reason; bare-mention and protected must stay 0.
    _emit_observe_to_close(lines)

    # --- Week-later revert check (fleet-ops#3124 part 4/4) ---
    # For each fleet-ops PR merged ~7 days ago with a `moves:` metric, compare
    # the metric's 7d value before vs after; if it did not improve, file ONE
    # revert-candidate issue (never re-filed). Non-fatal: a failure is logged
    # and the exporter still writes fleet.prom.
    _week_later_revert_check()

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
