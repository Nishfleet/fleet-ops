# Jev replay benchmark, 2026-09 (fleet-ops#7371)

Scored 2026-09-18 from committed files under `.fleet/bench7371/`. Numbers below are `python3 .fleet/bench7371/score_a.py` and `python3 .fleet/bench7371/score_b.py` output, plus latency/token sums from `a-jev.jsonl` / `b-jev.jsonl`, plus `.fleet/bench7371/b-relabel-metrics.json` and `~/.local/state/pi-packet/jev/spend.json`. No gate, timer, hook, or config was wired.

Price used for cost: issue #7371 / epic #7370 listed rate **$0.042 / MTok in, $0 out**.

## Cohort (Benchmark A)

Source: `.fleet/bench7371/a-cohort-certified.json`. 200 unique merged Nishfleet/0509 PRs, four quarters of 50, merge-ordered. `mergedAt` range 2026-09-11T22:04:58Z … 2026-09-14T18:32:08Z.

Truth (`.fleet/bench7371/a-truth.json`, union of classes): **85/200 positives (42.5%)**.

- class (i) `review:deep` label event: 1 PR (#3258); join notes 0 review threads, criterion (i) **not met** → **0 class-(i) positives**
- class (ii) post-merge outcome within 7d: **47**
- class (iii) high-risk paths: **51**

### Quarter 1 (n=50)

3527, 3525, 3526, 3524, 3523, 3511, 3508, 3518, 3517, 3481, 3513, 3503, 3510, 3504, 3506, 3505, 3497, 3468, 3495, 3494, 3376, 3492, 3491, 3489, 3488, 3487, 3485, 3484, 3482, 3479, 3475, 3467, 3474, 3469, 3463, 3462, 3443, 3423, 3452, 3428, 3451, 3450, 3449, 3448, 3426, 3424, 3446, 3416, 3439, 3436

### Quarter 2 (n=50)

3435, 3434, 3433, 3427, 3425, 3420, 3419, 3418, 3417, 3405, 3410, 3408, 3404, 3394, 3397, 3368, 3363, 3399, 3402, 3398, 3396, 3374, 3388, 3378, 3349, 3387, 3386, 3384, 3375, 3377, 3371, 3365, 3366, 3355, 3361, 3360, 3354, 3352, 3135, 3348, 3345, 3343, 3342, 3341, 3339, 3332, 3336, 3334, 3327, 3328

### Quarter 3 (n=50)

3316, 3324, 3320, 3031, 3313, 3312, 3245, 3037, 3041, 3300, 3289, 3305, 3283, 3297, 3284, 3282, 3232, 3285, 3271, 3287, 3258, 3281, 3273, 3274, 3269, 3211, 3260, 3259, 3241, 3236, 3256, 3248, 3230, 3243, 3228, 3052, 1924, 1064, 3240, 3239, 3234, 3138, 3163, 3220, 3216, 3194, 3225, 3226, 3223, 3145

### Quarter 4 (n=50)

3169, 3154, 3026, 3153, 3150, 3184, 3139, 3181, 3159, 3054, 3191, 3148, 3119, 3094, 3072, 3043, 3141, 3107, 3090, 3142, 3136, 3096, 3140, 3137, 3131, 3089, 3134, 3130, 3082, 3071, 3086, 3073, 3067, 3051, 3063, 3117, 3121, 3118, 3116, 3112, 3108, 3022, 3106, 3100, 3102, 3101, 3085, 3023, 3088, 3064

## A — precision / recall / flag-rate

Question scored: `needsDeepReview` probability. Positive = any truth class. Baseline = `.fleet/bench7371/a-baseline.json` risk-rule `spend` flag.

| rule | flags | flag-rate | P | R | recall(ii) | vs GO |
|---|---:|---:|---:|---:|---:|---|
| baseline (risk rules) | 26/200 | 13.0% | 0.88 | 0.27 | 9/47 = 0.19 | flag pass, recall(ii) is the bar |
| Jev p>=0.5 | 105/200 | 52.5% | 0.50 | 0.61 | 23/47 = 0.49 | **FAIL flag** (52.5% > 25%) |
| Jev p>=0.7 | 68/200 | 34.0% | 0.60 | 0.48 | 18/47 = 0.38 | **FAIL flag** (34.0% > 25%) |
| Jev p>=0.9 | 18/200 | 9.0% | 0.83 | 0.18 | 4/47 = 0.09 | **FAIL recall(ii)** (0.09 < 0.19) |

Confusion vs union truth:

| threshold | TP | FP | FN | TN |
|---|---:|---:|---:|---:|
| p>=0.5 | 52 | 53 | 33 | 62 |
| p>=0.7 | 41 | 27 | 44 | 88 |
| p>=0.9 | 15 | 3 | 70 | 112 |

### GO check (spec)

`flag-rate <= 25% AND recall(ii) >= baseline recall(ii) 0.19`.

**NO-GO.** No threshold satisfies both. p>=0.5 and p>=0.7 beat recall(ii) but overshoot the 25% flag cap. p>=0.9 is under the flag cap and under the recall bar.

### Calibration buckets (`needsDeepReview`)

| bucket | n PRs | positives | pos-rate |
|---|---:|---:|---:|
| 0.0–0.1 | 15 | 2 | 0.13 |
| 0.1–0.2 | 15 | 5 | 0.33 |
| 0.2–0.3 | 24 | 11 | 0.46 |
| 0.3–0.4 | 20 | 7 | 0.35 |
| 0.4–0.5 | 21 | 8 | 0.38 |
| 0.5–0.6 | 18 | 6 | 0.33 |
| 0.6–0.7 | 19 | 5 | 0.26 |
| 0.7–0.8 | 20 | 8 | 0.40 |
| 0.8–0.9 | 30 | 18 | 0.60 |
| 0.9–1.0 | 18 | 15 | 0.83 |

`riskClass` choices: feature 103, infra 34, test 32, docs 21, auth 5, db 4, deps 1.

`blastRadius` mean: all 2.13, class(ii) 2.20, rest 2.11.

## B — reserved-class triage

Sources: `.fleet/bench7371/b-corpus.json` (300 items: 200 event-labelled + 100 controls), `.fleet/bench7371/b-jev.jsonl`, `.fleet/bench7371/b-metrics.json`. Mechanical labels in `b-labels.jsonl`: truth_reserved **273/300**, truth auto_fixable **27/300**. Controls labelled truth_reserved: **83/100**.

Gate: **0** tolerated false `auto_fixable` on truly reserved items.

### V1: `needsNish` probability

| threshold | flag | P | R | TP | FP | FN | TN | false-auto_fixable-on-reserved |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| p>=0.5 | 51/300 | 0.92 | 0.17 | 47 | 4 | 226 | 23 | **226 FAIL** |
| p>=0.7 | 13/300 | 1.00 | 0.05 | 13 | 0 | 260 | 27 | **260 FAIL** |
| p>=0.9 | 4/300 | 1.00 | 0.01 | 4 | 0 | 269 | 27 | **269 FAIL** |

### V2: `reservedClass != auto_fixable`

| rule | flag | P | R | TP | FP | FN | TN | false-auto_fixable-on-reserved |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| class != auto_fixable | 56/300 | 0.93 | 0.19 | 52 | 4 | 221 | 23 | **221 FAIL** |

Verdict disagreement (class-rule vs `needsNish` p>=0.5): **19/300**.

### Confusion matrix (mechanical truth class → Jev `reservedClass`)

| truth \ Jev | authority reserved | auto_fixable | brand | destructive | money/pricing | product direction | security | n |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| authority Nish explicitly reserved | 4 | 45 | 0 | 2 | 0 | 0 | 1 | 52 |
| auto_fixable (truth) | 3 | 23 | 0 | 0 | 0 | 0 | 1 | 27 |
| brand | 1 | 7 | 0 | 0 | 0 | 1 | 0 | 9 |
| destructive/irreversible steps | 0 | 1 | 0 | 1 | 0 | 0 | 0 | 2 |
| money/pricing | 4 | 163 | 4 | 2 | 13 | 10 | 4 | 200 |
| product direction | 1 | 1 | 0 | 0 | 0 | 1 | 0 | 3 |
| security | 3 | 4 | 0 | 0 | 0 | 0 | 0 | 7 |

Jev `reservedClass` totals: auto_fixable 244, authority reserved 16, money/pricing 13, product direction 12, security 6, destructive 5, brand 4.

### Relabel disagreement vs 15%

Independent relabel: `.fleet/bench7371/b-relabel-output.txt`, 90 items (30% of 300). Committed `.fleet/bench7371/b-relabel-metrics.json`:

| metric | rate | count |
|---|---:|---|
| reserved_disagreement_rate | 0.9222222222222223 | 83/90 |
| class_disagreement_rate | 0.9555555555555556 | 86/90 |

Gate: disagreement **> 15% is no-go**. **92.2% > 15%. FAIL.**

## Latency and cost

Nearest-rank percentiles on the integer `ms` field. Cost = input tokens × $0.042 / 1e6.

| bench | n | p50 ms | p95 ms | input tokens | output tokens | cost USD | cost per 1k items |
|---|---:|---:|---:|---:|---:|---:|---:|
| A | 200 | 411 | 698 | 221502 | 20800 | 0.009303084 | 0.04651542 |
| B | 300 | 382 | 662 | 577006 | 39569 | 0.024234252 | 0.08078084 |
| A+B | 500 | — | — | 798508 | 60369 | 0.033537336 | — |

## Spend

Live helper ledger `~/.local/state/pi-packet/jev/spend.json` (shared host counter, not packet-only):

| field | value |
|---|---|
| usd | 0.52899777 |
| calls | 3127 |
| inputTokens | 12595185 |
| updated | 2026-09-18T12:12:34.746Z |

Issue spend cap **$1**. Host ledger **$0.52899777 < $1**. A+B replay token cost at the listed rate is **$0.033537336** (500 calls). Other callers share the ledger, so the host figure is not this packet's cost.

`/v1/credits` balance before and after: **missing evidence** (not in committed files; not read here).

HANDOFF.md recorded the same host counter at **$0.2234** (2026-09-17T21:52Z). That earlier read is not a credits-API delta.

## go/no-go per epic #7370 child

| # | child | verdict | measured threshold or missing evidence |
|---|---|---|---|
| 1 | review-gate.yml (`needsDeepReview` / `riskClass`) | **NO-GO** | GO check failed at every threshold. p>=0.5 flag 52.5% (cap 25%) recall(ii) 23/47; p>=0.7 flag 34.0% recall(ii) 18/47; p>=0.9 flag 9.0% recall(ii) 4/47 < baseline 9/47. No measured threshold is usable. |
| 2 | bugbot-gate (spend decision alongside reserved classes) | **NO-GO** on reserved half; spend question missing | Reserved false-auto is 226/260/269 (V1) and 221 (V2); gate is 0. No spend-decision question was replayed in A or B. |
| 3 | intake (scope score, cheap-vs-flagship tier, duplicate-of-open-PR) | missing evidence | No scope / seat-tier / duplicate-probability labels or replay in committed files. |
| 4 | reserved-class triage (Nish-questions / desk cards) | **NO-GO** | False-auto_fixable-on-reserved is 226 / 260 / 269 at p>=0.5 / 0.7 / 0.9 (gate 0). Relabel reserved disagreement 83/90 = 92.2% > 15%. |
| 5 | packet-verdict (done / partial / empty-run / failed) | missing evidence | No packet-verdict labels or replay in committed files. |
| 6 | CI failure triage (RUNNER-GONE / CONCURRENCY-BLOCKED / flaky / real) | missing evidence | No CI-log labels or replay in committed files. |
| 7 | Hermes message tiering (urgent-instant vs digest) | missing evidence | No Hermes-tier labels or replay in committed files. |
| 8 | findings-ledger class labelling + dedupe | missing evidence | No ledger-class / dedupe replay in committed files. |
| 9 | Weekly Fleet Review (rubric score) | missing evidence | No weekly-action rubric replay in committed files. |

No child has a passing measured threshold. This packet does not file follow-up issues and does not wire a gate.

## Active-learning cohort (fleet-ops#7430)

Uncertainty-selected rows are labelled separately from the fixed A/B cohorts
above (orchestrator ruling 2026-09-17: advisory logs are not benchmark truth;
do not mix active-learning samples into the fixed evaluation cohort).

- **Queue:** the `jev-labelling-queue` comment on fleet-ops#7430 — every live
  JSONL row with a probability in the uncertain band `0.1 < p < 0.9` (the
  standing `JEV_CASCADE_LO`/`_HI` defaults; no per-site overrides are set).
  It is an issue comment, not a new store.
- **Cadence:** the reviewer subagent labels at most 20 items/day from the
  queue, judging each site's own question against the row's recovered
  context (`ref` → `gh pr view` / commit / dispatch record).
- **Table:** labels append to `.fleet/bench7371/active-learning-labels.jsonl`,
  one JSON object per item: `{ts, cohort:"active-learning", source_issue,
  site, ref, question, question_type, jev_p, band_lo, band_hi, label,
  label_reason, labelled_by, label_run, labelled_at, state_sha256}`.
- **Reporting:** calibration deltas (bucketed `jev_p` vs observed label rate,
  per site+question) are reported from this table in the weekly fleet
  review. Batch 1 (2026-09-22, 20 rows, reviewer = grok-4.7 xhigh):
  `needs_review` 7/10 true, `merge_risk` 3/5 true, `claims_contradicted`
  0/4 true, `red_attributable_to_head_merge` 0/1 (insufficient evidence).
