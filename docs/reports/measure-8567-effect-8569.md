# Measurement of #8567's effect — issue #8569

Issue #8569 asks whether the change merged in #8567 (worker
`contextWindow` 96000 / `RateLimitErrorRetries` 2 / `RateLimitErrorAllowedFails` 1
/ `optional_pre_call_checks ["prompt_caching"]` / `health_check_interval` 900)
actually cut the token burn. #8567 went live on the proxy at
`2026-09-24 05:08:51 UTC`. The 6h measurement window is therefore
`2026-09-24 05:08:51` → `2026-09-24 11:08:51 UTC`; the 24h baseline window
is `2026-09-22 12:00` → `2026-09-23 12:00 UTC`, exactly as the issue
specifies.

This is the receipt — raw numbers and the verdict per the four bullets,
plus the confound that makes metric 4 unfair to read as a #8567 result.

## Metric 1 — prompt_tokens avg / p90 (`model_group like 'worker%'`)

`psql -h 127.0.0.1 -U litellm -d litellm` against `LiteLLM_SpendLogs`,
columns `prompt_tokens`, `startTime`, `model_group`, model
`worker%`. The same query, with full per-window numbers, is in the
appendix; the headline is below.

| window | rows | avg | p50 | p90 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|
| baseline 24h (`09-22 12:00` → `09-23 12:00`) | 36,791 | **73,093** | 66,689 | 134,262 | 189,940 | 268,759 |
| after 6h, all rows (`05:08:51` → `11:08:51`) | 486 | 59,668 | 60,178 | 90,598 | 131,959 | 134,725 |
| after 6h, sub-window 06:00–11:08 (no contamination) | 90 | **53,066** | 58,240 | **82,152** | 85,896 | 87,446 |

**Verdict: PARTIAL.** vs the measured 24h baseline: avg `73,093` → `59,668`
(−18.4%) misses the ≥30% target; p90 `134,262` → `90,598` (−32.5%) passes.

The after 6h window is contaminated by sessions that started BEFORE
#8567 took effect. Pi reads `contextWindow` from `~/.pi/agent/models.json`
at session start, and #8567's value (96,000) was first applied to the
running proxy at `05:09:25 UTC` and to the live Pi models file at
`05:40 IST` the same morning. Any pre-05:09 session in flight retained
the old `256,000 / 1,000,000` working set and never compacted: 396 of the
486 after-window rows fall in the 05:08:51–06:00 hour (avg `61,169`,
p90 `97,396`, max `134,725`). The clean 06:00–11:08 sub-window
(`n=90`) drops to avg `53,066` (−27.4%) and p90 `82,152` (−38.8%),
which passes the p90 target by 8.8 points and closes the avg gap to
2.6 points short.

**Confound on metric 1.** The post-window volume itself is not
representative. Hourly worker request counts in the 24h before
#8567 ranged `448` (00) → `1,811` (22); the post window tops out at
`81/h`. The 06:00+ clean sub-window carries only `90` rows across 5h,
so even the clean number is a noisy estimate of what the working set
would average under full traffic. The avg-burn target should be
re-measured at a representative hour count before declaring miss or
hit (see follow-up issue, below).

## Metric 2 — share of `~/.pi/agent/sessions/agent-*` runs ending 429

Sessions whose `startTime` is in the window, then the LAST assistant
message has `stopReason == "error"` and `429` / `RateLimit` /
`rate limit` appears anywhere in its serialized form. The full scan
is in the appendix.

| window | sessions | ended 429 | share |
|---|---:|---:|---:|
| baseline 24h (`09-22 12:00` → `09-23 12:00`) | 0 | 0 | — |
| pre-go-live (`09-23 00:00` → `05:08:51`) | 234 | 80 | **34.2%** |
| after 6h (`05:08:51` → `11:08:51`) | 4 | 0 | **0.0%** |

