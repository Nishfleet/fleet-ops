#!/usr/bin/env python3
"""findings_ledger.py — the ONLY writer for the canonical findings ledger (fleet-ops#5443+).

Canonical file: $FINDINGS_LEDGER (default
~/workspaces/tooling/nish-vault/_system/shared-memory/findings-ledger.jsonl),
next to decisions-ledger.md and promotion-denial-ledger.json, same
append-only JSONL conventions: one JSON object per line, no rewrites.

Row schema (every key required, refused otherwise):
  ts            ISO-8601 UTC timestamp of the append
  source_organ  org|host id that produced the finding (e.g. fleet-blind-audit,
                outside-in-audit, silent-drop-sweep)
  run_id        run / report id the finding came from
  finding_id    sha1(source_organ|run_id|normalised_title)[:16] — stable so a
                later filing/backfill worker can UPDATE the disposition
  severity      high|medium|low|info (free-form, preserved verbatim)
  title         the finding title
  evidence_ref  path/URL of the raw evidence (report dir, ledger line, URL)
  disposition   filed | carried_over | panel_fail | by_design | duplicate_of
  ref           where the disposition points: owner/repo#n, ledger path,
                design ref — REQUIRED (a row without a ref is a silent drop)
  reason        one line, why this disposition

CLI:
  append --source-organ S --run-id R --title T --severity S --evidence-ref E
         --disposition D --ref F [--reason R]        (idempotent: skips when
         finding_id already exists with the same disposition+ref)
  backfill --reports-dir DIR [--since TS] [--issues/--no-issues]
         walk blind-audit report dirs; every verdict PASS row whose reason
         contains "skipped: max findings" becomes carried_over (or filed /
         duplicate_of when an existing issue matches by title signature).
  import --source-organ S [--md FILE --ref-col VERBATIM-REF | --jsonl FILE]
         import an existing ledger's rows (outside-in ledger.md, silent-drop
         sweep ledger.md, carryover.jsonl).
  sync-carryover --file carryover.jsonl
         mirror the in-flight blind-audit carry-over ledger into rows.
  measure
         judge paragraph line: findings: total=n filed=n carried_over=n
         oldest_carry_h=n panel_fail=n
  validate
         exit 1 on any row missing disposition/ref/finding_id.

Never fabricates: rows always cite the evidence ref they were read from.
"""
import datetime, glob, hashlib, json, os, re, subprocess, sys

DEFAULT_LEDGER = os.path.join(
    os.path.expanduser("~/workspaces/tooling/nish-vault/_system/shared-memory"),
    "findings-ledger.jsonl")
DISPOSITIONS = ("filed", "carried_over", "panel_fail", "by_design", "duplicate_of")
FIELDS = ("ts", "source_organ", "run_id", "finding_id", "severity", "title",
          "evidence_ref", "disposition", "ref", "reason")


def finding_id(source_organ, run_id, title):
    norm = re.sub(r"\W+", " ", (title or "").strip().lower()).strip()
    return hashlib.sha256(f"{source_organ}|{run_id or ''}|{norm}".encode()).hexdigest()[:16]


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_rows(path=DEFAULT_LEDGER):
    out = []
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except json.JSONDecodeError:
                        raise SystemExit(f"findings_ledger: corrupt row in {path}: {line[:80]}")
    return out


def validate_row(row, where):
    missing = [k for k in FIELDS if k != "reason" and not str(row.get(k, "")).strip()]
    if missing:
        raise SystemExit(f"findings_ledger: refusing row missing {missing} ({where})")
    if row["disposition"] not in DISPOSITIONS:
        raise SystemExit(f"findings_ledger: bad disposition {row['disposition']!r} ({where})")


def make_row(source_organ, run_id, title, severity, evidence_ref, disposition, ref, reason, ts=None):
    ts = ts or utcnow()
    row = {"ts": ts, "source_organ": source_organ, "run_id": run_id or "",
           "finding_id": finding_id(source_organ, run_id, title),
           "severity": severity or "info", "title": title,
           "evidence_ref": evidence_ref or "",
           "disposition": disposition, "ref": ref, "reason": reason or ""}
    validate_row(row, f"title={title[:60]!r}")
    return row


def append_rows(path, rows):
    existing = {r["finding_id"]: r for r in read_rows(path)}
    new = duplicate = 0
    with open(path, "a") as fh:
        for r in rows:
            prev = existing.get(r["finding_id"])
            if prev and prev["disposition"] == r["disposition"] and prev["ref"] == r["ref"]:
                duplicate += 1
                continue
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
            existing[r["finding_id"]] = r
            new += 1
    return new, duplicate


