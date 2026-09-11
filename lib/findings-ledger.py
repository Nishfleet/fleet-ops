#!/usr/bin/env python3
# lib/findings-ledger.py — canonical append-only findings ledger writer.
#
# fleet-ops#5456 ("nothing dies silently"): every organ that detects a fault
# writes a row here so a finding is never a chat-only mention. This helper is
# the ONLY writer — callers pass the fields, this file owns the schema,
# the finding_id derivation, and the append (flock + O_APPEND).
#
# Ledger: FLEET_FINDINGS_LEDGER (default
#   ~/workspaces/tooling/nish-vault/_system/shared-memory/findings-ledger.jsonl)
#
# Row schema (matches the existing 769-row file):
#   ts            ISO-8601 UTC, Z suffix
#   source_organ  the organ that found it (e.g. stop-escalation-dispatch)
#   run_id        the organ's run identifier (dispatch hash, report dir, date)
#   finding_id    16-hex digest; default sha1(source_organ + run_id +
#                 normalised title) — stable across re-detection
#   severity      info | warning | error | critical
#   title         one-line human description
#   evidence_ref  path / url / issue ref proving it
#   disposition   filed | carried_over | by_design | duplicate_of | panel_fail
#   ref           issue/PR ref or named reason — REQUIRED, never empty
#   reason        why this disposition
#
# Usage:
#   findings-ledger.py append --source-organ X --run-id Y --severity warning \
#       --title T --evidence-ref E --disposition carried_over \
#       --ref "Nishfleet/fleet-ops#123" --reason "unit died at hop 2"
#
# Exit 0 on append; exit 2 on validation failure (missing/empty required
# fields, unknown severity/disposition); exit 1 on I/O failure.

import argparse
import fcntl
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone

DEFAULT_LEDGER = (
    "/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/"
    "findings-ledger.jsonl"
)

SEVERITIES = {"info", "warning", "error", "critical"}
DISPOSITIONS = {
    "filed",
    "carried_over",
    "by_design",
    "duplicate_of",
    "panel_fail",
}

REQUIRED = (
    "source_organ",
    "run_id",
    "severity",
    "title",
    "evidence_ref",
    "disposition",
    "ref",
    "reason",
)


def ledger_path() -> str:
    return os.environ.get("FLEET_FINDINGS_LEDGER", DEFAULT_LEDGER)


def normalize_title(title: str) -> str:
    """Lowercase + collapse whitespace so re-detection lands on the same id."""
    return re.sub(r"\s+", " ", title.strip().lower())


def finding_id(source_organ: str, run_id: str, title: str) -> str:
    digest = hashlib.sha1(
        f"{source_organ}\x00{run_id}\x00{normalize_title(title)}".encode("utf-8")
    ).hexdigest()
    return digest[:16]


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def validate(row: dict) -> list:
    errs = []
    for field in REQUIRED:
        if not str(row.get(field) or "").strip():
            errs.append(f"missing/empty required field: {field}")
    if row.get("severity") not in SEVERITIES:
        errs.append(f"unknown severity: {row.get('severity')!r}")
    if row.get("disposition") not in DISPOSITIONS:
        errs.append(f"unknown disposition: {row.get('disposition')!r}")
    return errs


def append_row(row: dict, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    line = json.dumps(row, ensure_ascii=False) + "\n"
    # flock serialises concurrent writers; O_APPEND keeps each write atomic.
    with open(path, "a", encoding="utf-8") as fh:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        fh.write(line)
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def cmd_append(args: argparse.Namespace) -> int:
    row = {
        "ts": args.ts or now_iso(),
        "source_organ": args.source_organ,
        "run_id": args.run_id,
        "finding_id": args.finding_id
        or finding_id(args.source_organ or "", args.run_id or "", args.title or ""),
        "severity": args.severity,
        "title": args.title,
        "evidence_ref": args.evidence_ref,
        "disposition": args.disposition,
        "ref": args.ref,
        "reason": args.reason,
    }
    if args.occurrences is not None:
        row["occurrences"] = args.occurrences

    errs = validate(row)
    if errs:
        for e in errs:
            print(f"findings-ledger: {e}", file=sys.stderr)
        return 2

    path = args.ledger or ledger_path()
    try:
        append_row(row, path)
    except OSError as exc:
        print(f"findings-ledger: append failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps({"finding_id": row["finding_id"], "ledger": path}))
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description="canonical append-only findings-ledger writer (fleet-ops#5456)"
    )
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("append", help="validate + append one finding row")
    a.add_argument("--source-organ", required=True)
    a.add_argument("--run-id", required=True)
    a.add_argument("--finding-id", default="")
    a.add_argument("--severity", required=True)
    a.add_argument("--title", required=True)
    a.add_argument("--evidence-ref", required=True)
    a.add_argument("--disposition", required=True)
    a.add_argument("--ref", required=True)
    a.add_argument("--reason", required=True)
    a.add_argument("--occurrences", type=int, default=None)
    a.add_argument("--ts", default="")
    a.add_argument("--ledger", default="")
    args = p.parse_args(argv)
    if args.cmd == "append":
        return cmd_append(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
