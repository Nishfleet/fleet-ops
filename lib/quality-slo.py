#!/usr/bin/env python3
"""Quality SLO generator + cycle verdict (fleet-ops#456).

Pure logic. Reads GitHub/journal event JSON, never agent self-scores.
Every metric carries the query that produced it.

Subcommands:
  compute   events JSON + optional previous snapshot → snapshot JSON
  render    snapshot JSON → markdown for conference / loop packets
  stale     snapshot JSON → exit 1 if a primary metric stopped being computed

DORA/SRE mapping (validated against the issue's structure, not a rewrite of it):
  Change Failure Rate  → auto_revert_rate + post_merge_defect_rate
  Rework / code churn  → churn_pct (Accelerate secondary, baseline 49%)
  SLO / error budget   → drill_pass_rate, canary_regression_count
  Unproductive output  → scout_futility_rate
  Decision calibration → decision_overturn_rate (not a DORA four-key)
  Deployment frequency / lead time → throughput, reported, cannot flip FAIL→PASS
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from typing import Any

# Work-quality bars from the quality-over-everything measurement named in
# fleet-ops#180's NORTH STAR comment. Beat them and keep beating them.
BASELINE_AUTO_REVERT = 0.02
BASELINE_DEFECT = 0.29
BASELINE_CHURN = 0.49

# Product-plane acquisition metrics may never be primary (issue comment on
# #456, Adapty 2026). Retention/LTV can join later; installs/traffic cannot.
ACQUISITION_KINDS = frozenset(
    {"installs", "traffic", "signups", "downloads", "impressions"}
)

EPS = 1e-12

QUERIES = {
    "decision_overturn_rate": (
        "conference_verdicts where "
        "(verdict=APPROVE AND later=auto-reverted) OR "
        "(verdict=REJECT AND later=re-landed-clean) "
        "/ count(conference_verdicts); "
        "source=events.conference_verdicts (GitHub PR history + "
        "agent-state/quality-slo/verdicts.jsonl)"
    ),
    "auto_revert_rate": (
        "count(auto_reverts) / count(merges) in the window; "
        "source=gh pr list --state merged (head revert/* or title Revert )"
    ),
    "post_merge_defect_rate": (
        "count(defect_issues) / count(merges) in the window; "
        "source=gh issue list --label bug,defect opened after a merge"
    ),
    "churn_pct": (
        "count(files re-edited in window) / count(files touched in window); "
        "source=events.file_churn from merged PR file paths"
    ),
    "drill_pass_rate": (
        "count(drills.passed) / count(drills.ran); "
        "source=tick logs + drill result files"
    ),
    "canary_regression_count": (
        "count of canary regressions in the window; "
        "source=events.canary_regressions (tick logs / drill results)"
    ),
    "scout_futility_rate": (
        "count(scout.futile) / count(scout.candidates); "
        "source=scout journals (rejected / not-agent-ready / duplicate)"
    ),
    "merge_count": (
        "count(merges) in the window; source=gh pr list --state merged"
    ),
    "saturation_pct": (
        "events.throughput.saturation_pct; source=heartbeat undersaturation pass"
    ),
}

PRIMARY: list[dict[str, Any]] = [
    {
        "id": "decision_overturn_rate",
        "group": "decision",
        "direction": "lower",
        "plane": "control",
    },
    {
        "id": "auto_revert_rate",
        "group": "work",
        "direction": "lower",
        "plane": "control",
        "baseline": BASELINE_AUTO_REVERT,
    },
    {
        "id": "post_merge_defect_rate",
        "group": "work",
        "direction": "lower",
        "plane": "control",
        "baseline": BASELINE_DEFECT,
    },
    {
        "id": "churn_pct",
        "group": "work",
        "direction": "lower",
        "plane": "control",
        "baseline": BASELINE_CHURN,
    },
    {
        "id": "drill_pass_rate",
        "group": "output",
        "direction": "higher",
        "plane": "control",
    },
    {
        "id": "canary_regression_count",
        "group": "output",
        "direction": "lower",
        "plane": "control",
    },
    {
        "id": "scout_futility_rate",
        "group": "output",
        "direction": "lower",
        "plane": "control",
    },
]

SECONDARY: list[dict[str, Any]] = [
    {"id": "merge_count", "group": "throughput", "direction": "higher"},
    {"id": "saturation_pct", "group": "throughput", "direction": "higher"},
]

PRIMARY_IDS = tuple(row["id"] for row in PRIMARY)
SECONDARY_IDS = tuple(row["id"] for row in SECONDARY)
PRIMARY_BY_ID = {row["id"]: row for row in PRIMARY}

STALE_DEFAULT_SECONDS = 5400  # 90 min: three heartbeat ticks


def _parse_now(now: str | None) -> datetime:
    if not now:
        return datetime.now(timezone.utc)
    raw = now.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    dt = datetime.fromisoformat(raw)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _ratio(num: int, den: int) -> float | None:
    if den <= 0:
        return None
    return num / den


def _as_int(value: Any, default: int = 0) -> int:
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def validate_metric_specs(specs: list[dict[str, Any]] | None = None) -> None:
    """Refuse product acquisition metrics as primary (fleet-ops#456 comment)."""
    for row in specs or PRIMARY:
        kind = str(row.get("kind") or "")
        plane = str(row.get("plane") or "")
        if plane == "product" and kind in ACQUISITION_KINDS:
            raise ValueError(
                f"primary metric {row.get('id')!r} is product acquisition "
                f"({kind}); retention/LTV only (fleet-ops#456)"
            )


def _metric_record(metric_id: str, value: float | int | None, status: str) -> dict[str, Any]:
    spec = PRIMARY_BY_ID.get(metric_id) or next(
        (row for row in SECONDARY if row["id"] == metric_id), {}
    )
    rec: dict[str, Any] = {
        "id": metric_id,
        "value": value,
        "status": status,
        "query": QUERIES.get(metric_id, ""),
        "group": spec.get("group", ""),
        "direction": spec.get("direction", "lower"),
        "primary": metric_id in PRIMARY_IDS,
    }
    if "baseline" in spec:
        rec["baseline"] = spec["baseline"]
    return rec


def compute_metrics(events: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Turn event counts into metric records. 0/0 is no-data, not 0%."""
    validate_metric_specs()
    verdicts = events.get("conference_verdicts") or []
    contradicted = 0
    n_verdicts = 0
    if isinstance(verdicts, list):
        for item in verdicts:
            if not isinstance(item, dict):
                continue
            n_verdicts += 1
            verdict = str(item.get("verdict") or "").upper()
            later = str(item.get("later") or "")
            if verdict == "APPROVE" and later == "auto-reverted":
                contradicted += 1
            elif verdict == "REJECT" and later == "re-landed-clean":
                contradicted += 1

    merges = events.get("merges") or []
    auto_reverts = events.get("auto_reverts") or []
    defects = events.get("defect_issues") or []
    n_merges = len(merges) if isinstance(merges, list) else _as_int(merges)
    n_reverts = (
        len(auto_reverts) if isinstance(auto_reverts, list) else _as_int(auto_reverts)
    )
    n_defects = len(defects) if isinstance(defects, list) else _as_int(defects)

    churn = events.get("file_churn") or {}
    if not isinstance(churn, dict):
        churn = {}
    touched = _as_int(churn.get("touched"))
    reedited = _as_int(churn.get("reedited"))

    drills = events.get("drills") or {}
    if not isinstance(drills, dict):
        drills = {}
    ran = _as_int(drills.get("ran"))
    passed = _as_int(drills.get("passed"))

    canary_n = events.get("canary_regressions")
    canary_status = "computed"
    if canary_n is None:
        canary_val: int | None = None
        canary_status = "no-data"
    else:
        canary_val = _as_int(canary_n)

    scout = events.get("scout") or {}
    if not isinstance(scout, dict):
        scout = {}
    candidates = _as_int(scout.get("candidates"))
    futile = _as_int(scout.get("futile"))

    throughput = events.get("throughput") or {}
    if not isinstance(throughput, dict):
        throughput = {}
    merge_count = throughput.get("merges")
    if merge_count is None:
        merge_count = n_merges
    sat = throughput.get("saturation_pct")

    def status_of(value: float | int | None, had_denom: bool) -> str:
        if value is None:
            return "no-data" if not had_denom else "no-data"
        return "computed"

    metrics = {
        "decision_overturn_rate": _metric_record(
            "decision_overturn_rate",
            _ratio(contradicted, n_verdicts),
            status_of(_ratio(contradicted, n_verdicts), n_verdicts > 0),
        ),
        "auto_revert_rate": _metric_record(
            "auto_revert_rate",
            _ratio(n_reverts, n_merges),
            "computed" if n_merges > 0 else "no-data",
        ),
        "post_merge_defect_rate": _metric_record(
            "post_merge_defect_rate",
            _ratio(n_defects, n_merges),
            "computed" if n_merges > 0 else "no-data",
        ),
        "churn_pct": _metric_record(
            "churn_pct",
            _ratio(reedited, touched),
            "computed" if touched > 0 else "no-data",
        ),
        "drill_pass_rate": _metric_record(
            "drill_pass_rate",
            _ratio(passed, ran),
            "computed" if ran > 0 else "no-data",
        ),
        "canary_regression_count": _metric_record(
            "canary_regression_count", canary_val, canary_status
        ),
        "scout_futility_rate": _metric_record(
            "scout_futility_rate",
            _ratio(futile, candidates),
            "computed" if candidates > 0 else "no-data",
        ),
        "merge_count": _metric_record(
            "merge_count",
            _as_int(merge_count),
            "computed",
        ),
        "saturation_pct": _metric_record(
            "saturation_pct",
            None if sat is None else float(sat),
            "computed" if sat is not None else "no-data",
        ),
    }
    return metrics


def _worse(direction: str, current: float, previous: float) -> bool:
    if direction == "higher":
        return current < previous - EPS
    return current > previous + EPS


def _misses_baseline(spec: dict[str, Any], value: float) -> bool:
    baseline = spec.get("baseline")
    if baseline is None:
        return False
    direction = spec.get("direction") or "lower"
    if direction == "higher":
        return value < float(baseline) - EPS
    return value > float(baseline) + EPS


def verdict(
    current: dict[str, dict[str, Any]],
    previous: dict[str, dict[str, Any]] | None,
) -> dict[str, Any]:
    """PASS/FAIL. Throughput cannot flip FAIL to PASS."""
    reasons: list[str] = []
    regressions: list[str] = []
    baseline_misses: list[str] = []
    first_cycle = not previous

    for spec in PRIMARY:
        mid = spec["id"]
        cur = current.get(mid) or {}
        if cur.get("status") != "computed" or cur.get("value") is None:
            continue
        value = float(cur["value"])
        if _misses_baseline(spec, value):
            baseline_misses.append(mid)
            reasons.append(
                f"{mid}={value} misses baseline {spec['baseline']} "
                f"({spec['direction']})"
            )
        if not first_cycle:
            prev = (previous or {}).get(mid) or {}
            if prev.get("status") == "computed" and prev.get("value") is not None:
                if _worse(str(spec["direction"]), value, float(prev["value"])):
                    regressions.append(mid)
                    reasons.append(
                        f"{mid} regressed {prev['value']} → {value}"
                    )

    fail = bool(regressions or baseline_misses)
    result = {
        "verdict": "FAIL" if fail else "PASS",
        "first_cycle": first_cycle,
        "regressions": regressions,
        "baseline_misses": baseline_misses,
        "reasons": reasons,
        "throughput_cannot_override": True,
    }
    return result


def check_staleness(
    snapshot: dict[str, Any],
    now: str | None = None,
    max_age_seconds: int = STALE_DEFAULT_SECONDS,
) -> dict[str, Any]:
    """A primary metric that stopped being computed is LOUD."""
    now_dt = _parse_now(now)
    missing: list[str] = []
    metrics = snapshot.get("metrics") or {}
    if not isinstance(metrics, dict):
        metrics = {}
    for mid in PRIMARY_IDS:
        rec = metrics.get(mid)
        if not isinstance(rec, dict):
            missing.append(mid)
            continue
        status = rec.get("status")
        if status not in ("computed", "no-data"):
            missing.append(mid)

    computed_at = snapshot.get("computed_at")
    age_s: int | None = None
    too_old = False
    if not computed_at:
        missing.append("computed_at")
    else:
        try:
            then = _parse_now(str(computed_at))
            age_s = int((now_dt - then).total_seconds())
            if age_s > max_age_seconds:
                too_old = True
        except ValueError:
            missing.append("computed_at")

    stale = bool(missing) or too_old
    return {
        "stale": stale,
        "missing": missing,
        "too_old": too_old,
        "age_seconds": age_s,
        "max_age_seconds": max_age_seconds,
    }


def build_snapshot(
    events: dict[str, Any],
    previous: dict[str, Any] | None = None,
    now: str | None = None,
) -> dict[str, Any]:
    now_dt = _parse_now(now)
    iso = now_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    metrics = compute_metrics(events)
    prev_metrics = None
    if previous and isinstance(previous.get("metrics"), dict):
        prev_metrics = previous["metrics"]
    cycle = verdict(metrics, prev_metrics)
    window_days = events.get("window_days", 14)
    snap = {
        "computed_at": iso,
        "window_days": window_days,
        "metrics": metrics,
        "cycle": cycle,
        "retention_rule": (
            "When product KPIs join this scoreboard, retention/LTV outranks "
            "acquisition. Installs and traffic cannot be primary."
        ),
        "issue": "Nishfleet/fleet-ops#456",
    }
    snap["staleness"] = check_staleness(snap, now=iso)
    return snap


def render_markdown(snapshot: dict[str, Any]) -> str:
    cycle = snapshot.get("cycle") or {}
    verdict_s = cycle.get("verdict", "UNKNOWN")
    lines = [
        "## Quality scoreboard (computed, fleet-ops#456)",
        "",
        f"Cycle verdict: **{verdict_s}**",
        "",
        "Primary quality metrics decide PASS/FAIL. Throughput is reported "
        "and cannot flip FAIL to PASS.",
        "",
        f"computed_at: {snapshot.get('computed_at', 'missing')}",
        f"window_days: {snapshot.get('window_days', '?')}",
        "",
        "| metric | group | value | status | baseline | query |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    metrics = snapshot.get("metrics") or {}
    for mid in PRIMARY_IDS + SECONDARY_IDS:
        rec = metrics.get(mid) or {}
        value = rec.get("value")
        if value is None:
            value_s = "—"
        elif isinstance(value, float):
            value_s = f"{value:.4f}"
        else:
            value_s = str(value)
        baseline = rec.get("baseline")
        baseline_s = "—" if baseline is None else str(baseline)
        query = str(rec.get("query") or "").replace("|", "/")
        lines.append(
            f"| {mid} | {rec.get('group', '')} | {value_s} | "
            f"{rec.get('status', '')} | {baseline_s} | {query} |"
        )
    lines.append("")
    reasons = cycle.get("reasons") or []
    if reasons:
        lines.append("Reasons:")
        for reason in reasons:
            lines.append(f"- {reason}")
        lines.append("")
    lines.append(str(snapshot.get("retention_rule") or ""))
    lines.append("")
    if cycle.get("first_cycle"):
        lines.append("First cycle (no prior snapshot): cannot regress.")
        lines.append("")
    stale = snapshot.get("staleness") or {}
    if stale.get("stale"):
        lines.append(
            f"STALE: missing={stale.get('missing')} too_old={stale.get('too_old')}"
        )
        lines.append("")
    return "\n".join(lines)


def _load_json(path: str | None) -> dict[str, Any]:
    if path in (None, "-", ""):
        raw = sys.stdin.read()
    else:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    if not raw.strip():
        raise SystemExit("empty input")
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise SystemExit("input must be a JSON object")
    return data


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Quality SLO generator (fleet-ops#456).")
    parser.add_argument(
        "command",
        choices=["compute", "render", "stale"],
        help="compute a snapshot, render markdown, or check staleness",
    )
    parser.add_argument("--events", help="events JSON (compute)")
    parser.add_argument("--previous", help="previous snapshot JSON (compute)")
    parser.add_argument("--snapshot", help="snapshot JSON (render/stale)")
    parser.add_argument("--now", help="ISO timestamp")
    parser.add_argument(
        "--max-age-seconds",
        type=int,
        default=STALE_DEFAULT_SECONDS,
        help="staleness ceiling (default 5400)",
    )
    args = parser.parse_args(argv)

    if args.command == "compute":
        events = _load_json(args.events)
        previous = _load_json(args.previous) if args.previous else None
        snap = build_snapshot(events, previous, now=args.now)
        json.dump(snap, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    snapshot = _load_json(args.snapshot)
    if args.command == "render":
        sys.stdout.write(render_markdown(snapshot))
        if not snapshot.get("metrics"):
            return 1
        return 0

    report = check_staleness(
        snapshot, now=args.now, max_age_seconds=args.max_age_seconds
    )
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 1 if report.get("stale") else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except json.JSONDecodeError as exc:
        print(json.dumps({"error": f"invalid JSON: {exc}"}), file=sys.stderr)
        raise SystemExit(2) from exc
