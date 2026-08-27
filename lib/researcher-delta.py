#!/usr/bin/env python3
"""Researcher delta contract, triggers, and adopted-delta scoreboard (fleet-ops#458).

Pure logic. Filing and systemd starts live in the bash wrappers.
Generic advice is a rejected deliverable. Rejected fingerprints are logged
so the same delta cannot be re-litigated.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DOMAINS = ("fleet-workflow", "product-0509")
DEFAULT_STALE_DAYS = 28
DEFAULT_NTH_CYCLE = 4
DEFAULT_MIN_INTERVAL_S = 7200
DEFAULT_ADOPTION_FLOOR = 0.10
DEFAULT_TRAILING = 8
MIN_JUDGED_FOR_CUT = 4
CADENCE_CUT_FACTOR = 4
MIN_FIELD_CHARS = 20
GENERIC_ADOPTING = re.compile(
    r"^(be better|do better|follow best practices|improve quality|"
    r"adopt industry standards|be more like (google|netflix|meta)|"
    r"raise the bar|just improve it)\.?$",
    re.I,
)
ISO_Z = re.compile(r"Z$")

# fleet-ops#457 snapshot metrics and the NORTH STAR cuts they are compared to.
PRIMARY_SLO_METRICS = ("revert_rate", "defect_rate", "overturn_rate")
DEFAULT_QUALITY_CUTS = {
    "revert_rate_cut": 0.04,
    "defect_rate_cut": 0.40,
    "overturn_rate_cut": 0.25,
}
DEFAULT_STALE_SNAPSHOT_SECS = 86400


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    text = ISO_Z.sub("+00:00", value.strip())
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def now_utc(override: str | None = None) -> datetime:
    parsed = parse_iso(override) if override else None
    return parsed or datetime.now(timezone.utc)


def fingerprint(they: str, we: str) -> str:
    blob = f"{they.strip().lower()}\n{we.strip().lower()}".encode("utf-8")
    return hashlib.sha256(blob).hexdigest()[:16]


def _quality_routing_path() -> str:
    return (
        os.environ.get("RESEARCHER_QUALITY_ROUTING_JSON")
        or os.environ.get("QUALITY_ROUTING_JSON")
        or str(Path.home() / ".local/state/pi-packet/quality-routing.json")
    )


def load_quality_thresholds() -> dict[str, float | int]:
    """Load SLO cuts from quality-routing config, with safe NORTH STAR defaults."""
    data = load_json(_quality_routing_path(), {})
    if not isinstance(data, dict):
        data = {}
    thresholds: dict[str, float | int] = {}
    for key in PRIMARY_SLO_METRICS:
        cut_key = f"{key}_cut"
        val = data.get(cut_key)
        if isinstance(val, (int, float)):
            thresholds[cut_key] = float(val)
        else:
            thresholds[cut_key] = DEFAULT_QUALITY_CUTS[cut_key]
    stale = data.get("stale_snapshot_secs")
    if isinstance(stale, int) and stale >= 1:
        thresholds["stale_snapshot_secs"] = stale
    else:
        thresholds["stale_snapshot_secs"] = DEFAULT_STALE_SNAPSHOT_SECS
    return thresholds


def _is_old_quality(raw: Any) -> bool:
    return isinstance(raw, dict) and (
        "verdict" in raw or "primary" in raw or "prior_primary" in raw
    )


def _is_quality_snapshot(raw: Any) -> bool:
    return isinstance(raw, dict) and "generated_at" in raw and "lanes" in raw


def _snapshot_stale(
    snapshot: dict[str, Any],
    thresholds: dict[str, float | int],
    now: datetime | None = None,
) -> bool:
    generated = parse_iso(str(snapshot.get("generated_at") or ""))
    if generated is None:
        return True
    now = now or now_utc()
    age = (now - generated).total_seconds()
    return age > thresholds["stale_snapshot_secs"]


def _primary_from_snapshot(snapshot: dict[str, Any]) -> dict[str, float]:
    """Summarise a #457 snapshot into the worst per-SLO rate across all lanes."""
    primary: dict[str, float] = {key: 0.0 for key in PRIMARY_SLO_METRICS}
    lanes = snapshot.get("lanes") or {}
    if not isinstance(lanes, dict):
        return primary
    for metrics in lanes.values():
        if not isinstance(metrics, dict):
            continue
        for key in PRIMARY_SLO_METRICS:
            val = metrics.get(key)
            if isinstance(val, (int, float)):
                primary[key] = max(primary[key], float(val))
    return primary


