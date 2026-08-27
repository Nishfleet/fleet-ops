#!/usr/bin/env python3
"""Loss-accounting metric family for the fleet metrics exporter (fleet-ops#1211).

The fleet counted activity and never waste. This writes fleet-waste.prom so
Prometheus can see, per lane per 24h: dispatches, completions, empty runs
(tools=0), retries of the same packet/issue, tokens when a source recorded
them, and merged PRs attributable to a run. Derived gauges:

  fleet_waste_ratio          spent-on-nonlanded / total
  fleet_lane_efficiency      completions / dispatches, per lane

Sources (the issue's list): dispatch ledger (#1009/#1147), alert-repair
actions.log, and the journal. PACKET-VERDICT lands in pi-issue *.out because
pi-issue-run redirects stdout; those receipts are the same lines the journal
would have held, so they are scanned too.

A drop-in on fleet-metrics-export.service runs this as a second ExecStart.
No new timer. Never fails the parent oneshot (errors still emit zeros).

Environment seams (tests):
  FLEET_DISPATCH_LEDGER, FLEET_WASTE_ACTIONS_LOG, FLEET_WASTE_JOURNAL,
  FLEET_WASTE_RECEIPTS_DIR, FLEET_WASTE_OUT, FLEET_WASTE_NOW, AGENT_STATE,
  FLEET_WASTE_JOURNALCTL, XDG_RUNTIME_DIR
"""
from __future__ import annotations

import calendar
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = os.environ.get("HOME", "/home/nish")
AS = Path(os.environ.get("AGENT_STATE", f"{HOME}/workspaces/agent-state"))
LEDGER = Path(os.environ.get("FLEET_DISPATCH_LEDGER", str(AS / "dispatch-ledger.jsonl")))
ACTIONS_LOG = Path(
    os.environ.get(
        "FLEET_WASTE_ACTIONS_LOG",
        str(AS / "alert-repair" / "actions.log"),
    )
)
RECEIPTS_DIR = Path(
    os.environ.get("FLEET_WASTE_RECEIPTS_DIR", f"{HOME}/.local/state/pi-issues")
)
JOURNAL_DUMP = os.environ.get("FLEET_WASTE_JOURNAL", "")
JOURNALCTL = os.environ.get("FLEET_WASTE_JOURNALCTL", "journalctl")
OUT = Path(
    os.environ.get(
        "FLEET_WASTE_OUT",
        "/var/lib/prometheus/node-exporter/fleet-waste.prom",
    )
)
NOW_ISO = os.environ.get("FLEET_WASTE_NOW", "")
XDG = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
JOURNAL_TIMEOUT = 15

HELP_RUNS = "# HELP fleet_waste_runs Dispatch-plane run counts in the trailing window by kind. kind=total is the organ heartbeat (always emitted)."
TYPE_RUNS = "# TYPE fleet_waste_runs gauge"
HELP_DISP = "# HELP fleet_waste_dispatches_24h Packet dispatches in the trailing 24h by lane."
TYPE_DISP = "# TYPE fleet_waste_dispatches_24h gauge"
HELP_COMP = "# HELP fleet_waste_completions_24h Runs that finished with tools>0 (or a completed ledger/actions receipt) in the trailing 24h by lane."
TYPE_COMP = "# TYPE fleet_waste_completions_24h gauge"
HELP_EMPTY = "# HELP fleet_waste_empty_runs_24h Dead/empty runs (PACKET-VERDICT tools=0 / class=no-tools) in the trailing 24h by lane."
TYPE_EMPTY = "# TYPE fleet_waste_empty_runs_24h gauge"
HELP_RETRY = "# HELP fleet_waste_retries_24h Extra dispatches of the same packet/issue in the trailing 24h by lane."
TYPE_RETRY = "# TYPE fleet_waste_retries_24h gauge"
HELP_TOK = "# HELP fleet_waste_tokens_24h Tokens recorded in ledger/journal in the trailing 24h by lane. 0 when the sources did not record tokens."
TYPE_TOK = "# TYPE fleet_waste_tokens_24h gauge"
HELP_PR = "# HELP fleet_waste_merged_prs_24h Merged PRs attributable to a run in the trailing 24h by lane."
TYPE_PR = "# TYPE fleet_waste_merged_prs_24h gauge"
HELP_RATIO = "# HELP fleet_waste_ratio Spend on non-landed work / total spend, trailing 24h. 0..1. Omitted when total=0."
TYPE_RATIO = "# TYPE fleet_waste_ratio gauge"
HELP_EFF = "# HELP fleet_lane_efficiency Completions / dispatches per lane, trailing 24h. 0..1. Omitted when dispatches=0."
TYPE_EFF = "# TYPE fleet_lane_efficiency gauge"

