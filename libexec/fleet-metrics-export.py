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

OUT = Path(
    os.environ.get(
        "FLEET_METRICS_OUT", "/var/lib/prometheus/node-exporter/fleet.prom"
    )
)
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
HELP_HEALTH = "# HELP fleet_pi_seat_healthy 1 if the Pi seat is healthy, else 0."
TYPE_HEALTH = "# TYPE fleet_pi_seat_healthy gauge"
# fleet-ops#3111: a stale pi-seat-health.json must read as UNKNOWN, never
# "healthy". The 2026-09-03 incident left the console tile saying "seat
# healthy" from a 2-day-old observation while the transport was down 33h.
# Age in seconds since observed_at; absent/unparseable -> -1 (UNKNOWN). The
# alert rule fires >1800 (30 min) so a stale feed can never mask an outage.
HELP_AGE = "# HELP fleet_pi_seat_health_age_seconds Seconds since the Pi seat was last observed (-1 if the observation is absent/unparseable). fleet-ops#3111."
TYPE_AGE = "# TYPE fleet_pi_seat_health_age_seconds gauge"
HELP_DCT = "# HELP fleet_pi_seat_dead_credential_total Number of enrolled (model cap>0) seats with seat_dead=true carrying a credentials_bad signal in health_class or failure_mode (HTTP 401/403) that will not recover on their own (fleet-ops#1445, fleet-ops#2667, fleet-ops#3301)."
TYPE_DCT = "# TYPE fleet_pi_seat_dead_credential_total gauge"
HELP_DC = "# HELP fleet_pi_seat_dead_credential 1 for each dead-credential seat; health_class=credentials_bad means re-auth may help, health_class=corpse means the seat is terminal and must be retired from config/seat-caps.json (fleet-ops#1445, fleet-ops#2667)."
TYPE_DC = "# TYPE fleet_pi_seat_dead_credential gauge"
# fleet-ops#2638: never-probed comeback visibility. Counts seats the prober
# has been failing on (consecutive_failure_count >= 10) without yet reaching
# the corpse threshold (default 25). Sustained > 0 here is the loud signal
# that the release path is firing but the seat still cannot recover — the
# next sweep should corpse it. Combined with fleet_seat_comeback_overdue_total
# it tells the repair worker which overdue seats are approaching the corpse
# boundary before the bin has actually written the corpse.
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
HELP_CI = "# HELP fleet_main_ci_green 1 if default-branch CI is green, 0 if red. PENDING rollup resolved from latest completed CI run; repos with no CI omitted. Tracks only the workflow literally named \"CI\" — a repo's production-deploy greenness is fleet_product_deploy_green (fleet-ops#5140)."
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
WORKTREE_REAPER_STALE_S = 7 * 86400

# Worktree reaper gauge family (fleet-ops#4118). fleet_worktree_dirs is the
# count of dirs left under agent-worktrees after the last reap — the
# unbounded-growth invariant the issue tracks. fleet_worktree_reaped_total is
# how many the reaper removed that run. The present gauge is ALWAYS emitted so
# the heartbeat can tell a dead reaper (0) from a healthy one (1); the count
# gauges are emitted only when the summary is present and fresh (a missing or
# stale summary means the count is unknown, not 0).


PR_CACHE_DIR = Path("/home/nish/workspaces/agent-state/fleet-metrics")
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
GH_PAGES = 10

# GitHub API rate-limit heartbeat (fleet-ops#1350). The 5000/hr core budget
# is the next binding constraint past RAM (Nish 2026-08-27 #1167 ceiling
# addendum), so the exporter pulls `gh api rate_limit` once per run. The
# per-resource remaining/limit/reset/low gauges were deleted on 2026-09-18
# (fourth cut, Jev p=0.79 ref fourth-cut-metrics) — nothing read them. The
# shaped dict is still LOAD-BEARING for two readers:
#   - _slo_compliance (gh_rate_limit_headroom SLO) reads remaining/limit
#     straight off the returned dict, never off Prometheus;
#   - _write_gh_rate_limit_state writes the pi-intake-tick.sh throttle
#     side-car (low + smallest remaining/limit) that gates claims.
# The `fleet_gh_rate_limit_fetched_seconds` gauge is the organ heartbeat
# (fleet-ops#1010): the absent() rule in fleet_rules.yml fires when the
# exporter stops pulling the limit. A failing gh call OMITS the family.
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
    "seat_availability",
    "gh_rate_limit_headroom",
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

