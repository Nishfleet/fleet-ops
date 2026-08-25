#!/usr/bin/env python3
"""Canonical pi-packet guard.

Reads a Claude Bash tool JSON payload from stdin. If the command is a
`pi --print` invocation, inspect the redirected packet log and classify the
failure mode:

- launcher fault  — command used `nohup` or a trailing `&`, the process was
  reaped, and the log is short with no verdict line. Tell the agent to use
  `pi-systemd-run` instead of `nohup ... &`.
- lane fault      — log contains rate limit / quota / ETIMEDOUT. Tell the
  agent to rotate the seat and not charge the task.

A fault exits 2 and writes a one-line reason to stderr.  Exits 0 otherwise.
"""

import json
import os
import re
import sys

LANE_FAULT = re.compile(r"rate_limit|ETIMEDOUT|Token Plan|quota|insufficient", re.I)
VERDICT = re.compile(r"^(RESULT|DRILL|RESTORE-WAVE|SKIP|OK)\b", re.M)
NOHUP = re.compile(r"\bnohup\b")
REDIRECT = re.compile(r"pi --print[^>]*>\s*\"?([^\s\"&;|]+)")


def _is_launcher_hint(command: str) -> bool:
    """Return True if the command uses nohup or a trailing background '&'."""
    if NOHUP.search(command):
        return True
    stripped = command.rstrip()
    # Single trailing &, not the shell && operator.
    if stripped.endswith("&") and not stripped.endswith("&&"):
        return True
    return False


def _log_path(command: str) -> str | None:
    m = REDIRECT.search(command)
    if not m:
        return None
    return os.path.expanduser(m.group(1))


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    cmd = (payload.get("tool_input") or {}).get("command", "")
    if "pi --print" not in cmd:
        return 0

    log = _log_path(cmd)
    if not log:
        return 0

    if not os.path.isfile(log):
        # A nohup/background launch may be reaped before the log is written.
        if _is_launcher_hint(cmd):
            print(
                "pi-packet guard: launcher fault — command used nohup or trailing '&' "
                "and no packet log was produced. Use `pi-systemd-run` instead of "
                "`nohup ... &` so the process outlives the launching shell.",
                file=sys.stderr,
            )
            return 2
        return 0

    try:
        with open(log, errors="replace") as f:
            text = f.read()
    except Exception:
        return 0

    lines = [l for l in text.splitlines() if l.strip()]
    problems: list[str] = []

    if LANE_FAULT.search(text):
        problems.append(
            "lane fault detected (rate limit / spawn timeout / quota) — "
            "rotate the seat, do not charge the task"
        )

    if len(lines) <= 5 and not VERDICT.search(text):
        if _is_launcher_hint(cmd):
            problems.append(
                "launcher fault — command used nohup or trailing '&' and the "
                "process was reaped before producing a verdict. Use "
                "`pi-systemd-run` instead of `nohup ... &`"
            )
        else:
            problems.append(
                f"suspiciously short output ({len(lines)} lines) with no verdict line — "
                "likely a narrate-and-quit or dead-on-arrival run"
            )

    if problems:
        print(
            "pi-packet guard: the packet log at "
            + log
            + " shows: "
            + "; ".join(problems)
            + ". Do NOT report this packet as dispatched/working.",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
