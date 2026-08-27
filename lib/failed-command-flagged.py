#!/usr/bin/env python3
"""Session-close lint for 'a failed command is ALWAYS flagged'
(fleet-ops#535).

The standing rule's failure mode is a swallowed non-zero: a Pi toolResult
with isError / 'Command exited with code N' / timeout, and no later
assistant text that names the failure. Burying it in the tool result the
user may not read does not count.

grep/rg/diff exit 1 (POSIX no-match) is not a failure. ls no-match
(exit 2) and which no-match (exit 1) are also treated as probes when
no real error text is present. Exit >= 2, timeouts, and non-probe
exit 1 (the 404 origin case) are. A spawn-guard or harness block
(SPAWN_BLOCKED / "Dangerous command blocked") is not a ran-and-failed
command: the call never executed.

Usage:
  python3 lib/failed-command-flagged.py scan --root DIR [--now ISO]
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
# Pipeline stage that is a search/diff whose exit 1 means "no match".
BENIGN_STAGE_RE = re.compile(
    r"(?:^|[;&|\n]|&&|\|\|)\s*(?:sudo\s+)?"
    r"(?:grep|egrep|fgrep|rg|ripgrep|diff|git\s+grep|git\s+diff|which)\b",
    re.I,
)
# Real errors that must not hide behind a grep in the same script.
REAL_ERR_RE = re.compile(
    r"(Not Found|Permission denied|HTTP\s*[45]\d\d|"
    r"error TS\d+|API rate limit)",
    re.I,
)
# ls(1) exits 2 when a path or glob does not match. Agents use this as a probe,
# so treat it like grep no-match unless the output shows a real ls error.
LS_BENIGN_RE = re.compile(
    r"(?:^|[;&|\n]|&&|\|\|)\s*(?:sudo\s+)?(?:ls|ll)\b",
    re.I,
)
# ls error text that must not be treated as a no-match probe.
LS_ERR_RE = re.compile(
    r"(?:ls:|cannot access|No such file or directory|Permission denied)",
    re.I,
)
# Unquoted assistant report. Tight on the standing-rule verbs.
FLAG_RE = re.compile(
    r"(failed|fails|failing|failure|\berror\b|non-zero|exited with|"
    r"timed out|timeout|blocker|not found|\b404\b|\b50[0-9]\b|"
    r"unexpected failing command|it is now the blocker)",
    re.I,
)
# Command never ran: Pi confirmation prompt, or fleet spawn-guard block.
# SPAWN_BLOCKED is the live #648 class (git_stash_forbidden on `git stash list`).
HARNESS_BLOCK_RE = re.compile(
    r"Dangerous command blocked \(no UI for confirmation\)"
    r"|SPAWN_BLOCKED reason=",
    re.I,
)
# Read tool with an offset past the end of the file: a negative result,
# like grep/rg/diff no-match, not a swallowed command failure.
READ_OFFSET_RE = re.compile(
    r"Offset \d+ is beyond end of file \(\d+ lines total\)", re.I
)
# Downstream of a harness block (fleet-ops#677): the spawn-guard refused the
# heredoc/redirect that would have created a script, so a later `bash <path>`
# fails with exit 127 "No such file or directory". The assistant recovers via
# the write tool. That ENOENT is a cascade of the block, not a swallowed
# command failure. Only exempt when a prior toolResult in the session was a
# harness block — a 127 ENOENT with no prior block is a real failure.
ENOENT_RE = re.compile(r"No such file or directory", re.I)
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


def _exit_code(text: str) -> int | None:
    match = EXIT_RE.search(text)
    if match is None:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def is_benign_no_match(command: str, text: str, code: int | None) -> bool:
    if code is None:
        return False
    if TIMEOUT_RE.search(text):
        return False
    if REAL_ERR_RE.search(text):
        return False
    # ls(1) exits 2 when a path or glob does not match; agents use this as a probe.
    if LS_BENIGN_RE.search(command) and code == 2 and not LS_ERR_RE.search(text):
        return True
    if code != 1:
        return False
    return BENIGN_STAGE_RE.search(command) is not None


def result_failed(
    msg: dict[str, Any], command: str, had_prior_block: bool = False
) -> tuple[bool, str]:
    text = _text_chunks(msg.get("content"))
    if HARNESS_BLOCK_RE.search(text):
        return False, text
    if msg.get("toolName") == "read" and READ_OFFSET_RE.search(text):
        return False, text
    is_error = bool(msg.get("isError"))
    timed_out = TIMEOUT_RE.search(text) is not None
    code = _exit_code(text)
    if not is_error and not timed_out and code is None:
        return False, text
    # Downstream of a harness block (fleet-ops#677): the spawn-guard refused
    # the heredoc/redirect that would have created the script, so invoking it
    # fails with exit 127 "No such file or directory". The assistant recovers
    # via the write tool. Only exempt when a prior toolResult was a block.
    if had_prior_block and code == 127 and ENOENT_RE.search(text):
        return False, text
    if is_benign_no_match(command, text, code if code is not None else (1 if is_error else None)):
        return False, text
    if is_error or timed_out or (code is not None and code != 0):
        return True, text
    return False, text


def snippet_for(text: str, width: int = 200) -> str:
    chunk = text.replace("\n", " ").strip()
    return chunk[:width]


def session_slug(path: str) -> str:
    stem = os.path.splitext(os.path.basename(path))[0].lower()
    slug = SLUG_RE.sub("-", stem).strip("-")
    return (slug or "session")[:80]


def scan_session(path: str) -> dict[str, str] | None:
    calls: dict[str, str] = {}
    pending: list[str] = []
    had_harness_block = False
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
                    if isinstance(content, list):
                        for chunk in content:
                            if not isinstance(chunk, dict):
                                continue
                            if chunk.get("type") == "toolCall":
                                cid = str(chunk.get("id") or "")
                                if cid:
                                    calls[cid] = _command_from_args(chunk.get("arguments"))
                    text = _text_chunks(content)
                    if pending and FLAG_RE.search(text):
                        pending.clear()
                elif role == "toolResult":
                    tid = str(msg.get("toolCallId") or "")
                    command = calls.get(tid, "")
                    result_text = _text_chunks(msg.get("content"))
                    if HARNESS_BLOCK_RE.search(result_text):
                        had_harness_block = True
                    failed, text = result_failed(
                        msg, command, had_prior_block=had_harness_block
                    )
                    if failed:
                        pending.append(snippet_for(text or command or msg.get("toolName") or "tool"))
    except OSError:
        return None
    if not pending:
        return None
    return {
        "slug": session_slug(path),
        "path": path,
        "snippet": pending[0],
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
    scan_p = sub.add_parser("scan", help="scan Pi session JSONL for swallowed failures")
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