def _verdict_from_primary(
    primary: dict[str, float], thresholds: dict[str, float | int]
) -> str:
    """FAIL if any primary SLO is over its cut; otherwise PASS."""
    for key in PRIMARY_SLO_METRICS:
        if primary.get(key, 0.0) > thresholds[f"{key}_cut"]:
            return "FAIL"
    return "PASS"


def normalize_quality(
    quality: Any,
    state: dict[str, Any],
    thresholds: dict[str, float | int] | None = None,
) -> dict[str, Any] | None:
    """Return an old-shaped quality dict.

    Accepts the legacy #456 shape ({verdict, primary, prior_primary}) or the
    live #457 snapshot ({generated_at, lanes: {...}}). A missing, malformed,
    or stale snapshot becomes None so the heartbeat tick does not fail.
    """
    if not isinstance(quality, dict) or not quality:
        return None
    if _is_old_quality(quality):
        return quality
    if not _is_quality_snapshot(quality):
        return None
    if thresholds is None:
        thresholds = load_quality_thresholds()
    if _snapshot_stale(quality, thresholds):
        return None
    primary = _primary_from_snapshot(quality)
    prior = state.get("last_quality_primary")
    if not isinstance(prior, dict):
        prior = {}
    verdict = _verdict_from_primary(primary, thresholds)
    # Persist the current primary so the next tick can compare for plateau.
    state["last_quality_primary"] = primary
    return {
        "verdict": verdict,
        "primary": primary,
        "prior_primary": prior,
    }


def _field(delta: dict[str, Any], *keys: str) -> str:
    for key in keys:
        raw = delta.get(key)
        if isinstance(raw, str) and raw.strip():
            return raw.strip()
    return ""


def citations_of(delta: dict[str, Any]) -> list[dict[str, str]]:
    raw = delta.get("citations") or delta.get("sources") or []
    if not isinstance(raw, list):
        return []
    out: list[dict[str, str]] = []
    for item in raw:
        if isinstance(item, str) and item.strip():
            out.append({"source": item.strip()})
            continue
        if not isinstance(item, dict):
            continue
        source = str(item.get("url") or item.get("source") or item.get("cite") or "").strip()
        if source:
            out.append({"source": source, "note": str(item.get("note") or "").strip()})
    return out


def validate_delta(delta: dict[str, Any]) -> tuple[bool, str]:
    """Return (ok, reason). reason is empty on success."""
    if not isinstance(delta, dict):
        return False, "delta is not an object"
    they = _field(delta, "they", "they_do", "theyDo")
    we = _field(delta, "we", "we_do", "weDo")
    adopting = _field(delta, "adopting", "adopting_here_means", "adoptingHereMeans")
    if not they:
        return False, "missing they-do"
    if not we:
        return False, "missing we-do"
    if not adopting:
        return False, "missing adopting-here-means"
    if len(they) < MIN_FIELD_CHARS:
        return False, "they-do too short (generic advice)"
    if len(we) < MIN_FIELD_CHARS:
        return False, "we-do too short (generic advice)"
    if len(adopting) < MIN_FIELD_CHARS:
        return False, "adopting-here-means too short (generic advice)"
    if GENERIC_ADOPTING.match(adopting):
        return False, "adopting-here-means is generic advice"
    cites = citations_of(delta)
    if not cites:
        return False, "missing citations"
    plane = _field(delta, "plane", "domain")
    if plane and plane not in DOMAINS:
        return False, f"unknown plane {plane!r} (want {'|'.join(DOMAINS)})"
    return True, ""


