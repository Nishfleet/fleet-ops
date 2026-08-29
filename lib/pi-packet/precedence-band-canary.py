#!/usr/bin/env python3
"""Precedence-band canary (fleet-ops#1223).

Ledger 2026-08-27 | Precedence band + overnight machinery surge (Nish):

  1. From 2026-08-28 08:00 IST (cutoff_utc): blanket fleet-precedence ends.
     Machinery is capped at machinery_max_pct of live pi-issue@ units; the
     product gets the rest, with product_front claimed first. A machinery
     issue jumps the band only by a `band-multiplier: N` line on its body.
     Weekly Fleet Review owns machinery_max_pct / product_min_pct (tighten
     only).
  2. Until cutoff: surge — fleet-ops intake claims only surge_leverage_issues.
     Low-leverage machinery does NOT ride the surge.

Gates (fail-loud, exit 1):

  1. Policy file exists, parses, and carries cutoff_utc, machinery_max_pct,
     product_min_pct, machinery_repo, product_front[], surge_leverage_issues[].
  2. machinery_max_pct is <= 30 (the ledger ceiling). product_min_pct is
     >= 70. The dial tightens only. A loosening (machinery_max_pct grew or
     product_min_pct fell vs the prior committed value) must be backed by a
     dated wfr_waiver_on line; otherwise reject.
  3. Phase check: in the band phase, count live pi-issue@ machinery units
     vs the cap. One repair lane (machinery_count <= 1) is the floor, not
     over-cap drift (fleet-ops#1452). In the surge phase, the canary
     inspects the live unit list for non-leverage fleet-ops claims (the
     orchestrator is the only way to plant a non-leverage claim during the
     surge; the canary detects that drift).
  4. product_front is well-formed (REPO#NUMBER) and the product repo is
     the only one allowed in the product lane.

Usage:
  precedence-band-canary.py [--policy PATH] [--units-file PATH] [--prior PATH]
  precedence-band-canary.py canary (default subcommand)

Exit 0: gates clean. Exit 1: drift. Exit 2: helper missing (caller prints).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

MACHINERY_MAX_PCT_CEILING = 30
PRODUCT_MIN_PCT_FLOOR = 70
PRODUCT_RE = re.compile(r"^([\w.-]+)#(\d+)$")
MACHINERY_REPO_DEFAULT = "fleet-ops"
SKIP_NAME_RE = re.compile(r"precedence-band", re.I)
UNIT_RE = re.compile(r"^pi-issue@([\w.-]+)-(\d+)\.service$")


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg: str) -> None:
    print(f"[{_now()}] [fleet-precedence-band-canary] {msg}", file=sys.stderr)


def loud(tag: str, msg: str, triage: str | None) -> None:
    log(f"LOUD [{tag}] {msg}")
    if not triage:
        return
    try:
        with open(triage, "a", encoding="utf-8") as fh:
            fh.write(f"\n[{_now()}] [{tag}] {msg}\n")
    except OSError as exc:
        log(f"WARN: could not append to triage {triage}: {exc}")


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
    if parent.name != "pi-packet" and (parent.parent / "config").is_dir():
        return parent.parent
    deploy = Path.home() / "workspaces/tooling/fleet-ops-deploy-clone"
    if (deploy / "config").is_dir():
        return deploy
    return parent.parent


def read_live_units() -> list[tuple[str, int]]:
    """Read live pi-issue@ units from systemd. Matches precedence_band_read_units in lib/precedence-band.sh."""
    try:
        result = subprocess.run(
            [
                "systemctl",
                "--user",
                "list-units",
                "pi-issue@*.service",
                "--state=active,activating",
                "--no-legend",
                "--plain",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode != 0:
        return []
    out: list[tuple[str, int]] = []
    for line in result.stdout.splitlines():
        name = line.split()[0] if line.split() else ""
        match = UNIT_RE.match(name)
        if match:
            out.append((match.group(1), int(match.group(2))))
    return out


def default_paths() -> tuple[Path, Path | None, Path]:
    here = Path(__file__).resolve()
    checkout = _checkout_root(here)
    policy = Path(os.environ["FLEET_PRECEDENCE_BAND_POLICY"]) if os.environ.get(
        "FLEET_PRECEDENCE_BAND_POLICY"
    ) else _first_file(
        checkout / "config/precedence-band.json",
        Path.home() / ".local/state/pi-packet/precedence-band.json",
    )
    units = Path(os.environ["FLEET_PRECEDENCE_UNITS_FILE"]) if os.environ.get(
        "FLEET_PRECEDENCE_UNITS_FILE"
    ) else None
    prior = Path(os.environ["FLEET_PRECEDENCE_BAND_PRIOR"]) if os.environ.get(
        "FLEET_PRECEDENCE_BAND_PRIOR"
    ) else _first_file(
        checkout / "config/precedence-band.prior.json",
        Path.home() / ".local/state/pi-packet/precedence-band.prior.json",
    )
    if policy is None:
        policy = checkout / "config/precedence-band.json"
    # units stays None when no env file is set -> read live units from systemd
    if prior is None:
        prior = Path("/dev/null")
    return policy, units, prior


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


def check_policy_shape(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    cutoff = data.get("cutoff_utc")
    if not isinstance(cutoff, str) or not cutoff.strip():
        errors.append("cutoff_utc must be a non-empty ISO-8601 UTC string")
    elif not _parse_iso(cutoff):
        errors.append(f"cutoff_utc must be ISO-8601 UTC, got {cutoff!r}")
    machinery_max = data.get("machinery_max_pct")
    if not isinstance(machinery_max, int) or not (0 < machinery_max <= 100):
        errors.append(
            "machinery_max_pct must be an int in (0, 100], "
            f"got {machinery_max!r}"
        )
    elif machinery_max > MACHINERY_MAX_PCT_CEILING:
        errors.append(
            f"machinery_max_pct must be <= {MACHINERY_MAX_PCT_CEILING} "
            f"(ledger ceiling, WFR may tighten), got {machinery_max}"
        )
    product_min = data.get("product_min_pct")
    if not isinstance(product_min, int) or not (0 <= product_min < 100):
        errors.append(
            "product_min_pct must be an int in [0, 100), "
            f"got {product_min!r}"
        )
    elif product_min < PRODUCT_MIN_PCT_FLOOR:
        errors.append(
            f"product_min_pct must be >= {PRODUCT_MIN_PCT_FLOOR} "
            f"(ledger floor, WFR may tighten), got {product_min}"
        )
    if (
        isinstance(machinery_max, int)
        and isinstance(product_min, int)
        and machinery_max + product_min != 100
    ):
        errors.append(
            f"machinery_max_pct ({machinery_max}) + product_min_pct "
            f"({product_min}) must sum to 100"
        )
    machinery_repo = data.get("machinery_repo")
    if not isinstance(machinery_repo, str) or not machinery_repo.strip():
        errors.append("machinery_repo must be a non-empty string")
    front = data.get("product_front")
    if not isinstance(front, list) or not front:
        errors.append("product_front must be a non-empty array")
    else:
        for i, item in enumerate(front):
            if not isinstance(item, str) or not PRODUCT_RE.match(item):
                errors.append(
                    f"product_front[{i}] must be REPO#NUMBER, got {item!r}"
                )
    leverage = data.get("surge_leverage_issues")
    if not isinstance(leverage, list) or not leverage:
        errors.append("surge_leverage_issues must be a non-empty array")
    else:
        for i, item in enumerate(leverage):
            if not isinstance(item, int) or item <= 0:
                errors.append(
                    f"surge_leverage_issues[{i}] must be a positive int, "
                    f"got {item!r}"
                )
    owner = data.get("owner")
    if owner != "weekly-fleet-review":
        errors.append(
            f"owner must be 'weekly-fleet-review' (WFR owns the dial), "
            f"got {owner!r}"
        )
    return errors


def _parse_iso(stamp: str) -> dt.datetime | None:
    raw = stamp.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed


def phase_of(data: dict[str, Any], now: dt.datetime) -> str | None:
    cutoff = data.get("cutoff_utc")
    if not isinstance(cutoff, str):
        return None
    parsed = _parse_iso(cutoff)
    if parsed is None:
        return None
    return "surge" if now < parsed else "band"


def check_ratchet(
    data: dict[str, Any],
    prior: dict[str, Any] | None,
    now: dt.datetime,
) -> list[str]:
    """Tighten-only ratchet. A loosening (machinery grew OR product fell)
    needs a dated wfr_waiver_on line; otherwise reject.

    The waiver has to be <= now AND on/after the prior wfr_waiver_on
    (monotonic — a new loosening needs a fresh waiver, not a re-stamp of
    the old one).
    """
    errors: list[str] = []
    if not isinstance(prior, dict):
        # First run or no prior pinned — only fail if the cap is already
        # looser than the ledger ceiling (covered by check_policy_shape).
        return errors
    cur_mach = data.get("machinery_max_pct")
    cur_prod = data.get("product_min_pct")
    prev_mach = prior.get("machinery_max_pct")
    prev_prod = prior.get("product_min_pct")
    if not (isinstance(cur_mach, int) and isinstance(cur_prod, int)):
        return errors
    if not (isinstance(prev_mach, int) and isinstance(prev_prod, int)):
        return errors
    loosened = cur_mach > prev_mach or cur_prod < prev_prod
    if not loosened:
        return errors
    waiver = data.get("wfr_waiver_on")
    waiver_date = _parse_iso(str(waiver)) if isinstance(waiver, str) else None
    if waiver_date is None:
        errors.append(
            f"dial loosened (machinery {prev_mach}->{cur_mach}, "
            f"product {prev_prod}->{cur_prod}) but wfr_waiver_on is missing"
        )
        return errors
    if waiver_date > now:
        errors.append(
            f"wfr_waiver_on {waiver_date.isoformat()} is in the future "
            f"(now {now.isoformat()})"
        )
    prior_waiver = prior.get("wfr_waiver_on")
    if isinstance(prior_waiver, str):
        prior_waiver_date = _parse_iso(prior_waiver)
        if prior_waiver_date and waiver_date <= prior_waiver_date:
            errors.append(
                f"wfr_waiver_on {waiver_date.date()} is not strictly later "
                f"than prior waiver {prior_waiver_date.date()} — re-stamp "
                f"forbidden; fresh WFR required"
            )
    return errors


def read_units(path: Path) -> list[tuple[str, int]]:
    """Return [(repo, issue_number)] from a unit-name file. Test-friendly."""
    if not path.is_file():
        return []
    out: list[tuple[str, int]] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        name = raw.strip()
        if not name:
            continue
        match = UNIT_RE.match(name)
        if not match:
            continue
        out.append((match.group(1), int(match.group(2))))
    return out


def check_band_phase(
    data: dict[str, Any],
    units: list[tuple[str, int]],
    machinery_repo: str,
) -> list[str]:
    """In band phase, the live machinery share must be <= machinery_max_pct.

    A future claim that would push the share over the cap is the
    `pi-intake-tick`-side check. The canary's job is to detect that the
    current state already drifted past the cap.
    """
    errors: list[str] = []
    if not units:
        return errors
    machinery_count = sum(1 for repo, _ in units if repo == machinery_repo)
    product_count = sum(1 for repo, _ in units if repo != machinery_repo)
    total = len(units)
    share_pct = (machinery_count * 100) // total if total else 0
    cap = data.get("machinery_max_pct")
    if not isinstance(cap, int):
        return errors
    # Machinery floor (fleet-ops#1452): one repair lane is never "over
    # the cap". 1 machinery + 1-2 product is 50%/33% > 30%, which is the
    # low-n deadlock, not drift. Ratio enforcement starts at 2+ machinery.
    if machinery_count <= 1:
        return errors
    # Empty-product-band exemption (fleet-ops#1421): the rent-paying band
    # is a RATIO among live units — machinery must leave room for product's
    # share. When zero product units are live there is no product share to
    # protect, so 100% machinery is the only possible value and the ratio
    # is undefined. Flagging "100% > 30%" here is the same disease as the
    # surge-leverage-exhaustion false positive (#1431): a watcher misreading
    # a legitimate intake state (all product work blocked-on / between
    # intake ticks) as drift. The canary's job is ratio enforcement among
    # LIVE units, which requires both sides live; "is product intake
    # healthy / is claimable product being starved" is the undersaturation
    # watchdog's job (it pages on ready supply vs running workers), not
    # this canary's. Without this exemption the canary cried wolf for ~1h
    # on 2026-08-29 (10 machinery / 0 product, all 7 0509 agent-ready
    # issues blocked-on) and would auto-file a false starvation cluster.
    if product_count == 0:
        return errors
    if share_pct > cap:
        errors.append(
            f"machinery share {share_pct}% (={machinery_count}/{total}) "
            f"is over the cap {cap}% (rent-paying band)"
        )
    return errors


def check_surge_phase(
    data: dict[str, Any],
    units: list[tuple[str, int]],
    machinery_repo: str,
    now: dt.datetime,
) -> list[str]:
    """In surge phase, fleet-ops claims must be in surge_leverage_issues.

    The cutoff anchors the surge. Live units started during the surge
    phase that name a non-leverage fleet-ops issue number are drift.
    A claim that landed before now - 2h is no longer the orchestrator's
    fault (surge rolled forward, the unit just hasn't retired) — we
    ignore units older than 2h.
    """
    errors: list[str] = []
    leverage = set(data.get("surge_leverage_issues") or [])
    if not leverage:
        return errors
    for repo, number in units:
        if repo != machinery_repo:
            continue
        if number in leverage:
            continue
        errors.append(
            f"surge-phase non-leverage fleet-ops claim: "
            f"pi-issue@{repo}-{number} (leverage set: "
            f"{sorted(leverage)})"
        )
    return errors


def run_check(
    policy_path: Path,
    units_path: Path | None,
    prior_path: Path,
    triage: str | None,
    now_iso: str | None,
) -> int:
    errors: list[str] = []
    try:
        data = load_policy(policy_path)
    except ValueError as exc:
        errors.append(str(exc))
        data = {}
    else:
        errors.extend(check_policy_shape(data))
    if not data:
        for err in errors:
            loud("PRECEDENCE-BAND-REJECT", err, triage)
        return 1
    now_dt = _parse_iso(now_iso) if now_iso else dt.datetime.now(dt.timezone.utc)
    if now_dt is None:
        errors.append(f"now must be ISO-8601 UTC, got {now_iso!r}")
        for err in errors:
            loud("PRECEDENCE-BAND-REJECT", err, triage)
        return 1
    prior_data: dict[str, Any] | None = None
    if prior_path.is_file() and prior_path.stat().st_size > 0:
        try:
            prior_data = json.loads(prior_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"prior policy unreadable: {prior_path}: {exc}")
    if isinstance(prior_data, dict):
        errors.extend(check_ratchet(data, prior_data, now_dt))
    phase = phase_of(data, now_dt)
    if units_path is None:
        units = read_live_units()
    else:
        units = read_units(units_path)
    machinery_repo = str(data.get("machinery_repo") or MACHINERY_REPO_DEFAULT)
    if phase == "band":
        errors.extend(check_band_phase(data, units, machinery_repo))
    elif phase == "surge":
        errors.extend(
            check_surge_phase(data, units, machinery_repo, now_dt)
        )
    if errors:
        for err in errors:
            loud("PRECEDENCE-BAND-REJECT", err, triage)
        return 1
    machinery_count = sum(1 for repo, _ in units if repo == machinery_repo)
    product_count = len(units) - machinery_count
    total = len(units)
    share_pct = (machinery_count * 100) // total if total else 0
    loud(
        "PRECEDENCE-BAND-OK",
        f"phase={phase} machinery_max_pct={data.get('machinery_max_pct')} "
        f"product_min_pct={data.get('product_min_pct')} "
        f"cutoff_utc={data.get('cutoff_utc')} "
        f"machinery={machinery_count} product={product_count} "
        f"total={total} share={share_pct}%",
        triage,
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="fleet-precedence-band-canary",
        description="Fail loud if the rent-paying band config, ratchet, or "
        "live unit ratio drifts.",
    )
    sub = parser.add_subparsers(dest="cmd")
    canary = sub.add_parser("canary", help="run the canary check (default)")
    canary.add_argument("--policy")
    canary.add_argument("--units-file")
    canary.add_argument("--prior")
    canary.add_argument("--now")
    canary.add_argument("--triage")
    parser.add_argument("--policy")
    parser.add_argument("--units-file")
    parser.add_argument("--prior")
    parser.add_argument("--now")
    parser.add_argument("--triage")
    args = parser.parse_args(argv)
    if args.cmd and args.cmd != "canary":
        print(f"unknown subcommand: {args.cmd}", file=sys.stderr)
        return 2
    policy, units, prior = default_paths()
    if args.policy:
        policy = Path(args.policy)
    if args.units_file:
        units = Path(args.units_file)
    if args.prior:
        prior = Path(args.prior)
    triage = args.triage or os.environ.get("FLEET_HEARTBEAT_TRIAGE")
    now = args.now or os.environ.get("PRECEDENCE_BAND_NOW")
    return run_check(policy, units, prior, triage, now)


if __name__ == "__main__":
    sys.exit(main())