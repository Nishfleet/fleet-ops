#!/usr/bin/env python3
"""Session-close lint for 'every finding gets queued' (fleet-ops#515).

The standing rule's failure mode is a finding named in chat and nowhere
else: "I noticed X, want me to file it?" and "Say the word and I'll…".
This helper reads session JSONL (assistant text only — the user prompt
quotes those phrases as documentation and must not trip the detector)
and reports sessions that ASK to file/queue without a matching queue
action in the same session.

Quoted / fenced text is stripped before the offer scan so a PR body that
names the failure mode in quotes is not itself a violation.

Three transcript shapes are scanned with the same offer/queue predicates
(fleet-ops#602 — the rule binds every agent on Mac and VPS, so every
reachable transcript root is scanned, not a second detector):
  - Pi:        {"type":"message","message":{"role":...,"content":[...]}}
               tool results arrive as role:"toolResult" messages.
  - Cursor:    {"role":"...","message":{"content":[{"type":"text"|"tool_use",
               "input":...}]}} (top-level role, no `type` field).
  - Claude:    {"type":"user"|"assistant","message":{"role":...,"content":
               [{"type":"text"|"tool_use"|"tool_result",...}]}}; tool_result
               chunks live inside user messages.

Usage:
  python3 lib/findings-queued.py scan --root DIR [--root DIR ...] [--now ISO]
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

# After a catch-all offer, the next few words must name the filing/queueing
# action (file/queue it, open an issue, dig in). Otherwise "say the word and
# I'll wire it" is an implementation offer, not an unqueued finding.
# "dig in" is the standing-rule named phrase (fleet-ops#721).
ACTION_RE = re.compile(
    r"\b(?:file|queue)\s+(?:it|one|this|that|an?\s+(?:new\s+)?(?:issue|finding|ticket))\b"
    r"|\bopen\s+(?:an?|the)\s+(?:new\s+)?(?:issue|ticket|finding)\b"
    r"|\bdig in\b",
    re.I,
)

# Unquoted asks. Tight on purpose: the standing rule names these.
OFFER_RE = re.compile(
    r"\b(?:want me to (file|open|queue)"
    r"|should i (file|open|queue)"
    r"|shall i (file|open|queue)"
    r"|say the word"
    r"|let me know if you want me to"
    r"|would you like me to (file|open|queue))\b",
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
        elif kind == "toolCall":  # Pi
            tools.append(str(chunk.get("name") or ""))
            args = chunk.get("arguments")
            if isinstance(args, dict):
                tools.append(json.dumps(args, ensure_ascii=False))
            elif args:
                tools.append(str(args))
        elif kind == "tool_use":  # Cursor / Claude
            tools.append(str(chunk.get("name") or ""))
            inp = chunk.get("input")
            if isinstance(inp, dict):
                tools.append(json.dumps(inp, ensure_ascii=False))
            elif inp:
                tools.append(str(inp))
        elif kind == "tool_result":  # Cursor / Claude (inside user msgs)
            rc = chunk.get("content")
            if isinstance(rc, str):
                tools.append(rc)
            elif isinstance(rc, list):
                for sub in rc:
                    if isinstance(sub, dict) and sub.get("type") == "text":
                        tools.append(str(sub.get("text") or ""))
                    elif isinstance(sub, str):
                        tools.append(sub)
        # "thinking" / unknown chunk types are not user-visible text; skip.
    return texts, tools


def _role_of(obj: dict[str, Any]) -> str | None:
    # Cursor puts role at the top level; Pi and Claude put it under message.
    role = obj.get("role")
    if isinstance(role, str):
        return role
    msg = obj.get("message")
    if isinstance(msg, dict):
        role = msg.get("role")
        if isinstance(role, str):
            return role
    # Claude uses top-level type == "user" | "assistant".
    top = obj.get("type")
    if top in ("user", "assistant"):
        return top
    return None


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
                role = _role_of(obj)
                if role is None:
                    continue
                msg = obj.get("message")
                content = msg.get("content") if isinstance(msg, dict) else None
                chunk_texts, chunk_tools = _content_chunks(content)
                if role == "assistant":
                    texts.extend(chunk_texts)
                    tools.extend(chunk_tools)
                else:
                    # User prompts are documentation (offers there are
                    # ignored). Tool results of any shape feed queue
                    # evidence; Pi delivers them as role:"toolResult"
                    # text messages, Cursor/Claude as tool_result chunks
                    # (already routed to chunk_tools by _content_chunks).
                    tools.extend(chunk_tools)
                    if role in ("toolResult", "tool_result"):
                        tools.extend(chunk_texts)
    except OSError:
        return "", ""
    return "\n".join(texts), "\n".join(tools)


CATCH_ALL_PHRASES = ("say the word", "let me know if you want me to")


def has_offer(assistant_text: str) -> re.Match[str] | None:
    text = strip_quoted(assistant_text)
    for match in OFFER_RE.finditer(text):
        # Catch-all phrases only count if a filing/queueing action follows
        # within a short window; otherwise they are generic "go ahead" offers.
        if match.group(0).lower().startswith(CATCH_ALL_PHRASES):
            window = text[match.end() : match.end() + 120]
            if not ACTION_RE.search(window):
                continue
        return match
    return None


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


def iter_session_files(roots: list[str]) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if name.endswith(".jsonl"):
                    p = os.path.join(dirpath, name)
                    if p not in seen:
                        seen.add(p)
                        out.append(p)
    out.sort()
    return out


def scan(
    roots: list[str],
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

    for path in iter_session_files(roots):
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
        "roots": roots,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    scan_p = sub.add_parser(
        "scan", help="scan session JSONL (Pi/Cursor/Claude) for unqueued offers"
    )
    scan_p.add_argument(
        "--root",
        action="append",
        required=True,
        help="session root dir (repeatable: Pi, Cursor, Claude roots)",
    )
    scan_p.add_argument("--now", default="")
    scan_p.add_argument("--window-hours", type=float, default=24.0)
    scan_p.add_argument("--grace-minutes", type=float, default=20.0)
    args = parser.parse_args(argv)

    if args.cmd == "scan":
        report = scan(
            roots=args.root,
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
