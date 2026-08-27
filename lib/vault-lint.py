#!/usr/bin/env python3
"""Vault snapshot lint (fleet-ops#1264 / #1145 slice 3).

Flags vault prose that asserts live state (unit status, seat caps, red/green
on main, PR merged/open, lane counts) unless the note also carries a
`check-command` and a fresh `observed` timestamp in frontmatter.

Live facts belong in a check you can run, not in a note that will rot.

Usage:
  vault-lint --check [PATH ...]
  vault-lint --report [PATH ...]
  vault-lint --pre-write FILE

Exit codes:
  0 — no violations (or --report, which never fails the caller)
  1 — --check found violations
  2 — --pre-write refused the note, or usage / missing path

--pre-write is the capture-wrapper refuse path (complements fleet-ops#1265):
print the violation report and exit 2 so the author can fix the note before
it is committed. siterep-vault-capture should call this before any write.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_VAULT = os.environ.get(
    "FLEET_VAULT", "/home/nish/workspaces/tooling/nish-vault"
)

# Class TTL defaults match fleet-ops#1263 (slice 2). Kept here so this slice
# does not wait on ttl-policy.md landing.
CLASS_TTL_SECONDS: dict[str, int] = {
    "drill-status": 5 * 60,
    "seat-caps": 60 * 60,
    "seat-health": 60,
    "decision-ledger": 7 * 86400,
    "evidence": 30 * 86400,
    "procedure": 90 * 86400,
}

CLASS_TTL_LABEL: dict[str, str] = {
    "drill-status": "5m",
    "seat-caps": "1h",
    "seat-health": "1m",
    "decision-ledger": "7d",
    "evidence": "30d",
    "procedure": "90d",
}

SKIP_DIR_NAMES = {
    ".git",
    ".stversions",
    "conflict-quarantine",
    "node_modules",
}

FRONTMATTER_RE = re.compile(r"\A---\r?\n(.*?\r?\n)---(?:\r?\n|$)", re.DOTALL)
INLINE_RE = re.compile(r"`[^`]*`")
DURATION_RE = re.compile(r"^(\d+)\s*([smhd])$", re.IGNORECASE)
DURATION_MULT = {"s": 1, "m": 60, "h": 3600, "d": 86400}

# Each tuple is (kind, pattern). Patterns run on prose lines (fences and
# inline code already stripped) so procedure examples in fences stay quiet.
LIVE_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (
        "unit-status",
        re.compile(
            r"(?i)\b[\w@.-]+\.service\s+Active:\s+"
            r"(?:active|inactive|failed)(?:\s+\((?:running|dead)\))?"
        ),
    ),
    (
        "seat-cap",
        re.compile(r"(?i)\bseats?\s+cap\s+(?:is|=)\s+\d+\b"),
    ),
    ("red-on-main", re.compile(r"(?i)\bred on main\b")),
    ("green-on-main", re.compile(r"(?i)\bgreen on main\b")),
    ("pr-merged", re.compile(r"(?i)\bPR\s+#?\d+\s+MERGED\b")),
    ("pr-open", re.compile(r"(?i)\bPR\s+#?\d+\s+OPEN\b")),
    ("merged-prs-24h", re.compile(r"(?i)\bmerged\s+\d+\s+PRs?/24h\b")),
    ("lanes-active", re.compile(r"(?i)\b\d+\s+lanes?\s+active\b")),
]


@dataclass(frozen=True)
class Match:
    line: int
    kind: str
    excerpt: str


@dataclass(frozen=True)
class Violation:
    path: str
    line: int
    kind: str
    excerpt: str
    reason: str


def parse_now(value: str | None) -> datetime:
    raw = (value or os.environ.get("VAULT_LINT_NOW") or "").strip()
    if not raw:
        return datetime.now(timezone.utc)
    dt = parse_iso(raw)
    if dt is None:
        raise ValueError(f"invalid --now timestamp: {raw}")
    return dt


def parse_iso(text: str) -> datetime | None:
    raw = text.strip().strip("'\"")
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


def parse_duration(text: str) -> int | None:
    raw = text.strip().strip("'\"")
    m = DURATION_RE.match(raw)
    if not m:
        return None
    return int(m.group(1)) * DURATION_MULT[m.group(2).lower()]


def parse_frontmatter(text: str) -> tuple[dict[str, str], str, int]:
    """Return (fields, body, body_start_lineno). Linenos are 1-based."""
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}, text, 1
    fields: dict[str, str] = {}
    for line in m.group(1).splitlines():
        if ":" not in line:
            continue
        key, _, rest = line.partition(":")
        key = key.strip().lower()
        if not key:
            continue
        value = rest.strip().strip("'\"")
        fields[key] = value
    body = text[m.end() :]
    body_start = text[: m.end()].count("\n") + 1
    return fields, body, body_start


def iter_prose_lines(body: str, start_line: int):
    in_fence = False
    for lineno, line in enumerate(body.splitlines(), start=start_line):
        stripped = line.lstrip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        yield lineno, INLINE_RE.sub(" ", line)


def find_live_state(body: str, start_line: int) -> list[Match]:
    found: list[Match] = []
    for lineno, prose in iter_prose_lines(body, start_line):
        for kind, pattern in LIVE_PATTERNS:
            m = pattern.search(prose)
            if m:
                found.append(Match(line=lineno, kind=kind, excerpt=m.group(0)))
    return found


def ttl_for(fields: dict[str, str]) -> tuple[int | None, str, str | None]:
    """Return (seconds, label, error). error is set when TTL cannot be applied."""
    explicit = fields.get("ttl", "").strip()
    if explicit:
        seconds = parse_duration(explicit)
        if seconds is None:
            return None, explicit, f"unparseable ttl {explicit!r} (want Ns/Nm/Nh/Nd)"
        return seconds, explicit, None
    klass = fields.get("class", "").strip().lower()
    if not klass:
        return None, "", "missing class (needed to apply TTL)"
    if klass not in CLASS_TTL_SECONDS:
        return None, klass, f"unknown class {klass!r}"
    return CLASS_TTL_SECONDS[klass], CLASS_TTL_LABEL[klass], None


def lint_text(path: str, text: str, now: datetime) -> list[Violation]:
    fields, body, body_start = parse_frontmatter(text)
    matches = find_live_state(body, body_start)
    if not matches:
        return []

    violations: list[Violation] = []
    check_command = fields.get("check-command", "").strip()
    observed_raw = fields.get("observed", "").strip()

    ttl_seconds, ttl_label, ttl_error = ttl_for(fields)
    observed = parse_iso(observed_raw) if observed_raw else None

    for match in matches:
        if not check_command:
            violations.append(
                Violation(
                    path=path,
                    line=match.line,
                    kind=match.kind,
                    excerpt=match.excerpt,
                    reason="missing check-command in frontmatter",
                )
            )
        if not observed_raw:
            violations.append(
                Violation(
                    path=path,
                    line=match.line,
                    kind=match.kind,
                    excerpt=match.excerpt,
                    reason="missing observed in frontmatter",
                )
            )
        elif observed is None:
            violations.append(
                Violation(
                    path=path,
                    line=match.line,
                    kind=match.kind,
                    excerpt=match.excerpt,
                    reason=f"unparseable observed {observed_raw!r} (want ISO8601)",
                )
            )
        elif ttl_error:
            violations.append(
                Violation(
                    path=path,
                    line=match.line,
                    kind=match.kind,
                    excerpt=match.excerpt,
                    reason=ttl_error,
                )
            )
        elif ttl_seconds is not None and (now - observed).total_seconds() > ttl_seconds:
            age = int((now - observed).total_seconds())
            violations.append(
                Violation(
                    path=path,
                    line=match.line,
                    kind=match.kind,
                    excerpt=match.excerpt,
                    reason=(
                        f"observed {observed.strftime('%Y-%m-%dT%H:%M:%SZ')} "
                        f"is older than class TTL {ttl_label} ({age}s ago)"
                    ),
                )
            )
    return violations


def collect_md_files(paths: list[Path]) -> list[Path]:
    files: list[Path] = []
    for path in paths:
        if str(path) == "-":
            files.append(path)
            continue
        if not path.exists():
            raise FileNotFoundError(str(path))
        if path.is_file():
            files.append(path)
            continue
        for md in sorted(path.rglob("*.md")):
            if any(part in SKIP_DIR_NAMES for part in md.parts):
                continue
            if md.is_file():
                files.append(md)
    return files


def read_note(path: Path) -> tuple[str, str]:
    if str(path) == "-":
        return "<stdin>", sys.stdin.read()
    return str(path), path.read_text(encoding="utf-8")


def lint_paths(paths: list[Path], now: datetime) -> tuple[list[Violation], int]:
    files = collect_md_files(paths)
    violations: list[Violation] = []
    for path in files:
        display, text = read_note(path)
        violations.extend(lint_text(display, text, now))
    return violations, len(files)


def format_report(violations: list[Violation], scanned: int) -> str:
    lines = [
        "# Vault snapshot lint",
        "",
        f"Scanned {scanned} note(s). {len(violations)} violation(s).",
        "",
    ]
    if not violations:
        lines.append("No vault snapshot-lint violations.")
        lines.append("")
        return "\n".join(lines)

    current = None
    for item in violations:
        if item.path != current:
            current = item.path
            lines.append(f"## `{item.path}`")
            lines.append("")
        excerpt = item.excerpt.replace("\n", " ").strip()
        lines.append(
            f"- line {item.line} (`{item.kind}`): `{excerpt}` — {item.reason}"
        )
    lines.append("")
    return "\n".join(lines)


def default_paths() -> list[Path]:
    vault = Path(DEFAULT_VAULT)
    if vault.is_dir():
        return [vault]
    return []


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="exit 1 on any violation (worker pre-write check; default)",
    )
    mode.add_argument(
        "--report",
        action="store_true",
        help="print Markdown violations; always exit 0 (heartbeat drift surface)",
    )
    mode.add_argument(
        "--pre-write",
        action="store_true",
        help="refuse a single note: print the report and exit 2 on violations",
    )
    parser.add_argument(
        "--now",
        help="ISO8601 clock for TTL checks (tests; default: now / VAULT_LINT_NOW)",
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="note file(s) or directories to scan (default: $FLEET_VAULT)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        now = parse_now(args.now)
    except ValueError as exc:
        print(f"vault-lint: {exc}", file=sys.stderr)
        return 2

    paths = [Path(p) for p in args.paths] or default_paths()
    if not paths:
        print("vault-lint: no path given and default vault is missing", file=sys.stderr)
        return 2

    if args.pre_write:
        if len(paths) != 1:
            print("vault-lint: --pre-write requires exactly one file", file=sys.stderr)
            return 2
        if str(paths[0]) != "-" and paths[0].is_dir():
            print("vault-lint: --pre-write requires a file, not a directory", file=sys.stderr)
            return 2

    try:
        violations, scanned = lint_paths(paths, now)
    except FileNotFoundError as exc:
        print(f"vault-lint: path not found: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"vault-lint: {exc}", file=sys.stderr)
        return 2

    report = format_report(violations, scanned)
    sys.stdout.write(report)

    if args.report:
        return 0
    if args.pre_write:
        return 2 if violations else 0
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
