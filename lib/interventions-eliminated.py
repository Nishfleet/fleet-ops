#!/usr/bin/env python3
"""Session-close lint for 'interventions get eliminated, not repeated'
(fleet-ops#526).

The standing rule's failure mode is a third identical correction of the
same intervention: first strike is the correction, second is still
"eliminate it", third means the class was absorbed silently and recurred.

This helper reads Pi session JSONL. User text is the primary signal
(Nish / orchestrator / reviewer correcting). Assistant text matching
self-caught-repeat phrases is also counted. Quoted and fenced text is
stripped. Worker packets (long dumps, TARGET:/Hard rules: markers) are
ignored so the prompt that documents the failure mode cannot trip it.

Events cluster by significant-token overlap. A cluster of size >=
threshold (default 3) is a finding.

Usage:
  python3 lib/interventions-eliminated.py scan --root DIR [--now ISO]
      [--window-hours 336] [--grace-minutes 20] [--threshold 3]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from typing import Any

FENCE_RE = re.compile(r"```[\s\S]*?```")
INLINE_RE = re.compile(r"`[^`]*`")
DQUOTE_RE = re.compile(r'"[^"\n]{0,240}"')

# Tight on purpose. The named failure is a repeated correction, not a
# generic "don't" in a standing-rules dump.
CORRECTION_RE = re.compile(
    r"("
    r"already (told|asked|said|corrected) you"
    r"|i (already |just )?(told|asked|said) you"
    r"|you keep (doing|using|writing|spawning|committing)"
    r"|don'?t (do|use|write|commit|spawn|merge) .{0,80} again"
    r"|stop (doing|using|writing|spawning) .{0,80}(again)?"
    r"|we('ve| have) been over this"
    r"|this is the same (mistake|error|issue|correction|intervention)"
    r"|same (mistake|correction|error|intervention) (again|as before)"
    r"|third time"
    r"|second time i('ve| have) (told|asked|corrected)"
    r"|you were (just )?corrected"
    r"|going backwards"
    r"|why are you (still|doing)"
    r")",
    re.I,
)

PACKET_RE = re.compile(
    r"(You implement exactly ONE GitHub issue"
    r"|TARGET:\s*repo\s"
    r"|MANDATORY WORKER RULE"
    r"|Hard rules:)",
    re.I,
)

MAX_USER_CHARS = 2400

STOP = set(
    "the a an is are was were be been to of in on for with and or not no yes "
    "do does how what which should would could can may we our your my his her "
    "their it this that these those you i nish about via when where who whom "
    "whose why just have has had did already told asked said stop doing using "
    "writing spawning committing again same mistake error issue correction "
    "intervention third second time over been going backwards still don't "
    "dont don never keep that".split()
)

SCAFFOLD = STOP  # alias: remaining tokens are the intervention subject

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


def toks(s: str) -> set[str]:
    out: set[str] = set()
    for w in re.findall(r"[a-z0-9][a-z0-9.-]{2,}", s.lower()):
        w = w.strip(".-")
        if len(w) < 3 or w in SCAFFOLD:
            continue
        out.add(w)
    return out


def _content_chunks(content: Any) -> list[str]:
    texts: list[str] = []
    if isinstance(content, str):
        texts.append(content)
        return texts
    if not isinstance(content, list):
        return texts
    for chunk in content:
        if not isinstance(chunk, dict):
            continue
        if chunk.get("type") == "text":
            texts.append(str(chunk.get("text") or ""))
    return texts


def is_packet(text: str) -> bool:
    if len(text) > MAX_USER_CHARS:
        return True
    return PACKET_RE.search(text) is not None


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


def session_events(path: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
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
                if role not in ("user", "assistant"):
                    continue
                for raw in _content_chunks(msg.get("content")):
                    if role == "user" and is_packet(raw):
                        continue
                    stripped = strip_quoted(raw)
                    match = CORRECTION_RE.search(stripped)
                    if match is None:
                        continue
                    # One event per message chunk, not per regex hit.
                    # "I told you X. Stop doing that." is one correction.
                    start = max(0, match.start() - 80)
                    end = min(len(stripped), match.end() + 160)
                    window = stripped[start:end]
                    core = toks(window)
                    if len(core) < 2:
                        continue
                    events.append(
                        {
                            "path": path,
                            "role": role,
                            "core": core,
                            "snippet": snippet_for(match, stripped),
                        }
                    )
    except OSError:
        return []
    return events


def _same_intervention(a: set[str], b: set[str]) -> bool:
    overlap = a & b
    if len(overlap) >= 3:
        return True
    if len(overlap) < 2:
        return False
    denom = len(a | b)
    return bool(denom) and (len(overlap) / denom) >= 0.5


def cluster_events(events: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    n = len(events)
    if n == 0:
        return []
    parent = list(range(n))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for i in range(n):
        for j in range(i + 1, n):
            if _same_intervention(events[i]["core"], events[j]["core"]):
                union(i, j)

    groups: dict[int, list[dict[str, Any]]] = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(events[i])
    return list(groups.values())


def cluster_slug(group: list[dict[str, Any]]) -> str:
    counts: Counter[str] = Counter()
    for event in group:
        counts.update(event["core"])
    # Count desc, then alpha, so the signal key is stable across processes.
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    seed = "-".join(tok for tok, _ in ranked[:6])
    slug = SLUG_RE.sub("-", seed.lower()).strip("-")
    return (slug or "correction")[:80]


def scan(
    root: str,
    now: float,
    window_hours: float,
    grace_minutes: float,
    threshold: int,
) -> dict[str, Any]:
    window_s = max(0.0, float(window_hours)) * 3600.0
    grace_s = max(0.0, float(grace_minutes)) * 60.0
    thresh = max(2, int(threshold))
    events: list[dict[str, Any]] = []
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
        events.extend(session_events(path))

    findings: list[dict[str, Any]] = []
    for group in cluster_events(events):
        if len(group) < thresh:
            continue
        paths = sorted({e["path"] for e in group})
        findings.append(
            {
                "slug": cluster_slug(group),
                "count": str(len(group)),
                "path": paths[-1],
                "paths": ",".join(os.path.basename(p) for p in paths),
                "snippet": group[-1]["snippet"],
            }
        )

    return {
        "findings": findings,
        "scanned": scanned,
        "events": len(events),
        "skipped_old": skipped_old,
        "skipped_grace": skipped_grace,
        "skipped_unreadable": skipped_unreadable,
        "root": root,
        "threshold": thresh,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    scan_p = sub.add_parser(
        "scan", help="scan Pi session JSONL for a third identical correction"
    )
    scan_p.add_argument("--root", required=True)
    scan_p.add_argument("--now", default="")
    scan_p.add_argument("--window-hours", type=float, default=336.0)
    scan_p.add_argument("--grace-minutes", type=float, default=20.0)
    scan_p.add_argument("--threshold", type=int, default=3)
    args = parser.parse_args(argv)

    if args.cmd == "scan":
        report = scan(
            root=args.root,
            now=parse_now(args.now or None),
            window_hours=args.window_hours,
            grace_minutes=args.grace_minutes,
            threshold=args.threshold,
        )
        json.dump(report, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