def normalize_delta(delta: dict[str, Any]) -> dict[str, Any]:
    they = _field(delta, "they", "they_do", "theyDo")
    we = _field(delta, "we", "we_do", "weDo")
    adopting = _field(delta, "adopting", "adopting_here_means", "adoptingHereMeans")
    plane = _field(delta, "plane", "domain") or "fleet-workflow"
    if plane not in DOMAINS:
        plane = "fleet-workflow"
    title = _field(delta, "title") or they[:80]
    return {
        "title": title,
        "they": they,
        "we": we,
        "adopting": adopting,
        "plane": plane,
        "citations": citations_of(delta),
        "fingerprint": fingerprint(they, we),
        "repo": "0509" if plane == "product-0509" else "fleet-ops",
    }


def parse_deltas_payload(raw: Any) -> list[dict[str, Any]]:
    if isinstance(raw, dict):
        items = raw.get("deltas")
        if items is None and any(k in raw for k in ("they", "they_do")):
            items = [raw]
        raw = items
    if not isinstance(raw, list):
        return []
    return [item for item in raw if isinstance(item, dict)]


def empty_state() -> dict[str, Any]:
    return {
        "version": 1,
        "last_dispatch_at": "",
        "last_run_at": "",
        "last_seat_map_hash": "",
        "last_quality_primary": {},
        "cadence_cut": False,
        "min_interval_s": DEFAULT_MIN_INTERVAL_S,
        "domains": {name: {"last_research_at": ""} for name in DOMAINS},
        "deltas": [],
        "rejected": [],
    }


def load_json(path: str, default: Any) -> Any:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return default


def save_state(path: str, state: dict[str, Any]) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(state, handle, indent=2, sort_keys=True)
        handle.write("\n")


def judged_tail(deltas: list[dict[str, Any]], trailing: int = DEFAULT_TRAILING) -> list[dict[str, Any]]:
    judged = [row for row in deltas if row.get("status") in ("adopted", "discarded", "rejected")]
    return judged[-trailing:]


def adoption_rate(deltas: list[dict[str, Any]], trailing: int = DEFAULT_TRAILING) -> tuple[float, int, int]:
    tail = judged_tail(deltas, trailing)
    if not tail:
        return 1.0, 0, 0
    adopted = sum(1 for row in tail if row.get("status") == "adopted")
    return adopted / len(tail), adopted, len(tail)


def cadence_is_cut(rate: float, judged: int, floor: float = DEFAULT_ADOPTION_FLOOR) -> bool:
    if judged < MIN_JUDGED_FOR_CUT:
        return False
    return rate < floor


def evaluate_triggers(
    now: datetime,
    state: dict[str, Any],
    quality: dict[str, Any] | None,
    gap: dict[str, Any] | None,
    seat_map_hash: str | None,
    stale_days: int = DEFAULT_STALE_DAYS,
    nth_cycle: int = DEFAULT_NTH_CYCLE,
) -> list[str]:
    reasons: list[str] = []
    thresholds = load_quality_thresholds()
    normalized = normalize_quality(quality, state, thresholds)
    if isinstance(normalized, dict) and normalized:
        verdict = str(normalized.get("verdict") or "").upper()
        if verdict == "FAIL":
            reasons.append("quality-regression")
        primary = normalized.get("primary")
        prior = normalized.get("prior_primary")
        if (
            verdict != "FAIL"
            and isinstance(primary, dict)
            and isinstance(prior, dict)
            and primary
            and primary == prior
        ):
            reasons.append("quality-plateau")
    if seat_map_hash:
        previous = str(state.get("last_seat_map_hash") or "")
        if previous and previous != seat_map_hash:
            reasons.append("seat-map-release")
        elif not previous:
            # First hash is a baseline, not a release. Recorded by the runner.
            pass
    if isinstance(gap, dict) and gap:
        try:
            cycle = int(gap.get("cycle") or 0)
        except (TypeError, ValueError):
            cycle = 0
        if cycle > 0 and nth_cycle > 0 and cycle % nth_cycle == 1:
            reasons.append("nth-gap-cycle")
        last_verdict = str(gap.get("last_verdict") or gap.get("verdict") or "").upper()
        if last_verdict in {"FAIL", "FAILED"}:
            reasons.append("failed-cycle")
    domains = state.get("domains") if isinstance(state.get("domains"), dict) else {}
    stale_s = stale_days * 86400
    for name in DOMAINS:
        stamp = parse_iso((domains.get(name) or {}).get("last_research_at"))
        if stamp is None:
            reasons.append(f"domain-stale:{name}")
            continue
        age = (now - stamp).total_seconds()
        if age > stale_s:
            reasons.append(f"domain-stale:{name}")
    # Unique, stable order.
    seen: set[str] = set()
    ordered: list[str] = []
    for reason in reasons:
        if reason in seen:
            continue
        seen.add(reason)
        ordered.append(reason)
    return ordered


