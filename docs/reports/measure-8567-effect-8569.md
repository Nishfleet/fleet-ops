# Measurement of #8567's effect — issue #8569

Issue #8569 asks whether the change merged in #8567 (worker
`contextWindow` 96000 / `RateLimitErrorRetries` 2 / `RateLimitErrorAllowedFails` 1
/ `optional_pre_call_checks ["prompt_caching"]` / `health_check_interval` 900)
actually cut the token burn. #8567 went live on the proxy at
`2026-09-24 05:08:51 UTC`. The 6h measurement window is therefore
`2026-09-24 05:08:51` → `2026-09-24 11:08:51 UTC`; the 24h baseline window
is `2026-09-22 12:00` → `2026-09-23 12:00 UTC`, exactly as the issue
specifies.

This is the receipt — raw numbers and the verdict per the four bullets.
Every number below is reproducible from the commands in the appendix.

## Method and retention boundaries (read first)

Three data sources, three different retention windows. A query that
"reaches back" into a source's dead zone returns a row count of zero, not
a measurement of zero — every window below is checked against these
boundaries:

| source | covers |
|---|---|
| `LiteLLM_SpendLogs` (psql) | earliest worker% row `2026-09-07 17:05:43 UTC` — both windows fully covered |
| `~/.pi/agent/sessions/agent-*` | oldest session `2026-09-23T18:12:26 UTC` — the 09-22/23 baseline window is **not** retained |
| proxy journal (`fleet-litellm-proxy.service`) | oldest line `2026-09-23T03:27:57 UTC` — most of the baseline window is **not** journalled |

## Metric 1 — prompt_tokens avg / p90 (`model_group like 'worker%'`)

`psql -h 127.0.0.1 -U litellm -d litellm` against `LiteLLM_SpendLogs`,
columns `prompt_tokens`, `startTime`, `model_group`. Full SQL in the
appendix; per-window numbers below.

| window | rows | avg | p50 | p90 | p99 | max |
|---|---:|---:|---:|---:|---:|---:|
| baseline 24h (`09-22 12:00` → `09-23 12:00`) | 36,791 | **73,093** | 66,689 | 134,262 | 189,940 | 268,759 |
| after 6h, all rows (`05:08:51` → `11:08:51`) | 486 | 59,668 | 60,178 | 90,598 | 131,959 | 134,725 |
| after 6h, sub-window `06:00`–`11:08:51` (full hours only) | 90 | **53,066** | 58,240 | **82,152** | 85,896 | 87,446 |
| controls (same shape, different days) | | | | | | |
| same-clock `05:08:51`–`11:08:51` on 09-22 | 2,550 | 62,919 | 59,684 | 106,225 | 164,197 | 188,109 |
| same-clock `05:08:51`–`11:08:51` on 09-23 | 4,451 | 80,358 | 71,067 | 163,256 | 213,957 | 268,759 |
| previous 24h (`09-23 12:00` → `09-24 12:00`) | 12,147 | 46,792 | 43,454 | 87,439 | 161,909 | 221,754 |

Failed rows carry `prompt_tokens = 0` (853 of 36,791 baseline, 17 of 486
after, 1 of 90 in the sub-window), so they sit at the floor and slightly
depress each average; at 2.3–3.5% they do not flip any verdict.

**Verdict: p90 PASS, avg MISS — and the avg cannot be attributed to
#8567 on this data.**

- Target is `≥30% lower`. Against the measured baseline:
  avg `73,093` → `59,668` is −18.4% (miss); p90 `134,262` → `90,598`
  is −32.5% (pass). The clean `06:00`+ sub-window is avg `53,066` (−27.4%,
  still a miss) and p90 `82,152` (−38.8%, pass). Using the issue's own
  "baseline about 68k" instead moves both percentages up ~7 points and
  changes no verdict.
- The after window is contaminated by sessions started before the 96k
  cap was live: 396 of the 486 after-window rows fall in the
  `05:08:51`–`06:00` hour (avg `61,169`, max `134,725`, impossible under
  the cap). The sub-window's 90 rows are clean of that.
- But the sub-window is a survivor series. Hourly request counts inside
  the after window are `543` (05:00 hour, 51 min of it in-window) `0`
  (06:00) `19` `53` `18` `0` (10:00) `149` (11:00 hour, 9 min
  in-window) — the fleet was seat-walled (metric 4), so those averages
  come from a tiny surviving population, not from full traffic.
