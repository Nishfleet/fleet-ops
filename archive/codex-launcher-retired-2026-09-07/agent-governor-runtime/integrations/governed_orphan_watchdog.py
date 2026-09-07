#!/usr/bin/env python3
"""Remove any governed workload process whose recorded supervisor is gone.

Cooperative same-user orphan cleanup: markers in /proc/<pid>/environ can be
forged or stripped by the same user. Exact PID + start-ticks + managed-marker
+ dead-supervisor revalidation immediately before each signal prevents
accidental cross-process kills. Unmarked processes are always preserved.
"""

from __future__ import annotations

import argparse
import os
import signal
import time
from pathlib import Path


def process_identity(proc_dir: Path) -> tuple[str, str] | None:
    try:
        content = (proc_dir / "stat").read_text(encoding="utf-8")
        fields_after_comm = content.rsplit(")", 1)[1].split()
        return fields_after_comm[0], fields_after_comm[19]
    except (FileNotFoundError, IndexError, PermissionError, ProcessLookupError, OSError):
        return None


def start_ticks(proc_dir: Path) -> str | None:
    identity = process_identity(proc_dir)
    return identity[1] if identity is not None else None


def environment(proc_dir: Path) -> dict[bytes, bytes]:
    try:
        entries = (proc_dir / "environ").read_bytes().split(b"\0")
    except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
        return {}
    return dict(entry.split(b"=", 1) for entry in entries if b"=" in entry)


def clock_ticks() -> int:
    return int(os.sysconf(os.sysconf_names["SC_CLK_TCK"]))


def uptime_seconds(proc_root: Path) -> float:
    return float((proc_root / "uptime").read_text(encoding="utf-8").split()[0])


def process_age_seconds(proc_dir: Path, proc_root: Path) -> float | None:
    """Kernel process age from start ticks + /proc uptime (not wall clock)."""
    ticks = start_ticks(proc_dir)
    if ticks is None:
        return None
    try:
        start = int(ticks)
        uptime = uptime_seconds(proc_root)
        hz = clock_ticks()
    except (FileNotFoundError, OSError, ValueError, IndexError, KeyError):
        return None
    if hz <= 0:
        return None
    return uptime - (start / float(hz))


def supervisor_alive(proc_root: Path, env: dict[bytes, bytes]) -> bool:
    try:
        pid = int(env[b"AGENT_GOVERNOR_SUPERVISOR_PID"])
        expected = env[b"AGENT_GOVERNOR_SUPERVISOR_START_TICKS"].decode("ascii")
    except (KeyError, ValueError, UnicodeDecodeError):
        return False
    identity = process_identity(proc_root / str(pid))
    return identity is not None and identity[0] != "Z" and identity[1] == expected


def is_managed(env: dict[bytes, bytes]) -> bool:
    return env.get(b"AGENT_GOVERNOR_MANAGED") == b"1"


def still_orphan_target(proc_root: Path, pid: int, expected_ticks: str) -> bool:
    """Revalidate identity immediately before TERM/KILL; preserve on any drift."""
    proc_dir = proc_root / str(pid)
    if start_ticks(proc_dir) != expected_ticks:
        return False
    env = environment(proc_dir)
    if not is_managed(env):
        return False
    if supervisor_alive(proc_root, env):
        return False
    return True


def stale_managed_processes(proc_root: Path, grace_seconds: int) -> list[tuple[int, str]]:
    stale: list[tuple[int, str]] = []
    for proc_dir in proc_root.glob("[0-9]*"):
        try:
            pid = int(proc_dir.name)
        except ValueError:
            continue
        env = environment(proc_dir)
        if not is_managed(env):
            continue
        age = process_age_seconds(proc_dir, proc_root)
        if age is None or age < grace_seconds or supervisor_alive(proc_root, env):
            continue
        ticks = start_ticks(proc_dir)
        if ticks is not None:
            stale.append((pid, ticks))
    return stale


def terminate(stale: list[tuple[int, str]], proc_root: Path, dry_run: bool) -> tuple[int, int]:
    # Initialize survivor state before any timing loop so a forward monotonic
    # jump cannot leave `survivors` unbound.
    survivors: list[tuple[int, str]] = list(stale)
    if dry_run:
        return len(stale), 0
    for pid, ticks in survivors:
        if still_orphan_target(proc_root, pid, ticks):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 10
    while True:
        survivors = [
            (pid, ticks) for pid, ticks in stale if still_orphan_target(proc_root, pid, ticks)
        ]
        if not survivors:
            return len(stale), 0
        if time.monotonic() >= deadline:
            break
        time.sleep(0.25)
    for pid, ticks in survivors:
        if still_orphan_target(proc_root, pid, ticks):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    kill_deadline = time.monotonic() + 1
    while True:
        survivors = [
            (pid, ticks) for pid, ticks in survivors if still_orphan_target(proc_root, pid, ticks)
        ]
        remaining = len(survivors)
        if not remaining:
            return len(stale), 0
        if time.monotonic() >= kill_deadline:
            break
        time.sleep(0.05)
    remaining = sum(1 for pid, ticks in survivors if still_orphan_target(proc_root, pid, ticks))
    return len(stale), remaining


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--grace-seconds", type=int, default=120)
    args = parser.parse_args()
    stale = stale_managed_processes(Path("/proc"), max(0, args.grace_seconds))
    count, survivors = terminate(stale, Path("/proc"), args.dry_run)
    print(f"governed_orphans={count} action={'reported' if args.dry_run else 'cleaned'} survivors={survivors}")
    return 1 if survivors else 0


if __name__ == "__main__":
    raise SystemExit(main())
