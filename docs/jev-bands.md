# Jev band edges — the one tuning knob (fleet-ops#7439)

`config/jev-bands.json` is the single table every Jev site reads its band
edges from. Site blocks carry no local threshold constants; if you are
tuning how confident Jev must be before a site treats its answer as
conclusive, this file is the knob — edit it and nothing else.

```json
{
  "sites": {
    "<site>": { "act_hi": 0.9, "review_lo": 0.1 }
  }
}
```

- `act_hi` — `p >= act_hi` is the confident-positive edge. Cascade sites
  treat it as the "yes" band; single-edge sites (hermes-digest's
  `disagree`, claim-check's `claims_contradicted` flag, second-opinion's
  split edge and the step-4 `needsNish` escalation check) use it as their
  comparison edge.
- `review_lo` — `p <= review_lo` is the confident-negative edge. Cascade
  sites treat it as the "no" band; `worker-context` uses it as its
  would-drop threshold.
- `sensitivity` (optional, per-site) — extra comparison edges a site may
  evaluate for telemetry only. Today only `worker-context` reads it, for
  its `would_drop_by_threshold`/`token_delta_est_by_threshold` columns.
- `scout` is log-only: it applies no edge today, so its band values are
  inert. The row still stamps them — they are the edges a future flip
  (fleet-ops#7442) would read.

Every site row stamps the `act_hi`/`review_lo` it ran under, so any row
can be replayed against the table value that produced it. A missing file,
a missing site entry, or a non-numeric/out-of-range value surfaces as
`null` fields — callers fail open: cascade sites fall to the uncertain
band (the probe/session still runs), advisory sites still write their
row, and second-opinion reports `disagreement=null`. Nothing silently
keeps an old constant.

## Site rows

| site | consumer | `act_hi` | `review_lo` |
|---|---|---|---|
| `alert-dispatch` | `bin/am-executor-claim` Jev cascade | 0.9 | 0.1 |
| `alert-triage` | `bin/am-executor-claim` triage batch | 0.9 | 0.1 |
| `alert-repair` | `prompts/alert-repair.md` | 0.9 | 0.1 |
| `auto-revert` | `prompts/alert-repair.md` | 0.9 | 0.1 |
| `claim-check-pr` | `prompts/worker.md` | 0.5 | 0.5 |
| `claim-check-report` | `prompts/worker.md` | 0.5 | 0.5 |
| `dependency-pr-arm` | `prompts/worker.md` | 0.9 | 0.1 |
| `flaky-test-quarantine` | `prompts/alert-repair.md` | 0.9 | 0.1 |
| `gha-stuck-run-watch` | `prompts/alert-repair.md` | 0.9 | 0.1 |
| `hermes-digest` | `prompts/daily-digest.md` | 0.5 | 0.5 |
| `intake-seat-smoke` | `prompts/intake.md` | 0.9 | 0.1 |
| `merge-queue-batches` | `prompts/daily-digest.md` | 0.9 | 0.1 |
| `merge-queue-enqueue` | `prompts/worker.md` | 0.9 | 0.1 |
| `reviewer-needs-review` | `prompts/worker.md` step 7 | 0.9 | 0.1 |
| `scout` | `prompts/scout.md` | 0.9 | 0.1 |
| `second-opinion` | `prompts/worker.md` | 0.5 | 0.5 |
| `second-opinion-reserved` | `prompts/worker.md` | 0.5 | 0.5 |
| `worker-context` | `prompts/intake.md` | 0.9 | 0.1 (+ `sensitivity` [0.1, 0.25, 0.5]) |
| `worker-escalation-target` | `prompts/worker.md` step 4 | 0.5 | 0.5 |

## What tuning does and does not do

Band edges decide what a Jev probability *means*. They never decide what
a site *does* — that is still the per-site mode flag:

- `shadow` (the shipped default): call Jev, write the row, run the
  existing path regardless. Advisory by construction.
- `off` / `0`: no Jev call, exact prior behaviour.
- `act`: the confident bands may short-circuit the expensive call. Only
  cascade sites have an `act` path today (`JEV_CASCADE_<SITE>=act` or the
  global `JEV_CASCADE=act`), and flipping one requires a benchmark go row
  (fleet-ops#7371). The September benchmark was NO-GO at every measured
  threshold — see `docs/jev-benchmark-2026-09.md` — so the shipped values
  are the fleet's standing bands, not measured ones.

Rollback ladder, unchanged: per-site env overrides
(`JEV_CASCADE_<SITE>_LO`/`_HI`, `JEV_WORKER_CONTEXT_THRESHOLD`) beat the
table, the global `JEV_CASCADE_LO`/`_HI` beat it next, and the mode flag
can always take a site to `off` entirely. `JEV_BANDS_FILE` points the
readers at a different table (tests use it for fixtures).