# --- Seat yield ledger (fleet-ops#3250) ---
# Pi issue-work sessions live here. Only pi-issue-* directories carry product
# work; scout/canary/audit roles use other dirs and keep their own routing.
SESSIONS_DIR = Path(
    os.environ.get("FLEET_SESSIONS_DIR", str(Path.home() / ".pi" / "agent" / "sessions"))
)
# Per-file parse cache so re-export ticks are cheap; keyed on file mtime seconds.
# JSON sidecar consumed by lib/seat-lib.sh pick_seat. Not a new organ; just a
# state file written by the existing fleet-metrics-export tick.
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



# fleet-ops#4643: prompt prefix-cache hit ratio. cacheRead is the cached
# prefix; input is uncached prompt tokens. ratio = cacheRead/(input+cacheRead).
# class follows the issue's metered/free vocabulary (prepaid-quota seats bill
# uncached input the same way metered seats do, so they count as metered).











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
# 2026-09-13: 429/403 denial sidecar — written when the usage endpoint answers
# 403 oauth_not_allowed_for_organization (cancelled subscription -> claude_free
# denies ALL OAuth; effectively permanent) or 429 (transient; honours
# Retry-After). While live the poller sends NO request at all, so a dark
# meter costs 4 requests/day instead of 288.
CLAUDE_QUOTA_BACKOFF = PR_CACHE_DIR / "claude-quota-backoff.json"
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

    2026-09-13 denial incident (#4611 lineage): the org's Max subscription was
    cancelled, so the org flipped to claude_free and denied ALL OAuth —
    /api/oauth/usage AND /v1/messages both 403 oauth_not_allowed_for_organization
    (proven live 09:47Z; the profile endpoint still 200s, so the token itself
    is alive). The 5-min poller answered 80+ consecutive 429/403s over 6.7h.
    While the CLAUDE_QUOTA_BACKOFF sidecar is live this poller sends NO request
    at all: 403 -> kind=denied, 6h recheck; 429 -> kind=rate honouring
    Retry-After. A success clears the sidecar (self-heal when the
    subscription returns — no human un-gating step).
    To force-verify a re-subscribed org, delete the sidecar; the next 5-min
    run fetches for real.
    """
    backoff = _claude_quota_backoff()
    if backoff:
        print(
            f"claude usage skipped: {backoff.get('kind') or '?'} backoff, "
            f"{int(float(backoff.get('until') or 0) - time.time())}s left "
            "(claude-usage 429/403 denial 2026-09-13; #4611 lineage)",
            file=sys.stderr,
        )
        return None
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
        elif exc.code in (403, 429):
            # 2026-09-13: 403 permission_error oauth_not_allowed_for_organization
            # (cancelled subscription -> claude_free) repeats forever; 429 is
            # their generic denial bucket, Retry-After ~56min. Back off instead
            # of hammering at 12 polls/hour (80+ consecutive failures, 6.7h).
            # Note: the 401->forced-refresh->retry path below swallows a retry
            # 403/429 as a generic failure without stamping the sidecar; the
            # next 5-min run then stamps it via this elif. Accepted: that
            # combination (dead token AND denied org) is rare and costs one
            # extra poll.
            _claude_quota_backoff_write(exc)
            print(f"claude usage fetch failed: {exc}", file=sys.stderr)
            return None
        else:
            print(f"claude usage fetch failed: {exc}", file=sys.stderr)
            return None
    except (OSError, urllib.error.URLError, json.JSONDecodeError, ValueError) as exc:
        print(f"claude usage fetch failed: {exc}", file=sys.stderr)
        return None
    if not isinstance(payload, dict):
        return None
    # Success (fresh or via the 401 -> forced-refresh -> retry path) clears the
    # backoff: the org allows OAuth again, the meter resumes, and the #4221-style
    # rule gate lifts itself. No human un-gating step.
    try:
        CLAUDE_QUOTA_BACKOFF.unlink()
    except OSError:
        pass
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


def _claude_quota_backoff():
    """Live claude usage backoff sidecar, or None. (2026-09-13, #4611 lineage)

    Written by _claude_quota_backoff_write when /api/oauth/usage answers
    403 oauth_not_allowed_for_organization (kind=denied — the org's
    subscription is cancelled, claude_free denies OAuth outright; effectively
    permanent) or 429 (kind=rate — transient, Retry-After honoured). While the
    sidecar is live the poller sends NO request at all. The metric side reads
    kind=denied to flip the fail-loud gauge to source=denied, which the
    FleetClaudeQuotaStale rule's #4221-style unless-gate consumes so a
    deliberately-dark cancelled subscription does not page the fleet.
    """
    try:
        doc = json.loads(CLAUDE_QUOTA_BACKOFF.read_text())
    except (OSError, json.JSONDecodeError, ValueError):
        return None
    until = doc.get("until") if isinstance(doc, dict) else None
    if not isinstance(until, (int, float)) or until <= time.time():
        return None
    return doc


def _claude_quota_backoff_write(exc):
    """Persist the claude usage backoff decision. (2026-09-13, #4611 lineage)

    403 permission_error oauth_not_allowed_for_organization -> kind=denied,
    6h lease: the org (claude_free after cancellation) denies OAuth at the
    account level, so the denial repeats until the subscription returns and
    retrying sooner just feeds the 429 bucket. 429 -> kind=rate, Retry-After
    honoured, clamped 1m..2h (default 15m when the header is absent or
    unparsable — their 429s carried Retry-After ~56min live). ts continuity: a
    repeated denied 403 keeps the FIRST denial's ts so the source=denied
    gauge's denial AGE grows across 6h renewals instead of resetting.
    To force-verify a re-subscribed org, delete the sidecar; the next 5-min
    run fetches for real and the 200-path clears it anyway.
    """
    now = time.time()
    if getattr(exc, "code", None) == 429:
        kind, lease = "rate", 900
        try:
            lease = min(max(int(float(exc.headers.get("Retry-After") or 900)), 60), 7200)
        except (TypeError, ValueError, AttributeError):
            pass
    else:
        kind, lease = "denied", 6 * 3600
    prev = _claude_quota_backoff()
    ts = now
    if (
        kind == "denied"
        and prev
        and prev.get("kind") == "denied"
        and isinstance(prev.get("ts"), (int, float))
    ):
        ts = prev["ts"]
    try:
        PR_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        CLAUDE_QUOTA_BACKOFF.write_text(json.dumps(
            {"kind": kind, "until": now + lease, "lease_s": lease, "ts": ts}))
    except OSError:
        pass


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
        lines.append(
            f'fleet_seat_quota_remaining_pct{{provider="{_prom_label(provider)}",'
            f'window="{window}",source="{_prom_label(source)}"}} {pct:.4f}'
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

    2026-09-13: when the 403/429 denial sidecar is live with kind=denied (the
    org's subscription is cancelled, claude_free denies ALL OAuth), the source
    flips to "denied" and the anchor becomes the FIRST-403 ts, so the gauge
    reports the denial AGE ("deliberately unpaid-dark for N hours") instead of
    a stale-data age. The FleetClaudeQuotaStale rule's #4221-style unless-gate
    consumes that source=denied series: cancelled-subscription silence is
    deliberate, not a lost meter, and the gate lifts itself when the
    subscription returns and a fetch succeeds again.
    """
    now = time.time()
    source = "stale"
    anchor = observed_at
    if provider == "claude":
        backoff = _claude_quota_backoff()
        if backoff and backoff.get("kind") == "denied":
            source = "denied"
            denied_ts = backoff.get("ts")
            if isinstance(denied_ts, (int, float)):
                anchor = denied_ts
    observed_s = max(0.0, now - anchor) if anchor else QUOTA_STALE_S + 1
    lines.append(
        f'fleet_seat_quota_observed_seconds{{provider="{_prom_label(provider)}",'
        f'source="{_prom_label(source)}"}} {observed_s:.4f}'
    )


def _emit_seat_quota_headers(lines):
    """Emit one HELP/TYPE pair per quota metric name (call once before rows)."""
    lines.append("")
    lines.append(HELP_QUOTA_PCT)
    lines.append(TYPE_QUOTA_PCT)
    lines.append(HELP_QUOTA_OBSERVED)
    lines.append(TYPE_QUOTA_OBSERVED)


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






# fleet-ops#1291: per-alertname repair-outcome counts for the WFR
# alert-quality lens. The dispatcher writes one line per outcome with an
# `alertname=` token; this counts DISPATCH / RESOLVED / FAILED /
# SKIPPED-CLAIMED per alertname in the trailing 24h. The WFR computes
# action_rate = dispatch/(dispatch+skipped) and reads the RESOLVED text to
# judge false-positives — the stats feed the review, the review judges.
# Handles both bracketed `[YYYY-..Z]` and bare `YYYY-..Z` timestamps (the
# dispatcher's FAILED/RESOLVED lines use the bare form).
# fleet-ops#2694: phantom resolutions carry root_cause=PHANTOM_ALERT...
# (the value is underscore-joined; the first whitespace-delimited token is
# the signal). Real resolutions have transient_npm_.../no root_cause token.




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




# --- Self-maintenance repo set (fleet-ops#1136) ----------------------------
# The fleet_self_maintenance_* / fleet_pr_quality_* families were deleted on
# 2026-09-18 (fourth cut). This set survives because the queue-composition
# counters (_gh_ready_work / _gh_all_agent_ready) split open agent-ready work
# into self vs product with it.


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
# limit), then emits
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
                                # doesn't render every wall as stuck


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






def _slo_compliance(slo, main_ci, healthy, rate_limit, seat_total):
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
    # 0509_user_journey / digest_delivery: source metrics pending instrumentation
    # (follow-up issues). Even if flagged instrumented=true in config, no live
    # reader exists yet → not instrumented.
    return None, False


def _emit_slo_metrics(lines, main_ci, healthy, rate_limit):
    """Append the fleet_slo_* gauge family for every SLO in the config.

    Called from main() with the data it has already gathered. Reads
    seat-caps.json for the SLOs
    whose sources live outside this exporter. Always emits the family (even
    on a missing config — zeros with instrumented=0) so FleetSloMetricsAbsent
    never false-fires on a config glitch; a missing config is logged to
    stderr.
    """
    sb = _slo_budget_mod()
    defs = _load_slo_defs()
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
            slo, main_ci, healthy, rate_limit, seat_total
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



# fleet-ops#4260: the blocked queue must be observable BY KIND so a parked
# needs-orchestrator class is visible before a human notices the fleet went
# idle. `kind` values come from the reconcile snapshot: the agent-blocked
# queue kinds (work-item/nish-decision/orchestrator/infra/senior-review) plus
# needs-orchestrator, which counts the label sweep across ALL open issues —
# a wider set, overlapping the others by design (an issue can be both
# agent-blocked and needs-orchestrator). Every kind is always emitted (0 when
# absent) so a stale family cannot false-fire or false-clear an alert.







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
# Client-side floor on merge age (fleet-ops#3948): a PR younger than this is
# never evaluated, whatever the search returned.
WEEK_LATER_CACHE_TTL = 6 * 3600
# Per-PR evaluation ledger: once a PR is evaluated (improved / already-filed /
# filed) it is never re-evaluated, so the gh dedup/create calls are bounded to
# one per PR, not one per tick. Pruned after WEEK_LATER_STATE_TTL.
WEEK_LATER_STATE_TTL = 14 * 86400

# moves: metric -> Prometheus expression for the metric's value. The 7d value
# is the avg_over_time of this expression over a 7d window. Only metrics with
# a mapping here are comparable; add mappings as the sibling parts land.

# Line-anchored `moves:` field (the sibling spec-gate's body line). Leading
# list markers allowed so a `- moves: ...` body line counts, mirroring the
# spec-gate's FIELD_RE.




















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




LIFECYCLE_SWEEP_JSON = Path(
    os.environ.get(
        "FLEET_LIFECYCLE_SWEEP_JSON",
        "/home/nish/.local/state/fleet-heartbeat/lifecycle-label-sweep.json",
    )
)


def _emit_deploy_fault_gate(lines):
    """Append the fleet_deploy_fault_* gauges. Never raises: missing or
    unparseable summaries emit 0 so the tripwire only fires on a real count."""
    violations = 0
    try:
        data = json.loads(LIFECYCLE_SWEEP_JSON.read_text(encoding="utf-8"))
        if isinstance(data.get("deploy_fault_closed_without_green"), (int, float)):
            violations = int(data["deploy_fault_closed_without_green"])
    except (OSError, json.JSONDecodeError):
        pass
    lines.append("")
    lines.append(HELP_DFG)
    lines.append(TYPE_DFG)
    lines.append(f"fleet_deploy_fault_closed_without_green {violations}")


TYPE_DFG = "# TYPE fleet_deploy_fault_closed_without_green gauge"


HELP_DFG = (
    "# HELP fleet_deploy_fault_closed_without_green Deploy-fault issues found "
    "closed without a green production-deploy run proving the fix in the last "
    "lifecycle-label-sweep tick (each was reopened; fleet-ops#5785). Must be 0."
)


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
    lines.append(HELP_HEALTH)
    lines.append(TYPE_HEALTH)
    lines.append(f"fleet_pi_seat_healthy {healthy}")
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
    # family and the verified-merge numerator both derive from this single
    # fetch (one gh call/run).
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
        main_ci = snap.get("main_ci") or {}
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

    if fresh_kinds:
        lines.append("")
        lines.append(HELP_FRESH)
        lines.append(TYPE_FRESH)
        for kind in fresh_kinds:
            lines.append(f'fleet_gh_cache_fresh{{kind="{kind}"}} 1')
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
    if k_mtime is not None:
        lines.append("")
        lines.append(HELP_KHB)
        lines.append(TYPE_KHB)
        lines.append(f"fleet_keystone_routing_heartbeat_seconds {k_mtime:.3f}")

    # --- Seat spend + metered provider balances (fleet-ops#3283) ---
    # Spend is derived from per-message usage.cost in pi session jsonl.  Balance
    # is fetched from each vendor's own credits/usage endpoint where one exists.
    spend = _compute_spend()
    _emit_spend(lines, spend)
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

    # --- SLO error budgets (fleet-ops#1291) ---
    # Emitted last so every source the SLOs read (CI rollup, seat health,
    # rate limit) has been gathered this tick. fleet_pi_seat_total
    # is the seat_availability denominator; published here so the SLO's
    # compliance is auditable from the raw gauges alone.
    _emit_slo_metrics(lines, main_ci, healthy, rl)

    # --- Deployment quality SLOs (fleet-ops#2758) ---
    # Emitted after the SLO family so every data source this module reads
    # (gh, journal, actions log) is complete for the tick; a module fault
    # degrades to NaN + up 0 (see _emit_deploy_quality) and never fails
    # the exporter oneshot.
    _emit_deploy_quality(lines)

    # --- close-duplicates close guard (fleet-ops#3161) ---
    # Per-tick close count by label; cross_repo and protected must stay 0.
    _emit_close_duplicates(lines)

    # --- observe-to-close close guard (fleet-ops#3231) ---
    # Per-tick close count by reason; bare-mention and protected must stay 0.
    _emit_observe_to_close(lines)
    _emit_deploy_fault_gate(lines)

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