VERDICT_RE = re.compile(r"PACKET-VERDICT\s+tools=(\d+)\s+class=(\S+)")
ACTIONS_TS_RE = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z\]")
SEAT_RE = re.compile(r"\bseat=(\S+)")
UNIT_RE = re.compile(r"\bunit=(\S+)")
HEADER_RE = re.compile(
    r"^#\s*ts=(\S+)\s+lane=(\S+)(?:\s+unit=(\S+))?",
    re.I,
)
ISSUE_RE = re.compile(r"([A-Za-z0-9._-]+)-(\d+)$")
PR_RE = re.compile(r"https://github\.com/[^/\s]+/[^/\s]+/pull/\d+", re.I)
TOKEN_RE = re.compile(r"\btokens?=(\d+)\b", re.I)
SEAT_LOG_RE = re.compile(
    r"\bon ([A-Za-z0-9._-]+)/([A-Za-z0-9._/-]+)\b"
)
RUN_TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z\]")


def now_dt():
    if NOW_ISO:
        return parse_iso(NOW_ISO) or datetime.now(timezone.utc)
    return datetime.now(timezone.utc)


def parse_iso(value):
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


def epoch_of(dt):
    if dt is None:
        return None
    return calendar.timegm(dt.utctimetuple())


def in_window(dt, start, end):
    return dt is not None and start <= dt < end


def prom_label(s):
    return str(s).replace("\\", "\\\\").replace('"', '\\"')


def lane_of(provider="", model="", seat="", unit=""):
    seat = (seat or "").strip().strip(",")
    if seat and "/" in seat:
        return seat
    provider = (provider or "").strip()
    model = (model or "").strip()
    if provider and model:
        return f"{provider}/{model}"
    if provider:
        return provider
    u = (unit or "").replace(".service", "")
    if u:
        return f"unit:{u}"
    return "unknown"


def issue_key(unit="", packet_path="", chain_id=""):
    u = (unit or "").replace(".service", "")
    u = u.replace("pi-issue@", "").replace("pi-issue-", "")
    m = ISSUE_RE.search(u)
    if m:
        return f"{m.group(1)}#{m.group(2)}"
    chain_id = (chain_id or "").strip()
    if chain_id:
        return f"chain:{chain_id}"
    name = Path(packet_path or "").name
    if name:
        stem = name.rsplit(".", 1)[0]
        m = ISSUE_RE.search(stem)
        if m:
            return f"{m.group(1)}#{m.group(2)}"
        return f"pkt:{name}"
    return f"unit:{u or 'unknown'}"


def atomic_write(path, text):
    path = Path(path)
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
    os.chmod(path, 0o644)


def empty_lane():
    return {
        "dispatches": 0,
        "completions": 0,
        "empty_runs": 0,
        "retries": 0,
        "tokens": 0,
        "merged_prs": 0,
        "salvage": 0,
        "spend": 0,
        "waste_spend": 0,
    }


