#!/usr/bin/env python3
"""Benchmark B confusion matrix for fleet-ops#7371.

Decision number: false "auto_fixable" on truly reserved items at each threshold.
Jev outputs reservedClass (choice) + needsNish (boolean).
Reserved-verdict variants scored:
  V1: needsNish probability >= t
  V2: reservedClass != auto_fixable
Gate rule: 0 tolerated false auto_fixable on truly reserved items at the chosen
threshold; report the "send to reviewer" band size.
"""
import json
from pathlib import Path
from collections import Counter

OUT = Path(".fleet/bench7371")
labels = {("r['repo']", r["number"]): r for r in ()}  # placeholder no-op
lab_rows = [json.loads(l) for l in open(OUT / "b-labels.jsonl")]
jev_rows = [json.loads(l) for l in open(OUT / "b-jev.jsonl")]
jev = {(r["repo"], r["number"]): r for r in jev_rows}

def confusion(pred_reserved, key):
    tp = sum(1 for k in key if pred_reserved[k] and lab["truth_reserved"][key_index[k]])
    return tp

key_index = {}
lab = {}
for i, r in enumerate(lab_rows):
    k = (r["repo"], r["number"])
    key_index[k] = i
    lab[k] = r

key = [(r["repo"], r["number"]) for r in lab_rows]
truth = {k: lab[k]["truth_reserved"] for k in key}

def report(name, pred):
    tp = sum(1 for k in key if pred[k] and truth[k])
    fp = sum(1 for k in key if pred[k] and not truth[k])
    fn = sum(1 for k in key if not pred[k] and truth[k])
    tn = sum(1 for k in key if not pred[k] and not truth[k])
    false_auto = fn  # reserved items Jev called auto-fixable
    p = tp / max(1, tp + fp)
    r = tp / max(1, tp + fn)
    print(f"{name}: flag {tp+fp}/300  P={p:.2f} R={r:.2f}  FALSE-auto_fixable-on-reserved={false_auto}  (TN={tn}, FP={fp})")
    return {"flag": tp + fp, "P": round(p, 2), "R": round(r, 2), "false_auto_on_reserved": false_auto, "FP": fp, "TP": tp, "FN": fn, "TN": tn}

print("=== V1: needsNish probability thresholds")
v1 = {}
for t in (0.5, 0.7, 0.9):
    pred = {k: jev[k]["answers"]["needsNish"]["probability"] >= t for k in key}
    v1[t] = report(f"  p>={t}", pred)

print("=== V2: reservedClass != auto_fixable")
pred2 = {k: jev[k]["answers"]["reservedClass"]["choice"] != "auto_fixable" for k in key}
v2 = report("  class!=auto_fixable", pred2)

# disagreement among the two verdicts
pred2_map = {k: jev[k]["answers"]["reservedClass"]["choice"] != "auto_fixable" for k in key}
both = {k: (pred2_map[k], jev[k]["answers"]["needsNish"]["probability"] >= 0.5) for k in key}
dis = sum(1 for k in key if pred2_map[k] != both[k][1])
print(f"\nverdict disagreement (class-rule vs needsNish p>=0.5): {dis}/300")

# confusion matrix per class for the p>=0.5 verdict (needsNish)
cm = {}
for k in key:
    j = jev[k]["answers"]["reservedClass"]["choice"]
    t = lab[k]["reserved_class"] if truth[k] else "auto_fixable(truth)"
    cm.setdefault((t, j), 0)
    cm[(t, j)] += 1
print("\ntruth-class -> Jev class (top pairs):")
for (t, j), n in sorted(cm.items(), key=lambda kv: -kv[1])[:12]:
    print(f"  {t:38s} -> {j:36s} {n}")

# false-auto detail on reserved items at p>=0.5
fa = [k for k in key if truth[k] and jev[k]["answers"]["needsNish"]["probability"] < 0.5]
print(f"\nfalse-auto_fixable on reserved (p>=0.5 verdict): {len(fa)} -> {[f'{a}#{b}' for a,b in fa][:10]}")
fa7 = [k for k in key if truth[k] and jev[k]["answers"]["needsNish"]["probability"] < 0.7]
print(f"false-auto_fixable on reserved (p>=0.7 verdict): {len(fa7)}")
fa9 = [k for k in key if truth[k] and jev[k]["answers"]["needsNish"]["probability"] < 0.9]
print(f"false-auto_fixable on reserved (p>=0.9 verdict): {len(fa9)} -> {[f'{a}#{b}' for a,b in fa9][:12]}")

json.dump({"v1": {str(t): v for t, v in v1.items()}, "v2": v2}, open(OUT / "b-metrics.json", "w"), indent=0)