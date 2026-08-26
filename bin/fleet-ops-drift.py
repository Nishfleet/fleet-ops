#!/usr/bin/env python3
"""fleet-ops-drift — fail-loud drift canary for fleet-ops merge-to-live.

fleet-ops#149: on every heartbeat tick, assert that the live installed state
matches the MANIFEST and that the MANIFEST matches origin/main. Any divergence
is a LOUD finding that exits 1, so fleet-heartbeat.service lands in --state=failed
and the standard escalation matrix fires.

Environment seams (overridden by tests):
  FLEET_OPS_CHECKOUT      path to the fleet-ops deploy checkout
  FLEET_OPS_AUDIT_LOG     drift audit log (default: ~/.local/state/fleet-ops/drift-audit.log)
  FLEET_OPS_TRIAGE        heartbeat triage file for LOUD lines
  FLEET_OPS_SKIP_FETCH    set to 1 to skip the git fetch (offline tests)
  FLEET_OPS_SYSTEMCTL     path to systemctl (default: systemctl)
"""

from __future__ import annotations

import datetime
import os
import re
import subprocess
import sys
from pathlib import Path


HOME = Path(os.environ.get("HOME", "/home/nish"))
CHECKOUT = os.environ.get("FLEET_OPS_CHECKOUT", "")
AUDIT_LOG = Path(os.environ.get("FLEET_OPS_AUDIT_LOG", HOME / ".local" / "state" / "fleet-ops" / "drift-audit.log"))
TRIAGE = Path(os.environ.get("FLEET_OPS_TRIAGE", "/home/nish/workspaces/agent-state/FLEET-HEARTBEAT-TRIAGE.md"))
SKIP_FETCH = os.environ.get("FLEET_OPS_SKIP_FETCH", "") == "1"
SYSTEMCTL = os.environ.get("FLEET_OPS_SYSTEMCTL", "systemctl")

FLEET_PREFIXES = (
    "pi-",
    "siterep-",
    "fleet-",
    "agent-cron-",
    "intake-",
    "oomd-",
    "codex-",
    "escalation-",
    "stop-",
    "unit-escalation",
)

MANAGED_DIRS = (
    HOME / ".local" / "bin",
    HOME / ".config" / "systemd" / "user",
    HOME / ".pi" / "agent" / "prompts",
    HOME / ".config" / "fleet-worker",
    HOME / ".local" / "lib" / "pi-packet",
    HOME / ".local" / "state" / "pi-packet",
)


def now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg: str) -> None:
    print(f"[{now_iso()}] [fleet-ops-drift] {msg}", file=sys.stderr)


def loud(tag: str, msg: str) -> None:
    log(f"LOUD [{tag}] {msg}")
    try:
        with TRIAGE.open("a", encoding="utf-8") as f:
            f.write(f"\n[{now_iso()}] [{tag}] {msg}\n")
    except OSError as e:
        log(f"WARN: could not append to triage {TRIAGE}: {e}")


def audit(unit: str, action: str, why: str) -> None:
    AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
    with AUDIT_LOG.open("a", encoding="utf-8") as f:
        f.write(f"{now_iso()} {unit} {action} actor=fleet-ops-drift why={why}\n")


def fail_loud(tag: str, msg: str) -> None:
    loud(tag, msg)
    audit("fleet-ops", "drift", msg)
    sys.exit(1)


def run(cmd: list[str], cwd: Path | None = None, check: bool = True, capture: bool = True) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            capture_output=capture,
            text=True,
            check=False,
            env={**os.environ, "XDG_RUNTIME_DIR": os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")},
        )
    except FileNotFoundError as e:
        if check:
            fail_loud("DRIFT-FATAL", f"command not found: {cmd[0]}: {e}")
        return 127, "", str(e)
    if check and proc.returncode != 0:
        fail_loud("DRIFT-FATAL", f"{' '.join(cmd)} failed (rc={proc.returncode}): {proc.stderr.strip()}")
    return proc.returncode, proc.stdout, proc.stderr


def find_checkout() -> Path:
    if CHECKOUT:
        return Path(CHECKOUT).resolve()
    self = Path(__file__).resolve()
    return self.parents[1]


def is_fleet_unit(name: str) -> bool:
    return name.startswith(FLEET_PREFIXES)


def unit_has_install(path: Path) -> bool:
    try:
        with path.open("r", encoding="utf-8") as f:
            return re.search(r"^\[Install\]\s*$", f.read(), re.MULTILINE) is not None
    except OSError:
        return False


def parse_manifest(checkout: Path) -> tuple[dict[str, Path], set[str]]:
    """Return (dest->src mapping, set of unit names that should be enabled)."""
    manifest = checkout / "MANIFEST"
    if not manifest.exists():
        fail_loud("DRIFT-FATAL", f"MANIFEST missing at {manifest}")

    entries: dict[str, Path] = {}
    expected_enabled: set[str] = set()
    user_systemd_dir = str(HOME / ".config" / "systemd" / "user") + os.sep

    with manifest.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            src, dest = parts[0], parts[1]
            entries[dest] = (checkout / src).resolve()

            if not dest.startswith(user_systemd_dir):
                continue

            basename = os.path.basename(dest)
            if "@" in basename:
                continue

            repo_file = checkout / src
            if not repo_file.exists():
                continue
            if not unit_has_install(repo_file):
                continue

            expected_enabled.add(basename)

    return entries, expected_enabled