- The controls kill the clean story. The same clock window ran at
  `62,919` (09-22) and `80,358` (09-23) — a ±28% day-to-day swing,
  larger than the −18/−27% effect being claimed. The 24h immediately
  before go-live averaged `46,792`, well **below** the after value, so
  the burn was already falling before #8567 for reasons of its own.
  Attributing the after number to the `contextWindow` change would
  over-read a confounded record.

Follow-up for the avg: #8581 (re-measure over a clean, un-walled 24h).

## Metric 2 — share of `agent-*` runs ending 429

Sessions whose `startTime` is in the window, then the LAST assistant
message has `stopReason == "error"` and `429` / `RateLimit` / `rate
limit` appears anywhere in its serialized form. The scan program is in
the appendix.

| window | sessions | ended 429 | share |
|---|---:|---:|---:|
| issue baseline 24h (`09-22 12:00` → `09-23 12:00`) | 0 | 0 | not retained (store floor `09-23 18:12:26`) |
| retained pre-go-live (`09-23 18:12:26` → `05:08:51`) | 234 | 80 | **34.2%** |
| retained pre-go-live, issue-filed cut (`…` → `05:11:00`) | 237 | 80 | **33.8%** |
| after 6h (`05:08:51` → `11:08:51`) | 4 | 0 | **0.0%** |

stopReason distribution in the retained pre-go-live window: `stop` 102,
`toolUse` 50, `error` 81 (80 of the 81 carry a 429), `length` 1. All 4
after-window sessions ended `stop`.

**Verdict: PASS on the target window, with the sample size named.**
The target is about the post-go-live window only: `0/4 = 0%` is under
the 10% line, but `n=4` cannot carry a claim on its own. The
request-level journal corroborates it (see below), and the issue's own
baseline `61/221 = 27.6%` sits in the same band as the retained pre-
window's `34.2%`, so the baseline rate is plausible — the improvement
is real in direction and far too small in sample to be called by the
sessions alone.

Request-level corroboration from the proxy journal (`POST
/chat/completions` lines containing `429`), which covers 8.5h of the
baseline window from `09-23 03:27:57`:

| window | POST+429 lines | any `429` line |
|---|---:|---:|
| journalled part of baseline 24h | 482 | 2,731 |
| 20h immediately before go-live (`09:09` → `05:08:51`) | 1,877 | 6,886 |
| after 6h | **3** | **34** |

The router's `RateLimitErrorRetries` is `2` as of #8567 and the journal
shows `LiteLLM Retried: 2 times` 8 times inside the after window
(first `05:11:01`, last `05:46:04 UTC`), against 15 in the journalled
baseline — the retry policy is exercising the seat fallbacks instead of
surfacing the 429 to the session, which is what the 0/4 sample shows.

## Metric 3 — health-check requests per hour (empty `model_group`, `prompt_tokens < 50`)

| api_base | baseline 24h (`/h`) | after 6h (`/h`) | deployments | after `/h/deployment` |
|---|---:|---:|---:|---:|
| `opencode.ai/zen/go/v1` | 87.3 | 0.0 | benched post-go-live | 0.0 |
| `api.synthetic.new/openai/v1` | 65.5 | 16.7 | 5 | 3.3 |
| `ai-gateway.vercel.sh/...` | 47.8 | 1.8 | 2 | 0.9 |
| `api.stepfun.ai/step_plan/v1` | 41.0 | 4.0 | 1 | **4.0** ✓ |
| `(blank)` | 24.2 | 0.7 | – | – |
| `api.paretoinference.com/v1` | 20.5 | 7.8 | 2 | **3.9** ✓ |
| the three the issue names | 127.0 | 28.5 | 8 | – |

**Verdict: PASS.** The target "about 4 per hour per deployment" is met
exactly on stepfun (`4.0`) and pareto (`3.9`), and met on synthetic
(`3.3` across 5 placements with `health_check_concurrency: 1` ×
`health_check_interval: 900s = 4/h`, one placement in cooldown). The
issue's ~105/h aggregate was the pre-#8567 60s interval multiplied out;
the math collapses to ~4/h per deployment once the interval is 900s,
which is what the records show.

