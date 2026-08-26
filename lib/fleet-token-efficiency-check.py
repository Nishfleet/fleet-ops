#!/usr/bin/env python3
"""Token-efficiency gate for custom prompt assemblers (fleet-ops#523).

Standing rule (Nish, 2026-08-20): "Token efficiency without quality loss".
This is a PR/static gate: it scans the files a PR touches for unambiguous
anti-patterns in prompt assembly:

  1. Hard max_tokens / maxTokens output caps on implementation or reasoning.
  2. Byte or line truncation (head -c, tail -c, head -n <cap>) of model
     context to save tokens.
  3. Volatile content (timestamps, run IDs, random values) emitted before the
     static prompt in a shell assembler.
  4. In-place template substitution (.replace('{{...}}', ...)) instead of
     appending volatile context after the static prompt.
  5. Unsorted file lists (find ... | head, ls ... | head) fed into a prompt.
  6. Prompt markdown templates with {{...}} placeholders before the static
     body (placeholders should be at the end).

Usage:
  fleet-token-efficiency-check --name-status FILE
  git diff --name-status origin/main...HEAD | fleet-token-efficiency-check --name-status -
  fleet-token-efficiency-check --all --root ROOT

Exit 0 when no un-allowlisted anti-patterns are found.
Exit 1 when one or more are found.
Exit 2 on usage or input errors.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterable

# Paths that are part of this gate itself, or test fixtures, and should not
# be linted by the gate (they legitimately contain the literal anti-patterns).
SELF_BASENAME_PATTERNS = (
    "fleet-token-efficiency-check",
    "token-efficiency-allowlist",
)

MAX_TOKENS_RE = re.compile(r"\bmax[_\s]?tokens\b", re.IGNORECASE)

# Byte/line caps on content. We intentionally avoid head -n 1 / tail -n 1 style
# single-item picks; the rule forbids *caps* on model context, not selecting
# one item.
TRUNCATION_RE = re.compile(r"\b(head|tail)\s+-[c]\s+", re.IGNORECASE)
HEAD_N_CAP_RE = re.compile(r"\bhead\s+(?:-n\s+|-)([0-9]+)\b", re.IGNORECASE)

# Volatile tokens that, if printed before the static prompt, break prefix cache.
VOLATILE_IN_OUTPUT_RE = re.compile(
    r"\$\(date|\"\$\{?(?:RUN_TS|NOW_ISO|TS|UUID|RANDOM)" r"|\brandom\b|\buuidgen\b",
    re.IGNORECASE,
)

# In-place placeholder substitution in a template.
INPLACE_SUB_RE = re.compile(r"\.replace\s*\(\s*['\"]\{\{")

# Unsorted file listing that is capped with head.
UNSORTED_FIND_HEAD_RE = re.compile(
    r"\b(find|ls)\b.*\|.*\bhead\b", re.IGNORECASE
)

# Static prompt 'cat' in shell assemblers.
CAT_PROMPT_RE = re.compile(r"\bcat\s+[\"']?\$\{?[^\s\"']*(?:prompt|PROMPT|prompt_file)")


def _looks_like_assembler(path: Path, text: str) -> bool:
    """True if the file looks like a prompt assembler or prompt template."""
    low = text.lower()
    assembler_markers = (
        "packet",
        "prompt",
        "pi --print",
        "pi -- ",
        "tpl.replace",
        ".replace('{{",
        '.replace("{{',
        "cache_control",
        "messages",
        "anthropic",
        "claude-",
    )
    if any(m in low for m in assembler_markers):
        return True
    # Markdown prompt templates live under prompts/.
    if path.suffix == ".md" and "prompts" in path.parts:
        return True
    return False


def _strip_shell_comment(line: str) -> str:
    """Remove a trailing # comment from a shell line (best-effort)."""
    # Simple heuristic: split on unquoted #.
    out = []
    in_sq = False
    in_dq = False
    escaped = False
    for ch in line:
        if escaped:
            out.append(ch)
            escaped = False
            continue
        if ch == "\\":
            out.append(ch)
            escaped = True
            continue
        if ch == "'" and not in_dq:
            in_sq = not in_sq
            out.append(ch)
            continue
        if ch == '"' and not in_sq:
            in_dq = not in_dq
            out.append(ch)
            continue
        if ch == "#" and not in_sq and not in_dq:
            return "".join(out)
        out.append(ch)
    return "".join(out)