def issue_signature(title):
    return re.sub(r"[^a-z0-9]+", "-", (title or "").strip().lower()).strip("-")[:72]


def gh_issue_map(sep, ref_repo="Nishfleet/fleet-ops"):
    """signature -> '#N' for all issues (open+closed); None when gh unreadable."""
    try:
        out = subprocess.run(
            ["gh", "issue", "list", "--repo", ref_repo, "--state", "all",
             "--limit", "2000", "--json", "number,title"],
            capture_output=True, text=True, timeout=90, check=True).stdout
    except Exception:
        return None
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return None
    return {issue_signature(i.get("title", "")): f"{ref_repo.split('/')[-1]}#{i['number']}"
            for i in data}


def backfill_rows(reports_dir, since=None, issues=True, organ="fleet-blind-audit",
                  ledger=None, counts=None):
    known = {r["finding_id"] for r in read_rows(ledger or DEFAULT_LEDGER)}
    imap = gh_issue_map(None) if issues else None
    rows, counts, occurrence = [], {}, {}
    for verdicts in sorted(glob.glob(os.path.join(reports_dir, "*", "verdicts.jsonl"))):
        run_id = os.path.basename(os.path.dirname(os.path.abspath(verdicts)))
        if since and run_id < since[:16]:
            continue
        for line in open(verdicts):
            try:
                v = json.loads(line)
            except json.JSONDecodeError:
                continue
            title = (v.get("title") or "").strip()
            if (v.get("verdict") or "").upper() != "PASS":
                continue
            reason = v.get("reason") or ""
            if "skipped: max findings" not in reason:
                continue
            fid = finding_id(organ, run_id, title)
            # occurrence-level dedupe: the same finding repeats across runs
            # (one row per run is audit noise). Keep the FIRST sighting —
            # the run it was born in — and record occurrence_count.
            run_key = (organ, issue_signature(title))
            if run_key in occurrence:
                occurrence[run_key]["occurrences"] += 1
                if run_id < occurrence[run_key]["run_id"]:
                    occurrence[run_key]["run_id"] = run_id
                continue
            if fid in known:
                continue
            known.add(fid)
            occurrence[run_key] = {"finding_id": fid, "run_id": run_id, "occurrences": 1}
            sig = issue_signature(title)
            if imap and sig in imap:
                disp, ref = "filed", "Nishfleet/" + imap[sig]
            elif sig in (imap or {}):
                disp, ref = "filed", "Nishfleet/" + imap[sig]
            else:
                disp, ref = "carried_over", "audit_fix_pending:blind-audit-cap"
            r = make_row(organ, occurrence.get(issue_signature(title), {}).get("run_id", run_id), title, v.get("severity", "info"), verdicts,
                         disp, ref, f"backfill 2026-09-11: {reason.strip() or 'cap-skipped panel-PASS'}")
            r["occurrences"] = occurrence.get(issue_signature(title), {}).get("occurrences", 1) if occurrence else 1
            rows.append(r)
            counts[disp] = counts.get(disp, 0) + 1
    return rows, counts


