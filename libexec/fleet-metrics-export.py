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
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone
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
    # A test injects a fake gh (GH != 'gh'); no human gh write is possible, so
    # skip minting there too. Production callers never set GH.
    if os.environ.get("GH", "gh") != "gh":
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
# fleet-ops#4627: per-class healthy seat count. The money-boundary starvation
# gate pages Nish ONLY when the fleet is starved — no healthy prepaid/free
# seat. This gauge exposes the per-class healthy-enrolled count so the alert
# rule and the success metric can key on it. A dry metered provider is a lane
# fault while fleet_seat_healthy{class=~"prepaid|free"} > 0.
HELP_SHC = "# HELP fleet_seat_healthy Number of healthy enrolled providers by seat class (prepaid / free). A dry metered provider is a lane fault while this is > 0 for prepaid/free; the money-boundary page fires only when the fleet is starved (fleet-ops#4627)."
TYPE_SHC = "# TYPE fleet_seat_healthy gauge"
# fleet-ops#4627: money-boundary page counter. The writer
# (bin/money-boundary-raise) appends one line per page to
# money-boundary-pages.log; this counter rolls them up by reason over the
# trailing 7d. The success metric is
# nish_boundary_money_pages_total{reason="provider_credits_dry"} == 0 while
# fleet_seat_healthy{class=~"prepaid|free"} > 0.
HELP_MBPT = "# HELP nish_boundary_money_pages_total Number of MONEY-BOUNDARY pages delivered to Nish by reason over the trailing 7 days (fleet-ops#4627). Suppressed pages (fleet not starved) do not count."
TYPE_MBPT = "# TYPE nish_boundary_money_pages_total counter"
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
HELP_OOMD = "# HELP fleet_oomd_kills_6h systemd-oomd kills of app-pi-issue.slice units in the trailing 6h, by unit (fleet-ops#4164). A rise > 3 in 6h trips FleetOomdKillsHigh, whose repair packet raises the live ram_gb_per_worker charge back to 2.0. Counts only oomd-managed kills (MESSAGE=Killed unit or Killed process), not kernel OOM."
TYPE_OOMD = "# TYPE fleet_oomd_kills_6h gauge"
HELP_RDISP = "# HELP fleet_repair_dispatch_24h DISPATCH lines in alert-repair actions.log within 24h."
TYPE_RDISP = "# TYPE fleet_repair_dispatch_24h gauge"
HELP_RSKIP = "# HELP fleet_repair_skip_24h SKIP lines in alert-repair actions.log within 24h."
TYPE_RSKIP = "# TYPE fleet_repair_skip_24h gauge"
HELP_AD = "# HELP fleet_alert_outcome_24h Per-alertname repair outcomes in the trailing 24h (fleet-ops#1291 alert-quality). kind=dispatch|resolved|failed|skipped|phantom_resolved. phantom_resolved = RESOLVED entries whose root_cause starts with PHANTOM_ALERT (drill fixtures, not real repair work) — the WFR alert-quality lens reads phantom_resolved>5/24h as phantom-drift regression (fleet-ops#2694). Feeds the WFR alert-quality lens."
TYPE_AD = "# TYPE fleet_alert_outcome_24h gauge"
HELP_OPEN = "# HELP fleet_open_prs Open pull-request count per repo from a cached org snapshot."
TYPE_OPEN = "# TYPE fleet_open_prs gauge"
HELP_CI = "# HELP fleet_main_ci_green 1 if default-branch CI is green, 0 if red. PENDING rollup resolved from latest completed CI run; repos with no CI omitted. Tracks only the workflow literally named \"CI\" — a repo's production-deploy greenness is fleet_product_deploy_green (fleet-ops#5140)."
TYPE_CI = "# TYPE fleet_main_ci_green gauge"
HELP_FRESH = "# HELP fleet_gh_cache_fresh 1 if this gh-derived family is served from a cache younger than 2h."
TYPE_FRESH = "# TYPE fleet_gh_cache_fresh gauge"
HELP_CTS = "# HELP fleet_gh_cache_timestamp_seconds Epoch seconds at which the served data for this gh-derived family was MEASURED. Equals the cache write time when the cache was served, and the export time when gh was just fetched. A consumer of a cached family (the console tiles) must stamp this, not its own run time: stamping the export time on a <=30 min old count reads as seconds-fresh (fleet-ops#5155, ConsoleLying tile=open_prs)."
TYPE_CTS = "# TYPE fleet_gh_cache_timestamp_seconds gauge"

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

# Worktree reaper summary (fleet-ops#4118). bin/fleet-worktree-reaper writes
# a JSON breakdown here on every daily timer run: post_count (dirs left under
# agent-worktrees after the reap), reaped, skipped_* breakdown, and the run
# timestamp. The heartbeat exporter reads it to emit the count metric the
# heartbeat can gauge (fleet_worktree_dirs) plus a liveness signal. A summary
# older than WORKTREE_REAPER_STALE_S (7d, matching the retired opus-heartbeat
# REAPER_STALE_S) is treated as stale — the reaper missed a week of daily runs.
WORKTREE_REAPER_SUMMARY = Path(
    "/home/nish/workspaces/agent-state/worktree-reaper-last-run.json"
)
WORKTREE_REAPER_STALE_S = 7 * 86400

# Worktree reaper gauge family (fleet-ops#4118). fleet_worktree_dirs is the
# count of dirs left under agent-worktrees after the last reap — the
# unbounded-growth invariant the issue tracks. fleet_worktree_reaped_total is
# how many the reaper removed that run. The present gauge is ALWAYS emitted so
# the heartbeat can tell a dead reaper (0) from a healthy one (1); the count
# gauges are emitted only when the summary is present and fresh (a missing or
# stale summary means the count is unknown, not 0).
HELP_WTP = (
    "# HELP fleet_worktree_reaper_present 1 when the worktree reaper's last-run "
    "summary is present and fresh, 0 when missing/unparseable/stale. The "
    "liveness signal for the reaper organ (fleet-ops#4118)."
)
TYPE_WTP = "# TYPE fleet_worktree_reaper_present gauge"
HELP_WTD = (
    "# HELP fleet_worktree_dirs Number of directories left under agent-worktrees "
    "after the last worktree-reaper run (post_count). The count metric the "
    "heartbeat gauges for unbounded worktree sprawl (fleet-ops#4118)."
)
TYPE_WTD = "# TYPE fleet_worktree_dirs gauge"
HELP_WTR = (
    "# HELP fleet_worktree_reaped Number of worktrees the reaper removed "
    "in its last run (fleet-ops#4118)."
)
TYPE_WTR = "# TYPE fleet_worktree_reaped gauge"
HELP_WTHB = (
    "# HELP fleet_worktree_reaper_heartbeat_seconds Epoch (s) of the reaper's "
    "last-run summary timestamp. Its presence is the freshness signal for the "
    "reaper organ; absent() fires when the reaper is dead (fleet-ops#4118)."
)
TYPE_WTHB = "# TYPE fleet_worktree_reaper_heartbeat_seconds gauge"

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
# seat-caps.json is the source of truth for enrolled-seat count
# (fleet_pi_seat_total) — providers with cap>0 are enrolled.
# fleet-ops#3811: the LIVE caps file the seat organs actually use comes
# first (same source as lib/seat-lib.sh SEAT_CAPS_JSON), then the repo
# checkouts as fallbacks. Validating comeback metrics against a stale repo
# checkout while the organs use the live file makes the two
# _seat_key_in_caps implementations disagree — a seat can be phantom to the
# metric and real to the organ (or the reverse), which was part of the
# comeback-release starvation this issue names.
SEAT_CAPS_LIVE = Path(
    os.environ.get(
        "SEAT_CAPS_JSON",
        "/home/nish/.local/state/pi-packet/seat-caps.json",
    )
)
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
# --- Seat spend + provider balance (fleet-ops#3283) ---
# Pi session jsonl already carries usage.cost per message; we sum it per
# provider per UTC day. The per-file mtime cache keeps re-export cheap.
SPEND_CACHE = PR_CACHE_DIR / "seat-spend-sessions-cache.json"
# Vendor API credentials. OpenRouter's key lives in the pi provider config
# models.json (the same config pi itself authenticates with); the xKiro key
# lives in its dotenv file. We read both with env-var override.
OPENROUTER_MODELS_JSON = Path(
    os.environ.get("OPENROUTER_MODELS_JSON", str(Path.home() / ".pi" / "agent" / "models.json"))
)
OPENROUTER_ENV_FILE = Path.home() / ".config" / "openrouter" / ".env"
XKIRO_ENV_FILE = Path.home() / ".config" / "xkiro" / ".env"
# At most one vendor HTTP fetch per exporter run; cached 30 min, stale 2 h.
VENDOR_BALANCE_TTL = 1800
VENDOR_BALANCE_STALE = 7200
OPENROUTER_BALANCE_CACHE = PR_CACHE_DIR / "openrouter-balance-cache.json"
XKIRO_BALANCE_CACHE = PR_CACHE_DIR / "xkiro-balance-cache.json"
# OpenRouter credits response carries total_credits and total_usage but no
# precomputed remaining field (live 2026-09-05); remaining = credits - usage.
OPENROUTER_API_KEY_ENV = "OPENROUTER_API_KEY"

SEAT_YIELD_WINDOW = 20
SEAT_YIELD_PROVISIONAL = 0.5
# fleet-ops#3250/#3310 state the rule "infra deaths never count as seat yield",
# but the ledger below never implemented it: a session that died because the
# PROVIDER failed (resource_exhausted, 429/5xx, connection reset, hang-watchdog
# rc=124/143) was counted as a no-PR miss, so a seat was punished for the
# fleet's own infrastructure. That poisoning already produced wrong verdicts:
# devin/swe-1-7 was retired on it (#3389, corrected in #3473). Matched against
# the final assistant message's structured stopReason/errorMessage pair — never
# free transcript text, so a worker discussing a timeout is not misread.
SEAT_YIELD_INFRA_RE = re.compile(
    r"resource_exhausted|rate[ _-]?limit|\b(?:429|500|502|503|504)\b"
    r"|ETIMEDOUT|ECONNRESET|ECONNREFUSED|socket hang up|connection error"
    r"|timed? ?out|overloaded|unavailable|bad gateway"
    r"|exited with code (?:124|143)|SIGKILL|SIGTERM|no seat available",
    re.I,
)
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
# fleet-ops#3322: per-seat sessions-to-PR percentage (0..100). The issue's
# moves: sessions_to_pr_pct metric. Computed from the same rolling window as
# fleet_seat_yield; emitted as a percentage so the fleet-landing-watch measure
# and the audition verdict share one scale. Does NOT replace
# fleet_sessions_no_pr_total — both are emitted.
HELP_STPR = (
    "# HELP fleet_sessions_to_pr_pct Rolling last-20 issue-work sessions PR "
    "yield as a percentage (0..100) per seat (fleet-ops#3322)."
)
TYPE_STPR = "# TYPE fleet_sessions_to_pr_pct gauge"

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
    # fleet-ops#3563: a held wrapper spawn-bench outranks a later healthy
    # observation. mark_seat_empty_run / mark_seat_spawn_fail co-write this
    # sidecar at bench time (fleet-ops#3559), but a subsequent healthy
    # observation from the seat-health extension — an in-flight run
    # completing after the bench landed, or a comeback probe — rewrites it
    # as health_class=healthy while the marker still holds the seat. The
    # bench and the health file then disagree exactly as this issue
    # reported (live 2026-09-05: devin/glm-5-2 ledger healthy at 23:19Z
    # while its spawn-bench held until 23:55Z). seat_usable already honours
    # the marker; report the seat not-healthy here too so a benched seat
    # never reads healthy on fleet_pi_seat_healthy.
    if healthy and _spawn_bench_held_for(data.get("provider"), data.get("model")):
        healthy = 0
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
            if ".empty-success" in f.name:
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


def _atomic_write(path, text, mode=0o644):
    """Write atomically: tmp in same dir, fsync, os.replace.

    mode defaults to 0644 so node_exporter (different uid) can read the
    textfile. Callers writing credentials must pass 0600 (fleet-ops#4670).
    """
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
    os.chmod(path, mode)


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


def _cache_ts(path):
    """Return the cache's observation ts (epoch), or None if unreadable.

    The quota caches store {"ts": <epoch>, "data": <rows>}; _read_cache ages
    them for TTL decisions but drops the ts. Quota rows need the real ts so
    fleet_seat_quota_observed_seconds reports data age, not export time
    (fleet-ops#4217). None -> caller emits observed_s 0 (fail open).
    """
    try:
        c = json.loads(path.read_text())
        ts = c.get("ts")
        return ts if isinstance(ts, (int, float)) else None
    except (OSError, json.JSONDecodeError):
        return None


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
    """Return {seat, timestamp, has_pr_url, cost} for a pi-issue session .jsonl.

    Seat is taken from the first model_change event; the timestamp is the
    session start time. A session counts as PR-producing if the final
    assistant message text contains a Nishfleet PR URL. cost is the sum of
    message.usage.cost.total across the session (fleet-ops#3323) — 0.0 for
    free lanes and sessions that record no usage.cost. infra_death is True
    when the session ended on a provider-side error (stopReason "error" whose
    errorMessage matches SEAT_YIELD_INFRA_RE); those sessions never count as
    seat yield (fleet-ops#3250/#3310).
    """
    session_ts = None
    model_seat = None
    last_assistant_line = None
    fallback_ts = None
    cost = 0.0
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
                if '"usage"' in line and '"cost"' in line:
                    try:
                        data = json.loads(line)
                        c = (
                            ((data.get("message") or {}).get("usage") or {})
                            .get("cost") or {}
                        ).get("total")
                        if c is not None:
                            cost += float(c)
                    except (json.JSONDecodeError, ValueError, TypeError):
                        pass
                if re.search(r'"role"\s*:\s*"assistant"', line):
                    last_assistant_line = line
    except OSError:
        return None
    if not model_seat:
        return None
    has_pr = False
    infra_death = False
    if last_assistant_line:
        try:
            data = json.loads(last_assistant_line)
            msg = data.get("message") or {}
            content = msg.get("content")
            text = _extract_text(content)
            if PR_URL_RE.search(text):
                has_pr = True
            # A provider-side failure ends the session with stopReason "error"
            # and a structured errorMessage. Only that pair is inspected, so
            # the classification cannot be tripped by transcript prose.
            if msg.get("stopReason") == "error":
                infra_death = bool(
                    SEAT_YIELD_INFRA_RE.search(msg.get("errorMessage") or "")
                )
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
        "cost": cost,
        "infra_death": infra_death,
    }


