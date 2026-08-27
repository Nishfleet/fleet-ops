#!/usr/bin/env python3
"""fleet-dispatch-canary — packet-dispatch COMPLETION plane (fleet-ops#1009).

Every pi-systemd-run dispatch appends an open JSONL ledger entry. This
companion walks that ledger each heartbeat tick:

  in-flight unit (active/activating)     -> leave open
  unit finished (Result or journal)      -> close completed/{success,failed}
  orphan past deadline, retries < 2      -> re-dispatch SAME packet file
                                           on the next healthy seat
  orphan past deadline, retries >= 2     -> STOP-REASON reason=dispatch-orphan
                                           (senior conference)
  orphan, no packet file, retries < 2    -> fail-loud (exit 1)

A systemd-run --collect unit unloads after it exits. systemctl show then
returns LoadState=not-found and the *default* Result=success. Treating that
default as a real success would close every missing unit and never
re-dispatch (unix.SE 543429; systemd-run --help --collect). LoadState=loaded
is required before Result/ExecMainStatus count; otherwise the journal is
the only receipt, and silence is an orphan.

This is the dispatch-plane sibling of fleet-completion-canary (alert-repair
hops, fleet-ops#468 / PR 1131) and fleet-escalation-completion (STOP-REASON
chains). Heartbeat block 32 runs it. Anti-recursion: this bin creates no
unit of its own; re-dispatch goes through pi-systemd-run.

Environment seams (tests):
  FLEET_DISPATCH_LEDGER, FLEET_DISPATCH_PACKET_DIR, FLEET_STOP_REASON,
  FLEET_DISPATCH_CANARY_SYSTEMCTL, FLEET_DISPATCH_CANARY_JOURNALCTL,
  FLEET_DISPATCH_CANARY_PI_SYSTEMD_RUN, FLEET_DISPATCH_CANARY_DISPATCHER,
  FLEET_DISPATCH_CANARY_SEAT_MODE (healthy = stub seat, skip dispatcher),
  FLEET_DISPATCH_CANARY_NOW, FLEET_HEARTBEAT_TRIAGE, AGENT_STATE
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HOME = os.environ.get("HOME", "/home/nish")
AS = Path(os.environ.get("AGENT_STATE", f"{HOME}/workspaces/agent-state"))
LEDGER = Path(os.environ.get("FLEET_DISPATCH_LEDGER", str(AS / "dispatch-ledger.jsonl")))
PKT_DIR = Path(os.environ.get("FLEET_DISPATCH_PACKET_DIR", str(AS / "dispatch-packets")))
STOP_REASON = Path(os.environ.get("FLEET_STOP_REASON", str(AS / "STOP-REASON.json")))
TRIAGE = Path(os.environ.get(
    "FLEET_HEARTBEAT_TRIAGE",
    str(AS / "FLEET-HEARTBEAT-TRIAGE.md"),
))
SYSTEMCTL = os.environ.get("FLEET_DISPATCH_CANARY_SYSTEMCTL", "systemctl")
JOURNALCTL = os.environ.get("FLEET_DISPATCH_CANARY_JOURNALCTL", "journalctl")
PI_SYSTEMD_RUN = os.environ.get(
    "FLEET_DISPATCH_CANARY_PI_SYSTEMD_RUN",
    f"{HOME}/.local/bin/pi-systemd-run",
)
DISPATCHER = os.environ.get(
    "FLEET_DISPATCH_CANARY_DISPATCHER",
    f"{HOME}/.local/libexec/alert-repair-dispatch",
)
SEAT_MODE = os.environ.get("FLEET_DISPATCH_CANARY_SEAT_MODE", "")
NOW_ISO = os.environ.get("FLEET_DISPATCH_CANARY_NOW", "")

FAILED_RESULTS = {
    "exit-code",
    "signal",
    "core-dump",
    "oom-kill",
    "timeout",
    "resources",
    "exit-signal",
}


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{ts}] [fleet-dispatch-canary] {msg}", file=sys.stderr)


def loud(tag: str, msg: str) -> None:
    log(f"LOUD [{tag}] {msg}")
    try:
        TRIAGE.parent.mkdir(parents=True, exist_ok=True)
        with TRIAGE.open("a") as f:
            f.write(
                f"\n[{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}] "
                f"[{tag}] {msg}\n"
            )
    except OSError as exc:
        log(f"WARN: triage append failed: {exc}")


def now_dt() -> datetime:
    if NOW_ISO:
        return parse_iso(NOW_ISO)
    return datetime.now(timezone.utc)


def parse_iso(value: str) -> datetime:
    text = (value or "").strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def unit_svc(unit: str) -> str:
    name = (unit or "").strip()
    if not name.endswith(".service"):
        name = f"{name}.service"
    return name


def show_prop(unit: str, prop: str) -> str:
    r = subprocess.run(
        [SYSTEMCTL, "--user", "show", f"--property={prop}", "--value", unit_svc(unit)],
        capture_output=True,
        text=True,
        check=False,
    )
    return (r.stdout or "").strip()


def is_active(unit: str) -> str:
    r = subprocess.run(
        [SYSTEMCTL, "--user", "is-active", unit_svc(unit)],
        capture_output=True,
        text=True,
        check=False,
    )
    return (r.stdout or "").strip() or "inactive"


def journal_text(unit: str) -> str:
    r = subprocess.run(
        [JOURNALCTL, "--user", "-u", unit_svc(unit), "-o", "cat", "-n", "20"],
        capture_output=True,
        text=True,
        check=False,
    )
    return r.stdout or ""


def journal_verdict(text: str) -> str | None:
    if re.search(r"\bSucceeded\b", text):
        return "success"
    if re.search(r"\bFailed\b", text):
        return "failed"
    return None


def load_latest() -> dict[str, dict]:
    latest: dict[str, dict] = {}
    if not LEDGER.is_file():
        return latest
    with LEDGER.open() as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as exc:
                log(f"WARN: skip malformed ledger line: {exc}")
                continue
            rec_id = rec.get("id")
            if not rec_id:
                continue
            latest[str(rec_id)] = rec
    return latest


def append_line(rec: dict) -> None:
    LEDGER.parent.mkdir(parents=True, exist_ok=True)
    with LEDGER.open("a") as f:
        f.write(json.dumps(rec, separators=(",", ":")) + "\n")


def close_entry(rec: dict, status: str, **extra: object) -> None:
    out = dict(rec)
    out["status"] = status
    out.update(extra)
    out["closed_ts"] = iso(now_dt())
    append_line(out)


def atomic_write(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".sr-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(body)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_stop_reason(rec: dict) -> None:
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
            "source": "fleet-dispatch-canary",
        },
        "timestamp": iso(now_dt()),
        "extension": "fleet-dispatch-canary",
        "source": "fleet-dispatch-canary",
    }
    atomic_write(STOP_REASON, json.dumps(body, indent=2) + "\n")
    log(
        f"STOP-REASON written reason=dispatch-orphan chain={body['detail']['chain_id']} "
        f"retries={body['detail']['retries']} path={STOP_REASON}"
    )


def pick_seat(exclude_provider: str) -> tuple[str, str, str] | None:
    if SEAT_MODE == "healthy":
        return ("commandcode", "minimax-m3-free", "healthy-stub")
    cmd = [DISPATCHER, "--print-seat"]
    if exclude_provider:
        cmd.extend(["--exclude", exclude_provider])
    r = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if r.returncode != 0:
        log(f"print-seat failed rc={r.returncode} stderr={(r.stderr or '').strip()}")
        return None
    line = (r.stdout or "").strip().splitlines()
    if not line:
        return None
    parts = line[-1].split("\t")
    if len(parts) < 2:
        return None
    reason = parts[2] if len(parts) > 2 else ""
    return (parts[0], parts[1], reason)


def classify(rec: dict) -> str:
    """Return in-flight | completed-success | completed-failed | orphan."""
    unit = rec.get("unit") or ""
    load = show_prop(unit, "LoadState")
    state = is_active(unit)
    if load == "loaded" and state in {"active", "activating"}:
        return "in-flight"
    if load == "loaded":
        result = show_prop(unit, "Result")
        if result == "success" or (state == "inactive" and result in {"", "success"}):
            # Loaded + inactive + success (or empty Result on a finished
            # simple service) is a real completion, not the not-found default.
            if result in FAILED_RESULTS or state == "failed":
                return "completed-failed"
            return "completed-success"
        if result in FAILED_RESULTS or state == "failed":
            return "completed-failed"
    verdict = journal_verdict(journal_text(unit))
    if verdict == "success":
        return "completed-success"
    if verdict == "failed":
        return "completed-failed"
    return "orphan"


def past_deadline(rec: dict) -> bool:
    now = now_dt()
    deadline = rec.get("deadline_ts") or ""
    if deadline:
        try:
            return now >= parse_iso(str(deadline))
        except ValueError:
            log(f"WARN: bad deadline_ts={deadline!r} id={rec.get('id')}")
    try:
        start = parse_iso(str(rec.get("ts") or ""))
        minutes = int(rec.get("deadline_min") or 90)
        return (now - start).total_seconds() >= minutes * 60
    except (ValueError, TypeError):
        return False


def redispatch(rec: dict, provider: str, model: str) -> int:
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
    log(f"REDISPATCH unit={new_unit} chain={chain_id} hop={hop + 1} seat={provider}/{model}")
    r = subprocess.run(cmd, check=False)
    return r.returncode


def process(rec: dict) -> str:
    """Return ok | redispatched | escalated | fail-loud | waiting | in-flight | closed."""
    kind = classify(rec)
    unit = rec.get("unit") or ""
    if kind == "in-flight":
        log(f"in-flight unit={unit} id={rec.get('id')}")
        return "in-flight"
    if kind == "completed-success":
        exit_status = show_prop(unit, "ExecMainStatus") or "0"
        close_entry(rec, "completed", verdict="success", result="success",
                    exit_status=exit_status)
        log(f"closed completed/success unit={unit} id={rec.get('id')}")
        return "closed"
    if kind == "completed-failed":
        result = show_prop(unit, "Result") or "exit-code"
        exit_status = show_prop(unit, "ExecMainStatus") or "1"
        close_entry(rec, "completed", verdict="failed", result=result,
                    exit_status=exit_status)
        log(f"closed completed/failed unit={unit} id={rec.get('id')} result={result}")
        return "closed"
    # orphan
    if not past_deadline(rec):
        log(f"orphan waiting (before deadline) unit={unit} id={rec.get('id')}")
        return "waiting"
    retries = int(rec.get("retries") or 0)
    if retries >= 2:
        write_stop_reason(rec)
        close_entry(rec, "escalated", verdict="orphan")
        loud(
            "DISPATCH-ORPHAN",
            f"unit={unit} chain={rec.get('chain_id')} retries={retries} "
            "— STOP-REASON dispatch-orphan (senior conference)",
        )
        return "escalated"
    packet = str(rec.get("packet_path") or "")
    if not packet or not Path(packet).is_file():
        log(f"orphan has no packet file unit={unit} path={packet!r} — fail-loud")
        loud(
            "DISPATCH-ORPHAN-NO-PACKET",
            f"unit={unit} chain={rec.get('chain_id')} retries={retries} "
            "packet missing; cannot re-dispatch",
        )
        return "fail-loud"
    picked = pick_seat(str(rec.get("provider") or ""))
    if not picked:
        log(f"no healthy seat for re-dispatch unit={unit} — fail-loud")
        return "fail-loud"
    provider, model, _reason = picked
    rc = redispatch(rec, provider, model)
    if rc != 0:
        log(f"re-dispatch failed rc={rc} unit={unit} — fail-loud")
        return "fail-loud"
    close_entry(
        rec,
        "redispatched",
        verdict="orphan",
        new_unit=f"{unit}-r{retries + 1}",
        seat=f"{provider}/{model}",
    )
    return "redispatched"


def usage() -> None:
    print(
        "usage: fleet-dispatch-canary [--help]\n\n"
        "Walk the pi-systemd-run dispatch ledger. Close completed units,\n"
        "re-dispatch orphans past deadline, escalate after 2 retries.\n"
        "Wired into fleet-heartbeat-tier1 block 32. No flags on the happy path.",
        file=sys.stderr,
    )


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in {"-h", "--help"}:
        usage()
        return 0
    latest = load_latest()
    open_recs = [r for r in latest.values() if r.get("status") == "open"]
    if not open_recs:
        log("no open dispatch-ledger entries")
        return 0
    open_recs.sort(key=lambda r: (str(r.get("ts") or ""), str(r.get("id") or "")))
    fail_loud = 0
    counts = {
        "in-flight": 0,
        "closed": 0,
        "waiting": 0,
        "redispatched": 0,
        "escalated": 0,
        "fail-loud": 0,
    }
    for rec in open_recs:
        action = process(rec)
        counts[action] = counts.get(action, 0) + 1
        if action == "fail-loud":
            fail_loud += 1
    log(
        f"tick open={len(open_recs)} in-flight={counts['in-flight']} "
        f"closed={counts['closed']} waiting={counts['waiting']} "
        f"redispatched={counts['redispatched']} escalated={counts['escalated']} "
        f"fail-loud={counts['fail-loud']}"
    )
    return 1 if fail_loud else 0


if __name__ == "__main__":
    sys.exit(main())