def _strip_python_comment(line: str) -> str:
    """Remove a trailing # comment from a Python line (best-effort)."""
    out = []
    in_str = None  # " or '
    escaped = False
    for ch in line:
        if escaped:
            out.append(ch)
            escaped = False
            continue
        if ch == "\\":
            out.append(ch)
            escaped = True
            continue
        if ch in ("'", '"'):
            if in_str is None:
                in_str = ch
            elif in_str == ch:
                in_str = None
            out.append(ch)
            continue
        if ch == "#" and in_str is None:
            return "".join(out)
        out.append(ch)
    return "".join(out)


def _strip_comment(line: str, ext: str) -> str:
    if ext in (".py",):
        return _strip_python_comment(line)
    return _strip_shell_comment(line)


def _non_code_text(text: str, ext: str) -> list[str]:
    """Return the non-comment portions of each line."""
    return [_strip_comment(line, ext) for line in text.splitlines()]


def _md_body_without_code(text: str) -> str:
    """For prompt templates, drop fenced code blocks before scanning."""
    lines = text.splitlines()
    out: list[str] = []
    in_code = False
    fence = ""
    for line in lines:
        stripped = line.lstrip()
        if not in_code and stripped.startswith("```"):
            in_code = True
            fence = stripped[:3]
            continue
        if in_code and stripped.startswith(fence):
            in_code = False
            fence = ""
            continue
        if not in_code:
            out.append(line)
    return "\n".join(out)


def _findings_for_shell(path: Path, text: str) -> list[str]:
    findings: list[str] = []
    lines = text.splitlines()
    non_code = _non_code_text(text, ".sh")

    for idx, (raw, code) in enumerate(zip(lines, non_code), start=1):
        if MAX_TOKENS_RE.search(code):
            findings.append(f"{path}:{idx}: hard max_tokens cap: {raw.strip()!r}")

        # Truncation of model context. Exclude obvious log/journal/error excerpts.
        if TRUNCATION_RE.search(code):
            if not any(
                word in raw.lower()
                for word in ("err", "stderr", "journal", "excerpt", "log")
            ):
                findings.append(
                    f"{path}:{idx}: byte/line truncation of context: {raw.strip()!r}"
                )

        m = HEAD_N_CAP_RE.search(code)
        if m and int(m.group(1)) > 1:
            if not any(
                word in raw.lower()
                for word in ("err", "stderr", "journal", "excerpt", "log")
            ):
                findings.append(
                    f"{path}:{idx}: head -n cap on context: {raw.strip()!r}"
                )

        if INPLACE_SUB_RE.search(code):
            findings.append(
                f"{path}:{idx}: in-place template substitution ({{{{ not last): {raw.strip()!r}"
            )

    # File list ordering: find | head or ls | head without a sort stage.
    for idx, (raw, code) in enumerate(zip(lines, non_code), start=1):
        if UNSORTED_FIND_HEAD_RE.search(code) and "sort" not in code.lower():
            findings.append(
                f"{path}:{idx}: unsorted file list capped with head: {raw.strip()!r}"
            )

    # Volatile content before the static prompt.
    cat_line: int | None = None
    for idx, (raw, code) in enumerate(zip(lines, non_code), start=1):
        if CAT_PROMPT_RE.search(code):
            cat_line = idx
            break
    if cat_line is not None:
        for idx, (raw, code) in enumerate(zip(lines, non_code), start=1):
            if idx >= cat_line:
                break
            if not ("printf" in code or "echo" in code):
                continue
            if VOLATILE_IN_OUTPUT_RE.search(code):
                findings.append(
                    f"{path}:{idx}: volatile content before static prompt: {raw.strip()!r}"
                )

    return findings


def _findings_for_python(path: Path, text: str) -> list[str]:
    findings: list[str] = []
    lines = text.splitlines()
    non_code = _non_code_text(text, ".py")

    for idx, (raw, code) in enumerate(zip(lines, non_code), start=1):
        if MAX_TOKENS_RE.search(code):
            findings.append(f"{path}:{idx}: hard max_tokens cap: {raw.strip()!r}")

        if INPLACE_SUB_RE.search(code):
            findings.append(
                f"{path}:{idx}: in-place template substitution ({{{{ not last): {raw.strip()!r}"
            )

    # Anthropic-style messages without cache_control.
    lowered = text.lower()
    if "anthropic" in lowered or "claude-" in lowered:
        if "messages" in lowered and "cache_control" not in lowered:
            # Try to be precise: a messages list of dicts.
            for idx, raw in enumerate(lines, start=1):
                if re.search(r"messages\s*=\s*\[", raw):
                    findings.append(
                        f"{path}:{idx}: Anthropic-style messages list missing cache_control on the static block"
                    )
                    break

    return findings