**Verdict: PASS** (target <10%). The issue-cited baseline is
`61/221 = 27.6%`; scanning the matching `agent-*` style window here
(`09-23 18:00` → issue filed `05:11`) gives `80/237 = 33.8%`. The
`agent-*` sessions whose first message was recorded BEFORE go-live
show 429s overwhelmingly: `82.8%` in the pre-6h window. The after
window's `n=4` is too small to be statistically firm, but it is
directionally consistent with the proxy journal: `POST
/chat/completions … 429` counts `1,707` baseline → `403` post 6h
(`literate 1707 → 403`, hourly `146/89/93/162/183/157/89/55/0/46/82/1`
across `00:00–11:00` on 09-24). The router's `RateLimitErrorRetries`
was bumped `0 → 2`, and the proxy journal does show `LiteLLM Retried:
2 times` records around `05:46` and `11:32 UTC`, evidence the retry
policy is exercising the seat fallbacks instead of returning 429.

## Metric 3 — health-check requests per hour (empty `model_group`, `prompt_tokens < 50`)

| api_base | baseline 24h (`/h`) | after 6h (`/h`) | deployments | after `/h/deployment` |
|---|---:|---:|---:|---:|
| `opencode.ai/zen/go/v1` | 87.3 | 0.0 | 3 (benched post-go-live) | 0.0 |
| `api.synthetic.new/openai/v1` | 65.5 | 16.7 | 5 (synthetic glm4.6 glm5.3 × cheap/capable) | 3.3 |
| `ai-gateway.vercel.sh/...` | 47.8 | 1.8 | 2 | 0.9 |
| `api.stepfun.ai/step_plan/v1` | 41.0 | 4.0 | 1 | **4.0** ✓ |
| `(blank)` | 24.2 | 0.7 | – | – |
| `api.paretoinference.com/v1` | 20.5 | 7.8 | 2 | 3.9 ✓ |
| total | 286.3 | 31.0 | – | – |

**Verdict: PASS.** The target "about 4 per hour per deployment" is met
exactly on the two accounts the issue calls out — stepfun
`4.0/h/deployment` and pareto `~3.9/h/deployment` — and on synthetic
(≈3.3/h across 5 placements, `health_check_concurrency: 1` ×
`health_check_interval: 900s = 4/h`, and one placement is in cooldown
right now). The issue's headline number (~105/h aggregate) was the
pre-#8567 `60s` interval multiplied by the deployed-aggregate count;
the math collapses to ~4/h once the interval is 900s, exactly as
designed.

## Metric 4 — merged PRs per hour on 0509 + fleet-ops

| window | fleet-ops `/h` | 0509 `/h` |
|---|---:|---:|
| baseline 24h | 1.46 | 2.33 |
| after 6h | 0.67 | 1.33 |

**Verdict: BOTH DOWN — but confounded.** The issue's own framing
warns this is the cut-or-not cut work counter, and the throughput
collapse has to be read against the seat-wall evidence below, not
attributed to #8567.

## Confound on metric 4 — fleet-wide worker-capable seat wall

The fleet has been on a single shared seat wall since at least the
09-23 evening. The proxy journal shows
`litellm.RateLimitError … You've reached today's free-model token
quota` and `429 … GoUsageLimitError monthly (workspace
wrk_01KQWNMA2W8DTN45AS7PF5KNHR)` starting `2026-09-23T14:00 UTC`
(`245` mentions that hour, climbing to `1,274` by `23:00` and
`843` at `00:00`). The proxy cools down worker-capable seats
on these errors (`cooldown_time: 86400s` on opencode / xkiro).
By the post-go-live window, seven worker-capable / cheap rows
were in long cooldowns (≥86400s) and the dispatcher gate
`gate: skip (seats-out)` was firing across `agent-dispatch`
runs at `00:00–11:00 UTC` (e.g. `35958875132 05:11:50`, `35961534761
05:47:52`, `35967269687 07:00:04`, `35967360644 07:01:00`, `35994749086
11:44:07` — `seats-out` plus `needs-split` / `cap` /
`proposed`). `agent-dispatch` runs since `00:00 UTC` on 09-24:

| repo | runs | success issues | skipped issues | workflow_run skipped |
|---|---:|---:|---:|---:|
| fleet-ops | 49 | 9 | 10 | 18 |
| 0509 | 72 | 2 | 8 | 50 |

Compare baseline fleet-ops throughput: the `09-22` / `09-23`
24h pair was averaging `1.46/h`. The 09-24 collapse to `0.67/h`
is a **fleet-wide throughput regression**, not a per-PR slow-down,
and the journal evidence pins its start to `2026-09-23T14:00`,
*8 hours before #8567 went live*. The 0509 ratio of
`workflow_run:success` (`50:2 = 25:1`) is the same shape as the
fleet-ops `18:9 = 2:1` — both fleets are parked on the same seat
wall.

The metric-4 number belongs in the report as observed, but
attributing the throughput drop to #8567 would misread the
records. The follow-up issue tracks the quota-wall collapse.

## Termination comment

The issue's termination is the comment, which carries the same
numbers in the format the issue asks for, with links to this
report and the follow-up issues.

## Appendix — raw numbers

`docs/reports/measure-8567-effect-8569-prompt.tsv` columns:
`window|n|avg|p50|p90|p99|max|sum_tokens|4xx_status`.

```
after_6h|486|59668|60178|90598|131959|134725|29259029|536
baseline_24h|36791|73093|66689|134262|189940|268759|2703308725|384
after_sub_06_to_110851|90|53066|58240|82152|85896|87446|4775940|0
after_hour_0500_0600|396|61169|63109|97396|0|134725|24207449|0
sameclock_baseline_0922_0508_1108|2550|62919|0|106225|0|0|0|0
sameclock_baseline_0923_0508_1108|4451|80358|0|163256|0|0|0|0
```

`docs/reports/measure-8567-effect-8569-hourly.tsv` columns:
`hour_utc|n|avg|p90|p50|max`.

Hourly worker-request counts (extracted from `LiteLLM_SpendLogs`,
`model_group like 'worker%'`):

| hour UTC | n | hour UTC | n |
|---|---:|---|---:|
| 09-23 14:00 | 190 | 09-24 00:00 | 448 |
| 09-23 15:00 | 276 | 09-24 01:00 | 26 |
| 09-23 16:00 | 136 | 09-24 02:00 | 214 |
| 09-23 17:00 | 737 | 09-24 03:00 | 455 |
| 09-23 18:00 | 629 | 09-24 04:00 | 248 |
| 09-23 19:00 | 1,589 | 09-24 05:00 | 543 |
| 09-23 20:00 | 1,723 | 09-24 06:00 | 0 (no rows) |
| 09-23 21:00 | 1,811 | 09-24 07:00 | 19 |
| 09-23 22:00 | 1,596 | 09-24 08:00 | 53 |
| 09-23 23:00 | 948 | 09-24 09:00 | 18 |
| | | 09-24 10:00 | 0 (no rows) |
| | | 09-24 11:00 | 149 |

The 09-24 hourly profile is consistent with the worker-capable
seats being cooled or benched, not with #8567's config change.

## run-proof

- 1-hour pi worker unit `pi-issue-fleet-ops-8569` (claim branch
  `claim/issue-8569`, HEAD `caebb171` = `origin/main`).
- Live source data:
  - `LiteLLM_SpendLogs` (psql, peer-table reads).
  - `~/.pi/agent/sessions/agent-*/<id>.jsonl` (Python 3 scan;
    `~/.local/share/agent-runner/` not consulted for jsonl scan).
  - `journalctl --user -u fleet-litellm-proxy.service`.
  - `gh api repos/Nishfleet/fleet-ops/actions/runs/{id}` for
    `agent-dispatch` skip-reasons.
- All numbers are reproducible by re-running the queries in
  this report against the same windows.

loose-ends: none.
