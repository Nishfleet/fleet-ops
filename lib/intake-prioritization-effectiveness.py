#!/usr/bin/env python3
"""Intake prioritization effectiveness metric (fleet-ops#2759).

The precedence-band product-first hold (fleet-ops#2519/#2539, see
lib/precedence-band.sh product_first_hold) engages when the queue
self-maintenance ratio exceeds PRODUCT_FIRST_SELF_RATIO_MAX (0.5) and
holds the self-maintenance repo (fleet-ops) in the intake buffer so
fleet capacity goes to product repos. The fleet previously optimized for
the MECHANISM (the hold engages) rather than the OUTCOME (product merges
actually rise). This module measures the outcome: it splits the trailing
14-day window into hold vs baseline periods and compares product merge
throughput between them. If the lift is < 0.1 while the hold engaged more
than half the window, the IntakePrioritizationIneffective rule fires; if
the hold engaged > 80% of the window while fleet-ops merges < 0.5/week,
IntakeHoldStarvesFleet fires (the fleet-ops#2657 hard-stall pattern).

Sources:

  hold periods   — journal evidence, trailing 14 days (journald keeps the
                   window; node_exporter does not reach back before
                   install):
      pi-intake@fleet-ops  `held-in-buffer: (` summary line
                          -> hold engaged (True)
      pi-intake@fleet-ops  `: claimed+spawned` on a fleet-ops issue
                          -> hold released in that tick (False); the
                             pi-intake@fleet-ops unit only processes
                             fleet-ops issues, so a normal claim inside
                             it is a non-hold sample
      fleet-heartbeat     `36.5. product-ratio cache STALE|MISSING`
                          -> the cache is dead and the hold is silently
                             failing open (False)
    Between samples the last observed state forward-fills. Before the
    first sample the state is False (fail-open, the mechanism's own
    posture). The last sample before the window sets the initial state,
    so a hold that started before the window still counts inside it.

  merge history — one cached gh GraphQL search
                  (`org:Nishfleet is:pr is:merged merged:>=CUT
                   sort:merged-desc`) with a 6h TTL so the 5-min tick
                   never burns the gh budget (the metric is a 14-day
                   trailing average; 6h freshness is plenty). Gh failure
                   serves the cache up to 24h; beyond that the
                   merge-derived gauges are omitted but the hold gauges
                   and the heartbeat gauge are still written (the absent()
                   rule keys on the heartbeat, not on a quiet gh day).

Output: fleet-intake-effectiveness.prom (node_exporter textfile),
written atomically. Runs as a drop-in ExecStart on the existing
fleet-metrics-export.service (no new timer); always exits 0 so a fault
cannot fail the parent exporter.

Environment seams (tests):
  INTAKE_NOW, INTAKE_WINDOW_S, INTAKE_HOLD_JOURNAL (journald -o json
  dump path instead of live journalctl), INTAKE_PI_INTAKE_UNIT,
  INTAKE_HEARTBEAT_UNIT, INTAKE_MERGES_CACHE, INTAKE_MERGES_TTL,
  INTAKE_MERGES_STALE, INTAKE_PRODUCT_REPO, INTAKE_CONTROL_REPO,
  INTAKE_OUT, HOLD_ACTIVE_MAX_AGE_S, XDG_RUNTIME_DIR
"""
from __future__ import annotations

import bisect
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

# --- Config ----------------------------------------------------------------