def _findings_for_markdown(path: Path, text: str) -> list[str]:
    findings: list[str] = []
    body = _md_body_without_code(text)
    lines = body.splitlines()
    placeholders = [i for i, line in enumerate(lines, start=1) if "{{" in line]
    if not placeholders:
        return findings
    # Placeholders should live in the last ~30% of the static body. If the
    # first placeholder is earlier, the static prefix is not byte-identical.
    first = placeholders[0]
    threshold = max(1, int(len(lines) * 0.7))
    if first <= threshold:
        findings.append(
            f"{path}:{first}: prompt template placeholder before the static body (first {{{{ at line {first} of {len(lines)}); move placeholders to the end"
        )
    return findings


def _is_self(path: Path) -> bool:
    name = path.name
    return any(pat in name for pat in SELF_BASENAME_PATTERNS)


def _is_test_path(path: Path, include_tests: bool) -> bool:
    if include_tests:
        return False
    return "tests" in path.parts or path.name.endswith(".test.sh")


def _file_findings(path: Path, include_tests: bool) -> list[str]:
    if _is_self(path) or _is_test_path(path, include_tests):
        return []
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"fleet-token-efficiency-check: cannot read {path}: {exc}", file=sys.stderr)
        return []

    ext = path.suffix
    if ext in (".json", ".toml", ".yaml", ".yml", ".lock", ".sum"):
        # Config/data files are not prompt assembly.
        return []
    if not _looks_like_assembler(path, text):
        # Non-assemblers are not prompt construction; skip them.
        return []

    if ext == ".md":
        return _findings_for_markdown(path, text)
    if ext == ".py":
        return _findings_for_python(path, text)
    return _findings_for_shell(path, text)


def _read_name_status(stream: Iterable[str]) -> list[Path]:
    paths: list[Path] = []
    for line in stream:
        line = line.rstrip("\n")
        if not line:
            continue
        cols = line.split("\t")
        status = cols[0][0] if cols[0] else ""
        if status in ("A", "M"):
            paths.append(Path(cols[1]))
        elif status == "C" and len(cols) >= 3:
            paths.append(Path(cols[2]))
        elif status == "R" and len(cols) >= 3:
            paths.append(Path(cols[2]))
    return paths


def _collect_all_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        rel = p.relative_to(root)
        parts = rel.parts
        if parts and parts[0] in ("bin", "lib", "prompts"):
            files.append(p)
        elif p.suffix in (".sh", ".py", ".md"):
            files.append(p)
    return files


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--name-status",
        help="git diff --name-status file (or '-' for stdin)",
    )
    parser.add_argument("--all", action="store_true", help="scan all files under --root")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("."),
        help="repo root for resolving relative paths (default: .)",
    )
    parser.add_argument(
        "--include-tests",
        action="store_true",
        help="do not skip tests/ and .test.sh files",
    )
    args = parser.parse_args(argv)

    if not args.name_status and not args.all:
        parser.error("specify --name-status or --all")
    if args.name_status and args.all:
        parser.error("--name-status and --all are mutually exclusive")

    if args.name_status:
        if args.name_status == "-":
            stream = sys.stdin
        else:
            try:
                stream = open(args.name_status, encoding="utf-8")
            except OSError as exc:
                print(f"fleet-token-efficiency-check: {exc}", file=sys.stderr)
                return 2
        try:
            files = _read_name_status(stream)
        finally:
            if args.name_status != "-":
                stream.close()
        # Resolve relative to --root.
        files = [args.root / f for f in files]
    else:
        files = _collect_all_files(args.root)

    findings: list[str] = []
    for f in files:
        findings.extend(_file_findings(f, args.include_tests))

    if findings:
        print("REJECT: token-efficiency anti-pattern(s) found", file=sys.stderr)
        for item in findings:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print("OK: no token-efficiency anti-patterns in changed prompt assemblers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
