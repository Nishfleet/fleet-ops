#!/usr/bin/env python3
"""fleet-heartbeat-failed-notify — rate-limited Telegram page on unit failure.

Triggered by systemd OnFailure= from any unit that still wires this target
(e.g. pi-transport-check.service). Maintains a per-unit consecutive-failure
counter and only pages after the configured threshold is reached within the
configured time window.

The escalation matrix (unit-escalation@) and Prometheus last-resort remain the
primary failure coverage; this page is a dampened last-resort alarm, not a
per-failure text.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

THRESHOLD = int(os.environ.get("FLEET_HEARTBEAT_FAILED_NOTIFY_THRESHOLD", 3))
WINDOW = int(os.environ.get("FLEET_HEARTBEAT_FAILED_NOTIFY_WINDOW", 900))
STATE_DIR = os.environ.get(
    "FLEET_HEARTBEAT_FAILED_NOTIFY_STATE_DIR",
    "/home/nish/.local/state/fleet-heartbeat/failed-notify",
)
HERMES = os.environ.get("HERMES") or shutil.which("hermes") or "/home/nish/.local/bin/hermes"
UNIT = os.environ.get("MONITOR_UNIT", "")


def _safe_name(unit: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", unit) or "unknown"


def _hostname() -> str:
    # Short hostname, matching `hostname -s` behaviour.
    return socket.gethostname().split(".")[0]


def _load_state(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def _save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
        f.write("\n")
    os.replace(tmp, path)


def main() -> int:
    if not UNIT:
        print("fleet-heartbeat-failed-notify: MONITOR_UNIT unset, nothing to do")
        return 0

    state_dir = Path(STATE_DIR)
    safe = _safe_name(UNIT)
    state_path = state_dir / f"{safe}.json"
    lock_path = state_dir / f"{safe}.lock"
    state_dir.mkdir(parents=True, exist_ok=True)

    now = time.time()

    with open(lock_path, "a+", encoding="utf-8") as lk:
        try:
            fcntl.flock(lk, fcntl.LOCK_EX)
        except OSError:
            pass

        state = _load_state(state_path)
        last_seen = state.get("last_seen", 0.0)
        count = state.get("count", 0)

        if now - float(last_seen) > WINDOW:
            count = 0

        count += 1
        state["last_seen"] = now
        state["count"] = count

        if count < THRESHOLD:
            print(
                f"fleet-heartbeat-failed-notify: {UNIT} failure {count}/{THRESHOLD}, "
                "not paging"
            )
            _save_state(state_path, state)
            return 0

        # Threshold reached. Page, then reset counter so we do not page on the
        # very next failure (it starts a fresh streak).
        msg = (
            f"FLEET UNIT FAILED ({THRESHOLD} consecutive): {UNIT} on {_hostname()} "
            f"— check: systemctl --user status {UNIT}"
        )

        env = os.environ.copy()
        env["HERMES_URGENT"] = "1"

        try:
            proc = subprocess.run(
                [HERMES, "send", "-t", "telegram", msg],
                check=False,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except OSError as exc:
            print(f"fleet-heartbeat-failed-notify: hermes exec failed: {exc}", file=sys.stderr)
            # Do not reset the counter; the next failure in the same window gets
            # another chance to page.
            state["count"] = max(THRESHOLD - 1, 0)
            _save_state(state_path, state)
            return 1

        if proc.returncode != 0:
            print(
                f"fleet-heartbeat-failed-notify: hermes send failed (rc={proc.returncode}): "
                f"{proc.stderr.strip()}",
                file=sys.stderr,
            )
            state["count"] = max(THRESHOLD - 1, 0)
            _save_state(state_path, state)
            return 1

        print(
            f"fleet-heartbeat-failed-notify: paged for {UNIT} "
            f"(threshold {THRESHOLD})"
        )
        state["count"] = 0
        state["last_paged"] = now
        _save_state(state_path, state)
        return 0


if __name__ == "__main__":
    sys.exit(main())
