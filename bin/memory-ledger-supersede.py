#!/usr/bin/env python3
"""memory-ledger-supersede — curator pass: flag memories a new ledger line contradicts.

fleet-ops#389. The deterministic memory curator (memoryctl curate/review) already
runs on nish-memory-curator.timer. This pass extends that unit via a drop-in
ExecStart: when a decisions-ledger line lands, sweep compiled memories and
agent memory indexes for entries whose scope/claims conflict, and mark them

    SUPERSEDED-BY:<ledger date+title>

rather than deleting or rewriting the claim. Agents treat the marker as
"ledger wins, re-verify".

Matching is mechanical, not prose: a ledger title that narrows enrolled
scope (exclusive/solely) versus a memory that still claims a wide set
("all 7 products in scope", "enrolled on 11 repos"). The curator never
rewrites the claim.

Environment seams (overridden by tests):
  MEMORY_VAULT            vault root (default: ~/workspaces/tooling/nish-vault)
  MEMORY_LEDGER           decisions-ledger.md
  MEMORY_COMPILED_ROOT    compiled shared-memory tree
  MEMORY_AGENT_ROOTS      os.pathsep-separated agent memory indexes
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


HOME = Path(os.environ.get("HOME", "/home/nish"))
DEFAULT_VAULT = HOME / "workspaces" / "tooling" / "nish-vault"

# Set-narrowing only. "never"/"banned"/"supersedes" appear in too many
# ledger lines that are not about enrolled-product scope (live dry-run
# on 2026-08-26 marked 246/476 files when those words counted).
NARROWING_RE = re.compile(r"\b(exclusive|solely)\b", re.I)
WIDENING_RE = re.compile(
    r"\b(?:"
    r"all\s+\d+\s+(?:products?|repos?)"
    r"|enrolled\s+(?:on|from)\s+\d+"
    r"|\d+\s+products?\s+in\s+scope"
    r"|all\s+(?:products?|repos?)\s+in\s+scope"
    r")\b",
    re.I,
)
SCOPE_DOMAIN_RE = re.compile(
    r"\b(?:products?|repos?|enrol(?:ment|led)?|intake|scouts?|supply|scope|campaign)\b",
    re.I,
)
LEDGER_LINE_RE = re.compile(
    r"^- (\d{4}-\d{2}-\d{2}) \| ([^|]+?) \| (.+) \| ([^|]+)\s*$"
)


@dataclass(frozen=True)
class LedgerLine:
    date: str
    title: str
    body: str
    pointer: str

    @property
    def marker(self) -> str:
        return f"SUPERSEDED-BY:{self.date} {self.title}"

    @property
    def text(self) -> str:
        return f"{self.title} {self.body} {self.pointer}"


def conflicts(line: LedgerLine, memory_text: str) -> bool:
    """True when the memory's scope/claims conflict with this ledger line."""
    mem_l = memory_text.lower()
    led_l = line.text.lower()

    # Conflict = a ledger line that narrows enrolled/product scope
    # (exclusive/only/solely) vs a memory that still claims a wide set
    # ("all 7 products in scope", "enrolled on 11 repos"). Same-keyword
    # overlap without that shape is not a conflict.
    # Title must itself narrow enrolled/product scope. Body text often
    # quotes an older "only"/"solely" line (enrolment quotes "maintenance
    # only"; loop-for-all-repos says "systemd only") and must not inherit
    # that as a conflict.
    ledger_narrows_scope = bool(NARROWING_RE.search(line.title)) and bool(
        SCOPE_DOMAIN_RE.search(led_l)
    )
    memory_widens_scope = bool(WIDENING_RE.search(memory_text))
    both_in_scope_domain = bool(SCOPE_DOMAIN_RE.search(led_l)) and bool(
        SCOPE_DOMAIN_RE.search(mem_l)
    )
    if ledger_narrows_scope and memory_widens_scope and both_in_scope_domain:
        return True
    return False


def parse_ledger(text: str) -> list[LedgerLine]:
    """Decision lines only. Open-questions / FLAG sections are skipped."""
    lines: list[LedgerLine] = []
    in_ledger = False
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped.startswith("## ") and "ledger" in stripped.lower():
            in_ledger = True
            continue
        if not in_ledger:
            continue
        if stripped.startswith("### Open questions"):
            break
        match = LEDGER_LINE_RE.match(stripped)
        if not match:
            continue
        date, title, body, pointer = (g.strip() for g in match.groups())
        lines.append(LedgerLine(date=date, title=title, body=body, pointer=pointer))
    return lines


def has_sync_conflict(roots: list[Path]) -> Path | None:
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*.sync-conflict-*"):
            return path
    return None


def iter_md(root: Path):
    if not root.is_dir():
        return
    for path in sorted(root.rglob("*.md")):
        if "_history" in path.parts:
            continue
        name = path.name
        if ".bak" in name or "autocompact-bak" in name:
            continue
        if "sync-conflict" in name:
            continue
        yield path


