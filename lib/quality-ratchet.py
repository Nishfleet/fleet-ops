#!/usr/bin/env python3
"""Weekly Fleet Review quality ratchet (fleet-ops#1222).

Ledger 2026-08-27 | Quality ratchet (Nish): WFR raises the quality bar
every week. Gates that were consistently met tighten one notch; they
never loosen without a Nish ledger waiver. Quality above all.

Usage:
  python3 lib/quality-ratchet.py canary \\
      --ratchet R.json --quality-routing Q.json --wfr-dir DIR [--now ISO]
  python3 lib/quality-ratchet.py evaluate-record \\
      --ratchet R.json --record REC.json [--now ISO]
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

ACTIONS = ("tighten", "hold", "nish-waiver")
KNOB_KEYS = ("revert_rate_cut", "defect_rate_cut", "overturn_rate_cut")
WAIVER_PREFIX = "decisions-ledger.md: "
PLACES = 6
MIN_EVIDENCE = 24


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
    return dt.astimezone(timezone.utc)


def _parse_date(raw: str) -> datetime | None:
    raw = (raw or "").strip()
    if not raw:
        return None
    dt = _parse_ts(raw)
    if dt is not None:
        return dt
    try:
        d = datetime.strptime(raw[:10], "%Y-%m-%d")
    except ValueError:
        return None
    return d.replace(tzinfo=timezone.utc)


def _now(raw: str | None) -> datetime:
    if raw:
        parsed = _parse_ts(raw) or _parse_date(raw)
        if parsed is None:
            raise ValueError(f"invalid --now timestamp: {raw!r}")
        return parsed
    return datetime.now(timezone.utc)


def load_json(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: root must be an object")
    return data


def _num(val: Any, label: str) -> float:
    if not isinstance(val, (int, float)) or isinstance(val, bool):
        raise ValueError(f"{label} must be a number, got {type(val).__name__}")
    return float(val)


def _same(a: float, b: float) -> bool:
    return round(a, PLACES) == round(b, PLACES)


def next_cut(current: float, notch: float, stop_at: float) -> float:
    nxt = round(current - notch, PLACES)
    stop = round(stop_at, PLACES)
    if nxt < stop:
        nxt = stop
    return nxt


def load_ratchet(path: str) -> dict[str, Any]:
    data = load_json(path)
    stale = data.get("stale_days", 8)
    if not isinstance(stale, int) or stale < 1:
        raise ValueError("stale_days must be a positive integer")
    knobs = data.get("knobs")
    if not isinstance(knobs, dict) or not knobs:
        raise ValueError("knobs must be a non-empty object")
    out: dict[str, Any] = {"stale_days": stale, "knobs": {}}
    for name in KNOB_KEYS:
        knob = knobs.get(name)
        if not isinstance(knob, dict):
            raise ValueError(f"missing knob: {name}")
        if knob.get("direction") != "down":
            raise ValueError(f"{name}.direction must be 'down'")
        out["knobs"][name] = {
            "file": str(knob.get("file") or "config/quality-routing.json"),
            "key": str(knob.get("key") or name),
            "direction": "down",
            "notch": _num(knob.get("notch"), f"{name}.notch"),
            "stop_at": _num(knob.get("stop_at"), f"{name}.stop_at"),
            "cut": _num(knob.get("cut"), f"{name}.cut"),
        }
        if out["knobs"][name]["notch"] <= 0:
            raise ValueError(f"{name}.notch must be > 0")
    extra = set(knobs) - set(KNOB_KEYS)
    if extra:
        raise ValueError(f"unknown knobs: {sorted(extra)}")
    return out


def check_cuts(ratchet: dict[str, Any], quality_routing: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    for name, knob in ratchet["knobs"].items():
        key = knob["key"]
        if key not in quality_routing:
            errors.append(f"quality-routing.json missing {key}")
            continue
        try:
            live = _num(quality_routing[key], key)
        except ValueError as exc:
            errors.append(str(exc))
            continue
        committed = knob["cut"]
        if not _same(live, committed):
            if live > committed:
                errors.append(
                    f"{key} live={live} loosened past committed cut {committed} "
                    "(never loosen without a Nish ledger waiver)"
                )
            else:
                errors.append(
                    f"{key} live={live} drifted below committed cut {committed} "
                    "(update config/quality-ratchet.json in the same PR as the tighten)"
                )
        if live < knob["stop_at"] and not _same(live, knob["stop_at"]):
            errors.append(
                f"{key} live={live} is past stop_at {knob['stop_at']}"
            )
    return errors


def evaluate_record(
    ratchet: dict[str, Any],
    record: dict[str, Any],
    *,
    now: datetime | None = None,
) -> list[str]:
    errors: list[str] = []
    now = now or datetime.now(timezone.utc)
    action = str(record.get("action") or "").strip()
    if action not in ACTIONS:
        errors.append(f"action must be one of {ACTIONS}, got {action!r}")
        return errors

    evidence = str(record.get("evidence") or "").strip()
    if len(evidence) < MIN_EVIDENCE or evidence.lower() in {"n/a", "none", "todo"}:
        errors.append(
            f"evidence must be a specific ≥{MIN_EVIDENCE}-char claim "
            "(not n/a / none / todo)"
        )

    dated = _parse_date(str(record.get("date") or ""))
    if dated is None:
        errors.append("record.date must be YYYY-MM-DD or ISO-8601")
    else:
        age = now - dated
        stale = timedelta(days=int(ratchet["stale_days"]))
        if age > stale:
            errors.append(
                f"record.date {record.get('date')} is older than "
                f"{ratchet['stale_days']} days"
            )
        if dated - now > timedelta(days=1):
            errors.append(f"record.date {record.get('date')} is in the future")

    if action == "hold":
        return errors

    knob_name = str(record.get("knob") or "").strip()
    knobs = ratchet["knobs"]
    if knob_name not in knobs:
        errors.append(f"knob must be one of {list(knobs)}, got {knob_name!r}")
        return errors
    knob = knobs[knob_name]

    try:
        frm = _num(record.get("from"), "from")
        to = _num(record.get("to"), "to")
    except ValueError as exc:
        errors.append(str(exc))
        return errors

    if action == "tighten":
        if not _same(frm, knob["cut"]):
            errors.append(
                f"tighten from={frm} must equal committed {knob_name} cut {knob['cut']}"
            )
        expected = next_cut(frm, knob["notch"], knob["stop_at"])
        if _same(frm, knob["stop_at"]) or _same(expected, frm):
            errors.append(
                f"{knob_name} is already at stop_at {knob['stop_at']}; hold, do not tighten"
            )
        elif not _same(to, expected):
            errors.append(
                f"tighten to={to} is not one notch "
                f"(expected {expected} = {frm} - {knob['notch']}, floor {knob['stop_at']})"
            )
        if to > frm and not _same(to, frm):
            errors.append("tighten must not raise a cut")
        return errors

    # nish-waiver: loosening (or any non-notch move) allowed with a ledger pointer.
    waiver = str(record.get("waiver_source") or "").strip()
    if not waiver.startswith(WAIVER_PREFIX) or len(waiver) <= len(WAIVER_PREFIX):
        errors.append(
            "nish-waiver requires waiver_source starting with "
            f"{WAIVER_PREFIX!r} plus a dated ledger title"
        )
    return errors


# --- fleet-ops#3519: per-repo quality ceiling ratchet ---------------------------

# The measured per-repo quality ceilings the fleet-metrics-export pipeline owns.
CEILING_METRICS = (
    "reverts_per_100_merges",
    "post_merge_defects_per_100",
    "sessions_to_pr_pct",
)


def load_ceilings_cfg(ratchet: dict[str, Any]) -> dict[str, dict[str, float]]:
    """Return the `.ceilings` block (repo -> metric -> number). Missing or
    malformed -> {} so a config fault tightens nothing, silently.
    """
    ceilings = ratchet.get("ceilings")
    if not isinstance(ceilings, dict):
        return {}
    out: dict[str, dict[str, float]] = {}
    for repo, row in ceilings.items():
        if not isinstance(row, dict):
            continue
        nums: dict[str, float] = {}
        for metric, val in row.items():
            try:
                nums[metric] = float(val)
            except (TypeError, ValueError):
                continue
        if nums:
            out[str(repo)] = nums
    return out


def _p50(samples: list[float]) -> float | None:
    clean = [
        s for s in samples
        if isinstance(s, (int, float)) and not isinstance(s, bool)
    ]
    if not clean:
        return None
    clean.sort()
    n = len(clean)
    mid = n // 2
    if n % 2 == 1:
        return float(clean[mid])
    return round((clean[mid - 1] + clean[mid]) / 2.0, PLACES)


def tighten_ceilings(
    ceilings: dict[str, dict[str, float]],
    metrics: dict[str, dict[str, list[float]]],
) -> tuple[dict[str, dict[str, float]], list[str]]:
    """Compute per-repo ceiling = min(current, p50 x 1.1). NEVER loosens.

    Returns (updated ceilings, human-readable change list). A repo/metric with
    no weekly samples keeps its current ceiling (no tightening signal). A repo
    with no committed ceiling is seeded from this week's p50 x 1.1.
    """
    updated = {repo: dict(row) for repo, row in ceilings.items()}
    changes: list[str] = []
    for repo, repo_metric in metrics.items():
        if not isinstance(repo_metric, dict):
            continue
        for metric, samples in repo_metric.items():
            if metric not in CEILING_METRICS:
                continue
            if repo not in updated or metric not in updated[repo]:
                base: float | None = None  # seed from this week
            else:
                base = updated[repo][metric]
            p50 = _p50(samples if isinstance(samples, list) else [samples])
            if p50 is None:
                continue
            candidate = round(p50 * 1.1, PLACES)
            new = candidate if base is None else round(min(base, candidate), PLACES)
            if base is not None and _same(new, base):
                continue  # no tightening
            if repo not in updated:
                updated[repo] = {}
            updated[repo][metric] = new
            changes.append(
                f"{repo}.{metric}: "
                + (f"{base:.6f} -> " if base is not None else "seed ")
                + f"{new:.6f} (p50 {p50:.6f} x 1.1 = {candidate:.6f})"
            )
    return updated, changes


def cmd_tighten_ceilings(args: argparse.Namespace) -> int:
    try:
        raw = load_json(args.ratchet)
        metrics = load_json(args.metrics)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"QUALITY-RATCHET: {exc}", file=sys.stderr)
        return 1
    if not isinstance(metrics, dict):
        print(
            "QUALITY-RATCHET: --metrics must be {repo: {metric: [samples]}}",
            file=sys.stderr,
        )
        return 1
    if not isinstance(raw.get("ceilings"), dict):
        raise ValueError("ratchet has no ceilings block")
    ceilings = raw["ceilings"]
    updated, changes = tighten_ceilings(ceilings, metrics)
    raw["ceilings"] = updated
    for change in changes:
        print(f"RATCHET: {change}", file=sys.stderr)
    if args.dry_run:
        print(
            f"QUALITY-RATCHET-OK: dry-run no write ({len(changes)} proposed tighten(s))",
            file=sys.stderr,
        )
        return 0
    if changes:
        _write_json(args.ratchet, raw)
    print(
        f"QUALITY-RATCHET-OK: {len(changes)} ceiling(s) tightened; none loosened",
        file=sys.stderr,
    )
    return 0


def _write_json(path: str, data: dict[str, Any]) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=False)
        fh.write("\n")


def check_weekly_record(
    ratchet: dict[str, Any],
    wfr_dir: Path,
    *,
    now: datetime,
) -> list[str]:
    actions = wfr_dir / "last-actions.json"
    record_path = wfr_dir / "last-ratchet.json"
    if not actions.is_file():
        return []
    if not record_path.is_file():
        return [
            "WFR last-actions.json exists but last-ratchet.json is missing "
            "(Weekly Fleet Review must write the weekly ratchet record)"
        ]
    try:
        record = load_json(str(record_path))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return [f"cannot load last-ratchet.json: {exc}"]
    return evaluate_record(ratchet, record, now=now)


def cmd_canary(args: argparse.Namespace) -> int:
    try:
        now = _now(args.now)
        ratchet = load_ratchet(args.ratchet)
        routing = load_json(args.quality_routing)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"QUALITY-RATCHET: {exc}", file=sys.stderr)
        return 1
    errors = check_cuts(ratchet, routing)
    errors.extend(
        check_weekly_record(ratchet, Path(args.wfr_dir), now=now)
    )
    if errors:
        for err in errors:
            print(f"QUALITY-RATCHET: {err}", file=sys.stderr)
        return 1
    wfr = Path(args.wfr_dir)
    if (wfr / "last-actions.json").is_file():
        print(
            "QUALITY-RATCHET-OK: cuts match committed floors; weekly record valid",
            file=sys.stderr,
        )
    else:
        print(
            "QUALITY-RATCHET-OK: cuts match committed floors; weekly record skipped (WFR has not run)",
            file=sys.stderr,
        )
    return 0


def cmd_evaluate_record(args: argparse.Namespace) -> int:
    try:
        now = _now(args.now)
        ratchet = load_ratchet(args.ratchet)
        record = load_json(args.record)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"QUALITY-RATCHET: {exc}", file=sys.stderr)
        return 1
    errors = evaluate_record(ratchet, record, now=now)
    if errors:
        for err in errors:
            print(f"QUALITY-RATCHET: {err}", file=sys.stderr)
        return 1
    print(
        f"QUALITY-RATCHET-OK: record action={record.get('action')}",
        file=sys.stderr,
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("canary", help="fail-loud heartbeat/CI check")
    p.add_argument("--ratchet", required=True)
    p.add_argument("--quality-routing", required=True)
    p.add_argument("--wfr-dir", required=True)
    p.add_argument("--now", default="")
    p.set_defaults(func=cmd_canary)

    e = sub.add_parser("evaluate-record", help="shape-check one WFR ratchet record")
    e.add_argument("--ratchet", required=True)
    e.add_argument("--record", required=True)
    e.add_argument("--now", default="")
    e.set_defaults(func=cmd_evaluate_record)

    t = sub.add_parser("tighten-ceilings", help="fleet-ops#3519 weekly ratchet: recompute .ceilings to min(current, p50 x 1.1)")
    t.add_argument("--ratchet", required=True, help="config/quality-ratchet.json")
    t.add_argument("--metrics", required=True, help="{repo: {metric: [weekly samples]}}")
    t.add_argument("--dry-run", action="store_true", help="report proposed tightens without writing")
    t.set_defaults(func=cmd_tighten_ceilings)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
