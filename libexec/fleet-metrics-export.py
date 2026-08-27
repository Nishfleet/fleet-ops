#!/usr/bin/env python3
"""Write fleet facts to node_exporter textfile collector (stdlib only).

Discovers fleet-* and pi-* timers dynamically from `systemctl --user
list-timers`. Never hardcodes a unit list — deleted timers disappear from
the export automatically.
"""
import calendar
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
# merged-prs; omitted after 2h stale — never a frozen value.
HELP_READY = "# HELP fleet_ready_work Open agent-ready issues across enrolled Nishfleet repos (intake-repos.json). Omitted when gh is unhealthy and cache is >2h stale."
TYPE_READY = "# TYPE fleet_ready_work gauge"
# `fleet_maintenance_quiescing` — 1 during the weekly maintenance window (or
# any manual quiesce), else 0. Gates FleetUndersaturated so the window's
# drained workers don't page. Reads agent-state/maintenance.json — the SAME
# flag vps-maintenance-quiesce sets — not a hardcoded schedule. Missing file
# → 0 (fail SAFE toward alerting; never silently suppress the guard).
HELP_MAINT = "# HELP fleet_maintenance_quiescing 1 during the weekly maintenance window (or manual quiesce), else 0. Gates FleetUndersaturated. Missing flag -> 0 (fail-safe toward alerting)."
TYPE_MAINT = "# TYPE fleet_maintenance_quiescing gauge"

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

ACTIONS_LOG = Path(
    "/home/nish/workspaces/agent-state/alert-repair/actions.log"
)
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
JOURNAL_TIMEOUT = 20
GH_PAGES = 10

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
        with urllib.request.urlopen(
            "http://127.0.0.1:9090/api/v1/alerts", timeout=10
        ) as r:
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
        with urllib.request.urlopen(req, timeout=10) as r:
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
    """Cached list of {repo, title} for PRs merged in the trailing 24h, or None.

    One gh call fetches repository + closedAt + title. The per-repo
    fleet_merged_prs_24h family, the self-maintenance ratio, and the
    upgrade/repair/churn classification all derive from this single fetch
    (fleet-ops#1136) — no extra gh call per exporter run.
    """
    return _cached_json(DETAIL_CACHE, _gh_merged_prs_raw, "merged_prs_detail")


def _gh_merged_prs():
    """Back-compat alias for callers expecting {repo: count}."""
    return _merged_prs_24h()


def _gh_merged_prs_raw():
    """One cheap gh call across all Nishfleet repos.

    Returns a list of {"repo": "Nishfleet/<name>", "title": "..."} for PRs
    merged in the trailing 24h, or None on failure.
    """
    try:
        r = subprocess.run(
            [
                "gh", "search", "prs",
                "--owner", GH_OWNER,
                "--merged",
                "--json", "repository,closedAt,title",
                "--limit", "500",
            ],
            capture_output=True, text=True, timeout=GH_TIMEOUT,
            env={**os.environ, "GH": "/usr/bin/gh"},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"gh search prs failed: {exc}", file=sys.stderr)
        return None
    if r.returncode != 0:
        print(f"gh search prs rc={r.returncode}: {r.stderr.strip()[:200]}",
              file=sys.stderr)
        return None
    try:
        rows = json.loads(r.stdout or "[]")
    except json.JSONDecodeError as exc:
        print(f"gh search prs json: {exc}", file=sys.stderr)
        return None
    cutoff_epoch = time.time() - 86400
    out = []
    for row in rows:
        repo = (row.get("repository") or {}).get("nameWithOwner") or \
               (row.get("repository") if isinstance(row.get("repository"), str)
                else "")
        merged = row.get("closedAt") or ""
        if not repo:
            continue
        ep = _parse_iso_utc(merged)
        if ep is None or ep < cutoff_epoch:
            continue
        out.append({"repo": repo, "title": row.get("title") or ""})
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
    """Count unit-escalation@<instance> starts in the last 24h (top 20)."""
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
        if m:
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
    Nishfleet` call → total count of open agent-ready issues across enrolled
    repos. Returns int >= 0, or None to omit the family.

    Owner-scoped (one call); results are filtered to enrolled repos so a
    non-enrolled Nishfleet repo's agent-ready issues don't inflate depth.
    None when no repos are enrolled (no work concept → rule must not fire).
    """
    repos = _enrolled_repos()
    if not repos:
        return None
    enrolled = set(repos)
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
    n = 0
    for row in rows:
        repo = row.get("repository")
        nwo = ""
        if isinstance(repo, dict):
            nwo = repo.get("nameWithOwner") or ""
        elif isinstance(repo, str):
            nwo = repo
        if nwo and nwo not in enrolled:
            continue
        n += 1
    return n


def _ready_work():
    """Cached open agent-ready issue count (30-min fresh, 2-h stale envelope)."""
    return _cached_json(READY_CACHE, _gh_ready_work, "ready_work")


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
    lines.append("")
    lines.append(HELP_TEST)
    lines.append(TYPE_TEST)
    lines.append(
        f"fleet_test_alert {1 if TEST_ALERT_FILE.exists() else 0}"
    )

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

    ready = _ready_work()
    if ready is not None:
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
