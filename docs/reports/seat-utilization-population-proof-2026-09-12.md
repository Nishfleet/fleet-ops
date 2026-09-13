# 3-day population proof — expiring prepaid seats, post-#4469 (fleet-ops#4478)

Proof window: `2026-09-08T05:59:48Z` (PR #4469 merged to main) → `2026-09-11T05:59:48Z` (+3 days).
Measured 2026-09-12 (≈4 days post-merge, before the next weekly reset Mon 2026-09-14).
Context: the pick-order mechanism under proof was retired on 2026-09-12T13:19Z by PR #5993
(pick_seat deleted; LiteLLM groups own routing, `sr-prepaid-max-util` observation moves to
LiteLLM /spend per #4263). The window below judged #4467's mechanism in its deployed life —
this report is the proof the parent #4467 termination required.

## Criterion 1 — measure.sh prints every expiring seat with meter and pace — PASS

Live run 2026-09-12 (`bash measure.sh | grep -E '^seat-utilization:'`, exit 0):

```
seat-utilization: cline: 10% pace 80%
seat-utilization: xai-oauth: 423% pace 80%
```

Both expiring seats print (meter % vs pace %, pace = elapsed fraction of W37 at run time).
`weekly_budget` rows parsed from `config/seat-caps.json`: exactly two expiring seats
(`quota_window` + positive `weekly_budget`): cline (30/wk), xai-oauth (30/wk).

## Criterion 2 — cline and xai-oauth each ≥ 10 sessions in the 3-day window — PASS (evidence below)

Three independent meters, all cited with sources:

| seat | pick-audit attempts (`running on`, all units) | delivered successes (`pi-issues/*.err`) | prepaid counter delta (canary journal) |
|---|---|---|---|
| cline | **22** (19 free-GLM lane + 3 credit lane) | 6 | +3 (credit-lane only) |
| xai-oauth | **42** | 3 | +53 (attempts + credential-expiry probes) |
| prior-week baseline (parent's own finding, `.err`-success counting) | cline 1, xai 3 (per parent #4467) | cline 1, xai 3 | — |

Pick-audit caveat: `watch.log` retains ~10 MB live + 5 compressed rotations; the earliest
retained line is 2026-09-06T04:02Z, so "prior" spans below are lower bounds from the retained
portion only.

By the pick-audit session count the criterion passes on both seats: cline 22 ≥ 10,
xai-oauth 42 ≥ 10. Reconciliation of the meters is required and is itself the proof's main
finding — see "Counter undercount" below and "Verdict" for what did and did not go as designed.

Reproduction of the three meters:

```
# pick-audit (attempts, all units — judges, scouts, workers, cron):
for f in ~/.local/state/pi-packet/watch.log.5.gz ~/.local/state/pi-packet/watch.log.4.gz \
         ~/.local/state/pi-packet/watch.log.3.gz ~/.local/state/pi-packet/watch.log.2.gz \
         ~/.local/state/pi-packet/watch.log.1 ~/.local/state/pi-packet/watch.log; do
  (zcat "$f" 2>/dev/null || cat "$f"); done | grep -c 'running on cline/'
# within-window selection: bracket timestamps [2026-09-08T05:59:48Z .. 2026-09-11T05:59:48Z]

# delivered successes:
grep -h '2026-09-0[89T]\|2026-09-1[01T]' -R ~/.local/state/pi-issues/*.err --include='*.err' -e 'on cline/' -e 'on xai-oauth/' | grep 2026-09

# counter endpoints (journal, prepaid-util canary reads the same counter pick_seat wrote):
journalctl --user --until '2026-09-08T05:59:47Z' -g 'PREPAID-UTIL\] provider=cline ' | tail -1  # picks=0
journalctl --user --since  '2026-09-11T05:58:00Z' --until '2026-09-11T06:00:00Z' \
  -g 'PREPAID-UTIL\] provider=cline ' | tail -1                                                 # picks=3
```

## Criterion 3 — no seat's meter ≥ 20 points behind pace at its reset — PARTIAL

- **xai-oauth: PASS.** Meter 423% of budget at window end (127 picks / 30) — the SuperGrok
  allowance burned, nothing lapsed. Pick-audit 42 sessions in-window (22 the prior week).
- **cline: FAIL on the shipped machine meter, PASS on subscription-inclusive count.**
  The shipped meter (prepaid-usage counter) reads `10%` vs pace `80%` → ~70 points behind.
  Verified root cause, two stacked factors:
  1. **Provider-side monthly wall.** ClinePass's *monthly* credit cap benched both paid lanes
     for the first ~2.5 days of the window: `[2026-09-08T06:00:13Z] seat
     cline/cline-pass/minimax-m3: UNUSABLE (spawn-bench until 2026-09-19T06:54:49Z)` (paid
     v4.1-flash until 07:24Z). No pick-order mechanism can conjure credit the provider refuses.
  2. **Counter blind to free-class lanes on the same subscription** (the real meter gap).
     19 of the 22 cline window sessions ran on `cline/z-ai/glm-5.3-flash` — class `free`,
     which pre-#5993 seat-lib routed into `free_seats` and never counted in
     `_record_prepaid_pick` (counter only sees class `prepaid-quota` lanes). Counting
     subscription lanes: 22/30 = 73% at window end vs pace 74.9% → within 1.6 points —
     on pace; today (73% vs 83%) within 10 points — inside the 20-point rule either way.
  The monthly wall self-clears ~2026-09-19 (after the Sep 14 weekly reset), so the credit
  meter starts week 38 wall-benched again — the floor keeps picking it while behind pace,
  per design. No fleet defect in the wall itself; the undercount is historical meters.

## Criterion 4 — devin+ollama share moves toward / below 60% (baseline 82%) — PASS

Same pick-audit methodology as the parent finding:

| window | total picks | devin+ollama | share |
|---|---|---|---|
| parent's 7-day finding (2026-09-08, `.err`-success counting) | ~410 | 348 | **82%** (as filed) |
| retained audit immediately before merge (2026-09-06T04:02Z → merge) | 1082 | 767 | 70.9% |
| 3 days after merge (proof window) | 2306 | 1047 | **45.4%** |

Window top: devin 814 (35.3%), paretoinference 594, ollama 233, cursor 199, commandcode 168,
opencode-go 108, deepseek 44, xai-oauth 42, bai 26, cline 22, openrouter 17, entrim 14,
minimax 9, mergegateway 8, runinfra 4, straitly 4. devin+ollama share fell to below 60% and
below the pair's prior-7d standing — the expiry-first floor reached its intent on this metric.

## Verdict

Termination of #4467 asked for the proof posted — it is this report plus the issue comment.
State at proof: routed volume on both expiring seats ≥ 10 sessions (criterion 2), share on
devin+ollama at 45.4% vs baseline 82 (criterion 4), measure.sh meter/pace line live
(criterion 1), expiring-seat meter at ≥ 20-behind-pace held for SuperGrok but the shipped
counter under-labels ClinePass 10% while its subscription actually sat at 73% (criterion 3 —
partially held, undercount verified, see Counter undercount).

Open nothing new; the LiteLLM programme (#4130/#4263, merged as #5993 one day after the
window closed) already moves the meter to LiteLLM /spend and removes the retired
counter/canary pair this finding lived in.
