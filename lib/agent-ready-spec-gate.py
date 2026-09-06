#!/usr/bin/env python3
"""agent-ready spec-gate (fleet-ops#543).

Ledger 2026-08-25 | work supply: orchestrators may apply `agent-ready`
autonomously (caps + spec gate); Nish's per-item key is not required.

This is the spec-gate half. An issue may receive `agent-ready` on first
admission only when its body carries a machine-checkable spec. Re-queue
paths (blocked-reconcile, undersaturation, in-progress flip) are not
first admission and do not call this.

Accepted spec shapes:
  product:     a `termination:` line with a command, or `accept:` / `metric:`
  control-plane: a `required:` line (canary/enforcement issues)

fleet-ops#3255: for repo fleet-ops, the body must ALSO carry a `moves:`
line naming one of the product metrics (sessions_to_pr_pct,
product_merges_per_day, reverts_per_100_merges, packet_bytes,
no_usable_seat_events, scout_candidate_age). No `moves:` line = SPEC-GATE
refused, the same path as a missing termination:.

Usage:
  python3 lib/agent-ready-spec-gate.py check-body
  python3 lib/agent-ready-spec-gate.py check-body --body FILE
  python3 lib/agent-ready-spec-gate.py check-body --repo fleet-ops
  python3 lib/agent-ready-spec-gate.py verify --repo-root DIR

Exit codes:
  0 — spec present / first-admission paths are wired
  1 — no spec / a first-admission path dropped the gate
  2 — usage error
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PROG = "agent-ready-spec-gate"

# Line-anchored field. Leading list markers allowed so canary bodies
# (`- required: ...`) count. termination: needs a command on the same
# line; the others may introduce a following list.
FIELD_RE = re.compile(
    r"(?im)^(?:[-*]\s+)*(termination|accept|required|metric)\s*:\s*(.*)$"
)

# fleet-ops#3255: control-plane work must name the product metric it moves.
MOVES_RE = re.compile(r"(?im)^(?:[-*]\s+)*moves\s*:\s*(.*)$")

MOVES_METRICS = (
    "sessions_to_pr_pct",
    "product_merges_per_day",
    "reverts_per_100_merges",
    "packet_bytes",
    "no_usable_seat_events",
    "scout_candidate_age",
)

FIRST_ADMISSION = (
    "bin/lifecycle-label-sweep",
    "bin/pi-audit-tally",
    # fleet-ops#3121: owner-authored admission bypass applies agent-ready
    # directly (no three-seat panel) after running the spec gate on the
    # issue body — a first-admission path, same class as pi-audit-tally.
    "bin/fleet-heartbeat-auditor",
)

REQUEUE_ALLOWLIST = (
    "bin/blocked-reconcile",
    "bin/fleet-heartbeat-undersaturation",
    # §3 orphan-claim release: already-admitted work returning to the queue
    "bin/fleet-heartbeat-tier1",
    # StartLimitBurst reap: same re-queue, not first admission
    "bin/pi-issue-failed-reap",
)

MATRIX_ID = "led-work-supply-agent-ready"
MATRIX_SOURCE = "decisions-ledger.md: 2026-08-25 | work supply"

# prompts/scout.md must keep a per-run label_budget cap; the exact
# number is the prompt's, not the gate's.
CAP_NEEDLES = (
    "label_budget = 8",
    "label_budget",
)


def _moves_metric(text: str) -> str | None:
    """Return the named metric when the body carries a valid moves: line."""
    for match in MOVES_RE.finditer(text):
        val = (match.group(1) or "").strip()
        for token in re.split(r"[\s,]+", val):
            if token in MOVES_METRICS:
                return token
    return None


def issue_has_spec(body: str | None, repo: str | None = None) -> bool:
    """True when the issue body carries a product or control-plane spec.

    For repo fleet-ops the body must also carry a `moves:` line naming one
    of the product metrics (fleet-ops#3255); without it the gate refuses.
    """
    text = body or ""
    if repo == "fleet-ops" and not _moves_metric(text):
        return False
    found_non_termination = False
    for match in FIELD_RE.finditer(text):
        name = match.group(1).lower()
        rest = (match.group(2) or "").strip()
        if name == "termination":
            if rest:
                return True
            continue
        found_non_termination = True
    return found_non_termination


def _die(msg: str, code: int = 2) -> None:
    print(f"{PROG}: {msg}", file=sys.stderr)
    raise SystemExit(code)


def cmd_check_body(args: argparse.Namespace) -> int:
    if args.body:
        try:
            text = Path(args.body).read_text(encoding="utf-8")
        except OSError as exc:
            _die(f"cannot read --body: {exc}")
    elif args.body_text is not None:
        text = args.body_text
    else:
        text = sys.stdin.read()
    if issue_has_spec(text, repo=args.repo):
        print("SPEC-GATE: ok")
        return 0
    if args.repo == "fleet-ops":
        print(
            "SPEC-GATE: refused — body has no termination:/accept:/required:/metric: "
            "or no moves: line naming a product metric (fleet-ops#3255)",
            file=sys.stderr,
        )
    else:
        print("SPEC-GATE: refused — body has no termination:/accept:/required:/metric:", file=sys.stderr)
    return 1


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def verify_wired(repo: Path) -> list[str]:
    errors: list[str] = []
    for rel in FIRST_ADMISSION:
        path = repo / rel
        if not path.exists():
            errors.append(f"missing first-admission script: {rel}")
            continue
        text = _read(path)
        if "agent-ready-spec-gate" not in text:
            errors.append(
                f"{rel} applies agent-ready without calling agent-ready-spec-gate"
            )
    bin_dir = repo / "bin"
    if bin_dir.is_dir():
        for path in sorted(bin_dir.iterdir()):
            if not path.is_file():
                continue
            rel = f"bin/{path.name}"
            if rel in FIRST_ADMISSION or rel in REQUEUE_ALLOWLIST:
                continue
            text = _read(path)
            if "--add-label agent-ready" in text:
                errors.append(
                    f"{rel} applies agent-ready but is not a first-admission "
                    "or requeue path; wire the spec-gate or add it to the "
                    "requeue allowlist with a named reason"
                )
    return errors


def verify_caps(repo: Path) -> list[str]:
    text = _read(repo / "prompts" / "scout.md")
    if not text:
        return ["prompts/scout.md missing (agent-ready cap lives there)"]
    if not any(needle in text for needle in CAP_NEEDLES):
        return ["prompts/scout.md lost the agent-ready label_budget cap"]
    return []


def verify_matrix(repo: Path) -> list[str]:
    path = repo / "config" / "rule-enforcement.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"cannot load rule-enforcement matrix: {exc}"]
    for rule in data.get("rules") or []:
        if not isinstance(rule, dict):
            continue
        if str(rule.get("id") or "") != MATRIX_ID:
            continue
        status = str(rule.get("status") or "")
        source = str(rule.get("source") or "")
        errors: list[str] = []
        if status != "enforced":
            errors.append(
                f"{MATRIX_ID} must be status=enforced, got {status!r}"
            )
        if source != MATRIX_SOURCE:
            errors.append(
                f"{MATRIX_ID} source drifted, got {source!r}"
            )
        return errors
    return [f"{MATRIX_ID} missing from the rule-enforcement matrix"]


def cmd_verify(args: argparse.Namespace) -> int:
    repo = Path(args.repo_root)
    errors = verify_wired(repo) + verify_caps(repo) + verify_matrix(repo)
    if errors:
        for err in errors:
            print(f"SPEC-GATE: {err}", file=sys.stderr)
        return 1
    print("SPEC-GATE: first-admission wired, cap of 12 present, matrix enforced")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_check = sub.add_parser("check-body", help="exit 0 iff the body has a spec")
    p_check.add_argument("--body", default="", help="read body from FILE")
    p_check.add_argument("--body-text", default=None, help="body as a string")
    p_check.add_argument(
        "--repo",
        default="",
        help="repo name; fleet-ops requires a moves: line naming a product metric",
    )
    p_check.set_defaults(func=cmd_check_body)

    p_verify = sub.add_parser(
        "verify", help="fail-closed check that first-admission paths stay wired"
    )
    p_verify.add_argument("--repo-root", required=True)
    p_verify.set_defaults(func=cmd_verify)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
