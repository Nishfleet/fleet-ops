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
      Published as the p95 over the trailing window.
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
      (for:30m), FleetChainStalled (for:15m), and 3h absence rules are
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

Environment seams (tests):
  FLEET_DQ_NOW              ISO/epoch override for deterministic tests
  FLEET_DQ_MERGED           path to a JSON list of {mergedAt} (skip gh)
  FLEET_DQ_REVERTS          path to a JSON list; length = auto-revert events (skip gh)
  FLEET_DQ_JOURNAL          path to a fleet-deploy-check journal fixture
  FLEET_DQ_ACTIONS_LOG      path to an alert-repair actions.log fixture
  FLEET_DQ_CRITICAL_ALERTS  comma-separated critical alert names (tests)
  FLEET_DQ_CACHE_DIR        cache dir (default: $AGENT_STATE/fleet-metrics)
  FLEET_DQ_GH               gh binary (default: gh)
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
#   FleetMainRed for=1800, FleetChainStalled for=900,
#   FleetCompletionCanaryAbsent/FleetUndersatGuardAbsent for=10800,
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
    alert (Alertmanager repeat / completion-canary hop) do not start a
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

    0 duration when the newest event is not a blocked cycle — either the
    pipeline is green or main has not moved. A run is the contiguous tail
    of blocked events with inter-line gaps <= BLOCK_RUN_GAP_S.
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
    greens = _green_finishes(events) if events is not None else []
    latency = []
    for m in merged:
        if m < journal_start - 86400:
            continue  # deploy record predates the journal — not measurable
        for g in greens:
            if g >= m:
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


def prom_lines(env=None):
    """Return the Prometheus text lines for the deploy-quality family.

    Raises ValueError on hard failure (caller emits NaN + up 0); the
    per-gauge values carry their own NaN when a sub-metric had no samples.
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