#!/usr/bin/env python3
# lib/manual-seam-lens.py — mechanical enumerator + report table for
# fleet-ops#377. A "manual seam" is an operation a human or flagship did
# by hand. Each cycle lists them from evidence, matches each to a queued
# mechanism issue, or records accepted-as-manual with a dated reason.
#
# This is context collection for the existing blind-audit oneshot, not a
# new dispatcher. Live sources fail soft (empty list) so tests stay
# hermetic unless a fixture path is passed.

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


WORKER_CLAIM_RE = re.compile(
    r"(?i)claimed by pi-|claim branch released after pi-"
)
MECHANICAL_BODY_RE = re.compile(
    r"(?i)filed by fleet-blind-audit|filed by pi-intake|filed by pi-scout"
)
MECHANICAL_TITLE_RE = re.compile(
    r"(?i)^\[gap-audit\]|^AUTO-REVERT"
)
ISO_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
HEADING_RE = re.compile(r"^## Manual-seam lens\b", re.M)

def parse_iso(value):
    if not value:
        return None
    value = str(value).strip().strip("'\"")
    m = ISO_RE.search(value)
    if m:
        try:
            return datetime.strptime(m.group(0), "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc
            )
        except ValueError:
            pass
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_iso_prefix(value):
    """Parse an ISO timestamp that may have a trailing ' (note)'."""
    if not value:
        return None
    m = ISO_RE.search(str(value))
    if not m:
        return None
    return parse_iso(m.group(0))


def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


def overlap(a, b):
    sa = set(norm(a).split())
    sb = set(norm(b).split())
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / min(len(sa), len(sb))


def is_match(title, candidates):
    t = norm(title)
    if not t:
        return None
    for c in candidates:
        other = c.get("title") or c.get("seam") or ""
        ct = norm(other)
        if not ct:
            continue
        if t in ct or ct in t or overlap(title, other) > 0.65:
            return c
    return None


def load_json(path, default):
    if not path:
        return default
    p = Path(path)
    if not p.is_file():
        return default
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default
    return data


def since_cutoff(since_s, now):
    dt = parse_iso_prefix(since_s) or parse_iso(since_s)
    if dt is None:
        return now - timedelta(hours=24)
    return dt


def candidate(seam, source, when, evidence, extra=None):
    row = {
        "seam": (seam or "").strip()[:200],
        "source": source,
        "when": when or "",
        "evidence": (evidence or "").strip()[:500],
    }
    if extra:
        row.update(extra)
    return row


def collect_memoryctl(dir_path, since_dt, now):
    out = []
    if not dir_path:
        return out
    root = Path(dir_path)
    if not root.is_dir():
        return out
    for path in sorted(root.rglob("*.md")):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if 'memory_kind: "outcome"' not in text and "memory_kind: outcome" not in text:
            continue
        created = None
        m = re.search(r"(?m)^created_at:\s*[\"']?([^\"'\n]+)", text)
        if m:
            created = parse_iso(m.group(1).strip())
        if created is None:
            created = parse_iso_prefix(path.name)
        if created is not None and created < since_dt:
            continue
        title = ""
        for line in text.splitlines():
            if line.startswith("# "):
                title = line[2:].strip()
                break
        if not title:
            title = path.stem
        when = created.strftime("%Y-%m-%dT%H:%M:%SZ") if created else now.strftime("%Y-%m-%dT%H:%M:%SZ")
        out.append(candidate(title, "memoryctl", when, str(path)))
        if len(out) >= 50:
            break
    return out


def collect_actions_log(log_path, since_dt, now):
    out = []
    if not log_path:
        return out
    p = Path(log_path)
    if not p.is_file():
        return out
    try:
        text = p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return out
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("EXTLOAD-") or line.startswith("PACKET-"):
            continue
        stamp = parse_iso_prefix(line)
        if stamp is None:
            continue
        if stamp < since_dt:
            continue
        rest = ISO_RE.sub("", line, count=1).strip(" -:")
        if not rest or len(rest) < 8:
            continue
        if WORKER_CLAIM_RE.search(rest):
            continue
        out.append(candidate(rest[:200], "actions-log", stamp.strftime("%Y-%m-%dT%H:%M:%SZ"), str(p)))
        if len(out) >= 50:
            break
    return out


def is_mechanical_github(event):
    title = event.get("title") or ""
    body = event.get("body") or ""
    if WORKER_CLAIM_RE.search(body) or MECHANICAL_BODY_RE.search(body):
        return True
    if MECHANICAL_TITLE_RE.search(title):
        return True
    return False


