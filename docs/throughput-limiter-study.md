# Throughput limiter study — is local vitest/workerd the CPU limiter? (fleet-ops#4804)

Population-first measurement. This note records the decision rule, the exact
commands, and the current snapshot. The four numbers are filled in once the
24h sampler window completes.

## Decision rule

The limiter is **local test runs** if BOTH hold over the 24h study window:

1. `vitest+workerd` + `tsc` are **>= 50%** of worker-worktree CPU, AND
2. the **saturated-with-backlog** condition holds **>= 6 of 24 hours**
   (load1 > 2x cores AND ready > 20).

If the rule is met, run a 24h trial on ONE repo (0509): worker instructions
change from full `vitest run` to `vitest related <changed files>` + typecheck,
with the full suite left to CI on the hosted runners. Measure merges/day and
revert-rate before/after.

If the rule is NOT met, close this issue with the numbers and name the next
suspect (seat rate limits / claim-loop empty-success churn — see #4457 — are
the two candidates seen in the same snapshot).

## Exact commands

### 1. Run the 24h sampler (one pi-systemd-run unit, exits on its own)

```bash
pi-systemd-run --unit fleet-cpu-sampler-4804 \
  --deadline 1500 \
  --deliverable /home/nish/workspaces/agent-state/fleet-metrics/cpu-sampler-<start-epoch>.jsonl \
  -- python3 /home/nish/workspaces/tooling/fleet-ops/libexec/fleet-cpu-sampler.py
```

The sampler writes one JSONL line per 60s sample to
`agent-state/fleet-metrics/cpu-sampler-<start-epoch>.jsonl` and exits on its
own after 24h. `--deadline 1500` = 25h grace budget (1500 minutes).

### 2. Analyse the window

```bash
python3 libexec/fleet-cpu-analysis.py \
  agent-state/fleet-metrics/cpu-sampler-<start-epoch>.jsonl \
  [--control agent-state/fleet-metrics/cpu-sampler-<control-epoch>.jsonl]
```

Produces the four numbers: CPU share by class, CPU-seconds per merge,
saturated-with-backlog hours, and control (or "no control").

## Current snapshot (2026-09-10 02:40 UTC, one sample, not proof)

- load 17.2/10.5/6.8 on 8 cores; CPU 75.8% user, 10.1% sys, 3.0% iowait, 4.0% idle
- RAM 6.3 GB available (not the limiter)
- Top consumers: `tsc -b` in agent-worktrees/issue-0509-2135 (118%),
  `vitest run --project workers` in 0509-2136 with workerd children,
  `react-router typegen`, `npm run typecheck`
- Ready queue: 0509=45, fleet-ops=23 (from the filing snapshot)
- Merged last 24h: 109 vs the 300/day target

## Control

No historical per-process CPU sampling exists in the metrics export, so the
control window is **"no control"** unless a sampler JSONL from 7 days earlier
is supplied to the analysis script.

## Status

- [x] Sampler + analysis tooling built and tested
- [x] 24h sampler launched as a detached pi-systemd-run unit
- [ ] 24h window completes; analysis produces the four numbers
- [ ] Decision rule evaluated; trial run or next suspect named
