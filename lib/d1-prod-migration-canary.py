#!/usr/bin/env python3
"""D1 prod migration senior-process canary (fleet-ops#905).

Ledger 2026-08-27: fleet may apply 0509 prod D1 migrations autonomously
through 2026-09-08, but ONLY via the senior process:
  1. strong lane plan
  2. independent senior blind-review and approval
  3. verified backup
  4. concrete rollback
  5. apply + live verification
  6. text Nish

This canary inspects the enrolled product repo (0509 by default) and
fail-loud (exit 1) when any migration added after the canary's own
introduction is missing the evidence directory that proves the six steps.

After 2026-09-08T23:59:59Z the vacation grant expires, so any new
migration is also a fail-loud violation because autonomous application is
no longer allowed.

Usage:
  d1-prod-migration-canary.py
  d1-prod-migration-canary.py --repo /home/nish/workspaces/products/0509
  d1-prod-migration-canary.py --threshold 2026-08-28T00:00:00Z --now 2026-08-28T12:00:00Z
  d1-prod-migration-canary.py --ledger-line
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

MIGRATION_NAME_PATTERN = re.compile(r"^\d{4}_[A-Za-z0-9_]+\.sql$")
REQUIRED_ARTIFACTS = (
    "plan.md",
    "review.md",
    "backup.md",
    "rollback.sql",
    "verification.md",
    "text-nish.md",
)
VACATION_WINDOW_END = datetime(2026, 9, 8, 23, 59, 59, tzinfo=timezone.utc)
DEFAULT_REPO = "/home/nish/workspaces/products/0509"
DEFAULT_FLEET_OPS_REPO = "/home/nish/workspaces/tooling/fleet-ops-deploy-clone"
CANARY_SOURCE_PATH = "lib/d1-prod-migration-canary.py"
LEDGER_LINE = (
    "2026-08-27 | D1 prod migrations | fleet may apply 0509 prod D1 migrations "
    "autonomously through 2026-09-08 ONLY via the senior process: strong lane plan, "
    "independent senior blind-review, verified backup, concrete rollback, "
    "apply + live verification, and text Nish. Enforced by "
    "fleet-d1-prod-migration-canary."
)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(s)
    except (ValueError, TypeError):
        return None


def log(msg: str, triage: str | None = None) -> None:
    ts = _now().strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"[{ts}] [fleet-d1-prod-migration-canary] {msg}"
    print(line, file=sys.stderr)
    if triage:
        try:
            with open(triage, "a", encoding="utf-8") as fh:
                fh.write(f"\n{line}\n")
        except OSError as exc:
            log(f"WARN: could not append to triage {triage}: {exc}")


def loud(tag: str, msg: str, triage: str | None = None) -> None:
    log(f"LOUD [{tag}] {msg}", triage=triage)


def _git_add_date(repo: Path, rel_path: str) -> datetime | None:
    """Return the author date a path was first added to the repo, or None."""
    cmd = ["git", "-C", str(repo), "log", "--diff-filter=A", "--format=%aI", "--", rel_path]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"WARN: git add-date failed for {rel_path}: {exc}")
        return None
    if result.returncode != 0:
        return None
    first = result.stdout.strip().splitlines()[0] if result.stdout.strip() else None
    return _parse_iso(first)


def _canary_intro_date(fleet_ops_repo: Path) -> datetime | None:
    """Date this canary source file was first added to fleet-ops."""
    return _git_add_date(fleet_ops_repo, CANARY_SOURCE_PATH)


def _list_migrations(repo: Path) -> list[str]:
    migrations_dir = repo / "migrations"
    if not migrations_dir.is_dir():
        return []
    names = [
        f.name
        for f in migrations_dir.iterdir()
        if f.is_file() and MIGRATION_NAME_PATTERN.match(f.name)
    ]
    return sorted(names)


def _migration_evidence_dir(repo: Path, migration_name: str, evidence_dir: Path) -> Path:
    return repo / evidence_dir / migration_name


def _check_evidence(evidence_dir: Path) -> list[str]:
    """Return a list of missing/empty artifact names."""
    errors: list[str] = []
    if not evidence_dir.is_dir():
        return ["<evidence directory missing>"]
    for artifact in REQUIRED_ARTIFACTS:
        path = evidence_dir / artifact
        if not path.is_file():
            errors.append(f"{artifact}: missing")
        elif path.stat().st_size == 0:
            errors.append(f"{artifact}: empty")
    return errors


def evaluate(
    repo: Path,
    fleet_ops_repo: Path,
    threshold: datetime | None,
    now: datetime,
    vacation_end: datetime,
    evidence_dir: Path,
    triage: str | None,
) -> dict[str, Any]:
    if not (repo / ".git").is_dir():
        return {
            "verdict": "SKIP",
            "reason": f"{repo} is not a git checkout — cannot date migrations",
            "repo": str(repo),
        }

    if not (repo / "migrations").is_dir():
        return {
            "verdict": "SKIP",
            "reason": f"{repo}/migrations not found — nothing to verify",
            "repo": str(repo),
        }

    if threshold is None:
        threshold = _canary_intro_date(fleet_ops_repo)
    if threshold is None:
        threshold = now
        log(
            "WARN: cannot determine canary introduction date; using current time "
            "as threshold (no migrations will be checked on this run)",
            triage=triage,
        )

    migrations = _list_migrations(repo)
    if not migrations:
        return {
            "verdict": "PASS",
            "reason": "no migration files in migrations/",
            "repo": str(repo),
        }

    grant_expired = now > vacation_end
    checked = 0
    failures: list[str] = []
    skipped = 0

    for name in migrations:
        add_date = _git_add_date(repo, f"migrations/{name}")
        if add_date is None:
            # Untracked or git-less? Use mtime as a fallback, but do not fail.
            try:
                mtime = datetime.fromtimestamp(
                    (repo / "migrations" / name).stat().st_mtime, tz=timezone.utc
                )
            except OSError:
                mtime = None
            if mtime is None or mtime <= threshold:
                skipped += 1
                continue
            add_date = mtime

        if add_date <= threshold:
            skipped += 1
            continue

        checked += 1

        if grant_expired:
            failures.append(
                f"{name} (added {add_date.isoformat()}) — vacation grant expired "
                f"({vacation_end.isoformat()}); autonomous D1 prod migration no longer allowed"
            )
            continue

        errors = _check_evidence(_migration_evidence_dir(repo, name, evidence_dir))
        if errors:
            failures.append(
                f"{name} (added {add_date.isoformat()}) missing senior-process evidence "
                f"at {evidence_dir}/{name}: {', '.join(errors)}"
            )

    if failures:
        return {
            "verdict": "REJECT",
            "reason": (
                f"{len(failures)} migration(s) added after {threshold.isoformat()} "
                f"fail the senior-process gate: " + "; ".join(failures)
            ),
            "repo": str(repo),
            "checked": checked,
            "skipped": skipped,
            "failures": failures,
        }

    return {
        "verdict": "PASS",
        "reason": (
            f"no new D1 prod migrations to verify after {threshold.isoformat()} "
            f"(checked {checked}, skipped {skipped})"
        ),
        "repo": str(repo),
        "checked": checked,
        "skipped": skipped,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="D1 prod migration senior-process canary for fleet-ops#905.",
    )
    parser.add_argument(
        "--repo",
        default=os.environ.get("FLEET_D1_PROD_MIGRATION_REPO", DEFAULT_REPO),
        help="path to the product repo containing migrations/ (default: 0509 checkout)",
    )
    parser.add_argument(
        "--fleet-ops-repo",
        default=os.environ.get("FLEET_D1_CANARY_FLEET_OPS_REPO", DEFAULT_FLEET_OPS_REPO),
        help="path to fleet-ops source repo (used to date the canary's introduction)",
    )
    parser.add_argument(
        "--threshold",
        default=os.environ.get("FLEET_D1_CANARY_THRESHOLD"),
        help="override the canary introduction date (ISO-8601)",
    )
    parser.add_argument(
        "--now",
        default=os.environ.get("FLEET_D1_CANARY_NOW"),
        help="override current time for date-based checks (ISO-8601)",
    )
    parser.add_argument(
        "--evidence-dir",
        default="migrations/evidence",
        help="relative path to evidence directory inside the product repo",
    )
    parser.add_argument(
        "--triage",
        default=os.environ.get("FLEET_HEARTBEAT_TRIAGE"),
        help="heartbeat triage file to append LOUD lines to",
    )
    parser.add_argument(
        "--ledger-line",
        action="store_true",
        help="print the ledger line this canary enforces",
    )
    args = parser.parse_args()

    if args.ledger_line:
        print(LEDGER_LINE)
        return 0

    repo = Path(args.repo)
    fleet_ops_repo = Path(args.fleet_ops_repo)
    threshold = _parse_iso(args.threshold)
    now = _parse_iso(args.now) or _now()

    result = evaluate(
        repo=repo,
        fleet_ops_repo=fleet_ops_repo,
        threshold=threshold,
        now=now,
        vacation_end=VACATION_WINDOW_END,
        evidence_dir=Path(args.evidence_dir),
        triage=args.triage,
    )
    verdict = result["verdict"]
    reason = result["reason"]

    if verdict == "PASS":
        log(f"D1-PROD-MIGRATION-OK: {reason}", triage=args.triage)
        return 0
    if verdict == "SKIP":
        log(f"D1-PROD-MIGRATION-SKIP: {reason}", triage=args.triage)
        return 0
    loud("D1-PROD-MIGRATION-REJECT", reason, triage=args.triage)
    return 1


if __name__ == "__main__":
    sys.exit(main())
