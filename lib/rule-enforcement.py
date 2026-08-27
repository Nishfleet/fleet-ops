#!/usr/bin/env python3
"""Join vault standing rules + ledger decisions against the enforcement matrix.

fleet-ops#383. Pure logic: parse, join, classify. Filing issues is the
canary's job (gh lives in bash). Tests import these functions and also
drive the CLI.

Usage:
  python3 lib/rule-enforcement.py join \\
      --rules STANDING.md --ledger LEDGER.md --matrix MATRIX.json \\
      [--now ISO] [--stale-days N]
  python3 lib/rule-enforcement.py validate-matrix --matrix MATRIX.json
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from typing import Any

STANDING_PREFIX = "global-standing-rules.md: "
LEDGER_PREFIX = "decisions-ledger.md: "

STATUS_ENFORCED = re.compile(r"^enforced$")
STATUS_QUEUED = re.compile(r"^queued\(#(\d+)\)$")
STATUS_ADVISORY = re.compile(r"^advisory\((.+)\)$")

HEADING_RE = re.compile(r"^## (.+)$", re.M)
LEDGER_RE = re.compile(
    r"^- (\d{4}-\d{2}-\d{2}) \| ([^|]+) \| (.+)$", re.M
)
# FLAG lines in the open-questions section are not standing rules.
FLAG_BODY_RE = re.compile(r"^FLAG\b", re.I)

SIGNAL_FMT = "signal: rule-enforcement/{id}"


def parse_standing_rules(text: str) -> list[dict[str, str]]:
    """Every `## ` heading is a standing rule. `###` children are not."""
    rules = []
    for match in HEADING_RE.finditer(text):
        heading = match.group(1).strip()
        if not heading:
            continue
        rules.append(
            {
                "kind": "standing",
                "key": heading,
                "source": STANDING_PREFIX + heading,
            }
        )
    return rules


def parse_ledger(text: str) -> list[dict[str, str]]:
    """Dated decision lines. Skip FLAG / not-a-decision rows."""
    rules = []
    seen: set[str] = set()
    for match in LEDGER_RE.finditer(text):
        date, title, body = (
            match.group(1),
            match.group(2).strip(),
            match.group(3).strip(),
        )
        if FLAG_BODY_RE.match(body):
            continue
        key = f"{date} | {title}"
        if key in seen:
            continue
        seen.add(key)
        rules.append(
            {
                "kind": "ledger",
                "key": key,
                "source": LEDGER_PREFIX + key,
            }
        )
    return rules


def parse_status(status: str) -> dict[str, Any]:
    status = (status or "").strip()
    if STATUS_ENFORCED.match(status):
        return {"kind": "enforced"}
    queued = STATUS_QUEUED.match(status)
    if queued:
        return {"kind": "queued", "issue": int(queued.group(1))}
    advisory = STATUS_ADVISORY.match(status)
    if advisory:
        reason = advisory.group(1).strip()
        return {"kind": "advisory", "reason": reason}
    return {"kind": "invalid", "raw": status}


def load_matrix(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("matrix root must be an object")
    rules = data.get("rules")
    if not isinstance(rules, list) or not rules:
        raise ValueError("matrix.rules must be a non-empty array")
    return data


def validate_matrix(data: dict[str, Any]) -> list[str]:
    """Return a list of error strings (empty = valid)."""
    errors: list[str] = []
    stale_days = data.get("queued_stale_days")
    if not isinstance(stale_days, int) or stale_days < 1:
        errors.append("queued_stale_days must be a positive integer")
    cap = data.get("auto_file_cap_per_tick")
    if not isinstance(cap, int) or cap < 1:
        errors.append("auto_file_cap_per_tick must be a positive integer")
    ids: set[str] = set()
    sources: set[str] = set()
    for i, rule in enumerate(data.get("rules") or []):
        loc = f"rules[{i}]"
        if not isinstance(rule, dict):
            errors.append(f"{loc}: must be an object")
            continue
        rid = rule.get("id")
        if not isinstance(rid, str) or not rid.strip():
            errors.append(f"{loc}: missing id")
        elif rid in ids:
            errors.append(f"{loc}: duplicate id {rid!r}")
        else:
            ids.add(rid)
        source = rule.get("source")
        if not isinstance(source, str) or not (
            source.startswith(STANDING_PREFIX) or source.startswith(LEDGER_PREFIX)
        ):
            errors.append(
                f"{loc}: source must start with {STANDING_PREFIX!r} or {LEDGER_PREFIX!r}"
            )
        elif source in sources:
            errors.append(f"{loc}: duplicate source {source!r}")
        else:
            sources.add(source)
        for field in ("mechanism", "proof"):
            val = rule.get(field)
            if not isinstance(val, str) or not val.strip():
                errors.append(f"{loc}: missing {field}")
        parsed = parse_status(str(rule.get("status", "")))
        if parsed["kind"] == "invalid":
            errors.append(
                f"{loc}: status must be enforced | queued(#N) | advisory(reason), "
                f"got {rule.get('status')!r}"
            )
        elif parsed["kind"] == "advisory" and not parsed["reason"]:
            errors.append(f"{loc}: advisory status needs a senior-judged reason")
        elif parsed["kind"] == "queued":
            since = rule.get("queued_since")
            if not isinstance(since, str) or not re.match(r"^\d{4}-\d{2}-\d{2}$", since):
                errors.append(f"{loc}: queued rows need queued_since YYYY-MM-DD")
        elif parsed["kind"] == "enforced":
            # Enforced rows must name a real mechanism and proof (already
            # required above). Nothing else.
            pass
    return errors


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


def _days_old(since: str, now: datetime) -> int:
    start = datetime.strptime(since, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return (now.date() - start.date()).days


def join(
    standing_text: str,
    ledger_text: str,
    matrix: dict[str, Any],
    now: str | None = None,
    stale_days: int | None = None,
) -> dict[str, Any]:
    """Join vault rules against the matrix. Return a JSON-ready report."""
    now_dt = _parse_now(now)
    if stale_days is None:
        stale_days = int(matrix.get("queued_stale_days") or 7)

    vault = parse_standing_rules(standing_text) + parse_ledger(ledger_text)
    by_source = {row["source"]: row for row in vault}

    matrix_by_source: dict[str, dict[str, Any]] = {}
    for rule in matrix.get("rules") or []:
        src = rule.get("source")
        if isinstance(src, str):
            matrix_by_source[src] = rule

    uncovered: list[dict[str, Any]] = []
    queued: list[dict[str, Any]] = []
    stale_queued: list[dict[str, Any]] = []
    malformed: list[dict[str, Any]] = []
    covered_rows: list[dict[str, Any]] = []
    covered = 0
    advisory = 0
    queued_ok = 0

    for row in vault:
        src = row["source"]
        entry = matrix_by_source.get(src)
        if entry is None:
            uncovered.append(
                {
                    "id": _fallback_id(row),
                    "source": src,
                    "kind": row["kind"],
                    "reason": "no matrix entry",
                }
            )
            continue
        parsed = parse_status(str(entry.get("status", "")))
        if parsed["kind"] == "invalid":
            malformed.append(
                {
                    "id": entry.get("id") or _fallback_id(row),
                    "source": src,
                    "reason": f"invalid status {entry.get('status')!r}",
                }
            )
            continue
        if parsed["kind"] == "advisory":
            if not parsed["reason"]:
                malformed.append(
                    {
                        "id": entry.get("id"),
                        "source": src,
                        "reason": "advisory without a senior-judged reason",
                    }
                )
            else:
                advisory += 1
                covered += 1
            continue
        if parsed["kind"] == "queued":
            since = entry.get("queued_since")
            if not isinstance(since, str):
                malformed.append(
                    {
                        "id": entry.get("id"),
                        "source": src,
                        "reason": "queued without queued_since",
                    }
                )
                continue
            age = _days_old(since, now_dt)
            payload = {
                "id": entry.get("id"),
                "source": src,
                "issue": parsed["issue"],
                "queued_since": since,
                "age_days": age,
                "stale_days": stale_days,
                "mechanism": entry.get("mechanism"),
                "proof": entry.get("proof"),
            }
            queued.append(payload)
            if age > stale_days:
                stale_queued.append(payload)
            else:
                queued_ok += 1
                covered += 1
            continue
        # enforced
        mech = str(entry.get("mechanism") or "").strip()
        proof = str(entry.get("proof") or "").strip()
        if not mech or not proof:
            malformed.append(
                {
                    "id": entry.get("id"),
                    "source": src,
                    "reason": "enforced row missing mechanism or proof",
                }
            )
        else:
            covered += 1
            covered_rows.append(
                {
                    "id": entry.get("id"),
                    "source": src,
                    "status": "enforced",
                    "fallback_id": _fallback_id(row),
                }
            )

    extra = []
    for src, entry in matrix_by_source.items():
        if src not in by_source:
            extra.append(
                {
                    "id": entry.get("id"),
                    "source": src,
                    "reason": "matrix entry has no matching vault rule",
                }
            )

    violations = len(uncovered) + len(stale_queued) + len(malformed)
    return {
        "vault_rule_count": len(vault),
        "matrix_rule_count": len(matrix.get("rules") or []),
        "covered": covered,
        "advisory": advisory,
        "queued_ok": queued_ok,
        "violations": violations,
        "uncovered": uncovered,
        "queued": queued,
        "stale_queued": stale_queued,
        "malformed": malformed,
        "extra_matrix": extra,
        "covered_rows": covered_rows,
        "auto_file_cap_per_tick": int(matrix.get("auto_file_cap_per_tick") or 5),
    }


def _fallback_id(row: dict[str, str]) -> str:
    key = row["key"].lower()
    slug = re.sub(r"[^a-z0-9]+", "-", key).strip("-")[:60]
    prefix = "sr" if row["kind"] == "standing" else "led"
    return f"{prefix}-{slug}"


def fallback_id_from_source(source: str) -> str:
    """Reconstruct the auto-file id the canary used before a matrix row existed."""
    source = (source or "").strip()
    if source.startswith(STANDING_PREFIX):
        kind, key = "standing", source[len(STANDING_PREFIX) :]
    elif source.startswith(LEDGER_PREFIX):
        kind, key = "ledger", source[len(LEDGER_PREFIX) :]
    else:
        kind, key = "ledger", source
    return _fallback_id({"kind": kind, "key": key})


def issue_matches_covered(body: str, row: dict[str, Any]) -> bool:
    """True when an auto-filed mechanism issue refers to this enforced row.

    Auto-file uses `_fallback_id` (from the vault key). Later matrix rows may
    pick a shorter id, so match matrix id OR fallback id. Do not match on the
    source string alone — other tickets quote that source in passing.
    """
    body = body or ""
    rid = str(row.get("id") or "").strip()
    src = str(row.get("source") or "").strip()
    fallback = str(row.get("fallback_id") or "").strip() or (
        fallback_id_from_source(src) if src else ""
    )
    for signal_id in (rid, fallback):
        if signal_id and (SIGNAL_FMT.format(id=signal_id) in body):
            return True
    return False


def observe_comment(row: dict[str, Any]) -> str:
    src = str(row.get("source") or "")
    rid = str(row.get("id") or "unknown")
    marker = f"canary-covered: {src}"
    return (
        f"{marker}\n\n"
        "status: enforced\n"
        f"matrix-id: `{rid}`\n"
        f"{SIGNAL_FMT.format(id=rid)}\n\n"
        "This source is covered on a real heartbeat tick "
        "(fleet-ops#383 observe-to-close).\n"
    )


def observe_targets(
    report: dict[str, Any], issues: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    """Open issues that an enforced covered row should comment on.

    Skips issues that already carry the `canary-covered:` marker in body or
    comments. Caps at auto_file_cap_per_tick.
    """
    cap = int(report.get("auto_file_cap_per_tick") or 5)
    rows = [
        r
        for r in (report.get("covered_rows") or [])
        if isinstance(r, dict) and r.get("status") == "enforced"
    ]
    out: list[dict[str, Any]] = []
    for issue in issues:
        if not isinstance(issue, dict):
            continue
        number = issue.get("number")
        if not isinstance(number, int):
            continue
        body = str(issue.get("body") or "")
        comment_bits = []
        for comment in issue.get("comments") or []:
            if isinstance(comment, dict):
                comment_bits.append(str(comment.get("body") or ""))
            else:
                comment_bits.append(str(comment))
        blob = body + "\n" + "\n".join(comment_bits)
        for row in rows:
            src = str(row.get("source") or "")
            if not src or not issue_matches_covered(body, row):
                continue
            marker = f"canary-covered: {src}"
            if marker in blob:
                break
            out.append(
                {
                    "number": number,
                    "id": row.get("id"),
                    "source": src,
                    "marker": marker,
                    "body": observe_comment(row),
                }
            )
            break
        if len(out) >= cap:
            break
    return out


def close_targets(
    report: dict[str, Any], issues: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    """Open mechanism issues that are ready to close (observe-to-close).

    An issue is closeable when BOTH hold:
      1. it matches an enforced covered row (issue_matches_covered), AND
      2. it already carries the `canary-covered: <source>` marker in body or
         comments — the persisted green report from a prior heartbeat tick.

    The marker-from-a-prior-tick requirement is what makes the close
    evidence-backed rather than manual (#362): the canary reported green on a
    real tick, and a later observing tick closes. Same-tick comment-then-close
    is avoided so the green report is durable before the close fires.

    Issues whose rule is not `enforced` are never closed here — a queued or
    uncovered row has no green report to close on. Caps at
    auto_file_cap_per_tick.
    """
    cap = int(report.get("auto_file_cap_per_tick") or 5)
    rows = [
        r
        for r in (report.get("covered_rows") or [])
        if isinstance(r, dict) and r.get("status") == "enforced"
    ]
    out: list[dict[str, Any]] = []
    for issue in issues:
        if not isinstance(issue, dict):
            continue
        number = issue.get("number")
        if not isinstance(number, int):
            continue
        body = str(issue.get("body") or "")
        comment_bits = []
        for comment in issue.get("comments") or []:
            if isinstance(comment, dict):
                comment_bits.append(str(comment.get("body") or ""))
            else:
                comment_bits.append(str(comment))
        blob = body + "\n" + "\n".join(comment_bits)
        for row in rows:
            src = str(row.get("source") or "")
            if not src or not issue_matches_covered(body, row):
                continue
            marker = f"canary-covered: {src}"
            if marker not in blob:
                break
            out.append(
                {
                    "number": number,
                    "id": row.get("id"),
                    "source": src,
                    "marker": marker,
                }
            )
            break
        if len(out) >= cap:
            break
    return out


def issue_title(item: dict[str, Any]) -> str:
    src = str(item.get("source") or item.get("id") or "unknown")
    short = src
    for prefix in (STANDING_PREFIX, LEDGER_PREFIX):
        if short.startswith(prefix):
            short = short[len(prefix) :]
            break
    if len(short) > 80:
        short = short[:77] + "..."
    rid = item.get("id") or "unknown"
    return f"feat(enforcement): mechanism for {rid} — {short}"


def issue_body(item: dict[str, Any]) -> str:
    rid = item.get("id") or "unknown"
    src = item.get("source") or ""
    signal = SIGNAL_FMT.format(id=rid)
    if "queued_since" in item or "age_days" in item:
        since = item.get("queued_since") or "unknown"
        age = item.get("age_days")
        stale = item.get("stale_days") or "?"
        age_text = f"{age}" if age is not None else "?"
        mech = item.get("mechanism") or "not specified"
        proof = item.get("proof") or "not specified"
        return (
            "The rule-coverage canary (fleet-ops#383) found a queued rule "
            "with no live enforcer.\n\n"
            f"- rule id: `{rid}`\n"
            f"- source: `{src}`\n"
            f"- queued since: `{since}` (age: {age_text} days, stale after: {stale})\n"
            f"- current mechanism: {mech}\n"
            f"- current proof: {proof}\n"
            "- required: a named gate / canary step / semgrep rule / systemd "
            "unit / CI check / drill, plus a proof pointer, recorded in "
            "`config/rule-enforcement.json` as `enforced`.\n\n"
            "Do not close this until the canary reports this source as covered "
            "on a real heartbeat tick (observe-to-close).\n\n"
            f"{signal}\n"
        )
    reason = item.get("reason") or "no matrix entry"
    return (
        "The rule-coverage canary (fleet-ops#383) found a standing rule "
        "with no live enforcer.\n\n"
        f"- rule id: `{rid}`\n"
        f"- source: `{src}`\n"
        f"- reason: {reason}\n"
        "- required: a named gate / canary step / semgrep rule / systemd "
        "unit / CI check / drill, plus a proof pointer, recorded in "
        "`config/rule-enforcement.json` as `enforced`.\n\n"
        "Do not close this until the canary reports this source as covered "
        "on a real heartbeat tick (observe-to-close).\n\n"
        f"{signal}\n"
    )


def cmd_join(args: argparse.Namespace) -> int:
    with open(args.rules, encoding="utf-8") as fh:
        standing = fh.read()
    with open(args.ledger, encoding="utf-8") as fh:
        ledger = fh.read()
    matrix = load_matrix(args.matrix)
    errors = validate_matrix(matrix)
    if errors:
        report = {
            "violations": len(errors),
            "malformed": [{"reason": e} for e in errors],
            "uncovered": [],
            "queued": [],
            "stale_queued": [],
            "extra_matrix": [],
            "covered": 0,
            "vault_rule_count": 0,
            "matrix_rule_count": len(matrix.get("rules") or []),
            "auto_file_cap_per_tick": int(matrix.get("auto_file_cap_per_tick") or 5),
        }
        json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return 1
    report = join(
        standing,
        ledger,
        matrix,
        now=args.now,
        stale_days=args.stale_days,
    )
    json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 1 if report["violations"] else 0


def cmd_validate(args: argparse.Namespace) -> int:
    matrix = load_matrix(args.matrix)
    errors = validate_matrix(matrix)
    if errors:
        for err in errors:
            print(err, file=sys.stderr)
        return 1
    print(f"OK: matrix valid ({len(matrix['rules'])} rules)")
    return 0


def cmd_issue_title(args: argparse.Namespace) -> int:
    item = json.loads(args.json)
    sys.stdout.write(issue_title(item) + "\n")
    return 0


def cmd_issue_body(args: argparse.Namespace) -> int:
    item = json.loads(args.json)
    body = issue_body(item)
    sys.stdout.write(body)
    if not body.endswith("\n"):
        sys.stdout.write("\n")
    return 0


def cmd_observe_targets(args: argparse.Namespace) -> int:
    with open(args.report, encoding="utf-8") as fh:
        report = json.load(fh)
    with open(args.issues, encoding="utf-8") as fh:
        issues = json.load(fh)
    if not isinstance(issues, list):
        print("issues JSON must be an array", file=sys.stderr)
        return 1
    targets = observe_targets(report, issues)
    json.dump(targets, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def cmd_close_targets(args: argparse.Namespace) -> int:
    with open(args.report, encoding="utf-8") as fh:
        report = json.load(fh)
    with open(args.issues, encoding="utf-8") as fh:
        issues = json.load(fh)
    if not isinstance(issues, list):
        print("issues JSON must be an array", file=sys.stderr)
        return 1
    targets = close_targets(report, issues)
    json.dump(targets, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    join_p = sub.add_parser("join", help="join vault rules against the matrix")
    join_p.add_argument("--rules", required=True)
    join_p.add_argument("--ledger", required=True)
    join_p.add_argument("--matrix", required=True)
    join_p.add_argument("--now", default=None)
    join_p.add_argument("--stale-days", type=int, default=None)
    join_p.set_defaults(func=cmd_join)

    val_p = sub.add_parser("validate-matrix", help="shape-check the matrix JSON")
    val_p.add_argument("--matrix", required=True)
    val_p.set_defaults(func=cmd_validate)

    title_p = sub.add_parser("issue-title", help="render an auto-file issue title")
    title_p.add_argument("--json", required=True)
    title_p.set_defaults(func=cmd_issue_title)

    body_p = sub.add_parser("issue-body", help="render an auto-file issue body")
    body_p.add_argument("--json", required=True)
    body_p.set_defaults(func=cmd_issue_body)

    obs_p = sub.add_parser(
        "observe-targets",
        help="open mechanism issues to comment when a source is enforced",
    )
    obs_p.add_argument("--report", required=True)
    obs_p.add_argument("--issues", required=True)
    obs_p.set_defaults(func=cmd_observe_targets)

    close_p = sub.add_parser(
        "close-targets",
        help="open mechanism issues ready to close (canary-covered + enforced)",
    )
    close_p.add_argument("--report", required=True)
    close_p.add_argument("--issues", required=True)
    close_p.set_defaults(func=cmd_close_targets)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
