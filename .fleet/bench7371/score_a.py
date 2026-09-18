#!/usr/bin/env python3
"""Benchmark A scoring: Jev thresholds vs truth vs the replayed risk-rule baseline.

Reads .fleet/bench7371/{a-jev.jsonl, a-truth.json, a-baseline.json}.
Decision-resolved gate: go iff some threshold has flag-rate <= 25% AND recall on
class (ii) >= the current rules' recall on class (ii).
Writes .fleet/bench7371/a-metrics.json and prints the metric table used by
docs/jev-benchmark-2026-09.md.
"""
import json
from pathlib import Path
from collections import Counter

OUT = Path(".fleet/bench7371")
jev = {r["pr"]: r for r in (json.loads(l) for l in open(OUT / "a-jev.jsonl"))}
truth = json.load(open(OUT / "a-truth.json"))
baseline = json.load(open(OUT / "a-baseline.json"))

nums = sorted(truth, key=int)
y = {n: truth[n]["positives"] for n in nums}
c2 = {n: bool(truth[n]["evidence"].get("ii")) for n in nums}

base_flags = {n: baseline[n]["spend"] for n in nums}
base_tp = sum(1 for n in nums if base_flags[n] and y[n])
base_fp = sum(1 for n in nums if base_flags[n] and not y[n])
base_fn = sum(1 for n in nums if not base_flags[n] and y[n])
base_rec_c2 = (sum(1 for n in nums if base_flags[n] and c2[n]) /
               max(1, sum(1 for n in nums if c2[n])))
print(f"BASELINE (risk rules): flag {sum(base_flags.values())}/200 ({sum(base_flags.values())/2:.1f}%)  "
      f"P={base_tp/max(1,base_tp+base_fp):.2f} R={base_tp/max(1,base_tp+base_fn):.2f}  recall(ii)={base_rec_c2:.2f}")

print("\nJEV needsDeepReview thresholds:")
rows = []
for t in (0.5, 0.7, 0.9):
    flags = {n: (jev[int(n)]["answers"]["needsDeepReview"]["probability"] >= t) for n in nums}
    tp = sum(1 for n in nums if flags[n] and y[n])
    fp = sum(1 for n in nums if flags[n] and not y[n])
    fn = sum(1 for n in nums if not flags[n] and y[n])
    rec_c2 = sum(1 for n in nums if flags[n] and c2[n]) / max(1, sum(1 for n in nums if c2[n]))
    fr = sum(flags.values()) / 2
    p = tp / max(1, tp + fp)
    r = tp / max(1, tp + fn)
    rows.append((t, sum(flags.values()), p, r, rec_c2))
    print(f"  p>={t}: flag {sum(flags.values())}/200 ({sum(flags.values())/2:.1f}%)  P={p:.2f} R={r:.2f}  recall(ii)={rec_c2:.2f}")

buckets = {}
for n in nums:
    p = jev[int(n)]["answers"]["needsDeepReview"]["probability"]
    b = min(int(p * 10), 9)
    buckets.setdefault(b, [0, 0])
    buckets[b][0] += 1
    if y[n]:
        buckets[b][1] += 1
print("\ncalibration buckets (needsDeepReview): bucket -> n / positives")
for b in sorted(buckets):
    n, pos = buckets[b]
    print(f"  {b/10:.1f}-{(b+1)/10:.1f}: {n} PRs, {pos} positive, pos-rate {pos/n:.2f}")

print("\nriskClass distribution:", dict(Counter(jev[int(n)]["answers"]["riskClass"]["choice"] for n in nums)))

import statistics
br = [jev[int(n)]["answers"]["blastRadius"]["score"] for n in nums]
br_c2 = [jev[int(n)]["answers"]["blastRadius"]["score"] for n in nums if c2[n]]
br_ok = [jev[int(n)]["answers"]["blastRadius"]["score"] for n in nums if not c2[n]]
print(f"blastRadius mean: all {statistics.mean(br):.2f}, class(ii) {statistics.mean(br_c2):.2f}, rest {statistics.mean(br_ok):.2f}")

go = any(fr / 200 <= 0.25 and rec_c2 >= base_rec_c2 for _, fr, _, _, rec_c2 in rows)
print(f"\nGO check (flag<=25% AND recall(ii)>=baseline {base_rec_c2:.2f}):", "GO" if go else "NO-GO")