HOME = os.environ.get("HOME", "/home/nish")
AS = Path(os.environ.get("AGENT_STATE", f"{HOME}/workspaces/agent-state"))
OUT = Path(
    os.environ.get(
        "INTAKE_OUT",
        "/var/lib/prometheus/node-exporter/fleet-intake-effectiveness.prom",
    )
)
CACHE = Path(
    os.environ.get(
        "INTAKE_MERGES_CACHE",
        str(AS / "fleet-metrics" / "intake-effectiveness-cache.json"),
    )
)
# Trailing window over which effectiveness is measured (default 14 days).
WINDOW_S = int(os.environ.get("INTAKE_WINDOW_S", "1209600"))
# A sample older than this means the intake machinery is silent (no work);
# the live hold gauge then reads 0, not a stale forward-fill.
HOLD_ACTIVE_MAX_AGE_S = int(os.environ.get("HOLD_ACTIVE_MAX_AGE_S", "21600"))
# Merge-history cache freshness envelope (mirrors the exporter's pattern).
MERGES_TTL = int(os.environ.get("INTAKE_MERGES_TTL", "21600"))
MERGES_STALE = int(os.environ.get("INTAKE_MERGES_STALE", "86400"))
PRODUCT_REPO = os.environ.get("INTAKE_PRODUCT_REPO", "Nishfleet/0509")
CONTROL_REPO = os.environ.get("INTAKE_CONTROL_REPO", "Nishfleet/fleet-ops")
# Journald units that carry the hold-state evidence.
PI_INTAKE_UNIT = os.environ.get(
    "INTAKE_PI_INTAKE_UNIT", "pi-intake@fleet-ops.service"
)
HEARTBEAT_UNIT = os.environ.get(
    "INTAKE_HEARTBEAT_UNIT", "fleet-heartbeat.service"
)
JOURNALCTL = os.environ.get("INTAKE_JOURNALCTL", "journalctl")
# Test seam: a full journald `-o json` dump file to parse instead of a live
# journalctl call (offline tests feed canned evidence through the SAME code
# path the live run uses).
HOLD_JOURNAL = os.environ.get("INTAKE_HOLD_JOURNAL", "")
# Everything under XDG runtime dir so journalctl reaches the user bus.
XDG = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
GH_TIMEOUT = 45
JOURNAL_TIMEOUT = 20
_SECONDS_PER_DAY = 86400.0

HOLD_HELP = (
    "# HELP fleet_intake_hold_active 1 if the intake precedence-band product-first "
    "hold is currently engaging fleet-ops dispatches (evidence: pi-intake@fleet-ops "
    "held-in-buffer lines; fleet-ops#2759). 0 when the last hold sample is older "
    "than HOLD_ACTIVE_MAX_AGE_S or the cache is dead (fails open)."
)
HOLD_TYPE = "# TYPE fleet_intake_hold_active gauge"
FRAC_HELP = (
    "# HELP fleet_intake_hold_fraction_14d Fraction of the trailing 14-day window "
    "during which the product-first hold was engaged, 0..1 (fleet-ops#2759)."
)
FRAC_TYPE = "# TYPE fleet_intake_hold_fraction_14d gauge"
PH_HELP = (
    "# HELP fleet_intake_product_merge_rate_during_hold Product-repo merged PRs per "
    "day measured inside hold windows, trailing 14d (fleet-ops#2759)."
)
PH_TYPE = "# TYPE fleet_intake_product_merge_rate_during_hold gauge"
PB_HELP = (
    "# HELP fleet_intake_product_merge_rate_baseline Product-repo merged PRs per day "
    "measured outside hold windows, trailing 14d (fleet-ops#2759)."
)
PB_TYPE = "# TYPE fleet_intake_product_merge_rate_baseline gauge"
CH_HELP = (
    "# HELP fleet_intake_control_merge_rate_during_hold Control-plane (fleet-ops) "
    "merged PRs per day measured inside hold windows, trailing 14d (fleet-ops#2759)."
)
CH_TYPE = "# TYPE fleet_intake_control_merge_rate_during_hold gauge"
CB_HELP = (
    "# HELP fleet_intake_control_merge_rate_baseline Control-plane (fleet-ops) "
    "merged PRs per day measured outside hold windows, trailing 14d (fleet-ops#2759)."
)
CB_TYPE = "# TYPE fleet_intake_control_merge_rate_baseline gauge"
CW_HELP = (
    "# HELP fleet_intake_control_merge_rate_week Control-plane (fleet-ops) merged "
    "PRs per week over the trailing 14d — the IntakeHoldStarvesFleet input "
    "(fleet-ops#2759, #2657 hard-stall pattern)."
)
CW_TYPE = "# TYPE fleet_intake_control_merge_rate_week gauge"
EFF_HELP = (
    "# HELP fleet_intake_prioritization_effectiveness Product merge-rate lift from "
    "the hold: (rate_during_hold - rate_baseline) / rate_baseline, trailing 14d "
    "(fleet-ops#2759). Omitted when the baseline rate is 0. < 0 means the hold "
    "lowered product throughput."
)
EFF_TYPE = "# TYPE fleet_intake_prioritization_effectiveness gauge"
LRUN_HELP = (
    "# HELP fleet_intake_effectiveness_last_run_seconds Epoch (s) of the last "
    "successful intake-effectiveness export. Organ heartbeat: the "
    "FleetIntakeEffectivenessAbsent absent() rule fires when this gauge "
    "disappears (fleet-ops#1010, #2759)."
)
LRUN_TYPE = "# TYPE fleet_intake_effectiveness_last_run_seconds gauge"

