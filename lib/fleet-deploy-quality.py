#!/usr/bin/env python3
"""Deployment quality SLOs for the fleet metrics exporter (fleet-ops#2758).

The fleet deploys fleet-ops via fleet-deploy-check.timer (2 min) -> bin/
fleet-ops-deploy on the VPS, not via GitHub Deployments (the API returns
zero deployments for this repo — verified live 2026-09-02). So this module
measures the deployment pipeline from the sources that actually record it:

  (a) deployment latency  = mergedAt -> first GREEN fleet-deploy-check
      cycle that ran the sanctioned deploy on the VPS. Green = a cycle
      whose "origin/main moved ... — invoking sanctioned deploy" line is
      NOT followed by a LOUD DEPLOY-BLOCKED / DEPLOY-CHECK-FAILED line.
      A merge whose wait contains a DEPLOY-BLOCKED event is excluded:
      that class is DeployBlockedStuck, and counting it after the
      episode ends is the hangover that kept DeploymentLatencyHigh
      firing for 24h+ on 2026-09-02..04 (fleet-ops#3136). Published
      as the p95 over the remaining samples in the trailing window.
  (b) rollback rate = auto-revert events / deployments over the trailing
      30 days. An auto-revert event is a PR titled
      "revert: auto-restore green main (reverts <sha>)" — the one artifact
      the auto-revert workflow produces when it actually performs a git
      revert. Workflow-run conclusion=success is NOT used deliberately:
      auto-revert.sh exits 0 on the "AUTO-REVERT SKIP: only non-required
      checks failed" halt path too (read .github/scripts/auto-revert.sh
      2026-09-02), so success-counting over-counts reverts ~5x.
  (c) time-to-detect = nearest prior merge -> first NEW critical alert
      episode (1:1). An episode starts on the first DISPATCH of an
      alertname after RESOLVED (or the first ever); redispatches of an
      already-open alert do not count. Critical names are curated to
      alerts whose Prometheus for: duration is UNDER the 10-min TTD
      budget (heartbeat/export staleness, fast burns) — FleetMainRed
      (for:30m) and 3h absence rules are
      excluded because they cannot meet the budget by construction.
      Host-health and synthetic alerts stay excluded. Published as p95
      over episode samples (NaN when fewer than TTD_MIN_SAMPLES).
  (d) deployment success rate = deployments with ZERO critical dispatch in
      the 1h after merge / total deployments (the issue's literal spec).
  (e) fleet_deploy_blocked_duration_seconds = age of the CURRENT blocked
      episode (a run of consecutive DEPLOY-BLOCKED cycles with no green in
      between), 0 when the pipeline is not blocked. Catches the #2725
      pattern: 2026-09-02 the VPS sat DEPLOY-BLOCKED on dirty tracked
      files for 30+ minutes with no mechanized alert.
  (f) product repos (fleet-ops#5140): every repo in config/intake-repos.json
      with product: true (fleet-ops itself excluded) gets its own deploy
      SLOs from its production-deploy workflow runs (0509: "Deploy
      production"). green = the newest run concluded success; blocked =
      age of the trailing run of consecutive non-green runs (an in-flight
      run is non-green — fail closed), 0 when the newest run is green;
      latency = mergedAt -> first green run. A product repo that cannot be
      measured emits NaN gauges plus fleet_deployment_quality_up{repo} 0 —
      never a silent absence. That is the signal that turns a 28h stall
      (2026-09-10: 131 merged product PRs that never reached a customer,
      invisible because every dashboard said green) into a metric.

Wiring: loaded lazily by libexec/fleet-metrics-export.py on the existing
5-min fleet-metrics-export tick (no new timer, no service change — the
issue's rollback contract). The module never raises out of the exporter:
a hard failure emits NaN gauges + fleet_deployment_quality_up 0 so the
DeploymentQualityStale rule screams instead of silently serving frozen or
zero values (a zero blocked-duration during a real 40-min block is exactly
the silent-drift the rule family exists to kill).

gh budget: at most ONE gh subprocess per scrape for the fleet-ops family
(merged fetch preferred, revert count serves its longer-TTL cache),
mirroring the exporter's _GH_FETCHED_THIS_RUN discipline so the 5-min
oneshot stays well under 60s. Cached to the same 30min/2h TTL/stale
envelope; a failing call serves the stale cache and only goes NaN after 2h.
Local sources (journal, actions log) are cached for 60s so an idle scrape is
a cheap read.

The product family (fleet-ops#5140) has a SEPARATE, hard-capped budget:
MAX_PRODUCT_FETCHES_PER_SCRAPE = 3 gh calls per scrape, counted in
_PRODUCT_FETCHES_THIS_RUN so _GH_FETCHED_THIS_RUN and the fleet-ops numbers
are untouched. The product compute path fetches runs first, merges second,
and the newest red run's jobs third (only while red — the failing-step
label for the repair packet, fleet-ops#5785).
Runs use RUNS_TTL = 120s (shorter than the 5-min tick, so a NEW stall is
visible on the very next tick) / RUNS_STALE = 3600s; merges reuse the
fleet-ops GH_TTL/GH_STALE envelope. PRODUCT_GH_TIMEOUT = 15 caps one product
call, so the worst added wall time is 30s — inside systemd's default 90s
TimeoutStartSec, which systemd/fleet-metrics-export.service does not set.

Environment seams (tests):
  FLEET_DQ_NOW              ISO/epoch override for deterministic tests
  FLEET_DQ_MERGED           path to a JSON list of {mergedAt} (skip gh)
  FLEET_DQ_REVERTS          path to a JSON list; length = auto-revert events (skip gh)
  FLEET_DQ_JOURNAL          path to a fleet-deploy-check journal fixture
  FLEET_DQ_ACTIONS_LOG      path to an alert-repair actions.log fixture
  FLEET_DQ_CRITICAL_ALERTS  comma-separated critical alert names (tests)
  FLEET_DQ_CACHE_DIR        cache dir (default: $AGENT_STATE/fleet-metrics)
  FLEET_DQ_GH               gh binary (default: gh)
  FLEET_DQ_REPOS_JSON       path to an intake-repos.json-shaped
                            {"repos": [{"name": ..., "product": true}]}
                            fixture; highest-priority product-repo source,
                            a missing file falls through to the in-repo list
  FLEET_DQ_DEPLOY_WORKFLOWS path to a JSON {"<repo>": "<workflow name>"}
                            object merged over PRODUCT_DEPLOY_WORKFLOWS
  FLEET_DQ_DEPLOY_RUNS      path to a JSON {"<repo>": [run, ...]} object of
                            production-deploy workflow runs, newest first
                            (skips gh for that repo)
  FLEET_DQ_DEPLOY_JOBS      path to a JSON {"<repo>": {"<run databaseId>":
                            {"jobs": [...]}}} object for the newest red
                            run's failing-step lookup (skips gh)
  FLEET_DQ_PRODUCT_MERGED   path to a JSON {"<repo>": [{"mergedAt": ...}]}
                            object (skips gh for that repo's merges)
  AGENT_STATE               default: ~/workspaces/agent-state
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HOME = os.environ.get("HOME", "/home/nish")
REPO = "fleet-ops"
WINDOW_DAYS = 30
# The 1h attribution window for "deployment caused a critical alert".
DEPLOY_ALERT_WINDOW_S = 3600
# Max gap (s) between consecutive blocked lines that still belongs to the
# same blocked episode. fleet-deploy-check runs every 2 min, so consecutive
# blocked cycles are ~120s apart; 600s absorbs a delayed tick.
BLOCK_RUN_GAP_S = 600
GH_TIMEOUT = 45
# One gh subprocess per scrape (see _cached); mirrors the exporter's own
# _GH_FETCHED_THIS_RUN discipline so the 5-min oneshot stays < 60s.
_GH_FETCHED_THIS_RUN = False
# A deploy cycle's own LOUD lines arrive within seconds of the invoke line
# (journal shows the deploy bin logging LOUD [DEPLOY-BLOCKED] ~1s after
# "origin/main moved"). Bounded cycle window so a GREEN cycle followed 2
# minutes later by a BLOCKED cycle is not mis-classified as blocked.
CYCLE_WINDOW_S = 30
# Same TTL/stale envelope as the exporter (fleet-ops#523): fresh <=30min
# skips gh; a failed call serves cache up to 2h; beyond that the family
# goes NaN (never a frozen value).
GH_TTL = 1800
GH_STALE = 7200
# The revert count is slow-moving (auto-revert events), so its own cache is
# longer-lived: 1h fresh, 4h stale. It is the SECOND fetch slot and should
# usually be served from cache, keeping one gh call per scrape.
REVERT_TTL = 3600
REVERT_STALE = 4 * 3600
JOURNAL_CACHE_TTL = 60

TS_RE = re.compile(r"\[?(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\]?")
# The journal's own UTC timestamp, e.g. "[2026-09-02T17:48:07Z]".
APP_TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\]")
MOVED_RE = re.compile(r"origin/main moved \S+ -> \S+")
BLOCKED_RE = re.compile(r"DEPLOY-BLOCKED|DEPLOY-CHECK-FAILED")
# A successful idle tick or a completed deploy ends a blocked episode even
# when origin/main did not move again (fleet-ops#3136: restoring the clone
# to main produced "nothing to do", but blocked_duration kept aging
# because the newest parsed event was still the last DEPLOY-BLOCKED).
CLEAR_RE = re.compile(r"nothing to do|deploy completed rc=0")
DISPATCH_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\]\s+DISPATCH alertname=([A-Za-z0-9_]+)")
RESOLVED_RE = re.compile(
    r"\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\].*?\bRESOLVED\b.*?\balertname=([A-Za-z0-9_]+)"
)
# Fallback when RESOLVED lines omit alertname= but name the alert inline.
RESOLVED_INLINE_RE = re.compile(
    r"\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\].*?\bRESOLVED\b"
)
REVERT_TITLE_Q = '"auto-restore green main" in:title'

# Critical alerts the deploy-quality TTD/success SLOs blame on a deployment.
# Curated to alerts that CAN meet the 10-min TTD budget: Prometheus for:
# duration must be < 600s. Verified live against /api/v1/rules 2026-09-02:
#   FleetHeartbeatStale/MetricsExportStale/FastBurns for=120
#   FleetMetricsExportMissing for=300
# Excluded on purpose (cannot meet budget by construction):
#   FleetMainRed for=1800,
#   FleetUndersatGuardAbsent for=10800,
#   FleetSloSeatAvailSlowBurn for=1800 AND severity=warning (not critical).
# Also excluded: host-health, synthetic, absence/self-maintenance alerts —
# a coincidental host fault must not mark a deployment as bad.
CRITICAL_DEPLOY_ALERTS = frozenset({
    "FleetSloSeatAvailFastBurn",
    "FleetSloMainGreenFastBurn",
    "FleetHeartbeatStale",
    "FleetMetricsExportStale",
    "FleetMetricsExportMissing",
})
# p95 over fewer than this many episode samples is not a p95 — emit NaN
# so DeploymentTimeToDetectHigh stays silent until the ledger has depth.
TTD_MIN_SAMPLES = 5

# --- product repos (fleet-ops#5140) ----------------------------------------
# Deliberately shorter than the 5-min export tick: a 30-min cache would make
# a new stall invisible for up to 30 minutes, and the issue's floor is
# visibility within 15. RUNS_STALE keeps a gh outage from NaN-ing the family
# for an hour.
RUNS_TTL = 120
RUNS_STALE = 3600
# Hard cap on product-repo gh calls per scrape. Kept separate from
# _GH_FETCHED_THIS_RUN so this family can neither spend nor block the
# fleet-ops single-call budget. Two covers the one declared product repo
# (runs + merges + the newest red run's jobs for the failing-step series,
# fleet-ops#5785). A SECOND product repo goes up=0 with a stderr line until
# this cap is raised on purpose — that is the tripwire, not a bug, same class
# as a repo missing from PRODUCT_DEPLOY_WORKFLOWS.
MAX_PRODUCT_FETCHES_PER_SCRAPE = 3
PRODUCT_GH_TIMEOUT = 15
_PRODUCT_FETCHES_THIS_RUN = 0
# Only conclusion == "success" is green. cancelled / failure / timed_out /
# startup_failure / skipped / neutral and "" (in-flight) are all non-green:
# an in-flight deploy is not a shipped deploy, so fail closed. Live 0509
# shape 2026-09-10: pending / cancelled / in_progress / failure.
GREEN_CONCLUSION = "success"
# Repos whose production gate is a GitHub Actions workflow. The value is the
# workflow name `gh run list --workflow` expects (the workflow's `name:`).
# A product repo absent from this table cannot be measured and is reported as
# up=0 rather than silently skipped (fleet-ops#5140 accept 1). env seam:
# FLEET_DQ_DEPLOY_WORKFLOWS = path to a JSON object merged over this table.
PRODUCT_DEPLOY_WORKFLOWS = {"0509": "Deploy production"}
# Product repo names become cache filenames (deploy-quality-runs-<repo>.json);
# anything outside this set is dropped and reported, never written to disk.
REPO_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")

METRIC_DEFS = (
    # (name, help). Ordered: within each metric the fleet-ops row is emitted
    # before any product row, and # HELP/# TYPE appear exactly once per name.
    ("fleet_deployment_latency_seconds",
     "p95 merge-to-live latency per measured repo: fleet-ops = mergedAt -> first green "
     "fleet-deploy-check cycle; a product repo = mergedAt -> first green production-deploy "
     "run; trailing window. fleet-ops#2758, fleet-ops#5140."),
    ("fleet_deployment_rollback_rate",
     "auto-revert events / merged deployments for fleet-ops, trailing 30 days. fleet-ops only: "
     "auto-revert is fleet-ops machinery, so no series is emitted for a product repo "
     "(fleet-ops#5140)."),
    ("fleet_deployment_time_to_detect_seconds",
     "p95 time from fleet-ops deploy to first critical alert dispatch, trailing window. "
     "fleet-ops only: it reads fleet-ops' alert-repair actions.log, so no series is emitted "
     "for a product repo (fleet-ops#5140)."),
    ("fleet_deployment_success_rate",
     "fleet-ops deployments with zero critical alerts in the 1h after merge / total "
     "deployments, trailing window. fleet-ops only: it reads fleet-ops' alert-repair "
     "actions.log, so no series is emitted for a product repo (fleet-ops#5140)."),
    ("fleet_deploy_blocked_duration_seconds",
     "Age in seconds of the current non-green deploy episode per measured repo: fleet-ops = "
     "run of consecutive DEPLOY-BLOCKED fleet-deploy-check cycles; a GitHub-deployed product "
     "repo = age of the current run of consecutive non-green production-deploy runs (an "
     "in-flight run counts as non-green), 0 when the newest run is green, NaN when the repo "
     "could not be measured this scrape. fleet-ops#2725, fleet-ops#5140."),
    ("fleet_deployment_quality_up",
     "1 when the deploy-quality computation succeeded for this repo this scrape, 0 when it "
     "failed (that repo's gauges are NaN). fleet-ops#2758, fleet-ops#5140."),
    ("fleet_deployment_total",
     "total fleet-ops merged deployments in the trailing window (denominator). fleet-ops "
     "only: shared with the three metrics above, no series for a product repo "
     "(fleet-ops#5140)."),
    ("fleet_deployment_revert_total",
     "auto-revert events (revert: auto-restore green main PRs) in the trailing window "
     "(numerator). fleet-ops only: no series for a product repo (fleet-ops#5140)."),
    ("fleet_product_deploy_green",
     "1 when the newest run of this repo's production-deploy workflow concluded success, 0 "
     "when it did not, NaN when the repo could not be measured this scrape. Deploy greenness "
     "lives here; fleet_main_ci_green tracks only the workflow literally named \"CI\". "
     "fleet-ops#5140."),
    ("fleet_product_deploy_last_red_run_info",
     "1 on the newest non-green run of a product repo's production-deploy workflow, carrying "
     "that run's url so ProductDeployStalled can name it; absent when the newest run is green "
     "or the repo could not be measured this scrape. fleet-ops#5140."),
    ("fleet_product_deploy_last_red_step_info",
     "1 on the newest non-green run of a product repo's production-deploy workflow, carrying "
     "that run's failing job+step names so a repair packet can read the failure directly; "
     "absent when the newest run is green, the jobs fetch failed, or the repo could not be "
     "measured this scrape. fleet-ops#5785."),
    ("fleet_product_production_stale_hours",
     "Hours since this product repo's production-deploy workflow last completed GREEN "
     "(completion timestamp). When no green run exists in the fetched window the value is a "
     "lower bound anchored at the oldest fetched run's createdAt. NaN when the repo could not "
     "be measured this scrape. fleet-ops#5785 — the FleetProductionStale signal."),
    ("fleet_product_deploy_last_green_seconds",
     "Completion epoch of the newest green run of a product repo's production-deploy "
     "workflow; NaN when no green run exists in the fetched window or the repo could not be "
     "measured. fleet-ops#5785."),
    ("fleet_product_main_last_merge_seconds",
     "Epoch of the newest mergedAt on a product repo's default branch in the trailing window; "
     "0 when no merges were fetched, NaN when the merges fetch failed. Informational — the "
     "merge-vs-green comparison lives on fleet_product_undeployed_merges. fleet-ops#5785."),
    ("fleet_product_undeployed_merges",
     "1 when the product repo's newest default-branch merge is newer than the newest GREEN "
     "production-deploy completion — code is merged that production has never shipped — or "
     "when merges exist and no green run is in the fetched window at all; 0 otherwise; NaN "
     "when the merges fetch failed. fleet-ops#5785 — the second half of FleetProductionStale."),
)

# Payload keys per metric name. Keys must cover every METRIC_DEFS name that
# is not in _PRODUCT_ONLY_METRICS; the family tests pin each fleet-ops value.
_FLEET_VALUE_KEYS = {
    "fleet_deployment_latency_seconds": "latency_p95",
    "fleet_deployment_rollback_rate": "rollback_rate",
    "fleet_deployment_time_to_detect_seconds": "time_to_detect_p95",
    "fleet_deployment_success_rate": "success_rate",
    "fleet_deploy_blocked_duration_seconds": "blocked_duration",
    "fleet_deployment_quality_up": "up",
    "fleet_deployment_total": "total",
    "fleet_deployment_revert_total": "revert_total",
}
# Metrics a product repo emits. Deliberately absent from this map: rollback
# rate, time-to-detect, success rate, and the two totals — those read
# fleet-ops machinery (auto-revert PRs, actions.log), so absence is the
# honest answer for a product repo, not a NaN row.
_PRODUCT_VALUE_KEYS = {
    "fleet_deployment_latency_seconds": "latency_p95",
    "fleet_deploy_blocked_duration_seconds": "blocked_duration",
    "fleet_deployment_quality_up": "up",
    "fleet_product_deploy_green": "green",
    "fleet_product_production_stale_hours": "production_stale_hours",
    "fleet_product_deploy_last_green_seconds": "last_green_seconds",
    "fleet_product_main_last_merge_seconds": "main_last_merge_seconds",
    "fleet_product_undeployed_merges": "undeployed_merges",
}
# Product-only metrics: no fleet-ops series at all.
_PRODUCT_ONLY_METRICS = frozenset({
    "fleet_product_deploy_green",
    "fleet_product_deploy_last_red_run_info",
    "fleet_product_deploy_last_red_step_info",
    "fleet_product_production_stale_hours",
    "fleet_product_deploy_last_green_seconds",
    "fleet_product_main_last_merge_seconds",
    "fleet_product_undeployed_merges",
})


def _now(env):
    raw = (env or os.environ).get("FLEET_DQ_NOW") or ""
    if not raw:
        return time_now()
    try:
        return float(raw)
    except ValueError:
        pass
    dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def time_now():
    return datetime.now(timezone.utc).timestamp()


def _parse_iso_utc(s):
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except ValueError:
        return None


def _iso(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _cache_paths(env):
    cache_dir = Path(
        (env or os.environ).get("FLEET_DQ_CACHE_DIR")
        or f"{os.environ.get('AGENT_STATE', f'{HOME}/workspaces/agent-state')}/fleet-metrics"
    )
    return (
        cache_dir / "deploy-quality-merged.json",
        cache_dir / "deploy-quality-reverts.json",
        cache_dir / "deploy-quality-journal.json",
        cache_dir / "deploy-quality-actions.json",
    )


def _read_cache(path):
    try:
        c = json.loads(path.read_text())
        if not isinstance(c, dict):
            return None, None
        data, ts = c.get("data"), c.get("ts")
        if isinstance(ts, (int, float)):
            return data, time_now() - ts
    except (OSError, json.JSONDecodeError):
        pass
    return None, None


def _write_cache(path, data):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps({"ts": time_now(), "data": data}))
        os.replace(tmp, path)
    except OSError as exc:
        print(f"deploy-quality cache write {path}: {exc}", file=sys.stderr)


def _run(cmd, env, timeout=GH_TIMEOUT):
    """Run a command, return subprocess result or None on failure.

    A missing binary (bad FLEET_DQ_GH, no gh on PATH) is an OSError, not a
    crash: prom_lines() must never raise, and a FileNotFoundError escaping
    here would take the whole family down instead of degrading one repo
    (fleet-ops#5140). A timeout raises subprocess.TimeoutExpired — a
    SubprocessError, not an OSError; catching it here keeps a slow fetch on
    the ordinary stale-cache path instead of failing the whole repo
    (fleet-ops#5140 phase-1 review).
    """
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, **env})
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"deploy-quality: cannot run {cmd[0]}: {exc}", file=sys.stderr)
        return None
    if r.returncode != 0:
        print(f"deploy-quality gh rc={r.returncode}: {r.stderr.strip()[:300]}",
              file=sys.stderr)
        return None
    return r


def _gh_json(cmd, env, timeout=GH_TIMEOUT):
    r = _run(cmd, env, timeout=timeout)
    if r is None:
        return None
    try:
        return json.loads(r.stdout or "[]")
    except json.JSONDecodeError as exc:
        print(f"deploy-quality gh json: {exc}", file=sys.stderr)
        return None


def _cached(cache_path, ttl, stale, fetcher, env):
    """TTL/stale cache envelope mirroring the exporter's _cached_json.

    At most ONE gh subprocess per scrape: the first cache miss fetches and
    sets _GH_FETCHED_THIS_RUN; later misses within the same scrape serve
    the stale cache instead (up to `stale` seconds) so an idle 5-min tick
    never issues a second gh call. A None result propagates to the caller
    as an unavailable family.
    """
    global _GH_FETCHED_THIS_RUN
    data, age = _read_cache(cache_path)
    if age is not None and age <= ttl and data is not None:
        return data
    if _GH_FETCHED_THIS_RUN:
        if data is not None and age is not None and age <= stale:
            print(f"deploy-quality: second gh family served stale cache (age={int(age)}s)",
                  file=sys.stderr)
            return data
        return None
    fresh = fetcher()
    _GH_FETCHED_THIS_RUN = True
    if fresh is not None:
        _write_cache(cache_path, fresh)
        return fresh
    if data is not None and age is not None and age <= stale:
        print(f"deploy-quality gh failed, serving stale cache (age={int(age)}s)",
              file=sys.stderr)
        return data
    return None


def _merged_records(env):
    """Return list of {mergedAt} within the window, or None on failure."""
    seam = (env or os.environ).get("FLEET_DQ_MERGED")
    if seam:
        try:
            rows = json.loads(Path(seam).read_text())
        except (OSError, json.JSONDecodeError):
            return None
        out = []
        for row in rows:
            ep = _parse_iso_utc(row.get("mergedAt") or "")
            if ep is not None:
                out.append(ep)
        return out
    now = _now(env)
    cutoff_iso = _iso(now - WINDOW_DAYS * 86400)[:10]
    gh = (env or os.environ).get("FLEET_DQ_GH") or "gh"
    # GitHub search date qualifiers are day-granular; a time-precision upper
    # bound (merged:<=<iso-with-time>) is silently dropped / ignored, so the
    # query bounds only the lower edge and python filters m <= now. The upper
    # edge cannot leak out-of-window PRs into the rollback denominator.
    query = f"merged:>={cutoff_iso} base:main"
    merge_cache, _, _, _ = _cache_paths(env)

    def fetch():
        return _gh_json([
            gh, "pr", "list", "--repo", f"Nishfleet/{REPO}",
            "--state", "merged", "--limit", "5000",
            "--search", query, "--json", "number,mergedAt",
        ], env)

    rows = _cached(merge_cache, GH_TTL, GH_STALE, fetch, env)
    if rows is None:
        return None
    out = []
    for row in rows:
        ep = _parse_iso_utc(row.get("mergedAt") or "")
        if ep is not None:
            out.append(ep)
    return out


def _revert_count(env):
    """Return auto-revert event count in the window, or None on failure."""
    seam = (env or os.environ).get("FLEET_DQ_REVERTS")
    if seam:
        try:
            return len(json.loads(Path(seam).read_text()))
        except (OSError, json.JSONDecodeError):
            return None
    now = _now(env)
    cutoff_iso = _iso(now - WINDOW_DAYS * 86400)[:10]
    gh = (env or os.environ).get("FLEET_DQ_GH") or "gh"
    _, rev_cache, _, _ = _cache_paths(env)

    def fetch():
        rows = _gh_json([
            gh, "pr", "list", "--repo", f"Nishfleet/{REPO}",
            "--state", "all", "--limit", "100",
            "--search", f"created:>={cutoff_iso} {REVERT_TITLE_Q}",
            "--json", "number",
        ], env)
        return None if rows is None else len(rows)

    return _cached(rev_cache, REVERT_TTL, REVERT_STALE, fetch, env)


def _read_journal(env, now):
    """Return sorted list of (ts, kind) for fleet-deploy-check events, or
    None when the journal is unavailable (degraded — never a fake empty)."""
    seam = (env or os.environ).get("FLEET_DQ_JOURNAL")
    cache_path = _cache_paths(env)[2]
    cutoff = now - WINDOW_DAYS * 86400
    if seam:
        try:
            return _parse_journal_lines(Path(seam).read_text())
        except OSError:
            return None
    data, age = _read_cache(cache_path)
    if age is not None and age <= JOURNAL_CACHE_TTL and data is not None:
        return _parse_journal_lines(data)
    cutoff_iso = _iso(cutoff)
    xdg = (env or os.environ).get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    r = _run([
        "journalctl", "--user", "-u", "fleet-deploy-check.service",
        "--since", cutoff_iso, "--no-pager",
    ], {"XDG_RUNTIME_DIR": xdg}, timeout=30)
    if r is not None:
        _write_cache(cache_path, r.stdout)
        return _parse_journal_lines(r.stdout)
    data, age = _read_cache(cache_path)
    if data is not None and age is not None and age <= GH_STALE:
        print(f"deploy-quality journal failed, serving stale cache (age={int(age)}s)",
              file=sys.stderr)
        return _parse_journal_lines(data)
    return None


def _parse_journal_lines(text):
    """Parse journal text into a sorted list of (ts, kind) events."""
    events = []
    for line in text.splitlines():
        m = APP_TS_RE.search(line)
        if not m:
            continue
        ts = _parse_iso_utc(m.group(1))
        if ts is None:
            continue
        if BLOCKED_RE.search(line):
            events.append((ts, "blocked"))
        elif MOVED_RE.search(line):
            events.append((ts, "moved"))
        elif CLEAR_RE.search(line):
            events.append((ts, "clear"))
    events.sort(key=lambda e: e[0])
    return events


def _read_actions_text(env):
    """Return the raw actions.log text, or None when unavailable."""
    seam = (env or os.environ).get("FLEET_DQ_ACTIONS_LOG")
    if seam:
        try:
            return Path(seam).read_text()
        except OSError:
            return None
    base = os.environ.get("AGENT_STATE", f"{HOME}/workspaces/agent-state")
    if env:
        base = env.get("AGENT_STATE", base)
    try:
        return (Path(base) / "alert-repair" / "actions.log").read_text()
    except OSError:
        return None


def _read_alert_events(env):
    """Return sorted list of (ts, alertname) DISPATCHes, or None when the
    actions.log ledger is unavailable (degraded — a missing ledger must not
    read as "zero alerts")."""
    cache_path = _cache_paths(env)[3]
    # Live source: AGENT_STATE/alert-repair/actions.log, cached 60s.
    # Seam path always re-reads (tests mutate fixtures between calls).
    if not (env or os.environ).get("FLEET_DQ_ACTIONS_LOG"):
        data, age = _read_cache(cache_path)
        if age is not None and age <= JOURNAL_CACHE_TTL and data is not None:
            return [(e[0], e[1]) for e in data]
    text = _read_actions_text(env)
    if text is None:
        return None
    parsed = _parse_dispatches(text)
    if not (env or os.environ).get("FLEET_DQ_ACTIONS_LOG"):
        _write_cache(cache_path, parsed)
    return parsed


def _parse_dispatches(text):
    """Return sorted list of (ts, alertname) DISPATCH lines.

    Kept for the actions-log cache shape and for success-rate fan-in
    (any in-window DISPATCH of a curated name still marks a deploy as
    non-success). TTD uses _episode_starts on top of this.
    """
    events = []
    for m in DISPATCH_RE.finditer(text):
        ts = _parse_iso_utc(m.group(1))
        if ts is not None:
            events.append((ts, m.group(2)))
    events.sort(key=lambda e: e[0])
    return events


def _episode_starts(text, crit):
    """Return sorted (ts, alertname) of NEW critical alert episodes.

    An episode starts on the first DISPATCH of an alertname while that
    name is not open; RESOLVED closes it. Redispatches of an already-open
    alert (Alertmanager repeat / alert-repair hop) do not start a
    new episode and must not blame later merges.
    """
    open_eps = set()
    starts = []
    # Walk the ledger in file order so DISPATCH/RESOLVED interleave correctly.
    for line in text.splitlines():
        m = DISPATCH_RE.search(line)
        if m:
            name = m.group(2)
            if name in crit and name not in open_eps:
                ts = _parse_iso_utc(m.group(1))
                if ts is not None:
                    open_eps.add(name)
                    starts.append((ts, name))
            continue
        if "RESOLVED" not in line:
            continue
        # Prefer alertname= token; fall back to inline name match against
        # currently-open critical episodes (RESOLVED lines vary in shape).
        rm = RESOLVED_RE.search(line)
        if rm:
            name = rm.group(2)
            if name in open_eps:
                open_eps.discard(name)
            continue
        for name in list(open_eps):
            if name in line:
                open_eps.discard(name)
    starts.sort(key=lambda e: e[0])
    return starts


def _blocked_timestamps(events):
    """Return sorted epochs of DEPLOY-BLOCKED / DEPLOY-CHECK-FAILED lines."""
    return [ts for ts, kind in events if kind == "blocked"]


def _span_contains_blocked(blocked_ts, start, end):
    """True when a blocked event sits in [start, end] inclusive.

    Those merge→green samples are the DeployBlockedStuck class, not
    deploy latency. Counting them after the episode ends is the hangover
    that kept DeploymentLatencyHigh firing for 24h+ after the clone was
    unblocked (fleet-ops#3136 live: p95 97594s of 460 samples, 411 of
    them blocked-span; the 50 clean samples p95'd at 327s).
    blocked_ts is sorted; scan stops once ts > end.
    """
    for ts in blocked_ts:
        if ts > end:
            return False
        if start <= ts <= end:
            return True
    return False


def _green_finishes(events):
    """Return sorted green-deploy finish epochs.

    A moved line is green when no blocked line falls within
    CYCLE_WINDOW_S of it (the deploy bin logs LOUD [DEPLOY-BLOCKED] ~1s
    after the invoke). The finish time is the moved line's own timestamp
    — the VPS deploy is ~1s once the gate allows it.
    """
    greens = []
    for i, (ts, kind) in enumerate(events):
        if kind != "moved":
            continue
        bl = False
        for j, (t2, k2) in enumerate(events):
            if k2 != "blocked":
                continue
            if 0 <= t2 - ts <= CYCLE_WINDOW_S:
                bl = True
                break
        if not bl:
            greens.append(ts)
    return greens


def _blocked_episode(events, now):
    """Return (duration, run_start) of the CURRENT blocked episode.

    0 duration when the newest event is not a blocked cycle — a green
    deploy, a successful idle tick ("nothing to do" / deploy completed),
    or main has not moved. A run is the contiguous tail of blocked events
    with inter-line gaps <= BLOCK_RUN_GAP_S.
    """
    if not events:
        return 0.0, None
    newest_ts, newest_kind = events[-1]
    if newest_kind != "blocked":
        return 0.0, None
    run_start = newest_ts
    for i in range(len(events) - 2, -1, -1):
        ts, kind = events[i]
        if kind != "blocked":
            # A non-blocked cycle (green deploy or nothing-to-do) ends the
            # episode only if it is not part of the same blocked cycle's
            # tail — blocked lines come in ~2min-spaced bursts, so a gap
            # > BLOCK_RUN_GAP_S after a non-blocked event also ends it.
            if events[i + 1][0] - ts > BLOCK_RUN_GAP_S:
                break
            represent_continuous = False
            # A moved line is part of a blocked CYCLE (same burst) — keep
            # walking; other kinds (unrelated tail) end the run.
            if kind == "moved" and events[i + 1][0] - ts <= CYCLE_WINDOW_S:
                represent_continuous = True
            if not represent_continuous:
                break
            continue
        if events[i + 1][0] - ts > BLOCK_RUN_GAP_S:
            break
        run_start = ts
    duration = max(0.0, now - run_start)
    return duration, run_start


def _p95(values):
    if not values:
        return None
    ordered = sorted(values)
    idx = max(0, min(len(ordered) - 1, int(round(0.95 * (len(ordered) - 1)))))
    return ordered[idx]


def compute(env=None):
    """Compute the deployment-quality metric payload.

    Returns a dict with the five SLO gauges plus totals and up.
    Raises (ValueError) when a required source is unavailable so the
    exporter can emit NaN; local-only degradation (journal/actions gone)
    degrades individual metrics to None.
    """
    env = env or {}
    now = _now(env)
    merged = _merged_records(env)
    if merged is None:
        raise ValueError("merged PR fetch unavailable (no cache within 2h)")
    reverts = _revert_count(env)
    if reverts is None:
        raise ValueError("revert count fetch unavailable (no cache within 2h)")
    events = _read_journal(env, now)
    alerts = _read_alert_events(env)
    crit = set((env or os.environ).get("FLEET_DQ_CRITICAL_ALERTS", "").split(",")) if (
        (env or os.environ).get("FLEET_DQ_CRITICAL_ALERTS")) else CRITICAL_DEPLOY_ALERTS
    # Drop empty tokens from a trailing/leading comma in the seam.
    crit = {c for c in crit if c}
    crit_alerts = [(ts, name) for ts, name in (alerts or []) if name in crit]

    # Episode starts (1:1 TTD). Prefer a fresh parse of the actions text so
    # RESOLVED lines close episodes; the DISPATCH-only cache is insufficient.
    actions_text = _read_actions_text(env)
    if actions_text is not None:
        episode_starts = _episode_starts(actions_text, crit)
    elif alerts is not None:
        # Degraded: no raw text (should not happen when alerts parsed) —
        # treat every DISPATCH as an episode start (old behaviour).
        episode_starts = list(crit_alerts)
    else:
        episode_starts = None

    window_start = now - WINDOW_DAYS * 86400
    merged = [m for m in merged if m >= window_start and m <= now]
    total = len(merged)
    # Data-depth limits: journal and actions.log only retain ~6-7 days on
    # this box (verified 2026-09-02: fleet-deploy-check unit journal starts
    # 2026-08-27; actions.log 2026-08-27). Latency / time-to-detect /
    # success-rate are computed over the deployments whose deploy and alert
    # windows fall inside the recorded data; rollback rate and totals use
    # the full 30-day gh window. Each family documents its own window.
    # Unavailable local sources degrade to None (NaN) — never a fake 0,
    # because a 0 blocked-duration would silently hide a real block.
    journal_start = events[0][0] if events else window_start
    actions_start = crit_alerts[0][0] if crit_alerts else (
        alerts[0][0] if alerts else window_start)

    # (a) deployment latency: mergedAt -> next green cycle finish.
    # Skip samples whose wait contains a DEPLOY-BLOCKED event — that is
    # DeployBlockedStuck, and leaving it in the p95 after the episode
    # ends is the #3136 hangover (repair loop terminal=green, detector
    # still red for 24h+).
    greens = _green_finishes(events) if events is not None else []
    blocked_ts = _blocked_timestamps(events) if events is not None else []
    latency = []
    for m in merged:
        # A merge that happened before the journal began (m < journal_start)
        # has an unmeasured wait: its DEPLOY-BLOCKED / DEPLOY-CHECK-FAILED
        # context (if any) is lost to the journal rotation boundary, so the
        # sample is either unmeasurable or the block-context is unknowable.
        # Counting it as deploy latency after a blocked episode is the
        # DeployBlockedStuck hangover this function exists to prevent
        # (fleet-ops#3136): e.g. 2026-09-08 live, 8 pre-journal Sep-04 merges
        # leaked 1860-4436s waits into p95 and kept DeploymentLatencyHigh red
        # for ~3 weeks. The previous generous 24h margin (journal_start -
        # 86400) let those leak. Exclude outright — not measurable.
        if m < journal_start:
            continue  # deploy record predates the journal — not measurable
        for g in greens:
            if g >= m:
                if _span_contains_blocked(blocked_ts, m, g):
                    break
                latency.append(g - m)
                break
    latency_p95 = _p95(latency) if events is not None else None

    # (c) time-to-detect: 1:1 nearest-prior-merge -> episode start.
    # Fan-out (every merge in the 1h before a redispatch) was the 2026-09-02
    # false-fire: p95 pinned near 3600s because redispatches of FleetMainRed
    # (for:30m) blamed ~8 prior merges each. One sample per new episode.
    ttd = []
    if episode_starts is not None:
        for ts, _name in episode_starts:
            prior = [m for m in merged if m <= ts]
            if not prior:
                continue
            delta = ts - prior[-1]
            if delta <= DEPLOY_ALERT_WINDOW_S:
                ttd.append(delta)
    min_samples = TTD_MIN_SAMPLES
    raw_min = (env or os.environ).get("FLEET_DQ_TTD_MIN_SAMPLES")
    if raw_min:
        try:
            min_samples = max(1, int(raw_min))
        except ValueError:
            pass
    ttd_p95 = _p95(ttd) if len(ttd) >= min_samples else None

    # (d) success rate: still fan-in over merges (a deploy with ANY curated
    # critical DISPATCH in its 1h window is a non-success). Unchanged shape.
    success_n = 0
    ttd_denom = 0
    if alerts is not None:
        for m in merged:
            if m < actions_start - DEPLOY_ALERT_WINDOW_S:
                continue  # alert ledger predates this deploy — not attributable
            ttd_denom += 1
            window_alerts = [
                ts for ts, _ in crit_alerts
                if m <= ts <= m + DEPLOY_ALERT_WINDOW_S
            ]
            if window_alerts:
                pass  # non-success; TTD already counted via episode starts
            else:
                success_n += 1
    success_rate = (success_n / ttd_denom) if ttd_denom else None

    rollback_rate = (reverts / total) if total else None

    if events is not None:
        blocked_duration, run_start = _blocked_episode(events, now)
    else:
        blocked_duration, run_start = None, None

    return {
        "now": now,
        "repo": REPO,
        "total": total,
        "revert_total": reverts,
        "rollback_rate": rollback_rate,
        "latency_p95": latency_p95,
        "latency_samples": len(latency),
        "time_to_detect_p95": ttd_p95,
        "ttd_samples": len(ttd),
        "success_rate": success_rate,
        "success_denom": ttd_denom,
        "blocked_duration": blocked_duration,
        "blocked_run_start": run_start,
        "up": 1,
    }


# --- product repos (fleet-ops#5140) ----------------------------------------


_FLEET_FAILED_KEYS = (
    "latency_p95", "rollback_rate", "time_to_detect_p95", "success_rate",
    "blocked_duration", "total", "revert_total",
)


def _failed_payload():
    """All-NaN fleet-ops payload with up=0 (the family's loud failure)."""
    payload = {k: None for k in _FLEET_FAILED_KEYS}
    payload["up"] = 0
    return payload


def _failed_product(repo, workflow):
    """All-NaN payload with up=0 for ONE product repo."""
    return {
        "repo": repo,
        "workflow": workflow,
        "up": 0,
        "latency_p95": None,
        "latency_samples": 0,
        "blocked_duration": None,
        "blocked_run_start": None,
        "blocked_lower_bound": False,
        "green": None,
        "last_red_url": None,
        "red_job": None,
        "red_step": None,
        "production_stale_hours": None,
        "last_green_seconds": None,
        "main_last_merge_seconds": None,
        "undeployed_merges": None,
    }


def _first_existing(paths):
    """First path in `paths` that is an existing file, else None.

    Same helper as lib/fleet-product-slo.py's _first_existing: one candidate
    list resolves intake-repos.json in-repo (tests), in the live tooling
    clones, and from an env seam, without inventing a new mechanism.
    """
    for p in paths:
        if not p:
            continue
        path = Path(p)
        try:
            if path.is_file():
                return path
        except OSError:
            continue
    return None


def _intake_candidates(env):
    """intake-repos.json candidates, highest priority first.

    The env seam is first so a test can pin the product set; a seam pointing
    at a missing file falls through to the in-repo copy, exactly as
    lib/fleet-product-slo.py behaves.
    """
    e = env or os.environ
    return [
        e.get("FLEET_DQ_REPOS_JSON") or "",
        str(Path(__file__).resolve().parents[1] / "config" / "intake-repos.json"),
        f"{HOME}/workspaces/tooling/fleet-ops-deploy-clone/config/intake-repos.json",
        f"{HOME}/workspaces/tooling/fleet-ops/config/intake-repos.json",
        f"{HOME}/.local/share/fleet-ops/config/intake-repos.json",
    ]


def product_repos(env=None):
    """Sorted names of intake repos[] entries with product: true.

    fleet-ops itself is excluded (it is measured by compute(), not by the
    product path). Names are sanitised against REPO_NAME_RE because they
    become cache filenames. A missing/unparseable file returns [] plus one
    stderr line — fleet-ops only, never a guess and never "all repos".
    Never raises.
    """
    path = _first_existing(_intake_candidates(env or os.environ))
    if path is None:
        print("deploy-quality: intake-repos.json not found (fleet-ops only this scrape)",
              file=sys.stderr)
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        print(f"deploy-quality: intake-repos.json unreadable: {exc} (fleet-ops only this scrape)",
              file=sys.stderr)
        return []
    rows = data.get("repos") if isinstance(data, dict) else None
    names = set()
    for row in rows or []:
        # `product` must be literally true: absent/false means not-product
        # (fail closed, the same rule seatlib.sh repo_is_product reads).
        if not isinstance(row, dict) or row.get("product") is not True:
            continue
        name = str(row.get("name") or "").strip()
        if not name or name == REPO:
            continue
        if not REPO_NAME_RE.match(name):
            print(f"deploy-quality: intake repo name {name!r} is not a safe cache "
                  "filename — skipped", file=sys.stderr)
            continue
        names.add(name)
    return sorted(names)


def product_workflows(env=None):
    """repo -> production-deploy workflow name (declared table + env seam)."""
    table = dict(PRODUCT_DEPLOY_WORKFLOWS)
    seam = (env or os.environ).get("FLEET_DQ_DEPLOY_WORKFLOWS")
    if not seam:
        return table
    try:
        override = json.loads(Path(seam).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        print(f"deploy-quality: deploy-workflow override unreadable: {exc}", file=sys.stderr)
        return table
    if not isinstance(override, dict):
        print("deploy-quality: deploy-workflow override is not a JSON object — ignored",
              file=sys.stderr)
        return table
    for repo, workflow in override.items():
        table[str(repo)] = str(workflow)
    return table


def _product_cache_paths(env, repo):
    """(runs_cache, merged_cache) for one product repo.

    repo is sanitised by product_repos() before it gets here, so the
    filename cannot escape the cache directory.
    """
    cache_dir = _cache_paths(env)[0].parent
    return (
        cache_dir / f"deploy-quality-runs-{repo}.json",
        cache_dir / f"deploy-quality-merged-{repo}.json",
    )


def _cached_product(cache_path, ttl, stale, fetcher, env):
    """TTL/stale envelope for the CAPPED product-repo gh budget.

    Same body as _cached(), but it consults _PRODUCT_FETCHES_THIS_RUN against
    MAX_PRODUCT_FETCHES_PER_SCRAPE instead of the exporter-wide
    _GH_FETCHED_THIS_RUN boolean, so the product family can neither spend nor
    block the fleet-ops single-gh-call budget. The counter increments whether
    the fetch succeeds or fails, matching the legacy flag's intent: once the
    cap is reached a later miss serves the stale cache (up to `stale`) or
    returns None — never a third gh call.
    """
    global _PRODUCT_FETCHES_THIS_RUN
    data, age = _read_cache(cache_path)
    if age is not None and age <= ttl and data is not None:
        return data
    if _PRODUCT_FETCHES_THIS_RUN >= MAX_PRODUCT_FETCHES_PER_SCRAPE:
        if data is not None and age is not None and age <= stale:
            print(f"deploy-quality: product gh budget spent "
                  f"({MAX_PRODUCT_FETCHES_PER_SCRAPE}/scrape), serving stale cache "
                  f"(age={int(age)}s)", file=sys.stderr)
            return data
        print(f"deploy-quality: product gh budget spent "
              f"({MAX_PRODUCT_FETCHES_PER_SCRAPE}/scrape), no cache to serve",
              file=sys.stderr)
        return None
    fresh = fetcher()
    _PRODUCT_FETCHES_THIS_RUN += 1
    if fresh is not None:
        _write_cache(cache_path, fresh)
        return fresh
    if data is not None and age is not None and age <= stale:
        print(f"deploy-quality product gh failed, serving stale cache (age={int(age)}s)",
              file=sys.stderr)
        return data
    return None


def _sort_runs(rows):
    """Newest-first production-deploy runs, non-object rows dropped.

    gh returns newest-first and the seam documents it; sorting here makes the
    contract explicit instead of trusting the source. The sort is stable, so
    runs sharing a createdAt keep their input order.
    """
    runs = [r for r in rows if isinstance(r, dict)]
    runs.sort(
        key=lambda r: (
            _parse_iso_utc(r.get("createdAt") or "")
            or _parse_iso_utc(r.get("updatedAt") or "")
            or 0.0
        ),
        reverse=True,
    )
    return runs


def _product_runs(repo, workflow, env):
    """Newest-first production-deploy runs for one repo, or None.

    Seam FLEET_DQ_DEPLOY_RUNS = path to a JSON object {repo: [run, ...]}; a
    missing key means "not measurable" (None), not "no runs". The live path
    caches to deploy-quality-runs-<repo>.json with RUNS_TTL/RUNS_STALE.

    An EMPTY run list is unmeasurable too, deliberately: `gh run list
    --workflow <wrong name>` returns [] rather than an error, and reporting
    that as "not green, blocked 0s" would hide the mistake. NaN gauges +
    up=0 + a stderr line is the tripwire.
    """
    seam = (env or os.environ).get("FLEET_DQ_DEPLOY_RUNS")
    if seam:
        try:
            blob = json.loads(Path(seam).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            print(f"deploy-quality: FLEET_DQ_DEPLOY_RUNS unreadable: {exc}", file=sys.stderr)
            return None
        rows = blob.get(repo) if isinstance(blob, dict) else None
        if not isinstance(rows, list):
            print(f"deploy-quality: FLEET_DQ_DEPLOY_RUNS has no entry for {repo}",
                  file=sys.stderr)
            return None
        return _sort_runs(rows)
    gh = (env or os.environ).get("FLEET_DQ_GH") or "gh"
    runs_cache, _ = _product_cache_paths(env, repo)

    def fetch():
        return _gh_json([
            gh, "run", "list", "--repo", f"Nishfleet/{repo}",
            "--workflow", workflow, "--limit", "30",
            "--json", "databaseId,status,conclusion,createdAt,updatedAt,url,headSha",
        ], env, timeout=PRODUCT_GH_TIMEOUT)

    rows = _cached_product(runs_cache, RUNS_TTL, RUNS_STALE, fetch, env)
    if not isinstance(rows, list):
        return None
    return _sort_runs(rows)


def _merged_epochs(rows):
    """[{mergedAt}] rows -> sorted epochs (unparseable rows dropped)."""
    out = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        ep = _parse_iso_utc(row.get("mergedAt") or "")
        if ep is not None:
            out.append(ep)
    return out


def _product_merged_epochs(repo, env):
    """Merged-at epochs in the trailing window for one repo, or None.

    Seam FLEET_DQ_PRODUCT_MERGED = path to a JSON object
    {repo: [{mergedAt}]}. The live path mirrors _merged_records (day-granular
    lower bound in the search, python filters the upper edge) but per repo
    and through the capped product budget.
    """
    seam = (env or os.environ).get("FLEET_DQ_PRODUCT_MERGED")
    if seam:
        try:
            blob = json.loads(Path(seam).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            print(f"deploy-quality: FLEET_DQ_PRODUCT_MERGED unreadable: {exc}", file=sys.stderr)
            return None
        rows = blob.get(repo) if isinstance(blob, dict) else None
        if not isinstance(rows, list):
            print(f"deploy-quality: FLEET_DQ_PRODUCT_MERGED has no entry for {repo}",
                  file=sys.stderr)
            return None
        return _merged_epochs(rows)
    now = _now(env)
    cutoff_iso = _iso(now - WINDOW_DAYS * 86400)[:10]
    gh = (env or os.environ).get("FLEET_DQ_GH") or "gh"
    _, merged_cache = _product_cache_paths(env, repo)

    def fetch():
        return _gh_json([
            gh, "pr", "list", "--repo", f"Nishfleet/{repo}",
            "--state", "merged", "--limit", "5000",
            "--search", f"merged:>={cutoff_iso} base:main",
            "--json", "number,mergedAt",
        ], env, timeout=PRODUCT_GH_TIMEOUT)

    rows = _cached_product(merged_cache, GH_TTL, GH_STALE, fetch, env)
    if not isinstance(rows, list):
        return None
    return _merged_epochs(rows)


def _run_completion(run):
    """(createdAt, completion) epochs for one run; completion falls back to
    createdAt when updatedAt is missing."""
    created = _parse_iso_utc(run.get("createdAt") or "")
    return created, (
        _parse_iso_utc(run.get("updatedAt") or "") or created
    )


def _product_greens(runs):
    """Sorted completion epochs of the runs that concluded success."""
    greens = []
    for run in runs:
        if run.get("conclusion") != GREEN_CONCLUSION:
            continue
        _created, completion = _run_completion(run)
        if completion is not None:
            greens.append(completion)
    greens.sort()
    return greens


def _product_red_step(repo, run, env):
    """(job_name, step_name) of the first failed step in a non-green run,
    or (None, None).

    fleet-ops#5785: FleetProductionStale's repair packet needs the failing
    step named, not just the run URL — a worker opening the newest red run
    blind re-does the diagnosis. Reads the run's jobs via `gh run view
    <databaseId> --json jobs`; the seam FLEET_DQ_DEPLOY_JOBS is a JSON object
    {repo: {"<databaseId>": {"jobs": [...]}}} so tests never touch gh.

    Counted in the MAX_PRODUCT_FETCHES_PER_SCRAPE budget via
    _cached_product (cache file deploy-quality-jobs-<repo>.json, RUNS_TTL
    freshness — a red run's job list is immutable once concluded, but the
    cache TTL keeps the code path identical to runs).
    """
    run_id = run.get("databaseId")
    if run_id is None:
        return None, None
    seam = (env or os.environ).get("FLEET_DQ_DEPLOY_JOBS")
    data = None
    if seam:
        try:
            blob = json.loads(Path(seam).read_text(encoding="utf-8"))
            per_repo = blob.get(repo) if isinstance(blob, dict) else None
            if isinstance(per_repo, dict):
                data = per_repo.get(str(run_id))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
            print(f"deploy-quality: FLEET_DQ_DEPLOY_JOBS unreadable: {exc}",
                  file=sys.stderr)
            return None, None
        if not isinstance(data, dict):
            print(f"deploy-quality: FLEET_DQ_DEPLOY_JOBS has no jobs for "
                  f"{repo} run {run_id}", file=sys.stderr)
            return None, None
    else:
        gh = (env or os.environ).get("FLEET_DQ_GH") or "gh"
        jobs_cache = _product_cache_paths(env, repo)[0].with_name(
            _product_cache_paths(env, repo)[0].name.replace("runs", "jobs"))

        def fetch():
            return _gh_json([
                gh, "run", "view", str(run_id), "--repo", f"Nishfleet/{repo}",
                "--json", "jobs",
            ], env, timeout=PRODUCT_GH_TIMEOUT)

        data = _cached_product(jobs_cache, RUNS_TTL, RUNS_STALE, fetch, env)
    if not isinstance(data, dict):
        return None, None
    for job in data.get("jobs") or []:
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue
            if step.get("conclusion") == "failure":
                job_name = str(job.get("name") or "").strip() or None
                step_name = str(step.get("name") or "").strip() or None
                if step_name:
                    return job_name, step_name
    return None, None


def _product_stale(runs, now):
    """(stale_seconds, last_green_completion, lower_bound) — how long since
    the production-deploy workflow last completed GREEN (fleet-ops#5785).

    Unlike _product_blocked (which asks "is the NEWEST run red"), this asks
    "how old is the newest green run" — a repo whose newest run is green but
    3 days old is stale production when main carries newer merges, and
    blocked_duration reads 0 for it. When no green run exists in the fetched
    window the value is a lower bound anchored at the oldest fetched run's
    createdAt (same discipline as _product_blocked's lower_bound flag).
    """
    greens = _product_greens(runs)
    if greens:
        last_green = greens[-1]
        return max(0.0, now - last_green), last_green, False
    start = None
    for run in runs:
        created, _completion = _run_completion(run)
        if created is not None:
            start = created
    if start is None:
        return None, None, False
    return max(0.0, now - start), None, True


def _product_blocked(runs, now):
    """(duration, run_start, lower_bound) of the trailing non-green streak.

    Only GREEN_CONCLUSION ("success") is green. Walk newest -> oldest while
    non-green; the streak's OLDEST createdAt is the episode start. 0.0 when
    the newest run is green. When the streak reaches the end of the fetched
    (limit-30) list the true start may be older, so the value is a LOWER
    BOUND: the caller logs one stderr line and never clamps to 0.
    """
    if not runs:
        return None, None, False
    if runs[0].get("conclusion") == GREEN_CONCLUSION:
        return 0.0, None, False
    start = None
    lower_bound = True
    for run in runs:
        if run.get("conclusion") == GREEN_CONCLUSION:
            lower_bound = False
            break
        created, _completion = _run_completion(run)
        if created is not None:
            start = created
    if start is None:
        return None, None, lower_bound
    return max(0.0, now - start), start, lower_bound


def compute_product(repo, workflow, env=None):
    """Measure one product repo's production-deploy SLOs (fleet-ops#5140).

    Returns a payload dict. Raises ValueError when the repo cannot be
    measured at all this scrape (no runs for the declared workflow) —
    prom_lines turns that into NaN gauges + fleet_deployment_quality_up 0 for
    THIS repo only, never a silent absence and never a sibling's failure.

    A merges outage is narrower on purpose: the latency gauge goes NaN with a
    stderr line while green/blocked still report, because the stall signal is
    the one that must survive a gh hiccup. This mirrors compute(), where a
    dead journal NaNs blocked_duration but leaves up=1.

    Latency: for each merge, the first green run whose completion (updatedAt
    else createdAt) >= the merge gives one sample. Merges older than the
    oldest fetched run are excluded as unmeasurable — the m < journal_start
    lesson from fleet-ops#3136.
    """
    env = env or {}
    now = _now(env)
    runs = _product_runs(repo, workflow, env)
    if not runs:
        raise ValueError(
            f"no runs for workflow {workflow!r} (misnamed workflow, empty run list, "
            "or the fetch failed)"
        )

    coverage_start = None
    for run in runs:
        created, _completion = _run_completion(run)
        if created is not None and (coverage_start is None or created < coverage_start):
            coverage_start = created

    latency_p95 = None
    latency_samples = 0
    merged = _product_merged_epochs(repo, env)
    if merged is None:
        print(f"deploy-quality: {repo} merged PRs unavailable — latency NaN this scrape",
              file=sys.stderr)
    else:
        samples = []
        greens = _product_greens(runs)
        for m in merged:
            if m > now:
                continue
            if coverage_start is None or m < coverage_start:
                continue  # predates the run list — its wait is unmeasurable
            for g in greens:
                if g >= m:
                    samples.append(g - m)
                    break
        latency_p95 = _p95(samples)
        latency_samples = len(samples)

    blocked_duration, run_start, lower_bound = _product_blocked(runs, now)
    if lower_bound:
        print(f"deploy-quality: {repo} non-green streak reaches the end of the fetched "
              "run list — blocked duration is a LOWER BOUND", file=sys.stderr)

    newest = runs[0]
    green = 1 if newest.get("conclusion") == GREEN_CONCLUSION else 0
    last_red_url = None
    red_job = None
    red_step = None
    if not green:
        last_red_url = str(newest.get("url") or "").strip() or None
        if last_red_url is None:
            print(f"deploy-quality: {repo} newest run is non-green but carries no url",
                  file=sys.stderr)
        red_job, red_step = _product_red_step(repo, newest, env)

    # fleet-ops#5785: staleness = age of the LAST GREEN completion, not the
    # newest run's redness. The newest-green-but-ancient case (blocked=0,
    # green=1, production 3 days old) is invisible to ProductDeployStalled;
    # FleetProductionStale compares this age against the newest main merge.
    stale_seconds, last_green, stale_lower_bound = _product_stale(runs, now)
    if stale_lower_bound:
        print(f"deploy-quality: {repo} no green run in the fetched list — "
              "production stale hours is a LOWER BOUND", file=sys.stderr)
    main_last_merge = None
    undeployed = None
    if merged is not None:
        main_last_merge = max(merged) if merged else 0.0
        # fleet-ops#5785: "main has newer merges" than the last green deploy.
        # No green run in the fetched window + any merge at all means the
        # merge is certainly undeployed (nothing has shipped in the window).
        if last_green is not None:
            undeployed = 1 if (merged and max(merged) > last_green) else 0
        else:
            undeployed = 1 if merged else 0

    return {
        "repo": repo,
        "workflow": workflow,
        "now": now,
        "up": 1,
        "latency_p95": latency_p95,
        "latency_samples": latency_samples,
        "blocked_duration": blocked_duration,
        "blocked_run_start": run_start,
        "blocked_lower_bound": lower_bound,
        "green": green,
        "last_red_url": last_red_url,
        "red_job": red_job,
        "red_step": red_step,
        "production_stale_hours": (
            None if stale_seconds is None else round(stale_seconds / 3600.0, 3)),
        "last_green_seconds": last_green,
        "main_last_merge_seconds": main_last_merge,
        "undeployed_merges": undeployed,
    }


def _fmt(v):
    if v is None:
        return "NaN"
    if isinstance(v, float):
        return repr(round(v, 3))
    return str(v)


def _prom_quote(value):
    """Escape a Prometheus label value (backslash, double quote, newline)."""
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _product_row(name, payload):
    """(labels, formatted value) for one product row, or None for no row.

    Only the blocked-duration series carries the workflow label. A url label
    is never placed on it: a URL that changes on every new run creates a new
    series, a new series restarts the rule's `for: 15m` timer, and the alert
    would never leave `pending` — that is the 28h-invisible stall this issue
    exists to kill. The URL rides on fleet_product_deploy_last_red_run_info
    instead.
    """
    repo = _prom_quote(payload.get("repo") or "")
    workflow = _prom_quote(payload.get("workflow") or "")
    key = _PRODUCT_VALUE_KEYS.get(name)
    if key is not None:
        if name in ("fleet_deploy_blocked_duration_seconds",
                    "fleet_product_production_stale_hours",
                    "fleet_product_deploy_last_green_seconds"):
            labels = f'repo="{repo}",workflow="{workflow}"'
        else:
            labels = f'repo="{repo}"'
        return labels, _fmt(payload.get(key))
    if name == "fleet_product_deploy_last_red_run_info":
        url = payload.get("last_red_url")
        if not url:
            return None
        return f'repo="{repo}",workflow="{workflow}",url="{_prom_quote(url)}"', "1"
    if name == "fleet_product_deploy_last_red_step_info":
        step = payload.get("red_step")
        if not step:
            return None
        job = _prom_quote(payload.get("red_job") or "")
        return (f'repo="{repo}",workflow="{workflow}",job="{job}",'
                f'step="{_prom_quote(step)}"', "1")
    return None


def _emit_family(fleet_payload, products):
    """Group the family by metric name: HELP/TYPE once, fleet-ops first.

    Iterating metric names (not payloads) is what keeps # HELP/# TYPE at
    exactly one per name across the whole output; emitting the fleet-ops row
    before the product rows is what keeps the existing
    `line.startswith(name + " ")` + break assertions reading the fleet-ops
    value.
    """
    out = [""]
    fleet_label = f'repo="{REPO}"'
    for name, help_text in METRIC_DEFS:
        rows = []
        if name not in _PRODUCT_ONLY_METRICS:
            rows.append((fleet_label, _fmt(fleet_payload.get(_FLEET_VALUE_KEYS.get(name)))))
        for payload in products:
            row = _product_row(name, payload)
            if row is not None:
                rows.append(row)
        if not rows:
            continue
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} gauge")
        for labels, value in rows:
            out.append(f"{name}{{{labels}}} {value}")
    return out


def prom_lines(env=None):
    """Return the Prometheus text lines for the deploy-quality family.

    Single entry point, and it NEVER raises (fleet-ops#5140): a fleet-ops
    failure degrades to all-NaN + up 0, and each product repo degrades on its
    own — one repo's exception must never NaN its siblings. The exporter's
    own fallback is now only for a module LOAD failure; a second HELP/TYPE
    block for the same metric name breaks the one-HELP-per-name discipline
    the textfile collector needs.
    """
    e = env if env is not None else os.environ
    try:
        fleet_payload = compute(env)
    except Exception as exc:  # noqa: BLE001 - prom_lines must never raise
        print(f"deploy-quality: fleet-ops computation failed: {exc}", file=sys.stderr)
        fleet_payload = _failed_payload()
    try:
        repos = product_repos(e)
        workflows = product_workflows(e)
    except Exception as exc:  # noqa: BLE001 - prom_lines must never raise
        print(f"deploy-quality: product repo resolution failed: {exc}", file=sys.stderr)
        repos, workflows = [], {}
    products = []
    for repo in repos:
        workflow = str(workflows.get(repo) or "")
        try:
            if not workflow:
                raise ValueError("no production-deploy workflow declared in "
                                 "PRODUCT_DEPLOY_WORKFLOWS")
            products.append(compute_product(repo, workflow, e))
        except Exception as exc:  # noqa: BLE001 - degrade this repo only
            print(f"deploy-quality: product repo {repo} unmeasurable: {exc} "
                  "(NaN gauges, up 0)", file=sys.stderr)
            products.append(_failed_product(repo, workflow))
    return _emit_family(fleet_payload, products)


def _fmt_json(p):
    p = dict(p)
    for k in ("now", "blocked_run_start"):
        if p.get(k) is not None and isinstance(p[k], float):
            p[k] = round(p[k], 3)
    return json.dumps(p, indent=2, sort_keys=True)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--json" in argv:
        print(_fmt_json(compute()))
        return 0
    if "--help" in argv or "-h" in argv:
        print("fleet-deploy-quality.py [--json|--prom]  (default --prom)")
        return 0
    for line in prom_lines():
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())