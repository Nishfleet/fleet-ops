#!/usr/bin/env python3
"""Vault sync-conflict resolver (fleet-ops#529).

Syncthing writes name.sync-conflict-YYYYMMDD-HHMMSS-DEVICE.ext when both
machines edited a file. The freeze-on-conflict rule still holds (writers
must stop), but the freeze is self-clearing: this oneshot classifies every
`*.sync-conflict-*` under the vault and:

  identical            -> conflict copy deleted
  base contains conflict (append superset) -> conflict copy deleted
  conflict contains base -> base replaced atomically with the superset
  missing base         -> conflict copy restored onto the base path
  divergent            -> conflict copy moved to _system/conflict-quarantine/
                          under a non-freezing name; base left untouched;
                          a worker is dispatched to merge. Writes resume.

Deterministic, zero-LLM. One resolver on the VPS so resolutions sync
outward from a single authority. Agents never hand-delete a sync-conflict
file and never write into conflict-quarantine except when completing a merge.

Env seams (tests + heartbeat canary):
  FLEET_VAULT                      vault root
  FLEET_VAULT_CONFLICT_LOG         log path
  FLEET_VAULT_CONFLICT_DISPATCH    watchdog-dispatch binary
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

VAULT = Path(os.environ.get("FLEET_VAULT", "/home/nish/workspaces/tooling/nish-vault"))
QUARANTINE = VAULT / "_system" / "conflict-quarantine"
CONFLICT_RE = re.compile(r"\.sync-conflict-\d{8}-\d{6}-[A-Z0-9]+")
LOG = Path(
    os.environ.get(
        "FLEET_VAULT_CONFLICT_LOG",
        str(Path.home() / ".local" / "state" / "vault-conflict-resolver.log"),
    )
)
DISPATCH_BIN = os.environ.get("FLEET_VAULT_CONFLICT_DISPATCH", "/usr/local/sbin/watchdog-dispatch")
DISPATCH_SIG = "vault-conflict"
DISPATCH_COOLDOWN_SEC = 600


def log(msg: str) -> None:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as handle:
        handle.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {msg}\n")


def dispatch(prompt: str) -> None:
    """Hand a divergent conflict to a worker. Never pages Nish."""
    try:
        subprocess.run(
            [DISPATCH_BIN, DISPATCH_SIG, str(DISPATCH_COOLDOWN_SEC)],
            input=prompt,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"DISPATCH-FAIL {exc}")


def classify_and_resolve() -> tuple[list[str], list[str]]:
    resolved: list[str] = []
    quarantined: list[str] = []
    if not VAULT.is_dir():
        return resolved, quarantined
    for cpath in sorted(VAULT.rglob("*.sync-conflict-*")):
        if not cpath.is_file():
            continue
        if CONFLICT_RE.search(cpath.name) is None:
            continue
        base = cpath.parent / CONFLICT_RE.sub("", cpath.name)
        try:
            ctext = cpath.read_bytes()
            btext = base.read_bytes() if base.is_file() else b""
        except OSError as exc:
            log(f"READ-FAIL {cpath}: {exc}")
            continue
        rel = cpath.relative_to(VAULT)
        if not base.is_file():
            cpath.replace(base)
            resolved.append(f"restored-missing-base {rel}")
        elif ctext == btext:
            cpath.unlink()
            resolved.append(f"identical {rel}")
        elif ctext in btext:
            cpath.unlink()
            resolved.append(f"base-superset {rel}")
        elif btext in ctext:
            tmp = base.with_name(f".resolver-{base.name}")
            tmp.write_bytes(ctext)
            tmp.replace(base)
            cpath.unlink()
            resolved.append(f"conflict-superset {rel}")
        else:
            QUARANTINE.mkdir(parents=True, exist_ok=True)
            safe = CONFLICT_RE.sub(".conflict-quarantined", cpath.name)
            dest = QUARANTINE / f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{safe}"
            shutil.move(str(cpath), str(dest))
            quarantined.append(f"{rel} -> {dest.relative_to(VAULT)}")
    return resolved, quarantined


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if "--test" in args:
        dispatch(
            "TEST dispatch (vault-conflict-resolver, netcup-rs2000): proof "
            "the vault conflict resolver can dispatch a worker. No action needed."
        )
        log("TEST dispatch sent")
        return 0
    resolved, quarantined = classify_and_resolve()
    for line in resolved:
        log("RESOLVED " + line)
    for line in quarantined:
        log("QUARANTINED " + line)
    if quarantined:
        log(f"DISPATCHING worker to merge {len(quarantined)} divergent conflict(s)")
        dispatch(
            "Watchdog dispatch (vault-conflict-resolver, netcup-rs2000): "
            f"{len(quarantined)} sync-conflict file(s) in nish-vault could NOT "
            "be auto-merged (divergent edits). The base is kept as-is; the "
            "other version is saved under "
            f"{QUARANTINE}. "
            "Vault writes have resumed. Merge each quarantined copy into its "
            "base by hand: read both versions, combine the real edits from "
            "each, write the merged result to the base path, then delete the "
            "quarantined copy. Read the vault contract first: "
            "/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/"
            "agent-contract.md. Do NOT page Nish. Quarantined conflicts:\n"
            + "\n".join(quarantined[:20])
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