def decide(
    now: datetime,
    state: dict[str, Any],
    triggers: list[str],
    unit_active: bool,
    min_interval_s: int | None = None,
    floor: float = DEFAULT_ADOPTION_FLOOR,
) -> dict[str, Any]:
    rate, adopted, judged = adoption_rate(state.get("deltas") or [])
    cut = cadence_is_cut(rate, judged, floor)
    interval = int(min_interval_s or state.get("min_interval_s") or DEFAULT_MIN_INTERVAL_S)
    if cut:
        interval *= CADENCE_CUT_FACTOR
    skip = ""
    if unit_active:
        skip = "unit-active"
    elif cut:
        skip = "cadence-cut"
    elif not triggers:
        skip = "no-trigger"
    else:
        last = parse_iso(str(state.get("last_dispatch_at") or ""))
        if last is not None:
            age = (now - last).total_seconds()
            if age < interval:
                skip = "min-interval"
    return {
        "dispatch": skip == "",
        "skip": skip,
        "triggers": triggers,
        "adoption_rate": rate,
        "adopted": adopted,
        "judged": judged,
        "cadence_cut": cut,
        "min_interval_s": interval,
    }


def apply_label_refresh(
    state: dict[str, Any],
    labels_by_issue: dict[str, list[str]],
) -> dict[str, Any]:
    """Update filed deltas from live labels. agent-ready=adopted, discarded=discarded."""
    deltas = list(state.get("deltas") or [])
    for row in deltas:
        if row.get("status") != "filed":
            continue
        key = f"{row.get('repo')}/{row.get('issue')}"
        labels = [str(x).lower() for x in labels_by_issue.get(key, [])]
        if "agent-ready" in labels:
            row["status"] = "adopted"
        elif "discarded" in labels:
            row["status"] = "discarded"
    state["deltas"] = deltas
    rate, _, judged = adoption_rate(deltas)
    state["cadence_cut"] = cadence_is_cut(rate, judged)
    return state


def already_seen(state: dict[str, Any], fp: str) -> str | None:
    for row in state.get("rejected") or []:
        if row.get("fingerprint") == fp:
            return str(row.get("reason") or "previously rejected")
    for row in state.get("deltas") or []:
        if row.get("fingerprint") == fp:
            return f"already {row.get('status') or 'logged'}"
    return None


def cmd_init(args: argparse.Namespace) -> int:
    path = args.state
    existing = load_json(path, None)
    if isinstance(existing, dict) and existing.get("version"):
        print(json.dumps({"ok": True, "created": False, "path": path}))
        return 0
    state = empty_state()
    save_state(path, state)
    print(json.dumps({"ok": True, "created": True, "path": path}))
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    payload = json.load(sys.stdin) if args.file == "-" else load_json(args.file, None)
    if payload is None:
        print(json.dumps({"ok": False, "error": "unreadable deltas"}))
        return 1
    accepted: list[dict[str, Any]] = []
    rejected: list[dict[str, Any]] = []
    for item in parse_deltas_payload(payload):
        ok, reason = validate_delta(item)
        if not ok:
            rejected.append({"reason": reason, "raw": item})
            continue
        accepted.append(normalize_delta(item))
    print(json.dumps({"ok": True, "accepted": accepted, "rejected": rejected}))
    return 0


