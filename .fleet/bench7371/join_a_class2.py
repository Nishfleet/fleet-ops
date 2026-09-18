#!/usr/bin/env python3
"""Benchmark A class-(ii) truth join for fleet-ops#7371 (decision-resolved 2026-09-17).

Outcome universe (fetched 2026-09-18, REST only):
  - 0509 issues/PRs labelled deploy-fault / repair:main-red / auto-revert
  - plus workflow-authored revert PRs: title matches
    "revert: auto-restore green main (reverts <7-40hex>)"
Citation rule (mechanical, per the decision-resolved spec): the outcome record's
title+body cites the cohort PR's merge SHA (>=7 leading hex chars) or the PR
number (#num or bare \bnum\b), and the record was created within
[mergedAt, mergedAt+7d].

Output: .fleet/bench7371/a-truth-class2.json
  { "<pr>": {"records": [{record, kind, label, created, state}], "positives": [...] }, ...}
Only PRs with >=1 in-window citation appear.
"""
import json, datetime, re
from pathlib import Path

OUT = Path(".fleet/bench7371")
REVERT_TITLE = re.compile(r"revert: auto-restore green main \(reverts ([0-9a-f]{7,40})\)")

cohort = json.load(open(OUT / "a-cohort-certified.json"))
sha_by_num = {r["number"]: (r["mergeCommit"] or "") for r in cohort}
merged_by_num = {r["number"]: r["mergedAt"] for r in cohort}

# revert PRs: titles captured 2026-09-18T10:0xZ (REST, one call per PR) -> /tmp/revert-prs.json
# bodies for revert PRs come from the same REST pulls endpoint (cached below)
universe = json.load(open("/tmp/outcome-universe.json"))
recs = {}
bodies = {}
for o in universe:
    recs[o["n"]] = {
        "record": o["n"], "kind": f"label:{o['label']}", "created": o["created"],
        "state": o.get("state"), "title": (o.get("title") or "")[:120],
    }
    bodies[o["n"]] = o.get("body") or ""

# revert PRs: titles captured 2026-09-18T10:0xZ (REST, one call per PR) -> /tmp/revert-prs.json
# (subprocess-in-script hit an intermittent keyless response; cached snapshot is the source here)
import subprocess
reverts = json.load(open("/tmp/revert-prs.json"))
for n, d in reverts.items():
    m = REVERT_TITLE.search(d["title"] or "")
    recs[int(n)] = {"record": int(n), "kind": "title:auto-revert", "created": d["created"],
               "state": d["state"], "title": d["title"][:120], "reverted_sha": (m.group(1) if m else None)}

def in_window(created, merged):
    try:
        cr = datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))
        mr = datetime.datetime.fromisoformat(merged.replace("Z", "+00:00"))
    except Exception:
        return False
    return mr <= cr <= mr + datetime.timedelta(days=7)

truth = {}
for o in recs.values():
    rev_sha = o.get("reverted_sha")
    text = (o.get("title") or "") + " " + bodies.get(o["record"], "")
    for num, sha in sha_by_num.items():
        if not o["created"]:
            continue
        if not in_window(o["created"], merged_by_num[num]):
            continue
        if rev_sha:
            cited = bool(sha) and (sha[:7] == rev_sha or sha.startswith(rev_sha))
        else:
            cited = (sha[:7] in text) or re.search(r"#%d\b" % num, text) or re.search(r"\b%d\b" % num, text)
        if cited:
            truth.setdefault(str(num), {"records": [], "positives": []})
            row = {"record": o["record"], "kind": o["kind"], "created": o["created"], "state": o["state"]}
            if row not in truth[str(num)]["records"]:
                truth[str(num)]["records"].append(row)
            truth[str(num)]["positives"].append(o["record"])

truth = {k: v for k, v in sorted(truth.items(), key=lambda kv: int(kv[0]))}
json.dump(truth, open(OUT / "a-truth-class2.json", "w"), indent=0)
print("class2 positive PRs:", len(truth))
for k, v in truth.items():
    print(" ", k, [r["record"] for r in v["records"]], [r["kind"] for r in v["records"]])