## Metric 4 — merged PRs per hour on 0509 + fleet-ops

| window | fleet-ops merged | 0509 merged | fleet-ops `/h` | 0509 `/h` |
|---|---:|---:|---:|---:|
| baseline 24h | 35 | 56 | 1.46 | 2.33 |
| after 6h | 4 | 8 | 0.67 | 1.33 |

**Verdict: BOTH DOWN — and the cause is not #8567.**

## Confound on metric 4 — fleet-wide worker-capable seat wall

The worker lane is on a shared seat wall (daily free-model token quota
429s and `GoUsageLimitError` monthly). Corrected, UTC-labelled journal
evidence, from the commands in the appendix:

- Earliest `free-model token quota` line: `2026-09-23T09:09:24 UTC`
  (`GoUsageLimitError` one second later) — about **20h** before #8567
  went live, not 8h as an earlier draft of this report had it. That
  earlier draft also quoted the local (+05:30) journal timestamps as
  UTC; every journal number here is bucketed in UTC.
- Quota mentions per UTC hour on 09-23 climb from `445` (09:00) through
  `872` (17:00) and `655` (23:00) to `506` at 09-24 `00:00`.
- `No deployments available` events: `1,237` inside the baseline window
  itself (`967` with `model=None`, `264` `worker-cheap`), `213` in the
  20h before go-live (`52` `worker-capable`, `8` `worker-cheap`), and
  `0` inside the after-6h window — the after window has essentially no
  traffic to trip the gate. Full-retention totals by group: `None`
  1,120, `worker-cheap` 272, `worker-capable` 52, `senior` 6. The
  `86400s` cooldowns in `config/litellm-proxy.yaml` (3 of them) put the
  benched seats on a day-scale timer.
- The dispatcher gate: an earlier draft of this report claimed
  `gate: skip (seats-out)` was firing on `agent-dispatch` runs. That is
  not on the records. `seats-out` is a skip reason in `agent.yml` (the
  issue worker), not in `agent-dispatch.yml`, and the literal string in
  the `agent-dispatch` logs that matches `seats-out` is the
  `skip() { echo "gate: skip ($1)"; … }` function definition, not an
  event. Actual gate-skip reasons in the after-6h window:
  `needs-split` ×3, `proposed` ×3, `agent-blocked` ×1 — on 45
  `agent-dispatch` runs (`14` success, `31` skipped). Over the wider
  `00:00`–`11:08` window: fleet-ops 184 runs (34 success, 125 skipped,
  25 failure), 0509 199 runs (18 success, 158 skipped, 21 failure,
  2 cancelled). `agent.yml` itself logged 2 runs all day (1 success,
  1 failure).

The metric-4 number is observed, not explained by #8567. This is the
open class tracked in #7820 (worker-lane 429 wall); fresh evidence from
this window is recorded there in the nishfleet-worker comment of
`2026-09-24T12:18:12Z`. Follow-up for the metric-1 avg: #8581.

## Termination comment

