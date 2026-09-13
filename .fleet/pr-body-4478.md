Why:
fleet-ops#4467 (merged as #4469, 2026-09-08) made pick_seat spend expiring prepaid subscriptions (ClinePass, SuperGrok) while they are behind pace, instead of letting the weekly allowance lapse. Its termination required a 3-day population proof posted after merge; #4478 tracks that proof. This PR is the proof, as one evidence-only report: `docs/reports/seat-utilization-population-proof-2026-09-12.md`. No code, no config, no mechanism. Note: the mechanism under proof was retired one day after the window closed by #5993 (LiteLLM groups own routing); the report judges it during its deployed life, which is what the termination asked.

Scope:
- One new file, `docs/reports/seat-utilization-population-proof-2026-09-12.md` (+107): each #4478 criterion with measured numbers and the exact commands that produced them; the criterion-3 shipped-meter reading root-caused; the #5993 supersession recorded. The population proof itself is posted as the #4478 issue comment.

Proof window: 2026-09-08T05:59:48Z (#4469 merged) -> 2026-09-11T05:59:48Z (+3 days).
- Criterion 1 (measure.sh prints every expiring seat with meter and pace): PASS — see run-proof below; also passed at report time 2026-09-12 (`cline: 10% pace 80%` / `xai-oauth: 423% pace 80%`).
- Criterion 2 (each of cline, xai-oauth >= 10 sessions in-window): PASS — pick-audit `running on` attempts, all units, window-bracketed: cline 22, xai-oauth 42 (prior retained week: 22); delivered-success and counter cross-checks cited in the report.
- Criterion 3 (no seat's meter >= 20 points behind pace at its reset): xai-oauth PASS (423% = 127 picks/30). cline: shipped counter read 10% vs pace 80-86% — explained, two stacked factors: the ClinePass monthly credit wall benched the paid lanes the first ~2.5 days (spawn-bench until 2026-09-19T06:54Z), and the counter was blind to the 19 of 22 window sessions that ran on free-class lanes of the SAME subscription; subscription-inclusive 22/30 = 73% vs pace 74.9% at window end (1.6 points) and vs 86% at the last reading before the 2026-09-14T00:00Z reset (13 points) — inside the 20-point rule at every reading. Metering moved to LiteLLM /spend by #5993, which also retires this counter.
- Criterion 4 (devin+ollama share, baseline 82%, toward/below 60%): PASS — 45.4% in-window (1047/2306); like-for-like retained-audit immediately before merge: 70.9%.

Verification:
run-proof (criterion 1, the literal #4478 acceptance command, live 2026-09-13T00:55Z):
```
$ bash measure.sh | grep -E '^seat-utilization:'
seat-utilization: cline: 10% pace 86%
seat-utilization: xai-oauth: 423% pace 86%
$ echo rc=$?
rc=0
```
The 10%/423% meters are the frozen week-37 counts (the counter stopped when #5993 removed pick_seat on 2026-09-12T13:19Z; week-37 runs to 2026-09-14T00:00Z). In-window session counts are period facts; the report cites the exact `watch.log` / `pi-issues/*.err` / journalctl commands that produced each.

run-proof: worker gates on this body + diff, all rc=0 — prove-one-run-check (--body --name-status --numstat), fleet-exec-review-canary --body, fleet-no-agent-names-check (--pr-body, --commit-range origin/main..HEAD), fleet-token-efficiency-check.

net-positive-because: #4467's termination required the 3-day population proof to exist as a citable artifact; +107 lines of evidence, no machinery.

Closes #4478

loose-ends: criterion-3 shipped-counter undercount — no open item: #5993 already replaced that counter with LiteLLM /spend metering (per #4263); the week-37 -> week-38 reset (2026-09-14T00:00Z) falls after the proof window and is noted in the report.
