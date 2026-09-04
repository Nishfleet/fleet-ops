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

Usage:
  python3 lib/agent-ready-spec-gate.py check-body
  python3 lib/agent-ready-spec-gate.py check-body --body FILE
  python3 lib/agent-ready-spec-gate.py check-size
  python3 lib/agent-ready-spec-gate.py check-size --body FILE --comments FILE --labels JSON
  python3 lib/agent-ready-spec-gate.py verify --repo-root DIR

Exit codes:
  0 — spec present / size ok / first-admission paths are wired
  1 — no spec / oversized / a first-admission path dropped the gate
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

FIRST_ADMISSION = (
    "bin/lifecycle-label-sweep",
    "bin/pi-audit-tally",
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

# fleet-ops#3309: more than this many live `required:` lines is too big
# for one worker. Struck-through lines do not count. Umbrella-labeled
# issues are exempt (tracking parents, never claimable).
MAX_REQUIRED = 2
STRUCK_LINE = re.compile(r"^\s*(?:[-*]\s+)?~~.+~~\s*$")
UMBRELLA_NAME = "umbrella"
SIZE_TICK = "lib/pi-intake-tick.sh"
SIZE_INTAKE = "prompts/intake.md"


def live_text(text: str | None) -> str:
    """Drop struck-through lines (same shape as blocked-reconcile)."""
    lines = []
    for line in (text or "").splitlines():
        if STRUCK_LINE.match(line):
            continue
        lines.append(line)
    return "\n".join(lines)


def count_required(text: str | None) -> int:
    """Count live required: field lines in body and/or comments."""
    n = 0
    for match in FIELD_RE.finditer(live_text(text)):
        if match.group(1).lower() == "required":
            n += 1
    return n


def has_umbrella(labels_raw: str | None) -> bool:
    """True when labels JSON/csv includes the umbrella label."""
    raw = (labels_raw or "").strip()
    names: list[str] = []
    if raw.startswith("["):
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            data = []
        if isinstance(data, list):
            for item in data:
                if isinstance(item, dict):
                    names.append(str(item.get("name") or ""))
                else:
                    names.append(str(item))
    else:
        names = [part.strip() for part in raw.split(",") if part.strip()]
    return any(name.lower() == UMBRELLA_NAME for name in names)


def issue_has_spec(body: str | None) -> bool:
    """True when the issue body carries a product or control-plane spec."""
    text = body or ""
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
    if issue_has_spec(text):
        print("SPEC-GATE: ok")
        return 0
    print("SPEC-GATE: refused — body has no termination:/accept:/required:/metric:", file=sys.stderr)
    return 1


def _read_optional(path: str) -> str:
    if not path:
        return ""
    if path == "-":
        return sys.stdin.read()
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        _die(f"cannot read {path}: {exc}")
    return ""


def cmd_check_size(args: argparse.Namespace) -> int:
    """Exit 1 when live required: lines exceed MAX_REQUIRED (fleet-ops#3309)."""
    body = _read_optional(args.body) if args.body else ""
    if not args.body and args.body_text is not None:
        body = args.body_text
    if not args.body and args.body_text is None and not sys.stdin.isatty() and not args.comments:
        body = sys.stdin.read()
    comments = _read_optional(args.comments) if args.comments else ""
    n = count_required(body) + count_required(comments)
    if has_umbrella(args.labels):
        print(f"SPEC-GATE: size-ok umbrella ({n} required:)")
        return 0
    if n > MAX_REQUIRED:
        print(f"split me: {n} requirements; one requirement per issue")
        print("blocked-on: split")
        return 1
    print(f"SPEC-GATE: size-ok ({n} required:)")
    return 0


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


def verify_size_wired(repo: Path) -> list[str]:
    """Claim-time size bounce must stay wired (fleet-ops#3309)."""
    errors: list[str] = []
    tick = _read(repo / SIZE_TICK)
    if not tick:
        errors.append(f"missing {SIZE_TICK} (size bounce lives there)")
    else:
        if "check-size" not in tick:
            errors.append(f"{SIZE_TICK} does not call agent-ready-spec-gate check-size")
        if "skipped-oversized" not in tick:
            errors.append(f"{SIZE_TICK} lost skipped-oversized on size bounce")
        i_size = tick.find("check-size")
        i_push = tick.find("push --force-with-lease")
        if i_size >= 0 and i_push >= 0 and i_size > i_push:
            errors.append(
                f"{SIZE_TICK} runs check-size after the claim push"
            )
        window = tick[i_size : i_size + 1200] if i_size >= 0 else ""
        if i_size >= 0 and "--add-label agent-blocked" not in window:
            errors.append(
                f"{SIZE_TICK} does not flip agent-blocked on size bounce"
            )
        if i_size >= 0 and "--remove-label agent-ready" not in window:
            errors.append(
                f"{SIZE_TICK} does not drop agent-ready on size bounce"
            )
    intake = _read(repo / SIZE_INTAKE)
    if not intake:
        errors.append(f"missing {SIZE_INTAKE} (size bounce lives there)")
    elif "check-size" not in intake:
        errors.append(f"{SIZE_INTAKE} does not call agent-ready-spec-gate check-size")
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
    errors = (
        verify_wired(repo)
        + verify_caps(repo)
        + verify_matrix(repo)
        + verify_size_wired(repo)
    )
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
    p_check.set_defaults(func=cmd_check_body)

    p_size = sub.add_parser(
        "check-size", help="exit 1 iff live required: lines exceed 2"
    )
    p_size.add_argument("--body", default="", help="read body from FILE")
    p_size.add_argument("--body-text", default=None, help="body as a string")
    p_size.add_argument(
        "--comments", default="", help="read comments text from FILE"
    )
    p_size.add_argument(
        "--labels", default="", help="labels JSON array or comma-separated names"
    )
    p_size.set_defaults(func=cmd_check_size)

    p_verify = sub.add_parser(
        "verify", help="fail-closed check that first-admission paths stay wired"
    )
    p_verify.add_argument("--repo-root", required=True)
    p_verify.set_defaults(func=cmd_verify)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