import argparse  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser(prog="findings_ledger")
    ap.add_argument("cmd", choices=["append", "backfill", "import-md", "import-jsonl",
                                    "sync-carryover", "measure", "validate"])
    ap.add_argument("--ledger", default=DEFAULT_LEDGER)
    ap.add_argument("--source-organ", default="")
    ap.add_argument("--run-id", default="")
    ap.add_argument("--title", default="")
    ap.add_argument("--severity", default="info")
    ap.add_argument("--evidence-ref", default="")
    ap.add_argument("--disposition", default="carried_over")
    ap.add_argument("--ref", default="")
    ap.add_argument("--reason", default="")
    ap.add_argument("--reports-dir", default=os.path.expanduser(
        "~/workspaces/agent-state/fleet-blind-audit/reports"))
    ap.add_argument("--issues", dest="issues", action="store_true", default=True)
    ap.add_argument("--no-issues", dest="issues", action="store_false")
    ap.add_argument("--since", default="")
    ap.add_argument("--file", default="")
    ap.add_argument("--ref-col-header", default="disposition-ref")
    a = ap.parse_args(argv)

    if a.cmd == "append":
        row = make_row(a.source_organ, a.run_id, a.title, a.severity,
                       a.evidence_ref, a.disposition, a.ref, a.reason)
        new, dup = append_rows(a.ledger, [row])
        print(json.dumps(row) if new else "skip: duplicate", file=sys.stderr)
        sys.exit(0 if new else 3)

    if a.cmd == "backfill":
        rows, counts = backfill_rows(a.reports_dir, since=a.since, issues=a.issues, ledger=a.ledger)
        new, dup = append_rows(a.ledger, rows)
        print(f"backfill_rows={len(rows)} appended={new} duplicates={dup} "
              + " ".join(f"{k}={v}" for k, v in sorted(counts.items())), file=sys.stderr)
        return

    if a.cmd == "import-md":
        # Markdown table: | col1 | ... | last col = ref |
        if not a.source_organ:
            raise SystemExit("import-md: --source-organ required")
        rows = []
        with open(a.file) as fh:
            for line in fh:
                if not line.strip().startswith("|") or set(line.strip()) <= set("|- "):
                    continue
                cells = [c.strip() for c in line.strip().strip("|").split("|")]
                if len(cells) < 2:
                    continue
                if len(cells) >= 2 and cells[1].strip().lower() in ("severity", "finding", "title", "size"):
                    continue  # header row
                severity, title = "info", cells[1]
                if len(cells) == 2:
                    title, ref = cells[0], cells[1]
                    sev_seen = False
                elif len(cells) == 3:
                    severity, title, ref = cells[0], cells[1], cells[2]
                else:
                    # anatomy: [severity?|severity|title|...|ref]
                    if cells[0].lower() in ("high", "medium", "low", "info"):
                        severity, title, ref = cells[0].lower(), cells[2], cells[-1]
                    elif cells[1].lower() in ("high", "medium", "low", "info"):
                        severity, title, ref = cells[1].lower(), cells[2], cells[-1]
                    else:
                        title, ref = cells[1], cells[-1]
                row = make_row(a.source_organ, a.run_id or f"import-{issue_signature(title)}", title,
                               severity, f"file:///{a.file}", "filed", ref,
                               f"imported from {a.file}")
                rows.append(row)
        new, dup = append_rows(a.ledger, rows)
        print(f"import_rows={len(rows)} appended={new} duplicates={dup}", file=sys.stderr)
        return

    if a.cmd == "import-jsonl" or a.cmd == "sync-carryover":
        src = a.file
        rows, errors = [], 0
        with open(src) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except json.JSONDecodeError:
                    errors += 1
                    continue
                title = o.get("title") or ""
                disp = o.get("disposition") or o.get("status") or "carried_over"
                rid = o.get("run_id") or o.get("runId") or ""
                rows.append(make_row(
                    o.get("source_organ") or a.source_organ or "blind_audit_carryover",
                    rid, title, o.get("severity", "info"),
                    o.get("evidence_ref") or f"file:///{src} @line{len(rows)+errors+1}",
                    disp if disp in DISPOSITIONS else "carried_over",
                    o.get("ref") or o.get("issue") or "audit_fix_pending:blind-audit-carry",
                    o.get("reason") or o.get("why") or f"imported from {src}"))
        new, dup = append_rows(a.ledger, rows)
        print(f"import_rows={len(rows)} appended={new} dup={dup} unparseable={errors}", file=sys.stderr)
        return

    if a.cmd == "measure":
        rows = read_rows(a.ledger)
        total = len(rows)
        counts = {d: 0 for d in DISPOSITIONS}
        for r in rows:
            counts[r["disposition"]] += 1
        oldest_carry = 0
        for r in rows:
            if r["disposition"] != "carried_over":
                continue
            try:
                dt = (datetime.datetime.now(datetime.timezone.utc)
                      - datetime.datetime.fromisoformat(r["ts"].replace("Z", "+00:00")))
                oldest_carry = max(oldest_carry, int(dt.total_seconds() // 3600))
            except Exception:
                pass
        print(f"findings: total={total} filed={counts['filed']} "
              f"carried_over={counts['carried_over']} oldest_carry_h={oldest_carry} "
              f"panel_fail={counts['panel_fail']}")
        return

    if a.cmd == "validate":
        rows = read_rows(a.ledger)
        bad = [r for r in rows
               if not str(r.get("disposition", "")).strip()
               or not str(r.get("ref", "")).strip()
               or not str(r.get("finding_id", "")).strip()]
        if bad:
            print(f"INVALID: {len(bad)} rows missing disposition/ref/finding_id", file=sys.stderr)
            sys.exit(1)
        print(f"VALID rows={len(rows)}")
        return


if __name__ == "__main__":
    main()
