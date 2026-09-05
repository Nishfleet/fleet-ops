#!/usr/bin/env python3
"""Canary effectiveness metrics (fleet-ops#2757).

Correlates canary failure events with subsequent user-facing incidents so
the fleet can prove each canary organ catches regressions before users,
not only that the canary runs.

Durable event store (fleet-ops#3052): the trailing 30d window outlives the
~7d retention of Prometheus query_range and journald, so without a store
real incidents older than retention are unclassifiable and effectiveness
can never be demonstrated. Every observed run/failure is merged into a
JSONL store under
$AGENT_STATE/canary-effectiveness/events.jsonl (dedup by
ts+kind+detail per organ), pruned to the window, and the window is
computed over the store — attribution stops flipping as old events age
out of retention.

Metric family (trailing 30d window unless noted):

  fleet_canary_runs_total{organ=...}
  fleet_canary_failures_total{organ=...}
  fleet_canary_caught_regressions_total{organ=...}
  fleet_canary_missed_regressions_total{organ=...}
  fleet_canary_effectiveness_ratio{organ=...}   caught / (caught + missed)
  fleet_canary_last_failure_seconds{organ=...}  0 when no failure in window
  fleet_canary_effectiveness_last_run_seconds   organ heartbeat (always)
  fleet_canary_effectiveness_drill_last_green_seconds
                                               epoch of last passing
                                               injected-fault drill (fleet-ops#3055)
  fleet_canary_effectiveness_drill_ok           1 = drill passed last tick

Drill (fleet-ops#3055): the hermetic self-test fault-injection drill runs
inside every LIVE tick (not only CI), so the classify path cannot silently
degrade again the way it did 2026-09-02 (19h of caught=0 with no drill
anywhere). The drill gauge only advances on a pass; a red/absent drill
trips FleetCanaryEffectivenessDrillStale.

Attribution rule (issue accept §1):
  canary failure → incident in the same product surface within 24h
    = caught-by-canary
  incident with no prior canary failure in that 24h window
    = missed-by-canary
  incident before the organ's first observed run/failure
    = ignored (the canary was not yet watching; cannot miss)

Sources:
  - Prometheus query_range for probe/drill gauges (0509-surface-probe,
    fleet-resilience-drill)
  - journalctl --user for oneshot unit Result= (fleet-completion-canary,
    siterep-live-canary)
  - `gh issue list` for bug/regression-labeled issues in each organ's
    product repos

Piggybacks fleet-metrics-export.service via
systemd/fleet-metrics-export.service.d/canary-effectiveness.conf — no new
timer. Always exits 0 so a fault cannot fail Prometheus export.

Environment seams (tests):
  FLEET_CANARY_EFF_OUT, FLEET_CANARY_EFF_NOW, FLEET_CANARY_EFF_EVENTS,
  FLEET_CANARY_EFF_PROM_URL, FLEET_CANARY_EFF_GH, FLEET_CANARY_EFF_JOURNALCTL,
  FLEET_CANARY_EFF_WINDOW_DAYS, FLEET_CANARY_EFF_CATCH_HOURS,
  FLEET_CANARY_EFF_STORE, AGENT_STATE, XDG_RUNTIME_DIR, HOME
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

HOME = os.environ.get("HOME", "/home/nish")
AS = Path(os.environ.get("AGENT_STATE", f"{HOME}/workspaces/agent-state"))
OUT = Path(
    os.environ.get(
        "FLEET_CANARY_EFF_OUT",
        "/var/lib/prometheus/node-exporter/fleet-canary-effectiveness.prom",
    )
)
# Durable event store (fleet-ops#3052): Prometheus/journald retain only
# ~7d but the effectiveness window is 30d. Every tick merges the freshly
# observed events into this JSONL so the window is genuinely observable.
STORE = Path(
    os.environ.get(
        "FLEET_CANARY_EFF_STORE",
        str(AS / "canary-effectiveness" / "events.jsonl"),
    )
)
PROM_URL = os.environ.get(
    "FLEET_CANARY_EFF_PROM_URL", "http://127.0.0.1:9090"
).rstrip("/")
GH = os.environ.get("FLEET_CANARY_EFF_GH", "gh")
JOURNALCTL = os.environ.get("FLEET_CANARY_EFF_JOURNALCTL", "journalctl")
EVENTS_FILE = os.environ.get("FLEET_CANARY_EFF_EVENTS", "")
NOW_ISO = os.environ.get("FLEET_CANARY_EFF_NOW", "")
WINDOW_DAYS = int(os.environ.get("FLEET_CANARY_EFF_WINDOW_DAYS", "30"))
CATCH_HOURS = int(os.environ.get("FLEET_CANARY_EFF_CATCH_HOURS", "24"))
XDG = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
PROM_TIMEOUT = 20
GH_TIMEOUT = 30
JOURNAL_TIMEOUT = 20

HELP_RUNS = (
    "# HELP fleet_canary_runs_total Canary executions observed in the "
    "trailing effectiveness window, per organ (fleet-ops#2757)."
)
TYPE_RUNS = "# TYPE fleet_canary_runs_total gauge"
HELP_FAIL = (
    "# HELP fleet_canary_failures_total Canary failure events in the "
    "trailing effectiveness window, per organ (fleet-ops#2757)."
)
TYPE_FAIL = "# TYPE fleet_canary_failures_total gauge"
HELP_CAUGHT = (
    "# HELP fleet_canary_caught_regressions_total User-facing incidents "
    "preceded by a canary failure within the catch window, per organ "
    "(fleet-ops#2757)."
)
TYPE_CAUGHT = "# TYPE fleet_canary_caught_regressions_total gauge"
HELP_MISSED = (
    "# HELP fleet_canary_missed_regressions_total User-facing incidents "
    "with no prior canary failure in the catch window, per organ "
    "(fleet-ops#2757)."
)
TYPE_MISSED = "# TYPE fleet_canary_missed_regressions_total gauge"
HELP_RATIO = (
    "# HELP fleet_canary_effectiveness_ratio caught / (caught + missed) "
    "over the trailing window, per organ. 0 when no incidents. "
    "(fleet-ops#2757)."
)
TYPE_RATIO = "# TYPE fleet_canary_effectiveness_ratio gauge"
HELP_LAST_FAIL = (
    "# HELP fleet_canary_last_failure_seconds Epoch of the most recent "
    "canary failure in the window, per organ. 0 when none "
    "(fleet-ops#2757)."
)
TYPE_LAST_FAIL = "# TYPE fleet_canary_last_failure_seconds gauge"
HELP_HB = (
    "# HELP fleet_canary_effectiveness_last_run_seconds Epoch of the last "
    "canary-effectiveness export tick (organ heartbeat, fleet-ops#2757)."
)
TYPE_HB = "# TYPE fleet_canary_effectiveness_last_run_seconds gauge"
HELP_DRILL = (
    "# HELP fleet_canary_effectiveness_drill_last_green_seconds Epoch of the "
    "last exporter tick whose injected-fault drill passed; 0 = drill red "
    "(fleet-ops#3055)."
)
TYPE_DRILL = "# TYPE fleet_canary_effectiveness_drill_last_green_seconds gauge"
HELP_DRILL_OK = (
    "# HELP fleet_canary_effectiveness_drill_ok 1 if the injected-fault "
    "drill passed on this tick, else 0 (fleet-ops#3055)."
)
TYPE_DRILL_OK = "# TYPE fleet_canary_effectiveness_drill_ok gauge"


@dataclass(frozen=True)
class Organ:
    name: str
    product_repos: tuple[str, ...]
    # Prometheus gauge that is 0 on failure / 1 on success (optional).
    failure_metric: str | None = None
    failure_labels: dict[str, str] = field(default_factory=dict)
    # Gauge whose value changes (or is refreshed) on each run (optional).
    run_metric: str | None = None
    run_labels: dict[str, str] = field(default_factory=dict)
    # systemd user unit whose Result= is scraped from the journal (optional).
    unit: str | None = None


ORGANS: tuple[Organ, ...] = (
    Organ(
        name="0509-surface-probe",
        product_repos=("Nishfleet/0509",),
        failure_metric="fleet_probe_success",
        failure_labels={"probe": "0509-surface"},
        run_metric="fleet_surface_probe_last_run_seconds",
        run_labels={"probe": "0509-surface"},
    ),
    Organ(
        name="fleet-completion-canary",
        product_repos=("Nishfleet/fleet-ops",),
        unit="fleet-completion-canary.service",
    ),
    Organ(
        name="siterep-live-canary",
        product_repos=("Nishfleet/siterep-public",),
        unit="siterep-live-canary.service",
    ),
    Organ(
        name="fleet-resilience-drill",
        # Daily oneshot — count runs/failures from the unit journal, not
        # from the always-on all_pass gauge (that gauge is scraped every
        # 15s and would inflate runs_total by ~5000x).
        product_repos=("Nishfleet/fleet-ops",),
        unit="fleet-resilience-drill.service",
    ),
)


def now_dt() -> datetime:
    if NOW_ISO:
        return parse_iso(NOW_ISO) or datetime.now(timezone.utc)
    return datetime.now(timezone.utc)


def parse_iso(value: str | None) -> datetime | None:
    text = (value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        try:
            dt = datetime.strptime(text[:19], "%Y-%m-%dT%H:%M:%S").replace(
                tzinfo=timezone.utc
            )
        except ValueError:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def prom_label(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace("\n", "\\n")
        .replace('"', '\\"')
    )


def selector(metric: str, labels: dict[str, str]) -> str:
    if not labels:
        return metric
    inner = ",".join(
        f'{k}="{prom_label(v)}"' for k, v in sorted(labels.items())
    )
    return f"{metric}{{{inner}}}"


# --- Correlation (pure; offline-testable) ---------------------------------


@dataclass(frozen=True)
class Event:
    organ: str
    ts: float  # unix epoch seconds
    kind: str  # "run" | "failure"
    detail: str = ""


@dataclass(frozen=True)
class Incident:
    repo: str
    ts: float
    number: int
    labels: tuple[str, ...] = ()
    title: str = ""


@dataclass
class OrganStats:
    organ: str
    runs: int = 0
    failures: int = 0
    caught: int = 0
    missed: int = 0
    last_failure_seconds: float = 0.0

    @property
    def effectiveness_ratio(self) -> float:
        denom = self.caught + self.missed
        if denom <= 0:
            return 0.0
        return self.caught / denom


def correlate(
    failures: Iterable[Event],
    incidents: Iterable[Incident],
    *,
    catch_hours: int = CATCH_HOURS,
) -> tuple[list[Incident], list[Incident]]:
    """Split incidents into caught vs missed under the 24h prior-failure rule.

    An incident is caught when at least one canary failure for the SAME organ
    (caller pre-filters) lands in (incident.ts - catch_hours, incident.ts].
    """
    fail_ts = sorted(f.ts for f in failures)
    catch = catch_hours * 3600
    caught: list[Incident] = []
    missed: list[Incident] = []
    for inc in sorted(incidents, key=lambda i: i.ts):
        prior = [t for t in fail_ts if 0 < (inc.ts - t) <= catch]
        if prior:
            caught.append(inc)
        else:
            missed.append(inc)
    return caught, missed


def observe_since(events: Iterable[Event]) -> float | None:
    """Earliest observed run or failure for this organ, or None if never seen.

    Incidents before this instant cannot be missed-by-canary: the organ was
    not yet watching. A canary with no observed events therefore contributes
    zero caught and zero missed (ratio stays 0 and the Low alert stays quiet
    because caught+missed==0).
    """
    stamps = [e.ts for e in events if e.kind in {"run", "failure"}]
    if not stamps:
        return None
    return min(stamps)


def stats_for_organ(
    organ: Organ,
    events: list[Event],
    incidents: list[Incident],
    *,
    catch_hours: int = CATCH_HOURS,
) -> OrganStats:
    org_events = [e for e in events if e.organ == organ.name]
    runs = sum(1 for e in org_events if e.kind == "run")
    fails = [e for e in org_events if e.kind == "failure"]
    repos = set(organ.product_repos)
    since = observe_since(org_events)
    org_incidents = [
        i
        for i in incidents
        if i.repo in repos and since is not None and i.ts >= since
    ]
    caught, missed = correlate(fails, org_incidents, catch_hours=catch_hours)
    last_fail = max((e.ts for e in fails), default=0.0)
    return OrganStats(
        organ=organ.name,
        runs=runs,
        failures=len(fails),
        caught=len(caught),
        missed=len(missed),
        last_failure_seconds=last_fail,
    )


# --- Live collectors ------------------------------------------------------


def _http_json(
    url: str,
    path: str,
    params: dict[str, str],
    timeout: float = PROM_TIMEOUT,
) -> dict[str, Any]:
    qs = urllib.parse.urlencode(params)
    full = f"{url}{path}?{qs}"
    req = urllib.request.Request(full, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # nosemgrep
        return json.loads(resp.read().decode())


def _query_range(
    query: str,
    start: float,
    end: float,
    step: int = 300,
) -> list[tuple[float, float]]:
    """Return [(ts, value), ...] for the first matching series."""
    try:
        payload = _http_json(
            PROM_URL,
            "/api/v1/query_range",
            {
                "query": query,
                "start": str(start),
                "end": str(end),
                "step": str(step),
            },
        )
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, json.JSONDecodeError) as exc:
        print(f"canary-effectiveness: query_range failed: {exc}", file=sys.stderr)
        return []
    if payload.get("status") != "success":
        return []
    result = (payload.get("data") or {}).get("result") or []
    if not result:
        return []
    values = result[0].get("values") or []
    out: list[tuple[float, float]] = []
    for ts, val in values:
        try:
            out.append((float(ts), float(val)))
        except (TypeError, ValueError):
            continue
    return out


def events_from_gauge_failures(
    organ: Organ,
    start: float,
    end: float,
) -> list[Event]:
    """Derive run + failure events from Prometheus gauges.

    Failures: each transition of failure_metric into value==0 (plus a
    leading 0 sample) is one failure.

    Runs: prefer run_metric value changes (e.g. last_run_seconds bumps on
    each real probe). Fall back to counting failure_metric samples only
    when no run_metric is configured — never both, or scrapes inflate
    runs_total.

    The query window is anchored to a fixed 5-min wall-clock grid
    (fleet-ops#3052): query_range sample times are start + k*step, so an
    un-aligned start shifts the sample instants on every tick and the
    durable event store would re-add shifted duplicates each run.
    """
    start = float(int(start / 300) * 300)
    events: list[Event] = []
    if organ.failure_metric:
        points = _query_range(
            selector(organ.failure_metric, organ.failure_labels), start, end
        )
        prev: float | None = None
        for ts, val in points:
            if val == 0.0 and (prev is None or prev != 0.0):
                events.append(
                    Event(
                        organ=organ.name,
                        ts=ts,
                        kind="failure",
                        detail=f"{organ.failure_metric}=0",
                    )
                )
            prev = val
        if not organ.run_metric:
            # No dedicated run metric: each sample is the best proxy.
            for ts, _val in points:
                events.append(Event(organ=organ.name, ts=ts, kind="run"))
    if organ.run_metric:
        run_pts = _query_range(
            selector(organ.run_metric, organ.run_labels), start, end
        )
        prev_v: float | None = None
        for ts, val in run_pts:
            if prev_v is None or val != prev_v:
                events.append(Event(organ=organ.name, ts=ts, kind="run"))
            prev_v = val
    return events


def events_from_unit_journal(
    organ: Organ,
    start: datetime,
    end: datetime,
) -> list[Event]:
    """Derive run/failure events from systemd user-unit journal Result= lines."""
    if not organ.unit:
        return []
    env = os.environ.copy()
    env["XDG_RUNTIME_DIR"] = XDG
    cmd = [
        JOURNALCTL,
        "--user",
        "-u",
        organ.unit,
        "--since",
        start.strftime("%Y-%m-%d %H:%M:%S UTC"),
        "--until",
        end.strftime("%Y-%m-%d %H:%M:%S UTC"),
        "-o",
        "json",
        "--no-pager",
    ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=JOURNAL_TIMEOUT,
            env=env,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"canary-effectiveness: journalctl failed: {exc}", file=sys.stderr)
        return []
    events: list[Event] = []
    unit_short = organ.unit.replace(".service", "")
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        # Only systemd's own unit-lifecycle lines (SYSLOG_IDENTIFIER=systemd).
        # Application log lines from the canary itself contain the words
        # "fail"/"Failed" constantly (UNREPAIRED-FAIL, fail_loud, FLAG:)
        # and must NOT count as unit failures.
        ident = str(row.get("SYSLOG_IDENTIFIER") or row.get("_COMM") or "")
        if ident not in {"systemd", "systemd-run"}:
            continue
        msg = str(row.get("MESSAGE") or "")
        ts_usec = row.get("__REALTIME_TIMESTAMP") or row.get("_SOURCE_REALTIME_TIMESTAMP")
        try:
            ts = int(ts_usec) / 1_000_000.0
        except (TypeError, ValueError):
            continue
        lower = msg.lower()
        if lower.startswith("finished ") and unit_short in lower:
            events.append(Event(organ=organ.name, ts=ts, kind="run", detail="finished"))
        elif "failed with result" in lower and unit_short in lower:
            events.append(
                Event(organ=organ.name, ts=ts, kind="failure", detail=msg[:160])
            )
            events.append(Event(organ=organ.name, ts=ts, kind="run", detail="failed-run"))
        elif "unit entered failed state" in lower and unit_short in lower:
            events.append(
                Event(organ=organ.name, ts=ts, kind="failure", detail=msg[:160])
            )
    return events


def load_incidents_gh(
    repos: Iterable[str],
    start: datetime,
    end: datetime,
) -> list[Incident]:
    """Pull bug/regression-labeled issues created inside the window."""
    since = start.strftime("%Y-%m-%d")
    incidents: list[Incident] = []
    for repo in repos:
        # Two searches keep the query simple under gh's search syntax.
        for label in ("bug", "regression"):
            q = f"label:{label} created:>={since}"
            cmd = [
                GH,
                "issue",
                "list",
                "-R",
                repo,
                "--state",
                "all",
                "--search",
                q,
                "--limit",
                "100",
                "--json",
                "number,createdAt,labels,title",
            ]
            try:
                proc = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=GH_TIMEOUT,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                print(
                    f"canary-effectiveness: gh issue list failed for {repo}: {exc}",
                    file=sys.stderr,
                )
                continue
            if proc.returncode != 0:
                print(
                    f"canary-effectiveness: gh issue list rc={proc.returncode} "
                    f"for {repo} label={label}: {proc.stderr.strip()[:200]}",
                    file=sys.stderr,
                )
                continue
            try:
                rows = json.loads(proc.stdout or "[]")
            except json.JSONDecodeError:
                continue
            for row in rows:
                created = parse_iso(row.get("createdAt"))
                if created is None:
                    continue
                ts = created.timestamp()
                if ts < start.timestamp() or ts > end.timestamp():
                    continue
                labels = tuple(
                    (lab.get("name") if isinstance(lab, dict) else str(lab))
                    for lab in (row.get("labels") or [])
                )
                incidents.append(
                    Incident(
                        repo=repo,
                        ts=ts,
                        number=int(row.get("number") or 0),
                        labels=labels,
                        title=str(row.get("title") or ""),
                    )
                )
    # Dedupe (bug+regression double-hit).
    seen: set[tuple[str, int]] = set()
    uniq: list[Incident] = []
    for inc in incidents:
        key = (inc.repo, inc.number)
        if key in seen:
            continue
        seen.add(key)
        uniq.append(inc)
    return uniq


# --- Durable event store (fleet-ops#3052) --------------------------------
#
# The effectiveness window is a trailing 30d but the live sources retain
# only ~7d. Without a store, observe_since drifts forward as events age
# out, so real incidents older than ~7d are silently re-ignored and
# effectiveness can never be demonstrated. The store keeps every observed
# event for WINDOW_DAYS so the window is real and attribution is stable.


def event_keys(events: Iterable[Event]) -> set[tuple[str, float, str, str]]:
    return {(e.organ, e.ts, e.kind, e.detail) for e in events}


def merge_events(
    existing: Iterable[Event], fresh: Iterable[Event]
) -> list[Event]:
    """Union of two event collections, deduped by (organ, ts, kind, detail).

    The same canary failure is re-observed on consecutive ticks while it
    is still inside retention; the store must not double-count it.
    """
    seen: set[tuple[str, float, str, str]] = set()
    out: list[Event] = []
    for e in list(existing) + list(fresh):
        key = (e.organ, e.ts, e.kind, e.detail)
        if key in seen:
            continue
        seen.add(key)
        out.append(e)
    return out


def prune_events(
    events: Iterable[Event],
    end: datetime,
    window_days: int = WINDOW_DAYS,
) -> list[Event]:
    cutoff = (end - timedelta(days=window_days)).timestamp()
    return [e for e in events if e.ts >= cutoff]


def store_load(path: Path = STORE) -> list[Event]:
    """Read the JSONL event store; corrupt/unknown lines are skipped."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return []
    except OSError as exc:
        print(f"canary-effectiveness: store read failed: {exc}", file=sys.stderr)
        return []
    out: list[Event] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
            out.append(
                Event(
                    organ=str(row["organ"]),
                    ts=float(row["ts"]),
                    kind=str(row["kind"]),
                    detail=str(row.get("detail") or ""),
                )
            )
        except (KeyError, TypeError, ValueError):
            continue
    return out


def store_save(path: Path, events: Iterable[Event]) -> None:
    """Atomically rewrite the store (JSONL, ts-sorted)."""
    ordered = sorted(events, key=lambda e: (e.ts, e.organ, e.kind, e.detail))
    body = "".join(
        json.dumps(
            {"organ": e.organ, "ts": e.ts, "kind": e.kind, "detail": e.detail},
            sort_keys=True,
        )
        + "\n"
        for e in ordered
    )
    _atomic_write(path, body)


def load_fixture_events(path: str) -> tuple[list[Event], list[Incident]]:
    """Load offline fixture: {events:[{organ,ts,kind}], incidents:[...]}."""
    data = json.loads(Path(path).read_text())
    events = [
        Event(
            organ=str(e["organ"]),
            ts=float(e["ts"]),
            kind=str(e["kind"]),
            detail=str(e.get("detail") or ""),
        )
        for e in (data.get("events") or [])
    ]
    incidents = [
        Incident(
            repo=str(i["repo"]),
            ts=float(i["ts"]),
            number=int(i.get("number") or 0),
            labels=tuple(i.get("labels") or ()),
            title=str(i.get("title") or ""),
        )
        for i in (data.get("incidents") or [])
    ]
    return events, incidents


def collect_live(start: datetime, end: datetime) -> tuple[list[Event], list[Incident]]:
    events: list[Event] = []
    for organ in ORGANS:
        if organ.failure_metric:
            events.extend(
                events_from_gauge_failures(
                    organ, start.timestamp(), end.timestamp()
                )
            )
        if organ.unit:
            events.extend(events_from_unit_journal(organ, start, end))
    repos: list[str] = []
    for organ in ORGANS:
        for r in organ.product_repos:
            if r not in repos:
                repos.append(r)
    incidents = load_incidents_gh(repos, start, end)
    return events, incidents


# --- Export ---------------------------------------------------------------


def export_prom(
    stats: list[OrganStats],
    *,
    now: datetime,
    out: Path = OUT,
    drill_ok: int | None = None,
    drill_green: float | None = None,
) -> str:
    lines: list[str] = [
        HELP_RUNS,
        TYPE_RUNS,
    ]
    for s in stats:
        lines.append(
            f'fleet_canary_runs_total{{organ="{prom_label(s.organ)}"}} {s.runs}'
        )
    lines += ["", HELP_FAIL, TYPE_FAIL]
    for s in stats:
        lines.append(
            f'fleet_canary_failures_total{{organ="{prom_label(s.organ)}"}} {s.failures}'
        )
    lines += ["", HELP_CAUGHT, TYPE_CAUGHT]
    for s in stats:
        lines.append(
            f'fleet_canary_caught_regressions_total{{organ="{prom_label(s.organ)}"}} {s.caught}'
        )
    lines += ["", HELP_MISSED, TYPE_MISSED]
    for s in stats:
        lines.append(
            f'fleet_canary_missed_regressions_total{{organ="{prom_label(s.organ)}"}} {s.missed}'
        )
    lines += ["", HELP_RATIO, TYPE_RATIO]
    for s in stats:
        lines.append(
            f'fleet_canary_effectiveness_ratio{{organ="{prom_label(s.organ)}"}} '
            f"{s.effectiveness_ratio:.6f}"
        )
    lines += ["", HELP_LAST_FAIL, TYPE_LAST_FAIL]
    for s in stats:
        lines.append(
            f'fleet_canary_last_failure_seconds{{organ="{prom_label(s.organ)}"}} '
            f"{int(s.last_failure_seconds)}"
        )
    if drill_ok is not None:
        lines += [
            "",
            HELP_DRILL,
            TYPE_DRILL,
            f"fleet_canary_effectiveness_drill_last_green_seconds "
            f"{int(drill_green or 0)}",
            "",
            HELP_DRILL_OK,
            TYPE_DRILL_OK,
            f"fleet_canary_effectiveness_drill_ok {1 if drill_ok else 0}",
        ]
    lines += [
        "",
        HELP_HB,
        TYPE_HB,
        f"fleet_canary_effectiveness_last_run_seconds {int(now.timestamp())}",
        "",
    ]
    body = "\n".join(lines)
    _atomic_write(out, body)
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


def compute_all(
    events: list[Event],
    incidents: list[Incident],
    *,
    catch_hours: int = CATCH_HOURS,
) -> list[OrganStats]:
    return [
        stats_for_organ(organ, events, incidents, catch_hours=catch_hours)
        for organ in ORGANS
    ]


def run_live_drill(now: datetime) -> tuple[int, float]:
    """Run the hermetic injected-fault drill inside the live exporter tick
    (fleet-ops#3055). Returns (ok, last_green_seconds): ok=1 with
    last_green=now when the drill passes; ok=0 with last_green=0 when it
    fails. The gauge only advances on a passing drill, so a silent
    classify regression (the 2026-09-02 class that pinned caught=0 for
    19h while no drill ran anywhere) goes red/stale and the
    FleetCanaryEffectivenessDrillStale alert fires instead of waiting for
    the next real incident.

    Hermetic by construction: self_test() drives the real main() against
    its own temp store + fixture events (never the live store or the real
    node-exporter path), so this costs a few milliseconds per tick.
    Never raises — a drill fault must not fail the exporter.
    """
    buf = io.StringIO()
    rc = 1
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        try:
            rc = self_test()
        except Exception as exc:  # noqa: BLE001 — never fail the exporter
            print(f"canary-effectiveness: live drill crashed: {exc}", file=buf)
            rc = 1
    detail = buf.getvalue()
    if rc != 0:
        print(
            f"canary-effectiveness: DRILL RED: {detail.strip()[:400]}",
            file=sys.stderr,
        )
    else:
        # A green live detection must be journal-visible, not only a
        # gauge (fleet-ops#3060): the exporter tick's stderr proves the
        # injected fault was caught end to end every cycle. Silent-green
        # was the exact failure mode that let 2026-09-02's caught=0 run
        # 19h with no evidence either way.
        summary = next(
            (
                ln.strip()
                for ln in reversed(detail.splitlines())
                if ln.strip().startswith("SELF-TEST ")
            ),
            detail.strip()[:400],
        )
        print(
            f"canary-effectiveness: DRILL GREEN: {summary}",
            file=sys.stderr,
        )
    return (1, now.timestamp()) if rc == 0 else (0, 0.0)


def self_test() -> int:
    """Inject a synthetic canary failure + incident within the 24h catch
    window and prove the emitter classifies it as caught, end-to-end through
    the real main() -> store -> compute_all -> export_prom pipeline
    (fleet-ops#3047, #3052).

    The live exporter reported caught=0 across all organs because the 30d
    incident window exceeds the ~7d retention of Prometheus/journald, so
    every real incident predates the earliest observable canary failure and
    is honestly unclassifiable. #3047 proved the classify path with a
    synthetic fault; #3052 adds the durable event store that closes the
    retention gap. This drill proves BOTH halves:

      tick 1: a probe failure at T-2h and a bug issue 1h later in the same
              product repo are injected through the real main() path and
              must export caught=1, ratio=1.0.
      tick 2: the live source no longer returns the failure (retention
              loss simulated: empty live events). The store must retain the
              failure so the same incident is STILL caught=1. Without the
              store this tick would drop to caught=0 — the exact silent
              regression this issue escalated on.
    """
    end = 1_788_350_400.0  # deterministic 2026-09-02T12:00:00Z
    fail_ts = end - 7200.0
    inc_ts = end - 3600.0
    incident = {
        "repo": "Nishfleet/0509",
        "ts": inc_ts,
        "number": 999999,
        "labels": ["bug"],
        "title": "self-test injected regression",
    }
    tmpdir = tempfile.mkdtemp(prefix="canary-selftest.")
    saved_env = {
        k: os.environ.get(k)
        for k in (
            "FLEET_CANARY_EFF_EVENTS",
            "FLEET_CANARY_EFF_STORE",
            "FLEET_CANARY_EFF_NOW",
            "FLEET_CANARY_EFF_OUT",
        )
    }
    try:
        store = Path(tmpdir) / "events.jsonl"
        fixture1 = Path(tmpdir) / "tick1.json"
        fixture2 = Path(tmpdir) / "tick2.json"
        fixture1.write_text(
            json.dumps(
                {
                    "events": [
                        {
                            "organ": "0509-surface-probe",
                            "ts": fail_ts,
                            "kind": "run",
                            "detail": "self-test run",
                        },
                        {
                            "organ": "0509-surface-probe",
                            "ts": fail_ts,
                            "kind": "failure",
                            "detail": "self-test injected failure",
                        },
                    ],
                    "incidents": [incident],
                }
            )
        )
        # Tick 2 loses the canary events: the live source only retains
        # ~7d while the incident window is 30d — the retention gap the
        # durable store closes (fleet-ops#3052).
        fixture2.write_text(json.dumps({"events": [], "incidents": [incident]}))
        os.environ["FLEET_CANARY_EFF_STORE"] = str(store)
        os.environ["FLEET_CANARY_EFF_NOW"] = datetime.fromtimestamp(
            end, tz=timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        for tick, fixture in (("tick1", fixture1), ("tick2", fixture2)):
            os.environ["FLEET_CANARY_EFF_EVENTS"] = str(fixture)
            out_path = Path(tmpdir) / f"{tick}.prom"
            os.environ["FLEET_CANARY_EFF_OUT"] = str(out_path)
            if main(["--stdout"]) != 0:
                print(f"SELF-TEST FAIL: {tick} main() rc != 0", file=sys.stderr)
                return 1
            if not out_path.exists():
                print(
                    f"SELF-TEST FAIL: {tick} did not write the prom file",
                    file=sys.stderr,
                )
                return 1
            body = out_path.read_text()
            if (
                'fleet_canary_caught_regressions_total{organ="0509-surface-probe"} 1'
                not in body
            ):
                print(
                    f"SELF-TEST FAIL: {tick} missing caught=1 line; without the "
                    f"durable store the retention-loss tick cannot attribute",
                    file=sys.stderr,
                )
                return 1
            if (
                'fleet_canary_effectiveness_ratio{organ="0509-surface-probe"} 1.000000'
                not in body
            ):
                print(
                    f"SELF-TEST FAIL: {tick} ratio != 1.0",
                    file=sys.stderr,
                )
                return 1
        # Dedup: the store must hold exactly the two tick-1 events, not a
        # re-observation copy from tick 2.
        if len(store_load(store)) != 2:
            print(
                f"SELF-TEST FAIL: store dedup broken, {len(store_load(store))} "
                f"events instead of 2",
                file=sys.stderr,
            )
            return 1
        print("SELF-TEST OK: injected fault detected (caught=1, ratio=1.0)")
        return 0
    finally:
        for k, v in saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(tmpdir, ignore_errors=True)


def usage() -> int:
    print(
        "usage: canary-effectiveness.py [--stdout] [--self-test] [--help]\n"
        "  Computes canary effectiveness metrics and writes\n"
        f"  {OUT} (override with FLEET_CANARY_EFF_OUT).\n"
        "  Offline fixture: FLEET_CANARY_EFF_EVENTS=/path/to.json\n"
        "  --self-test: inject a synthetic fault and prove it is caught.\n"
        "  Each live tick also runs the hermetic self-test drill and exports\n"
        "  drill_ok / drill_last_green_seconds (fleet-ops#3055).",
        file=sys.stderr,
    )
    return 2


def main(argv: list[str] | None = None) -> int:
    argv = list(argv if argv is not None else sys.argv[1:])
    to_stdout = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            return usage()
        if a == "--self-test":
            return self_test()
        if a == "--stdout":
            to_stdout = True
            i += 1
            continue
        print(f"canary-effectiveness: unknown flag {a}", file=sys.stderr)
        return usage()

    end = now_dt()
    start = end - timedelta(days=WINDOW_DAYS)
    # Resolve per-call so tests and --self-test can point the exporter at
    # hermetic paths at runtime (production defaults stay module-level).
    out = Path(os.environ.get("FLEET_CANARY_EFF_OUT", str(OUT)))
    store_path = Path(os.environ.get("FLEET_CANARY_EFF_STORE", str(STORE)))
    events_file = os.environ.get("FLEET_CANARY_EFF_EVENTS", "")
    try:
        if events_file:
            fresh, incidents = load_fixture_events(events_file)
        else:
            fresh, incidents = collect_live(start, end)
        # Durable event store (fleet-ops#3052): Prometheus query_range and
        # journald only retain ~7d but the window is 30d. Merge each
        # tick's observed events into the store so the window is genuinely
        # observable and attribution stops flipping as old events age out
        # of retention.
        try:
            stored = store_load(store_path)
        except Exception as exc:  # noqa: BLE001 — never fail the export
            print(
                f"canary-effectiveness: store load failed: {exc}",
                file=sys.stderr,
            )
            stored = []
        events = prune_events(merge_events(stored, fresh), end)
        if event_keys(events) != event_keys(stored):
            try:
                store_save(store_path, events)
            except Exception as exc:  # noqa: BLE001
                print(
                    f"canary-effectiveness: store save failed: {exc}",
                    file=sys.stderr,
                )
        stats = compute_all(events, incidents)
        # Live-drill the classify path every tick (fleet-ops#3055): the
        # 2026-09-02 incident ran 19h with the exporter reporting
        # caught=0 while nothing live ever ran the injected-fault drill.
        # The drill is hermetic (temp store + fixtures); its result is
        # exported so a silent regression is visible within one alert
        # window instead of at the next real incident.
        drill_ok: int | None = None
        drill_green: float | None = None
        if not events_file:
            drill_ok, drill_green = run_live_drill(end)
        body = export_prom(
            stats,
            now=end,
            out=out,
            drill_ok=drill_ok,
            drill_green=drill_green,
        )
        if to_stdout:
            sys.stdout.write(body if body.endswith("\n") else body + "\n")
        print(
            f"canary-effectiveness: wrote {out} "
            f"({len(stats)} organs, {len(events)} events, "
            f"{len(incidents)} incidents)",
            file=sys.stderr,
        )
        return 0
    except Exception as exc:  # noqa: BLE001 — never fail the parent exporter
        print(f"canary-effectiveness failed: {exc}", file=sys.stderr)
        try:
            zeros = [
                OrganStats(organ=o.name) for o in ORGANS
            ]
            export_prom(zeros, now=end, out=out)
        except Exception as write_exc:  # noqa: BLE001
            print(
                f"canary-effectiveness zero-write failed: {write_exc}",
                file=sys.stderr,
            )
        return 0


if __name__ == "__main__":
    sys.exit(main())
