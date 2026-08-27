#!/usr/bin/env python3
"""Session-close lint for 'check the decisions ledger before asking Nish'
(fleet-ops#514).

The standing rule's failure mode is a re-ask: an assistant question whose
tokens already sit on a ledger line. Claude Code's PreToolUse hook covers
AskUserQuestion only. This helper is the harness-agnostic gate: Pi session
JSONL (assistant text + ask-shaped tool calls) is scanned the same way,
quoted/fenced text is stripped, and 'ledger-checked' is the escape valve
matching the vault guard.

Usage:
  python3 lib/decisions-ledger.py scan --root DIR --ledger FILE [--now ISO]
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

# Sentence terminators: a . ! or ? followed by whitespace/end, or a blank
# line. Used to bound the sentence an ask phrase sits in so a "?" from a
# LATER sentence cannot be mistaken for the ask's own question mark
# (fleet-ops#846: "ask Nish to land this." is a directive; a "?" in the
# next sentence is not the ask).
SENTENCE_BOUNDARY_RE = re.compile(r"(?:[.!?])(?:\s|$)|\n\n")

# Tight on purpose: "confirm that" in implementation prose is not an ask.
# Prose asks also require a '?' in the SAME SENTENCE as the ask phrase
# (see ask_blobs + _question_in_same_sentence).
ASK_RE = re.compile(
    r"(ask(?:ing)?\s+nish"
    r"|nish[,:]?\s+(?:should|do you|can we|is this|what)"
    r"|should we\b"
    r"|wasn't this decided"
    r"|is this (?:already )?decided"
    r"|what(?:'s| is) the (?:call|decision)"
    r"|do you want (?:us|me) to)",
    re.I,
)

ASK_TOOL_NAMES = {
    "askuserquestion",
    "askquestion",
    "ask_user_question",
    "ask_question",
}

STOP = set(
    "the a an is are was were be been to of in on for with and or not no yes "
    "do does how what which should would could can may we our your my his her "
    "their it this that these those you i nish about via when where who whom "
    "whose why".split()
)

SLUG_RE = re.compile(r"[^a-z0-9]+")
LEDGER_CHECKED_RE = re.compile(r"ledger-checked", re.I)
LEDGER_LINE_RE = re.compile(r"^- 20")


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


def toks(s: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9][a-z0-9.-]{2,}", s.lower()) if w not in STOP}


def _content_chunks(content: Any) -> tuple[list[str], list[tuple[str, str]]]:
    texts: list[str] = []
    tools: list[tuple[str, str]] = []
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
            name = str(chunk.get("name") or "")
            args = chunk.get("arguments")
            if isinstance(args, dict):
                payload = json.dumps(args, ensure_ascii=False)
            elif args:
                payload = str(args)
            else:
                payload = ""
            tools.append((name, payload))
    return texts, tools


def session_blobs(path: str) -> tuple[str, list[tuple[str, str]]]:
    texts: list[str] = []
    tools: list[tuple[str, str]] = []
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
                    continue
    except OSError:
        return "", []
    return "\n".join(texts), tools


def load_ledger_lines(path: str) -> list[str]:
    lines: list[str] = []
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if LEDGER_LINE_RE.match(line):
                    lines.append(line)
    except OSError:
        return []
    return lines


def best_overlap(blob: str, ledger_lines: list[str]) -> tuple[int, str]:
    qtok = toks(blob)
    if not qtok:
        return 0, ""
    hits: list[tuple[int, str]] = []
    for line in ledger_lines:
        overlap = qtok & toks(line)
        if len(overlap) >= 3:
            hits.append((len(overlap), line))
    if not hits:
        return 0, ""
    hits.sort(reverse=True)
    return hits[0]


def decision_slug(line: str) -> str:
    # "- YYYY-MM-DD | scope | rest" → scope, else the date+first words.
    parts = [p.strip() for p in line.lstrip("- ").split("|", 2)]
    seed = parts[1] if len(parts) >= 2 else parts[0]
    slug = SLUG_RE.sub("-", seed.lower()).strip("-")
    return (slug or "decision")[:80]


def snippet_for(text: str, width: int = 200) -> str:
    chunk = text.replace("\n", " ").strip()
    return chunk[:width]


def _question_in_same_sentence(text: str, match_start: int, match_end: int) -> bool:
    # The sentence containing the ask phrase must itself carry a "?". A "?"
    # in a later sentence (e.g. "ask Nish to land this.  What about using a
    # fork?") is not the ask's own question — fleet-ops#846.
    after = text[match_end:]
    m_after = SENTENCE_BOUNDARY_RE.search(after)
    sent_end = match_end + (m_after.end() if m_after else len(after))
    before = text[:match_start]
    prev = list(SENTENCE_BOUNDARY_RE.finditer(before))
    sent_start = prev[-1].end() if prev else 0
    return "?" in text[sent_start:sent_end]


def ask_blobs(assistant_text: str, tools: list[tuple[str, str]]) -> list[str]:
    blobs: list[str] = []
    stripped = strip_quoted(assistant_text)
    for match in ASK_RE.finditer(stripped):
        if not _question_in_same_sentence(stripped, match.start(), match.end()):
            continue
        start = max(0, match.start() - 80)
        end = min(len(stripped), match.end() + 240)
        window = stripped[start:end]
        blobs.append(window)
    for name, payload in tools:
        if name.lower() in ASK_TOOL_NAMES:
            blobs.append(payload)
    return blobs


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
    ledger: str,
    now: float,
    window_hours: float,
    grace_minutes: float,
) -> dict[str, Any]:
    window_s = max(0.0, float(window_hours)) * 3600.0
    grace_s = max(0.0, float(grace_minutes)) * 60.0
    ledger_lines = load_ledger_lines(ledger)
    findings: list[dict[str, str]] = []
    scanned = 0
    skipped_old = 0
    skipped_grace = 0
    skipped_unreadable = 0
    seen: set[str] = set()

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
        for blob in ask_blobs(assistant, tools):
            if LEDGER_CHECKED_RE.search(blob):
                continue
            count, line = best_overlap(blob, ledger_lines)
            if count < 3:
                continue
            slug = decision_slug(line)
            key = f"{path}::{slug}"
            if key in seen:
                continue
            seen.add(key)
            findings.append(
                {
                    "slug": slug,
                    "path": path,
                    "ledger_line": line[:300],
                    "snippet": snippet_for(blob),
                }
            )

    return {
        "findings": findings,
        "scanned": scanned,
        "skipped_old": skipped_old,
        "skipped_grace": skipped_grace,
        "skipped_unreadable": skipped_unreadable,
        "root": root,
        "ledger": ledger,
        "ledger_lines": len(ledger_lines),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    scan_p = sub.add_parser(
        "scan", help="scan Pi session JSONL for ledger-overlapping asks"
    )
    scan_p.add_argument("--root", required=True)
    scan_p.add_argument("--ledger", required=True)
    scan_p.add_argument("--now", default="")
    scan_p.add_argument("--window-hours", type=float, default=24.0)
    scan_p.add_argument("--grace-minutes", type=float, default=20.0)
    args = parser.parse_args(argv)

    if args.cmd == "scan":
        report = scan(
            root=args.root,
            ledger=args.ledger,
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
