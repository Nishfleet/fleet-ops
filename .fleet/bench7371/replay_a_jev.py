#!/usr/bin/env python3
"""Benchmark A Jev replay for fleet-ops#7371 (decision-resolved 2026-09-17).

Per cohort PR, state = title + body (capped) + changed file list (capped) + diffstat.
One jev-eval call with the three decision-resolved questions:
  needsDeepReview (boolean), riskClass (choice: deps/docs/auth/db/feature/infra/test),
  blastRadius (score 0-4).
Rows are tagged with the cohort quarter. Resume-safe: PRs already present in
.fleet/bench7371/a-jev.jsonl are skipped. Receipts also land in the helper's
own JSONL under site benchmark-7371-benchA with ref Nishfleet/0509#<pr>.

Usage: python3 replay_a_jev.py [q1|q2|q3|q4|all]
"""
import json, subprocess, sys, time
from pathlib import Path

OUT = Path(".fleet/bench7371")
REPO = "Nishfleet/0509"
JEV = "/home/nish/.local/bin/jev-eval"
CAP_USD = "1.2"  # host-shared counter; packet's own rows are tallied separately in the report

QUESTIONS = {
    "needsDeepReview": {"type": "boolean",
        "instructions": "Does this PR warrant a rationed paid deep code review (review:deep)? Judge from the state: does it touch money, auth, secrets, database/migrations, deploy pipelines, or is it a large or subtle change where a silent defect would be costly? Trivial, mechanical or docs-only changes do not."},
    "riskClass": {"type": "choice",
        "criteria": {"deps": "dependency/lockfile bump only", "docs": "documentation only",
                     "auth": "auth, sessions, secrets, permissions", "db": "database, schema or migrations",
                     "feature": "product feature or behaviour change", "infra": "CI, deploy or infrastructure",
                     "test": "tests only"},
        "instructions": "Which single risk class best describes this change?"},
    "blastRadius": {"type": "score",
        "criteria": ["trivial/cosmetic, no behaviour change", "local single-module change", "several modules or API surface", "cross-subsystem or user-visible behaviour", "whole-product/deploy/money path"],
        "instructions": "Blast radius 0-4 for this change (see levels)."},
}

def state_for(r):
    files = r["files"]
    shown = files[:40]
    lines = [f"- {f['filename']} (+{f['additions']}/-{f['deletions']})" for f in shown]
    if len(files) > len(shown):
        lines.append(f"... and {len(files)-len(shown)} more files")
    body = (r.get("body") or "")[:1200]
    return (f"PR #{r['number']} in Nishfleet/0509 (merged {r['mergedAt']})\n"
            f"Title: {r['title']}\n\nBody:\n{(r.get('body') or '')[:1200]}\n\n"
            f"Changed files ({r['changedFiles']}):\n" + "\n".join(lines) +
            f"\nDiffstat: {r['changedFiles']} files, +{r['additions']}/-{r['deletions']}")

out_file = OUT / "a-jev.jsonl"
done_prs = set()
if out_file.exists():
    for line in out_file.read_text().splitlines():
        try:
            done = json.loads(line)
            done_prs.add(done["pr"])
        except Exception:
            pass

scope = sys.argv[1] if len(sys.argv) > 1 else "all"
cohort = json.load(open(OUT / "a-cohort-certified.json"))
todo = [r for r in cohort if (scope == "all" or r["quarter"] == int(scope[1:])) and r["number"] not in done_prs]
print(f"to replay: {len(todo)} (already done: {len(done_prs)})", flush=True)

ms = 0
for i, r in enumerate(todo):
    payload = json.dumps({
        "state": state_for(r),
        "questions": QUESTIONS,
        "site": "benchmark-7371-benchA",
        "ref": f"Nishfleet/0509#{r['number']}",
    })
    p = subprocess.run([JEV, "--site", "benchmark-7371-benchA", "--ref", f"Nishfleet/0509#{r['number']}",
                        "--cap-usd", CAP_USD], input=payload, capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        print(f"JEV FAIL pr={r['number']} rc={p.returncode} {p.stderr[:160]}", flush=True)
        if p.returncode == 3:
            sys.exit("spend cap reached — stop here, resume later")
        continue
    try:
        d = json.loads(p.stdout)
    except json.JSONDecodeError:
        print(f"JEV BADJSON pr={r['number']} {p.stdout[:120]}", flush=True)
        continue
    row = {"pr": r["number"], "quarter": r["quarter"], "mergedAt": r["mergedAt"],
           "answers": d.get("answers"), "ms": d.get("ms"), "usage": d.get("usage"),
           "state_sha256": d.get("state_sha256")}
    with open(out_file, "a") as fh:
        fh.write(json.dumps(row) + "\n")
    ms += d.get("ms") or 0
    if (i + 1) % 25 == 0:
        print(f"{i+1}/{len(todo)} done (avg {ms//(i+1)}ms)", flush=True)
print("DONE", len(todo))
