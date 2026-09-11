#!/usr/bin/env python3
# lib/blind-audit-carryover.py — carry-over ledger + --backfill driver for
# bin/fleet-blind-audit.
#
# Nish 2026-09-11: a panel-PASS finding must never be dropped again. The
# audit appends unfiled PASS findings to $STATE_DIR/carryover.jsonl; the next
# run files the ledger FIRST (oldest first) under the same cap. `backfill`
# reconstructs every PASS-but-unfiled finding persisted in report
# verdicts.jsonl files since a date, re-panels it, and files survivors
# through the fleet-ops#1212 same-problem gate (bin/fleet-issue-file).
#
# Subcommands (the bash organ calls these; finding JSON on stdin where noted):
#   signature                        finding JSON on stdin -> sha256 hex
#   norm                             titles on stdin -> normalised keys out
#   load --file F                    ledger entries on stdout, oldest first
#   append --file F --run R --now N  finding on stdin; append unless sig seen
#   rewrite --file F --resolved P    drop entries whose signature resolved
#   backfill --since DATE            reconstruct + re-panel + file survivors

import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

SEV = {"blocker": 0, "critical": 0, "high": 1, "medium": 2}
GAP_PREFIX = re.compile(r"^\[gap-audit\]\s*", re.I)
RUN_DIR_RE = re.compile(r"\d{8}T\d{6}Z")


def tkey(s):
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


def norm_title(t):
    # Issues we file are titled "[gap-audit] <title>"; strip before matching.
    return tkey(GAP_PREFIX.sub("", t or ""))


def sig_of(f):
    # Signature = normalised title + evidence hash, so a re-worded duplicate
    # with the same evidence still collapses. Keep in sync with the format
    # bin/fleet-blind-audit documents for carryover.jsonl.
    seed = tkey(f.get("title"))
    ev = f.get("evidence")
    if isinstance(ev, str) and ev.strip():
        seed += "\x00" + hashlib.sha256(ev.strip().encode()).hexdigest()
    return hashlib.sha256(seed.encode()).hexdigest()


def log(msg):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{ts}] [fleet-blind-audit] {msg}", file=sys.stderr)


def gh_json(args, default):
    try:
        p = subprocess.run(["gh"] + args, capture_output=True, text=True, timeout=120)
        if p.returncode == 0 and p.stdout.strip():
            return json.loads(p.stdout)
    except Exception:
        pass
    return default


# --- carry-over ledger ------------------------------------------------------

def load_entries(path):
    entries = []
    try:
        fh = open(path, encoding="utf-8")
    except OSError:
        return entries
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            if not isinstance(e, dict) or not isinstance(e.get("finding"), dict):
                continue
            # Backfill the identity a writer forgot to store, so an entry can
            # always be resolved later.
            if not e.get("signature"):
                e["signature"] = sig_of(e["finding"])
            entries.append(e)
    return entries


def append_entry(path, finding, run, now_iso):
    sig = sig_of(finding)
    if any(e.get("signature") == sig for e in load_entries(path)):
        return sig  # already pending
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"first_seen": now_iso, "run": run,
                             "signature": sig, "finding": finding}) + "\n")
    return sig


def cmd_append(a):
    finding = json.loads(sys.stdin.read() or "{}")
    append_entry(a.file, finding, a.run, a.now)
    return 0


def cmd_load(a):
    for e in load_entries(a.file):
        print(json.dumps(e))
    return 0


def cmd_rewrite(a):
    resolved = set()
    if os.path.isfile(a.resolved):
        resolved = set(open(a.resolved, encoding="utf-8").read().split())
    kept = [e for e in load_entries(a.file) if e["signature"] not in resolved]
    tmp = a.file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        for e in kept:
            fh.write(json.dumps(e) + "\n")
    os.replace(tmp, a.file)
    return 0


# --- deliberate-states table (same parse as the bash organ) -----------------

def load_deliberate(path):
    rows = []
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return rows
    in_table = False
    for ln in lines:
        if not in_table:
            if re.match(r"^\|?\s*state\s*\|", ln, re.I):
                in_table = True
            continue
        cells = [c.strip() for c in ln.split("|")]
        while cells and cells[0] == "":
            cells.pop(0)
        while cells and cells[-1] == "":
            cells.pop()
        if not cells or all(re.match(r"^[-:]+$", c) for c in cells):
            continue
        if len(cells) >= 4 and cells[0].lower() != "state" and cells[0]:
            rows.append({"state": cells[0], "reason": cells[1],
                         "expiry": cells[2], "owner": cells[3]})
    return rows


