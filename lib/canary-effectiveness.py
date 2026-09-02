#!/usr/bin/env python3
"""Canary effectiveness metrics (fleet-ops#2757).

Correlates canary failure events with subsequent user-facing incidents so
the fleet can prove each canary organ catches regressions before users,
not only that the canary runs.

Metric family (trailing 30d window unless noted):

  fleet_canary_runs_total{organ=...}
  fleet_canary_failures_total{organ=...}
  fleet_canary_caught_regressions_total{organ=...}
  fleet_canary_missed_regressions_total{organ=...}
  fleet_canary_effectiveness_ratio{organ=...}   caught / (caught + missed)
  fleet_canary_last_failure_seconds{organ=...}  0 when no failure in window
  fleet_canary_effectiveness_last_run_seconds   organ heartbeat (always)

Attribution rule (issue accept §1):
  canary failure → incident in the same product surface within 24h
    = caught-by-canary
  incident with no prior canary failure in that 24h window
    = missed-by-canary

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
  XDG_RUNTIME_DIR, HOME
"""
from __future__ import annotations

import json
import os
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
OUT = Path(
    os.environ.get(
        "FLEET_CANARY_EFF_OUT",
        "/var/lib/prometheus/node-exporter/fleet-canary-effectiveness.prom",
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
    org_incidents = [i for i in incidents if i.repo in repos]
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
    """
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


def export_prom(stats: list[OrganStats], *, now: datetime) -> str:
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
    lines += [
        "",
        HELP_HB,
        TYPE_HB,
        f"fleet_canary_effectiveness_last_run_seconds {int(now.timestamp())}",
        "",
    ]
    body = "\n".join(lines)
    _atomic_write(OUT, body)
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


def usage() -> int:
    print(
        "usage: canary-effectiveness.py [--stdout] [--help]\n"
        "  Computes canary effectiveness metrics and writes\n"
        f"  {OUT} (override with FLEET_CANARY_EFF_OUT).\n"
        "  Offline fixture: FLEET_CANARY_EFF_EVENTS=/path/to.json",
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
        if a == "--stdout":
            to_stdout = True
            i += 1
            continue
        print(f"canary-effectiveness: unknown flag {a}", file=sys.stderr)
        return usage()

    end = now_dt()
    start = end - timedelta(days=WINDOW_DAYS)
    try:
        if EVENTS_FILE:
            events, incidents = load_fixture_events(EVENTS_FILE)
        else:
            events, incidents = collect_live(start, end)
        stats = compute_all(events, incidents)
        body = export_prom(stats, now=end)
        if to_stdout:
            sys.stdout.write(body if body.endswith("\n") else body + "\n")
        print(
            f"canary-effectiveness: wrote {OUT} "
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
            export_prom(zeros, now=end)
        except Exception as write_exc:  # noqa: BLE001
            print(
                f"canary-effectiveness zero-write failed: {write_exc}",
                file=sys.stderr,
            )
        return 0


if __name__ == "__main__":
    sys.exit(main())