def load_ledger_events(path, start, end):
    events = []
    path = Path(path)
    if not path.is_file():
        return events
    try:
        raw_lines = path.read_text(errors="replace").splitlines()
    except OSError as exc:
        print(f"waste ledger: {exc}", file=sys.stderr)
        return events
    latest = {}
    order = []
    for raw in raw_lines:
        line = raw.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        rec_id = rec.get("id")
        key = str(rec_id) if rec_id else f"anon:{len(order)}"
        if key not in latest:
            order.append(key)
        latest[key] = rec
    seen_issue = set()
    for key in order:
        rec = latest[key]
        ts = parse_iso(rec.get("ts") or rec.get("salvage_ts") or rec.get("closed_ts"))
        if not in_window(ts, start, end):
            continue
        unit = rec.get("unit") or ""
        lane = lane_of(
            rec.get("provider") or "",
            rec.get("model") or "",
            rec.get("seat") or "",
            unit,
        )
        ikey = issue_key(unit, rec.get("packet_path") or "", rec.get("chain_id") or "")
        hop = int(rec.get("hop") or 0)
        retries = int(rec.get("retries") or 0)
        is_retry = hop > 0 or retries > 0 or ikey in seen_issue
        seen_issue.add(ikey)
        tokens = rec.get("tokens") or rec.get("token_count") or 0
        try:
            tokens = int(tokens)
        except (TypeError, ValueError):
            tokens = 0
        status = str(rec.get("status") or "")
        tools = rec.get("tools")
        empty = False
        if tools is not None:
            try:
                empty = int(tools) == 0
            except (TypeError, ValueError):
                empty = False
        if "no-tools" in status or status == "empty":
            empty = True
        complete = status.startswith("completed") or status in {"success", "resolved"}
        salvaged = bool(rec.get("salvaged_branch"))
        merged = bool(rec.get("pr_url") or rec.get("merged") or rec.get("merged_pr"))
        if rec.get("pr_url") and PR_RE.search(str(rec.get("pr_url"))):
            merged = True
        events.append(
            {
                "ts": ts,
                "lane": lane,
                "issue": ikey,
                "dispatch": True,
                "retry": is_retry,
                "empty": empty,
                "complete": complete and not empty,
                "salvage": salvaged,
                "merged": merged,
                "tokens": tokens,
            }
        )
    return events


def load_actions_events(path, start, end):
    events = []
    path = Path(path)
    if not path.is_file():
        return events
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError as exc:
        print(f"waste actions.log: {exc}", file=sys.stderr)
        return events
    seen_issue = set()
    for line in lines:
        m = ACTIONS_TS_RE.match(line)
        if not m:
            continue
        ts = parse_iso(m.group(1) + "Z")
        if not in_window(ts, start, end):
            continue
        rest = line[m.end():].lstrip()
        unit_m = UNIT_RE.search(rest)
        seat_m = SEAT_RE.search(rest)
        unit = unit_m.group(1) if unit_m else ""
        seat = seat_m.group(1) if seat_m else ""
        lane = lane_of(seat=seat, unit=unit)
        ikey = issue_key(unit, rest)
        pr = bool(PR_RE.search(rest))
        tokens = 0
        tm = TOKEN_RE.search(rest)
        if tm:
            tokens = int(tm.group(1))
        if rest.startswith("DISPATCH "):
            retry = ikey in seen_issue
            seen_issue.add(ikey)
            events.append(
                {
                    "ts": ts,
                    "lane": lane,
                    "issue": ikey,
                    "dispatch": True,
                    "retry": retry,
                    "empty": False,
                    "complete": False,
                    "salvage": False,
                    "merged": pr,
                    "tokens": tokens,
                }
            )
        elif rest.startswith("REDISPATCH "):
            seen_issue.add(ikey)
            events.append(
                {
                    "ts": ts,
                    "lane": lane,
                    "issue": ikey,
                    "dispatch": True,
                    "retry": True,
                    "empty": False,
                    "complete": False,
                    "salvage": False,
                    "merged": False,
                    "tokens": tokens,
                }
            )
        elif rest.startswith("RESOLVED "):
            events.append(
                {
                    "ts": ts,
                    "lane": lane,
                    "issue": ikey,
                    "dispatch": False,
                    "retry": False,
                    "empty": False,
                    "complete": True,
                    "salvage": False,
                    "merged": pr,
                    "tokens": tokens,
                }
            )
    return events