def collect_github(events, since_dt, now):
    out = []
    if not isinstance(events, list):
        return out
    for ev in events:
        if not isinstance(ev, dict):
            continue
        when = parse_iso(ev.get("created_at") or ev.get("when") or "")
        if when is not None and when < since_dt:
            continue
        if is_mechanical_github(ev):
            continue
        kind = ev.get("kind") or "issue"
        title = ev.get("title") or ev.get("body") or ev.get("label") or kind
        if kind == "comment" and WORKER_CLAIM_RE.search(str(title)):
            continue
        stamp = (when or now).strftime("%Y-%m-%dT%H:%M:%SZ")
        evidence = ev.get("evidence") or f"github {kind} #{ev.get('number', '?')}"
        out.append(candidate(str(title)[:200], "github", stamp, evidence, {"kind": kind}))
        if len(out) >= 50:
            break
    return out


def collect_systemctl_starts(events, since_dt, now):
    out = []
    if not isinstance(events, list):
        return out
    for ev in events:
        if not isinstance(ev, dict):
            continue
        triggered = ev.get("triggered_by") or []
        if triggered:
            continue
        unit = (ev.get("unit") or "").strip()
        if not unit:
            continue
        when = parse_iso(ev.get("when") or ev.get("created_at") or "")
        if when is not None and when < since_dt:
            continue
        stamp = (when or now).strftime("%Y-%m-%dT%H:%M:%SZ")
        out.append(
            candidate(
                f"hand-started {unit}",
                "systemctl-start",
                stamp,
                ev.get("evidence") or f"systemctl start {unit} (no timer/trigger parent)",
            )
        )
        if len(out) >= 50:
            break
    return out


def collect(args):
    now = parse_iso(args.now) or datetime.now(timezone.utc)
    since_dt = since_cutoff(args.since, now)
    if args.evidence_file:
        data = load_json(args.evidence_file, {"candidates": []})
        if isinstance(data, list):
            candidates = data
        else:
            candidates = data.get("candidates") or []
        return {
            "since": since_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "now": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "candidates": candidates,
        }

    candidates = []
    candidates.extend(collect_memoryctl(args.memoryctl_dir, since_dt, now))
    candidates.extend(collect_actions_log(args.actions_log, since_dt, now))
    candidates.extend(collect_github(load_json(args.gh_events, []), since_dt, now))
    candidates.extend(collect_systemctl_starts(load_json(args.systemctl_starts, []), since_dt, now))
    return {
        "since": since_dt.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "now": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "candidates": candidates,
    }


def reviewer_disposition(candidate_row, reviewer_seams):
    hit = is_match(candidate_row.get("seam", ""), reviewer_seams)
    if not hit:
        return None
    disp = (hit.get("disposition") or "").strip().lower()
    if disp not in ("accepted-as-manual", "matched", "filed"):
        return None
    return hit


def dated_reason(reason, now_iso):
    reason = (reason or "").strip()
    if not reason:
        return f"{now_iso}: accepted as Nish-only (no further reason given)"
    if ISO_RE.search(reason):
        return reason
    return f"{now_iso}: {reason}"


def classify(candidates, findings_doc, open_issues, now_iso):
    findings = list((findings_doc or {}).get("findings") or [])
    reviewer_seams = list((findings_doc or {}).get("seams") or [])
    rows = []
    added = 0
    next_rank = 1
    for f in findings:
        try:
            r = int(f.get("rank") or 0)
        except (TypeError, ValueError):
            r = 0
        if r >= next_rank:
            next_rank = r + 1

    for cand in candidates:
        seam = cand.get("seam") or ""
        source = cand.get("source") or ""
        evidence = cand.get("evidence") or ""
        rev = reviewer_disposition(cand, reviewer_seams)
        if rev and (rev.get("disposition") or "").lower() == "accepted-as-manual":
            rows.append(
                {
                    "seam": seam,
                    "source": source,
                    "mechanism": "—",
                    "disposition": "accepted-as-manual",
                    "reason": dated_reason(rev.get("reason") or "", now_iso),
                    "evidence": evidence,
                }
            )
            continue
        matched = is_match(seam, open_issues)
        if matched:
            num = matched.get("number")
            mech = f"#{num}" if num else (matched.get("title") or "open issue")
            rows.append(
                {
                    "seam": seam,
                    "source": source,
                    "mechanism": mech,
                    "disposition": "matched",
                    "reason": f"queued mechanism {mech}",
                    "evidence": evidence,
                }
            )
            continue
        found = is_match(seam, findings)
        if found:
            rows.append(
                {
                    "seam": seam,
                    "source": source,
                    "mechanism": found.get("title") or "finding this run",
                    "disposition": "filed",
                    "reason": "queued as a gap-audit finding this run",
                    "evidence": evidence,
                }
            )
            continue
        title = f"manual seam: {seam}"[:80]
        body = (
            f"Hand-performed operation since the last cycle with no queued "
            f"mechanism issue. Source: {source}. File (or match to) a "
            f"mechanism via the standard queue."
        )
        finding = {
            "rank": next_rank,
            "title": title,
            "body": body,
            "severity": "high",
            "evidence": evidence or source,
        }
        findings.append(finding)
        next_rank += 1
        added += 1
        rows.append(
            {
                "seam": seam,
                "source": source,
                "mechanism": title,
                "disposition": "filed",
                "reason": "no matching mechanism — queued this run",
                "evidence": evidence,
            }
        )
    return findings, rows, added


