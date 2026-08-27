#!/usr/bin/env python3
"""Canary for Cursor $400 extra-usage sequencing + overage model.

fleet-ops#1179 (led-2026-08-27-cursor-400-sequencing-model-nish).

Ledger: the $400 extra-usage opens ONLY after Cursor's included usage is
exhausted; on the overage, use Grok 4.6 (cursor-grok-4.6-high).

Official docs (cursor.com/docs/models-and-pricing, read 2026-08-27):
  - Cursor Models pool: Grok 4.6, Grok 4.5, Composer 2.5.
  - Other Models pool may add on-demand usage after included is consumed.
  - Dashboard: cursor.com/dashboard/usage and cursor.com/dashboard/spending.
cursor-agent about --help has no usage/spend fields (confirmed 2026-08-27).
fleet-seat-live-validate is SuperGrok CLI auth only. entitled-wired-canary
is seat-caps wiring. prepaid-usage/*.json is pick-count, not billing.

The meter file is operator-refreshed (no public usage API). Missing or
stale meter is REJECT — meter-checked is the rule, not a skip.

Usage:
  fleet-cursor-overage-canary
  fleet-cursor-overage-canary --from-fixtures <dir>
  fleet-cursor-overage-canary --now 2026-08-27T17:00:00Z
  fleet-cursor-overage-canary --ledger-line
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from typing import Any

REPO = "Nishfleet/fleet-ops"
OVERAGE_MODEL = "cursor-grok-4.6-high"
OVERAGE_PROVIDER = "cursor"
STALE_DEFAULT_MIN = 1440
LEDGER = (
    "2026-08-27 | Cursor $400 sequencing + model (Nish) | The $400 "
    "extra-usage opens ONLY after Cursor's included usage is exhausted; "
    "on the overage, use Grok 4.6 (cursor-grok-4.6-high) via "
    "fleet-cursor-overage-canary (policy lock + meter sequencing + "
    "pick_seat overage-model lock)."
)


def _repo_root() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.dirname(here)


def _parse_now(raw: str | None) -> datetime:
    if not raw:
        return datetime.now(timezone.utc)
    text = raw.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _parse_iso(raw: str) -> datetime | None:
    text = (raw or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _load_json(path: str) -> Any | None:
    if not path or not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _reject(tag: str, reason: str) -> dict[str, Any]:
    return {"verdict": "REJECT", "tag": tag, "reason": reason, "rc": 1}


def _pass(reason: str) -> dict[str, Any]:
    return {"verdict": "PASS", "tag": "OK", "reason": reason, "rc": 0}


def evaluate(
    *,
    policy: Any,
    caps: Any,
    meter: Any,
    active: list[dict[str, str]],
    now: datetime,
    stale_minutes: int = STALE_DEFAULT_MIN,
) -> dict[str, Any]:
    """Decide PASS/REJECT. No I/O. Missing meter is REJECT (meter-checked)."""
    if not isinstance(policy, dict):
        return _reject(
            "POLICY-MISSING",
            "cursor overage policy missing or unparseable",
        )
    if policy.get("overage_model") != OVERAGE_MODEL:
        return _reject(
            "OVERAGE-MODEL-POLICY",
            "policy.overage_model must be %s, got %r"
            % (OVERAGE_MODEL, policy.get("overage_model")),
        )
    if policy.get("overage_provider", OVERAGE_PROVIDER) != OVERAGE_PROVIDER:
        return _reject(
            "OVERAGE-MODEL-POLICY",
            "policy.overage_provider must be %s, got %r"
            % (OVERAGE_PROVIDER, policy.get("overage_provider")),
        )
    if policy.get("included_exhaust_first") is not True:
        return _reject(
            "SEQUENCING-POLICY",
            "policy.included_exhaust_first must be true "
            "(extra-usage opens only after included is exhausted)",
        )

    if not isinstance(caps, dict):
        return _reject("SEAT-CAPS", "seat-caps missing or unparseable")
    cursor = (caps.get("providers") or {}).get("cursor") or {}
    models = cursor.get("models") or {}
    cap = models.get(OVERAGE_MODEL)
    if not isinstance(cap, int) or cap < 1:
        return _reject(
            "SEAT-CAPS",
            "seat-caps cursor/%s cap must be >=1, got %r"
            % (OVERAGE_MODEL, cap),
        )

    if not isinstance(meter, dict):
        return _reject(
            "METER-MISSING",
            "cursor-overage-meter.json missing — extra-usage sequencing "
            "cannot be proven (meter-checked)",
        )
    observed = _parse_iso(str(meter.get("observed_at") or ""))
    if observed is None:
        return _reject(
            "METER-UNPARSEABLE",
            "meter.observed_at missing or unparseable",
        )
    age = now - observed
    if age > timedelta(minutes=stale_minutes):
        return _reject(
            "METER-STALE",
            "meter observed_at %s is older than %s minutes"
            % (meter.get("observed_at"), stale_minutes),
        )
    if age < timedelta(0):
        return _reject(
            "METER-UNPARSEABLE",
            "meter.observed_at is in the future: %s" % meter.get("observed_at"),
        )

    exhausted = meter.get("included_exhausted")
    if not isinstance(exhausted, bool):
        return _reject(
            "METER-UNPARSEABLE",
            "meter.included_exhausted must be a boolean, got %r" % exhausted,
        )
    overage_open = meter.get("overage_open")
    if not isinstance(overage_open, bool):
        return _reject(
            "METER-UNPARSEABLE",
            "meter.overage_open must be a boolean, got %r" % overage_open,
        )
    spend = meter.get("overage_spend_usd_today", 0)
    if isinstance(spend, bool) or not isinstance(spend, (int, float)):
        return _reject(
            "METER-UNPARSEABLE",
            "meter.overage_spend_usd_today must be a number, got %r" % spend,
        )

    if not exhausted and overage_open:
        return _reject(
            "SEQUENCING",
            "overage_open=true while included_exhausted=false — $400 "
            "extra-usage must not open before included is exhausted",
        )
    if not exhausted and spend > 0:
        return _reject(
            "SEQUENCING",
            "overage spend $%s today while included_exhausted=false"
            % spend,
        )

    if exhausted:
        bad = []
        for row in active:
            if row.get("provider") != OVERAGE_PROVIDER:
                continue
            model = row.get("model") or ""
            if model and model != OVERAGE_MODEL:
                bad.append("%s/%s" % (OVERAGE_PROVIDER, model))
        if bad:
            return _reject(
                "OVERAGE-MODEL",
                "included exhausted but active cursor workers are not %s: %s"
                % (OVERAGE_MODEL, ", ".join(sorted(set(bad)))),
            )

    return _pass(
        "included_exhausted=%s overage_open=%s overage_model=%s meter_age_ok"
        % (str(exhausted).lower(), str(overage_open).lower(), OVERAGE_MODEL)
    )


def _load_active(dir_path: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    if not dir_path or not os.path.isdir(dir_path):
        return rows
    for name in sorted(os.listdir(dir_path)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(dir_path, name)
        try:
            data = _load_json(path)
        except (OSError, json.JSONDecodeError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        rows.append(
            {
                "provider": str(data.get("provider") or ""),
                "model": str(data.get("model") or ""),
            }
        )
    return rows


def _default_paths() -> dict[str, str]:
    root = _repo_root()
    home = os.environ.get("HOME", "/home/nish")
    state = os.path.join(home, ".local/state/pi-packet")
    policy = os.environ.get("FLEET_CURSOR_OVERAGE_POLICY") or os.path.join(
        root, "config/cursor-overage-policy.json"
    )
    if not os.path.isfile(policy):
        policy = os.path.join(state, "cursor-overage-policy.json")
    caps = os.environ.get("SEAT_CAPS_JSON") or os.path.join(
        root, "config/seat-caps.json"
    )
    if not os.path.isfile(caps):
        caps = os.path.join(state, "seat-caps.json")
    meter = os.environ.get("FLEET_CURSOR_OVERAGE_METER") or os.path.join(
        state, "cursor-overage-meter.json"
    )
    active = os.environ.get("FLEET_CURSOR_OVERAGE_ACTIVE_SEATS") or os.path.join(
        state, "active-seats"
    )
    return {
        "policy": policy,
        "caps": caps,
        "meter": meter,
        "active": active,
    }


def _from_fixtures(dir_path: str) -> dict[str, str]:
    return {
        "policy": os.path.join(dir_path, "policy.json"),
        "caps": os.path.join(dir_path, "seat-caps.json"),
        "meter": os.path.join(dir_path, "meter.json"),
        "active": os.path.join(dir_path, "active-seats"),
    }


def _safe_load(path: str) -> Any | None:
    try:
        return _load_json(path)
    except (OSError, json.JSONDecodeError, ValueError):
        return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Cursor $400 extra-usage sequencing + overage-model canary"
    )
    parser.add_argument("--from-fixtures", metavar="DIR")
    parser.add_argument("--policy")
    parser.add_argument("--seat-caps")
    parser.add_argument("--meter")
    parser.add_argument("--active-seats")
    parser.add_argument("--now")
    parser.add_argument("--stale-minutes", type=int, default=0)
    parser.add_argument("--ledger-line", action="store_true")
    args = parser.parse_args(argv)

    if args.ledger_line:
        print(LEDGER)
        return 0

    paths = _from_fixtures(args.from_fixtures) if args.from_fixtures else _default_paths()
    if args.policy:
        paths["policy"] = args.policy
    if args.seat_caps:
        paths["caps"] = args.seat_caps
    if args.meter:
        paths["meter"] = args.meter
    if args.active_seats:
        paths["active"] = args.active_seats

    policy = _safe_load(paths["policy"])
    caps = _safe_load(paths["caps"])
    meter = _safe_load(paths["meter"])
    active = _load_active(paths["active"])
    now = _parse_now(args.now)

    stale = args.stale_minutes
    if stale <= 0:
        if isinstance(policy, dict) and isinstance(policy.get("meter_stale_minutes"), int):
            stale = int(policy["meter_stale_minutes"])
        else:
            stale = STALE_DEFAULT_MIN

    result = evaluate(
        policy=policy,
        caps=caps,
        meter=meter,
        active=active,
        now=now,
        stale_minutes=stale,
    )
    line = "cursor-overage-canary: %s [%s] — %s" % (
        result["verdict"],
        result["tag"],
        result["reason"],
    )
    print(line, file=sys.stderr)
    return int(result["rc"])


if __name__ == "__main__":
    sys.exit(main())