def insert_file_marker(text: str, marker: str) -> str:
    """Add the marker line. Never rewrites existing claim prose."""
    if marker in text:
        return text
    marker_line = marker + "\n"
    if text.startswith("---"):
        parts = text.split("---", 2)
        if len(parts) >= 3:
            body = parts[2]
            if body.startswith("\n"):
                body = body[1:]
            return f"---{parts[1]}---\n{marker_line}{body}"
    if text and not text.endswith("\n"):
        return marker_line + text + "\n"
    return marker_line + text


def mark_index_bullets(text: str, line: LedgerLine) -> str:
    """Append the marker to conflicting MEMORY.md bullets; leave other lines."""
    marker = line.marker
    out: list[str] = []
    for raw in text.splitlines(keepends=True):
        core = raw.rstrip("\n")
        is_bullet = core.lstrip().startswith("- ")
        if is_bullet and marker not in core and conflicts(line, core):
            nl = "\n" if raw.endswith("\n") else ""
            out.append(f"{core} {marker}{nl}")
        else:
            out.append(raw)
    return "".join(out)


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def apply_file(
    path: Path,
    ledger: list[LedgerLine],
    dry_run: bool,
) -> list[str]:
    original = path.read_text(encoding="utf-8")
    text = original
    applied: list[str] = []
    is_index = path.name == "MEMORY.md"

    for line in ledger:
        if is_index:
            updated = mark_index_bullets(text, line)
            if updated != text:
                text = updated
                applied.append(line.marker)
                continue
        if line.marker in text:
            continue
        if not conflicts(line, text):
            continue
        text = insert_file_marker(text, line.marker)
        applied.append(line.marker)

    if applied and text != original and not dry_run:
        atomic_write(path, text)
    return applied


def collect_roots(args: argparse.Namespace) -> tuple[Path, Path, list[Path], list[Path]]:
    vault = Path(os.environ.get("MEMORY_VAULT", args.vault or DEFAULT_VAULT))
    ledger = Path(os.environ.get("MEMORY_LEDGER", args.ledger or (vault / "_system/shared-memory/decisions-ledger.md")))
    compiled = Path(
        os.environ.get(
            "MEMORY_COMPILED_ROOT",
            args.compiled_root or (vault / "03 Knowledge/compiled/shared-memory"),
        )
    )
    if args.agent_memory:
        agent_roots = [Path(p) for p in args.agent_memory]
    elif os.environ.get("MEMORY_AGENT_ROOTS"):
        agent_roots = [Path(p) for p in os.environ["MEMORY_AGENT_ROOTS"].split(os.pathsep) if p]
    else:
        agent_roots = [
            HOME / ".pi" / "agent" / "memory",
            HOME / ".claude" / "projects" / "-home-nish" / "memory",
        ]
    return vault, ledger, compiled, agent_roots


def run(args: argparse.Namespace) -> int:
    vault, ledger_path, compiled, agent_roots = collect_roots(args)
    if not ledger_path.is_file():
        print(f"memory-ledger-supersede: ledger not found: {ledger_path}", file=sys.stderr)
        return 2

    conflict = has_sync_conflict([vault, compiled, *agent_roots])
    status = {
        "checked": 0,
        "marked": 0,
        "already": 0,
        "skipped_unrelated": 0,
        "markers": [],
        "sync_conflict": False,
        "dry_run": bool(args.dry_run),
    }
    if conflict is not None:
        status["sync_conflict"] = True
        status["sync_conflict_path"] = str(conflict)
        print(json.dumps(status, sort_keys=True))
        print(f"memory-ledger-supersede: vault sync-conflict present: {conflict}", file=sys.stderr)
        return 2

    ledger = parse_ledger(ledger_path.read_text(encoding="utf-8"))
    files = list(iter_md(compiled))
    for root in agent_roots:
        files.extend(iter_md(root))

    for path in files:
        status["checked"] += 1
        before = path.read_text(encoding="utf-8")
        already = sum(1 for line in ledger if line.marker in before)
        applied = apply_file(path, ledger, dry_run=args.dry_run)
        if applied:
            status["marked"] += 1
            status["markers"].append({"path": str(path), "markers": applied})
        elif already:
            status["already"] += 1
        else:
            status["skipped_unrelated"] += 1

    print(json.dumps(status, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="memory-ledger-supersede",
        description="Mark compiled/agent memories contradicted by a new decisions-ledger line.",
    )
    parser.add_argument("--dry-run", action="store_true", help="report marks without writing")
    parser.add_argument("--vault", default="", help="vault root")
    parser.add_argument("--ledger", default="", help="path to decisions-ledger.md")
    parser.add_argument("--compiled-root", default="", help="compiled shared-memory directory")
    parser.add_argument(
        "--agent-memory",
        action="append",
        default=[],
        help="agent memory directory (repeatable)",
    )
    args = parser.parse_args(argv)
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
