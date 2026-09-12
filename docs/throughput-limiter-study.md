# Throughput limiter study — is local vitest/workerd the CPU limiter? (fleet-ops#4804)

Population-first measurement. This note records the decision rule, the exact
commands, the four numbers from the sampler window, and the verdict.

The 24h sampler died after ~5h (unit gone, 285 JSONL lines). Per the
orchestrator decision (2026-09-10) the sampler was NOT relaunched; the numbers
below come from those 285 lines plus existing fleet-metrics-export and gh.

## Decision rule

The limiter is **local test runs** if BOTH hold over the 24h study window:

1. `vitest+workerd` + `tsc` are **>= 50%** of worker-worktree CPU, AND
2. the **saturated-with-backlog** condition holds **>= 6 of 24 hours**
   (load1 > 2x cores AND ready > 20).

If the rule is met, run a 24h trial on ONE repo (0509): worker instructions
change from full `vitest run` to `vitest related <changed files>` + typecheck,
with the full suite left to CI on the hosted runners. Measure merges/day and
revert-rate before/after.

If the rule is NOT met (or cannot be scored), close this issue with the numbers
and name the next suspect (seat rate limits / claim-loop empty-success churn —
see #4457 — are the two candidates seen in the same snapshot).

## The four numbers (sampler window 2026-09-09T21:20Z → 2026-09-10T02:17Z, 4.95h, 285 samples)

Produced by `python3 libexec/fleet-cpu-analysis.py
agent-state/fleet-metrics/cpu-sampler-4804.jsonl`:

```json
{
  "window_s": 17750,
  "cpu_share_by_class": {
    "tsc": 53.74,
    "vitest+workerd": 35.09,
    "other": 10.15,
    "node build": 0.45,
    "wrangler/esbuild": 0.31,
    "pi/cursor-agent": 0.21,
    "gh": 0.05,
    "git": 0.0
  },
  "cpu_total_s": 12286.82,
  "merged_prs": 33,
  "cpu_s_per_merge": 372.33,
  "saturated_with_backlog_hours": 0.0,
  "samples": 284,
  "control": "no control"
}
```

### 1. CPU share by command class

| class | % of worker CPU |
|---|---|
| tsc | 53.74% |
| vitest+workerd | 35.09% |
| other | 10.15% |
| node build | 0.45% |
| wrangler/esbuild | 0.31% |
| pi/cursor-agent | 0.21% |
| gh | 0.05% |
| git | 0.0% |

**vitest+workerd+tsc = 88.83%** of worker-worktree CPU. Conjunct 1 (>= 50%) is
met.

### 2. CPU-seconds per merged PR

Total worker-worktree CPU over the window: 12,286.82 CPU-seconds (per-interval
deltas of cumulative per-process utime+stime, summed across worktrees and
classes). PRs merged in the same window: 33 (21 in 0509, 12 in fleet-ops).

**372.33 CPU-seconds per merge** (~6.2 CPU-minutes per merge).

### 3. Saturated-with-backlog hours

**Unscoreable — recorded as 0.0 but that is a measurement gap, not a result.**

The `ready` field is 0 in all 285 samples. The sampler read the ready-work
count from `agent-state/fleet-metrics/ready-work-cache.json` with
`data.get("ready", 0)`, but that cache's shape is `{"ts": ..., "data": 144}`
— there is no `"ready"` key, so every sample defaulted to 0. The cache was also
stale (last written 2026-09-04, >2h old), so even with the right key the
freshness guard would have returned 0.

**Fixed 2026-09-10 (fleet-ops#4956).** The re-created
`libexec/fleet-cpu-sampler.py` reads the backlog from
`queue-composition-cache.json` `data["ready-work"]["total"]` (fallback
`ready-work-cache.json` `data`), records `ready_source` and `ready_age_s`, and
scores a missing/key-less/dead-producer cache as `0` with
`ready_source=NO_DATA` — a deliberate zero, never a silent 0-by-default.
`libexec/fleet-cpu-analysis.py` now also prints `ready_min`/`ready_max`,
`ready_sources` and `ready_nodata_samples` so the values the conjunct was
scored from are visible in the report.

The freshness bound is 2400s, not 300s. The queue-composition cache is written
by the 5-min `fleet-metrics-export` timer, but that write is gated by
`PR_CACHE_TTL = 1800` plus "at most one gh fetch per exporter run", so its `ts`
legitimately ages to ~35 min (proven live: cache written 19:05:07, the 19:10:00
and 19:12:00 runs exited 0 and did not rewrite it; a 300s bound read NO_DATA on
4 of 4 live samples). `NO_DATA` therefore means the producer is dead or gh is
failing, which is the state that should score the conjunct 0.

Without a real `ready` value the backlog half of the condition (ready > 20)
can never be true, so saturated-with-backlog is structurally 0 regardless of
load. load1 > 2x cores (16) did hold for ~2.22h of the 4.95h window (133/285
samples, 46.7%), but that is saturation without a measured backlog.

### 4. Control

**No control.** No per-process CPU sampler ran 7 days earlier, so the CPU-share
and CPU-sec/merge numbers have no historical comparison. The only control
signal available is merged-PR counts for the same 4.95h window 7 days earlier
(2026-09-02T21:20Z → 2026-09-03T02:18Z): fleet-ops = 3, 0509 = 0 (3 total vs 33
now). That is not an apples-to-apples CPU control; it only shows the fleet was
far less active then.

## Interim verdict (4.95h window): the decision rule cannot be scored

- Conjunct 1 (vitest+workerd+tsc >= 50%): **MET** (88.83%).
- Conjunct 2 (saturated-with-backlog >= 6 of 24h): **CANNOT BE SCORED**, for
  two independent reasons:
  1. Only 4.95h of data exist (the sampler died), not 24h — so even a perfect
     measurement could not reach "6 of 24 hours".
  2. `ready` is 0 in every sample (sampler bug above), so the backlog half of
     the condition was never measured at all.

Per the issue's step 4 and the orchestrator decision, the `vitest related` +
CI-offload trial stayed **unauthorized** until the rule was scored against a
real 24h window with a working `ready` measurement. No worker prompt, CI
workflow, or gate was changed.

## Final verdict (24h window, fleet-ops#4959): conjunct 2 NOT MET — trial NOT authorized

The re-created sampler (fleet-ops#4956) completed a full window:
`fleet-cpu-sampler-4956.service` ran 2026-09-10T13:45:48Z →
2026-09-11T13:45:50Z (window_s=86287, ~24h), 1,436 samples,
`ready_nodata_samples=0`, clean stop (`Result=success`, "sampler done" in the
unit journal). `ready` was real data all window: min 35, max 176, mean ~102,
source `queue-composition-cache.json`.

The four numbers (`python3 libexec/fleet-cpu-analysis.py
agent-state/fleet-metrics/cpu-sampler-4956-24h.jsonl`, exit 0):

| metric | value |
|---|---|
| CPU share by class | vitest+workerd 47.47%, tsc 11.59%, other 39.03%, wrangler/esbuild 1.64%, pi/cursor-agent 0.15%, node build 0.06%, gh 0.05%, git 0.02% |
| CPU-seconds per merged PR | 90.71 (25,944 CPU-s / 286 merges; merge count re-verified live via `gh pr list`: 103 fleet-ops + 183 0509) |
| saturated_with_backlog_hours | **1.13h** (load1 > 16 = 2x8 cores AND ready > 20) |
| control | no control |

- Conjunct 1 (tsc + vitest+workerd >= 50%): **MET** — 59.06%.
- Conjunct 2 (saturated-with-backlog >= 6 of 24h): **NOT MET** — 1.13h of a
  full ~24h window. No scaling needed; the window is complete.

The decision rule fails, so the `vitest related <changed>` + CI-offload trial
is **not authorized**. No worker prompt, CI workflow, or gate changes.

Why it fails: the backlog leg held for the entire window — `ready > 20` was
true in all samples (never below 35) — but the load leg held only ~1.1h. The
box was >50% idle for ~11.9h of the 24h while 35-176 ready items sat queued.
Work was waiting and CPU was not the thing stopping it.

**Next route: seat-side capacity removal.** The study's other named candidate,
claim-loop empty-success churn (fleet-ops#4457), already landed (CLOSED). The
live signature matches seat walls: `ready >= 35` all day on an idle box means
ready work was not being converted into running workers. In-window evidence:
`seats-retired-ds4flash` at 2026-09-10T17:25Z and 18:55Z, six
`seats-corpse-retired` events, `pi-seat-health.json` showing a 429
`rate_limited` seat. Open work on this route: fleet-ops#5272
(seat-availability SLO slow burn), #5096 (seat-recovery trigger storms), #5141
(registry reaping live workers), #5326 (senior ladder walled).

Per the study's delete-the-sampler discipline, `agent-state/cpu-sampler-4956/`
and the 24h JSONL were deleted after the verdict; the numbers above are
reproducible by re-running `libexec/fleet-cpu-analysis.py` on any future
sampler JSONL.

## Next suspect

The issue names two candidates from the same snapshot. Both show up live on
this very issue's thread:

1. **Seat rate limits / seat walls.** A seat wall is the stronger signal:
   `commandcode/deepseek/deepseek-v4-flash` died fast 159 times in 3h and was
   walled at 2026-09-10T00:25:17Z (`free_balance_exhausted`,
   `bench_until 2026-09-11T00:25:17Z`). That wall burned every claim on this
   issue (4 claims in 7200s spinning dead workers) before the block was
   released. A walled seat removes worker capacity independent of CPU.
2. **Claim-loop empty-success churn (fleet-ops#4457).** This issue itself hit
   the 4-claim-in-7200s reclaim cap with no open PR — the claim path was
   spinning dead workers into the seat pool instead of completing.

CPU is a real load (88.83% of worker CPU is test/build, load1 hit 25 on 8
cores), but with the backlog condition unmeasured and a seat wall actively
removing capacity in the same window, **seat rate limits / claim-loop
empty-success churn is the next suspect**, not local test runs. A follow-up
study needs a 24h sampler with a working `ready` field (read
`queue-composition-cache.json` `data["ready-work"]["total"]` or
`ready-work-cache.json` `data["data"]`, with a freshness check) before the
trial can be authorized.

## Exact commands

### Run the sampler (one pi-systemd-run unit, exits on its own)

```bash
pi-systemd-run --unit fleet-cpu-sampler-4804 \
  --deadline 1500 \
  --deliverable /home/nish/workspaces/agent-state/fleet-metrics/cpu-sampler-<start-epoch>.jsonl \
  -- python3 /home/nish/workspaces/tooling/fleet-ops/libexec/fleet-cpu-sampler.py
```

The sampler writes one JSONL line per 60s sample to
`agent-state/fleet-metrics/cpu-sampler-<start-epoch>.jsonl` and exits on its
own after 24h. `--deadline 1500` = 25h grace budget (1500 minutes).

> The sampler script (`libexec/fleet-cpu-sampler.py`) was deleted after the
> study per the issue's "delete the sampler" instruction. It was re-created
> with the `ready`-field fix on 2026-09-10 (fleet-ops#4956) and re-run; the
> analysis script (`libexec/fleet-cpu-analysis.py`) is retained so the four
> numbers above are reproducible from any sampler JSONL.

### Analyse the window

```bash
python3 libexec/fleet-cpu-analysis.py \
  agent-state/fleet-metrics/cpu-sampler-4804.jsonl \
  [--control agent-state/fleet-metrics/cpu-sampler-<control-epoch>.jsonl]
```

Produces the four numbers: CPU share by class, CPU-seconds per merge,
saturated-with-backlog hours, and control (or "no control"). Merged-PR
timestamps come from `gh pr list --state merged --search "merged:>=.. merged:<=.."`
(one call per repo: fleet-ops, 0509), parsed as UTC.

## Status

- [x] Sampler + analysis tooling built
- [x] Sampler ran (died at ~5h / 285 lines; not relaunched per orchestrator)
- [x] Analysis produces the four numbers
- [x] Decision rule evaluated: cannot be scored (5h not 24h; `ready`=0 bug)
- [x] Next suspect named: seat rate limits / claim-loop empty-success churn
- [x] Sampler deleted after the study
- [x] `ready`-field bug fixed and sampler re-created (fleet-ops#4956,
      2026-09-10): real backlog read, freshness guard, ready_source
- [x] Decision rule conjunct 2 scored from a completed 24h sampler window
      (fleet-ops#4959, 2026-09-11): NOT MET — 1.13h < 6h; trial not authorized;
      next route = seat rate-limit walls
- [x] Sampler artifacts deleted after the verdict
      (`agent-state/cpu-sampler-4956/` + 24h JSONL)
