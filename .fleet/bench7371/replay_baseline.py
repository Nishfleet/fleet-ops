#!/usr/bin/env python3
"""Offline replay of the 0509 review-gate.yml risk classifier over the A cohort.

Faithful port of the classifier step (fetched 2026-09-18 from
repos/Nishfleet/0509/contents/.github/workflows/review-gate.yml at main HEAD,
134 lines). Budget bar is replayed per-PR with the month's actual spend at the
PR's creation time recomputed from the cohort itself: spend = count of earlier
cohort PRs in the same calendar month that the gate would have flagged
(this mirrors the gate's own search count of review:deep labels).
The real gate ran against live search counts; we approximate them from cohort
order, which is exact for a cohort that IS the month's merged PRs (September).
Output: .fleet/bench7371/a-baseline.json { "<pr>": {"level", "why", "spend", "ratio"} }
"""
import json, datetime
from pathlib import Path

OUT = Path(".fleet/bench7371")
cohort = json.load(open(OUT / "a-cohort-certified.json"))

CRITICAL = ("auth", "oauth", "session", "password", "secret", "token", "credential",
            "permission", "rbac", "billing", "payment", "stripe", "checkout",
            "subscription", "invoice", "refund", "migration", "migrations",
            "/schema", "d1/", "prisma/", "drizzle/", ".github/workflows/")
BROAD = ("api/", "server/", "worker", "wrangler", "middleware", "deploy", "release")
LOCKFILES = ("package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock")
DOCS = (".md", ".mdx", ".txt", ".rst", ".adoc")
MONTHLY_CAP = 30

def classify(files):
    rows = [(f["filename"], f["additions"], f["deletions"]) for f in files]
    names = [r[0] for r in rows]
    churn = sum(a + d for _, a, d in rows)
    lower = [n.lower() for n in names]

    def any_hit(hints):
        return [n for n in lower if any(h in n for h in hints)]

    critical = any_hit(CRITICAL)
    broad = any_hit(BROAD)
    locks = any_hit(LOCKFILES)

    if not names:
        level, why = "low", "no files changed"
    elif all(n.endswith(DOCS) for n in names):
        level, why = "low", "docs only"
    elif locks and len(names) <= 3:
        level, why = "normal", "dependency bump only"
    elif critical:
        level, why = "critical", "touches " + ", ".join(sorted(set(critical))[:3])
    elif len(names) >= 25 or churn >= 2000:
        level, why = "high", f"large diff: {len(names)} files, {churn} lines"
    elif broad and churn >= 400:
        level, why = "high", f"substantial server-side change: {churn} lines"
    else:
        level, why = "normal", "ordinary diff"
    return level, why

# order cohort oldest->newest within its month to replay the budget counter
by_asc = sorted(cohort, key=lambda r: r["mergedAt"])
spent = 0
baseline = {}
cur_month = None
for r in by_asc:
    m = r["mergedAt"][:7]
    if m != cur_month:
        cur_month = m
        spent = 0  # gate counts review:deep labels per calendar month
    level, why = classify(r["files"])
    ratio = spent / MONTHLY_CAP
    if ratio < 0.5:
        bar = {"critical", "high"}
    elif ratio < 0.85:
        bar = {"critical"}
    else:
        bar = set()
    spend = level in bar
    if spend:
        spent += 1
    baseline[str(r["number"])] = {"level": level, "why": why, "spend": spend, "ratio": round(ratio, 3)}

json.dump(baseline, open(OUT / "a-baseline.json", "w"), indent=0)
flagged = sum(1 for v in baseline.values() if v["spend"])
print(f"baseline flag-rate: {flagged}/200 = {flagged/2:.1f}%")
from collections import Counter
print("levels:", dict(Counter(v["level"] for v in baseline.values())))