def _compute_seat_yield():
    """Compute per-seat rolling last-20 issue-work session PR yield and cost.

    Scans FLEET_SESSIONS_DIR/pi-issue-*/**/*.jsonl, caches per-file results
    by mtime, and returns {seat: {yield, sessions, pr_count, provisional,
    cost_per_session}}. cost_per_session is the mean usage.cost over the
    same rolling window (fleet-ops#3323) so pick_seat can rank by value =
    yield / max(cost_per_session, 0.001).
    Also writes the JSON sidecar used by lib/seat-lib.sh pick_seat.
    """
    sessions_dir = Path(SESSIONS_DIR)
    if not sessions_dir.is_dir():
        return {}

    cache = {}
    try:
        data, _age = _read_cache(SEAT_YIELD_CACHE)
        # v3: cached entries carry infra_death (fleet-ops#3250 enforcement);
        # v1/v2 entries lack it, so they are re-parsed once on this tick.
        if isinstance(data, dict) and data.get("v") == 3:
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
                "cost": cached.get("cost", 0.0),
                "infra_death": cached.get("infra_death", False),
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
            "cost": entry["cost"],
            "infra_death": entry["infra_death"],
        }
        sessions.append(entry)

    try:
        _write_cache(SEAT_YIELD_CACHE, {"v": 3, "entries": new_cache})
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
        # Cost keeps the raw last-20 window: an infra death can still burn
        # tokens before it dies, and the audition spend cap (fleet-ops#3322)
        # must keep seeing that spend. Only the QUALITY signal is filtered.
        window = entries[:SEAT_YIELD_WINDOW]
        # fleet-ops#3250/#3310: yield is measured over sessions where the model
        # actually worked. Infra deaths are dropped rather than counted as
        # misses, and the window reaches further back to stay 20 deep, which is
        # exactly the retirement rule's ">= 20 sessions ended with the model
        # working" bar.
        working = [e for e in entries if not e.get("infra_death")]
        infra_deaths = sum(1 for e in window if e.get("infra_death"))
        yield_window = working[:SEAT_YIELD_WINDOW]
        total = len(yield_window)
        pr_count = sum(1 for e in yield_window if e["has_pr_url"])
        no_pr = total - pr_count
        if entries and not working:
            # Every attempt died on infrastructure. There is no quality
            # evidence either way, so the seat is NOT promoted to the
            # provisional 0.5 it would get as a newcomer; benching and caps
            # (seat-lib) own dead seats, not this ledger.
            y = 0.0
            provisional = False
        elif total < SEAT_YIELD_WINDOW:
            y = SEAT_YIELD_PROVISIONAL
            provisional = True
        else:
            y = pr_count / total if total > 0 else 0.0
            provisional = False
        # fleet-ops#3323: mean usage.cost per session over the same window.
        # Sessions with no recorded cost count 0, so free lanes land on 0 and
        # pick_seat's value floor (0.001) sorts them first at equal yield.
        raw_total = len(window)
        cost_per_session = (
            sum(e.get("cost", 0.0) for e in window) / raw_total
            if raw_total > 0 else 0.0
        )
        # fleet-ops#3322: total audition cost (sum over the rolling window).
        # The audition lane caps total spend at $1; cost_usd is the figure the
        # intake tick reads to enforce that cap. cost_per_session stays for the
        # value-ranking path (fleet-ops#3323) — both are written so existing
        # consumers are unaffected.
        cost_usd = sum(e.get("cost", 0.0) for e in window) if raw_total > 0 else 0.0
        result[seat] = {
            "yield": y,
            "sessions": total,
            "pr_count": pr_count,
            "no_pr_count": no_pr,
            "provisional": provisional,
            "infra_deaths": infra_deaths,
            "cost_per_session": cost_per_session,
            "cost_usd": cost_usd,
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
    lines.append("")
    lines.append(HELP_STPR)
    lines.append(TYPE_STPR)
    for seat in sorted(seat_yield):
        y = seat_yield[seat]
        lbl = _prom_label(seat)
        lines.append(f'fleet_seat_yield{{seat="{lbl}"}} {y["yield"]:.6f}')
        lines.append(
            f'fleet_sessions_no_pr_total{{seat="{lbl}"}} {y["no_pr_count"]}'
        )
        # fleet-ops#3322: sessions-to-PR percentage (0..100).
        pct = (y["yield"] * 100.0) if isinstance(y.get("yield"), (int, float)) else 0.0
        lines.append(f'fleet_sessions_to_pr_pct{{seat="{lbl}"}} {pct:.2f}')


def _day_from_iso(s):
    """Return YYYY-MM-DD UTC day from an ISO timestamp, or None."""
    if not s:
        return None
    epoch = _parse_iso_utc(s)
    if epoch is None:
        return None
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%d")


def _parse_session_file_for_cost(path):
    """Return {provider: {day: cost}} for a session jsonl.

    Pi session jsonl carries the provider only on `model_change` lines, not
    on `message` lines (fleet-ops#3283, live session shape). We track the
    active provider as we walk the file and attribute each message's
    usage.cost.total to that provider on the message's UTC day. Messages
    with no usage.cost, a zero cost, or an unparseable line are ignored;
    a file with no model_change contributes nothing.
    """
    spend = {}
    provider = None
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                if not line.startswith("{"):
                    continue
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(data, dict) or "type" not in data:
                    continue
                t = data.get("type")
                if t == "model_change":
                    provider = data.get("provider")
                    continue
                if t != "message":
                    continue
                msg = data.get("message") or {}
                if not isinstance(msg, dict):
                    continue
                # Pi session jsonl nests per-message cost under message.usage
                # (fleet-ops#3283, live shape). Fall back to the tracked
                # model_change provider, or the message's own provider key.
                if not provider:
                    provider = msg.get("provider")
                if not provider:
                    continue
                cost = ((msg.get("usage") or {}).get("cost") or {}).get("total")
                if cost is None:
                    continue
                try:
                    cost = float(cost)
                except (ValueError, TypeError):
                    continue
                if cost == 0:
                    continue
                ts = data.get("timestamp") or ""
                day = _day_from_iso(ts)
                if day is None:
                    continue
                spend.setdefault(provider, {}).setdefault(day, 0.0)
                spend[provider][day] += cost
    except OSError:
        return None
    return spend


def _compute_spend():
    """Compute seat spend per provider per UTC day from session jsonl.

    Scans FLEET_SESSIONS_DIR/**/*.jsonl, caches per-file results by mtime,
    and returns {provider: {day: cost}}.
    """
    sessions_dir = Path(SESSIONS_DIR)
    if not sessions_dir.is_dir():
        return {}

    cache = {}
    try:
        data, _age = _read_cache(SPEND_CACHE)
        if isinstance(data, dict) and data.get("v") == 1:
            cache = data.get("entries") or {}
    except (OSError, json.JSONDecodeError):
        pass

    new_cache = {}
    spend = {}
    # Scan ALL pi session jsonl (interactive + pi-issue) so metered spend is
    # not hidden. Live check: ~$188 of minimax spend lives in --home-nish--
    # (interactive) sessions, not pi-issue-* — restricting to worker dirs
    # would miss exactly the spend the zero-revenue rule needs to see.
    # The mtime cache keeps re-scans cheap (first cold scan ~15s, cached ~0s).
    dirty = False
    for path in sessions_dir.rglob("*.jsonl"):
        try:
            mtime_s = int(path.stat().st_mtime)
        except OSError:
            continue
        key = str(path)
        cached = cache.get(key)
        if isinstance(cached, dict) and cached.get("mtime_s") == mtime_s:
            entry = cached.get("spend") or {}
        else:
            entry = _parse_session_file_for_cost(path)
            dirty = True
            if entry is None:
                continue
        new_cache[key] = {"mtime_s": mtime_s, "spend": entry}
        for provider, days in entry.items():
            prov = spend.setdefault(provider, {})
            for day, cost in days.items():
                prov[day] = prov.get(day, 0.0) + cost

    # Rewrite the cache only when a file was actually re-parsed, so a quiet
    # 5-min tick does not churn-write the multi-thousand-entry cache.
    if dirty:
        try:
            _write_cache(SPEND_CACHE, {"v": 1, "entries": new_cache})
        except OSError:
            pass

    return spend


HELP_SPEND = (
    "# HELP fleet_seat_spend_usd Seat spend in USD per provider per UTC day "
    "from pi session usage.cost (fleet-ops#3283)."
)
TYPE_SPEND = "# TYPE fleet_seat_spend_usd gauge"
# Bound the family's cardinality: only the trailing retention window is
# exported so old days do not accumulate in Prometheus forever.
SPEND_RETENTION_DAYS = 30
HELP_SPEND_TODAY = (
    "# HELP fleet_seat_spend_today_usd Seat spend in USD per provider for the "
    "current UTC day (fleet-ops#3284). The day-labelled fleet_seat_spend_usd "
    "series cannot express 'today' in a static PromQL rule (the label is a "
    "date string, not comparable to now()), so the spend-boundary alert rules "
    "on this day-less copy of the current day's row."
)
TYPE_SPEND_TODAY = "# TYPE fleet_seat_spend_today_usd gauge"
HELP_CREDITS = (
    "# HELP fleet_seat_credits_remaining_usd Remaining account balance in USD "
    "for metered providers from vendor credits/usage endpoints (fleet-ops#3283)."
)
TYPE_CREDITS = "# TYPE fleet_seat_credits_remaining_usd gauge"
HELP_FREE_TOKENS = (
    "# HELP fleet_seat_free_tokens_remaining Remaining free-tier tokens "
    "for xkiro (fleet-ops#3283)."
)
TYPE_FREE_TOKENS = "# TYPE fleet_seat_free_tokens_remaining gauge"
HELP_HELD = (
    "# HELP fleet_seat_credits_held_usd Held/pending spend in USD "
    "for xkiro wallet (fleet-ops#3283)."
)
TYPE_HELD = "# TYPE fleet_seat_credits_held_usd gauge"


def _emit_spend(lines, spend):
    """Append fleet_seat_spend_usd family per provider/day (trailing window),
    plus fleet_seat_spend_today_usd{provider} for the current UTC day
    (fleet-ops#3284 — the alert-rule selector)."""
    if not spend:
        return
    now = datetime.now(timezone.utc)
    today = now.strftime("%Y-%m-%d")
    cutoff = (now - timedelta(days=SPEND_RETENTION_DAYS)).strftime("%Y-%m-%d")
    lines.append("")
    lines.append(HELP_SPEND)
    lines.append(TYPE_SPEND)
    today_rows = []
    for provider in sorted(spend):
        for day in sorted(spend[provider]):
            if day < cutoff:
                continue
            lines.append(
                f'fleet_seat_spend_usd{{provider="{_prom_label(provider)}",'
                f'day="{_prom_label(day)}"}} {spend[provider][day]:.6f}'
            )
            if day == today:
                today_rows.append(
                    f'fleet_seat_spend_today_usd{{provider="{_prom_label(provider)}"}} '
                    f'{spend[provider][day]:.6f}'
                )
    if today_rows:
        lines.append("")
        lines.append(HELP_SPEND_TODAY)
        lines.append(TYPE_SPEND_TODAY)
        lines.extend(today_rows)


_HELP_USD24 = (
    "# HELP fleet_usd_24h Rate-card cost of the trailing 24h in USD from "
    "session usage tokens x the seat rate card (fleet-ops#4459). "
    "metered=per-token seats; flat_share=prorated daily share of flat plans."
)
_TYPE_USD24 = "# TYPE fleet_usd_24h gauge"
_HELP_USD_PER_PR = (
    "# HELP fleet_usd_per_merged_pr USD (metered + flat_share) 24h / merged "
    "PRs 24h (fleet-ops#4459). 0 when no PR merged or spend is unreadable."
)
_TYPE_USD_PER_PR = "# TYPE fleet_usd_per_merged_pr gauge"

# fleet-ops#4643: prompt prefix-cache hit ratio. cacheRead is the cached
# prefix; input is uncached prompt tokens. ratio = cacheRead/(input+cacheRead).
# class follows the issue's metered/free vocabulary (prepaid-quota seats bill
# uncached input the same way metered seats do, so they count as metered).
_HELP_CACHE_HIT = (
    "# HELP fleet_prompt_cache_hit_ratio Prefix-cache hit ratio for the "
    "trailing 24h by provider and packet type, from Pi session jsonl usage "
    "(cacheRead / (input + cacheRead); fleet-ops#4643). 0..1. Omitted when no "
    "prompt tokens were recorded for that (provider, packet_type) pair."
)
_TYPE_CACHE_HIT = "# TYPE fleet_prompt_cache_hit_ratio gauge"

_FLEET_USD_MOD = None


def _fleet_usd_mod():
    """Lazily load lib/fleet_usd.py from ../lib/."""
    global _FLEET_USD_MOD
    if _FLEET_USD_MOD is not None:
        return _FLEET_USD_MOD
    import importlib.util
    lib_path = Path(__file__).resolve().parent.parent / "lib" / "fleet_usd.py"
    spec = importlib.util.spec_from_file_location("fleet_usd", lib_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["fleet_usd"] = mod
    spec.loader.exec_module(mod)
    _FLEET_USD_MOD = mod
    return mod


def _resolve_seat_caps_path():
    """First readable seat-caps.json (live file first, repo checkouts fallback)."""
    for path in (SEAT_CAPS_LIVE, SEAT_CAPS_DEFAULT, SEAT_CAPS_FALLBACK):
        try:
            path.read_text()
            return path
        except OSError:
            continue
    return SEAT_CAPS_DEFAULT


def _emit_usd_24h(lines, pr_counts):
    """Emit fleet_usd_24h + fleet_usd_per_merged_pr from rate card x usage.

    Shares the exact rate-card math with measure.sh via lib/fleet_usd.py so the
    judge header and the prom metric cannot drift. pr_counts is the per-repo
    merged-PR map from the detailed fetch (may be None if that fetch failed);
    usd_per_merged_pr is emitted only when a real merge count is available and
    > 0, else it is UNAVAILABLE — never a fabricated $0."""
    try:
        mod = _fleet_usd_mod()
        caps_path = _resolve_seat_caps_path()
        rate_card = mod.load_rate_card(str(caps_path))
        agg, seen_missing, flat = mod.compute_usd_24h(str(SESSIONS_DIR), rate_card)
        metered = sum(
            v for prov, v in agg.items() if not rate_card.get(prov, {}).get("flat")
        )
        flat_share = sum(flat.values())
        lines.append("")
        lines.append(_HELP_USD24)
        lines.append(_TYPE_USD24)
        lines.append(f'fleet_usd_24h{{kind="metered"}} {metered:.6f}')
        lines.append(f'fleet_usd_24h{{kind="flat_share"}} {flat_share:.6f}')
        if pr_counts and sum(pr_counts.values()) > 0:
            merged_total = sum(pr_counts.values())
            lines.append("")
            lines.append(_HELP_USD_PER_PR)
            lines.append(_TYPE_USD_PER_PR)
            per = (metered + flat_share) / merged_total
            lines.append(
                f'fleet_usd_per_merged_pr{{merged_prs="{merged_total}"}} {per:.6f}'
            )
    except Exception as exc:  # noqa: BLE001 — metric must never take main() down
        lines.append(f'# fleet_usd_24h UNAVAILABLE error: {_prom_label(str(exc))[:120]}')


def _emit_cache_hit_ratio(lines):
    """Emit fleet_prompt_cache_hit_ratio{provider,packet_type,class} (fleet-ops#4643).

    Aggregates cacheRead vs uncached input over the trailing 24h of Pi session
    jsonl via lib/fleet_usd.compute_cache_hit_24h. Rows with no prompt tokens
    are omitted by the helper (no denominator). A failure never takes main()
    down — it emits a UNAVAILABLE comment line, matching _emit_usd_24h.
    """
    try:
        mod = _fleet_usd_mod()
        caps_path = _resolve_seat_caps_path()
        rate_card = mod.load_rate_card(str(caps_path))
        rows = mod.compute_cache_hit_24h(str(SESSIONS_DIR), rate_card)
        if not rows:
            return
        lines.append("")
        lines.append(_HELP_CACHE_HIT)
        lines.append(_TYPE_CACHE_HIT)
        for r in rows:
            prov = _prom_label(r["provider"])
            ptype = _prom_label(r["packet_type"])
            cls = _prom_label(r["class"])
            lines.append(
                f'fleet_prompt_cache_hit_ratio{{provider="{prov}",'
                f'packet_type="{ptype}",class="{cls}"}} {r["ratio"]:.6f}'
            )
    except Exception as exc:  # noqa: BLE001 — metric must never take main() down
        lines.append(
            f'# fleet_prompt_cache_hit_ratio UNAVAILABLE error: '
            f'{_prom_label(str(exc))[:120]}'
        )


def _read_env_key(path, names):
    """Return the first matching key from a dotenv file or env var, or None."""
    if path.is_file():
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            text = ""
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key in names and value:
                return value
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


# --- 0509 signups funnel (fleet-ops#4582) --------------------------------
# The direction metric — signups/week (nish→0509 #4518 direction entry) — was
# unmeasured on the control plane: every steering decision stressed a number
# nobody could query. Read it live from 0509's D1 ‘user’ table each tick via
# the SAME sanctioned VPS Cloudflare token + REST “query” endpoint that
# lib/fleet-product-slo.py uses (fleet-ops#4456 / fleet-ops#1166) — no new
# credential is minted. An empty-but-reachable table is a HEALTHY 0 (a real
# value, never a scrape error); an UNREACHABLE source omits the family (the
# exporter's “no fabricated 0” rule), so Prometheus absent() surfaces
# the outage instead of a false zero.
_S7_D1_ACCOUNT = os.environ.get(
    "FLEET_PRODUCT_D1_ACCOUNT", "f670a698e17bf160c8e4679823e68916")
_S7_D1_DATABASE = os.environ.get(
    "FLEET_PRODUCT_D1_DATABASE", "746c6e3d-782e-443a-82d6-28ca93a16294")
_S7_CF_TOKEN_CANDIDATES = [
    os.environ.get("FLEET_PRODUCT_CF_FILE", ""),
    os.path.expanduser("~/.config/cloudflare/deploy-ci.env"),
]
# The SQL is a literal. Only the two Cloudflare ID segments come from config
# and each is validated 32-hex before URL interpolation (see _S7_url). The
# 0509 table is ‘user’ (lowercase), matching fleet-purchase-slo.py's live
# query — the issue's “FROM User” is the conceptual table, not the schema.
_S7_SQL = (
    "SELECT COUNT(*) AS n FROM user "
    "WHERE julianday(createdAt) >= julianday('now','-7 days');"
)
# Hex alphabet for validating the Cloudflare D1 account/database IDs before
# they are interpolated into the fixed api.cloudflare.com URL (fleet-ops#4456).
_HEX = "0123456789abcdefABCDEF"
HELP_S7 = (
    "# HELP fleet_signups_7d Users created in 0509 D1 in the trailing 7 days "
    "(fleet-ops#4582). Source: 0509 D1 user.createdAt via the sanctioned "
    "Cloudflare token (reuses fleet-ops#4456's access path; no new credential). "
    "0 is a healthy-but-empty table, not a failure; the family is omitted only "
    "when the D1 source is unreachable."
)
TYPE_S7 = "# TYPE fleet_signups_7d gauge"



def _s7_cf_token():
    """Return the sanctioned VPS Cloudflare API token, or None.

    fleet-ops#1166: the token file is ~/.config/cloudflare/deploy-ci.env and
    holds CLOUDFLARE_API_TOKEN=<value>. The value is NEVER printed or logged;
    only whether one was found is reported.
    """
    for cand in _S7_CF_TOKEN_CANDIDATES:
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


def _s7_is_d1_id(value):
    """True when value is a Cloudflare D1 ID: 32 hex chars (dashes allowed)."""
    if not isinstance(value, str) or not value:
        return False
    digits = value.replace("-", "")
    return len(digits) == 32 and all(c in _HEX for c in digits)


def _s7_url():
    """The fixed D1 “query” URL with validated ID segments, or None."""
    account = _S7_D1_ACCOUNT
    database = _S7_D1_DATABASE
    if not _s7_is_d1_id(account):
        print("signups_7d: invalid D1 account id (must be hex)", file=sys.stderr)
        return None
    if not _s7_is_d1_id(database):
        print("signups_7d: invalid D1 database id (must be hex)", file=sys.stderr)
        return None
    return (
        "https://api.cloudflare.com/client/v4/accounts/"
        f"{account}/d1/database/{database}/query"
    )


def _fetch_signups_7d():
    """Return the trailing-7-day 0509 signup count, or None when unavailable.

    None means the source could not be READ (no token / network / Cloudflare
    error / bad shape) — the emitter then omits the family. A successful query
    that returns 0 rows returns 0 (a real value). Web call only when a token
    and valid IDs are present, so offline tests stay hermetic (they stub this
    function outright).
    """
    token = _s7_cf_token()
    if not token:
        print(
            "signups_7d: no sanctioned Cloudflare token (fleet-ops#4582)",
            file=sys.stderr,
        )
        return None
    url = _s7_url()
    if url is None:
        return None
    payload = json.dumps({"sql": _S7_SQL}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:  # nosemgrep
            data = json.loads(resp.read().decode("utf-8"))
    except (OSError, ValueError, urllib.error.HTTPError) as exc:
        print(f"signups_7d: D1 query unavailable: {exc}", file=sys.stderr)
        return None
    if not data.get("success"):
        print(
            f"signups_7d: D1 unavailable: cloudflare errors={data.get('errors')}",
            file=sys.stderr,
        )
        return None
    rows = (data.get("result") or [{}])[0].get("results") or []
    try:
        return int(rows[0]["n"])
    except (IndexError, KeyError, TypeError, ValueError):
        print(f"signups_7d: unexpected shape {rows!r}", file=sys.stderr)
        return None


def _emit_signups_7d(lines, signups):
    """Append the fleet_signups_7d gauge, or omit the family when None."""
    if signups is None:
        return
    lines.append("")
    lines.append(HELP_S7)
    lines.append(TYPE_S7)
    lines.append(f"fleet_signups_7d {int(signups)}")


def _resolve_cut_directive(value):
    """Resolve a pi `!cut -d= -f2 /path/to/file` apiKey directive, or return value.

    pi's models.json stores some apiKeys as `!cut -d<sep> -f<n> <file>`: a shell
    command pi runs at load time to read the real key from a dotenv-style file.
    The Python exporter does not run pi, so a raw `!cut ...` string 401s against
    the vendor API (fleet-ops#4217: OpenRouter /key and /credits both 401'd
    with the unresolved directive). Parse and run the cut command ourselves.
    """
    if not isinstance(value, str):
        return None
    if not value.startswith("!cut"):
        return value
    parts = value.split()
    # parts[0] == "!cut"; expect -d<sep> -f<n> <file> (the shape pi writes).
    if len(parts) < 4:
        return None
    delim = None
    field = None
    filepath = None
    i = 1
    while i < len(parts):
        p = parts[i]
        if p.startswith("-d") and len(p) > 2:
            delim = p[2:]
            i += 1
        elif p.startswith("-f") and len(p) > 2:
            try:
                field = int(p[2:])
            except ValueError:
                return None
            i += 1
        elif p.startswith("-d") and i + 1 < len(parts):
            delim = parts[i + 1]
            i += 2
        elif p.startswith("-f") and i + 1 < len(parts):
            try:
                field = int(parts[i + 1])
            except ValueError:
                return None
            i += 2
        else:
            filepath = p
            i += 1
    if delim is None or field is None or filepath is None:
        return None
    try:
        text = Path(filepath).read_text(encoding="utf-8")
    except OSError:
        return None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        cols = line.split(delim)
        if 0 < field <= len(cols):
            v = cols[field - 1].strip().strip('"').strip("'")
            return v or None
    return None


def _openrouter_api_key():
    """Return the OpenRouter API key, or None.

    Resolution order: env var OPENROUTER_API_KEY, then the pi provider config
    models.json (providers.openrouter.apiKey, resolving any `!cut` directive),
    then the dotenv fallback. Never prints the key.
    """
    env_key = os.environ.get(OPENROUTER_API_KEY_ENV)
    if env_key:
        return env_key
    try:
        data = json.loads(OPENROUTER_MODELS_JSON.read_text(encoding="utf-8"))
        key = (data.get("providers") or {}).get("openrouter", {}).get("apiKey")
        if key:
            return _resolve_cut_directive(key)
    except (OSError, json.JSONDecodeError):
        pass
    return _read_env_key(OPENROUTER_ENV_FILE, (OPENROUTER_API_KEY_ENV, "API_KEY"))


# Vendors reject urllib's default User-Agent (xkiro 403'd Python-urllib;
# curl/Mozilla pass, live 2026-09-05). Send an identifiable UA on every fetch.
_VENDOR_USER_AGENT = "fleet-metrics-export/1.0 (Nishfleet; fleet-ops#3283)"


def _fetch_openrouter_credits():
    """Return remaining USD from OpenRouter /api/v1/credits, or None.

    The endpoint returns total_credits and total_usage but no precomputed
    remaining, so remaining = total_credits - total_usage. If only
    total_credits is present we report it as-is (no usage data to subtract).
    None omits the family (never a frozen/bogus value).
    """
    key = _openrouter_api_key()
    if not key:
        return None
    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/credits",
        headers={"Authorization": f"Bearer {key}", "User-Agent": _VENDOR_USER_AGENT},
    )
    try:
        # req URL is a hardcoded constant; only the auth header is dynamic.
        with urllib.request.urlopen(req, timeout=15) as resp:  # nosemgrep
            payload = json.loads(resp.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        print(f"openrouter credits fetch failed: {exc}", file=sys.stderr)
        return None
    data = payload.get("data") or {}
    if not isinstance(data, dict):
        return None
    total = data.get("total_credits")
    usage = data.get("total_usage")
    remaining = data.get("total_remaining")
    try:
        if remaining is not None:
            return float(remaining)
        total = None if total is None else float(total)
        usage = None if usage is None else float(usage)
        if total is not None and usage is not None:
            return total - usage
        if total is not None:
            return total
    except (ValueError, TypeError):
        return None
    return None


def _fetch_xkiro_usage():
    """Return (free_tokens, wallet_balance, wallet_held) for xkiro, or None."""
    key = _read_env_key(XKIRO_ENV_FILE, ("XKIRO_API_KEY", "API_KEY"))
    if not key:
        return None
    req = urllib.request.Request(
        "https://api.xkiro.com/v1/usage",
        headers={"Authorization": f"Bearer {key}", "User-Agent": _VENDOR_USER_AGENT},
    )
    try:
        # req URL is a hardcoded constant; only the auth header is dynamic.
        with urllib.request.urlopen(req, timeout=15) as resp:  # nosemgrep
            payload = json.loads(resp.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        print(f"xkiro usage fetch failed: {exc}", file=sys.stderr)
        return None
    free = payload.get("free_tokens") or {}
    wallet = payload.get("wallet") or {}
    try:
        remaining = free.get("remaining")
        balance = wallet.get("balance_usd")
        held = wallet.get("held_usd")
        remaining = None if remaining is None else int(remaining)
        balance = None if balance is None else float(balance)
        held = None if held is None else float(held)
    except (ValueError, TypeError):
        return None
    if remaining is None and balance is None and held is None:
        return None
    return (remaining, balance, held)


_VENDOR_BALANCE_FETCHED = set()


def _cached_vendor_json(path, fetcher, name):
    """Return fetched/cached vendor data, or None to omit the metric family.

    Fresh cache (<=30 min) skips network. On failure, serve cache up to 2h.
    One fetch per vendor per exporter run so the 5-min oneshot stays under
    the rate-limit budget.
    """
    global _VENDOR_BALANCE_FETCHED
    cached, cache_age = _read_cache(path)
    if cache_age is not None and cache_age <= VENDOR_BALANCE_TTL and cached is not None:
        return cached
    if name in _VENDOR_BALANCE_FETCHED:
        if cached is not None and cache_age is not None and cache_age <= VENDOR_BALANCE_STALE:
            return cached
        return None
    data = fetcher()
    _VENDOR_BALANCE_FETCHED.add(name)
    if data is not None:
        _write_cache(path, data)
        return data
    if cached is not None and cache_age is not None and cache_age <= VENDOR_BALANCE_STALE:
        print(f"{name} vendor fetch failed, serving stale cache (age={int(cache_age)}s)",
              file=sys.stderr)
        return cached
    return None


def _emit_credits_remaining(lines, balances):
    """Append fleet_seat_credits_remaining_usd per provider with a balance."""
    rows = []
    for provider, amount in sorted(balances.items()):
        if amount is not None:
            rows.append(
                f'fleet_seat_credits_remaining_usd{{provider="{_prom_label(provider)}"}} '
                f'{amount:.6f}'
            )
    if rows:
        lines.append("")
        lines.append(HELP_CREDITS)
        lines.append(TYPE_CREDITS)
        lines.extend(rows)


def _emit_xkiro_wallet(lines, xkiro):
    """Append xkiro free tokens and wallet held metrics."""
    if xkiro is None:
        return
    remaining, balance, held = xkiro
    rows = []
    if remaining is not None:
        rows.append(
            f'fleet_seat_free_tokens_remaining{{provider="xkiro"}} {remaining}'
        )
    if held is not None:
        rows.append(
            f'fleet_seat_credits_held_usd{{provider="xkiro"}} {held:.6f}'
        )
    if rows:
        lines.append("")
        lines.append(HELP_FREE_TOKENS)
        lines.append(TYPE_FREE_TOKENS)
        lines.append(HELP_HELD)
        lines.append(TYPE_HELD)
        lines.extend(rows)


# --- Live seat quotas (fleet-ops#4217) ---
# Nish 2026-09-07: the fleet learns a wall reactively (429/402) and benches on
# guesses. This family emits the LIVE remaining quota per seat so judges and
# seat-lib can read it before a decision. Phase 1 (this PR) covers the
# VPS-native API seats whose credentials already live on this host and whose
# quota endpoint answers a token-authenticated GET from the VPS:
#   - OpenRouter /api/v1/key (limit_remaining + limit_reset, verified live)
#   - Claude OAuth api.anthropic.com/api/oauth/usage (five_hour + seven_day
#     utilization + resets_at, verified live from ~/.claude/.credentials.json)
#   - Codex OAuth chatgpt.com/backend-api/wham/usage (rate_limit primary_window
#     used_percent + reset_after_seconds, verified live from ~/.codex/auth.json)
# Browser-session seats (Cursor, Devin, Grok, Ollama, Z.ai, OpenCode, RunInfra,
# ZenMux, Cline, Straitly, MiniMax, CommandCode) need headless-browser login or
# credential repair and are filed as follow-up issues; this PR wires the metric
# family and the API-native reads so those seats slot in as one fetcher each.
# OpenUsage (robinebers/openusage) is the authoritative reference for each
# provider's exact endpoint and auth; the endpoint strings below are copied
# from its provider sources (Sources/OpenUsage/Providers/*) and verified live.
HELP_QUOTA_PCT = (
    "# HELP fleet_seat_quota_remaining_pct Remaining quota as a percentage "
    "(0..100) per provider per window from the provider's own usage/quota "
    "endpoint (fleet-ops#4217). source label: api (VPS-native token read), "
    "dashboard (headless-browser scrape), stale (session died, repair pending)."
)
TYPE_QUOTA_PCT = "# TYPE fleet_seat_quota_remaining_pct gauge"
HELP_QUOTA_RESET = (
    "# HELP fleet_seat_quota_reset_seconds Seconds until the quota window "
    "resets, per provider per window (fleet-ops#4217). 0 when the provider "
    "does not report a reset time."
)
TYPE_QUOTA_RESET = "# TYPE fleet_seat_quota_reset_seconds gauge"
HELP_QUOTA_OBSERVED = (
    "# HELP fleet_seat_quota_observed_seconds Seconds since the quota was last "
    "observed from the provider (fleet-ops#4217). absent() on this family is "
    "the stale-quota alert: a seat whose observed_at is older than "
    "QUOTA_STALE_S has no live figure."
)
TYPE_QUOTA_OBSERVED = "# TYPE fleet_seat_quota_observed_seconds gauge"
QUOTA_STALE_S = 900  # 15 min — the issue's stale threshold.
CLAUDE_CREDENTIALS_JSON = Path.home() / ".claude" / ".credentials.json"
CODEX_AUTH_JSON = Path.home() / ".codex" / "auth.json"
CLAUDE_OAUTH_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
# OpenUsage ClaudeAuthStore.prodRefreshURL / Claude Code 2.1.260 TOKEN_URL.
CLAUDE_OAUTH_REFRESH_URL = "https://platform.claude.com/v1/oauth/token"
# Claude Code prod CLIENT_ID (OpenUsage ClaudeAuthStore.prodClientID).
CLAUDE_OAUTH_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"  # gitleaks:allow - public OAuth client id, not a secret
# OpenUsage ClaudeUsageClient.scopes — the file login's user:profile set.
CLAUDE_OAUTH_REFRESH_SCOPE = (
    "user:profile user:inference user:sessions:claude_code "
    "user:mcp_servers user:file_upload"
)
# OpenUsage ClaudeAuthStore.needsRefresh: expiresAt - now <= 5 min.
CLAUDE_OAUTH_REFRESH_SKEW_MS = 5 * 60 * 1000
CODEX_WHAM_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
OPENROUTER_KEY_URL = "https://openrouter.ai/api/v1/key"
CURSOR_AUTH_JSON = Path.home() / ".config" / "cursor" / "auth.json"
CURSOR_PERIOD_USAGE_URL = (
    "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
)
DEVIN_CREDENTIALS_TOML = Path.home() / ".local" / "share" / "devin" / "credentials.toml"
DEVIN_GET_USER_STATUS_URL = (
    "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
)
CLAUDE_QUOTA_CACHE = PR_CACHE_DIR / "claude-quota-cache.json"
CODEX_QUOTA_CACHE = PR_CACHE_DIR / "codex-quota-cache.json"
OPENROUTER_KEY_CACHE = PR_CACHE_DIR / "openrouter-key-cache.json"
CURSOR_QUOTA_CACHE = PR_CACHE_DIR / "cursor-quota-cache.json"
DEVIN_QUOTA_CACHE = PR_CACHE_DIR / "devin-quota-cache.json"
XKIRO_QUOTA_CACHE = PR_CACHE_DIR / "xkiro-quota-cache.json"
QUOTA_TTL = 300  # 5 min — matches the exporter cadence; one fresh fetch per run.
QUOTA_STALE_CACHE = 1800  # 30 min — serve stale cache while a fetch is failing.


def _fetch_openrouter_key():
    """Return OpenRouter /api/v1/key quota rows, or None.

    The endpoint returns limit_remaining (USD left in the per-key cap window)
    and limit_reset (ISO timestamp). When limit is null the key has no per-key
    cap, so there is no quota meter to emit (the account-wide /credits balance
    is already exported as fleet_seat_credits_remaining_usd). Verified live
    2026-09-07: limit=null for this key, so this fetcher returns None today
    and emits nothing; a key with a cap emits both rows.
    """
    key = _openrouter_api_key()
    if not key:
        return None
    req = urllib.request.Request(
        OPENROUTER_KEY_URL,
        headers={"Authorization": f"Bearer {key}", "User-Agent": _VENDOR_USER_AGENT},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:  # nosemgrep
            payload = json.loads(resp.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        print(f"openrouter key fetch failed: {exc}", file=sys.stderr)
        return None
    data = payload.get("data") or {}
    if not isinstance(data, dict):
        return None
    limit = data.get("limit")
    remaining = data.get("limit_remaining")
    reset = data.get("limit_reset")
    if limit is None or remaining is None:
        return None
    try:
        limit = float(limit)
        remaining = float(remaining)
    except (ValueError, TypeError):
        return None
    if limit <= 0:
        return None
    pct = (remaining / limit) * 100.0 if limit else 0.0
    reset_s = _iso_to_seconds_until(reset)
    return {"pct": pct, "reset_s": reset_s, "window": "key_cap"}


def _read_claude_credentials():
    """Return (full_file_dict, oauth_dict) from the file login, or (None, None).

    The usage endpoint needs user:profile. CLAUDE_CODE_OAUTH_TOKEN (claude
    setup-token) is inference-only and 403s; never read it here
    (fleet-ops#4670; OpenUsage ClaudeAuthStore.inferenceOnly).
    """
    try:
        data = json.loads(CLAUDE_CREDENTIALS_JSON.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None, None
    if not isinstance(data, dict):
        return None, None
    oauth = data.get("claudeAiOauth") or {}
    if not isinstance(oauth, dict):
        return None, None
    return data, oauth


def _claude_access_token():
    """Return a live file-login access token, refreshing if near expiry.

    Never returns CLAUDE_CODE_OAUTH_TOKEN. A dead refresh keeps the current
    access token so a still-valid window can serve one more usage GET; a
    401 on that GET forces one more refresh via _fetch_claude_usage.
    """
    return _ensure_claude_file_token()


def _claude_needs_refresh(oauth, now_ms=None):
    """True when the file access token is inside OpenUsage's 5-min skew."""
    if not isinstance(oauth, dict):
        return False
    expires_at = oauth.get("expiresAt")
    if not isinstance(expires_at, (int, float)):
        return False
    if now_ms is None:
        now_ms = time.time() * 1000.0
    return expires_at - now_ms <= CLAUDE_OAUTH_REFRESH_SKEW_MS


def _claude_refresh_grant(refresh_token):
    """POST the OpenUsage refresh grant. Return parsed JSON or None.

    Body shape is OpenUsage ClaudeUsageClient.refreshToken: grant_type,
    refresh_token, client_id, scope (space-separated, includes user:profile).
    """
    if not refresh_token:
        return None
    payload = json.dumps({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": CLAUDE_OAUTH_CLIENT_ID,
        "scope": CLAUDE_OAUTH_REFRESH_SCOPE,
    }).encode("utf-8")
    req = urllib.request.Request(
        CLAUDE_OAUTH_REFRESH_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": _VENDOR_USER_AGENT,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:  # nosemgrep
            body = json.loads(resp.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        print(f"claude oauth refresh failed: {exc}", file=sys.stderr)
        return None
    if not isinstance(body, dict) or not body.get("access_token"):
        return None
    return body


def _persist_claude_oauth(expected_refresh, new_oauth):
    """Atomically write rotated oauth if the file refreshToken still matches.

    CAS is best-effort (OpenUsage ClaudeAuthStore.save ifUnchanged): a Mac or
    CLI writer that rotated first wins, so we do not clobber their new pair.
    Mode stays 0600. Sibling oauth fields (subscriptionType, rateLimitTier)
    are preserved; only access/refresh/expiry/scopes are updated.
    """
    try:
        current = json.loads(CLAUDE_CREDENTIALS_JSON.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    if not isinstance(current, dict):
        return False
    oauth = current.get("claudeAiOauth") or {}
    if not isinstance(oauth, dict):
        return False
    if oauth.get("refreshToken") != expected_refresh:
        print(
            "claude oauth persist skipped: file refreshToken changed under us",
            file=sys.stderr,
        )
        return False
    merged = dict(oauth)
    merged.update(new_oauth)
    current["claudeAiOauth"] = merged
    text = json.dumps(current, separators=(",", ":"))
    try:
        _atomic_write(CLAUDE_CREDENTIALS_JSON, text, mode=0o600)
    except OSError as exc:
        print(f"claude oauth persist failed: {exc}", file=sys.stderr)
        return False
    return True


def _ensure_claude_file_token(force=False):
    """Return the file access token, refreshing when near expiry or forced.

    force=True is the usage-401 recovery path: refresh even if expiresAt
    still looks healthy (clock skew / early revoke).
    """
    _data, oauth = _read_claude_credentials()
    if oauth is None:
        return None
    access = oauth.get("accessToken") or None
    refresh = oauth.get("refreshToken") or None
    # Fresh non-empty access skips the grant. A blanked accessToken with a
    # surviving refresh (the 2026-08-21 signature, minus a fully-blanked pair)
    # still heals. force=True is the usage-401 path.
    if not force and access and not _claude_needs_refresh(oauth):
        return access
    if not refresh:
        return access
    grant = _claude_refresh_grant(refresh)
    if not grant:
        return access
    try:
        expires_in = float(grant["expires_in"])
    except (KeyError, TypeError, ValueError):
        print("claude oauth refresh missing expires_in", file=sys.stderr)
        return access
    if expires_in <= 0:
        print("claude oauth refresh expires_in<=0", file=sys.stderr)
        return access
    now_ms = int(time.time() * 1000)
    new_oauth = {
        "accessToken": grant["access_token"],
        "refreshToken": grant.get("refresh_token") or refresh,
        "expiresAt": now_ms + int(expires_in * 1000),
    }
    rte = grant.get("refresh_token_expires_in")
    if rte is not None:
        try:
            new_oauth["refreshTokenExpiresAt"] = now_ms + int(float(rte) * 1000)
        except (TypeError, ValueError):
            pass
    scope = grant.get("scope")
    if isinstance(scope, str) and scope.strip():
        new_oauth["scopes"] = scope.split()
    elif isinstance(scope, list) and scope:
        new_oauth["scopes"] = [str(s) for s in scope]
    _persist_claude_oauth(refresh, new_oauth)
    return new_oauth["accessToken"]


def _codex_access_token():
    """Return the Codex OAuth access token from ~/.codex/auth.json, or None."""
    try:
        data = json.loads(CODEX_AUTH_JSON.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    tokens = (data or {}).get("tokens") or {}
    token = tokens.get("access_token")
    return token or None


def _claude_usage_request(token):
    """GET /api/oauth/usage. Return payload dict, or raise."""
    req = urllib.request.Request(
        CLAUDE_OAUTH_USAGE_URL,
        headers={"Authorization": f"Bearer {token}", "User-Agent": _VENDOR_USER_AGENT},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:  # nosemgrep
        return json.loads(resp.read().decode("utf-8"))


def _fetch_claude_usage():
    """Return Claude OAuth usage quota rows, or None.

    api.anthropic.com/api/oauth/usage returns five_hour and seven_day windows
    with utilization (0..100, percent USED) and resets_at (ISO). remaining_pct
    = 100 - utilization. Verified live 2026-09-07.

    fleet-ops#4670: a 401 means the file access token died. Force one refresh
    of the file login (not CLAUDE_CODE_OAUTH_TOKEN) and retry once. A 429 is
    not a credential fault; leave it to the stale-cache / fail-loud path.
    """
    token = _claude_access_token()
    if not token:
        return None
    try:
        payload = _claude_usage_request(token)
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            print("claude usage 401: forcing file-token refresh", file=sys.stderr)
            token = _ensure_claude_file_token(force=True)
            if not token:
                print(f"claude usage fetch failed: {exc}", file=sys.stderr)
                return None
            try:
                payload = _claude_usage_request(token)
            except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as retry_exc:
                print(f"claude usage fetch failed: {retry_exc}", file=sys.stderr)
                return None
        else:
            print(f"claude usage fetch failed: {exc}", file=sys.stderr)
            return None
    except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        print(f"claude usage fetch failed: {exc}", file=sys.stderr)
        return None
    if not isinstance(payload, dict):
        return None
    rows = []
    for key, window in (("five_hour", "session"), ("seven_day", "weekly")):
        entry = payload.get(key)
        if not isinstance(entry, dict):
            continue
        util = entry.get("utilization")
        resets_at = entry.get("resets_at")
        if util is None:
            continue
        try:
            util = float(util)
        except (ValueError, TypeError):
            continue
        pct = max(0.0, 100.0 - util)
        reset_s = _iso_to_seconds_until(resets_at)
        rows.append({"pct": pct, "reset_s": reset_s, "window": window})
    return rows or None


def _fetch_codex_usage():
    """Return Codex OAuth wham/usage quota rows, or None.

    chatgpt.com/backend-api/wham/usage returns rate_limit.primary_window with
    used_percent (0..100) and reset_after_seconds. remaining_pct =
    100 - used_percent. Verified live 2026-09-07.
    """
    token = _codex_access_token()
    if not token:
        return None
    req = urllib.request.Request(
        CODEX_WHAM_USAGE_URL,
        headers={"Authorization": f"Bearer {token}", "User-Agent": _VENDOR_USER_AGENT},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:  # nosemgrep
            payload = json.loads(resp.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        print(f"codex usage fetch failed: {exc}", file=sys.stderr)
        return None
    if not isinstance(payload, dict):
        return None
    rl = payload.get("rate_limit")
    if not isinstance(rl, dict):
        return None
    pw = rl.get("primary_window")
    if not isinstance(pw, dict):
        return None
    used = pw.get("used_percent")
    reset_after = pw.get("reset_after_seconds")
    if used is None:
        return None
    try:
        used = float(used)
    except (ValueError, TypeError):
        return None
    pct = max(0.0, 100.0 - used)
    reset_s = None
    if reset_after is not None:
        try:
            reset_s = float(reset_after)
        except (ValueError, TypeError):
            reset_s = None
    return [{"pct": pct, "reset_s": reset_s, "window": "primary"}]


def _cursor_access_token():
    """Return the Cursor access token from ~/.config/cursor/auth.json, or None."""
    try:
        data = json.loads(CURSOR_AUTH_JSON.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    token = (data or {}).get("accessToken")
    return token or None


def _fetch_cursor_usage():
    """Return Cursor GetCurrentPeriodUsage quota rows, or None.

    api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage answers a
    POST with the Bearer accessToken from ~/.config/cursor/auth.json (the same
    token the Cursor CLI uses; verified live 2026-09-07). The payload carries
    planUsage.totalPercentUsed (percent USED across the billing cycle) and
    billingCycleEnd (epoch-milliseconds). remaining_pct = 100 - totalPercentUsed;
    reset_s = seconds until billingCycleEnd. The endpoint is the one OpenUsage's
    Cursor provider calls (Sources/OpenUsage/Providers/Cursor/CursorUsageClient.swift).
    """
    token = _cursor_access_token()
    if not token:
        return None
    req = urllib.request.Request(
        CURSOR_PERIOD_USAGE_URL,
        data=b"{}",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "User-Agent": _VENDOR_USER_AGENT,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:  # nosemgrep
            payload = json.loads(resp.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        print(f"cursor usage fetch failed: {exc}", file=sys.stderr)
        return None
    if not isinstance(payload, dict):
        return None
    plan_usage = payload.get("planUsage")
    if not isinstance(plan_usage, dict):
        return None
    used = plan_usage.get("totalPercentUsed")
    if used is None:
        return None
    try:
        used = float(used)
    except (ValueError, TypeError):
        return None
    pct = max(0.0, min(100.0, 100.0 - used))
    reset_s = None
    cycle_end = payload.get("billingCycleEnd")
    if cycle_end is not None:
        try:
            reset_s = max(0.0, float(cycle_end) / 1000.0 - time.time())
        except (ValueError, TypeError):
            reset_s = None
    return [{"pct": pct, "reset_s": reset_s, "window": "monthly"}]


def _devin_windsurf_api_key():
    """Return the Devin/Codeium windsurf_api_key from credentials.toml, or None.

    OpenUsage's Devin provider reads the same file (DevinAuthStore.swift:
    ~/.local/share/devin/credentials.toml, key windsurf_api_key). The key is
    the Codeium/Windsurf auth token, not the api.devin.ai API key.
    """
    try:
        with open(DEVIN_CREDENTIALS_TOML, "rb") as fh:
            cfg = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError):
        return None
    key = cfg.get("windsurf_api_key")
    return key if isinstance(key, str) and key else None


def _fetch_devin_usage():
    """Return Devin GetUserStatus quota rows, or None.

    server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus
    answers a POST carrying the windsurf_api_key from
    ~/.local/share/devin/credentials.toml (the same auth OpenUsage's Devin
    provider uses; verified live 2026-09-07). The payload's planStatus carries
    dailyQuotaRemainingPercent / weeklyQuotaRemainingPercent (percent REMAINING)
    and dailyQuotaResetAtUnix / weeklyQuotaResetAtUnix (epoch seconds).
    remaining_pct is used as-is; reset_s = seconds until the reset.
    """
    key = _devin_windsurf_api_key()
    if not key:
        return None
    body = {
        "metadata": {
            "apiKey": key,
            "ideName": "devin",
            "ideVersion": "1.108.2",
            "extensionName": "devin",
            "extensionVersion": "1.108.2",
            "locale": "en",
        }
    }
    req = urllib.request.Request(
        DEVIN_GET_USER_STATUS_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Connect-Protocol-Version": "1",
            "User-Agent": _VENDOR_USER_AGENT,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:  # nosemgrep
            payload = json.loads(resp.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        print(f"devin usage fetch failed: {exc}", file=sys.stderr)
        return None
    if not isinstance(payload, dict):
        return None
    user_status = payload.get("userStatus")
    if not isinstance(user_status, dict):
        return None
    plan_status = user_status.get("planStatus")
    if not isinstance(plan_status, dict):
        return None
    rows = []
    now = time.time()
    # Daily quota (percent remaining).
    daily = plan_status.get("dailyQuotaRemainingPercent")
    if daily is not None:
        try:
            daily = float(daily)
        except (ValueError, TypeError):
            daily = None
        if daily is not None:
            daily_reset = plan_status.get("dailyQuotaResetAtUnix")
            daily_reset_s = None
            if daily_reset is not None:
                try:
                    daily_reset_s = max(0.0, float(daily_reset) - now)
                except (ValueError, TypeError):
                    daily_reset_s = None
            rows.append(
                {"pct": max(0.0, min(100.0, daily)), "reset_s": daily_reset_s, "window": "daily"}
            )
    # Weekly quota (percent remaining).
    weekly = plan_status.get("weeklyQuotaRemainingPercent")
    if weekly is not None:
        try:
            weekly = float(weekly)
        except (ValueError, TypeError):
            weekly = None
        if weekly is not None:
            weekly_reset = plan_status.get("weeklyQuotaResetAtUnix")
            weekly_reset_s = None
            if weekly_reset is not None:
                try:
                    weekly_reset_s = max(0.0, float(weekly_reset) - now)
                except (ValueError, TypeError):
                    weekly_reset_s = None
            rows.append(
                {"pct": max(0.0, min(100.0, weekly)), "reset_s": weekly_reset_s, "window": "weekly"}
            )
    return rows or None


def _fetch_xkiro_quota():
    """Return xKiro free-tokens quota rows, or None.

    api.xkiro.com/v1/usage (the same endpoint _fetch_xkiro_usage calls for
    the vendor-balance family) returns free_tokens.remaining / limit_per_day
    and wallet.balance_usd. remaining_pct = remaining / limit * 100; the
    daily window resets at 00:00 UTC. Verified live 2026-09-08.
    """
    key = _read_env_key(XKIRO_ENV_FILE, ("XKIRO_API_KEY", "API_KEY"))
    if not key:
        return None
    req = urllib.request.Request(
        "https://api.xkiro.com/v1/usage",
        headers={"Authorization": f"Bearer {key}", "User-Agent": _VENDOR_USER_AGENT},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:  # nosemgrep
            payload = json.loads(resp.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        print(f"xkiro quota fetch failed: {exc}", file=sys.stderr)
        return None
    free = payload.get("free_tokens") or {}
    remaining = free.get("remaining")
    limit = free.get("limit_per_day")
    if remaining is None or limit is None:
        return None
    try:
        remaining = int(remaining)
        limit = int(limit)
    except (ValueError, TypeError):
        return None
    if limit <= 0:
        return None
    pct = max(0.0, min(100.0, (remaining / limit) * 100.0))
    # xKiro free-tokens reset at 00:00 UTC daily.
    now = datetime.now(timezone.utc)
    tomorrow = now.replace(
        hour=0, minute=0, second=0, microsecond=0
    ) + timedelta(days=1)
    reset_s = max(0.0, (tomorrow - now).total_seconds())
    return [{"pct": pct, "reset_s": reset_s, "window": "daily"}]


def _iso_to_seconds_until(iso_str):
    """Return seconds from now until an ISO timestamp, or None."""
    if not iso_str or not isinstance(iso_str, str):
        return None
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
    except ValueError:
        return None
    now = datetime.now(timezone.utc)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return max(0.0, (dt - now).total_seconds())


def _cached_quota_json(path, fetcher, name):
    """Return (data, observed_at) for a provider quota, or (None, None) to omit.

    observed_at is the epoch seconds the data was actually observed: now when
    freshly fetched, or the cache's own ts when served from a stale cache. It
    feeds fleet_seat_quota_observed_seconds so that metric reports the real
    age of the quota figure (fleet-ops#4217: "Stale (>15 min) => absent" — a
    stale observation must be visible, not masked as fresh).

    Fresh cache (<=5 min) skips network. On failure, serve cache up to 30 min
    (with its true ts), so a dying fetch surfaces as growing observed_seconds
    and trips the stale-quota alert instead of silently emitting a frozen,
    fresh-looking 0. One fetch per provider per exporter run.
    """
    cached, cache_age = _read_cache(path)
    if cache_age is not None and cache_age <= QUOTA_TTL and cached is not None:
        return cached, _cache_ts(path)
    data = fetcher()
    if data is not None:
        _write_cache(path, data)
        return data, time.time()
    if cached is not None and cache_age is not None and cache_age <= QUOTA_STALE_CACHE:
        print(f"{name} quota fetch failed, serving stale cache (age={int(cache_age)}s)",
              file=sys.stderr)
        return cached, _cache_ts(path)
    return None, None


def _claude_observed_anchor():
    """Return an epoch the fail-loud claude observed_seconds grows from.

    fleet-ops#4611: _cached_quota_json returns (None, None) once a dead claude
    fetch (401/429) outlives the 30-min stale-cache window, and the provider
    used to be dropped silently. This returns the epoch the dark meter counts
    from: the last good cache ts if a cache ever existed (the meter was live
    until that point), else a persisted first-miss sidecar so the age grows
    from the first outage tick instead of a never-seen claude being dropped.
    """
    ts = _cache_ts(CLAUDE_QUOTA_CACHE)
    if ts is not None:
        return ts
    sidecar = Path(str(CLAUDE_QUOTA_CACHE) + ".miss")
    try:
        c = json.loads(sidecar.read_text())
        t = c.get("ts")
        if isinstance(t, (int, float)):
            return t
    except (OSError, json.JSONDecodeError):
        pass
    try:
        PR_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        sidecar.write_text(json.dumps({"ts": time.time()}))
    except OSError:
        pass
    return time.time()


def _emit_seat_quota(lines, provider, rows, source, observed_at):
    """Append fleet_seat_quota_* rows for one provider.

    rows: list of {pct, reset_s, window}. observed_at: epoch seconds of the
    fetch. source: api | dashboard | stale.

    Emits the data rows only (no HELP/TYPE); the caller emits the HELP/TYPE
    headers once via _emit_seat_quota_headers so multiple providers do not
    duplicate them (fleet-ops#1844: a duplicate HELP/TYPE makes the textfile
    unparseable and node_exporter drops the whole fleet.prom).
    """
    if not rows:
        return
    now = time.time()
    observed_s = max(0.0, now - observed_at) if observed_at else 0.0
    for r in rows:
        window = _prom_label(r.get("window") or "primary")
        pct = r["pct"]
        reset_s = r.get("reset_s")
        reset_val = float(reset_s) if reset_s is not None else 0.0
        lines.append(
            f'fleet_seat_quota_remaining_pct{{provider="{_prom_label(provider)}",'
            f'window="{window}",source="{_prom_label(source)}"}} {pct:.4f}'
        )
        lines.append(
            f'fleet_seat_quota_reset_seconds{{provider="{_prom_label(provider)}",'
            f'window="{window}",source="{_prom_label(source)}"}} {reset_val:.4f}'
        )
    lines.append(
        f'fleet_seat_quota_observed_seconds{{provider="{_prom_label(provider)}",'
        f'source="{_prom_label(source)}"}} {observed_s:.4f}'
    )


def _emit_seat_quota_fail_loud(lines, provider, observed_at):
    """Emit only the observed_seconds gauge for a failing quota provider.

    fleet-ops#4611: a dead fetch (401/429) past the stale-cache window used to
    drop the provider entirely from _quota_providers, so its whole gauge family
    went silently absent and — as long as other providers kept emitting — the
    absent() leg of the stale-quota rule never fired. Emitting the growing
    observed_seconds gauge with source="stale" keeps the meter loud: the value
    crosses QUOTA_STALE_S and the FleetClaudeQuotaStale / FleetSeatQuotaStale
    rule fires instead of a dark money meter being invisible.
    """
    now = time.time()
    observed_s = max(0.0, now - observed_at) if observed_at else QUOTA_STALE_S + 1
    lines.append(
        f'fleet_seat_quota_observed_seconds{{provider="{_prom_label(provider)}",'
        f'source="stale"}} {observed_s:.4f}'
    )


def _emit_seat_quota_headers(lines):
    """Emit one HELP/TYPE pair per quota metric name (call once before rows)."""
    lines.append("")
    lines.append(HELP_QUOTA_PCT)
    lines.append(TYPE_QUOTA_PCT)
    lines.append(HELP_QUOTA_RESET)
    lines.append(TYPE_QUOTA_RESET)
    lines.append(HELP_QUOTA_OBSERVED)
    lines.append(TYPE_QUOTA_OBSERVED)


_GH_FETCHED_THIS_RUN = False

# Measurement time (epoch seconds) of the data _cached_json actually served,
# per family. See HELP_CTS: a cached family's number was measured when the
# CACHE was written, not when this exporter run copied it out.
_CACHE_TS_SERVED = {}


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
        _CACHE_TS_SERVED[name] = time.time() - cache_age
        return cached
    if _GH_FETCHED_THIS_RUN:
        if cached is not None and cache_age is not None and cache_age <= PR_CACHE_STALE:
            _CACHE_TS_SERVED[name] = time.time() - cache_age
            return cached
        return None
    data = fetcher()
    _GH_FETCHED_THIS_RUN = True
    if data is not None:
        _write_cache(path, data)
        _CACHE_TS_SERVED[name] = time.time()
        return data
    if cached is not None and cache_age is not None and cache_age <= PR_CACHE_STALE:
        print(f"{name} gh failed, serving stale cache (age={int(cache_age)}s)",
              file=sys.stderr)
        _CACHE_TS_SERVED[name] = time.time() - cache_age
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
    detail = _cached_json(DETAIL_CACHE, _gh_merged_prs_raw, "merged_prs")
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
        detail = _cached_json(DETAIL_CACHE, _gh_merged_prs_raw, "merged_prs")
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
    Skipped/neutral/cancelled runs are not verdicts (a cancelled run is a
    superseded/abandoned run, not a red trunk) so they are skipped; if no run
    with a real conclusion completed, return None (omit).
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
        if concl in ("failure", "timed_out",
                     "action_required", "startup_failure"):
            return 0
        # skipped / neutral / cancelled → not a verdict (a cancelled run is a
        # superseded/abandoned run, not a red trunk), keep looking
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
        # fleet-ops#180 (PR #4437): the gap-closure drill stubs.
        # fleet-gap-closure-drill's drill_unit_escalation / drill_timer_mask
        # spin a throwaway ExecStart=/bin/false unit to prove the escalation
        # and timer OnFailure= chain fires; the stub failing IS the drill
        # working. unit-escalation-write refuses the trip, so counting the
        # unit-escalation@<stub> template START here would still storm
        # FleetEscalationStorm and summon a fresh auditor per drill cycle
        # (same class as the #3617 fleet-orphan-reset-probe@* fix). Globs are
        # suffix-open so they match both the stripped and full unit name.
        "gap-closure-drill-stub*",
        "gap-closure-drill-mask-probe*",
        # fleet-ops#3180: resync with the writer's refuse list. The
        # 2026-08-30 pi-issue@* exclusion (fleet-ops#2133/#2475 — workers
        # escalate via their own reaper + re-dispatch lane, never to the
        # senior auditor) and the drill/probe scaffolding never landed here,
        # so the unit-escalation@<instance> template START was still counted
        # even though the writer refused the trip. Measured 2026-09-05:
        # 868 of 936 counted starts were pi-issue@* no-seat crash-loops,
        # tripping FleetEscalationStorm (threshold 300; remaining 64).
        # tests/fleet-metrics-export.test.sh locks this list against the
        # writer's case line so a future exclusion cannot drift again.
        "notify-probe.service",
        "notify-probe.onfail.service",
        "probe-*.service",
        # fleet-ops#3617: the fleet-orphan-reset-probe@* test stub (fleet-ops#3617)
        # proves reset-failed semantics via ExecStart=/bin/false; its
        # deliberate failure is refused by unit-escalation-write (excluded in
        # the writer's case list) so its template STOPS there — but the
        # unit-escalation@<instance> template START was still being counted
        # here, tripping the escalation-exclusion drift-lock. Mirror the
        # writer's refuse entry so the metric and writer cannot drift.
        "fleet-orphan-reset-probe@*",
        "multi-*-sink.service",
        "pi-issue@*",
        # fleet-ops#4266 detached dead-man: the writer refuses the scope.d
        # anti-recursion scopes (init.scope, app-*.scope) and the live-dummy*
        # dead-man PROOF units (a deliberate stop-without-deliverable is the
        # verdict being proven, not a fault). Mirror the writer's refuse
        # entries so the metric and writer cannot drift.
        "init.scope",
        "app-*.scope",
        "live-dummy*",
        # Canaries / orchestrator organs: their deliberate fail-loud escalations
        # are expected, not a flapping worker.
        "fleet-heartbeat*",
        "pi-intake@fleet-ops-canary*",
        # OnFailure repair units are recovery machinery; counting them in the
        # storm metric double-counts the original failure. fleet-ops#3349:
        # alert-repair-* units use a hyphen separator, so they escaped the
        # *-repair@* glob and stayed counted (the "alert-repair run hop stalled"
        # component of the FleetEscalationStorm); exclude them too.
        "*-repair@*",
        "alert-repair-*",
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


def _oomd_kills_6h():
    """Count systemd-oomd kills of app-pi-issue.slice units in the last 6h.

    fleet-ops#4164: a rise > 3 in 6h trips FleetOomdKillsHigh, whose repair
    packet raises the live ram_gb_per_worker charge back to 2.0. Counts only
    oomd-managed kills (systemd-oomd logs "Killed unit ..." or
    "Killed process ..."), not kernel OOM. Scoped to the app-pi-issue.slice
    cgroup so host-level oomd kills (unrelated services) do not trip the
    fleet alert. Returns a dict {unit: count} (top 20).

    Overridable for tests via FLEET_OOMD_JOURNAL_STUB (a file whose lines
    stand in for journalctl --output=cat output).
    """
    stub = os.environ.get("FLEET_OOMD_JOURNAL_STUB")
    if stub:
        try:
            with open(stub) as f:
                stdout = f.read()
        except OSError:
            return {}
        rc = 0
    else:
        try:
            r = subprocess.run(
                [
                    "journalctl", "--user",
                    "--since", "6 hours ago",
                    "--no-pager",
                    "--output=cat",
                    "SYSTEMD_OOMD_KILL=1",
                ],
                capture_output=True, text=True, timeout=JOURNAL_TIMEOUT,
                env={**os.environ, "XDG_RUNTIME_DIR": XDG},
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            print(f"oomd-kills journalctl failed: {exc}", file=sys.stderr)
            return {}
        rc = r.returncode
        stdout = r.stdout
    if rc != 0 and not stub:
        print(f"oomd-kills journalctl rc={rc}", file=sys.stderr)
        return {}
    counts = Counter()
    for line in stdout.splitlines():
        # systemd-oomd log lines (cat output): "Killed unit <name>.service."
        # or "Killed unit <name>.slice." or
        # "Killed process <pid> (<comm>) in unit <name>.service."
        m = re.search(r"in unit (\S+?)\.service", line)
        if not m:
            m = re.search(r"Killed unit (\S+?)\.(service|slice)", line)
        if not m:
            continue
        unit = m.group(1)
        # Scope to fleet worker units (pi-issue@* under app-pi-issue.slice)
        # and the slice itself. A host-level oomd kill of an unrelated
        # service is not a fleet signal.
        if not (unit.startswith("pi-issue@") or unit == "app-pi-issue"):
            continue
        counts[unit] += 1
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


def _read_worktree_reaper():
    """Read the worktree reaper's last-run summary (fleet-ops#4118).

    bin/fleet-worktree-reaper writes a JSON breakdown to
    WORKTREE_REAPER_SUMMARY on every daily timer run. This surfaces the count
    the heartbeat can gauge: post_count (dirs left under agent-worktrees after
    the reap), reaped (how many the reaper removed), and the run timestamp for
    freshness. Degrades to present=False when the summary is missing,
    unparseable, or stale (older than WORKTREE_REAPER_STALE_S) so the heartbeat
    can tell a dead reaper from a healthy one — a missing reaper result is
    data, not a crash.

    Returns a dict with present + the count fields, or present=False with a
    reason.
    """
    try:
        doc = json.loads(
            WORKTREE_REAPER_SUMMARY.read_text(encoding="utf-8", errors="replace")
        )
    except OSError:
        return {"present": False, "reason": "summary-missing"}
    except json.JSONDecodeError:
        return {"present": False, "reason": "summary-unparseable"}
    ts = doc.get("ts")
    age_s = None
    if isinstance(ts, str):
        ts_epoch = _parse_iso_utc(ts)
        if ts_epoch is not None:
            age_s = time.time() - ts_epoch
    if age_s is not None and age_s > WORKTREE_REAPER_STALE_S:
        return {
            "present": False,
            "reason": "summary-stale",
            "ts": ts,
            "age_s": age_s,
        }
    return {
        "present": True,
        "ts": ts,
        "age_s": age_s,
        "post_count": doc.get("post_count"),
        "pre_count": doc.get("pre_count"),
        "reaped": doc.get("reaped"),
        "scanned": doc.get("scanned"),
        "bound_breached": doc.get("bound_breached"),
        "skipped_dirty": doc.get("skipped_dirty"),
        "skipped_notpushed": doc.get("skipped_notpushed"),
        "skipped_live": doc.get("skipped_live"),
        "skipped_young": doc.get("skipped_young"),
        "skipped_unmerged": doc.get("skipped_unmerged"),
        "skipped_notterminal": doc.get("skipped_notterminal"),
        "salvaged": doc.get("salvaged"),
        "failed": doc.get("failed"),
    }


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


def _seat_key_in_caps(provider, model):
    """True when provider/model is an allowlisted key in seat-caps.json.

    Mirrors lib/seat-lib.sh `_seat_key_in_caps` (the SEAT-KEY-INVALID guard,
    fleet-ops#3661): a model key present under `.providers.<p>.models` counts
    as a real seat even when its cap is 0 (a bench / production-lock row); a
    key absent from that models map is a PHANTOM (probe-output filename
    fragment, a retired slug still holding a ledger, provider/model pairs the
    router never allows). The comeback-release organ refuses to probe or
    release phantoms, so they can never be unwalled by it — the metrics must
    not count them as overdue or never-released, or the seat-comeback alerts
    fire indefinitely until a worker manually retires the phantom.

    Returns True (fail-open) when the config is missing/unparseable so a
    broken seat-caps can never silently suppress a real alert — same shape as
    the other seat-caps reads in this module.

    fleet-ops#3811: the LIVE caps file (SEAT_CAPS_LIVE — the same source
    lib/seat-lib.sh uses) is checked FIRST so this guard's verdict matches
    what the comeback-release organ actually does. The repo checkouts are
    kept as fallbacks for hosts where the live file is absent (CI, dev).
    """
    for path in (SEAT_CAPS_LIVE, SEAT_CAPS_DEFAULT, SEAT_CAPS_FALLBACK):
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        providers = data.get("providers")
        if not isinstance(providers, dict):
            continue
        if provider not in providers:
            return False
        pcfg = providers.get(provider)
        if not isinstance(pcfg, dict):
            return False
        models = pcfg.get("models")
        if not isinstance(models, dict):
            return False
        return model in models
    return True


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
            if ".empty-success" in f.name:
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
            # fleet-ops#3661 (consistency with seat-lib's SEAT-KEY-INVALID
            # guard): a ledger whose provider/model is not a valid
            # seat-caps.json models key is a PHANTOM. Comeback-release
            # refuses to probe or release phantoms, so they can never be
            # unwalled here — counting them as overdue just fires this alert
            # until a worker manually retires the phantom. A phantom is
            # cleanup-owned, never a live-seat comeback signal; skip it.
            if not _seat_key_in_caps(data.get("provider", ""), data.get("model", "")):
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
            if ".empty-success" in f.name:
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
            if ".empty-success" in f.name:
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
            # fleet-ops#3564: reason dates are bare calendar dates on a UTC
            # ledger. time.mktime applies the process local timezone, so on a
            # +05:30 host this read every dated reason ~19800s more stale than
            # a UTC host (the same local-time-offset bug class #3520/#3562
            # fixed for observed_at). timegm keeps the age host-TZ independent.
            ds = int(calendar.timegm(time.strptime(
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
            if ".empty-success" in f.name:
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
            # fleet-ops#3661 (consistency with seat-lib's SEAT-KEY-INVALID
            # guard): a ledger whose provider/model is not a valid
            # seat-caps.json models key is a PHANTOM and is never probed or
            # released by comeback-release, so its consecutive-failure window
            # can never resolve here — counting it fires
            # FleetSeatComebackNeverReleased until a worker manually retires
            # the phantom. A phantom is cleanup-owned, never a live-seat
            # comeback signal; skip it.
            if not _seat_key_in_caps(data.get("provider", ""), data.get("model", "")):
                continue
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
    return _spawn_bench_marker_held(spawn_bench)


def _seat_spawn_bench_path(provider, model):
    """Spawn-bench marker path for a provider/model seat key.

    Mirrors lib/seat-lib.sh seat_spawn_bench_path: each of provider and
    model is sanitised ([^A-Za-z0-9._-] -> _) and joined as
    `<p>__<m>.spawn-bench.json` under SEAT_LEDGER.
    """
    safe_p = re.sub(r"[^A-Za-z0-9._-]", "_", provider)
    safe_m = re.sub(r"[^A-Za-z0-9._-]", "_", model)
    return SEAT_LEDGER / f"{safe_p}__{safe_m}.spawn-bench.json"


def _spawn_bench_held_for(provider, model) -> bool:
    """True if the named seat's wrapper spawn-bench marker is held now.

    fleet-ops#3563: the single-record sidecar (pi-seat-health.json) names a
    provider/model directly rather than a ledger path, so the overlay needs
    a seat-key lookup instead of _spawn_bench_active's ledger-path lookup.
    """
    if not isinstance(provider, str) or not provider:
        return False
    if not isinstance(model, str) or not model:
        return False
    return _spawn_bench_marker_held(_seat_spawn_bench_path(provider, model))


# fleet-ops#3737: freshness window for an expired spawn-bench marker that
# still gates the seat. Matches EMPTY_RUN_COUNT_WINDOW_S / SEAT_PARK_WALL_S
# in lib/seat-lib.sh and SPAWN_BENCH_FRESH_S in bin/fleet-seat-comeback-
# release (24 h). Older than this the marker is archaeology and fail-open.
SPAWN_BENCH_FRESH_S = 86400
# Failure ceilings mirror lib/seat-lib.sh seat_usable(): a spawn_fail (or
# any non-empty_run) seat parks past 20 consecutive failures; an empty run
# parks past 5. Used by the fleet-ops#3826 ceiling fence below.
SEAT_FAILURE_CEILING = 20
EMPTY_RUN_FAILURE_CEILING = 5


def _spawn_bench_marker_held(spawn_bench: Path) -> bool:
    """True if the spawn-bench marker currently gates this seat's
    re-admission. Never raises; missing/unreadable data is False
    (fail-open).

    fleet-ops#3737: seat_usable holds the bench in TWO cases —
      (a) usable_at strictly in the future (the active bench), or
      (b) usable_at expired/absent BUT the marker is FRESH (written within
          SPAWN_BENCH_FRESH_S) and still the seat's latest evidence: no
          sibling-ledger observed_at newer than written_at. A later ledger
          observation is post-bench evidence — a run that produced output
          writes healthy with no following marker — so case (b) releases
          on it; otherwise the comeback organ probes the seat before
          re-admission and the census must agree the seat is not healthy
          while it is probe-gated. Without case (b) a clobbered-healthy
          ledger reports an unprobed dead-weight seat as available
          (the ollama/<retired-V4-flash> empty-run churn this issue
          names).

    Beyond the two clock cases (and the reason this function is the
    ledger-demotion fix for fleet-ops#3828), seat_usable holds the bench in
    TWO more cases that this function previously missed:

    fleet-ops#3889 — corpse fence: a marker that declares seat_dead=true
    (the wrapper's verdict for a CHRONIC spawn_fail streak past the corpse
    threshold, consecutive_failure_count >= SEAT_DEAD_CONSECUTIVE_THRESHOLD)
    holds the seat TERMINALLY, regardless of usable_at and regardless of a
    later false-healthy ledger write. The seat-health extension logs a
    transport http 200 as healthy during the very run that then fails to
    spawn, because after_provider_response carries status+headers only —
    never the body or the process rc — so an rc=1 spawn failure is
    indistinguishable from a healthy response. Only a real recovery probe
    (source="comeback_release" on the ledger) re-proves the seat. Without
    this, the census/availability read the clobbered health_class=healthy
    ledger, counted the seat available, and "re-offered" a seat the router
    held — the live xkiro/<retired-V4-flash> at 47 consecutive spawn_fail
    with ledger_health_class=healthy.

    fleet-ops#3826 — ceiling fence: even a FRESH marker whose usable_at has
    passed and whose sibling ledger carries a NEWER healthy observation must
    stay held when the marker's consecutive_failure_count is at or past the
    failure ceiling (SEAT_FAILURE_CEILING for spawn_fail, and
    EMPTY_RUN_FAILURE_CEILING for empty_run). The newer observation is the
    same after_provider_response 200 the corpse fence names — status+headers
    only, no body/rc — so it is the false-healthy clobber again, NOT recovery
    evidence. Only a comeback-release probe re-proves the seat.
    """
    if not spawn_bench.is_file():
        return False
    try:
        marker = json.loads(spawn_bench.read_text())
    except (OSError, json.JSONDecodeError):
        return False
    if not isinstance(marker, dict):
        return False
    now = int(time.time())
    # Parse ISO timestamps as UTC (the seat ledger is always UTC-Z).
    # time.mktime is local-timezone-dependent and would give a wrong epoch
    # on a non-UTC host (the live VPS runs IST, +5:30; a future-Z timestamp
    # would parse to a past-local epoch). _parse_iso_utc uses
    # calendar.timegm so the parsed tuple is treated as UTC.
    usable_at = marker.get("usable_at")
    usable_epoch = (
        _parse_iso_utc(usable_at) if isinstance(usable_at, str) else None
    )
    if usable_epoch is not None and usable_epoch > now:
        return True
    # Sibling per-seat ledger: both the false-healthy clobber target and the
    # recovery authority (a comeback-release probe writes source on it).
    ledger = spawn_bench.with_name(
        spawn_bench.name[: -len(".spawn-bench.json")] + ".json"
    )
    try:
        led = json.loads(ledger.read_text())
    except (OSError, json.JSONDecodeError):
        led = {}
    if not isinstance(led, dict):
        led = {}
    ledger_src = led.get("source") or ""
    # fleet-ops#3889 corpse fence: terminal until a real recovery probe
    # (source=comeback_release) re-writes the ledger. Mirrors seat_usable —
    # no usable_at or marker-age bound, the corpse hold is durable.
    if marker.get("seat_dead") is True:
        if ledger_src != "comeback_release":
            return True
        # Recovered corpse: fall through — the fresh ledger observation now
        # decides (seat_usable drops the corpse hold the same way).
    # Case (b): expired or clockless bench — held only while the marker is
    # fresh and remains the seat's latest evidence.
    written_at = marker.get("written_at")
    written_epoch = (
        _parse_iso_utc(written_at) if isinstance(written_at, str) else None
    )
    if written_epoch is None or now - written_epoch > SPAWN_BENCH_FRESH_S:
        return False
    obs = led.get("observed_at")
    obs_epoch = _parse_iso_utc(obs) if isinstance(obs, str) else None
    if obs_epoch is None or obs_epoch <= written_epoch:
        return True
    # fleet-ops#3826 ceiling fence: a NEWER healthy observation is the
    # false-healthy clobber, not recovery, for a ceiling-parked seat.
    mcount = marker.get("consecutive_failure_count") or 0
    if not isinstance(mcount, int) or isinstance(mcount, bool):
        try:
            mcount = int(mcount)
        except (TypeError, ValueError):
            mcount = 0
    mmode = marker.get("failure_mode") or ""
    _ceil = (
        EMPTY_RUN_FAILURE_CEILING if mmode == "empty_run"
        else SEAT_FAILURE_CEILING
    )
    if mcount >= _ceil and ledger_src != "comeback_release":
        return True
    return False


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
            if ".empty-success" in f.name:
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


def _provider_class_map():
    """Return {provider: class} from seat-caps.json, or None when unavailable.

    Mirrors lib/seat-lib.sh load_seat_caps: a provider value may be a bare
    number (shorthand cap=N, class defaults to "free") or an object with
    .class (subscription is the pre-#387 name for prepaid-quota). Returns
    None when the config is missing/unparseable so callers fail safe.
    """
    for path in (SEAT_CAPS_DEFAULT, SEAT_CAPS_FALLBACK):
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        providers = data.get("providers") or {}
        if not isinstance(providers, dict):
            continue
        out = {}
        for prov, cfg in providers.items():
            if isinstance(cfg, bool):
                continue
            if isinstance(cfg, (int, float)):
                out[prov] = "free"
                continue
            if isinstance(cfg, dict):
                cls = cfg.get("class") or "free"
                if cls == "subscription":
                    cls = "prepaid-quota"
                out[prov] = cls
        return out
    return None


def _healthy_enrolled_seat_count_by_class():
    """Count healthy enrolled providers grouped by seat class.

    fleet-ops#4627: the money-boundary starvation gate needs to know whether
    ANY healthy prepaid/free seat exists. Returns a dict {class: count} over
    the same healthy-enrolled rollup as _healthy_enrolled_seat_count (a
    provider counts healthy when any of its model ledgers reports
    health_class=healthy and seat_dead != true, or its wall clock has
    released it; a held spawn-bench outranks a later healthy observation).
    Only prepaid / free classes are populated; metered is omitted
    (the issue is about dry metered providers with healthy prepaid/free
    capacity). prepaid-quota is emitted as the label "prepaid" to match
    the issue's class=~"prepaid|free" regex. Returns {} when the config or
    ledger is unavailable.
    """
    enrolled = _enrolled_seat_providers()
    if not enrolled:
        return {}
    if not SEAT_LEDGER.is_dir():
        return {}
    classes = _provider_class_map() or {}
    healthy = set()
    try:
        for f in SEAT_LEDGER.iterdir():
            if not f.is_file() or "__" not in f.name or not f.name.endswith(".json"):
                continue
            if ".empty-success" in f.name:
                continue
            try:
                data = json.loads(f.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(data, dict):
                continue
            if data.get("seat_dead") is True:
                continue
            if _spawn_bench_active(f):
                continue
            if data.get("health_class") != "healthy" and not _seat_is_released(data):
                continue
            prov = data.get("provider")
            if isinstance(prov, str) and prov in enrolled:
                healthy.add(prov)
    except OSError:
        return {}
    # Map the canonical seat-caps class to the metric label. The issue's
    # success metric keys on class=~"prepaid|free" (PromQL =~ is fully
    # anchored), so prepaid-quota -> "prepaid" to match the regex.
    counts = {"prepaid": 0, "free": 0}
    for prov in healthy:
        cls = classes.get(prov, "free")
        if cls == "prepaid-quota":
            cls = "prepaid"
        if cls in counts:
            counts[cls] += 1
    return counts


def _money_boundary_pages_log():
    """Path to the money-boundary pages log (writer's page counter)."""
    return Path(os.environ.get(
        "MONEY_BOUNDARY_PAGES_LOG",
        "/home/nish/workspaces/agent-state/lanes/money-boundary-pages.log",
    ))


def _read_money_boundary_pages():
    """Count money-boundary page log lines by reason over the trailing 7d.

    fleet-ops#4627: the success metric is
    `nish_boundary_money_pages_total{reason="provider_credits_dry"} == 0
    while fleet_seat_healthy{class=~"prepaid|free"} > 0` over seven days.
    The writer (bin/money-boundary-raise) appends one line per page (or
    suppressed page) to money-boundary-pages.log:
        <ts> reason=<reason> provider=<p>            (a real page)
        <ts> suppressed reason=<reason> provider=<p>  (a suppressed page)
    Returns a dict {reason: count} of REAL (non-suppressed) pages in the
    trailing 7 days. Suppressed lines do not count toward the total — the
    metric tracks pages that actually reached Nish. Returns {} when the
    log is missing/unreadable.
    """
    log = _money_boundary_pages_log()
    if not log.is_file():
        return {}
    cutoff = time.time() - 7 * 86400
    counts = {}
    try:
        for line in log.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # Skip suppressed lines — they did not reach Nish. The writer
            # emits `<ts> suppressed reason=...` (the remainder after the
            # first space starts with "suppressed").
            if line.split(" ", 1)[1].startswith("suppressed"):
                continue
            ts = line.split(" ", 1)[0]
            try:
                epoch = calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
            except ValueError:
                continue
            if epoch < cutoff:
                continue
            m = re.search(r"reason=([A-Za-z0-9_-]+)", line)
            if not m:
                continue
            reason = m.group(1)
            counts[reason] = counts.get(reason, 0) + 1
    except OSError:
        return {}
    return counts


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
    # 0509_user_journey / digest_delivery: source metrics pending instrumentation
    # (follow-up issues). Even if flagged instrumented=true in config, no live
    # reader exists yet → not instrumented.
    return None, False


def _emit_slo_metrics(lines, main_ci, healthy, rate_limit):
    """Append the fleet_slo_* gauge family for every SLO in the config.

    Called from main() with the data it has already gathered. Reads
    fleet-waste.prom and seat-caps.json for the SLOs
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

# fleet-ops#4260: the blocked queue must be observable BY KIND so a parked
# needs-orchestrator class is visible before a human notices the fleet went
# idle. `kind` values come from the reconcile snapshot: the agent-blocked
# queue kinds (work-item/nish-decision/orchestrator/infra/senior-review) plus
# needs-orchestrator, which counts the label sweep across ALL open issues —
# a wider set, overlapping the others by design (an issue can be both
# agent-blocked and needs-orchestrator). Every kind is always emitted (0 when
# absent) so a stale family cannot false-fire or false-clear an alert.
_BLOCKED_KINDS = (
    "work-item",
    "nish-decision",
    "orchestrator",
    "infra",
    "senior-review",
    "needs-orchestrator",
)
HELP_FBI = "# HELP fleet_blocked_issues Open blocked issues by kind from the last blocked-reconcile sweep (fleet-ops#4260). kind=needs-orchestrator counts the label sweep across all open issues; the other kinds count the agent-blocked queue."
TYPE_FBI = "# TYPE fleet_blocked_issues gauge"
HELP_FBIA = "# HELP fleet_blocked_issue_age_seconds Age stats for blocked issues by kind, seconds, from the last blocked-reconcile sweep (fleet-ops#4260). kind=needs-orchestrator reports time since the issue entered that class (last label add), not issue age: FleetNeedsOrchestratorStale measures a parked drain, not old tickets."
TYPE_FBIA = "# TYPE fleet_blocked_issue_age_seconds gauge"


def _emit_blocked_reconcile(lines):
    """Append blocked-queue metrics.

    Reads the last blocked-reconcile sweep summary. A missing or
    unparseable file emits zeros so the metric families are always present.
    """
    count = 0
    by_kind = {k: 0 for k in _BLOCKED_KINDS}
    orch_p50 = 0
    orch_oldest = 0
    try:
        data = json.loads(BLOCKED_QUEUE_JSON.read_text(encoding="utf-8"))
        raw = data.get("rejected_nish_decisions")
        if isinstance(raw, (int, float)):
            count = int(raw)
        for item in data.get("items") or []:
            k = item.get("kind") if isinstance(item, dict) else None
            if k in by_kind:
                by_kind[k] += 1
        orch = data.get("needs_orchestrator")
        if isinstance(orch, dict):
            oc = orch.get("count")
            if isinstance(oc, (int, float)):
                by_kind["needs-orchestrator"] = int(oc)
            for key, dest in (("p50_age_s", "p50"), ("oldest_age_s", "oldest")):
                v = orch.get(key)
                if isinstance(v, (int, float)):
                    if dest == "p50":
                        orch_p50 = int(v)
                    else:
                        orch_oldest = int(v)
    except (OSError, json.JSONDecodeError):
        pass
    lines.append("")
    lines.append(HELP_NBR)
    lines.append(TYPE_NBR)
    lines.append(f"fleet_nish_decision_rejected_total {count}")
    lines.append("")
    lines.append(HELP_FBI)
    lines.append(TYPE_FBI)
    for k in _BLOCKED_KINDS:
        lines.append(f'fleet_blocked_issues{{kind="{k}"}} {by_kind[k]}')
    lines.append("")
    lines.append(HELP_FBIA)
    lines.append(TYPE_FBIA)
    lines.append(
        'fleet_blocked_issue_age_seconds{kind="needs-orchestrator",quantile="0.5"} '
        f"{orch_p50}"
    )
    lines.append(
        'fleet_blocked_issue_age_seconds{kind="needs-orchestrator",quantile="1"} '
        f"{orch_oldest}"
    )


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
    "reasons are claim-branch (delivery PR head), closes-trailer (explicit "
    "Closes/Fixes/Resolves trailer), and verdict-pass (verification-only "
    "issue with a worker VERDICT: PASS comment; fleet-ops#4274). "
    "bare-mention and protected must always be 0; an alert on either > 0 "
    "catches a wrong close of a mentioned or critical-path/owner-authored issue."
)
TYPE_MPC = "# TYPE fleet_observe_to_close_total gauge"
_MPC_REASONS = ("claim-branch", "closes-trailer", "verdict-pass", "bare-mention", "protected")


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


# fleet-ops#5785: deploy-fault close gate gauges. Two sources, both written
# by existing sweeps:
#   - lifecycle-label-sweep.json: deploy_fault_closed_without_green is the
#     issue's "must be 0" metric — every unit is a deploy-fault issue the
#     sweep found CLOSED without a green production run and reopened.
#   - merged-pr-close.json: deploy_fault_gate_blocked counts deliveries
#     observe-to-close refused to close this tick because production is
#     not green yet (the gate holding, not a violation).
LIFECYCLE_SWEEP_JSON = Path(
    os.environ.get(
        "FLEET_LIFECYCLE_SWEEP_JSON",
        "/home/nish/.local/state/fleet-heartbeat/lifecycle-label-sweep.json",
    )
)
HELP_DFG = (
    "# HELP fleet_deploy_fault_closed_without_green Deploy-fault issues found "
    "closed without a green production-deploy run proving the fix in the last "
    "lifecycle-label-sweep tick (each was reopened; fleet-ops#5785). Must be 0."
)
TYPE_DFG = "# TYPE fleet_deploy_fault_closed_without_green gauge"
HELP_DFG_BLOCKED = (
    "# HELP fleet_deploy_fault_gate_blocked Deliveries observe-to-close refused "
    "to close this tick because the deploy-fault issue has no green "
    "production-deploy run containing the fix yet (fleet-ops#5785)."
)
TYPE_DFG_BLOCKED = "# TYPE fleet_deploy_fault_gate_blocked gauge"
HELP_DFG_LABELED = (
    "# HELP fleet_deploy_fault_labeled Open issues the lifecycle sweep labelled "
    "deploy-fault this tick because the body cites a failed production-deploy "
    "run (fleet-ops#5785)."
)
TYPE_DFG_LABELED = "# TYPE fleet_deploy_fault_labeled gauge"


def _emit_deploy_fault_gate(lines):
    """Append the fleet_deploy_fault_* gauges. Never raises: missing or
    unparseable summaries emit 0 so the tripwire only fires on a real count."""
    violations = 0
    labeled = 0
    try:
        data = json.loads(LIFECYCLE_SWEEP_JSON.read_text(encoding="utf-8"))
        if isinstance(data.get("deploy_fault_closed_without_green"), (int, float)):
            violations = int(data["deploy_fault_closed_without_green"])
        if isinstance(data.get("deploy_fault_labeled"), (int, float)):
            labeled = int(data["deploy_fault_labeled"])
    except (OSError, json.JSONDecodeError):
        pass
    blocked = 0
    try:
        data = json.loads(MERGED_PR_CLOSE_JSON.read_text(encoding="utf-8"))
        if isinstance(data.get("deploy_fault_gate_blocked"), (int, float)):
            blocked = int(data["deploy_fault_gate_blocked"])
    except (OSError, json.JSONDecodeError):
        pass
    lines.append("")
    lines.append(HELP_DFG)
    lines.append(TYPE_DFG)
    lines.append(f"fleet_deploy_fault_closed_without_green {violations}")
    lines.append(HELP_DFG_BLOCKED)
    lines.append(TYPE_DFG_BLOCKED)
    lines.append(f"fleet_deploy_fault_gate_blocked {blocked}")
    lines.append(HELP_DFG_LABELED)
    lines.append(TYPE_DFG_LABELED)
    lines.append(f"fleet_deploy_fault_labeled {labeled}")


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
# Client-side floor on merge age (fleet-ops#3948): a PR younger than this is
# never evaluated, whatever the search returned.
WEEK_LATER_MIN_AGE_S = 7 * 86400 - WEEK_LATER_WINDOW_S
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
        f"merged:{start_iso}..{end_iso} sort:merged-desc\"" "\n"
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
        if now - merged_epoch < WEEK_LATER_MIN_AGE_S:
            # fleet-ops#3948: the search window is the only thing that
            # makes this a WEEK-later check. When it leaks younger PRs
            # (two `merged:` qualifiers were OR-ed by GitHub search and
            # returned everything merged in the last 7d), before and
            # after cover the same trailing-7d data and the PR is filed
            # as a revert candidate hours after merge. Not evaluated, not
            # recorded: retried when it is actually a week old.
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


# --- Inotify budget (fleet-ops#5839) ----------------------------------------

# fleet-ops#5839: 2026-09-12 11:19-11:40 IST a transient uid-1000 tree-watcher
# consumed the whole fs.inotify.max_user_watches budget (124083) and every
# systemd --user unit start logged 2x "Failed to add control|memory inotify
# watch descriptor for control group ...: No space left on device" (~50
# lines/2h) while the steady state sat at ~273 watches / 10 instances. fd
# accounting is not journaled anywhere on the box, so a journal-only
# investigation could name the limiter (max_user_watches — ENOSPC is raised by
# inotify_add_watch when the per-uid watch budget is full) but never the
# holder. This family samples /proc at scrape time — the exporter timer fires
# every 5 min (systemd/fleet-metrics-export.timer), so a 21-min burst spans
# 4+ scrapes — and carries the top holder pid+cmd so the NEXT burst is caught
# mid-flight. The usage/limit ratio drives FleetInotifyWatchExhausted in
# config/fleet_rules.yml. Pure /proc reads; never raises, never touches gh;
# any read failure degrades to -1 (UNKNOWN) rather than dropping the family
# so absent() stays meaningful.

INOTIFY_WATCHES_PATH = "/proc/sys/fs/inotify/max_user_watches"
INOTIFY_INSTANCES_PATH = "/proc/sys/fs/inotify/max_user_instances"

HELP_IUSE = "# HELP fleet_inotify_watch_usage Total inotify watch descriptors held by processes of this uid (fleet-ops#5839)."
TYPE_IUSE = "# TYPE fleet_inotify_watch_usage gauge"
HELP_ILIM = "# HELP fleet_inotify_watch_limit fs.inotify.max_user_watches — the per-uid watch budget the usage burns against (fleet-ops#5839)."
TYPE_ILIM = "# TYPE fleet_inotify_watch_limit gauge"
HELP_IINS = "# HELP fleet_inotify_instance_usage Inotify instances (fds) held by processes of this uid (fleet-ops#5839)."
TYPE_IINS = "# TYPE fleet_inotify_instance_usage gauge"
HELP_IILM = "# HELP fleet_inotify_instance_limit fs.inotify.max_user_instances — the per-uid instance budget (fleet-ops#5839)."
TYPE_IILM = "# TYPE fleet_inotify_instance_limit gauge"
HELP_IRAT = "# HELP fleet_inotify_watch_usage_ratio fleet_inotify_watch_usage / fleet_inotify_watch_limit (-1 when the limit is unreadable) (fleet-ops#5839)."
TYPE_IRAT = "# TYPE fleet_inotify_watch_usage_ratio gauge"
HELP_ITOP = "# HELP fleet_inotify_watch_top Watches held by the top 3 processes of this uid, by pid+cmd — sampled DURING a burst this names the consumer (fleet-ops#5839)."
TYPE_ITOP = "# TYPE fleet_inotify_watch_top gauge"


def _proc_sys_int(path):
    """Read an int from /proc/sys; -1 (UNKNOWN) on any failure (fleet-ops#5839)."""
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return -1


def _inotify_usage():
    """Sample the per-uid inotify watch/instance budget from /proc.

    fleet-ops#5839: emits the usage, limits, usage/limit ratio and the top 3
    watch holders (pid+cmd labels). fd counts are not journaled anywhere, so
    this scrape-time sample is the only way to name a burst consumer after
    the fact. Defensive: every read failure degrades, never raises.
    """
    uid = os.getuid()
    usage = 0
    instances = 0
    holders = []  # (watches, pid, cmd)
    try:
        pid_dirs = list(Path("/proc").glob("[0-9]*"))
    except OSError:
        pid_dirs = []
    for pid_dir in pid_dirs:
        fd_dir = pid_dir / "fd"
        try:
            if pid_dir.stat().st_uid != uid:
                continue
            fds = os.listdir(fd_dir)
            raw = (pid_dir / "cmdline").read_bytes()
        except OSError:
            continue
        cmd = raw.replace(b"\0", b" ").decode("utf-8", "replace").strip()[:60]
        pid = pid_dir.name
        pid_watches = 0
        for fd in fds:
            try:
                if "inotify" not in os.readlink(fd_dir / fd):
                    continue
            except OSError:
                continue
            instances += 1
            try:
                with open(pid_dir / "fdinfo" / fd) as fh:
                    pid_watches += sum(
                        1 for line in fh if line.startswith("inotify wd:")
                    )
            except OSError:
                pass
        usage += pid_watches
        if pid_watches > 0:
            holders.append((pid_watches, pid, cmd or "unknown"))
    holders.sort(reverse=True)
    limit = _proc_sys_int(INOTIFY_WATCHES_PATH)
    ratio = round(usage / limit, 6) if limit > 0 else -1.0

    def _esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")

    out = [
        "",
        HELP_IUSE,
        TYPE_IUSE,
        f"fleet_inotify_watch_usage {usage}",
        "",
        HELP_ILIM,
        TYPE_ILIM,
        f"fleet_inotify_watch_limit {limit}",
        "",
        HELP_IINS,
        TYPE_IINS,
        f"fleet_inotify_instance_usage {instances}",
        "",
        HELP_IILM,
        TYPE_IILM,
        f"fleet_inotify_instance_limit {_proc_sys_int(INOTIFY_INSTANCES_PATH)}",
        "",
        HELP_IRAT,
        TYPE_IRAT,
        f"fleet_inotify_watch_usage_ratio {ratio}",
        "",
        HELP_ITOP,
        TYPE_ITOP,
    ]
    for pid_watches, pid, cmd in holders[:3]:
        out.append(
            f'fleet_inotify_watch_top{{pid="{pid}",cmd="{_esc(cmd)}"}} {pid_watches}'
        )
    if not holders:
        # Emit the series even when no pid holds watches, so absent() and the
        # rule rows stay predictable (fleet-ops#1844 class: the family must
        # never silently vanish).
        out.append('fleet_inotify_watch_top{pid="-1",cmd="none"} 0')
    return out


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
    # A test injects a fake gh (GH != 'gh'); no human gh write is possible, so
    # skip minting there too. Production callers never set GH.
    if os.environ.get("GH", "gh") != "gh":
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
    # fleet-ops#3445's fail-closed guard is about gh WRITES (the week-later
    # revert-candidate filing below). Everything else in this exporter is
    # read-only, so a transient worker-token mint failure (GitHub
    # /app/installations hiccup / rate-limit / stale install cache) must
    # DEGRADE to a read-only tick, not abort the export — otherwise a token
    # hiccup fails the metrics write (all fleet_* gauges go stale) and trips
    # unit-escalation every 5 min for a non-write outage (recurring trips:
    # 2026-09-05T19:48Z, 20:05Z, 21:17Z, 2026-09-06T09:15Z, 2026-09-08T06:10Z,
    # fleet-metrics-export.service exit-code 1). When the App token cannot
    # mint, the write family is skipped; human gh is read-only for organs.
    gh_write = True
    try:
        _ensure_worker_token()
    except SystemExit:
        gh_write = False
        print(
            "fleet-metrics-export: app token unavailable this tick — running "
            "READ-ONLY (revert-candidate filing disabled); gh reads may use "
            "the human identity (read-only)",
            file=sys.stderr,
        )
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
    # fleet-ops#5839: per-uid inotify budget — /proc sample of watches,
    # instances, limits, ratio and the top holders, so a tree-watcher burst
    # is caught mid-flight with its pid instead of only surfacing as journal
    # ENOSPC lines after the fact. Drives FleetInotifyWatchExhausted.
    lines.extend(_inotify_usage())
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
    # fleet-ops#4627: per-class healthy seat count + money-boundary page
    # counter. The starvation gate pages Nish ONLY when the fleet is starved
    # (no healthy prepaid/free seat). This gauge exposes the per-class count
    # so the alert rule and the success metric can key on it. The page
    # counter rolls up real (non-suppressed) pages by reason over 7d.
    _shc = _healthy_enrolled_seat_count_by_class()
    lines.append("")
    lines.append(HELP_SHC)
    lines.append(TYPE_SHC)
    for _cls, _n in sorted(_shc.items()):
        lines.append(f'fleet_seat_healthy{{class="{_cls}"}} {_n}')
    _mbp = _read_money_boundary_pages()
    lines.append("")
    lines.append(HELP_MBPT)
    lines.append(TYPE_MBPT)
    for _reason, _n in sorted(_mbp.items()):
        lines.append(f'nish_boundary_money_pages_total{{reason="{_reason}"}} {_n}')
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
    if _CACHE_TS_SERVED:
        lines.append("")
        lines.append(HELP_CTS)
        lines.append(TYPE_CTS)
        for _kind, _ts in sorted(_CACHE_TS_SERVED.items()):
            lines.append(
                f'fleet_gh_cache_timestamp_seconds{{kind="{_kind}"}} {_ts:.0f}'
            )

    # Escalations per unit (top 20).
    esc_counts = _escalations_24h()
    lines.append("")
    lines.append(HELP_ESC)
    lines.append(TYPE_ESC)
    for unit in sorted(esc_counts):
        lines.append(
            f'fleet_escalations_24h{{unit="{unit}"}} {esc_counts[unit]}'
        )

    # oomd kills of app-pi-issue.slice units in the last 6h (fleet-ops#4164).
    oomd_counts = _oomd_kills_6h()
    lines.append("")
    lines.append(HELP_OOMD)
    lines.append(TYPE_OOMD)
    for unit in sorted(oomd_counts):
        lines.append(
            f'fleet_oomd_kills_6h{{unit="{unit}"}} {oomd_counts[unit]}'
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

    # --- Worktree reaper gauge (fleet-ops#4118) ---
    # The reaper (bin/fleet-worktree-reaper) writes a daily summary JSON. The
    # present gauge is ALWAYS emitted so the heartbeat can tell a dead reaper
    # (0) from a healthy one (1); the count + heartbeat gauges are emitted only
    # when the summary is present and fresh (a missing/stale summary means the
    # count is unknown, not 0). fleet_worktree_dirs is the count metric the
    # heartbeat gauges for unbounded worktree sprawl.
    wt = _read_worktree_reaper()
    lines.append("")
    lines.append(HELP_WTP)
    lines.append(TYPE_WTP)
    lines.append(f"fleet_worktree_reaper_present {1 if wt.get('present') else 0}")
    if wt.get("present"):
        lines.append("")
        lines.append(HELP_WTD)
        lines.append(TYPE_WTD)
        lines.append(f"fleet_worktree_dirs {int(wt.get('post_count') or 0)}")
        lines.append("")
        lines.append(HELP_WTR)
        lines.append(TYPE_WTR)
        lines.append(f"fleet_worktree_reaped {int(wt.get('reaped') or 0)}")
        if isinstance(wt.get("ts"), str):
            ts_epoch = _parse_iso_utc(wt["ts"])
            if ts_epoch is not None:
                lines.append("")
                lines.append(HELP_WTHB)
                lines.append(TYPE_WTHB)
                lines.append(f"fleet_worktree_reaper_heartbeat_seconds {ts_epoch}")

    # --- Seat yield ledger (fleet-ops#3250) ---
    # Computed from the agent's own pi-issue session files. Per-seat rolling
    # last-20-sessions PR yield; new/idle seats get a provisional 0.5 yield
    # so they are tried, not starved. Emits the family and writes a JSON
    # sidecar for lib/seat-lib.sh pick_seat to consume.
    seat_yield = _compute_seat_yield()
    _emit_seat_yield(lines, seat_yield)

    # --- Seat spend + metered provider balances (fleet-ops#3283) ---
    # Spend is derived from per-message usage.cost in pi session jsonl.  Balance
    # is fetched from each vendor's own credits/usage endpoint where one exists.
    spend = _compute_spend()
    _emit_spend(lines, spend)
    # fleet-ops#4459: rate-card USD for the 24h + $/merged-PR, shared with measure.sh
    _emit_usd_24h(lines, pr_counts)
    # fleet-ops#4643: prompt prefix-cache hit ratio (cacheRead vs uncached input)
    _emit_cache_hit_ratio(lines)
    openrouter_balance = _cached_vendor_json(
        OPENROUTER_BALANCE_CACHE, _fetch_openrouter_credits, "openrouter_credits"
    )
    xkiro_usage = _cached_vendor_json(
        XKIRO_BALANCE_CACHE, _fetch_xkiro_usage, "xkiro_usage"
    )
    balances = {}
    if openrouter_balance is not None:
        balances["openrouter"] = openrouter_balance
    if xkiro_usage is not None and xkiro_usage[1] is not None:
        balances["xkiro"] = xkiro_usage[1]
    _emit_credits_remaining(lines, balances)
    _emit_xkiro_wallet(lines, xkiro_usage)

    # --- Live seat quotas (fleet-ops#4217) ---
    # VPS-native API reads. Each fetcher is cached independently; a None
    # return omits that provider's rows (never a frozen value). observed_at is
    # the real observation ts so fleet_seat_quota_observed_seconds reports the
    # true age of the quota figure — a stale fetch surfaces as growing
    # observed_seconds, never a fresh-looking 0 (the "Stale (>15 min)" alert
    # depends on this). Browser-session seats (Grok, Ollama, Z.ai, OpenCode,
    # RunInfra, ZenMux, Cline, Straitly, MiniMax, CommandCode) are follow-up
    # issues (#4232 / #4233) — each slots in as one fetcher.
    openrouter_key, openrouter_key_obs = _cached_quota_json(
        OPENROUTER_KEY_CACHE, _fetch_openrouter_key, "openrouter_key"
    )
    claude_usage, claude_usage_obs = _cached_quota_json(
        CLAUDE_QUOTA_CACHE, _fetch_claude_usage, "claude_usage"
    )
    codex_usage, codex_usage_obs = _cached_quota_json(
        CODEX_QUOTA_CACHE, _fetch_codex_usage, "codex_usage"
    )
    cursor_usage, cursor_usage_obs = _cached_quota_json(
        CURSOR_QUOTA_CACHE, _fetch_cursor_usage, "cursor_usage"
    )
    devin_usage, devin_usage_obs = _cached_quota_json(
        DEVIN_QUOTA_CACHE, _fetch_devin_usage, "devin_usage"
    )
    xkiro_quota, xkiro_quota_obs = _cached_quota_json(
        XKIRO_QUOTA_CACHE, _fetch_xkiro_quota, "xkiro_quota"
    )
    _quota_providers = []
    if isinstance(openrouter_key, dict):
        _quota_providers.append(("openrouter", [openrouter_key], openrouter_key_obs))
    if isinstance(claude_usage, list):
        _quota_providers.append(("claude", claude_usage, claude_usage_obs))
    else:
        # fleet-ops#4611: claude is a billable OAuth seat that must always meter
        # when the token is valid. A dead fetch (401/429) that outlives the
        # 30-min stale window makes _cached_quota_json return (None, None) and
        # the provider used to be dropped — the whole claude gauge family went
        # silently absent for days while the generic absent() rule stayed silent
        # (other providers kept the family present). Emit the observed_seconds
        # gauge with a growing anchor (source="stale") so FleetClaudeQuotaStale
        # fires and a dark money meter is loud, not invisible.
        _quota_providers.append(("claude", None, _claude_observed_anchor()))
    if isinstance(codex_usage, list):
        _quota_providers.append(("codex", codex_usage, codex_usage_obs))
    if isinstance(cursor_usage, list):
        _quota_providers.append(("cursor", cursor_usage, cursor_usage_obs))
    if isinstance(devin_usage, list):
        _quota_providers.append(("devin", devin_usage, devin_usage_obs))
    if isinstance(xkiro_quota, list):
        _quota_providers.append(("xkiro", xkiro_quota, xkiro_quota_obs))
    if _quota_providers:
        _emit_seat_quota_headers(lines)
        for _prov, _rows, _obs in _quota_providers:
            if _rows:
                _emit_seat_quota(lines, _prov, _rows, "api", _obs)
            else:
                _emit_seat_quota_fail_loud(lines, _prov, _obs)

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

    # --- 0509 signups funnel (fleet-ops#4582) ---
    # The direction metric (signups/week) read live from 0509's D1 every tick
    # over the sanctioned Cloudflare path (no new credential). A healthy-empty
    # table exports 0; an unreachable source returns None and the family is
    # omitted (never a fabricated 0), so absent() surfaces the outage.
    _emit_signups_7d(lines, _fetch_signups_7d())

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
    _emit_deploy_fault_gate(lines)

    # --- Week-later revert check (fleet-ops#3124 part 4/4) ---
    # For each fleet-ops PR merged ~7 days ago with a `moves:` metric, compare
    # the metric's 7d value before vs after; if it did not improve, file ONE
    # revert-candidate issue (never re-filed). Non-fatal: a failure is logged
    # and the exporter still writes fleet.prom.
    if gh_write:
        _week_later_revert_check()
    else:
        print(
            "week-later: skipped (app token unavailable — no human-gh write)",
            file=sys.stderr,
        )

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