def cmd_triggers(args: argparse.Namespace) -> int:
    state = load_json(args.state, empty_state()) if args.state else empty_state()
    quality = load_json(args.quality, None) if args.quality else None
    gap = load_json(args.gap, None) if args.gap else None
    now = now_utc(args.now)
    reasons = evaluate_triggers(
        now,
        state,
        quality if isinstance(quality, dict) else None,
        gap if isinstance(gap, dict) else None,
        args.seat_hash or None,
        stale_days=args.stale_days,
        nth_cycle=args.nth_cycle,
    )
    print(json.dumps({"now": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "triggers": reasons}))
    return 0


def cmd_decide(args: argparse.Namespace) -> int:
    state = load_json(args.state, empty_state()) if args.state else empty_state()
    quality = load_json(args.quality, None) if args.quality else None
    gap = load_json(args.gap, None) if args.gap else None
    now = now_utc(args.now)
    triggers = evaluate_triggers(
        now,
        state,
        quality if isinstance(quality, dict) else None,
        gap if isinstance(gap, dict) else None,
        args.seat_hash or None,
        stale_days=args.stale_days,
        nth_cycle=args.nth_cycle,
    )
    verdict = decide(
        now,
        state,
        triggers,
        unit_active=bool(args.unit_active),
        min_interval_s=args.min_interval_s,
        floor=args.floor,
    )
    if args.state:
        save_state(args.state, state)
    print(json.dumps(verdict))
    return 0 if not args.fail_on_skip else (0 if verdict["dispatch"] else 1)


def cmd_refresh(args: argparse.Namespace) -> int:
    state = load_json(args.state, empty_state())
    labels = load_json(args.labels, {})
    if not isinstance(labels, dict):
        labels = {}
    coerced = {str(k): list(v) if isinstance(v, list) else [] for k, v in labels.items()}
    state = apply_label_refresh(state, coerced)
    if args.write:
        save_state(args.state, state)
    rate, adopted, judged = adoption_rate(state.get("deltas") or [])
    print(
        json.dumps(
            {
                "adoption_rate": rate,
                "adopted": adopted,
                "judged": judged,
                "cadence_cut": state.get("cadence_cut"),
            }
        )
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="researcher-delta")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init")
    p_init.add_argument("--state", required=True)
    p_init.set_defaults(func=cmd_init)

    p_val = sub.add_parser("validate")
    p_val.add_argument("--file", required=True)
    p_val.set_defaults(func=cmd_validate)

    p_tr = sub.add_parser("triggers")
    p_tr.add_argument("--state", default="")
    p_tr.add_argument("--quality", default="")
    p_tr.add_argument("--gap", default="")
    p_tr.add_argument("--seat-hash", default="")
    p_tr.add_argument("--now", default="")
    p_tr.add_argument("--stale-days", type=int, default=DEFAULT_STALE_DAYS)
    p_tr.add_argument("--nth-cycle", type=int, default=DEFAULT_NTH_CYCLE)
    p_tr.set_defaults(func=cmd_triggers)

    p_de = sub.add_parser("decide")
    p_de.add_argument("--state", default="")
    p_de.add_argument("--quality", default="")
    p_de.add_argument("--gap", default="")
    p_de.add_argument("--seat-hash", default="")
    p_de.add_argument("--now", default="")
    p_de.add_argument("--stale-days", type=int, default=DEFAULT_STALE_DAYS)
    p_de.add_argument("--nth-cycle", type=int, default=DEFAULT_NTH_CYCLE)
    p_de.add_argument("--unit-active", action="store_true")
    p_de.add_argument("--min-interval-s", type=int, default=0)
    p_de.add_argument("--floor", type=float, default=DEFAULT_ADOPTION_FLOOR)
    p_de.add_argument("--fail-on-skip", action="store_true")
    p_de.set_defaults(func=cmd_decide)

    p_rf = sub.add_parser("refresh")
    p_rf.add_argument("--state", required=True)
    p_rf.add_argument("--labels", required=True)
    p_rf.add_argument("--write", action="store_true")
    p_rf.set_defaults(func=cmd_refresh)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
