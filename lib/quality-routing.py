#!/usr/bin/env python3
"""Quality-weighted seat routing (fleet-ops#457).

Reads a #456-shaped scoreboard snapshot plus config/quality-routing.json
and decides which lanes lose heavy/keystone work. Fail-closed on the
numbers, fail-open on a missing snapshot (a broken scoreboard must not
brick pick_seat).

Snapshot schema (written by fleet-ops#456; drills inject fixtures):

  {
    "generated_at": "2026-08-26T20:00:00Z",
    "lanes": {
      "cursor/composer-2.5": {
        "role": "builder",
        "revert_rate": 0.12,
        "defect_rate": 0.20,
        "overturn_rate": 0.0
      }
    }
  }

Usage:
  python3 lib/quality-routing.py heavy-bans --thresholds T.json --scoreboard S.json
  python3 lib/quality-routing.py decide --provider P --model M --need-capable 0|1 \\
      --thresholds T.json --scoreboard S.json
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _parse_ts(raw: str) -> datetime | None:
    raw = (raw or "").strip()
    if not raw:
        return None
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def load_json(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: root must be an object")
    return data


def snapshot_age_secs(snapshot: dict[str, Any], now: datetime | None = None) -> int | None:
    generated = _parse_ts(str(snapshot.get("generated_at") or ""))
    if generated is None:
        return None
    now = now or datetime.now(timezone.utc)
    return max(0, int((now - generated).total_seconds()))


def lane_over_cut(metrics: dict[str, Any], thresholds: dict[str, Any]) -> list[str]:
    """Return the metric names that exceed their cut. Empty = healthy."""
    hits: list[str] = []
    for key in ("revert_rate", "defect_rate", "overturn_rate"):
        cut = thresholds.get(f"{key}_cut")
        if not isinstance(cut, (int, float)):
            continue
        value = metrics.get(key)
        if not isinstance(value, (int, float)):
            continue
        if float(value) > float(cut):
            hits.append(key)
    return hits


def evaluate_snapshot(
    thresholds: dict[str, Any],
    snapshot: dict[str, Any] | None,
    *,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Classify the snapshot and list heavy-banned lanes.

    status:
      missing  — no snapshot object (pick_seat must not cut)
      stale    — generated_at older than stale_snapshot_secs (no cuts)
      ok       — numbers applied
    """
    stale_secs = thresholds.get("stale_snapshot_secs", 86400)
    if not isinstance(stale_secs, int) or stale_secs < 1:
        stale_secs = 86400

    if not snapshot:
        return {
            "status": "missing",
            "heavy_bans": [],
            "reasons": {},
            "age_secs": None,
        }

    age = snapshot_age_secs(snapshot, now=now)
    if age is None or age > stale_secs:
        return {
            "status": "stale",
            "heavy_bans": [],
            "reasons": {},
            "age_secs": age,
        }

    bans: list[str] = []
    reasons: dict[str, list[str]] = {}
    lanes = snapshot.get("lanes") or {}
    if isinstance(lanes, dict):
        for lane, metrics in lanes.items():
            if not isinstance(lane, str) or not isinstance(metrics, dict):
                continue
            hits = lane_over_cut(metrics, thresholds)
            if hits:
                bans.append(lane)
                reasons[lane] = hits
    bans.sort()
    return {
        "status": "ok",
        "heavy_bans": bans,
        "reasons": reasons,
        "age_secs": age,
    }


def decide(
    provider: str,
    model: str,
    need_capable: bool,
    evaluation: dict[str, Any],
) -> str:
    """Return ok | light-only. light-only means skip when need_capable."""
    lane = f"{provider}/{model}"
    if lane in evaluation.get("heavy_bans", []) and need_capable:
        return "light-only"
    return "ok"


def _cmd_heavy_bans(args: argparse.Namespace) -> int:
    thresholds = load_json(args.thresholds)
    snapshot = None
    if args.scoreboard and Path(args.scoreboard).is_file():
        snapshot = load_json(args.scoreboard)
    result = evaluate_snapshot(thresholds, snapshot)
    for lane in result["heavy_bans"]:
        print(lane)
    return 0


def _cmd_decide(args: argparse.Namespace) -> int:
    thresholds = load_json(args.thresholds)
    snapshot = None
    if args.scoreboard and Path(args.scoreboard).is_file():
        snapshot = load_json(args.scoreboard)
    result = evaluate_snapshot(thresholds, snapshot)
    need = str(args.need_capable) in {"1", "true", "True"}
    print(decide(args.provider, args.model, need, result))
    return 0


def _cmd_evaluate(args: argparse.Namespace) -> int:
    thresholds = load_json(args.thresholds)
    snapshot = None
    if args.scoreboard and Path(args.scoreboard).is_file():
        snapshot = load_json(args.scoreboard)
    print(json.dumps(evaluate_snapshot(thresholds, snapshot), indent=2, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    def add_common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--thresholds", required=True)
        p.add_argument("--scoreboard", default="")

    p_bans = sub.add_parser("heavy-bans")
    add_common(p_bans)
    p_bans.set_defaults(func=_cmd_heavy_bans)

    p_dec = sub.add_parser("decide")
    add_common(p_dec)
    p_dec.add_argument("--provider", required=True)
    p_dec.add_argument("--model", required=True)
    p_dec.add_argument("--need-capable", default="0")
    p_dec.set_defaults(func=_cmd_decide)

    p_ev = sub.add_parser("evaluate")
    add_common(p_ev)
    p_ev.set_defaults(func=_cmd_evaluate)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
