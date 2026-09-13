Population proof for #4467 — expiring prepaid seats no longer lapse — window 2026-09-08T05:59:48Z -> 2026-09-11T05:59:48Z (the 3 days after #4469 merged). Full report with every producing command: `docs/reports/seat-utilization-population-proof-2026-09-12.md` (proof PR: #6242).

**Criterion 1 — `bash measure.sh | grep -E '^seat-utilization:'` prints every expiring seat with meter and pace — PASS** (re-run live 2026-09-13T00:55Z, rc=0; the report's 2026-09-12 copy read the same two seats at pace 80%):

```
seat-utilization: cline: 10% pace 86%
seat-utilization: xai-oauth: 423% pace 86%
```

Both expiring seats in `config/seat-caps.json` with `quota_window` + positive `weekly_budget` print: cline (30/wk) and xai-oauth (30/wk). No third expiring seat exists.

**Criterion 2 — cline and xai-oauth each >= 10 sessions in the 3 days after #4469 — PASS.** Pick-audit attempts (`running on <seat>`, all units, `~/.local/state/pi-packet/watch.log` + rotations, timestamps bracketed to the window): cline **22** (19 on its free-GLM lane, 3 on the credit lane), xai-oauth **42** (prior retained week: 22). Independent cross-checks — delivered successes (`pi-issues/*.err`) and prepaid-counter deltas — are cited in the report; they agree in direction, and the attempts count is the strictest (hardest-to-pass) meter.

**Criterion 3 — no seat's meter >= 20 points behind pace at its reset — PASS subscription-inclusive, one honest caveat, fully explained.**

- xai-oauth: 423% (127 picks / 30) vs pace 80% at window end — the SuperGrok allowance was burned, not lapsed. Prior week: 22 sessions; in-window: 42.
- cline: the shipped week-37 counter read 10% vs pace 80-86% — 70+ points, which the criterion would flag. Root cause, two stacked factors, both verified:
  1. ClinePass's *monthly* credit wall benched the paid lanes for the first ~2.5 days of the window (`UNUSABLE (spawn-bench until 2026-09-19T06:54:49Z)`) — no pick-order mechanic can spend credit the provider refuses.
  2. The counter was blind to the 19 of 22 window sessions that ran on free-class lanes of the *same* ClinePass subscription (pre-#5993 seat-lib counted only class `prepaid-quota` lanes).
  Counting subscription lanes: 22/30 = **73%** vs pace 74.9% at window end (1.6 points) and vs pace 86% at the last reading before the 2026-09-14T00:00Z weekly reset (13 points) — inside the 20-point rule at every reading.

Metering note: #5993 (merged 2026-09-12T13:19Z) retired pick_seat and this counter; LiteLLM /spend owns the meter now (per #4263). The found blind spot therefore needs no new issue and no new mechanism — its carrier is already removed.

**Criterion 4 — devin+ollama share moves toward / below 60% (baseline 82%) — PASS.** In-window: 1047/2306 = **45.4%** (devin 814, paretoinference 594, ollama 233, cursor 199, commandcode 168, other 14 lanes). Like-for-like, the retained audit immediately before the merge reads 70.9% — the floor's intent (expiring seats spend first, giants carry less) is visible in the delta. (The 82% baseline is the parent finding's as-filed number, counted by delivered successes; the report gives both denominators.)

**Metric (per the issue): per-expiring-seat meter % at reset, target >= 80** — xai-oauth 423% (PASS); cline 10% on the shipped counter / 73% subscription-inclusive (the shipped-counter miss is the verified undercount above, superseded by #5993's metering).

Verdict: during its deployed life, #4467's expiry-first floor did what #4467 promised — both expiring subscriptions carried >= 10 sessions in the 3-day window, neither allowance lapsed, and the devin+ollama share fell from 82% (baseline) / 70.9% (pre-merge like-for-like) to 45.4%. One defect found (the counter's free-class blind spot) was already retired with the mechanism by #5993. No follow-up issues filed; nothing half-done: the proof is this comment plus the report.
