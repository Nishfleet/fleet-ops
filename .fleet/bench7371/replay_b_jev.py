#!/usr/bin/env python3
"""Benchmark B Jev replay for fleet-ops#7371 (decision-resolved 2026-09-17).

Per corpus item, state = PRE-DECISION text (title + body + comments before the
first nish3451 / decision-resolved comment) + the canonical reserved-classes
list. Questions:
  reservedClass (choice over the canonical reserved classes + auto_fixable)
  needsNish (boolean)
Jev never sees the truth labels. Receipts: helper JSONL site
benchmark-7371-benchB ref Nishfleet/<repo>#<n>; local rows .fleet/bench7371/b-jev.jsonl.
Resume-safe on existing rows.
"""
import json, subprocess, sys
from pathlib import Path

OUT = Path(".fleet/bench7371")
JEV = "/home/nish/.local/bin/jev-eval"
CAP_USD = "1.2"

CANONICAL = ("Canonical reserved classes (Nish's vault, verbatim): money/pricing; privacy; security; "
             "legal; brand; product direction; customer-data deletion; destructive/irreversible steps; "
             "authority Nish explicitly reserved. Anything outside those classes is auto_fixable — "
             "a worker or the orchestrator may handle it without Nish.")

QUESTIONS = {
    "reservedClass": {"type": "choice",
        "criteria": {
            "money/pricing": "payments, pricing, spend caps, paid upgrades, budgets",
            "privacy": "personal data handling, GDPR, PII exposure",
            "security": "secrets, credentials, auth bypasses, vulnerabilities",
            "legal": "licenses, terms, trademark, copyright, DMCA",
            "brand": "naming, public-facing tone, domains, logos",
            "product direction": "roadmap, scope, positioning, what to build next",
            "customer-data deletion": "deleting or purging customer/user data",
            "destructive/irreversible steps": "irreversible or destructive operations (prod migrations, rm -rf, drops)",
            "authority Nish explicitly reserved": "explicitly reserved by Nish but not one of the named classes",
            "auto_fixable": "safe for an agent or the orchestrator to handle; none of the reserved classes apply",
        },
        "instructions": "Which single class best describes who must decide this item?"},
    "needsNish": {"type": "boolean",
        "instructions": "Must Nish personally decide or approve this (any reserved class), or is it auto_fixable (agents/orchestrator handle it)?"},
}

out_file = OUT / "b-jev.jsonl"
done = set()
if out_file.exists():
    for line in out_file.read_text().splitlines():
        try:
            done.add((json.loads(line)["repo"], json.loads(line)["number"]))
        except Exception:
            pass

rows = [json.loads(l) for l in open(OUT / "b-labels.jsonl")]
todo = [r for r in rows if (r["repo"], r["number"]) not in done]
print(f"to replay: {len(todo)} (done: {len(done)})", flush=True)

ms = 0
for i, r in enumerate(todo):
    state = f"{CANONICAL}\n\nIssue {r['repo']}#{r['number']}:\n{r['pre_text'][:5000]}"
    payload = json.dumps({
        "state": state,
        "questions": QUESTIONS,
        "site": "benchmark-7371-benchB",
        "ref": f"{r['repo']}#{r['number']}",
    })
    p = subprocess.run([JEV, "--site", "benchmark-7371-benchB", "--ref", f"{r['repo']}#{r['number']}",
                        "--cap-usd", CAP_USD], input=payload, capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        print(f"JEV FAIL {r['repo']}#{r['number']} rc={p.returncode} {p.stderr[:140]}", flush=True)
        if p.returncode == 3:
            sys.exit("spend cap reached — stop, resume later")
        continue
    try:
        d = json.loads(p.stdout)
    except json.JSONDecodeError:
        print(f"JEV BADJSON {r['repo']}#{r['number']}", flush=True)
        continue
    row = {"repo": r["repo"], "number": r["number"], "control": r["control"],
           "answers": d.get("answers"), "ms": d.get("ms"), "usage": d.get("usage"),
           "state_sha256": d.get("state_sha256")}
    with open(out_file, "a") as fh:
        fh.write(json.dumps(row) + "\n")
    ms += d.get("ms") or 0
    if (i + 1) % 50 == 0:
        print(f"{i+1}/{len(todo)} (avg {ms//(i+1)}ms)", flush=True)
print("DONE", len(todo))