# --- Journal evidence parsing ----------------------------------------------

_HOLD_RE = re.compile(r"held-in-buffer: \(")
_CLAIMED_RE = re.compile(r": claimed\+spawned\b")
_CACHE_DEAD_RE = re.compile(r"36\.5\. product-ratio cache (STALE|MISSING)")


def _parse_iso_utc(s):
    """YYYY-MM-DDTHH:MM:SS[.frac]Z -> epoch seconds, or None."""
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return None


def _journal_json_lines(unit, since_iso):
    """Return the journald `-o json` lines for one user unit as a text blob."""
    if HOLD_JOURNAL:
        # Test seam: the whole dump lives in one file (all units merged).
        try:
            return Path(HOLD_JOURNAL).read_text()
        except OSError:
            return ""
    try:
        r = subprocess.run(
            [
                JOURNALCTL, "--user", "-u", unit, "-o", "json",
                "--since", since_iso,
            ],
            capture_output=True,
            text=True,
            timeout=JOURNAL_TIMEOUT,
            env={**os.environ, "XDG_RUNTIME_DIR": XDG},
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if r.returncode != 0:
        return ""
    return r.stdout


def parse_journal_samples(text, window_start):
    """Parse journald `-o json` lines into (epoch, hold_bool) samples.

    A sample is a point-in-time observation of the precedence-band hold:
      held-in-buffer: (        -> True  (hold engaging)
      : claimed+spawned        -> False (a normal fleet-ops claim happened)
      36.5 ... STALE|MISSING   -> False (cache dead, hold fails open)
    Samples older than the 14-day window are kept ONLY to seed the initial
    state (a hold that started before the window must count inside it).
    """
    samples = []
    for line in (text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(rec, dict):
            continue
        ts_us = rec.get("__REALTIME_TIMESTAMP") or rec.get("_SOURCE_REALTIME_TIMESTAMP")
        msg = rec.get("MESSAGE") or ""
        if not ts_us or not msg:
            continue
        # journald -o json exports multi-line messages as a LIST of lines;
        # normalize to a single string so the regex search is robust.
        if isinstance(msg, list):
            msg = "\n".join(str(x) for x in msg)
        elif not isinstance(msg, str):
            msg = str(msg)
        try:
            epoch = int(ts_us) // 1_000_000
        except (TypeError, ValueError):
            continue
        if _HOLD_RE.search(msg):
            samples.append((epoch, True))
        elif _CLAIMED_RE.search(msg) or _CACHE_DEAD_RE.search(msg):
            samples.append((epoch, False))
    return samples


def read_hold_samples(window_start):
    """Collect + parse hold samples from the two journal units; sorted."""
    since_iso = datetime.fromtimestamp(
        window_start, tz=timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    samples = []
    samples += parse_journal_samples(
        _journal_json_lines(PI_INTAKE_UNIT, since_iso), window_start
    )
    samples += parse_journal_samples(
        _journal_json_lines(HEARTBEAT_UNIT, since_iso), window_start
    )
    return sorted(samples)


# --- Merge history ---------------------------------------------------------

_MERGED_SEARCH_QUERY_TEMPLATE = """
query($cursor: String) {
  search(query: "org:Nishfleet is:pr is:merged merged:{RANGE} sort:merged-desc", type: ISSUE, first: 100, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        id
        mergedAt
        repository { nameWithOwner }
      }
    }
  }
}
"""

# GitHub caps ANY search query at 1000 results (documented) and does NOT
# support `merged:<timestamp` qualifiers — a single merged:>=14d query
# silently truncates the OLDEST merges in the window (mid-August 2026
# fleet2 alone merged 100-300+ PRs/day; the trailing 14 days total ~1800
# merges org-wide, so the cap eats exactly the baseline records). Fix:
# split the window into contiguous 2-calendar-day chunks quoted with the
# inclusive date-range syntax `merged:YYYY-MM-DD..YYYY-MM-DD`. Each chunk
# stays far under the 1000-result cap (peak observed 608 across the
# worst 2-day pair, 2026-08-26..27). Adjacent chunks share their boundary
# day; _gh_merge_history_raw dedupes by (repo, epoch).
MERGE_CHUNK_DAYS = 2
PAGES_PER_CHUNK = 12


def _chunk_window(now):
    """Yield (start, end) epoch pairs covering the trailing WINDOW_S.

    Each chunk is MERGE_CHUNK_DAYS calendar days (UTC); `end` is the last
    second of the chunk's last day + 1. The range syntax is inclusive on
    both ends, so a merge on a shared boundary day appears in both adjacent
    chunks — the fetcher dedupes.
    """
    cutoff = now - WINDOW_S
    end_dt = datetime.fromtimestamp(now, tz=timezone.utc).date()
    start_dt = datetime.fromtimestamp(cutoff, tz=timezone.utc).date()
    day = start_dt
    while day <= end_dt:
        chunk_end = min(
            day +
            timedelta(days=MERGE_CHUNK_DAYS - 1),
            end_dt,
        )
        start_epoch = int(
            datetime(day.year, day.month, day.day, tzinfo=timezone.utc)
            .timestamp()
        )
        end_epoch = int(
            datetime(
                chunk_end.year, chunk_end.month, chunk_end.day,
                tzinfo=timezone.utc,
            ).timestamp()
        ) + 86400
        if end_epoch > now + 86400:
            end_epoch = int(now) + 1
        yield start_epoch, end_epoch
        day = chunk_end + timedelta(days=1)


def _gh_graphql(query, cursor=None):
    try:
        r = subprocess.run(
            ["gh", "api", "graphql", "-f", f"query={query}"]
            + (["-f", f"cursor={cursor}"] if cursor else []),
            capture_output=True, text=True, timeout=GH_TIMEOUT,
            env={**os.environ, "GH": "/usr/bin/gh"},
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        print(f"intake-effective: gh graphql rc={r.returncode}", file=sys.stderr)
        return None
    try:
        return json.loads(r.stdout or "{}")
    except json.JSONDecodeError:
        return None


def _gh_merge_history_raw():
    """Chunked paginated search: merged PRs (repo, epoch) since window start.

    One GraphQL call set; each chunk is a 3-day merged:>= / merged:< range
    so no single query trie GitHub's 1000-result cap (see the comment above
    the template for why the org volume forces this). Returns None only on
    a gh transport/error failure (caller serves the cache / omits).
    """
    now = time.time()
    out = []
    seen = set()
    for start, end in _chunk_window(now):
        start_d = datetime.fromtimestamp(start, tz=timezone.utc).date()
        end_d = datetime.fromtimestamp(end - 1, tz=timezone.utc).date()
        query = _MERGED_SEARCH_QUERY_TEMPLATE.replace(
            "{RANGE}", f"{start_d.isoformat()}..{end_d.isoformat()}"
        )
        cursor = None
        done = False
        for _ in range(PAGES_PER_CHUNK):
            payload = _gh_graphql(query, cursor)
            if payload is None:
                return None
            if payload.get("errors"):
                print(f"intake-effective: gh graphql errors: {payload['errors'][:1]}",
                      file=sys.stderr)
                return None
            conn = (payload.get("data") or {}).get("search") or {}
            for node in conn.get("nodes") or []:
                node_id = node.get("id") or ""
                repo = (node.get("repository") or {}).get("nameWithOwner") or ""
                ep = _parse_iso_utc(node.get("mergedAt") or "")
                if not node_id or not repo or ep is None:
                    continue
                if not (start <= ep < end):
                    continue
                # Dedupe by the PR node id: GitHub mergedAt has second
                # granularity, so (repo, epoch) collides for same-second
                # batch merges (common during the old fleet era) and
                # silently drops records.
                if node_id in seen:
                    continue
                seen.add(node_id)
                out.append({"repo": repo, "epoch": ep})
            page = conn.get("pageInfo") or {}
            if not page.get("hasNextPage"):
                done = True
                break
            cursor = page.get("endCursor")
            if not cursor:
                done = True
                break
        if not done:
            print(
                "intake-effective: gh merged-search chunk page cap at "
                f"{PAGES_PER_CHUNK}x100 records for "
                f"{start_d.isoformat()}..{end_d.isoformat()}",
                file=sys.stderr,
            )
    return out


def _read_cache():
    try:
        c = json.loads(CACHE.read_text())
        return c.get("data"), c.get("ts")
    except (OSError, json.JSONDecodeError):
        return None, None


def _write_cache(data):
    try:
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        tmp = CACHE.with_suffix(CACHE.suffix + ".tmp")
        tmp.write_text(json.dumps({"ts": time.time(), "data": data}))
        tmp.replace(CACHE)
    except OSError as exc:
        print(f"intake-effective: cache write {CACHE}: {exc}", file=sys.stderr)


def load_merge_history():
    """Return [{repo, epoch}] or None when gh data is too stale to trust.

    Fresh cache (<= MERGES_TTL) skips gh. On gh failure serve the cache up
    to MERGES_STALE. Beyond that, None -> the caller omits merge-derived
    gauges but still writes the hold + heartbeat gauges.
    """
    cached, ts = _read_cache()
    now = time.time()
    age = now - ts if isinstance(ts, (int, float)) else None
    if age is not None and age <= MERGES_TTL and cached is not None:
        return cached
    data = _gh_merge_history_raw()
    if data is not None:
        _write_cache(data)
        return data
    if cached is not None and age is not None and age <= MERGES_STALE:
        print(f"intake-effective: gh failed, serving stale merges (age={int(age)}s)",
              file=sys.stderr)
        return cached
    return None


# --- Effectiveness math ----------------------------------------------------

def hold_segments(samples, start, now):
    """Forward-filled (start, end, hold) segments over [start, now].

    samples: sorted (epoch, hold_bool) list (may include pre-window seeds).
    Segments are half-open: [s, e) with the hold flag of the sample at s.
    """
    segs = []
    state = False
    for e, b in samples:
        if e >= start:
            break
        state = b
    pos = start
    for e, b in samples:
        if e < start:
            continue
        if e > now:
            break
        if e > pos:
            segs.append((pos, e, state))
            pos = e
        state = b
    if pos < now:
        segs.append((pos, now, state))
    return segs


def _segment_contains(segments, t):
    starts = [s for s, _e, _h in segments]
    idx = bisect.bisect_right(starts, t) - 1
    if idx < 0:
        return False
    s, e, h = segments[idx]
    return h if s <= t < e else False


def compute(samples, merges, window_start, now):
    """Compute the effectiveness family from hold samples + merge records.

    Returns a dict with the gauge values; merge-derived keys are None when
    `merges` is None (gh data unavailable) or when the denominator is 0.
    """
    out = {
        "hold_active": 0,
        "hold_fraction": 0.0,
        "product_rate_hold": None,
        "product_rate_baseline": None,
        "control_rate_hold": None,
        "control_rate_baseline": None,
        "control_rate_week": None,
        "effectiveness": None,
    }
    window_days = (now - window_start) / _SECONDS_PER_DAY
    # Live hold gauge: last observed state at-or-before `now`, bounded by
    # staleness (a silent intake machinery is not an active hold). Samples
    # are sorted; bisect for the newest one inside the window.
    if samples:
        idx = bisect.bisect_right([s[0] for s in samples], now) - 1
        if idx >= 0:
            last_e, last_b = samples[idx]
            if now - last_e <= HOLD_ACTIVE_MAX_AGE_S:
                out["hold_active"] = 1 if last_b else 0
    segments = hold_segments(samples, window_start, now)
    hold_secs = sum(e - s for s, e, h in segments if h)
    hold_days = hold_secs / _SECONDS_PER_DAY
    out["hold_fraction"] = min(1.0, max(0.0, hold_secs / max(1.0, now - window_start)))
    if merges is None:
        return out
    product_hold = product_base = control_hold = control_base = 0
    for m in merges:
        t = m.get("epoch")
        repo = m.get("repo")
        if t is None or repo is None:
            continue
        if not (window_start <= t <= now):
            continue
        holding = _segment_contains(segments, t)
        if repo == PRODUCT_REPO:
            if holding:
                product_hold += 1
            else:
                product_base += 1
        elif repo == CONTROL_REPO:
            if holding:
                control_hold += 1
            else:
                control_base += 1
    base_days = max(0.0, window_days - hold_days)
    if hold_days > 0:
        out["product_rate_hold"] = product_hold / hold_days
        out["control_rate_hold"] = control_hold / hold_days
    if base_days > 0:
        out["product_rate_baseline"] = product_base / base_days
        out["control_rate_baseline"] = control_base / base_days
    if window_days > 0:
        out["control_rate_week"] = ((control_hold + control_base) / window_days) * 7.0
    pb = out["product_rate_baseline"]
    ph = out["product_rate_hold"]
    if pb is not None and pb > 0 and ph is not None:
        out["effectiveness"] = (ph - pb) / pb
    return out


# --- Prometheus output -----------------------------------------------------

def _short_repo(repo):
    return repo.rsplit("/", 1)[-1]


def format_prometheus(stats, last_run_epoch):
    p_label = _short_repo(PRODUCT_REPO)
    c_label = _short_repo(CONTROL_REPO)
    lines = [HOLD_HELP, HOLD_TYPE,
             f'fleet_intake_hold_active{{repo="{c_label}"}} {int(stats["hold_active"])}',
             "",
             FRAC_HELP, FRAC_TYPE,
             f'fleet_intake_hold_fraction_14d{{repo="{c_label}"}} {stats["hold_fraction"]:.6f}',
             ""]
    if stats["product_rate_hold"] is not None:
        lines += [PH_HELP, PH_TYPE,
                  f'fleet_intake_product_merge_rate_during_hold{{repo="{p_label}"}} {stats["product_rate_hold"]:.6f}',
                  ""]
    if stats["product_rate_baseline"] is not None:
        lines += [PB_HELP, PB_TYPE,
                  f'fleet_intake_product_merge_rate_baseline{{repo="{p_label}"}} {stats["product_rate_baseline"]:.6f}',
                  ""]
    if stats["control_rate_hold"] is not None:
        lines += [CH_HELP, CH_TYPE,
                  f'fleet_intake_control_merge_rate_during_hold{{repo="{c_label}"}} {stats["control_rate_hold"]:.6f}',
                  ""]
    if stats["control_rate_baseline"] is not None:
        lines += [CB_HELP, CB_TYPE,
                  f'fleet_intake_control_merge_rate_baseline{{repo="{c_label}"}} {stats["control_rate_baseline"]:.6f}',
                  ""]
    if stats["control_rate_week"] is not None:
        lines += [CW_HELP, CW_TYPE,
                  f'fleet_intake_control_merge_rate_week{{repo="{c_label}"}} {stats["control_rate_week"]:.6f}',
                  ""]
    if stats["effectiveness"] is not None:
        lines += [EFF_HELP, EFF_TYPE,
                  f'fleet_intake_prioritization_effectiveness{{repo="{p_label}"}} {stats["effectiveness"]:.6f}',
                  ""]
    lines += [LRUN_HELP, LRUN_TYPE,
              f"fleet_intake_effectiveness_last_run_seconds {last_run_epoch:.3f}" + "\n"]
    return "\n".join(lines)


def _atomic_write(path, text):
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
        os.chmod(path, 0o644)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


# --- Entrypoint ------------------------------------------------------------

def main(argv=None):
    now = time.time()
    try:
        now_override = os.environ.get("INTAKE_NOW", "")
        if now_override:
            parsed = _parse_iso_utc(now_override)
            if parsed is not None:
                now = parsed
    except ValueError:
        pass
    window_start = now - WINDOW_S
    samples = read_hold_samples(window_start)
    merges = load_merge_history()
    stats = compute(samples, merges, window_start, now)
    body = format_prometheus(stats, now)
    _atomic_write(OUT, body)
    print(
        f"intake-effective: wrote {OUT} hold_active={stats['hold_active']} "
        f"hold_fraction={stats['hold_fraction']:.3f} "
        f"effectiveness={stats['effectiveness']} "
        f"samples={len(samples)} merges={'n/a' if merges is None else len(merges)}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))