def _verdict_event(ts, lane, unit, tools, cls, extra_text=""):
    empty = tools == 0 or cls == "no-tools"
    tokens = 0
    tm = TOKEN_RE.search(extra_text or "")
    if tm:
        tokens = int(tm.group(1))
    merged = bool(PR_RE.search(extra_text or ""))
    return {
        "ts": ts,
        "lane": lane,
        "issue": issue_key(unit),
        "dispatch": False,
        "retry": False,
        "empty": empty,
        "complete": (not empty) and tools > 0,
        "salvage": False,
        "merged": merged,
        "tokens": tokens,
    }


def load_journal_text(text, start, end, default_lane="unknown"):
    events = []
    last_lane = default_lane
    last_unit = ""
    last_ts = None
    for raw in (text or "").splitlines():
        line = raw.rstrip("\n")
        # journalctl short-iso: "2026-08-27T04:20:00+00:00 host ... message"
        ts = None
        if len(line) >= 20 and line[4] == "-" and line[10] == "T":
            ts = parse_iso(line[:19] + "Z")
        hm = HEADER_RE.match(line)
        if hm:
            ts = parse_iso(hm.group(1))
            last_lane = hm.group(2)
            last_unit = hm.group(3) or last_unit
            last_ts = ts
        sm = SEAT_LOG_RE.search(line)
        if sm:
            last_lane = f"{sm.group(1)}/{sm.group(2)}"
        um = UNIT_RE.search(line)
        if um:
            last_unit = um.group(1)
        vm = VERDICT_RE.search(line)
        if not vm:
            continue
        if ts is None:
            ts = last_ts
        if not in_window(ts, start, end):
            continue
        events.append(
            _verdict_event(
                ts,
                last_lane or default_lane,
                last_unit,
                int(vm.group(1)),
                vm.group(2),
                line,
            )
        )
    return events


def load_journal_live(start, end):
    if JOURNAL_DUMP:
        try:
            text = Path(JOURNAL_DUMP).read_text(errors="replace")
        except OSError as exc:
            print(f"waste journal dump: {exc}", file=sys.stderr)
            return []
        return load_journal_text(text, start, end)
    # Live journalctl --grep over days hangs on this host. PACKET-VERDICT
    # is in pi-issue *.err receipts. Opt in with FLEET_WASTE_USE_JOURNALCTL=1.
    if os.environ.get("FLEET_WASTE_USE_JOURNALCTL", "0") != "1":
        return []
    since = start.strftime("%Y-%m-%d %H:%M:%S UTC")
    try:
        r = subprocess.run(
            [
                JOURNALCTL,
                "--user",
                "--since",
                since,
                "--no-pager",
                "--grep",
                "PACKET-VERDICT",
                "-o",
                "short-iso",
            ],
            capture_output=True,
            text=True,
            timeout=JOURNAL_TIMEOUT,
            env={**os.environ, "XDG_RUNTIME_DIR": XDG},
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"waste journalctl: {exc}", file=sys.stderr)
        return []
    if r.returncode not in (0, 1):
        print(f"waste journalctl rc={r.returncode}", file=sys.stderr)
        return []
    return load_journal_text(r.stdout or "", start, end)


def load_receipt_events(path, start, end):
    events = []
    path = Path(path)
    if not path.is_dir():
        return events
    files = []
    try:
        files.extend(path.glob("*.out"))
        files.extend(path.glob("*.err"))
    except OSError as exc:
        print(f"waste receipts: {exc}", file=sys.stderr)
        return events
    for fp in sorted(files):
        try:
            body = fp.read_text(errors="replace")
        except OSError:
            continue
        header_ts = None
        header_lane = None
        unit = fp.stem
        hm = HEADER_RE.search(body)
        if hm:
            header_ts = parse_iso(hm.group(1))
            header_lane = hm.group(2)
            unit = hm.group(3) or unit
        vm = VERDICT_RE.search(body)
        if not vm:
            continue
        ts = header_ts
        if ts is None:
            stamps = RUN_TS_RE.findall(body)
            if stamps:
                ts = parse_iso(stamps[-1] + "Z")
        if ts is None:
            try:
                ts = datetime.fromtimestamp(fp.stat().st_mtime, tz=timezone.utc)
            except OSError:
                continue
        if not in_window(ts, start, end):
            continue
        sm = SEAT_LOG_RE.search(body)
        lane = header_lane
        if sm:
            lane = f"{sm.group(1)}/{sm.group(2)}"
        events.append(
            _verdict_event(ts, lane, unit, int(vm.group(1)), vm.group(2), body)
        )
    return events


