#!/usr/bin/env python3
"""Session-close lint for 'debugging sessions end with a playbook note'
(fleet-ops#522).

The standing rule's failure mode is a multi-attempt debug — two or more
real failed toolResults in one Pi session — that never filed a vault
playbook note in the four-heading shape: SIGNATURE, ROOT CAUSE, FIX THAT
WORKED, DEAD ENDS. A single failure is not this rule (fleet-ops#535).
grep/rg/diff exit 1 (POSIX no-match) is not a failed attempt.

The playbook may live in assistant text or in a tool argument (a vault
write / memoryctl capture). Quoted headings in a PR body still count:
the rule wants the note filed, not that it was unquoted.

Usage:
  python3 lib/debug-playbook.py scan --root DIR [--now ISO]
      [--window-hours 24] [--grace-minutes 20]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from typing import Any

EXIT_RE = re.compile(r"Command exited with code (\d+)")
TIMEOUT_RE = re.compile(r"Command timed out", re.I)
BENIGN_STAGE_RE = re.compile(
    r"(?:^|[;&|\n]|&&|\|\|)\s*(?:sudo\s+)?"
    r"(?:grep|egrep|fgrep|rg|ripgrep|diff|git\s+grep|git\s+diff)\b",
    re.I,
)
REAL_ERR_RE = re.compile(
    r"(Not Found|Permission denied|HTTP\s*[45]\d\d|"
    r"error TS\d+|API rate limit)",
    re.I,
)
HARNESS_BLOCK_RE = re.compile(
    r"Dangerous command blocked \(no UI for confirmation\)",
    re.I,
)
HEADING_RES = (
    re.compile(r"\bSIGNATURE\b", re.I),
    re.compile(r"ROOT CAUSE", re.I),
    re.compile(r"FIX THAT WORKED", re.I),
    re.compile(r"DEAD ENDS", re.I),
)
SLUG_RE = re.compile(r"[^a-z0-9]+")


def parse_now(value: str | None) -> float:
    if not value:
        return datetime.now(timezone.utc).timestamp()
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    return datetime.fromisoformat(text).timestamp()


def _text_chunks(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for chunk in content:
        if not isinstance(chunk, dict):
            continue
        if chunk.get("type") == "text":
            parts.append(str(chunk.get("text") or ""))
    return "\n".join(parts)


def _command_from_args(args: Any) -> str:
    if isinstance(args, dict):
        return str(args.get("command") or args.get("cmd") or "")
    if isinstance(args, str):
        try:
            parsed = json.loads(args)
        except json.JSONDecodeError:
            return args
        if isinstance(parsed, dict):
            return str(parsed.get("command") or parsed.get("cmd") or "")
        return args
    return ""


def _blob_from_args(args: Any) -> str:
    if args is None:
        return ""
    if isinstance(args, str):
        return args
    try:
        return json.dumps(args, ensure_ascii=False)
    except (TypeError, ValueError):
        return str(args)


def _exit_code(text: str) -> int | None:
    match = EXIT_RE.search(text)
    if match is None:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def is_benign_no_match(command: str, text: str, code: int | None) -> bool:
    if code != 1:
        return False
    if TIMEOUT_RE.search(text):
        return False
    if REAL_ERR_RE.search(text):
        return False
    return BENIGN_STAGE_RE.search(command) is not None


def result_failed(msg: dict[str, Any], command: str) -> tuple[bool, str]:
    text = _text_chunks(msg.get("content"))
    if HARNESS_BLOCK_RE.search(text):
        return False, text
    is_error = bool(msg.get("isError"))
    timed_out = TIMEOUT_RE.search(text) is not None
    code = _exit_code(text)
    if not is_error and not timed_out and code is None:
        return False, text
    if is_benign_no_match(command, text, code if code is not None else (1 if is_error else None)):
        return False, text
    if is_error or timed_out or (code is not None and code != 0):
        return True, text
    return False, text


def has_playbook_shape(blob: str) -> bool:
    return all(pattern.search(blob) for pattern in HEADING_RES)


def snippet_for(text: str, width: int = 200) -> str:
    chunk = text.replace("\n", " ").strip()
    return chunk[:width]


def session_slug(path: str) -> str:
    stem = os.path.splitext(os.path.basename(path))[0].lower()
    slug = SLUG_RE.sub("-", stem).strip("-")
    return (slug or "session")[:80]


def scan_session(path: str) -> dict[str, str] | None:
    calls: dict[str, str] = {}
    failures: list[str] = []
    blobs: list[str] = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msg = obj.get("message")
                if not isinstance(msg, dict):
                    continue
                role = msg.get("role")
                content = msg.get("content")
                if role == "assistant":
                    blobs.append(_text_chunks(content))
                    if isinstance(content, list):
                        for chunk in content:
                            if not isinstance(chunk, dict):
                                continue
                            if chunk.get("type") != "toolCall":
                                continue
                            cid = str(chunk.get("id") or "")
                            args = chunk.get("arguments")
                            if cid:
                                calls[cid] = _command_from_args(args)
                            blobs.append(_blob_from_args(args))
                elif role == "toolResult":
                    # Reads (standing-rules, prior notes) must not count as
                    # filing. Only assistant text and toolCall arguments do.
                    tid = str(msg.get("toolCallId") or "")
                    command = calls.get(tid, "")
                    failed, fail_text = result_failed(msg, command)
                    if failed:
                        failures.append(snippet_for(fail_text or command or msg.get("toolName") or "tool"))
    except OSError:
        return None
    if len(failures) < 2:
        return None
    if has_playbook_shape("\n".join(blobs)):
        return None
    return {
        "slug": session_slug(path),
        "path": path,
        "snippet": failures[0],
        "attempts": str(len(failures)),
    }


def iter_session_files(root: str) -> list[str]:
    out: list[str] = []
    if not os.path.isdir(root):
        return out
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".jsonl"):
                out.append(os.path.join(dirpath, name))
    out.sort()
    return out


def scan(
    root: str,
    now: float,
    window_hours: float,
    grace_minutes: float,
) -> dict[str, Any]:
    window_s = max(0.0, float(window_hours)) * 3600.0
    grace_s = max(0.0, float(grace_minutes)) * 60.0
    findings: list[dict[str, str]] = []
    scanned = 0
    skipped_old = 0
    skipped_grace = 0
    skipped_unreadable = 0

    for path in iter_session_files(root):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            skipped_unreadable += 1
            continue
        age = now - mtime
        if age > window_s:
            skipped_old += 1
            continue
        if age < grace_s:
            skipped_grace += 1
            continue
        scanned += 1
        finding = scan_session(path)
        if finding is not None:
            findings.append(finding)

    return {
        "findings": findings,
        "scanned": scanned,
        "skipped_old": skipped_old,
        "skipped_grace": skipped_grace,
        "skipped_unreadable": skipped_unreadable,
        "root": root,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    scan_p = sub.add_parser("scan", help="scan Pi session JSONL for missing debug playbooks")
    scan_p.add_argument("--root", required=True)
    scan_p.add_argument("--now", default="")
    scan_p.add_argument("--window-hours", type=float, default=24.0)
    scan_p.add_argument("--grace-minutes", type=float, default=20.0)
    args = parser.parse_args(argv)

    if args.cmd == "scan":
        report = scan(
            root=args.root,
            now=parse_now(args.now or None),
            window_hours=args.window_hours,
            grace_minutes=args.grace_minutes,
        )
        json.dump(report, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