# --- backfill ----------------------------------------------------------------

def reconstruct(state, since):
    """Every PASS-but-unfiled verdict joined to its persisted finding.

    Returns (rows, lost, no_verdicts): matched findings with first_run set,
    runs whose PASS titles are absent from findings.json, and report dirs
    with no verdicts.jsonl at all (nothing persisted to reconstruct).
    """
    since_key = since.replace("-", "")[:8]
    rows, lost, no_verdicts = [], [], []
    reports = os.path.join(state, "reports")
    if not os.path.isdir(reports):
        return rows, lost, no_verdicts
    for name in sorted(os.listdir(reports)):
        d = os.path.join(reports, name)
        if not (RUN_DIR_RE.fullmatch(name) and os.path.isdir(d) and name[:8] >= since_key):
            continue
        vpath = os.path.join(d, "verdicts.jsonl")
        if not os.path.isfile(vpath):
            no_verdicts.append(name)
            continue
        want = set()
        for line in open(vpath, encoding="utf-8"):
            try:
                v = json.loads(line)
            except Exception:
                continue
            # PASS + no issue = never filed. "refused:" verdicts are drill
            # fixtures that must never be reconstructed into live filings.
            if (v.get("verdict") == "PASS" and not (v.get("issue") or "")
                    and not (v.get("reason") or "").startswith("refused:")
                    and (v.get("title") or "")):
                want.add(v["title"])
        if not want:
            continue
        try:
            data = json.load(open(os.path.join(d, "findings.json"), encoding="utf-8"))
            fs = data.get("findings", []) if isinstance(data, dict) else data
        except Exception:
            fs = []
        got = 0
        for f in fs if isinstance(fs, list) else []:
            if isinstance(f, dict) and f.get("title") in want:
                f = dict(f)
                f["first_run"] = name
                rows.append(f)
                got += 1
        if got < len(want):
            lost.append({"run": name, "pass_but_lost": len(want) - got})
    return rows, lost, no_verdicts


