#!/usr/bin/env python3
"""Session-close lint for 'every finding gets queued' (fleet-ops#515).

The standing rule's failure mode is a finding named in chat and nowhere
else: "I noticed X, want me to file it?" and "Say the word and I'll…".
This helper reads Pi session JSONL (assistant text only — the user prompt
quotes those phrases as documentation and must not trip the detector)
and reports sessions that ASK to file/queue without a matching queue
action in the same session.

Quoted / fenced text is stripped before the offer scan so a PR body that
names the failure mode in quotes is not itself a violation.

Usage:
  python3 lib/findings-queued.py scan --root DIR [--now ISO]
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

FENCE_RE = re.compile(r"```[\s\S]*?```")
INLINE_RE = re.compile(r"`[^`]*`")
DQUOTE_RE = re.compile(r'"[^"\n]{0,240}"')

# Unquoted asks. Tight on purpose: the standing rule names these.
OFFER_RE = re.compile(
    r"(want me to (file|open|queue)"
    r"|should i (file|open|queue)"
    r"|shall i (file|open|queue)"
    r"|say the word"
    r"|let me know if you want me to"
    r"|would you like me to (file|open|queue))",
    re.I,
)

QUEUE_RE = re.compile(
    r"(gh\s+issue\s+create"
    r"|routed-by-standing-order"
    r"|github\.com/[^/\s]+/[^/\s]+/issues/\d+)",
    re.I,
)

SLUG_RE = re.compile(r"[^a-z0-9]+")


def parse_now(value: str | None) -> float:
    if not value:
        return datetime.now(timezone.utc).timestamp()
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    return datetime.fromisoformat(text).timestamp()


def strip_quoted(text: str) -> str:
    text = FENCE_RE.sub(" ", text)
    text = INLINE_RE.sub(" ", text)
    text = DQUOTE_RE.sub(" ", text)
    return text


def _content_chunks(content: Any) -> tuple[list[str], list[str]]:
    texts: list[str] = []
    tools: list[str] = []
    if isinstance(content, str):
        texts.append(content)
        return texts, tools
    if not isinstance(content, list):
        return texts, tools
    for chunk in content:
        if not isinstance(chunk, dict):
            continue
        kind = chunk.get("type")
        if kind == "text":
            texts.append(str(chunk.get("text") or ""))
        elif kind == "toolCall":
            tools.append(str(chunk.get("name") or ""))
            args = chunk.get("arguments")
            if isinstance(args, dict):
                tools.append(json.dumps(args, ensure_ascii=False))
            elif args:
                tools.append(str(args))
    return texts, tools


def session_blobs(path: str) -> tuple[str, str]:
    texts: list[str] = []
    tools: list[str] = []
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
                chunk_texts, chunk_tools = _content_chunks(msg.get("content"))
                if role == "assistant":
                    texts.extend(chunk_texts)
                    tools.extend(chunk_tools)
                elif role == "toolResult":
                    tools.extend(chunk_texts)
    except OSError:
        return "", ""
    return "\n".join(texts), "\n".join(tools)


def has_offer(assistant_text: str) -> re.Match[str] | None:
    return OFFER_RE.search(strip_quoted(assistant_text))


def has_queue(assistant_text: str, tools: str) -> bool:
    blob = f"{assistant_text}\n{tools}"
    return QUEUE_RE.search(blob) is not None


def session_slug(path: str) -> str:
    stem = os.path.splitext(os.path.basename(path))[0].lower()
    slug = SLUG_RE.sub("-", stem).strip("-")
    return (slug or "session")[:80]


def snippet_for(match: re.Match[str], text: str, width: int = 160) -> str:
    start = max(0, match.start() - 20)
    end = min(len(text), match.end() + width)
    chunk = text[start:end].replace("\n", " ").strip()
    return chunk[:200]


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
        assistant, tools = session_blobs(path)
        match = has_offer(assistant)
        if match is None:
            continue
        if has_queue(assistant, tools):
            continue
        findings.append(
            {
                "slug": session_slug(path),
                "path": path,
                "snippet": snippet_for(match, strip_quoted(assistant)),
            }
        )

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
    scan_p = sub.add_parser("scan", help="scan Pi session JSONL for unqueued offers")
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
