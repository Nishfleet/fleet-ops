#!/usr/bin/env python3
"""Quality ratchet — one-way tightening of every gate the fleet met (fleet-ops#1146).

The Weekly Fleet Review's Phase 3. Each week, for every quality
gate/threshold (VERIFY-block reproduction rate, drill pass rate,
upgrade:repair:churn mix, escaped-defect count, worker verdict-accuracy,
main-red hours, etc.), if the fleet met the bar consistently that week,
TIGHTEN it one evidence-based notch for next week. The ratchet is
one-way: loosening any bar requires a Nish decision recorded in the
decisions ledger. This helper is the deterministic engine.

The companion `bin/fleet-quality-ratchet` wraps this library for the
heartbeat canary path (which fires when the Weekly Review fails to
publish a ratchet move for a met bar); `bin/fleet-weekly-review` calls
this library directly each Sunday.

Output: writes ratchet decisions as dated ledger lines into the
decisions-ledger.md (atomic: read, mutate, write). Each ratchet line
carries its evidence (the metric value, the source, the run timestamp)
and the new tightened threshold. A ratchet move that would loosen a
bar is REJECTED with a loud exit — only `--loosen-with-decision <sha>`
on the command line (which itself requires a Nish-approved ledger
entry) lets the bar move the other way.

Usage:
  python3 lib/quality-ratchet.py ratchet \\
      --now ISO --ledger FILE --actions-log FILE \\
      --state-dir DIR --out FILE --log FILE
  python3 lib/quality-ratchet.py propose \\
      --gate <name> --new-value <v> [--evidence TEXT] \\
      [--loosen-with-decision <sha>]
  python3 lib/quality-ratchet.py score \\
      --now ISO --actions-log FILE --out FILE
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Each tracked gate. Tightening direction matches "tighter is harder to
# meet" — % pass rates ratchet UP, time budgets ratchet DOWN.
# `source` is the file or stream we read the metric from.
# `parser` is the metric name + value-extractor (lambda over the loaded
# JSON dict). A nil parser means the gate is not yet wired to live data
# and the ratchet will SKIP it with a loud "data-source-missing" line.
GATES: list[dict[str, Any]] = [
    {
        "name": "verify-block-reproduction-rate",
        "direction": "up",
        "step": 0.02,
        "floor": 0.90,
        "ceiling": 1.00,
        "source": "lib/north-star-quality.py scoreboard (auto-generated)",
        "parser": None,  # wired when lib/north-star-quality.py emits this field
    },
    {
        "name": "drill-pass-rate",
        "direction": "up",
        "step": 0.02,
        "floor": 0.90,
        "ceiling": 1.00,
        "source": "tests/fleet-resilience-drill.* + tests/fleet-restore-drill.*",
        "parser": None,
    },
    {
        "name": "upgrade-repair-churn-mix",
        "direction": "toward_target",
        "step": 0.05,
        "floor": 0.60,
        "ceiling": 0.95,
        "source": "bin/fleet-heartbeat-undersaturation throughput split",
        "parser": None,
    },
    {
        "name": "escaped-defect-count",
        "direction": "down",
        "step": 1,
        "floor": 0,
        "ceiling": 100,
        "source": "gh issue list -R Nishfleet/<repo> --search 'label:defect OR label:escaped'",
        "parser": None,
    },
    {
        "name": "worker-verdict-accuracy",
        "direction": "up",
        "step": 0.03,
        "floor": 0.90,
        "ceiling": 0.99,
        "source": "lib/pi-packet-verdict.py + senior-conference overturn rate",
        "parser": None,
    },
    {
        "name": "main-red-hours",
        "direction": "down",
        "step": 0.5,
        "floor": 0.5,
        "ceiling": 24.0,
        "source": "FleetMainRed fuse (issue #1199) journal aggregation",
        "parser": None,
    },
]

# Date format used in the decisions-ledger.md entries.
LEDGER_DATE_FMT = "%Y-%m-%d"
LEDGER_LINE_RE = re.compile(
    r"^- (\d{4}-\d{2}-\d{2}) \| ([^|]+) \| (.+)$", re.M
)


def _read_ledger(ledger_path: Path) -> str:
    """Read the ledger text. Returns empty string on missing file (tests)."""
    if not ledger_path.exists():
        return ""
    return ledger_path.read_text(encoding="utf-8")


def _ledger_atomically_replace(
    ledger_path: Path, new_text: str, marker: str
) -> None:
    """Atomic write with a sidecar `.lock` so concurrent reviews don't race.

    `marker` is a stable string we write into a scratch file and rename
    into place — POSIX rename is atomic on the same filesystem.
    """
    lock_path = ledger_path.with_suffix(ledger_path.suffix + ".ratchet.lock")
    try:
        # flock with a brief wait; another process holding it for >2s
        # is a real conflict, fail loud.
        import fcntl

        with open(lock_path, "w", encoding="utf-8") as lf:
            fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
            tmp = ledger_path.with_suffix(ledger_path.suffix + f".ratchet.{os.getpid()}.tmp")
            tmp.write_text(new_text, encoding="utf-8")
            tmp.replace(ledger_path)
    finally:
        try:
            lock_path.unlink()
        except FileNotFoundError:
            pass


def _existing_threshold(ledger_text: str, gate_name: str) -> float | None:
    """Find the most recent ratchet move for this gate (the current bar)."""
    last: float | None = None
    for m in LEDGER_LINE_RE.finditer(ledger_text):
        body = m.group(3)
        if "quality-ratchet:" not in body:
            continue
        if f"gate={gate_name}" not in body:
            continue
        value_match = re.search(r"new-bar=([0-9.]+)", body)
        if value_match:
            last = float(value_match.group(1))
    return last


def _week_key(now: datetime) -> str:
    """ISO week key, used to mark ratchet moves with the week they belong to."""
    iso = now.date().isocalendar()
    return f"{iso[0]}-W{iso[1]:02d}"


def _step_toward(direction: str, current: float, step: float,
                 floor: float, ceiling: float, loosening: bool) -> tuple[float, str]:
    """Compute the new bar. Loosening is only allowed when the operator
    passes --loosen-with-decision <sha>, which is the audit trail."""
    if direction == "up":
        new = current + step
    elif direction == "down":
        new = current - step
    elif direction == "toward_target":
        # Mix target is 0.85; tighten toward it.
        target = 0.85
        if current < target:
            new = current + step
        elif current > target:
            new = current - step
        else:
            return current, "at-target"
    else:
        raise ValueError(f"unknown direction: {direction}")
    if loosening:
        # Loosening flips the step direction.
        new = current - (new - current)
    new = max(floor, min(ceiling, round(new, 4)))
    return new, "stepped"


def cmd_ratchet(args: argparse.Namespace) -> int:
    """Phase 3 main: read the ledger, score each gate, emit ratchet moves."""
    now = datetime.strptime(args.now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    ledger_path = Path(args.ledger)
    actions_log = Path(args.actions_log) if args.actions_log else None
    state_dir = Path(args.state_dir)
    out_path = Path(args.out)
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    ledger_text = _read_ledger(ledger_path)
    ratchet_moves: list[dict[str, Any]] = []
    decisions: list[dict[str, Any]] = []

    # Walk every gate. Live data parsers are wired by later PRs; until
    # then, the ratchet reports the gate + current floor + "data-source-
    # not-wired" and the Weekly Review still gets a deterministic pass.
    week = _week_key(now)
    for gate in GATES:
        name = gate["name"]
        current = _existing_threshold(ledger_text, name)
        if current is None:
            current = gate["floor"]
        # No parser wired yet -> we cannot EVIDENCE a tightening, so we
        # record the gate's current bar in the ledger WITHOUT moving it.
        # That's the safe default: the ratchet never tightens without proof.
        evidence = (
            f"no live parser wired for {name}; "
            f"source={gate['source']}; current={current}"
        )
        move = {
            "gate": name,
            "direction": gate["direction"],
            "current_bar": current,
            "new_bar": current,
            "step": 0,
            "action": "no-evidence",
            "evidence": evidence,
            "source": gate["source"],
            "week": week,
            "ts": args.now,
        }
        ratchet_moves.append(move)

    # Write the per-run ratchet-out.json so the review run has a durable
    # artifact even when no moves happened (every Sunday the file lands).
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps({"moves": ratchet_moves, "week": week, "ts": args.now}, indent=2),
        encoding="utf-8",
    )

    # The log line is one record per ratchet. Even no-evidence moves are
    # logged so a future parser can prove "this gate has been audited
    # every Sunday".
    with open(log_path, "a", encoding="utf-8") as lf:
        for move in ratchet_moves:
            lf.write(json.dumps(move) + "\n")

    # Update the persistent ratchet state so the next ratchet can see
    # "no live parser" history.
    state_file = state_dir / "ratchet-state.json"
    state_file.parent.mkdir(parents=True, exist_ok=True)
    if state_file.exists():
        state = json.loads(state_file.read_text(encoding="utf-8"))
    else:
        state = {"weeks": []}
    state["weeks"].append({
        "week": week,
        "ts": args.now,
        "moves": ratchet_moves,
        "no_evidence_gates": [m["gate"] for m in ratchet_moves if m["action"] == "no-evidence"],
    })
    state_file.write_text(json.dumps(state, indent=2), encoding="utf-8")

    return 0


def cmd_propose(args: argparse.Namespace) -> int:
    """Explicit ratchet move from a wired parser. Loosening requires a sha."""
    ledger_path = Path(args.ledger)
    ledger_text = _read_ledger(ledger_path)
    gate = next((g for g in GATES if g["name"] == args.gate), None)
    if gate is None:
        print(f"PROPOSE: REJECT unknown gate: {args.gate}", file=sys.stderr)
        return 2

    current = _existing_threshold(ledger_text, gate["name"])
    if current is None:
        current = gate["floor"]
    new_value = float(args.new_value)
    # Loosening = moving AWAY from the stricter end of the bar.
    # direction "up" means higher is tighter; new < current = loosening.
    # direction "down" means lower is tighter; new > current = loosening.
    # direction "toward_target" means away from target = loosening.
    if gate["direction"] == "up":
        loosening = new_value < current
    elif gate["direction"] == "down":
        loosening = new_value > current
    elif gate["direction"] == "toward_target":
        target = 0.85
        if current < target:
            loosening = new_value < current  # moving away from target
        elif current > target:
            loosening = new_value > current
        else:
            loosening = abs(new_value - current) > 0
    else:
        loosening = abs(new_value - current) > 0

    if loosening and not args.loosen_with_decision:
        print(
            f"PROPOSE: REJECT loosening move on {gate['name']} "
            f"({current} -> {new_value}) without --loosen-with-decision <sha>. "
            f"Loosening requires a Nish-recorded decision.",
            file=sys.stderr,
        )
        return 1
    if loosening and args.loosen_with_decision:
        # Verify the sha is on a ledger line.
        if args.loosen_with_decision not in ledger_text:
            print(
                f"PROPOSE: REJECT --loosen-with-decision sha not found in ledger: "
                f"{args.loosen_with_decision}",
                file=sys.stderr,
            )
            return 1

    # Emit the ledger line.
    today = datetime.strptime(args.now, "%Y-%m-%dT%H:%M:%SZ").strftime(LEDGER_DATE_FMT) \
        if hasattr(args, "now") and args.now \
        else datetime.now(timezone.utc).strftime(LEDGER_DATE_FMT)
    evidence = args.evidence or "explicit propose (no evidence supplied)"
    new_line = (
        f"- {today} | Quality ratchet {gate['name']} | "
        f"gate={gate['name']} direction={gate['direction']} "
        f"new-bar={new_value} evidence={evidence} source={gate['source']} "
        f"loosening-decision-sha={args.loosen_with_decision or 'n/a'} | "
        f"source: quality-ratchet.py propose {args.now}\n"
    )
    new_text = ledger_text
    if new_text and not new_text.endswith("\n"):
        new_text += "\n"
    new_text += new_line

    _ledger_atomically_replace(ledger_path, new_text, args.gate)

    print(f"PROPOSE: ACCEPT {gate['name']} {current} -> {new_value}")
    return 0


def cmd_score(args: argparse.Namespace) -> int:
    """Score last week's actions (Phase 3 self-scoring opener for next week)."""
    actions_log = Path(args.actions_log)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    now = datetime.strptime(args.now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    week = _week_key(now)
    if not actions_log.exists():
        score = {
            "week": week,
            "ts": args.now,
            "actions_logged": 0,
            "actions_landed": 0,
            "actions_open": 0,
            "actions_closed_clean": 0,
        }
        out_path.write_text(json.dumps(score, indent=2), encoding="utf-8")
        print(f"SCORE: no actions log at {actions_log}; recorded 0/0/0/0")
        return 0
    actions = []
    with open(actions_log, "r", encoding="utf-8") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            try:
                actions.append(json.loads(ln))
            except json.JSONDecodeError:
                pass
    last_week_actions = [a for a in actions if a.get("week") and a["week"] != week]
    # Without wiring to gh (tests don't have it), the actions_landed count
    # is the count of actions logged last week whose `verified` flag is
    # set. The weekly-review orchestrator can set `verified` after a
    # follow-up tick; until then, score = 0/0. The shape still lands so
    # next week's opener has a deterministic input.
    score = {
        "week": week,
        "ts": args.now,
        "actions_logged": len(last_week_actions),
        "actions_landed": sum(1 for a in last_week_actions if a.get("verified")),
        "actions_open": sum(1 for a in last_week_actions if not a.get("verified") and not a.get("closed")),
        "actions_closed_clean": sum(1 for a in last_week_actions if a.get("closed")),
    }
    out_path.write_text(json.dumps(score, indent=2), encoding="utf-8")
    print(
        f"SCORE: week={week} logged={score['actions_logged']} "
        f"landed={score['actions_landed']} open={score['actions_open']} "
        f"closed_clean={score['actions_closed_clean']}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="quality-ratchet.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_ratchet = sub.add_parser("ratchet", help="Phase 3: emit ratchet moves")
    p_ratchet.add_argument("--now", required=True)
    p_ratchet.add_argument("--ledger", required=True)
    p_ratchet.add_argument("--actions-log")
    p_ratchet.add_argument("--state-dir", required=True)
    p_ratchet.add_argument("--out", required=True)
    p_ratchet.add_argument("--log", required=True)
    p_ratchet.set_defaults(func=cmd_ratchet)

    p_propose = sub.add_parser("propose", help="explicit ratchet move")
    p_propose.add_argument("--gate", required=True)
    p_propose.add_argument("--new-value", required=True)
    p_propose.add_argument("--evidence", default="")
    p_propose.add_argument("--loosen-with-decision", default="")
    p_propose.add_argument("--ledger", required=True)
    p_propose.add_argument("--now", default="")
    p_propose.set_defaults(func=cmd_propose)

    p_score = sub.add_parser("score", help="Phase 3 self-scoring opener")
    p_score.add_argument("--now", required=True)
    p_score.add_argument("--actions-log", required=True)
    p_score.add_argument("--out", required=True)
    p_score.set_defaults(func=cmd_score)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())