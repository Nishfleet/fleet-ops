#!/usr/bin/env python3
"""NORTH STAR quality guard (fleet-ops#459).

Verifies that the quality-routing config keeps the primary SLOs
(revert_rate, defect_rate, overturn_rate) as the mechanical north star
and that the role-quality-gates catalog ties reviewer, senior-auditor,
and researcher to the quality scoreboard. A PR that drops one of these
SLOs or weakens a cut above the current ceiling is rejected.

Usage:
  python3 lib/north-star-quality.py verify \
      --quality-routing Q.json --role-gates R.json
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Any

# NORTH STAR primary SLOs for quality-weighted routing. These correspond
# to the gap-closure loop's decision / work / output quality metrics.
PRIMARY_SLO_METRICS = ("revert_rate", "defect_rate", "overturn_rate")

# Current ceilings. Any PR that weakens a cut above these values is
# a speed/resilience win that costs quality and is rejected at the gate.
QUALITY_CUT_CEILINGS = {
    "revert_rate_cut": 0.04,
    "defect_rate_cut": 0.40,
    "overturn_rate_cut": 0.25,
}

SCOREBOARD_ROLES = ("reviewer", "senior-auditor", "researcher")


def load_json(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: root must be an object")
    return data


def verify_quality_routing(path: str) -> list[str]:
    errors: list[str] = []
    try:
        cfg = load_json(path)
    except (OSError, ValueError) as exc:
        return [f"cannot load quality-routing config: {exc}"]

    for key in QUALITY_CUT_CEILINGS:
        if key not in cfg:
            errors.append(f"missing primary SLO cut: {key}")
            continue
        val = cfg[key]
        if not isinstance(val, (int, float)):
            errors.append(f"{key} must be a number, got {type(val).__name__}")
            continue
        ceiling = QUALITY_CUT_CEILINGS[key]
        if float(val) > float(ceiling):
            errors.append(
                f"{key}={val} weakens the NORTH STAR ceiling {ceiling}"
            )

    stale = cfg.get("stale_snapshot_secs")
    if not isinstance(stale, int) or stale < 1:
        errors.append("stale_snapshot_secs must be a positive integer")

    return errors


def verify_role_gates(path: str) -> list[str]:
    errors: list[str] = []
    try:
        cfg = load_json(path)
    except (OSError, ValueError) as exc:
        return [f"cannot load role-gates config: {exc}"]

    roles = cfg.get("roles") or []
    if not isinstance(roles, list):
        return ["role-gates 'roles' must be a list"]

    by_id: dict[str, Any] = {}
    for role in roles:
        if isinstance(role, dict):
            by_id[str(role.get("id") or "")] = role

    for rid in SCOREBOARD_ROLES:
        role = by_id.get(rid)
        if not isinstance(role, dict):
            errors.append(f"missing role: {rid}")
            continue
        gate = str(role.get("gate") or "")
        if "scoreboard" not in gate.lower():
            errors.append(
                f"{rid} gate must reference the quality scoreboard, got: {gate!r}"
            )

    return errors


def cmd_verify(args: argparse.Namespace) -> int:
    q_errors = verify_quality_routing(args.quality_routing)
    r_errors = verify_role_gates(args.role_gates)
    errors = q_errors + r_errors
    if errors:
        for err in errors:
            print(f"NORTH-STAR-QUALITY: {err}", file=sys.stderr)
        return 1
    print("NORTH-STAR-QUALITY: primary SLOs wired and cuts are not weakened")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("verify", help="fail-closed check of the NORTH STAR gate")
    p.add_argument("--quality-routing", required=True)
    p.add_argument("--role-gates", required=True)
    p.set_defaults(func=cmd_verify)
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
