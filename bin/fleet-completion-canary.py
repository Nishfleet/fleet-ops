#!/usr/bin/env python3
# PROM_URL is operator-controlled localhost Prometheus (127.0.0.1:9090); the
# env override is loopback-only and never pointed elsewhere. Audit-confirmed
# safe (same suppression as bin/gh-webhook-canary.py + lib/credential-expiry-canary.py).
# nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected
"""fleet-completion-canary — alert-repair COMPLETION invariant (fleet-ops#468).

The coverage canary (fleet-escalation-canary) proves every failure STARTS a
chain. The sibling fleet-escalation-completion already proves unit-escalation
chains (STOP-REASON → auditor → detector-green) terminate. This companion
proves Prometheus alert-repair chains terminate, with hop clocks, and exports
the fleet_chain_* metrics both planes share.

Chain (alert-repair plane), hop receipts that already exist:
  TRIP     alert firing on :9090 /api/v1/alerts
  DISPATCH actions.log `DISPATCH alertname=... unit=alert-repair-...`
  RUN      that unit's systemd Result
  VERIFY   alert no longer firing, or actions.log RESOLVED / VERIFY resolved

Hop clocks (packet 11):
  dispatch within 10 min of firing
  unit finishes within 60 min of dispatch
  alert resolves within 30 min of unit success

Ladder (this process takes it; no human):
  first stall at dispatch/run → re-dispatch via alert-repair-dispatch
    (seat pick is `--print-seat`, not a copy of _pick_seat)
  twice-failed / verify stall / synthetic CanaryDrill → STOP-REASON.json
    (reason=alert-repair-stalled) which summons the senior conference
  terminal close persists the ladder marker; a re-open of the SAME dispatch
    unit re-parks (sliding cooldown, fleet-ops#2397) instead of re-laddering
    — an escalation already owned by the senior conference must not keep
    summoning new STOP-REASONs for the same dead unit.

CanaryDrill is skip-listed in the dispatcher (like FleetTestAlert) so a
drill never spawns a real repair worker. The canary still tracks a fake
DISPATCH + dead unit and takes the STOP-REASON / REDISPATCH-log ladder.

Unit-escalation plane: observe only (open/stalled gauges). Ladder stays
with fleet-escalation-completion (24h cycle budget, wired into heartbeat).

Dispatch plane (fleet-ops#1009): pi-systemd-run appends one JSONL entry
per dispatch to $AGENT_STATE/dispatch-ledger.jsonl. This canary walks
open entries each tick:
  in-flight unit (active/activating)     -> leave open
  unit finished (Result or journal)      -> close completed/{success,failed}
  orphan past deadline, retries < 2      -> re-dispatch SAME packet file
                                           on the next healthy seat
  orphan past deadline, retries >= 2     -> STOP-REASON reason=dispatch-orphan
                                           (senior conference)
  orphan, no packet file, retries < 2    -> fail-loud (exit 1)
A systemd-run --collect unit unloads after it exits; LoadState=loaded is
required before Result/ExecMainStatus count, otherwise the journal is the
only receipt and silence is an orphan. Re-dispatch goes through
pi-systemd-run (anti-recursion: this bin creates no unit of its own).

Anti-recursion: this bin never creates an alert-repair-* unit of its own.
Its service inherits service.d/10-escalate.conf; a genuine fail-loud exit
climbs that ladder. After STOP-REASON is written, subsequent ticks
only export stalled>0 (the 15m FleetChainStalled rail) until the chain's
next stall tick closes it as terminal=escalated (fleet-ops#2367) — a
handled escalation must not park the chain open/stalled forever, or the
rail turns into a permanent red loop that keeps dispatching repair
workers into unrepairable structural alerts.

Environment seams (tests):
  FLEET_COMPLETION_STATE, FLEET_COMPLETION_ACTIONS_LOG,
  FLEET_COMPLETION_PROM, FLEET_COMPLETION_ALERTS_JSON,
  FLEET_COMPLETION_PROM_URL, FLEET_COMPLETION_NOW,
  FLEET_COMPLETION_DISPATCHER, FLEET_COMPLETION_SYSTEMCTL,
  FLEET_COMPLETION_JOURNALCTL, FLEET_STOP_REASON, FLEET_COMPLETION_TRIAGE,
  FLEET_COMPLETION_CLOCK_DISPATCH/RUN/VERIFY,
  FLEET_ESCALATION_COMPLETION_BUDGET,
  FLEET_DISPATCH_LEDGER, FLEET_DISPATCH_PACKET_DIR,
  FLEET_COMPLETION_PI_SYSTEMD_RUN, FLEET_DISPATCH_MAX_RETRIES,
  FLEET_DISPATCH_CANARY_SEAT_MODE (healthy = stub seat, skip dispatcher)
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = os.environ.get("HOME", "/home/nish")
AS = Path(os.environ.get("AGENT_STATE", f"{HOME}/workspaces/agent-state"))
STATE = Path(os.environ.get("FLEET_COMPLETION_STATE", str(AS / "fleet-completion-canary")))
ACTIONS = Path(os.environ.get(
    "FLEET_COMPLETION_ACTIONS_LOG",
    str(AS / "alert-repair" / "actions.log"),
))
PROM = Path(os.environ.get(
    "FLEET_COMPLETION_PROM",
    "/var/lib/prometheus/node-exporter/fleet-chains.prom",
))
ALERTS_JSON = os.environ.get("FLEET_COMPLETION_ALERTS_JSON", "")
PROM_URL = os.environ.get("FLEET_COMPLETION_PROM_URL", "http://127.0.0.1:9090/api/v1/alerts")
DISPATCHER = os.environ.get(
    "FLEET_COMPLETION_DISPATCHER",
    f"{HOME}/.local/libexec/alert-repair-dispatch",
)
SYSTEMCTL = os.environ.get("FLEET_COMPLETION_SYSTEMCTL", "systemctl")
JOURNALCTL = os.environ.get("FLEET_COMPLETION_JOURNALCTL", "journalctl")
STOP_REASON = Path(os.environ.get("FLEET_STOP_REASON", str(AS / "STOP-REASON.json")))
TRIAGE = Path(os.environ.get(
    "FLEET_COMPLETION_TRIAGE",
    str(AS / "FLEET-HEARTBEAT-TRIAGE.md"),
))
NOW_ISO = os.environ.get("FLEET_COMPLETION_NOW", "")

# Dispatch plane (fleet-ops#1009): pi-systemd-run appends one JSONL entry per
# dispatch to this ledger. This canary walks open entries each tick, closes
# completed ones, re-dispatches orphans past deadline, escalates after
# DISPATCH_MAX_RETRIES. Re-dispatch goes through pi-systemd-run (anti-
# recursion: no unit created directly here).
DISPATCH_LEDGER = Path(os.environ.get(
    "FLEET_DISPATCH_LEDGER", str(AS / "dispatch-ledger.jsonl"),
))
DISPATCH_PKT_DIR = Path(os.environ.get(
    "FLEET_DISPATCH_PACKET_DIR", str(AS / "dispatch-packets"),
))
PI_SYSTEMD_RUN = os.environ.get(
    "FLEET_COMPLETION_PI_SYSTEMD_RUN",
    f"{HOME}/.local/bin/pi-systemd-run",
)
DISPATCH_MAX_RETRIES = int(os.environ.get("FLEET_DISPATCH_MAX_RETRIES", "2"))
DISPATCH_FAILED_RESULTS = {
    "exit-code", "signal", "core-dump", "oom-kill",
    "timeout", "resources", "exit-signal",
}

CLOCK_DISPATCH = int(os.environ.get("FLEET_COMPLETION_CLOCK_DISPATCH", "600"))
CLOCK_RUN = int(os.environ.get("FLEET_COMPLETION_CLOCK_RUN", "3600"))
CLOCK_VERIFY = int(os.environ.get("FLEET_COMPLETION_CLOCK_VERIFY", "1800"))
VERIFY_DEADLINE = int(os.environ.get(
    "FLEET_COMPLETION_VERIFY_DEADLINE", str(CLOCK_VERIFY * 2)
))
UE_BUDGET = int(os.environ.get("FLEET_ESCALATION_COMPLETION_BUDGET", "86400"))

# Decision-pending class park (2026-08-31 senior auditor): a structural alert
# whose chain escalated to the senior conference (ladder=stop-reason) and was
# closed out (terminal=escalated/detector-red) while STILL firing is a
# Nish-reserved decision, not a fresh fault. Without a class-level park, each
# new dispatch unit resets the stale ladder marker (fleet-ops#2397 fresh-trip
# branch) and the whole cycle re-runs: spawn repair worker -> verify fail ->
# STOP-REASON -> senior summon. Live: FleetQueueSelfMaintenanceRatioHigh — 6
# repair dispatches + 4 escalations in ~48h for one undecided policy question.
# Park the CLASS (not just the instance) for PARK_CLASS seconds: while parked,
# a fresh unit on the same still-firing alert re-parks (metrics only, no new
# STOP-REASON, no worker). Park expiry re-opens ONE bounded nag per window so
# a pending decision cannot rot silently.
PARK_CLASS = int(os.environ.get("FLEET_COMPLETION_PARK_CLASS", "86400"))

# Issue-close evidence check (fleet-ops#1527): look back this many hours for
# closed issues to verify they have PR/commit evidence.
ISSUE_EVIDENCE_LOOKBACK_HOURS = int(os.environ.get(
    "FLEET_COMPLETION_ISSUE_EVIDENCE_LOOKBACK_HOURS", "24"
))
# Repos to check (from intake-repos.json enrolled repos).
ISSUE_EVIDENCE_REPOS_FILE = os.environ.get(
    "FLEET_COMPLETION_ISSUE_EVIDENCE_REPOS_FILE",
    f"{HOME}/workspaces/tooling/fleet-ops-deploy-clone/config/intake-repos.json",
)

SKIP_FIRING = {
    "Watchdog",
    "FleetTestAlert",
    "LoadStorm",
    # Anti-recursion: this canary's own organ-absence / stall rails. A
    # missing fleet_chain_open is fixed by THIS process exporting it, not
    # by spawning an alert-repair worker to rebuild the canary.
    "FleetCompletionCanaryAbsent",
    "FleetChainStalled",
    # FleetSloSeatAvailSlowBurn is a WFR-input slow-burn SLO alert
    # (fleet-ops#1291/2429): the dispatcher skip-list means no DISPATCH is
    # ever expected, so a firing-without-dispatch chain must not ladder —
    # it would redispatch (skipped, rc=0), then write STOP-REASON and
    # escalate the senior conference for a measurement. Repair is
    # mechanism-impossible (seat supply is operator-owned); the alert
    # clears only when compliance >= 0.9 + the smoothing window flushes.
    "FleetSloSeatAvailSlowBurn",
    # WFR-input slow-burn SLO (fleet-ops#1291/2429): same class as
    # FleetSloSeatAvailSlowBurn — the dispatcher skip-list means no DISPATCH
    # is ever expected, so a firing-without-dispatch chain must not ladder.
    # The main_green burn-rate alert is a lagging integrator that clears
    # only when ~6h of all-green samples flush the burn windows; repair is
    # mechanism-impossible (fleet-ops#2672: it held a verify chain stalled at
    # 2026-09-01T15:23Z, re-seating onto an empty-run benched seat).
    "FleetSloMainGreenSlowBurn",
    # WFR-input trend regression (fleet-ops#2440/#2441): no DISPATCH comes,
    # so a firing trend delta must never ladder to a STOP-REASON.
    "FleetSelfMaintenanceRegression",
    # WFR-input trend regression (fleet-ops#2440/#2441): no DISPATCH comes,
    # so a firing trend delta must never ladder to a STOP-REASON.
    "FleetQualityChurnRegression",
    # WFR-input trend regression (fleet-ops#2440/#2441): no DISPATCH comes,
    # so a firing trend delta must never ladder to a STOP-REASON.
    "FleetVerifiedMergeRegression",
}
SYNTHETIC = {"CanaryDrill"}
SELF_UNITS = ("fleet-completion-canary",)

LOG_RE = re.compile(
    r"\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\]\s+"
    r"(DISPATCH|RESOLVED|VERIFY|SKIP|REDISPATCH)\s+alertname=(\S+)(.*)$"
)
SEAT_RE = re.compile(r"\bseat=(\S+)")
UNIT_RE = re.compile(r"\bunit=(\S+)")


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{ts}] [fleet-completion-canary] {msg}", file=sys.stderr)


def loud(tag: str, msg: str) -> None:
    log(f"LOUD [{tag}] {msg}")
    try:
        TRIAGE.parent.mkdir(parents=True, exist_ok=True)
        with TRIAGE.open("a") as f:
            ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            f.write(f"\n[{ts}] [{tag}] {msg}\n")
    except OSError as exc:
        log(f"WARN: triage append failed: {exc}")


def parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    ts = ts.strip()
    m = re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?Z?", ts)
    if m:
        return datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(
            tzinfo=timezone.utc
        )
    try:
        if ts.endswith("Z"):
            ts = ts[:-1] + "+00:00"
        dt = datetime.fromisoformat(ts)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except ValueError:
        return None


def now_dt() -> datetime:
    if NOW_ISO:
        parsed = parse_iso(NOW_ISO)
        if parsed is not None:
            return parsed
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch(dt: datetime) -> int:
    return int(dt.timestamp())


def atomic_write(path: Path, text: str) -> None:
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
        # node_exporter runs as prometheus; mkstemp is 0600.
        os.chmod(path, 0o644)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def prom_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def reason_is_terminal(reason: str) -> bool:
    if reason == "":
        return True
    if reason in {"cooldown_active", "auditor-resolved"}:
        return True
    return reason.startswith("boundary:")


def load_firing_alerts() -> dict[str, datetime]:
    """alertname → first activeAt for currently-firing non-skip alerts."""
    payload = None
    if ALERTS_JSON:
        p = Path(ALERTS_JSON)
        if p.is_file():
            try:
                payload = json.loads(p.read_text())
            except (OSError, json.JSONDecodeError) as exc:
                log(f"WARN: alerts json unreadable: {exc}")
                return {}
        else:
            return {}
    else:
        try:
            # Operator-controlled PROM_URL (localhost Prometheus).
            # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
            with urllib.request.urlopen(PROM_URL, timeout=5) as resp:
                payload = json.loads(resp.read().decode())
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as exc:
            log(f"WARN: 9090 unreachable ({exc}); skip firing enumeration")
            return {}
    out: dict[str, datetime] = {}
    alerts = (payload or {}).get("data", {}).get("alerts", [])
    for a in alerts:
        # Pending (`for:` still counting) is not a repair-dispatchable trip.
        # Alertmanager only pages firing; treating pending as firing caused a
        # live redispatch of FleetCompletionCanaryAbsent during the first tick.
        if a.get("state") != "firing":
            continue
        name = (a.get("labels") or {}).get("alertname")
        if not name or name in SKIP_FIRING:
            continue
        started = parse_iso(a.get("activeAt") or a.get("startsAt") or "")
        if started is None:
            started = now_dt()
        prev = out.get(name)
        if prev is None or started < prev:
            out[name] = started
    return out


def parse_actions(path: Path) -> dict[str, dict]:
    """Per-alertname latest DISPATCH plus any terminal / redispatch receipts."""
    chains: dict[str, dict] = {}
    if not path.is_file():
        return chains
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError as exc:
        log(f"WARN: actions.log unreadable: {exc}")
        return chains
    for line in lines:
        m = LOG_RE.search(line)
        if not m:
            continue
        ts_s, kind, name, rest = m.group(1), m.group(2), m.group(3), m.group(4)
        ts = parse_iso(ts_s)
        if ts is None:
            continue
        rec = chains.setdefault(name, {
            "alertname": name,
            "dispatch_ts": None,
            "dispatch_unit": None,
            "dispatch_seat": None,
            "resolved_ts": None,
            "redispatch_ts": None,
            "events": [],
        })
        rec["events"].append((ts, kind, line))
        unit_m = UNIT_RE.search(rest)
        seat_m = SEAT_RE.search(rest)
        if kind == "DISPATCH":
            rec["dispatch_ts"] = ts
            rec["dispatch_unit"] = unit_m.group(1) if unit_m else rec["dispatch_unit"]
            rec["dispatch_seat"] = seat_m.group(1) if seat_m else rec["dispatch_seat"]
        elif kind == "RESOLVED":
            # Keep the LATEST resolve, not the first. An alertname can fire
            # multiple chains; the first RESOLVED belongs to an old chain and
            # would make classify() misread a re-fire as a verify-stall of the
            # old chain instead of a new dispatch (FleetMainRed 2026-08-27
            # re-fire at 21:10:56Z misclassified as hop=verify age=8794).
            rec["resolved_ts"] = ts
        elif kind == "VERIFY":
            low = line.lower()
            if " resolved" in low:
                rec["resolved_ts"] = ts
        elif kind == "REDISPATCH":
            rec["redispatch_ts"] = ts
            if unit_m:
                rec["dispatch_unit"] = unit_m.group(1)
    return chains


def unit_status(unit: str | None) -> tuple[str, str]:
    """Return (result, active_state). Missing unit → ("missing", "inactive").

    A systemd-run --collect unit unloads after exit; systemctl show then
    returns LoadState=not-found with the *default* Result=success. Treating
    that default as a real success pins alert-repair chains at hop=verify on
    a dead unit that actually failed (fleet-ops#2100: FleetDeadCredentialSeats
    unit exited exit-code but --collect unloaded it, so classify saw
    unit_success and stalled at verify forever). When LoadState=not-found,
    fall back to the journal — the same receipt classify_dispatch uses
    (fleet-ops#1295). "Failed" → exit-code; "Succeeded"/"Started"-only →
    success; empty journal → missing (never started).
    """
    if not unit:
        return "missing", "inactive"
    for prefix in SELF_UNITS:
        if unit.startswith(prefix):
            return "ignored", "inactive"
    try:
        r = subprocess.run(
            [SYSTEMCTL, "--user", "show", unit,
             "--property=Result", "--property=ActiveState",
             "--property=LoadState"],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "missing", "inactive"
    result, active, load = "missing", "inactive", "not-found"
    for line in (r.stdout or "").splitlines():
        if line.startswith("Result="):
            val = line.split("=", 1)[1].strip()
            result = val or "missing"
        elif line.startswith("ActiveState="):
            val = line.split("=", 1)[1].strip()
            active = val or "inactive"
        elif line.startswith("LoadState="):
            val = line.split("=", 1)[1].strip()
            load = val or "not-found"
    if r.returncode != 0 and result == "missing":
        return "missing", "inactive"
    # --collect unloaded the unit: Result=success is the default, not a real
    # verdict. The journal is the only receipt (fleet-ops#1295/#2100).
    if load == "not-found":
        jtext = journal_text(unit)
        verdict = journal_verdict(jtext)
        if verdict == "failed":
            return "exit-code", "inactive"
        if verdict == "success":
            return "success", "inactive"
        if journal_has_started(jtext) or journal_started(unit):
            # Loaded and ran to completion; no "Failed" line (fleet-ops#1295).
            return "success", "inactive"
        # No journal at all — the unit never started under this name.
        return "missing", "inactive"
    return result, active


def unit_running(result: str, active: str) -> bool:
    return active in {"active", "activating"} and result != "exit-code"


def unit_success(result: str, active: str) -> bool:
    return result == "success" and active != "failed"


def load_chain_state(name: str) -> dict:
    p = STATE / "open" / f"{name}.json"
    if not p.is_file():
        return {"alertname": name, "stall_count": 0, "ladder": ""}
    try:
        d = json.loads(p.read_text())
    except (OSError, json.JSONDecodeError):
        return {"alertname": name, "stall_count": 0, "ladder": ""}
    d.setdefault("stall_count", 0)
    d.setdefault("ladder", "")
    return d


def save_chain_state(name: str, d: dict) -> None:
    p = STATE / "open" / f"{name}.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(p, json.dumps(d, sort_keys=True) + "\n")


def _prune_park_fields(state: dict) -> dict:
    """Return the class-park fields present in state (for cooldown markers).

    A cooldown close must NOT silently deletethe class park (decision_class_until /
    reason / set_by, fleet-ops#2651) — dropping it would letthe dispatcher re-
    dispatch the class each repeat_interval cycle, burning a fresh repair worker to
    re-derive the same verdict forever. Retaining it lets the #2397 re-park guard
    hold the chain drained until the park expiry re-opens ONE bounded nag per window.

    Returns an empty dict when nothing is parked (old states unchanged).
    """
    out = {}
    for k in ("decision_class_until", "decision_class_reason", "decision_class_set_by"):
        if state.get(k):
            out[k] = state[k]
    return out


def drop_chain_state(name: str) -> None:
    p = STATE / "open" / f"{name}.json"
    try:
        p.unlink()
    except OSError:
        pass


def ledger_path() -> Path:
    return STATE / "chains.terminated.jsonl"


def already_terminated(name: str, start_iso: str) -> bool:
    p = ledger_path()
    if not p.is_file():
        return False
    try:
        lines = p.read_text().splitlines()
    except OSError:
        return False
    for line in lines:
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("alertname") == name and d.get("start_ts") == start_iso:
            return True
    return False


def append_terminal(rec: dict) -> None:
    p = ledger_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a") as f:
        f.write(json.dumps(rec, sort_keys=True) + "\n")
    # Mirror under alert-repair so a reviewer finds it next to actions.log.
    mirror = AS / "alert-repair" / "chains.terminated.jsonl"
    if str(STATE).startswith(str(AS)):
        try:
            mirror.parent.mkdir(parents=True, exist_ok=True)
            with mirror.open("a") as f:
                f.write(json.dumps(rec, sort_keys=True) + "\n")
        except OSError:
            pass


def print_seat(exclude: str | None) -> tuple[str, str, str] | None:
    argv = [DISPATCHER, "--print-seat"]
    if exclude:
        argv += ["--exclude", exclude]
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"WARN: --print-seat failed: {exc}")
        return None
    if r.returncode != 0:
        log(f"WARN: --print-seat rc={r.returncode} stderr={r.stderr.strip()[:200]}")
        return None
    line = (r.stdout or "").strip().splitlines()
    if not line:
        return None
    parts = line[0].split("\t")
    if len(parts) < 3:
        return None
    return parts[0], parts[1], parts[2]


def redispatch_real(alertname: str) -> int:
    env = os.environ.copy()
    env["AMX_STATUS"] = "firing"
    env["AMX_RECEIVER"] = "completion-canary-redispatch"
    env["AMX_ALERT_1_LABEL_alertname"] = alertname
    try:
        r = subprocess.run([DISPATCHER], env=env, capture_output=True, text=True,
                           timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"ERROR: redispatch {alertname} failed: {exc}")
        return 1
    log(f"redispatch alertname={alertname} dispatcher_rc={r.returncode}")
    return 0 if r.returncode == 0 else r.returncode


def write_stop_reason(chain: dict, hop: str, age: int) -> None:
    body = {
        "reason": "alert-repair-stalled",
        "detail": {
            "chain": chain.get("alertname"),
            "hop": hop,
            "age": age,
            "unit": chain.get("dispatch_unit") or "",
            "alertname": chain.get("alertname"),
            "source": "fleet-completion-canary",
        },
        "timestamp": iso(now_dt()),
        "extension": "fleet-completion-canary",
        "source": "fleet-completion-canary",
    }
    atomic_write(STOP_REASON, json.dumps(body, indent=2) + "\n")
    log(f"STOP-REASON written reason=alert-repair-stalled hop={hop} "
        f"alertname={chain.get('alertname')} path={STOP_REASON}")


def append_redispatch_log(name: str, hop: str, seat: str, reason: str) -> None:
    try:
        ACTIONS.parent.mkdir(parents=True, exist_ok=True)
        with ACTIONS.open("a") as f:
            f.write(
                f"[{iso(now_dt())}] REDISPATCH alertname={name} hop={hop} "
                f"seat={seat} reason={reason} source=fleet-completion-canary\n"
            )
    except OSError as exc:
        log(f"WARN: actions.log append failed: {exc}")


def take_ladder(chain: dict, hop: str, age: int, state: dict,
                now: datetime) -> str:
    name = chain["alertname"]
    synthetic = name in SYNTHETIC
    stall_count = int(state.get("stall_count") or 0)
    prev_ladder = state.get("ladder") or ""

    # Class-park gate (fleet-ops#2651 semantics extended to every hop,
    # fleet-ops#2700): if the class is parked (decision_class_until in the
    # future), the park IS the escalation verdict. The dispatcher SKIPs a
    # park-skipped alertname and returns rc=0 WITHOUT spawning a unit — so a
    # redispatch here cannot re-seat the chain: it only fakes a
    # "re-dispatched rc=0" receipt in the actions log, leaves the chain
    # stalled at hop=run, and the NEXT tick then re-writes STOP-REASON and
    # re-summons the senior conference for a chain the conference already
    # parked (live 2026-09-01: FleetSloMainGreenSlowBurn class parked until
    # 2026-09-03, run-hop redispatch was park-SKIPped rc=0, next tick
    # re-wrote STOP-REASON 18:37:09Z, and the FleetChainStalled rail stayed
    # red 18:08→18:52Z even though the alert was already owned). A parked
    # chain therefore drains: ladder=stop-reason → the #2367 close in main
    # terminates terminal=escalated same-tick (run/dispatch) or the verify
    # deadline drains it as detector-red — no redispatch, no re-summon.
    class_until = state.get("decision_class_until")
    parked = False
    if class_until:
        class_dt = parse_iso(str(class_until))
        if class_dt is not None and now < class_dt:
            parked = True
    if parked:
        state["ladder"] = "stop-reason"
        if hop == "verify":
            # Zero-grace deadline so the #1610 block drains it next tick.
            state["verify_deadline_ts"] = iso(now_dt())
        log(f"chain {name} class-parked until {class_until} at hop={hop} — "
            f"no redispatch, no STOP-REASON (park is the escalation "
            f"verdict; chain drains)")
        return "already"

    if stall_count >= 1 or prev_ladder:
        # fleet-ops#2247: a prior redispatch at dispatch/run returned rc=0,
        # but rc=0 only proves the dispatcher SPAWNED an async unit — it is
        # not evidence the repair ran or the alert resolved. If the chain is
        # STILL stalled on a later tick (take_ladder is only called when
        # decision["stalled"] is True), the redispatch was a no-op: the
        # alert kept firing. Fail loud — write STOP-REASON and escalate to
        # the senior conference — instead of parking the chain at "already"
        # forever, which left FleetMainRed stuck through endless rc=0
        # redispatches that never turned main green.
        # fleet-ops#2651: the no-op-redispatch test must apply at hop=verify
        # too. A unit that exits per the packet EXIT CONTRACT (alert still
        # firing) and is then --collect unloaded reads as SUCCESS from a
        # Started-only journal (fleet-ops#2100), so the chain hops run ->
        # verify after the redispatch. The old hop restriction parked such a
        # chain at "already" with no STOP-REASON, no verify deadline and no
        # terminal — a permanent verify stall that kept FleetChainStalled
        # red through endless re-derivations of the same verdict (live:
        # FleetQueueSelfMaintenanceRatioHigh after the 12:22Z redispatch,
        # 2026-09-01). Escalate instead; the verify_deadline_ts marker then
        # drains it as detector-red via the #1610 path.
        if prev_ladder == "redispatch" and hop in {"dispatch", "run", "verify"}:
            # fleet-ops#2651: if the class is parked (decision_class_until in
            # the future), the park IS the escalation verdict — re-summoning
            # the senior conference per redispatch would re-open the churn
            # loop this field exists to break. For hop=verify the chain still
            # drains quietly: the zero-grace verify_deadline_ts (set below by
            # the #1610 block) terminates it as detector-red + cooldown, and
            # the re-park guard (fleet-ops#2397) holds it drained until the
            # park expiry re-opens the bounded nag. For dispatch/run (no
            # deadline rail) the stop-reason stays — park or not.
            parked = hop == "verify"
            if parked:
                class_until = state.get("decision_class_until")
                if class_until:
                    class_dt = parse_iso(str(class_until))
                    if class_dt is None or not (now < class_dt):
                        parked = False
                else:
                    parked = False
            if not parked:
                write_stop_reason(chain, hop, age)
                loud("UNREPAIRED-FAIL",
                     f"alertname={name} hop={hop} age={age}s — redispatch no-op: "
                     f"alert still firing after rc=0 redispatch; STOP-REASON "
                     f"alert-repair-stalled (senior conference)")
                state["ladder"] = "stop-reason"
                state["hop"] = hop
                state["age"] = age
                if hop == "verify":
                    state["verify_deadline_ts"] = iso(now_dt())
                return "stop-reason"
            # fleet-ops#2651: mark the chain escalated (ladder=stop-reason) so
            # the #2397 re-park guard holds it drained after its cooldown close; a
            # bare "already" would re-open each cycle forever. No new STOP-REASON,
            # no redispatch — the park is the escalation verdict.

            state["ladder"] = "stop-reason"
            log(f"chain {name} redispatch no-op at verify, class parked "
                f"until {state.get('decision_class_until')} — no re-summon; "
                f"ladder=stop-reason; verify deadline drains")
        log(f"chain {name} already laddered ({prev_ladder}); metrics only")
        return "already"

    exclude = None
    seat_s = chain.get("dispatch_seat") or ""
    if seat_s:
        exclude = seat_s.split("/")[0]

    picked = print_seat(exclude if hop != "dispatch" else None)
    seat_label = f"{picked[0]}/{picked[1]}" if picked else "none"
    pick_reason = picked[2] if picked else "no-seat"

    if synthetic or hop == "verify":
        # CanaryDrill never spawns a real pi worker (dispatcher skip-list).
        # Verify stalls mean the worker already ran; climb to senior conference.
        # Set a deadline marker so main() can bump it to now+VERIFY_DEADLINE —
        # a verify chain must not hold the FleetChainStalled rail open forever
        # (fleet-ops#1610).
        append_redispatch_log(name, hop, seat_label, pick_reason)
        write_stop_reason(chain, hop, age)
        state["verify_deadline_ts"] = iso(now_dt())
        loud("UNREPAIRED-FAIL",
             f"alertname={name} hop={hop} age={age}s — ladder: REDISPATCH-log "
             f"seat={seat_label} + STOP-REASON alert-repair-stalled")
        return "stop-reason"

    if hop in {"dispatch", "run"}:
        rc = redispatch_real(name)
        append_redispatch_log(name, hop, seat_label, f"redispatch-rc={rc}")
        if rc != 0:
            write_stop_reason(chain, hop, age)
            loud("UNREPAIRED-FAIL",
                 f"alertname={name} hop={hop} age={age}s — redispatch failed "
                 f"rc={rc}; STOP-REASON written")
            return "stop-reason"
        loud("UNREPAIRED-FAIL",
             f"alertname={name} hop={hop} age={age}s — re-dispatched via "
             f"alert-repair-dispatch seat={seat_label}")
        return "redispatch"

    write_stop_reason(chain, hop, age)
    loud("UNREPAIRED-FAIL",
         f"alertname={name} hop={hop} age={age}s — STOP-REASON alert-repair-stalled")
    return "stop-reason"


def observe_unit_escalation(now: datetime) -> tuple[int, int]:
    """Return (open, stalled) for the unit-escalation plane. Ladder is sibling."""
    if not STOP_REASON.is_file():
        return 0, 0
    try:
        d = json.loads(STOP_REASON.read_text())
    except (OSError, json.JSONDecodeError):
        return 0, 0
    reason = str(d.get("reason") or "")
    if reason_is_terminal(reason):
        return 0, 0
    # A STOP-REASON we ourselves just wrote is an alert-repair stall, not
    # a unit-escalation chain. Count it on the alert-repair plane only.
    if reason == "alert-repair-stalled":
        return 0, 0
    ts = parse_iso(str(d.get("timestamp") or ""))
    age = epoch(now) - epoch(ts) if ts else 0
    stalled = 1 if age >= UE_BUDGET else 0
    return 1, stalled


def emit_metrics(open_hops: dict, stalled_hops: dict, ue_open: int, ue_stalled: int,
                 cycles: list[tuple[str, str, int]], now: datetime,
                 dispatch_counts: dict | None = None,
                 issue_evidence: dict | None = None) -> None:
    lines = [
        "# HELP fleet_chain_open Open failure chains not yet at a legal terminal.",
        "# TYPE fleet_chain_open gauge",
    ]
    for hop in ("dispatch", "run", "verify"):
        lines.append(
            f'fleet_chain_open{{plane="alert-repair",hop="{hop}"}} {open_hops[hop]}'
        )
    lines.append(f'fleet_chain_open{{plane="unit-escalation",hop="trip"}} {ue_open}')
    if dispatch_counts:
        disp_open = dispatch_counts.get("in_flight", 0) + dispatch_counts.get("waiting", 0)
        lines.append(f'fleet_chain_open{{plane="dispatch",hop="run"}} {disp_open}')
    else:
        lines.append('fleet_chain_open{plane="dispatch",hop="run"} 0')
    lines += [
        "# HELP fleet_chain_stalled Chains past their hop clock.",
        "# TYPE fleet_chain_stalled gauge",
    ]
    for hop in ("dispatch", "run", "verify"):
        lines.append(
            f'fleet_chain_stalled{{plane="alert-repair",hop="{hop}"}} {stalled_hops[hop]}'
        )
    lines.append(
        f'fleet_chain_stalled{{plane="unit-escalation",hop="trip"}} {ue_stalled}'
    )
    if dispatch_counts:
        disp_stalled = (dispatch_counts.get("redispatched", 0)
                        + dispatch_counts.get("escalated", 0)
                        + dispatch_counts.get("fail_loud", 0))
        lines.append(f'fleet_chain_stalled{{plane="dispatch",hop="run"}} {disp_stalled}')
    else:
        lines.append('fleet_chain_stalled{plane="dispatch",hop="run"} 0')
    lines += [
        "# HELP fleet_chain_cycle_seconds Failure-to-fix cycle time.",
        "# TYPE fleet_chain_cycle_seconds gauge",
    ]
    if cycles:
        secs = [c[2] for c in cycles]
        lines.append(f'fleet_chain_cycle_seconds{{stat="min"}} {min(secs)}')
        lines.append(f'fleet_chain_cycle_seconds{{stat="max"}} {max(secs)}')
        lines.append(
            f'fleet_chain_cycle_seconds{{stat="avg"}} {sum(secs) / len(secs):.1f}'
        )
        # Last per-alertname sample (reviewer-friendly).
        last: dict[str, tuple[str, int]] = {}
        for name, terminal, sec in cycles:
            last[name] = (terminal, sec)
        for name, (terminal, sec) in sorted(last.items()):
            lines.append(
                f'fleet_chain_cycle_seconds{{alertname="{prom_label(name)}",'
                f'terminal="{prom_label(terminal)}"}} {sec}'
            )
    else:
        lines.append('fleet_chain_cycle_seconds{stat="min"} 0')
        lines.append('fleet_chain_cycle_seconds{stat="max"} 0')
        lines.append('fleet_chain_cycle_seconds{stat="avg"} 0')
    lines += [
        "# HELP fleet_chain_completion_timestamp_seconds When the canary last ran.",
        "# TYPE fleet_chain_completion_timestamp_seconds gauge",
        f"fleet_chain_completion_timestamp_seconds {epoch(now)}",
        "",
    ]
    # fleet_chain_repair_duration_seconds — p95 of chain cycle times (fleet-ops#2168).
    # This is the source metric for the chain_repair_latency SLO (p95 ≤ 30 min).
    lines += [
        "# HELP fleet_chain_repair_duration_seconds p95 alert-repair chain duration (seconds).",
        "# TYPE fleet_chain_repair_duration_seconds gauge",
    ]
    if cycles:
        secs = sorted([c[2] for c in cycles])
        # p95 index (nearest-rank method, same as Prometheus histogram_quantile).
        idx = max(0, min(len(secs) - 1, int(len(secs) * 0.95)))
        p95 = secs[idx]
        lines.append(f"fleet_chain_repair_duration_seconds {p95}")
    else:
        lines.append("fleet_chain_repair_duration_seconds 0")
    lines.append("")
    # Issue-close evidence metrics (fleet-ops#1527)
    if issue_evidence is not None:
        lines += [
            "# HELP fleet_issue_closed_without_evidence_total Issues closed without PR/commit evidence.",
            "# TYPE fleet_issue_closed_without_evidence_total counter",
            f'fleet_issue_closed_without_evidence_total {issue_evidence.get("total_without_evidence", 0)}',
            "# HELP fleet_issue_closed_total Total issues closed in lookback window.",
            "# TYPE fleet_issue_closed_total counter",
            f'fleet_issue_closed_total {issue_evidence.get("total_closed", 0)}',
            "",
        ]
        for repo, count in sorted(issue_evidence.get("by_repo", {}).items()):
            lines.append(
                f'fleet_issue_closed_without_evidence{{repo="{prom_label(repo)}"}} {count}'
            )
        lines.append("")
    atomic_write(PROM, "\n".join(lines))
    log(f"wrote {PROM}")


def load_ledger_cycles() -> list[tuple[str, str, int]]:
    p = ledger_path()
    out: list[tuple[str, str, int]] = []
    if not p.is_file():
        return out
    try:
        lines = p.read_text().splitlines()
    except OSError:
        return out
    for line in lines:
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        name = d.get("alertname")
        terminal = d.get("terminal") or "green"
        sec = d.get("cycle_seconds")
        if name and isinstance(sec, (int, float)):
            out.append((str(name), str(terminal), int(sec)))
    return out


def classify(name: str, rec: dict, firing: dict[str, datetime], now: datetime) -> dict:
    """Return hop / stalled / terminal decision for one alertname."""
    synthetic = name in SYNTHETIC
    is_firing = name in firing
    disp_ts = rec.get("dispatch_ts")
    resolved_ts = rec.get("resolved_ts")
    unit = rec.get("dispatch_unit")
    result, active = unit_status(unit)
    start = firing.get(name) or disp_ts or now
    out = {
        "alertname": name,
        "hop": None,
        "stalled": False,
        "age": 0,
        "terminal": None,
        "start_ts": start,
        "dispatch_unit": unit,
        "dispatch_seat": rec.get("dispatch_seat"),
        "dispatch_ts": disp_ts,
        "result": result,
        "active": active,
    }
    if resolved_ts is not None:
        # A RESOLVED/VERIFY only closes the trip it belongs to. A later
        # re-fire (activeAt after resolved_ts) or a later DISPATCH is a new chain.
        trip_start = disp_ts or firing.get(name) or start
        if resolved_ts >= (disp_ts or resolved_ts) and (
            not is_firing or resolved_ts >= firing[name]
        ):
            out["start_ts"] = disp_ts or start
            out["terminal"] = "green"
            out["end_ts"] = resolved_ts
            return out
        # Stale resolve; fall through as an open chain on the new trip.
        # Only clear disp_ts if it belongs to the old trip (before resolved_ts)
        # or never existed. A later DISPATCH (disp_ts >= resolved_ts) is part
        # of the new trip and must be kept — without this, a chain stays
        # pinned at hop=dispatch forever even after a fresh worker is
        # dispatched for the re-fire (alert-repair 2026-08-27 redispatch
        # case on FleetMainRed).
        if is_firing and firing[name] > resolved_ts:
            start = firing[name]
            out["start_ts"] = start
            if disp_ts is None or epoch(disp_ts) < epoch(resolved_ts):
                disp_ts = None
                rec = dict(rec)
                rec["dispatch_ts"] = None
                rec["dispatch_unit"] = None
    # A dispatch can only belong to a trip that was firing at dispatch time.
    # If the current fire started AFTER the dispatch (firing[name] > disp_ts),
    # the dispatch is from a prior trip that already terminated — keeping it
    # pins the chain to a dead unit at hop=verify forever (fleet-ops#2100:
    # FleetMainRed re-fired at 18:35:56 but disp_ts stayed 00:16:09 from the
    # prior green chain, so classify saw the stale unit's success and stalled
    # at verify through endless detector-red → cooldown → re-ladder cycles).
    # Clear it so the re-fire starts at hop=dispatch and gets a fresh worker.
    if is_firing and disp_ts is not None and not unit_running(result, active):
        fire_start = firing.get(name)
        if fire_start is not None and epoch(disp_ts) < epoch(fire_start):
            disp_ts = None
            rec = dict(rec)
            rec["dispatch_ts"] = None
            rec["dispatch_unit"] = None
            unit = None
            out["dispatch_ts"] = None
            out["dispatch_unit"] = None
            out["result"] = "missing"
            out["active"] = "inactive"
    if not synthetic and not is_firing and disp_ts is not None:
        # Alert left 9090. Legal terminal: detector-green.
        if unit_success(result, active) or result in {"missing", "ignored"}:
            out["terminal"] = "green"
            out["end_ts"] = now
            return out
        if unit_running(result, active):
            out["hop"] = "run"
            out["age"] = epoch(now) - epoch(disp_ts)
            out["stalled"] = out["age"] >= CLOCK_RUN
            return out
        # Failed unit, alert already gone: close green (detector is the 9090 set).
        out["terminal"] = "green"
        out["end_ts"] = now
        return out
    if not synthetic and not is_firing and disp_ts is None:
        return out  # nothing
    # Open: firing, or synthetic with a DISPATCH and no RESOLVED.
    if disp_ts is None:
        if not is_firing:
            return out
        out["hop"] = "dispatch"
        out["age"] = epoch(now) - epoch(start)
        out["stalled"] = out["age"] >= CLOCK_DISPATCH
        return out
    out["age"] = epoch(now) - epoch(disp_ts)
    if unit_running(result, active):
        out["hop"] = "run"
        out["stalled"] = out["age"] >= CLOCK_RUN
        return out
    if unit_success(result, active):
        out["hop"] = "verify"
        # Clock is 30 min from unit success; we don't have exact success ts
        # on all units, so age-since-dispatch minus RUN budget is the floor,
        # and age-since-dispatch itself is the conservative stall if > RUN+VERIFY.
        verify_age = max(0, out["age"] - CLOCK_RUN)
        if is_firing or synthetic:
            out["stalled"] = verify_age >= CLOCK_VERIFY or out["age"] >= CLOCK_RUN + CLOCK_VERIFY
        else:
            out["terminal"] = "green"
            out["end_ts"] = now
        return out
    # Dead / missing / failed unit after DISPATCH.
    out["hop"] = "run"
    out["stalled"] = out["age"] >= CLOCK_RUN
    return out


# ---------------------------------------------------------------------------
# Dispatch plane (fleet-ops#1009)
# ---------------------------------------------------------------------------

def show_prop(unit: str, prop: str) -> str:
    """Return a single systemctl --user show --property value."""
    try:
        r = subprocess.run(
            [SYSTEMCTL, "--user", "show", f"--property={prop}",
             "--value", unit if unit.endswith(".service") else f"{unit}.service"],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return (r.stdout or "").strip()


def journal_text(unit: str) -> str:
    """Return last 20 journal lines for a unit (cat format)."""
    try:
        r = subprocess.run(
            [JOURNALCTL, "--user", "-u",
             unit if unit.endswith(".service") else f"{unit}.service",
             "-o", "cat", "-n", "20"],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout or ""


def journal_started(unit: str) -> bool:
    """Return True if the unit's journal carries its systemd 'Started' line.

    journal_text() truncates to the last 20 lines, but the
    'Started <unit>.service' line is always the FIRST journal entry. A
    verbose pi transcript pushes it out of that window, so
    journal_has_started(text) misses it and a --collect unit that genuinely
    ran to completion is classified 'orphan' — its dispatch-ledger entry
    stays open until the deadline, then the SAME packet is re-dispatched
    (duplicate repair work) and exported as
    fleet_chain_stalled{plane=dispatch,hop=run} (live fleet-ops#2414: two
    24-line journals, Started at line 1, hidden by -n 20). Grep the full
    unit journal journald-side (-g is bounded, -n 1 short-circuits) for the
    exact start marker instead; the marker is unique to systemd's own line
    and absent from a unit that never started.
    """
    name = unit.rstrip(".service")
    try:
        r = subprocess.run(
            [JOURNALCTL, "--user", "-u",
             name if unit.endswith(".service") else f"{name}.service",
             "-o", "cat", "-g", rf"^Started {re.escape(name)}\.service\b",
             "-n", "1"],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return bool((r.stdout or "").strip())


def journal_verdict(text: str) -> str | None:
    """Return 'success' / 'failed' from journal text, or None.

    A systemd-run --collect unit unloads after exit. For successful units the
    journal may only contain the "Started" line -- the "Succeeded" summary is
    emitted as part of the unload and can be suppressed. Absence of "Failed"
    on a journal that has "Started" is treated as success elsewhere.
    """
    if re.search(r"\bSucceeded\b", text):
        return "success"
    if re.search(r"\bFailed\b", text):
        return "failed"
    return None


def journal_has_started(text: str) -> bool:
    """Return True if the journal text contains a unit start line.

    A --collect unit that was loaded and started but whose "Succeeded" line
    was suppressed still leaves a "Started <unit>.service" line. Its presence
    means the unit loaded and ran to completion without a failure log.
    """
    return bool(re.search(r"Started .+\.service", text))


def classify_dispatch(rec: dict) -> str:
    """Return in-flight | completed-success | completed-failed | orphan.

    A systemd-run --collect unit unloads after it exits. systemctl show then
    returns LoadState=not-found and the *default* Result=success. Treating
    that default as a real success would close every missing unit and never
    re-dispatch. LoadState=loaded is required before Result counts; otherwise
    the journal is the only receipt.

    Gap (fleet-ops#1295): --collect units that exited successfully may not
    have a "Succeeded" journal line (it is suppressed during unload), so
    journal_verdict returns None and the unit is misclassified as "orphan"
    -- leaving the dispatch ledger entry open until the deadline fires. When
    the journal has a "Started" line but no "Failed", the unit loaded and
    ran to completion: classify as completed-success. A truly empty journal
    (unit never started) remains an orphan.
    """
    unit = rec.get("unit") or ""
    if not unit:
        return "orphan"
    load = show_prop(unit, "LoadState")
    active = show_prop(unit, "ActiveState")
    if load == "loaded" and active in {"active", "activating"}:
        return "in-flight"
    if load == "loaded":
        result = show_prop(unit, "Result")
        if result in DISPATCH_FAILED_RESULTS or active == "failed":
            return "completed-failed"
        return "completed-success"
    # LoadState=not-found (or missing): --collect unloaded the unit.
    # The journal is the only receipt.
    jtext = journal_text(unit)
    verdict = journal_verdict(jtext)
    if verdict == "success":
        return "completed-success"
    if verdict == "failed":
        return "completed-failed"
    # No verdict from standard strings. A --collect unit that was loaded and
    # started (journal has "Started <unit>.service") but never logged
    # "Succeeded" (common with --collect) completed without a failure log.
    if journal_has_started(jtext) or journal_started(unit):
        # journal_has_started only sees the last 20 journal lines; the
        # 'Started' marker is the FIRST line, so a verbose transcript hides
        # it and a completed run would be orphaned until the deadline
        # (fleet-ops#2414). journal_started scans the full journal for it.
        return "completed-success"
    return "orphan"


def dispatch_past_deadline(rec: dict, now: datetime) -> bool:
    deadline = rec.get("deadline_ts") or ""
    if deadline:
        try:
            return now >= parse_iso(str(deadline))
        except (ValueError, TypeError):
            log(f"WARN: bad deadline_ts={deadline!r} id={rec.get('id')}")
    try:
        start = parse_iso(str(rec.get("ts") or ""))
        minutes = int(rec.get("deadline_min") or 90)
        return (now - start).total_seconds() >= minutes * 60
    except (ValueError, TypeError):
        return False


def load_dispatch_latest() -> dict[str, dict]:
    """Return last record per id from the dispatch ledger."""
    latest: dict[str, dict] = {}
    if not DISPATCH_LEDGER.is_file():
        return latest
    try:
        with DISPATCH_LEDGER.open() as f:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                rec_id = rec.get("id")
                if rec_id:
                    latest[str(rec_id)] = rec
    except OSError:
        pass
    return latest


def append_dispatch_line(rec: dict) -> None:
    """Append a closing/redispatch line to the dispatch ledger."""
    try:
        DISPATCH_LEDGER.parent.mkdir(parents=True, exist_ok=True)
        with DISPATCH_LEDGER.open("a") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    except OSError as exc:
        log(f"WARN: dispatch ledger append failed: {exc}")


def close_dispatch_entry(rec: dict, status: str, **extra: object) -> None:
    out = dict(rec)
    out["status"] = status
    out.update(extra)
    out["closed_ts"] = iso(now_dt())
    append_dispatch_line(out)


def write_dispatch_stop_reason(rec: dict) -> None:
    body = {
        "reason": "dispatch-orphan",
        "detail": {
            "chain_id": rec.get("chain_id") or "",
            "retries": int(rec.get("retries") or 0),
            "hop": int(rec.get("hop") or 0),
            "unit": rec.get("unit") or "",
            "packet_path": rec.get("packet_path") or "",
            "provider": rec.get("provider") or "",
            "model": rec.get("model") or "",
            "source": "fleet-completion-canary",
        },
        "timestamp": iso(now_dt()),
        "extension": "fleet-completion-canary",
        "source": "fleet-completion-canary",
    }
    atomic_write(STOP_REASON, json.dumps(body, indent=2) + "\n")
    log(
        f"STOP-REASON written reason=dispatch-orphan "
        f"chain={body['detail']['chain_id']} "
        f"retries={body['detail']['retries']} path={STOP_REASON}"
    )


def dispatch_pick_seat(exclude_provider: str) -> tuple[str, str, str] | None:
    """Pick a healthy seat for re-dispatch. SEAT_MODE=healthy returns a stub."""
    seat_mode = os.environ.get("FLEET_DISPATCH_CANARY_SEAT_MODE", "")
    if seat_mode == "healthy":
        return ("commandcode", "minimax-m3-free", "healthy-stub")
    argv = [DISPATCHER, "--print-seat"]
    if exclude_provider:
        argv += ["--exclude", exclude_provider]
    try:
        r = subprocess.run(argv, capture_output=True, text=True,
                           timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"WARN: dispatch --print-seat failed: {exc}")
        return None
    if r.returncode != 0:
        log(f"WARN: dispatch --print-seat rc={r.returncode}")
        return None
    lines = (r.stdout or "").strip().splitlines()
    if not lines:
        return None
    parts = lines[-1].split("\t")
    if len(parts) < 2:
        return None
    reason = parts[2] if len(parts) > 2 else ""
    return (parts[0], parts[1], reason)


def dispatch_redispatch(rec: dict, provider: str, model: str) -> int:
    """Re-dispatch the SAME packet file via pi-systemd-run."""
    unit = rec.get("unit") or "pi-job"
    retries = int(rec.get("retries") or 0)
    hop = int(rec.get("hop") or 0)
    new_unit = f"{unit}-r{retries + 1}"
    deadline_min = str(int(rec.get("deadline_min") or 90))
    chain_id = str(rec.get("chain_id") or rec.get("id") or "")
    packet = str(rec.get("packet_path") or "")
    cmd = [
        PI_SYSTEMD_RUN,
        "--unit", new_unit,
        "--stdin", packet,
        "--deadline", deadline_min,
        "--provider", provider,
        "--model", model,
        "--chain-id", chain_id,
        "--hop", str(hop + 1),
        "--",
        "pi", "--print",
        "--provider", provider,
        "--model", model,
    ]
    log(f"REDISPATCH unit={new_unit} chain={chain_id} hop={hop + 1} "
        f"seat={provider}/{model}")
    try:
        r = subprocess.run(cmd, check=False, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"ERROR: redispatch failed: {exc}")
        return 1
    return r.returncode


def process_dispatch_plane(now: datetime) -> dict:
    """Walk open dispatch-ledger entries. Return counts dict."""
    latest = load_dispatch_latest()
    open_recs = [r for r in latest.values() if r.get("status") == "open"]
    counts = {
        "open": len(open_recs),
        "in_flight": 0,
        "closed": 0,
        "waiting": 0,
        "redispatched": 0,
        "escalated": 0,
        "fail_loud": 0,
    }
    if not open_recs:
        return counts
    open_recs.sort(key=lambda r: (str(r.get("ts") or ""), str(r.get("id") or "")))
    for rec in open_recs:
        kind = classify_dispatch(rec)
        unit = rec.get("unit") or ""
        if kind == "in-flight":
            log(f"dispatch in-flight unit={unit} id={rec.get('id')}")
            counts["in_flight"] += 1
            continue
        if kind == "completed-success":
            exit_status = show_prop(unit, "ExecMainStatus") or "0"
            close_dispatch_entry(rec, "completed", verdict="success",
                                 result="success", exit_status=exit_status)
            log(f"dispatch closed/success unit={unit} id={rec.get('id')}")
            counts["closed"] += 1
            continue
        if kind == "completed-failed":
            # For --collect units (LoadState=not-found), systemctl show
            # Result is the default "success" and misleading. The verdict
            # came from journal "Failed", so record journal-derived result.
            result = show_prop(unit, "Result") or "exit-code"
            if show_prop(unit, "LoadState") == "not-found":
                result = "exit-code"
            exit_status = show_prop(unit, "ExecMainStatus") or "1"
            close_dispatch_entry(rec, "completed", verdict="failed",
                                 result=result, exit_status=exit_status)
            log(f"dispatch closed/failed unit={unit} result={result}")
            counts["closed"] += 1
            continue
        # orphan
        if not dispatch_past_deadline(rec, now):
            log(f"dispatch orphan waiting (before deadline) unit={unit} "
                f"id={rec.get('id')}")
            counts["waiting"] += 1
            continue
        retries = int(rec.get("retries") or 0)
        if retries >= DISPATCH_MAX_RETRIES:
            write_dispatch_stop_reason(rec)
            close_dispatch_entry(rec, "escalated", verdict="orphan")
            loud(
                "DISPATCH-ORPHAN",
                f"unit={unit} chain={rec.get('chain_id')} retries={retries} "
                "— STOP-REASON dispatch-orphan (senior conference)",
            )
            counts["escalated"] += 1
            continue
        packet = str(rec.get("packet_path") or "")
        if not packet or not Path(packet).is_file():
            log(f"dispatch orphan no packet file unit={unit} path={packet!r}")
            loud(
                "DISPATCH-ORPHAN-NO-PACKET",
                f"unit={unit} chain={rec.get('chain_id')} retries={retries} "
                "packet missing; cannot re-dispatch",
            )
            counts["fail_loud"] += 1
            continue
        picked = dispatch_pick_seat(str(rec.get("provider") or ""))
        if not picked:
            log(f"dispatch no healthy seat unit={unit} — fail-loud")
            counts["fail_loud"] += 1
            continue
        provider, model, _reason = picked
        rc = dispatch_redispatch(rec, provider, model)
        if rc != 0:
            log(f"dispatch re-dispatch failed rc={rc} unit={unit}")
            counts["fail_loud"] += 1
            continue
        close_dispatch_entry(
            rec, "redispatched", verdict="orphan",
            new_unit=f"{unit}-r{retries + 1}",
            seat=f"{provider}/{model}",
        )
        counts["redispatched"] += 1
    return counts


def check_closed_issues_without_evidence(now: datetime) -> dict:
    """Check enrolled repos for issues closed without PR/commit evidence.

    Returns a dict with:
      - total_closed: total issues closed in lookback window
      - total_without_evidence: issues closed without PR/commit evidence
      - by_repo: dict of repo -> count of issues without evidence
      - details: list of {repo, issue_number, title, closed_at} for flagged issues
    """
    result = {
        "total_closed": 0,
        "total_without_evidence": 0,
        "by_repo": {},
        "details": [],
    }
    
    # Load enrolled repos from intake-repos.json
    repos_file = Path(ISSUE_EVIDENCE_REPOS_FILE)
    if not repos_file.is_file():
        log(f"WARN: intake-repos.json not found at {repos_file}")
        return result
    
    try:
        with repos_file.open() as f:
            intake_config = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        log(f"WARN: failed to load intake-repos.json: {exc}")
        return result
    
    enrolled_repos = [r.get("name") for r in intake_config.get("repos", []) if r.get("name")]
    if not enrolled_repos:
        log("WARN: no enrolled repos found in intake-repos.json")
        return result
    
    # Calculate lookback cutoff
    cutoff = now - timedelta(hours=ISSUE_EVIDENCE_LOOKBACK_HOURS)
    cutoff_iso = cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")
    
    for repo in enrolled_repos:
        full_repo = f"Nishfleet/{repo}"
        try:
            # Query closed issues in the lookback window
            # Use --json to get structured data including closedByPullRequestsReferences
            cmd = [
                "gh", "issue", "list",
                "-R", full_repo,
                "--state", "closed",
                "--limit", "100",
                "--json", "number,title,closedAt,closedByPullRequestsReferences",
            ]
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
            if proc.returncode != 0:
                log(f"WARN: gh issue list failed for {full_repo}: {proc.stderr.strip()[:200]}")
                continue
            
            issues = json.loads(proc.stdout or "[]")
            if not isinstance(issues, list):
                continue
            
            repo_without_evidence = 0
            for issue in issues:
                closed_at_str = issue.get("closedAt")
                if not closed_at_str:
                    continue
                closed_at = parse_iso(closed_at_str)
                if not closed_at or closed_at < cutoff:
                    continue
                
                result["total_closed"] += 1
                
                # Check for PR evidence: closedByPullRequestsReferences
                pr_refs = issue.get("closedByPullRequestsReferences") or []
                has_pr_evidence = len(pr_refs) > 0
                
                # Check for commit evidence: search commits referencing the issue
                # This is done via a separate gh api call for commits mentioning the issue
                has_commit_evidence = False
                if not has_pr_evidence:
                    issue_num = issue.get("number")
                    if issue_num:
                        # Search for commits referencing the issue number
                        # Using gh api to search commits
                        search_cmd = [
                            "gh", "api",
                            f"/repos/Nishfleet/{repo}/commits",
                            "--jq", f".[] | select(.commit.message | contains(\"#{issue_num}\")) | .sha",
                        ]
                        search_proc = subprocess.run(search_cmd, capture_output=True, text=True, timeout=15, check=False)
                        if search_proc.returncode == 0 and search_proc.stdout.strip():
                            has_commit_evidence = True
                
                if not has_pr_evidence and not has_commit_evidence:
                    result["total_without_evidence"] += 1
                    repo_without_evidence += 1
                    result["details"].append({
                        "repo": repo,
                        "issue_number": issue.get("number"),
                        "title": issue.get("title", "")[:100],
                        "closed_at": closed_at_str,
                    })
                    log(f"FLAG: {full_repo}#{issue.get('number')} closed without PR/commit evidence: {issue.get('title', '')[:80]}")
            
            if repo_without_evidence > 0:
                result["by_repo"][repo] = repo_without_evidence
        
        except (subprocess.TimeoutExpired, OSError, json.JSONDecodeError) as exc:
            log(f"WARN: error checking {full_repo}: {exc}")
            continue
    
    if result["total_without_evidence"] > 0:
        loud(
            "ISSUE-CLOSE-NO-EVIDENCE",
            f"{result['total_without_evidence']} issue(s) closed without PR/commit evidence in last {ISSUE_EVIDENCE_LOOKBACK_HOURS}h"
        )
    
    return result


def main() -> int:
    from datetime import timedelta
    STATE.mkdir(parents=True, exist_ok=True)
    now = now_dt()
    firing = load_firing_alerts()
    parsed = parse_actions(ACTIONS)
    names = set(parsed) | set(firing)
    open_hops: dict[str, int] = defaultdict(int)
    stalled_hops: dict[str, int] = defaultdict(int)
    laddered_this_tick = 0

    for name in sorted(names):
        if name in SKIP_FIRING:
            continue
        rec = parsed.get(name, {
            "alertname": name,
            "dispatch_ts": None,
            "dispatch_unit": None,
            "dispatch_seat": None,
            "resolved_ts": None,
        })
        decision = classify(name, rec, firing, now)
        if decision.get("terminal") in ("green", "detector-red"):
            start = decision["start_ts"]
            end = decision.get("end_ts") or now
            start_iso = iso(start)
            terminal_kind = decision["terminal"]
            if not already_terminated(name, start_iso):
                cycle = max(0, epoch(end) - epoch(start))
                append_terminal({
                    "alertname": name,
                    "terminal": terminal_kind,
                    "start_ts": start_iso,
                    "end_ts": iso(end),
                    "cycle_seconds": cycle,
                    "unit": decision.get("dispatch_unit") or "",
                })
                log(f"TERMINAL {terminal_kind} alertname={name} cycle_seconds={cycle}")
            drop_chain_state(name)
            continue
        # After a detector-red termination, the chain state is left as a
        # cooldown marker (dead_until). Respect it (fleet-ops#1610).
        existing = load_chain_state(name)
        if existing.get("dead_until"):
            cooldown_until = parse_iso(existing["dead_until"])
            if cooldown_until is not None and now < cooldown_until:
                continue
        # fleet-ops#2397: a chain whose SAME dispatch unit already reached
        # ladder=stop-reason (STOP-REASON handed to the senior conference)
        # and was closed terminal must NOT re-ladder when its cooldown
        # expires. Re-opening re-wrote STOP-REASON and held the verify hop
        # open past its cycle budget forever (live: FleetQueueSelfMaintenance
        # RatioHigh — detector-red close 13:07:38Z, re-ladder 14:22:11Z, so
        # the auditor had to hand-park dead_until=+6h). A re-open of the
        # same unit (or a legacy marker without a unit) re-parks (sliding
        # cooldown) and stays drained. Only a genuinely fresh trip — a
        # different dispatch unit (re-fire or machinery re-dispatch) —
        # resets the stale marker and opens a clean chain with the normal
        # ladder. The alert leaving 9090 still closes via the green path.
        if existing.get("terminal") and existing.get("ladder") == "stop-reason":
            same_unit = (
                existing.get("dispatch_unit")
                and decision.get("dispatch_unit")
                and decision.get("dispatch_unit") == existing.get("dispatch_unit")
            )
            if same_unit or not existing.get("dispatch_unit"):
                park_until = now + timedelta(seconds=VERIFY_DEADLINE)
                existing["dead_until"] = iso(park_until)
                existing["dispatch_unit"] = (
                    existing.get("dispatch_unit")
                    or decision.get("dispatch_unit") or ""
                )
                save_chain_state(name, existing)
                log(f"re-park {name} hop={decision.get('hop')} "
                    f"unit={existing.get('dispatch_unit')} — escalation owns "
                    f"the chain; cooldown extended to "
                    f"{existing['dead_until']} (no re-ladder, no new STOP-REASON)")
                continue
            # Decision-pending class park: the senior conference adjudicated
            # this still-firing alert and the root is a Nish-reserved decision
            # (PARK_CLASS window still open). A NEW dispatch unit on the SAME
            # alertname must NOT reset the stale marker — that reset is the
            # churn vector that re-spawned repair workers and re-summoned the
            # senior conference every cycle (live: FleetQueueSelfMaintenance
            # RatioHigh, 08-29..08-31). Re-park instead; the alert leaving
            # 9090 still closes via the green path; park expiry re-opens one
            # bounded nag.
            class_until = existing.get("decision_class_until")
            if class_until:
                class_dt = parse_iso(class_until)
                if class_dt is not None and now < class_dt:
                    cd = parse_iso(existing.get("dead_until") or "")
                    if cd is None or now >= cd:
                        existing["dead_until"] = iso(
                            now + timedelta(seconds=VERIFY_DEADLINE)
                        )
                    existing["dispatch_unit"] = (
                        existing.get("dispatch_unit")
                        or decision.get("dispatch_unit") or ""
                    )
                    save_chain_state(name, existing)
                    log(f"decision-pending park {name} class_until={class_until} "
                        f"new_unit={decision.get('dispatch_unit') or 'none'} — no "
                        f"ladder reset, no new STOP-REASON, metrics only")
                    continue
            # Fresh trip: the old unit's escalation is settled. Reset the
            # stale marker so this dispatch opens a clean chain.
            existing.pop("terminal", None)
            existing.pop("dead_until", None)
            existing.pop("verify_deadline_ts", None)
            existing["ladder"] = ""
            existing["stall_count"] = 0
            existing["dispatch_unit"] = decision.get("dispatch_unit") or ""
            save_chain_state(name, existing)
            log(f"fresh trip {name}: dispatch unit changed to "
                f"{existing.get('dispatch_unit')} — stale escalation marker "
                f"reset, chain opens clean")
        hop = decision.get("hop")
        if not hop:
            continue
        open_hops[hop] += 1
        state = load_chain_state(name)
        if decision["stalled"]:
            stalled_hops[hop] += 1
            # Verify deadline: a laddered verify chain must not hold the
            # FleetChainStalled rail open indefinitely (fleet-ops#1610).
            # A verify chain that stays stalled past its deadline terminates
            # as detector-red (unit succeeded, alert still firing).
            if hop == "verify":
                deadline_ts = state.get("verify_deadline_ts")
                if deadline_ts:
                    deadline = parse_iso(deadline_ts)
                    if deadline is not None and now >= deadline:
                        # Deadline expired: terminal close as detector-red.
                        start = decision["start_ts"]
                        start_iso = iso(start)
                        cycle = max(0, epoch(now) - epoch(start))
                        if not already_terminated(name, start_iso):
                            append_terminal({
                                "alertname": name,
                                "terminal": "detector-red",
                                "start_ts": start_iso,
                                "end_ts": iso(now),
                                "cycle_seconds": cycle,
                                "unit": decision.get("dispatch_unit") or "",
                            })
                            log(f"TERMINAL detector-red alertname={name} "
                                f"cycle_seconds={cycle} (verify deadline expired)")
                        # Write a cooldown state so the chain does not
                        # immediately re-create (fleet-ops#1610). The alert
                        # is still firing but this chain is closed.
                        cooldown_deadline = now + timedelta(seconds=VERIFY_DEADLINE)
                        # fleet-ops#2651: preserve the class park across the cooldown
                        # close so the dispatcher keeps skipping this class each
                        # repeat_interval (the park is the escalation verdict).
                        save_chain_state(name, {
                            "alertname": name,
                            "hop": "verify",
                            "terminal": "detector-red",
                            "dead_until": iso(cooldown_deadline),
                            # fleet-ops#2397: persist the terminal marker so a
                            # re-open of the same dispatch unit re-parks via
                            # the guard in main() instead of re-laddering.
                            "ladder": state.get("ladder") or "stop-reason",
                            "stall_count": int(state.get("stall_count") or 0),
                            "dispatch_unit": decision.get("dispatch_unit") or "",
                            **_prune_park_fields(state),
                        })
                        # The chain terminated this tick — do not count it as
                        # still-open/stalled (fleet-ops#1610). Without this the
                        # metric over-counts and the next tick shows a phantom
                        # open verify chain even though it just closed.
                        open_hops[hop] -= 1
                        stalled_hops[hop] -= 1
                        continue
                elif state.get("ladder"):
                    # Pre-existing stuck chain (laddered by a prior canary version
                    # before the deadline feature existed). Drain at next tick by
                    # setting a deadline of now (zero-grace).
                    state["verify_deadline_ts"] = iso(now)
            action = take_ladder(decision, hop, decision["age"], state, now)
            if action != "already":
                state["stall_count"] = int(state.get("stall_count") or 0) + 1
                state["ladder"] = action
                state["hop"] = hop
                state["age"] = decision["age"]
                if action == "stop-reason" and name not in SYNTHETIC:
                    # Senior conference owns the escalation; park the class so a
                    # still-firing structural alert does not re-ladder on each
                    # fresh dispatch unit (churn loop; see PARK_CLASS).
                    state["decision_class_until"] = iso(
                        now + timedelta(seconds=PARK_CLASS)
                    )
                # Bump the verify_deadline_ts marker set inside take_ladder
                # to now + VERIFY_DEADLINE.
                if hop == "verify" and state.get("verify_deadline_ts"):
                    deadline_dt = now + timedelta(seconds=VERIFY_DEADLINE)
                    state["verify_deadline_ts"] = iso(deadline_dt)
                save_chain_state(name, state)
                laddered_this_tick += 1
            else:
                # fleet-ops#2367: a chain whose ladder already reached
                # "stop-reason" (STOP-REASON alert-repair-stalled written —
                # the senior conference owns the escalation) must TERMINATE as
                # terminal=escalated, not park open/stalled forever. Parking
                # converted a handled escalation into a permanent red rail:
                # FleetChainStalled fired, a repair worker was dispatched for
                # the rail, found the underlying alert unrepairable in-turn
                # (genuine structural signal), exited non-zero per the packet
                # EXIT CONTRACT — another failed run unit — and nothing ever
                # drained. Escalation IS the run hop's terminal. Mirror the
                # verify-hop detector-red close (fleet-ops#1610): terminate
                # this tick, record the terminal, and write a cooldown marker
                # so the SAME stale dispatch does not re-open the chain next
                # tick. A fresh dispatch (new DISPATCH line) or the alert
                # leaving 9090 still closes the chain via the normal paths.
                if state.get("ladder") == "stop-reason" and hop in {"dispatch", "run"}:
                    start = decision["start_ts"]
                    start_iso = iso(start)
                    cycle = max(0, epoch(now) - epoch(start))
                    if not already_terminated(name, start_iso):
                        append_terminal({
                            "alertname": name,
                            "terminal": "escalated",
                            "start_ts": start_iso,
                            "end_ts": iso(now),
                            "cycle_seconds": cycle,
                            "unit": decision.get("dispatch_unit") or "",
                        })
                        log(f"TERMINAL escalated alertname={name} "
                            f"cycle_seconds={cycle} "
                            "(stop-reason hand-off; STOP-REASON owns the escalation)")
                    cooldown_deadline = now + timedelta(seconds=VERIFY_DEADLINE)
                    # fleet-ops#2651: preserve the class park across the cooldown
                    # close too (same shape as the detector-red write above).
                    save_chain_state(name, {
                        "alertname": name,
                        "hop": hop,
                        "terminal": "escalated",
                        "dead_until": iso(cooldown_deadline),
                        # fleet-ops#2397: persist the terminal marker so a
                        # re-open of the same dispatch unit re-parks via the
                        # guard in main() instead of re-laddering.
                        "ladder": "stop-reason",
                        "stall_count": int(state.get("stall_count") or 0),
                        "dispatch_unit": decision.get("dispatch_unit") or "",
                        **_prune_park_fields(state),
                    })
                    # The chain terminated this tick — do not count it as
                    # still-open/stalled (same exclusion as the verify close).
                    open_hops[hop] -= 1
                    stalled_hops[hop] -= 1
                    continue
                # Already laddered on another rung — persist hop/age.
                state["hop"] = hop
                state["age"] = decision["age"]
                save_chain_state(name, state)
        else:
            state["hop"] = hop
            state["age"] = decision["age"]
            save_chain_state(name, state)
            log(f"in-flight alertname={name} hop={hop} age={decision['age']}s")

    ue_open, ue_stalled = observe_unit_escalation(now)
    dispatch_counts = process_dispatch_plane(now)
    cycles = load_ledger_cycles()
    issue_evidence = check_closed_issues_without_evidence(now)
    emit_metrics(open_hops, stalled_hops, ue_open, ue_stalled, cycles, now,
                 dispatch_counts, issue_evidence)

    log(
        f"tick open_ar={dict(open_hops)} stalled_ar={dict(stalled_hops)} "
        f"ue_open={ue_open} ue_stalled={ue_stalled} "
        f"laddered={laddered_this_tick} firing={sorted(firing)} "
        f"dispatch={dispatch_counts} "
        f"issue_evidence_closed={issue_evidence.get('total_closed', 0)} "
        f"issue_evidence_no_evidence={issue_evidence.get('total_without_evidence', 0)}"
    )
    # Exit 0: ladder taken or nothing stalled. Fail-loud (1) only when a
    # stalled chain could not be laddered (no dispatcher, unwritable STOP-REASON)
    # — the unit then climbs service.d/10-escalate.conf. A dispatch-plane
    # fail-loud (no packet file, no seat, redispatch rc!=0) also exits 1.
    if dispatch_counts.get("fail_loud"):
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 — fail loud, never silent
        log(f"FATAL: {exc}")
        sys.exit(1)
