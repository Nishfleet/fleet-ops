#!/usr/bin/env python3
"""Attestation identity-separation gate (fleet-ops#413).

Implementation artifacts and attestation comments must come from DIFFERENT
identities. A worker bot cannot attest; a fixture where the same login both
implements and attests is REJECT.

Pure evaluator: JSON on stdin / --input, verdict JSON on stdout. No GitHub
writes, no network.

Input shape:
  {
    "implementers": ["nishfleet-worker[bot]"],   # GitHub actor logins
                                                 # (PR author / pusher), NOT
                                                 # git author names
    "attestors": ["nish3451"],
    "worker_identities": ["nishfleet-worker[bot]"],  # optional
    "strict": false                                  # optional
  }

Rules:
  1. Any attestor in worker_identities → REJECT (bots cannot attest).
  2. Intersection(implementers, attestors) empty → PASS.
  3. Overlap + (strict OR a worker login is among implementers) → REJECT.
  4. Remaining overlap is owner self-attest of a human-only PR → PASS.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

DEFAULT_WORKER_IDENTITIES = ("nishfleet-worker[bot]",)


def norm(login: Any) -> str:
    if not isinstance(login, str):
        return ""
    return login.strip().lower()


def as_set(value: Any) -> set[str]:
    if not isinstance(value, list):
        return set()
    return {n for n in (norm(item) for item in value) if n}


def evaluate(bundle: dict[str, Any]) -> dict[str, Any]:
    implementers = as_set(bundle.get("implementers"))
    attestors = as_set(bundle.get("attestors"))
    workers = as_set(bundle.get("worker_identities")) or {
        norm(x) for x in DEFAULT_WORKER_IDENTITIES
    }
    strict = bool(bundle.get("strict"))

    if not attestors:
        return {
            "verdict": "PASS",
            "reason": "no attestations to check",
            "overlap": [],
        }

    bot_attestors = sorted(attestors & workers)
    if bot_attestors:
        return {
            "verdict": "REJECT",
            "reason": (
                "worker identity cannot attest: " + ", ".join(bot_attestors)
            ),
            "overlap": bot_attestors,
        }

    overlap = sorted(implementers & attestors)
    if not overlap:
        return {
            "verdict": "PASS",
            "reason": "implementers and attestors are disjoint",
            "overlap": [],
        }

    worker_implemented = bool(implementers & workers)
    if strict or worker_implemented:
        return {
            "verdict": "REJECT",
            "reason": (
                "same identity implemented and attested: " + ", ".join(overlap)
            ),
            "overlap": overlap,
        }

    return {
        "verdict": "PASS",
        "reason": (
            "owner self-attest allowed (no worker implementer): "
            + ", ".join(overlap)
        ),
        "overlap": overlap,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", help="JSON file (default: stdin)")
    args = parser.parse_args()
    if args.input:
        with open(args.input, encoding="utf-8") as fh:
            raw = fh.read()
    else:
        raw = sys.stdin.read()
    try:
        bundle = json.loads(raw or "{}")
    except json.JSONDecodeError as exc:
        print(json.dumps({"verdict": "REJECT", "reason": f"invalid JSON: {exc}"}))
        return 1
    if not isinstance(bundle, dict):
        print(json.dumps({"verdict": "REJECT", "reason": "input is not an object"}))
        return 1
    result = evaluate(bundle)
    print(json.dumps(result))
    return 0 if result["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
