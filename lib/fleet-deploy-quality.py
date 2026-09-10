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
  (f) product deploy freshness = seconds since the newest SUCCESSFUL
      push-triggered "Deploy production" run on the default branch, per
      product repo (intake-repos.json minus self-maintenance). The family
      above answers "did OUR pipeline work"; this one answers "are merges
      reaching users" — product repos deploy through GitHub Actions, not
      through the VPS deploy clone. The run_url label is the LAST
      SUCCESSFUL run on purpose, never the newest ATTEMPTED run: it stays
      fixed for the whole outage, so ProductDeployStale's for: 15m timer
      can actually complete. A label that tracked each failing attempt
      would reset the timer on every failing run and the alert could never
      fire (fleet-ops#4995). A read failure is up 0 + NaN seconds; a read
      that succeeds with no successful run ever is up 1 + +Inf seconds
      (truthfully infinitely stale — a fake 0 would read as freshly
      deployed).

Wiring: loaded lazily by libexec/fleet-metrics-export.py on the existing
5-min fleet-metrics-export tick (no new timer, no service change — the
issue's rollback contract). The module never raises out of the exporter:
a hard failure emits NaN gauges + fleet_deployment_quality_up 0 so the
DeploymentQualityStale rule screams instead of silently serving frozen or
zero values (a zero blocked-duration during a real 40-min block is exactly
the silent-drift the rule family exists to kill).

gh budget: at most ONE gh subprocess per scrape (merged fetch preferred,
revert count serves its longer-TTL cache), mirroring the exporter's
_GH_FETCHED_THIS_RUN discipline so the 5-min oneshot stays well under 60s.
Cached to the same 30min/2h TTL/stale envelope; a failing call serves the
stale cache and only goes NaN after 2h. Local sources (journal, actions
log) are cached for 60s so an idle scrape is a cheap read.

The product family (f) is a SEPARATE gh slot with its own per-repo TTL
cache, because _GH_FETCHED_THIS_RUN is already burned by the fleet-ops
family when prom_lines() reaches it (fleet-ops#4995). It fetches only the
repo whose product cache is oldest — never-fetched first — so N repos cost
one gh call per N ticks, and its cache stores the success EPOCH so the
freshness age is recomputed every scrape and never freezes.

Environment seams (tests):
  FLEET_DQ_NOW              ISO/epoch override for deterministic tests
  FLEET_DQ_MERGED           path to a JSON list of {mergedAt} (skip gh)
  FLEET_DQ_REVERTS          path to a JSON list; length = auto-revert events (skip gh)
  FLEET_DQ_JOURNAL          path to a fleet-deploy-check journal fixture
  FLEET_DQ_ACTIONS_LOG      path to an alert-repair actions.log fixture
  FLEET_DQ_CRITICAL_ALERTS  comma-separated critical alert names (tests)
  FLEET_DQ_CACHE_DIR        cache dir (default: $AGENT_STATE/fleet-metrics)
  FLEET_DQ_GH               gh binary (default: gh)
  FLEET_DQ_PRODUCT_REPOS    comma-separated product repos (skips the intake read)
  FLEET_DQ_PRODUCT_RUNS     JSON {repo: gh run list --json array} (skips gh + cache)
  FLEET_DQ_PRODUCT_CACHE_DIR  product cache dir (default: FLEET_DQ_CACHE_DIR)
  FLEET_DQ_PRODUCT_WORKFLOW default: deploy-production.yml
  FLEET_DQ_PRODUCT_BRANCH   default: main
  AGENT_STATE               default: ~/workspaces/agent-state
"""
from __future__ import annotations

import importlib.util
import json
import math
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

METRIC_DEFS = (
    # (name, help)
    ("fleet_deployment_latency_seconds",
     "p95 merge-to-live latency for fleet-ops (mergedAt -> first green fleet-deploy-check cycle), trailing window."),
    ("fleet_deployment_rollback_rate",
     "auto-revert events / merged deployments for fleet-ops, trailing 30 days."),
    ("fleet_deployment_time_to_detect_seconds",
     "p95 time from fleet-ops deploy to first critical alert dispatch, trailing window."),
    ("fleet_deployment_success_rate",
     "fleet-ops deployments with zero critical alerts in the 1h after merge / total deployments, trailing window."),
    ("fleet_deploy_blocked_duration_seconds",
     "age in seconds of the current DEPLOY-BLOCKED episode on the fleet-ops deploy clone; 0 when not blocked (fleet-ops#2725 pattern)."),
    ("fleet_deployment_quality_up",
     "1 when the deploy-quality computation succeeded this scrape, 0 when it failed (values are NaN)."),
    ("fleet_deployment_total",
     "total fleet-ops merged deployments in the trailing window (denominator)."),
    ("fleet_deployment_revert_total",
     "auto-revert events (revert: auto-restore green main PRs) in the trailing window (numerator)."),
)

# Product deploy-freshness family (fleet-ops#4995). Kept apart from
# METRIC_DEFS because these carry a per-repo label set and their own +Inf
# renderer, not the repo="fleet-ops" one-liner the loop above emits.
PRODUCT_METRIC_DEFS = (
    ("fleet_product_deploy_last_success_seconds",
     "seconds since the newest SUCCESSFUL push-triggered Deploy production run on the default branch "
     "(fleet-ops#4995); +Inf means the read succeeded but no successful run exists yet, NaN means the "
     "GitHub read failed. run_url labels the LAST SUCCESSFUL run, not the newest attempt: it is stable "
     "for the whole outage so ProductDeployStale's for: 15m timer can complete."),
    ("fleet_product_deploy_up",
     "1 when the product deploy-freshness read succeeded this scrape (including 'no successful run "
     "ever', which reports +Inf seconds), 0 when the read failed (seconds are NaN); the labels match "
     "fleet_product_deploy_last_success_seconds so ProductDeployStale's `and` vector-matches "
     "(fleet-ops#4995)."),
)
PRODUCT_WORKFLOW = "deploy-production.yml"
PRODUCT_BRANCH = "main"
PRODUCT_CACHE_PREFIX = "deploy-quality-product-"
# The product family's own one-fetch-per-scrape slot: _GH_FETCHED_THIS_RUN
# is already burned by the fleet-ops family by the time prom_lines() gets
# here (fleet-ops#4995), so routing this path through _cached() would leave
# every product repo uncached forever.
_DQ_PRODUCT_GH_FETCHED_THIS_RUN = False
_PRODUCT_SLO_MOD = None


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
    """Run a command, return subprocess result or None on failure."""
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                       env={**os.environ, **env})
    if r.returncode != 0:
        print(f"deploy-quality gh rc={r.returncode}: {r.stderr.strip()[:300]}",
              file=sys.stderr)
        return None
    return r


def _gh_json(cmd, env):
    r = _run(cmd, env)
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


def _fmt(v):
    if v is None:
        return "NaN"
    if isinstance(v, float):
        return repr(round(v, 3))
    return str(v)


def _esc(s):
    """Escape a Prometheus label value (backslash, quote, newline).

    The product labels carry a URL from gh or from a cache file; a bare
    quote there would emit a malformed line and take the whole metrics
    scrape down with it.
    """
    return str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _fmt_seconds(v):
    """Prometheus text for a product freshness age.

    _fmt() routes floats through repr(round(v, 3)), which prints `inf` —
    not the Prometheus literal `+Inf`, and `inf` parses as a metric name
    (fleet-ops#4995). NaN / +Inf are rendered explicitly; everything else
    keeps the existing rounding.
    """
    if v is None:
        return "NaN"
    if isinstance(v, float):
        if math.isnan(v):
            return "NaN"
        if math.isinf(v):
            return "+Inf" if v > 0 else "-Inf"
    return _fmt(v)


def _product_cache_dir(env):
    """Product per-repo cache dir: FLEET_DQ_PRODUCT_CACHE_DIR, else the
    shared $FLEET_DQ_CACHE_DIR / $AGENT_STATE/fleet-metrics root the
    fleet-ops caches already use — one cache root, no new one."""
    seam = (env or os.environ).get("FLEET_DQ_PRODUCT_CACHE_DIR")
    if seam:
        return Path(seam)
    return _cache_paths(env)[0].parent


def _product_slo_mod():
    """Lazily load lib/fleet-product-slo.py for load_product_repos().

    Reused rather than re-implemented (fleet-ops#4995): the
    intake-minus-self-maintenance rule already lives there, and that
    module's own path candidates cover the deploy clone and the checkout
    this file is installed from.
    """
    global _PRODUCT_SLO_MOD
    if _PRODUCT_SLO_MOD is not None:
        return _PRODUCT_SLO_MOD
    name = "fleet_product_slo_for_deploy_quality"
    mod = sys.modules.get(name)
    if mod is None:
        path = Path(__file__).resolve().parent / "fleet-product-slo.py"
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
    _PRODUCT_SLO_MOD = mod
    return mod


def _product_repo_list(env):
    """Product repo short names, or [] when enrollment cannot be read.

    FLEET_DQ_PRODUCT_REPOS (comma-separated, possibly empty) bypasses the
    config read so offline fixtures never touch intake-repos.json. Any
    failure to load or resolve the list yields ZERO product lines and is
    logged — never an exception (fleet-ops#4995).
    """
    seam = (env or os.environ).get("FLEET_DQ_PRODUCT_REPOS")
    if seam is not None:
        return [r.strip() for r in seam.split(",") if r.strip()]
    try:
        return [r for r in _product_slo_mod().load_product_repos() if r]
    except Exception as exc:  # noqa: BLE001 - a broken sibling must not kill the export
        print(f"deploy-quality product: repo list unavailable: {exc}", file=sys.stderr)
        return []


def _product_from_rows(rows, branch):
    """Return {"epoch": float|None, "url": str} for a gh run-list array.

    None means the READ failed. {"epoch": None, "url": ""} means the read
    succeeded and no qualifying run exists — truthfully +Inf seconds, never
    a fake 0 (a 0 would read as "deployed just now", fleet-ops#4995).
    gh is asked for --status success, but every row is re-validated here:
    only conclusion=success on a push event on the default branch counts,
    so a PR-head success or a cancelled run can never be counted even if
    the server-side filter ever widens.
    """
    if not isinstance(rows, list):
        return None
    for row in rows:
        if not isinstance(row, dict):
            continue
        if row.get("conclusion") != "success":
            continue
        if row.get("event") != "push" or row.get("headBranch") != branch:
            continue
        epoch = _parse_iso_utc(str(row.get("createdAt") or ""))
        if epoch is None:
            continue
        return {"epoch": epoch, "url": str(row.get("url") or "")}
    return {"epoch": None, "url": ""}


def _product_fetch(repo, env):
    """ONE gh call: newest successful push-triggered deploy run for a repo."""
    e = env or os.environ
    branch = e.get("FLEET_DQ_PRODUCT_BRANCH") or PRODUCT_BRANCH
    rows = _gh_json([
        e.get("FLEET_DQ_GH") or "gh",
        "run", "list", "-R", f"Nishfleet/{repo}",
        "--workflow", e.get("FLEET_DQ_PRODUCT_WORKFLOW") or PRODUCT_WORKFLOW,
        "--event", "push",
        "--branch", branch,
        "--status", "success",
        "--limit", "1",
        "--json", "conclusion,createdAt,event,headBranch,url",
    ], e)
    return _product_from_rows(rows, branch)


def _product_row(repo, data, age, now):
    """Gauge values for one repo; a corrupt cache entry degrades HERE."""
    failed = {"repo": repo, "up": 0, "seconds": float("nan"), "url": ""}
    if not isinstance(data, dict) or age is None or age > GH_STALE:
        # No reading within the 2h stale window: a failed read, not a stale
        # number presented as if it were current.
        return failed
    epoch = data.get("epoch")
    if epoch is None:
        # Read succeeded, no successful deploy ever: +Inf is the honest
        # age, and up stays 1 because the read itself worked.
        return {"repo": repo, "up": 1, "seconds": float("inf"), "url": ""}
    try:
        epoch = float(epoch)
    except (TypeError, ValueError):
        return failed
    return {"repo": repo, "up": 1, "seconds": max(0.0, now - epoch),
            "url": str(data.get("url") or "")}


def _product_scrape(repos, env):
    """Resolve every repo's last successful deploy, spending <= ONE gh call.

    Only the repo whose cache is oldest is fetched (never-fetched first);
    every other repo is served from its cache, so N repos rotate fairly at
    one gh call per N ticks. The cache holds the success EPOCH, so
    now - epoch is recomputed on every scrape and a cached reading never
    freezes the freshness age.
    """
    global _DQ_PRODUCT_GH_FETCHED_THIS_RUN
    if not repos:
        return []
    e = env or os.environ
    now = _now(env)
    branch = e.get("FLEET_DQ_PRODUCT_BRANCH") or PRODUCT_BRANCH
    cache_dir = _product_cache_dir(env)
    entries = {}
    for repo in repos:
        path = cache_dir / f"{PRODUCT_CACHE_PREFIX}{repo}.json"
        data, age = _read_cache(path)
        entries[repo] = [path, data, age]

    seam = e.get("FLEET_DQ_PRODUCT_RUNS")
    if seam is not None:
        # Fixture seam: no gh and no cache read, so a test may mutate the
        # fixture between calls and see the change (fleet-ops#4995).
        table = None
        if seam:
            try:
                table = json.loads(Path(seam).read_text())
            except (OSError, json.JSONDecodeError) as exc:
                print(f"deploy-quality product: runs fixture unreadable: {exc}",
                      file=sys.stderr)
        for repo in repos:
            rows = table.get(repo) if isinstance(table, dict) else None
            data = _product_from_rows(rows, branch)
            # A repo absent from the fixture is a MISSING READ, not "no
            # successful run": those two outcomes must not be conflated.
            entries[repo] = [entries[repo][0], data, 0.0 if data is not None else None]
    elif not _DQ_PRODUCT_GH_FETCHED_THIS_RUN:
        # Freshness TTL scales with the repo count so a repo is not
        # re-fetched out of turn while the others are still fresh: N repos
        # rotate in N * 300s, with GH_TTL as the floor (fleet-ops#4995).
        fresh_ttl = max(GH_TTL, len(repos) * 300)

        def _age_rank(r):
            age = entries[r][2]
            return float("inf") if age is None else age

        target = max(repos, key=_age_rank)
        if _age_rank(target) < fresh_ttl:
            target = None  # every cache is fresh — spend no gh call
        if target is not None:
            _DQ_PRODUCT_GH_FETCHED_THIS_RUN = True
            fresh = None
            try:
                fresh = _product_fetch(target, env)
            except (OSError, subprocess.SubprocessError) as exc:
                # e.g. FLEET_DQ_GH=/nonexistent/gh: a dead binary or a
                # timeout must degrade, never raise out of prom_lines().
                print(f"deploy-quality product {target}: gh failed: {exc}",
                      file=sys.stderr)
            if fresh is not None:
                _write_cache(entries[target][0], fresh)
                entries[target] = [entries[target][0], fresh, 0.0]
            elif entries[target][2] is not None and entries[target][2] <= GH_STALE:
                print(f"deploy-quality product {target}: gh failed, serving stale cache "
                      f"(age={int(entries[target][2])}s)", file=sys.stderr)

    return [_product_row(repo, entries[repo][1], entries[repo][2], now) for repo in repos]


def _product_lines(env):
    """The fleet_product_deploy_* family; never raises (fleet-ops#4995).

    A per-repo read failure degrades THAT repo to up 0 + NaN seconds while
    the others keep their values; a failed enrollment read degrades to ZERO
    product lines. The fleet-ops family's raising contract is untouched, so
    libexec/fleet-metrics-export.py::_emit_deploy_quality keeps its shape.
    """
    try:
        repos = _product_repo_list(env)
    except Exception as exc:  # noqa: BLE001 - defensive: prom_lines must not raise
        print(f"deploy-quality product: repo list failed: {exc}", file=sys.stderr)
        return []
    if not repos:
        return []
    try:
        rows = _product_scrape(repos, env)
    except Exception as exc:  # noqa: BLE001 - one bad scrape must not kill the export
        print(f"deploy-quality product: scrape failed: {exc}", file=sys.stderr)
        rows = [{"repo": r, "up": 0, "seconds": float("nan"), "url": ""} for r in repos]
    out = [""]
    for name, help in PRODUCT_METRIC_DEFS:
        out.append(f"# HELP {name} {help}")
        out.append(f"# TYPE {name} gauge")
        for row in rows:
            repo_label = _esc(row["repo"])
            url_label = _esc(row["url"])
            label = f'repo="{repo_label}", run_url="{url_label}"'
            value = (row["up"] if name == "fleet_product_deploy_up"
                     else _fmt_seconds(row["seconds"]))
            out.append(f"{name}{{{label}}} {value}")
    return out


def prom_lines(env=None):
    """Return the Prometheus text lines for the deploy-quality family.

    The fleet-ops family raises ValueError on hard failure (caller emits
    NaN + up 0) and its per-gauge values carry their own NaN when a
    sub-metric had no samples. The appended product family never raises:
    it degrades per repo to up 0 + NaN seconds, or to no lines at all when
    the enrollment itself cannot be read.
    """
    p = compute(env)
    label = f'repo="{REPO}"'
    out = [""]
    for name, help in METRIC_DEFS:
        if name == "fleet_deployment_latency_seconds":
            v = p["latency_p95"]
        elif name == "fleet_deployment_rollback_rate":
            v = p["rollback_rate"]
        elif name == "fleet_deployment_time_to_detect_seconds":
            v = p["time_to_detect_p95"]
        elif name == "fleet_deployment_success_rate":
            v = p["success_rate"]
        elif name == "fleet_deploy_blocked_duration_seconds":
            v = p["blocked_duration"]
        elif name == "fleet_deployment_quality_up":
            v = 1
        elif name == "fleet_deployment_total":
            v = p["total"]
        else:  # fleet_deployment_revert_total
            v = p["revert_total"]
        out.append(f"# HELP {name} {help}")
        out.append(f"# TYPE {name} gauge")
        out.append(f"{name}{{{label}}} {_fmt(v)}")
    out.extend(_product_lines(env))
    return out


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