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

## Verdict: the decision rule cannot be scored — trial NOT authorized

- Conjunct 1 (vitest+workerd+tsc >= 50%): **MET** (88.83%).
- Conjunct 2 (saturated-with-backlog >= 6 of 24h): **CANNOT BE SCORED**, for
  two independent reasons:
  1. Only 4.95h of data exist (the sampler died), not 24h — so even a perfect
     measurement could not reach "6 of 24 hours".
  2. `ready` is 0 in every sample (sampler bug above), so the backlog half of
     the condition was never measured at all.

Per the issue's step 4 and the orchestrator decision, the `vitest related` +
CI-offload trial stays **unauthorized** until the rule is scored against a real
24h window with a working `ready` measurement. No worker prompt, CI workflow,
or gate is changed.

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
> study per the issue's "delete the sampler" instruction. The analysis script
> (`libexec/fleet-cpu-analysis.py`) is retained so the four numbers above are
> reproducible from any sampler JSONL. A follow-up that re-runs the sampler
> must first fix the `ready`-field bug documented in section 3.

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
