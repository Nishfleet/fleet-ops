#!/usr/bin/env python3
"""GEO/AEO policy canary (fleet-ops#1245).

Ledger 2026-08-27: fleet executes measurement + owned-content tactics;
community/PR parked for Nish. Brand gate is preview-then-autonomous.
llms.txt is developer-docs-only.

Gates (fail-loud, exit 1):
  1. Policy file exists, parses, and locks allowed_tactics, parked_tactics,
     brand_gate, and llms_txt to the ledger values.
  2. parked_tactics never appear in allowed_tactics.
  3. prompts/worker.md still names the parked tactics, the brand gate,
     and the llms.txt skip.
  4. Every grants[] row is Nish-dated and names a parked tactic.
  5. Every approved_surfaces[] row carries nish_preview_approved=true
     and a YYYY-MM-DD date.
  6. bin/ and systemd/ contain no Reddit-API / PRAW / HARO posting
     machinery (the canary and this library are skipped by name).

Usage:
  geo-aeo.py
  geo-aeo.py --policy PATH --worker PATH --scan-root PATH --triage PATH
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

ALLOWED_TACTICS = ["measurement", "owned-content"]
PARKED_TACTICS = ["reddit-community", "digital-pr"]
BRAND_GATE = "preview-then-autonomous"
LLMS_TXT = "developer-docs-only"
MEASUREMENT_ISSUES = [1236]
OWNED_CONTENT_ISSUES = [1237, 1238]
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SKIP_NAME_RE = re.compile(r"geo-aeo", re.I)
WORKER_NEEDLES = (
    "measurement",
    "owned-content",
    "preview-then-autonomous",
    "Reddit/community",
    "digital-PR",
    "llms.txt",
    "developer docs",
)
DENY_RES = (
    re.compile(r"oauth\.reddit\.com", re.I),
    re.compile(r"(?:www\.)?reddit\.com/api", re.I),
    re.compile(r"(?m)^\s*(?:import praw|from praw(?:\.| import))", re.I),
    re.compile(r"helpareporter(?:\.com)?", re.I),
)
SCAN_DIRS = ("bin", "systemd")


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg: str) -> None:
    print(f"[{_now()}] [fleet-geo-aeo-canary] {msg}", file=sys.stderr)


def loud(tag: str, msg: str, triage: str | None) -> None:
    log(f"LOUD [{tag}] {msg}")
    if not triage:
        return
    try:
        with open(triage, "a", encoding="utf-8") as fh:
            fh.write(f"\n[{_now()}] [{tag}] {msg}\n")
    except OSError as exc:
        log(f"WARN: could not append to triage {triage}: {exc}")


def load_policy(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise ValueError(f"policy missing: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"policy unreadable: {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"policy must be a JSON object: {path}")
    return data


def check_policy(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    allowed = data.get("allowed_tactics")
    parked = data.get("parked_tactics")
    if allowed != ALLOWED_TACTICS:
        errors.append(
            f"allowed_tactics must be {ALLOWED_TACTICS}, got {allowed!r}"
        )
    if parked != PARKED_TACTICS:
        errors.append(
            f"parked_tactics must be {PARKED_TACTICS}, got {parked!r}"
        )
    if data.get("brand_gate") != BRAND_GATE:
        errors.append(
            f"brand_gate must be {BRAND_GATE!r}, got {data.get('brand_gate')!r}"
        )
    if data.get("llms_txt") != LLMS_TXT:
        errors.append(
            f"llms_txt must be {LLMS_TXT!r}, got {data.get('llms_txt')!r}"
        )
    if data.get("measurement_issues") != MEASUREMENT_ISSUES:
        errors.append(
            "measurement_issues must be "
            f"{MEASUREMENT_ISSUES}, got {data.get('measurement_issues')!r}"
        )
    if data.get("owned_content_issues") != OWNED_CONTENT_ISSUES:
        errors.append(
            "owned_content_issues must be "
            f"{OWNED_CONTENT_ISSUES}, got {data.get('owned_content_issues')!r}"
        )
    if isinstance(allowed, list) and isinstance(parked, list):
        overlap = sorted(set(allowed) & set(parked))
        if overlap:
            errors.append(f"parked tactics leaked into allowed_tactics: {overlap}")
    errors.extend(check_grants(data.get("grants"), parked))
    errors.extend(check_surfaces(data.get("approved_surfaces")))
    return errors


def check_grants(grants: Any, parked: Any) -> list[str]:
    if grants is None:
        return ["grants must be an array (empty is the parked default)"]
    if not isinstance(grants, list):
        return [f"grants must be an array, got {type(grants).__name__}"]
    parked_set = set(parked) if isinstance(parked, list) else set()
    errors: list[str] = []
    for i, row in enumerate(grants):
        prefix = f"grants[{i}]"
        if not isinstance(row, dict):
            errors.append(f"{prefix} must be an object")
            continue
        tactic = row.get("tactic")
        granted_by = row.get("granted_by")
        granted_on = row.get("granted_on")
        if tactic not in parked_set:
            errors.append(
                f"{prefix}.tactic must be one of {PARKED_TACTICS}, got {tactic!r}"
            )
        if not isinstance(granted_by, str) or granted_by.strip().lower() != "nish":
            errors.append(
                f"{prefix}.granted_by must be 'nish', got {granted_by!r}"
            )
        if not isinstance(granted_on, str) or not DATE_RE.match(granted_on):
            errors.append(
                f"{prefix}.granted_on must be YYYY-MM-DD, got {granted_on!r}"
            )
    return errors


def check_surfaces(surfaces: Any) -> list[str]:
    if surfaces is None:
        return ["approved_surfaces must be an array (empty until Nish previews)"]
    if not isinstance(surfaces, list):
        return [
            f"approved_surfaces must be an array, got {type(surfaces).__name__}"
        ]
    errors: list[str] = []
    for i, row in enumerate(surfaces):
        prefix = f"approved_surfaces[{i}]"
        if not isinstance(row, dict):
            errors.append(f"{prefix} must be an object")
            continue
        name = row.get("name")
        if not isinstance(name, str) or not name.strip():
            errors.append(f"{prefix}.name must be a non-empty string")
        if row.get("nish_preview_approved") is not True:
            errors.append(
                f"{prefix} must set nish_preview_approved=true "
                f"(got {row.get('nish_preview_approved')!r})"
            )
        approved_on = row.get("approved_on")
        if not isinstance(approved_on, str) or not DATE_RE.match(approved_on):
            errors.append(
                f"{prefix}.approved_on must be YYYY-MM-DD, got {approved_on!r}"
            )
    return errors


def check_worker(path: Path) -> list[str]:
    if not path.is_file():
        return [f"worker prompt missing: {path}"]
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"worker prompt unreadable: {path}: {exc}"]
    missing = [needle for needle in WORKER_NEEDLES if needle not in text]
    if missing:
        return [f"worker.md missing GEO/AEO needles: {missing}"]
    return []


def check_scan(root: Path) -> list[str]:
    errors: list[str] = []
    for dirname in SCAN_DIRS:
        folder = root / dirname
        if not folder.is_dir():
            continue
        for path in folder.rglob("*"):
            if not path.is_file():
                continue
            if SKIP_NAME_RE.search(path.name):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for deny in DENY_RES:
                match = deny.search(text)
                if match:
                    errors.append(
                        f"parked-tactic execution in {path.relative_to(root)}: "
                        f"{match.group(0)!r}"
                    )
                    break
    return errors


def run_check(
    policy_path: Path,
    worker_path: Path,
    scan_root: Path,
    triage: str | None,
) -> int:
    errors: list[str] = []
    try:
        data = load_policy(policy_path)
    except ValueError as exc:
        errors.append(str(exc))
        data = {}
    else:
        errors.extend(check_policy(data))
    errors.extend(check_worker(worker_path))
    errors.extend(check_scan(scan_root))
    if errors:
        for err in errors:
            loud("GEO-AEO-REJECT", err, triage)
        return 1
    loud(
        "GEO-AEO-OK",
        "measurement + owned-content locked; Reddit/community and digital-PR "
        "parked; brand gate preview-then-autonomous; llms.txt developer-docs-only",
        triage,
    )
    return 0


def _first_file(*candidates: Path) -> Path | None:
    for path in candidates:
        if path.is_file():
            return path
    return None


def _checkout_root(here: Path) -> Path:
    """Repo root when running from a checkout; deploy-clone when installed.

    Honor FLEET_OPS_REPO only when it is an existing directory. Other
    canaries reuse that name as a GitHub slug (Nishfleet/fleet-ops); a
    slug is not a checkout path and must not win here.
    """
    env_repo = os.environ.get("FLEET_OPS_REPO")
    if env_repo:
        env_path = Path(env_repo)
        if env_path.is_dir() and (env_path / "config").is_dir():
            return env_path
    parent = here.parent
    # Checkout: lib/geo-aeo.py -> repo root is parent.parent.
    # Installed: ~/.local/lib/pi-packet/geo-aeo.py is not a checkout.
    if parent.name != "pi-packet" and (parent.parent / "config").is_dir():
        return parent.parent
    deploy = Path.home() / "workspaces/tooling/fleet-ops-deploy-clone"
    if (deploy / "config").is_dir():
        return deploy
    return parent.parent


def default_paths() -> tuple[Path, Path, Path]:
    here = Path(__file__).resolve()
    checkout = _checkout_root(here)
    policy = Path(os.environ["FLEET_GEO_AEO_POLICY"]) if os.environ.get(
        "FLEET_GEO_AEO_POLICY"
    ) else _first_file(
        checkout / "config/geo-aeo-policy.json",
        Path.home() / ".local/state/pi-packet/geo-aeo-policy.json",
    )
    worker = Path(os.environ["FLEET_GEO_AEO_WORKER"]) if os.environ.get(
        "FLEET_GEO_AEO_WORKER"
    ) else _first_file(
        checkout / "prompts/worker.md",
        Path.home() / ".pi/agent/prompts/worker.md",
    )
    scan_env = os.environ.get("FLEET_GEO_AEO_SCAN_ROOT")
    scan_root = Path(scan_env) if scan_env else checkout
    if policy is None:
        policy = checkout / "config/geo-aeo-policy.json"
    if worker is None:
        worker = checkout / "prompts/worker.md"
    return policy, worker, scan_root


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="fleet-geo-aeo-canary",
        description="Fail loud if GEO/AEO parked tactics, brand gate, or "
        "llms.txt policy drift.",
    )
    parser.add_argument("--policy", help="path to geo-aeo-policy.json")
    parser.add_argument("--worker", help="path to prompts/worker.md")
    parser.add_argument("--scan-root", help="repo root to scan bin/ and systemd/")
    parser.add_argument("--triage", help="heartbeat triage file")
    args = parser.parse_args(argv)
    policy, worker, scan_root = default_paths()
    if args.policy:
        policy = Path(args.policy)
    if args.worker:
        worker = Path(args.worker)
    if args.scan_root:
        scan_root = Path(args.scan_root)
    triage = args.triage or os.environ.get("FLEET_HEARTBEAT_TRIAGE")
    return run_check(policy, worker, scan_root, triage)


if __name__ == "__main__":
    sys.exit(main())
