#!/usr/bin/env python3
"""Combine A truth classes (fleet-ops#7371, decision-resolved 2026-09-17).

truth(PR) = ANY of:
  (i)   review:deep label EVENT ever applied (from a-events-q*.json)  — measured: 0 in cohort
  (ii)  outcome record cites merge SHA / PR number within 7d (a-truth-class2.json)
  (iii) diff touches house high-risk classes (a-truth-class3.json)
Output: .fleet/bench7371/a-truth.json { "<pr>": {"positives": bool, "classes": [...], "evidence": {...}} }
"""
import json
from pathlib import Path

OUT = Path(".fleet/bench7371")
cohort = json.load(open(OUT / "a-cohort-certified.json"))
class2 = json.load(open(OUT / "a-truth-class2.json"))
class3 = json.load(open(OUT / "a-truth-class3.json"))

# (i) review:deep label events across the four quarter captures
class1 = set()
q_files = ["a-events-q1.json", "a-events-q2.json", "a-events-q3.json", "a-events-q4.json"]
for qf in q_files:
    d = json.load(open(OUT / qf))
    for rec in d["records"]:
        for e in rec.get("events", []):
            if e.get("event") == "labeled" and e.get("label", {}).get("name") == "review:deep":
                class1.add(rec["number"])
                break

truth = {}
for r in cohort:
    num = r["number"]
    classes, ev = [], {}
    if num in class1:
        # criterion (i) additionally requires a Greptile/CodeRabbit thread requesting a change
        # that a later commit addressed. Verified 2026-09-18 for the single class-(i) PR 3258:
        # reviews=[] and review comments=[] (REST), so no change-request thread exists -> (i) alone
        # does NOT make it a true positive. Kept in evidence with the class marked.
        if num == 3258:
            ev["i"] = "review:deep label event 2026-09-12; but 0 review threads (REST reviews/comments empty) -> criterion (i) NOT met"
        else:
            classes.append("i"); ev["i"] = "review:deep label event in history"
    if str(num) in class2:
        classes.append("ii")
        ev["ii"] = class2[str(num)]["records"]
    if str(num) in class3 and class3[str(num)]:
        classes.append("iii"); ev["iii"] = class3[str(num)]
    truth[str(num)] = {"positives": bool(classes), "classes": classes, "evidence": ev,
                       "quarter": r["quarter"]}

json.dump(truth, open(OUT / "a-truth.json", "w"), indent=0)
pos = sum(1 for v in truth.values() if v["positives"])
c2 = len(class2)
print(f"class(i) events={len(class1)} (1 met the thread condition? no — 3258 had none) class(ii)={c2} class(iii)={sum(1 for v in class3.values() if v)}")
print(f"A truth positives: {pos}/200  (prevalence {pos/2:.1f}%)")
from collections import Counter
print("per quarter:", dict(Counter(v['quarter'] for v in truth.values() if v['positives'])))