def collect_events(start, end, ledger=None, actions=None, receipts=None, journal=None):
    events = []
    events.extend(load_ledger_events(ledger or LEDGER, start, end))
    events.extend(load_actions_events(actions or ACTIONS_LOG, start, end))
    if journal is None:
        events.extend(load_journal_live(start, end))
    else:
        events.extend(load_journal_text(journal, start, end))
    events.extend(load_receipt_events(receipts or RECEIPTS_DIR, start, end))
    return dedupe_events(events)


def dedupe_events(events):
    """Collapse journal + *.out copies of the same PACKET-VERDICT line.

    Ledger hops and actions DISPATCH/REDISPATCH stay distinct — those are
    real extra runs, not two views of one line.
    """
    seen = set()
    out = []
    for ev in events:
        if ev.get("dispatch") or ev.get("salvage") or ev.get("merged"):
            out.append(ev)
            continue
        ts = ev.get("ts")
        stamp = ts.strftime("%Y-%m-%dT%H:%M") if ts is not None else ""
        key = (
            stamp,
            ev.get("lane"),
            ev.get("issue"),
            bool(ev.get("empty")),
            bool(ev.get("complete")),
        )
        if key in seen:
            continue
        seen.add(key)
        out.append(ev)
    return out


def aggregate(events):
    lanes = defaultdict(empty_lane)
    landed = set()
    issue_lane = {}
    for ev in events:
        if ev.get("merged"):
            landed.add(ev["issue"])
        issue_lane.setdefault(ev["issue"], ev["lane"])
    for ev in events:
        lane = ev["lane"] or "unknown"
        row = lanes[lane]
        spend = ev["tokens"] if ev["tokens"] else 1
        if ev["dispatch"]:
            row["dispatches"] += 1
            row["spend"] += spend
            if ev["retry"]:
                row["retries"] += 1
                row["waste_spend"] += spend
            elif ev["issue"] not in landed:
                row["waste_spend"] += spend
        if ev["empty"]:
            row["empty_runs"] += 1
            if not ev["dispatch"]:
                row["waste_spend"] += spend
                row["spend"] += spend
        if ev["complete"]:
            row["completions"] += 1
        if ev["salvage"]:
            row["salvage"] += 1
        if ev["merged"]:
            row["merged_prs"] += 1
        if ev["tokens"] and not ev["dispatch"] and not ev["empty"]:
            row["tokens"] += ev["tokens"]
        elif ev["tokens"]:
            row["tokens"] += ev["tokens"]
    totals = empty_lane()
    for row in lanes.values():
        for k in totals:
            totals[k] += row[k]
    waste_ratio = None
    if totals["spend"] > 0:
        waste_ratio = totals["waste_spend"] / totals["spend"]
        if waste_ratio > 1:
            waste_ratio = 1.0
    efficiency = {}
    for lane, row in lanes.items():
        if row["dispatches"] > 0:
            efficiency[lane] = row["completions"] / row["dispatches"]
    return {
        "lanes": dict(lanes),
        "totals": totals,
        "waste_ratio": waste_ratio,
        "efficiency": efficiency,
        "landed": sorted(landed),
    }


