#!/usr/bin/env python3
"""Cohort A fetcher for fleet-ops#7371 benchmark A.

Cohort per the decision-resolved rule (2026-09-17): the 200 most recently MERGED
Nishfleet/0509 PRs before 2026-09-17T00:00Z. Search ranks candidates; each
candidate is then verified with the authoritative pulls REST endpoint
(merged_at, merge_commit_sha, changed_files, additions, deletions) and the top
200 are re-sorted LOCALLY by merged_at. files[] (filename/additions/deletions)
is fetched paginated for the risk-rule baseline and the Jev state.
"""
import json, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

OUT = Path(".fleet/bench7371")
REPO = "Nishfleet/0509"
CUTOFF = "2026-09-17T00:00:00Z"
N = 200

def gh(args, retries=3):
    for i in range(retries):
        r = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
        if r.returncode == 0:
            return r.stdout
        err = r.stderr.strip()[:200]
        if "rate limit" in err.lower():
            time.sleep(60)
            continue
        time.sleep(2 + 3 * i)
    print(f"GH FAIL: {args[:3]} -> {err}", file=sys.stderr)
    return None

# 1) candidate numbers from search (server-ranked newest-merged first)
cands = []
for page in (1, 2, 3, 4):
    out = gh(["-X", "GET", "search/issues",
              "-f", f"q=repo:{REPO} is:pr is:merged merged:<{CUTOFF}",
              "-f", "sort=merged-desc", "-f", "order=desc",
              "-f", "per_page=100", "-f", f"page={page}",
              "--jq", ".items[] | {number, title, body, search_merged: .pull_request.merged_at}"])
    if out is None:
        sys.exit(f"search page {page} failed")
    rows = [json.loads(l) for l in out.splitlines() if l.strip()]
    cands += rows
    print(f"page {page}: {len(rows)} (total so far {len(cands)})", flush=True)

# 2) verify each candidate with the pulls endpoint, fetch diffstat
def verify(c):
    num = c["number"]
    out = gh(["repos/Nishfleet/0509/pulls/%d" % num,
              "--jq", "{number, title, body, mergedAt: .merged_at, mergeCommit: .merge_commit_sha, changedFiles: .changed_files, additions, deletions}"])
    if out is None:
        return None
    d = json.loads(out)
    if not d.get("mergedAt") or d["mergedAt"] >= CUTOFF:
        return None
    fl = gh(["--paginate", f"repos/Nishfleet/0509/pulls/{num}/files",
             "--jq", ".[] | {filename, additions, deletions}"])
    files = []
    if fl:
        for l in fl.splitlines():
            if l.strip():
                try:
                    files.append(json.loads(l))
                except json.JSONDecodeError:
                    pass
    d["files"] = files
    d["body"] = (d.get("body") or "")[:20000]
    return d

verified = []
with ThreadPoolExecutor(max_workers=4) as ex:
    for i, d in enumerate(ex.map(verify, cands)):
        if d is not None:
            verified.append(d)
        if (i + 1) % 50 == 0:
            print(f"verified {i+1}/{len(cands)}", flush=True)

# 3) local sort by authoritative merged_at, take top N
seen, uniq = set(), []
for d in sorted(verified, key=lambda x: x["mergedAt"], reverse=True):
    if d["number"] in seen:
        continue
    seen.add(d["number"])
    uniq.append(d)
top = uniq[:N]
assert len(top) == N, f"only {len(top)} verified PRs"
print("cohort range:", top[-1]["mergedAt"], "->", top[0]["mergedAt"])
print("mature (7d window ended by 2026-09-17T18:15Z):",
      sum(1 for t in top if t["mergedAt"] <= "2026-09-10T18:15:00Z"))
json.dump(top, open(OUT / "a-cohort.json", "w"))
print("wrote", OUT / "a-cohort.json")