The issue's termination is the comment, which carries the same numbers
in the format the issue asks for, with links to this report and the
follow-ups (#8581, #7820).

## Appendix — exact commands

All timestamps are UTC. `LiteLLM_SpendLogs.startTime` is
`timestamp without time zone` and stores UTC (session `TimeZone` is
`Asia/Kolkata`; `now()` returns `+05:30`, its `AT TIME ZONE 'UTC'`
projection matches `startTime`'s latest rows).

**Metric 1.**

```sql
WITH w(label, a, b) AS (VALUES
 ('issue_baseline_24h', timestamp '2026-09-22 12:00:00', timestamp '2026-09-23 12:00:00'),
 ('after_6h',           timestamp '2026-09-24 05:08:51', timestamp '2026-09-24 11:08:51'),
 ('after_hour_0508_0600',timestamp '2026-09-24 05:08:51', timestamp '2026-09-24 06:00:00'),
 ('after_sub_0600_1108',timestamp '2026-09-24 06:00:00', timestamp '2026-09-24 11:08:51'),
 ('sameclock_0922',     timestamp '2026-09-22 05:08:51', timestamp '2026-09-22 11:08:51'),
 ('sameclock_0923',     timestamp '2026-09-23 05:08:51', timestamp '2026-09-23 11:08:51'),
 ('prev24h_0923_0924',  timestamp '2026-09-23 12:00:00', timestamp '2026-09-24 12:00:00')
)
SELECT w.label, count(*) n, round(avg(s."prompt_tokens")) avg,
  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY s."prompt_tokens")) p50,
  round(percentile_cont(0.9) WITHIN GROUP (ORDER BY s."prompt_tokens")) p90,
  round(percentile_cont(0.99) WITHIN GROUP (ORDER BY s."prompt_tokens")) p99,
  max(s."prompt_tokens") mx,
  count(*) FILTER (WHERE s.status='failure') failures,
  round(sum(s."prompt_tokens")) sum_tok
FROM w JOIN "LiteLLM_SpendLogs" s
  ON s."startTime" >= w.a AND s."startTime" < w.b AND s."model_group" LIKE 'worker%'
GROUP BY w.label ORDER BY 1;
```

Hourly rows (`hour_utc|n|avg|p50|p90|max|failures`):

```sql
SELECT date_trunc('hour', "startTime"), count(*), round(avg("prompt_tokens")),
  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY "prompt_tokens")),
  round(percentile_cont(0.9) WITHIN GROUP (ORDER BY "prompt_tokens")),
  max("prompt_tokens"), count(*) FILTER (WHERE status='failure')
FROM "LiteLLM_SpendLogs"
WHERE "model_group" LIKE 'worker%'
  AND "startTime" >= '2026-09-22 11:00:00' AND "startTime" < '2026-09-24 12:00:00'
GROUP BY 1 ORDER BY 1;
```

**Metric 2.** Session scan (the store's floor is
`2026-09-23T18:12:26`, so any window before that reads 0 sessions):

```python
import json, glob, collections
from datetime import datetime, timezone
T = lambda *a: datetime(*a, tzinfo=timezone.utc).timestamp()
windows = {
  "issue_baseline_24h": (T(2026,9,22,12,0,0), T(2026,9,23,12,0,0)),
  "retained_pre_golive": (T(2026,9,23,18,12,26), T(2026,9,24,5,8,51)),
  "retained_pre_golive_issuestyle": (T(2026,9,23,18,12,26), T(2026,9,24,5,11,0)),
  "after_6h": (T(2026,9,24,5,8,51), T(2026,9,24,11,8,51)),
}
stats = collections.defaultdict(collections.Counter)
for f in glob.glob("/home/nish/.pi/agent/sessions/agent-*/*.jsonl"):
    started = None; last = None
    for line in open(f, errors="replace"):
        try: o = json.loads(line)
        except Exception: continue
        if o.get("type") == "session" and started is None:
            ts = o.get("timestamp")
            if ts: started = datetime.fromisoformat(ts.replace("Z","+00:00")).timestamp()
        elif o.get("type") == "message" and o.get("message",{}).get("role") == "assistant":
            last = o["message"]
    if started is None: continue
    for name,(a,b) in windows.items():
        if not (a <= started < b): continue
        stats[name]["sessions"] += 1
        if last is None: continue
        sr = last.get("stopReason"); stats[name][sr or "null"] += 1
        if sr == "error" and "429" in json.dumps(last):
            stats[name]["ended_429"] += 1
for name, s in stats.items():
    print(name, "sessions", s["sessions"], "ended_429", s["ended_429"],
          "stopReason", {k: v for k, v in s.items() if k not in ("sessions","ended_429")})
```

Journal corroboration (UTC-labelled, the retention floor is
`2026-09-23T03:27:57`):

```sh
export XDG_RUNTIME_DIR=/run/user/$(id -u)
journalctl --user -u fleet-litellm-proxy.service -o short-iso --no-pager > /tmp/j.txt
# window counts (baseline part-journalled 03:27:57→12:00; pre 09:09→05:08:51; after 05:08:51→11:08:51)
awk '$1 >= "2026-09-23T03:27:57" && $1 < "2026-09-23T12:00:00"' /tmp/j.txt | grep -c "429"          # 2731
awk '$1 >= "2026-09-24T05:08:51" && $1 < "2026-09-24T11:08:51"' /tmp/j.txt | grep -c "429"          # 34
awk '$1 >= "2026-09-23T03:27:57" && $1 < "2026-09-23T12:00:00" && /POST \/chat\/completions/' \
  /tmp/j.txt | grep -c "429"                                                                        # 482
awk '$1 >= "2026-09-24T05:08:51" && $1 < "2026-09-24T11:08:51" && /POST \/chat\/completions/' \
  /tmp/j.txt | grep -c "429"                                                                        # 3
```

**Metric 3.**

```sql
WITH rows AS (
  SELECT ("startTime" >= '2026-09-24 05:08:51') AS post, "api_base"
  FROM "LiteLLM_SpendLogs"
  WHERE "model_group" = '' AND "prompt_tokens" < 50
    AND ( ("startTime" >= '2026-09-22 12:00:00' AND "startTime" < '2026-09-23 12:00:00')
       OR ("startTime" >= '2026-09-24 05:08:51' AND "startTime" < '2026-09-24 11:08:51') )
)
SELECT "api_base",
  round(count(*) FILTER (WHERE NOT post)::numeric/24.0,1) AS base_per_h,
  round(count(*) FILTER (WHERE post)::numeric/6.0,1)      AS post_per_h
FROM rows GROUP BY 1 ORDER BY 1;
```

**Metric 4.** Merged PRs per window, per repo:

```sh
gh pr list -R Nishfleet/fleet-ops --state merged --limit 200 --json mergedAt \
  --jq '[.[]|select(.mergedAt>="2026-09-22T12:00:00Z" and .mergedAt<"2026-09-23T12:00:00Z")]|length'  # 35
gh pr list -R Nishfleet/fleet-ops --state merged --limit 200 --json mergedAt \
  --jq '[.[]|select(.mergedAt>="2026-09-24T05:08:51Z" and .mergedAt<"2026-09-24T11:08:51Z")]|length'  # 4
# same two jq for -R Nishfleet/0509 with --limit 300                      → 56 and 8
```

Dispatch run counts and real gate-skip reasons (the literal `seats-out`
in these logs is the `skip() { echo "gate: skip ($1)"; … }` definition,
not an event — grep for `gate: skip (` to get the actual reasons):

```sh
gh run list -R Nishfleet/fleet-ops --workflow agent-dispatch.yml --limit 200 \
  --json conclusion,createdAt --jq '[.[]|select(.createdAt>="2026-09-24T05:08:51Z" and .createdAt<"2026-09-24T11:08:51Z")]|group_by(.conclusion)|map({c:.[0].conclusion,n:length})'
gh run view <run-id> -R Nishfleet/fleet-ops --log | grep -oE "gate: skip \([a-z-]+\)" | sort | uniq -c
```

Journal wall evidence:

```sh
export XDG_RUNTIME_DIR=/run/user/$(id -u)
journalctl --user -u fleet-litellm-proxy.service -o short-iso | grep -m1 "free-model token quota"
# 2026-09-23T09:09:24+05:30 → 09:09:24 UTC (GoUsageLimitError one second later)
```

## Appendix — raw numbers

`docs/reports/measure-8567-effect-8569-prompt.tsv`
columns: `window|n|avg|p50|p90|p99|max|failures|sum_tokens`.

`docs/reports/measure-8567-effect-8569-hourly.tsv`
columns: `hour_utc|n|avg|p50|p90|max|failures`, full coverage of the
baseline window, the 24h before go-live, and the after window.

## run-proof

- 1-hour pi worker unit `pi-issue-fleet-ops-8569`, claim branch
  `claim/issue-8569`, docs-only diff under `docs/reports/`.
- Live sources: `LiteLLM_SpendLogs` via psql; `~/.pi/agent/sessions/agent-*/*.jsonl`
  via the Python scan above; `journalctl --user -u
  fleet-litellm-proxy.service` (UTC-labelled); `gh pr list` and
  `gh run list/view` against Nishfleet/fleet-ops and Nishfleet/0509.
- Every number in this report is re-derivable by running the appendix
  commands; the two `.tsv` files are those queries' output.

encoded: 5 — a one-off measurement receipt is prose by nature; the
correction ladder's rungs 1–4 (structure, static gate, rule, skill)
have nothing to enforce: there is no repeated behaviour to gate, only
this report and the verdict comment, and the follow-ups (#8581, #7820)
carry the open measurement work.

loose-ends: none.