def render_prom(agg, window_hours=24):
    # window_hours is documentary; HELP text says 24h for the live scrape.
    _ = window_hours
    lines = [
        HELP_RUNS,
        TYPE_RUNS,
        f'fleet_waste_runs{{kind="total"}} {agg["totals"]["dispatches"]}',
        f'fleet_waste_runs{{kind="empty"}} {agg["totals"]["empty_runs"]}',
        f'fleet_waste_runs{{kind="retry"}} {agg["totals"]["retries"]}',
        f'fleet_waste_runs{{kind="salvage"}} {agg["totals"]["salvage"]}',
        "",
    ]
    lanes = sorted(agg["lanes"])
    def emit_family(help_s, type_s, name, field):
        out = [help_s, type_s]
        if not lanes:
            out.append(f'{name}{{lane="none"}} 0')
        else:
            for lane in lanes:
                out.append(
                    f'{name}{{lane="{prom_label(lane)}"}} {agg["lanes"][lane][field]}'
                )
        out.append("")
        return out

    lines.extend(emit_family(HELP_DISP, TYPE_DISP, "fleet_waste_dispatches_24h", "dispatches"))
    lines.extend(emit_family(HELP_COMP, TYPE_COMP, "fleet_waste_completions_24h", "completions"))
    lines.extend(emit_family(HELP_EMPTY, TYPE_EMPTY, "fleet_waste_empty_runs_24h", "empty_runs"))
    lines.extend(emit_family(HELP_RETRY, TYPE_RETRY, "fleet_waste_retries_24h", "retries"))
    lines.extend(emit_family(HELP_TOK, TYPE_TOK, "fleet_waste_tokens_24h", "tokens"))
    lines.extend(emit_family(HELP_PR, TYPE_PR, "fleet_waste_merged_prs_24h", "merged_prs"))
    if agg["waste_ratio"] is not None:
        lines.extend(
            [
                HELP_RATIO,
                TYPE_RATIO,
                f"fleet_waste_ratio {agg['waste_ratio']:.6f}",
                "",
            ]
        )
    if agg["efficiency"]:
        lines.extend([HELP_EFF, TYPE_EFF])
        for lane in sorted(agg["efficiency"]):
            lines.append(
                f'fleet_lane_efficiency{{lane="{prom_label(lane)}"}} {agg["efficiency"][lane]:.6f}'
            )
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def utc_day(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%d")


def retro_days(events, end, days=3):
    rows = []
    end_day = datetime(
        end.year, end.month, end.day, tzinfo=timezone.utc
    ) + timedelta(days=1)
    for i in range(days, 0, -1):
        day_end = end_day - timedelta(days=i - 1)
        day_start = day_end - timedelta(days=1)
        date = day_start.strftime("%Y-%m-%d")
        day_events = [e for e in events if in_window(e["ts"], day_start, day_end)]
        agg = aggregate(day_events)
        empty_by_lane = {
            lane: row["empty_runs"]
            for lane, row in sorted(agg["lanes"].items())
            if row["empty_runs"]
        }
        retries_by_lane = {
            lane: row["retries"]
            for lane, row in sorted(agg["lanes"].items())
            if row["retries"]
        }
        rows.append(
            {
                "date": date,
                "dispatches": agg["totals"]["dispatches"],
                "completions": agg["totals"]["completions"],
                "empty_runs": agg["totals"]["empty_runs"],
                "empty_by_lane": empty_by_lane,
                "retries": agg["totals"]["retries"],
                "retries_by_lane": retries_by_lane,
                "salvage": agg["totals"]["salvage"],
                "waste_ratio": agg["waste_ratio"],
                "merged_prs": agg["totals"]["merged_prs"],
            }
        )
    return rows


def detect_spikes(day_rows):
    empty_spike = None
    salvage_spike = None
    best_empty = (-1, None, None)
    best_salvage = (-1.0, None)
    for row in day_rows:
        for lane, count in (row.get("empty_by_lane") or {}).items():
            if count > best_empty[0]:
                best_empty = (count, row["date"], lane)
        salvage_score = row["retries"] + row["salvage"]
        ratio = row["waste_ratio"] if row["waste_ratio"] is not None else 0.0
        score = salvage_score + (10 * ratio if ratio >= 0.4 else 0)
        if score > best_salvage[0]:
            best_salvage = (score, row)
    if best_empty[0] > 0:
        empty_spike = {
            "date": best_empty[1],
            "lane": best_empty[2],
            "count": best_empty[0],
        }
    if best_salvage[1] is not None and (
        best_salvage[1]["retries"] > 0 or best_salvage[1]["salvage"] > 0
    ):
        salvage_spike = {
            "date": best_salvage[1]["date"],
            "retries": best_salvage[1]["retries"],
            "salvage": best_salvage[1]["salvage"],
            "waste_ratio": best_salvage[1]["waste_ratio"],
        }
    return {"empty_run": empty_spike, "salvage_bleed": salvage_spike}


def prove_known_losses(spikes):
    """0509#1302 pattern: an instrument that cannot see the known losses fails.

    Salvage bleed (#1204) must appear as a retries/salvage spike.
    Devin empty runs (#902) must appear as a tools=0 spike on a devin lane.
    """
    errors = []
    empty = spikes.get("empty_run") or {}
    salvage = spikes.get("salvage_bleed") or {}
    lane = str(empty.get("lane") or "")
    if empty.get("count", 0) < 3:
        errors.append(
            f"empty-run spike missing or too small: {empty!r} (need count>=3)"
        )
    if "devin" not in lane:
        errors.append(
            f"empty-run spike lane is {lane!r}, expected a devin lane (fleet-ops#902)"
        )
    retries = int(salvage.get("retries") or 0)
    salv = int(salvage.get("salvage") or 0)
    ratio = salvage.get("waste_ratio")
    ratio_ok = isinstance(ratio, (int, float)) and ratio >= 0.40
    if retries + salv < 5 and not ratio_ok:
        errors.append(
            f"salvage-bleed spike missing: {salvage!r} "
            "(need retries+salvage>=5 or waste_ratio>=0.40, fleet-ops#1204)"
        )
    return errors


def window_bounds(end, hours=24):
    return end - timedelta(hours=hours), end


def export_prom(agg, path=None):
    body = render_prom(agg)
    atomic_write(path or OUT, body)
    return body


def usage():
    print(
        """usage: fleet-waste-export.py [--retro Nd] [--prove-known-losses] [--stdout]

Write fleet-waste.prom (default), or print a last-N-days retro JSON.

  --retro 3d              last 3 UTC days of the same metric family
  --prove-known-losses    exit 1 unless the retro shows the #902 empty-run
                          spike and the #1204 salvage-bleed spike
  --stdout                print the prometheus text to stdout (still writes)
  --help                  this text
""",
        file=sys.stderr,
    )
    return 2


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    retro_days_n = 0
    prove = False
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
        if a == "--prove-known-losses":
            prove = True
            i += 1
            continue
        if a == "--retro":
            i += 1
            if i >= len(argv):
                return usage()
            raw = argv[i].lower().rstrip("d")
            try:
                retro_days_n = int(raw)
            except ValueError:
                return usage()
            i += 1
            continue
        if a.startswith("--retro="):
            raw = a.split("=", 1)[1].lower().rstrip("d")
            try:
                retro_days_n = int(raw)
            except ValueError:
                return usage()
            i += 1
            continue
        print(f"fleet-waste-export: unknown flag {a}", file=sys.stderr)
        return usage()

    end = now_dt()
    try:
        if retro_days_n or prove:
            if retro_days_n <= 0:
                retro_days_n = 3
            start = end - timedelta(days=retro_days_n)
            events = collect_events(start, end)
            days = retro_days(events, end, days=retro_days_n)
            spikes = detect_spikes(days)
            payload = {"days": days, "spikes": spikes, "window_days": retro_days_n}
            print(json.dumps(payload, indent=2, default=str))
            if prove:
                errors = prove_known_losses(spikes)
                if errors:
                    for err in errors:
                        print(f"FAIL: {err}", file=sys.stderr)
                    return 1
                print("OK: known losses are visible (empty-run + salvage-bleed spikes)", file=sys.stderr)
            return 0

        start, end_w = window_bounds(end, hours=24)
        events = collect_events(start, end_w)
        agg = aggregate(events)
        body = export_prom(agg)
        if to_stdout:
            sys.stdout.write(body)
        return 0
    except Exception as exc:
        print(f"waste ledger failed: {exc}", file=sys.stderr)
        try:
            export_prom(
                {
                    "lanes": {},
                    "totals": empty_lane(),
                    "waste_ratio": None,
                    "efficiency": {},
                    "landed": [],
                }
            )
        except Exception as write_exc:
            print(f"waste ledger zero-write failed: {write_exc}", file=sys.stderr)
        return 0


if __name__ == "__main__":
    sys.exit(main())
