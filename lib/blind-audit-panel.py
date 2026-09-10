#!/usr/bin/env python3
# lib/blind-audit-panel.py — local dedupe/quality gate for blind-audit findings.
#
# This is the stub for the #146 senior-auditor panel. It reads a JSON object
# from stdin and prints a JSON verdict.  Verdict is "PASS" if the finding may
# be filed as a gap-audit issue, "FAIL" if it should be logged but not filed.

import json
import re
import sys
from datetime import datetime, timezone


def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


def overlap(a, b):
    sa = set(norm(a).split())
    sb = set(norm(b).split())
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / min(len(sa), len(sb))


def is_duplicate(title, candidates):
    t = norm(title)
    for c in candidates:
        ct = norm(c.get("title", ""))
        if t in ct or ct in t:
            return c
        if overlap(title, c.get("title", "")) > 0.65:
            return c
    return None


def parse_date(d):
    if not d:
        return None
    d = d.strip()
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(d, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    try:
        return datetime.fromisoformat(d.replace("Z", "+00:00"))
    except ValueError:
        return None


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        print(json.dumps({"verdict": "FAIL", "reason": "empty input"}))
        return
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"verdict": "FAIL", "reason": f"invalid JSON: {e}"}))
        return

    finding = data.get("finding", {})
    open_issues = data.get("open_issues", []) or []
    recent_merges = data.get("recent_merges", []) or []
    deliberate_states = data.get("deliberate_states", []) or []

    title = (finding.get("title") or "").strip()
    body = (finding.get("body") or "").strip()
    evidence = (finding.get("evidence") or "").strip()
    severity = (finding.get("severity") or "").strip().lower()

    if not title:
        print(json.dumps({"verdict": "FAIL", "reason": "finding has no title"}))
        return
    if not body:
        print(json.dumps({"verdict": "FAIL", "reason": "finding has no body"}))
        return
    if not evidence:
        print(json.dumps({"verdict": "FAIL", "reason": "finding has no evidence"}))
        return
    if not severity or severity not in ("critical", "high", "medium", "low"):
        print(json.dumps({"verdict": "FAIL", "reason": f"severity missing or invalid: {severity!r}"}))
        return

    dup = is_duplicate(title, open_issues)
    if dup:
        msg = f"duplicate of open gap-audit issue #{dup.get('number')}: {dup.get('title','')}"
        print(json.dumps({"verdict": "FAIL", "reason": msg}))
        return

    dup = is_duplicate(title, recent_merges)
    if dup:
        msg = f"already addressed by merged PR #{dup.get('number')}: {dup.get('title','')}"
        print(json.dumps({"verdict": "FAIL", "reason": msg}))
        return

    now = datetime.now(timezone.utc)
    combined = norm(title + " " + body)
    for ds in deliberate_states:
        state = (ds.get("state") or "").strip().lower()
        if not state:
            continue
        if state in combined or norm(state) in combined:
            expiry = parse_date(ds.get("expiry"))
            if expiry is None:
                msg = f"deliberate state '{state}' has no parseable expiry — loud finding"
                print(json.dumps({"verdict": "PASS", "reason": msg, "loud": True}))
                return
            if expiry > now:
                msg = f"suppressed by active deliberate state '{state}' (expiry {ds.get('expiry')})"
                print(json.dumps({"verdict": "FAIL", "reason": msg}))
                return
            else:
                msg = f"deliberate state '{state}' expired on {ds.get('expiry')}"
                print(json.dumps({"verdict": "PASS", "reason": msg, "loud": True}))
                return

    print(json.dumps({"verdict": "PASS"}))


if __name__ == "__main__":
    main()