def parse_intake_repos(checkout: Path) -> list[str]:
    intake_json = checkout / "config" / "intake-repos.json"
    if not intake_json.exists():
        return []
    import json

    try:
        data = json.loads(intake_json.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        fail_loud("DRIFT-FATAL", f"intake-repos.json is invalid JSON: {e}")

    return [r["name"] for r in data.get("repos", []) if isinstance(r, dict) and r.get("name")]


def check_checkout(checkout: Path) -> None:
    if not (checkout / ".git").exists():
        fail_loud("DRIFT-FATAL", f"{checkout} is not a git checkout")

    if not SKIP_FETCH:
        rc, _, err = run(["git", "-C", str(checkout), "fetch", "origin"], check=False)
        if rc != 0:
            fail_loud("DRIFT-CHECKOUT", f"git fetch origin failed: {err.strip()}")

    rc, head, _ = run(["git", "-C", str(checkout), "rev-parse", "HEAD"], check=False)
    if rc != 0:
        fail_loud("DRIFT-CHECKOUT", f"git rev-parse HEAD failed: {head}")
    head = head.strip()

    rc, origin_main, _ = run(["git", "-C", str(checkout), "rev-parse", "origin/main"], check=False)
    if rc != 0:
        fail_loud("DRIFT-CHECKOUT", f"git rev-parse origin/main failed: {origin_main}")
    origin_main = origin_main.strip()

    if head != origin_main:
        fail_loud("DRIFT-CHECKOUT", f"checkout stale: HEAD {head[:12]} != origin/main {origin_main[:12]}")

    rc, porcelain, _ = run(
        ["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=no"],
        check=False,
    )
    if rc != 0:
        fail_loud("DRIFT-CHECKOUT", f"git status failed: {porcelain}")
    if porcelain.strip():
        fail_loud("DRIFT-CHECKOUT", f"checkout has uncommitted tracked changes:\n{porcelain.strip()}")

    log(f"checkout {checkout} is at origin/main ({head[:12]}) and clean")


def check_manifest_install(checkout: Path) -> None:
    rc, out, err = run([str(checkout / "install.sh"), "--check"], cwd=checkout, check=False)
    if rc == 2:
        fail_loud("DRIFT-INSTALL", f"install.sh --check usage error: {out}{err}")
    if rc != 0:
        diffs = (out + err).strip()
        fail_loud("DRIFT-INSTALL", f"MANIFEST install drift:\n{diffs}")
    log("install.sh --check: clean")


def check_enabled_units(checkout: Path, expected_enabled: set[str]) -> None:
    expected_enabled = set(expected_enabled)

    for repo in parse_intake_repos(checkout):
        expected_enabled.add(f"pi-intake@{repo}.timer")
        expected_enabled.add(f"pi-scout@{repo}.timer")

    missing: list[str] = []
    for unit in sorted(expected_enabled):
        rc, _, _ = run([SYSTEMCTL, "--user", "is-enabled", unit], check=False, capture=False)
        if rc != 0:
            missing.append(unit)

    rc, out, _ = run(
        [SYSTEMCTL, "--user", "list-unit-files", "--state=enabled", "--no-legend", "--plain"],
        check=False,
    )
    if rc != 0:
        fail_loud("DRIFT-UNITS", f"systemctl list-unit-files failed: {out}")

    extra: list[str] = []
    for line in out.strip().splitlines():
        unit = line.split()[0] if line.split() else ""
        if not unit:
            continue
        if unit in expected_enabled:
            continue
        if is_fleet_unit(unit):
            extra.append(unit)

    if missing or extra:
        parts: list[str] = []
        if missing:
            parts.append(f"missing-enabled: {', '.join(sorted(missing))}")
        if extra:
            parts.append(f"extra-enabled: {', '.join(sorted(extra))}")
        fail_loud("DRIFT-UNITS", "; ".join(parts))

    log(f"enabled units match MANIFEST + intake-repos ({len(expected_enabled)} expected)")


def is_fleet_path(path: Path) -> bool:
    return "fleet-ops" in str(path)


def check_extra_symlinks(checkout: Path, expected_dests: set[str]) -> None:
    checkout_str = str(checkout.resolve())
    findings: list[str] = []

    for d in MANAGED_DIRS:
        if not d.is_dir():
            continue
        for item in d.iterdir():
            if not item.is_symlink():
                continue
            if str(item) in expected_dests:
                continue
            try:
                target = item.resolve()
            except OSError:
                findings.append(f"{item} -> <broken>")
                continue
            target_str = str(target)

            if target_str.startswith(checkout_str + os.sep):
                findings.append(f"{item} -> {target} (extra from current checkout)")
                continue

            if is_fleet_path(target) or is_fleet_path(item):
                findings.append(f"{item} -> {target} (outside current checkout)")
                continue

            if str(d) == str(HOME / ".config" / "systemd" / "user") and is_fleet_unit(item.name):
                findings.append(f"{item} -> {target} (extra fleet unit)")

    if findings:
        fail_loud("DRIFT-EXTRAS", "hand-installed extras or stale symlinks:\n" + "\n".join(findings))

    log("no extra fleet symlinks in managed directories")


def main() -> None:
    checkout = find_checkout()
    expected_dests, expected_enabled = parse_manifest(checkout)

    check_checkout(checkout)
    check_manifest_install(checkout)
    check_enabled_units(checkout, expected_enabled)
    check_extra_symlinks(checkout, set(expected_dests.keys()))

    log("drift canary: clean")
    audit("fleet-ops", "drift-ok", "checkout-and-installed-state-match-main")
    sys.exit(0)


if __name__ == "__main__":
    main()
