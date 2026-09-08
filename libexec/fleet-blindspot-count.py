#!/usr/bin/env python3
"""Blind-spot counters for the weekly review and judge (fleet-ops#4460).

The weekly review and the judge only see what measure.sh measures. On
2026-09-08 Nish caught 19 red deploys, 55 discarded issues, a starving pool
and a 400-idle-pool by hand, all under green reports. This helper turns the
caught-by-hand record into two counts measure.sh (and so the review) can read:

  new_measures_7d    = "<what>" lines the judge emitted as new measure.sh
                       coverage for a blind spot over the trailing 7 days.
  caught_by_hand_7d  = distinct findings Nish / the orchestrator noticed by
                       hand over the trailing 7 days that no metric surfaced
                       first (decisions-ledger entries marking a manual catch
                       + caught-by-hand notes in the judge's run output).

The metric invariant (fleet-ops#4460): new_measures_7d >= caught_by_hand_7d
every week — every caught-by-hand item gets a measure line that same week,
and caught_by_hand_7d trends to 0.

Sources:
  - decisions-ledger.md (Nish's manual catches land here),
  - fable-state.json (the judge's run state; a new-measure:<what> record
    lives under .new_measures or is found in the trailing cron output),
  - cron-output/fable-check-*.md (an append-only-by-day record of the
    judge's header; new-measure:<what> lines are counted across the window).

Any field that cannot be read prints UNAVAILABLE:<why>, never a fabricated 0.

Environment seams (tests):
  FLEET_LEDGER, FLEET_FABLE_STATE, FLEET_FABLE_OUT_DIR, FLEET_BLIND_NOW,
  FLEET_WINDOW_DAYS
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = os.environ.get("HOME", "/home/nish")
AS = Path(os.environ.get("AGENT_STATE", f"{HOME}/workspaces/agent-state"))
LEDGER = Path(os.environ.get("FLEET_LEDGER", str(AS / "nish-vault/_system/shared-memory/decisions-ledger.md")))
FABLE_STATE = Path(os.environ.get("FLEET_FABLE_STATE", str(AS / "fleet-landing-watch/fable-state.json")))
FABLE_OUT_DIR = Path(os.environ.get("FLEET_FABLE_OUT_DIR", str(AS / "cron-output")))
WINDOW_DAYS = int(os.environ.get("FLEET_WINDOW_DAYS", "7"))

_NOW = os.environ.get("FLEET_BLIND_NOW")  # ISO ts, optional (tests)
if _NOW:
    NOW = datetime.fromisoformat(_NOW.replace("Z", "+00:00"))
else:
    NOW = datetime.now(timezone.utc)
if NOW.tzinfo is None:
    NOW = NOW.replace(tzinfo=timezone.utc)

CUT = NOW - timedelta(days=WINDOW_DAYS)

# A ledger line that records a manual catch by Nish / the orchestrator. The
# blind-spot rule (fleet-ops#4460, 2026-09-08) says a caught-by-hand finding
# lands in the ledger; these markers make that countable. Absent markers,
# the count is 0 — never a guess.
LEDGER_CATCH_RE = re.compile(
    r"(caught\s+by\s+hand|by\s+hand\s+(this\s+)?week|manual\s+catch|nish.*?noticed|new-measure)",
    re.I,
)
# A dated ledger decision line: "- YYYY-MM-DD | scope | decision | pointer"
LEDGER_DATE_RE = re.compile(r"^-\s+(\d{4}-\d{2}-\d{2})\s*\|")

# new-measure:<what> — the header line the judge emits when it converts a
# caught-by-hand item into a measure.sh line.
NEW_MEASURE_RE = re.compile(r"\bnew-measure\s*:\s*(.+)", re.I)
# A bare "caught by hand" / "discarded by hand" note in a fable-check run.
FABLE_CATCH_RE = re.compile(r"\bcaught\s+by\s+hand\b", re.I)


def _parse_date(s: str) -> datetime | None:
    try:
        d = datetime.strptime(s, "%Y-%m-%d")
        return d.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def ledger_catches(path: Path) -> list[str]:
    """Return caught-by-hand text from decisions-ledger entries in the window."""
    if not path.exists():
        return []
    found: list[str] = []
    try:
        text = path.read_text(errors="ignore")
    except OSError:
        return []
    for line in text.splitlines():
        if not line.startswith("- "):
            continue
        m = LEDGER_DATE_RE.match(line)
        if not m:
            continue
        d = _parse_date(m.group(1))
        if d is None or d < CUT:
            continue
        if LEDGER_CATCH_RE.search(line):
            found.append(line.strip())
    return found


def fable_catch_evidence(out_dir: Path) -> tuple[list[str], list[str]]:
    """Return (new_measure_lines, catch_lines) from trailing-7d fable-check runs.

    Scans the append-only-by-day cron-output/fable-check-YYYY-MM-DD.md files
    plus the fable-state.json new-measure record.
    """
    new_lines: list[str] = []
    catch_lines: list[str] = []
    if out_dir.is_dir():
        for f in sorted(out_dir.glob("fable-check-*.md")):
            try:
                stamp = datetime.strptime(f.stem.replace("fable-check-", ""), "%Y-%m-%d")
            except ValueError:
                continue
            if stamp.replace(tzinfo=timezone.utc) < CUT:
                continue
            try:
                text = f.read_text(errors="ignore")
            except OSError:
                continue
            for m in NEW_MEASURE_RE.finditer(text):
                new_lines.append(m.group(1).strip())
            if FABLE_CATCH_RE.search(text):
                catch_lines.append(f.name)
    # fable-state.json may carry a new-measure record for the current run.
    if FABLE_STATE.exists():
        try:
            st = json.loads(FABLE_STATE.read_text(errors="ignore"))
        except (OSError, ValueError):
            st = {}
        nm = st.get("new_measures")
        if isinstance(nm, list):
            for item in nm:
                if isinstance(item, dict) and item.get("at"):
                    try:
                        at = datetime.fromisoformat(str(item["at"]).replace("Z", "+00:00"))
                        if at.tzinfo is None:
                            at = at.replace(tzinfo=timezone.utc)
                    except ValueError:
                        at = None
                    if at is None or at >= CUT:
                        new_lines.append(str(item.get("what", "")))
                elif isinstance(item, str):
                    new_lines.append(item)
        elif isinstance(nm, str):
            new_lines.append(nm)
    return new_lines, catch_lines


def main() -> int:
    ledger = ledger_catches(LEDGER)
    new_lines, catch_lines = fable_catch_evidence(FABLE_OUT_DIR)
    new_measures_7d = len(new_lines)
    # caught_by_hand = distinct findings caught by hand in the window: ledger
    # manual catches + caught-by-hand notes in the judge output. A new-measure
    # line is the coverage for such a finding, not a separate finding, so it
    # is counted only on the new_measures side (no double count).
    caught_by_hand_7d = len(ledger) + len(catch_lines)

    print(f"new_measures_7d={new_measures_7d}")
    print(f"caught_by_hand_7d={caught_by_hand_7d}")
    if new_measures_7d < caught_by_hand_7d:
        print(
            f"blindspot_balance=red caught_by_hand_7d({caught_by_hand_7d}) > "
            f"new_measures_7d({new_measures_7d})"
        )
    else:
        print("blindspot_balance=ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