def run_backfill(a):
    state = a.state_dir
    os.makedirs(state, exist_ok=True)
    bf_dir = os.path.join(state, "backfill")
    os.makedirs(bf_dir, exist_ok=True)

    # Same single-run lock a normal audit takes: never interleave a backfill
    # with a live run writing the same ledger.
    lock = open(os.path.join(state, "audit.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("audit already running; backfill no-op (re-run when it finishes)")
        return 0

    for path, what in ((a.panel_bin, "panel"), (a.issue_file, "issue-file")):
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            log(f"FATAL: {what} not executable: {path}")
            return 2

    log(f"backfill: reconstructing unfiled PASS findings since {a.since}")
    stamp = os.environ.get("AUDIT_FAKE_NOW") \
        or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    now_dir = re.sub(r"[^A-Za-z0-9]", "_", stamp) if os.environ.get("AUDIT_FAKE_NOW") \
        else datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    open_issues = gh_json(["issue", "list", "-R", a.repo, "--state", "open",
                           "--json", "number,title,labels", "-L", "500"], [])
    closed_issues = gh_json(["issue", "list", "-R", a.repo, "--state", "closed",
                             "--json", "number,title,closedAt", "-L", "500"], [])
    recent_merges = gh_json(["pr", "list", "-R", a.repo, "--state", "merged",
                             "--json", "number,title", "-L", "50"], [])
    deliberate = load_deliberate(a.deliberate)

    rows, lost, no_verdicts = reconstruct(state, a.since)

    # Dedupe by signature across runs, then drop what an open or closed
    # issue already carries (exact normalised-title match; the #1212 gate
    # remains the fuzzy backstop at file time).
    seen = {}
    dupes = 0
    for f in rows:
        s = sig_of(f)
        if s in seen:
            dupes += 1
            continue
        seen[s] = f
    issued = {norm_title(i.get("title")) for i in open_issues + closed_issues
              if isinstance(i, dict)}
    issued.discard("")
    kept = []
    pre_dropped = 0
    for f in seen.values():
        if tkey(f.get("title")) in issued:
            pre_dropped += 1
            log(f"backfill dedupe-issue: open/closed issue already carries {f.get('title')}")
            continue
        kept.append(f)
    kept.sort(key=lambda f: (SEV.get(f.get("severity") or "", 3),
                             f.get("first_run") or ""))

    queue_path = os.path.join(bf_dir, f"queue-{now_dir}.jsonl")
    with open(queue_path, "w", encoding="utf-8") as fh:
        for f in kept:
            fh.write(json.dumps(f) + "\n")
    log(f"backfill reconstruct: reconstructed={len(rows)} unique={len(seen)} "
        f"dupes_across_runs={dupes} dropped_vs_issue={pre_dropped} "
        f"queue={len(kept)} lost={json.dumps(lost)} no_verdicts={json.dumps(no_verdicts)}")

    summary_path = os.path.join(bf_dir, f"summary-{now_dir}.txt")
    if not kept:
        text = (f"## Backfill summary (--backfill {a.since})\n\n"
                "Nothing to backfill.\n\n"
                f"Unreconstructed detail: reconstructed={len(rows)} "
                f"lost={json.dumps(lost)} no_verdicts={json.dumps(no_verdicts)}\n")
        open(summary_path, "w", encoding="utf-8").write(text)
        sys.stdout.write(text)
        log("backfill complete: nothing unfiled to reconstruct")
        return 0

    # Panel context mirrors the normal path: open gap-audit issues only.
    panel_issues = [
        i for i in open_issues
        if any((l.get("name") if isinstance(l, dict) else l) == "gap-audit"
               for l in (i.get("labels") or []))
    ]
    vlog = open(os.path.join(bf_dir, f"verdicts-{now_dir}.jsonl"), "a", encoding="utf-8")

    def vrec(title, verdict, reason, issue=""):
        vlog.write(json.dumps({"timestamp": stamp, "title": title, "verdict": verdict,
                               "reason": reason or "", "issue": issue, "loud": False}) + "\n")
        vlog.flush()

    duplicates = panel_fail = filed = unfiled = 0
    issue_nums = []
    for f in kept:
        title = f.get("title") or ""
        if not title:
            panel_fail += 1
            continue
        pin = {"repo": a.repo, "finding": f, "open_issues": panel_issues,
               "recent_merges": recent_merges, "deliberate_states": deliberate}
        p = subprocess.run([a.panel_bin], input=json.dumps(pin),
                           capture_output=True, text=True)
        try:
            verdict = json.loads(p.stdout)
        except Exception:
            verdict = {}
        if not isinstance(verdict, dict):
            verdict = {}
        v, rsn = verdict.get("verdict"), verdict.get("reason") or ""
        if p.returncode != 0 or not verdict:
            # A panel ERROR is transient: carry the finding over instead of
            # dropping a previously-PASS finding on a crash.
            unfiled += 1
            append_entry(a.carryover_file, f, now_dir, stamp)
            vrec(title, "ERR", f"panel error rc={p.returncode} -> carry-over")
            log(f"backfill: PANEL-ERROR rc={p.returncode} -> carry-over ({title})")
            continue
        if v != "PASS":
            panel_fail += 1
            vrec(title, v or "FAIL", rsn)
            log(f"backfill: PANEL-FAIL ({rsn}) ({title})")
            continue
        body = (f"{f.get('body') or ''}\n\n"
                f"**Evidence:** {f.get('evidence') or ''}\n\n"
                f"**Severity:** {f.get('severity') or ''}\n\n"
                f"**First audit report:** {f.get('first_run') or ''}\n\n"
                f"*Backfilled by fleet-blind-audit --backfill at {stamp}.*\n")
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as bf:
            bf.write(body)
        res = subprocess.run(
            [a.issue_file, "file", "--json", "-R", a.repo,
             "--title", f"[gap-audit] {title}", "--body-file", bf.name,
             "--label", "gap-audit", "--label", "agent-ready"],
            capture_output=True, text=True)
        os.unlink(bf.name)
        try:
            out = json.loads(res.stdout) if res.returncode == 0 else {}
        except Exception:
            out = {}
        if res.returncode == 0 and isinstance(out, dict) and out:
            url = out.get("url") or out.get("existing") or ""
            if out.get("action") == "commented":
                duplicates += 1
                vrec(title, "PASS", "deduped (#1212 gate commented)", url)
                log(f"backfill: DEDUPED existing issue carries this problem ({title})")
            else:
                filed += 1
                if url:
                    issue_nums.append(url.rsplit("/", 1)[-1])
                vrec(title, "PASS", "filed", url)
                log(f"backfill: FILED {url} ({title})")
        else:
            unfiled += 1
            append_entry(a.carryover_file, f, now_dir, stamp)
            vrec(title, "PASS", "file failed -> carry-over")
            log(f"backfill: file failed -> carry-over ({title})")
    vlog.close()

    text = (
        f"## Backfill summary (--backfill {a.since})\n\n"
        "| reconstructed | unique | dup-across-runs | issue-prefilter | panel-FAIL | duplicates(1212) | filed | unfiled |\n"
        "|---|---|---|---|---|---|---|---|\n"
        f"| {len(rows)} | {len(seen)} | {dupes} | {pre_dropped} | {panel_fail} | {duplicates} | {filed} | {unfiled} |\n\n"
        f"Filed issues:{' ' + ' '.join(issue_nums) if issue_nums else ' (none)'}\n\n"
        f"Unreconstructed detail: lost={json.dumps(lost)} no_verdicts={json.dumps(no_verdicts)}\n")
    open(summary_path, "w", encoding="utf-8").write(text)
    sys.stdout.write(text)
    if unfiled:
        carryover_total = len(load_entries(a.carryover_file))
        line = (f"LOUD [AUDIT-BACKLOG] unfiled_pass={unfiled} "
                f"carryover_total={carryover_total} context=backfill={a.since}")
        log(line)
        try:
            with open(a.triage, "a", encoding="utf-8") as tf:
                tf.write(f"{stamp} [fleet-blind-audit] {line}\n")
        except OSError:
            log(f"WARN: could not append to triage {a.triage}")
    log(f"backfill complete: reconstructed={len(rows)} duplicates={duplicates} "
        f"panel_fail={panel_fail} filed={filed} unfiled={unfiled}")
    return 0 if unfiled == 0 else 1


def main():
    ap = argparse.ArgumentParser(prog="blind-audit-carryover")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("signature")
    sub.add_parser("norm")
    for name in ("load", "append", "rewrite"):
        p = sub.add_parser(name)
        p.add_argument("--file", required=True)
        if name == "append":
            p.add_argument("--run", default="")
            p.add_argument("--now", default="")
        if name == "rewrite":
            p.add_argument("--resolved", required=True)
    b = sub.add_parser("backfill")
    b.add_argument("--since", required=True)
    home = os.environ.get("HOME", "/home/nish")
    b.add_argument("--state-dir",
                   default=os.environ.get("AUDIT_STATE_DIR",
                                          f"{home}/workspaces/agent-state/fleet-blind-audit"))
    b.add_argument("--repo", default=os.environ.get("AUDIT_REPO", "Nishfleet/fleet-ops"))
    b.add_argument("--panel-bin",
                   default=os.environ.get("AUDIT_PANEL_BIN",
                                          f"{home}/.local/bin/fleet-blind-audit-panel"))
    b.add_argument("--issue-file",
                   default=os.environ.get("FLEET_ISSUE_FILE") or os.path.join(
                       os.path.dirname(os.path.realpath(__file__)), "..", "bin", "fleet-issue-file"))
    b.add_argument("--carryover-file",
                   default=os.environ.get("AUDIT_CARRYOVER_FILE") or
                   os.path.join(os.environ.get("AUDIT_STATE_DIR",
                                               f"{home}/workspaces/agent-state/fleet-blind-audit"),
                                "carryover.jsonl"))
    b.add_argument("--triage",
                   default=os.environ.get("AUDIT_TRIAGE") or os.environ.get("FLEET_HEARTBEAT_TRIAGE") or
                   f"{home}/workspaces/agent-state/FLEET-HEARTBEAT-TRIAGE.md")
    b.add_argument("--deliberate", default="")
    a = ap.parse_args()

    if a.cmd == "signature":
        print(sig_of(json.loads(sys.stdin.read() or "{}")))
        return 0
    if a.cmd == "norm":
        for line in sys.stdin:
            n = norm_title(line)
            if n:
                print(n)
        return 0
    if a.cmd == "load":
        return cmd_load(a)
    if a.cmd == "append":
        return cmd_append(a)
    if a.cmd == "rewrite":
        return cmd_rewrite(a)
    # backfill: resolve the deliberate-states path like the organ does.
    if not (a.deliberate and os.path.isfile(a.deliberate)):
        a.deliberate = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                                    "..", "docs", "deliberate-states.md")
    return run_backfill(a)


if __name__ == "__main__":
    sys.exit(main())