def render_table(rows, since, now):
    lines = [
        "## Manual-seam lens",
        "",
        f"Seams since `{since}` (this run `{now}`).",
        "",
        "A cycle is not CLEAN while any row is still unmatched. "
        "Nish-only work (money, privacy, security, legal, product "
        "direction) is listed as accepted-as-manual with a dated reason, "
        "not 'fixed'.",
        "",
        "| seam | source | mechanism | disposition | reason |",
        "|---|---|---|---|---|",
    ]
    if not rows:
        lines.append("| — | — | — | none | no hand seams in the window |")
    else:
        for r in rows:
            seam = (r.get("seam") or "—").replace("|", "/")
            source = (r.get("source") or "—").replace("|", "/")
            mech = (r.get("mechanism") or "—").replace("|", "/")
            disp = (r.get("disposition") or "—").replace("|", "/")
            reason = (r.get("reason") or "—").replace("|", "/")
            lines.append(f"| {seam} | {source} | {mech} | {disp} | {reason} |")
    lines.append("")
    return "\n".join(lines)


def upsert_report(report_path, table_md):
    path = Path(report_path)
    text = ""
    if path.is_file():
        text = path.read_text(encoding="utf-8", errors="replace")
    if HEADING_RE.search(text):
        # Replace from the heading through the next top-level ## or EOF.
        parts = HEADING_RE.split(text, maxsplit=1)
        prefix = parts[0].rstrip()
        rest = parts[1] if len(parts) > 1 else ""
        nxt = re.search(r"\n## ", rest)
        suffix = rest[nxt.start() :] if nxt else ""
        text = prefix + "\n\n" + table_md.rstrip() + suffix
    else:
        text = text.rstrip() + "\n\n" + table_md.rstrip() + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text if text.endswith("\n") else text + "\n", encoding="utf-8")


def close(args):
    now_iso = args.now or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    collected = load_json(args.candidates, {"candidates": []})
    if isinstance(collected, list):
        candidates = collected
        since = args.since or ""
    else:
        candidates = collected.get("candidates") or []
        since = collected.get("since") or args.since or ""
    findings_doc = load_json(args.findings, {"findings": []})
    if isinstance(findings_doc, list):
        findings_doc = {"findings": findings_doc}
    elif not isinstance(findings_doc, dict):
        findings_doc = {"findings": []}
    open_issues = load_json(args.open_issues, [])
    if not isinstance(open_issues, list):
        open_issues = []

    findings, rows, added = classify(candidates, findings_doc, open_issues, now_iso)
    findings_doc["findings"] = findings
    findings_doc["seams"] = [
        {
            "seam": r["seam"],
            "source": r["source"],
            "mechanism": r["mechanism"],
            "disposition": r["disposition"],
            "reason": r["reason"],
        }
        for r in rows
    ]
    Path(args.findings).parent.mkdir(parents=True, exist_ok=True)
    Path(args.findings).write_text(json.dumps(findings_doc, indent=2) + "\n", encoding="utf-8")
    table = render_table(rows, since or "(unknown)", now_iso)
    upsert_report(args.report, table)
    if args.seams_out:
        Path(args.seams_out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.seams_out).write_text(
            json.dumps({"since": since, "now": now_iso, "seams": findings_doc["seams"]}, indent=2)
            + "\n",
            encoding="utf-8",
        )
    counts = {
        "added": added,
        "matched": sum(1 for r in rows if r["disposition"] == "matched"),
        "filed": sum(1 for r in rows if r["disposition"] == "filed"),
        "accepted": sum(1 for r in rows if r["disposition"] == "accepted-as-manual"),
        "total": len(rows),
    }
    return counts


def build_parser():
    p = argparse.ArgumentParser(description="Manual-seam lens for fleet-blind-audit")
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("collect", help="enumerate hand-performed operations")
    c.add_argument("--since", default="")
    c.add_argument("--now", default="")
    c.add_argument("--evidence-file", default="")
    c.add_argument("--memoryctl-dir", default="")
    c.add_argument("--actions-log", default="")
    c.add_argument("--gh-events", default="")
    c.add_argument("--systemctl-starts", default="")

    k = sub.add_parser("close", help="match, file unmatched, write the report table")
    k.add_argument("--candidates", required=True)
    k.add_argument("--findings", required=True)
    k.add_argument("--open-issues", required=True)
    k.add_argument("--report", required=True)
    k.add_argument("--seams-out", default="")
    k.add_argument("--since", default="")
    k.add_argument("--now", default="")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.cmd == "collect":
        json.dump(collect(args), sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    if args.cmd == "close":
        json.dump(close(args), sys.stdout)
        sys.stdout.write("\n")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
