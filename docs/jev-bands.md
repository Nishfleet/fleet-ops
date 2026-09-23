# Jev band edges — the one tuning knob (fleet-ops#7439)

The table below is the record of every Jev site's band edges.
`config/jev-bands.json` was deleted in the glue-zero wipe (fleet-ops#8234);
nothing reads a file for these edges anymore, and a site's own prompt
carries the comparison it actually applies. If you are tuning how confident
Jev must be before a site treats its answer as conclusive, the row below is
what you change — and the prompt that applies it.

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
  sites treat it as the "no" band.
- `sensitivity` — comparison edges a site reports for telemetry only.
  `worker-context` (fleet-ops#7454) reports its would-drop set and token
  delta at 0.1, 0.25 and 0.5, written into its own prompt rather than read
  from a file, and no edge decides anything: the tier is advisory and the
  packet is unchanged.
- `vault-drop-routing` is log-only and has no consumer. The glue wipe
  deleted `config/jev-bands.json`, so there is no row to stamp and nothing
  reads an edge. The site's shadow run and its confident-disagreement list
  are in `docs/vault-drop-routing-2026-09.md` (fleet-ops#7766). Scoring
  is filed as fleet-ops#8289, because #7754 closed without covering this site.
- `scout` and `scout-rank` are log-only: they apply no edge today, so
  their band values are inert. The rows still stamp them — they are the
  edges a future flip (fleet-ops#7442, fleet-ops#7778) would read.
- `intake-repair-seatfault` is log-only while the shadow tier is armed and
  inert by default. It is a single-edge site: `act_hi` is the confidence
  floor under which a Jev `choice(3)` answer is not conclusive enough to
  steer a repair, so the classifier reports `park=yes` and the repair agent
  parks the issue for the orchestrator instead (fleet-ops#7772). Arm it with
  `systemctl --user set-environment JEV_SEATFAULT_SHADOW=1`, and check the
  window with `python3 lib/seat_fault.py --replay
  ~/.local/state/pi-packet/jev/intake-repair-seatfault.jsonl`.
- `failure-triage` is log-only while the shadow tier is armed. It is
  single-edge: `act_hi` is the `p >= 0.9` bar the flip will read once
  fleet-ops#7754 has scored the rows (fleet-ops#7780). The tier is
  advisory by construction and shipped on; disable it with
  `JEV_FAILURE_TRIAGE=0`, and check the window with `python3
  lib/failure_triage.py --replay
  ~/.local/state/pi-packet/jev/failure-triage.jsonl`.

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
| `failure-triage` | `lib/failure_triage.py` | 0.9 | 0.1 |
| `gha-stuck-run-watch` | `prompts/alert-repair.md` | 0.9 | 0.1 |
| `hermes-digest` | `prompts/daily-digest.md` | 0.5 | 0.5 |
| `intake-repair-seatfault` | `lib/seat_fault.py` | 0.6 | 0.6 |
| `intake-seat-smoke` | `prompts/intake.md` | 0.9 | 0.1 |
| `intake-order` | `prompts/intake.md` | 0.9 | 0.1 |
| `merge-queue-batches` | `prompts/daily-digest.md` | 0.9 | 0.1 |
| `merge-queue-enqueue` | `prompts/worker.md` | 0.9 | 0.1 |
| `reviewer-needs-review` | `prompts/worker.md` step 7 | 0.9 | 0.1 |
| `scout` | `prompts/scout.md` | 0.9 | 0.1 |
| `scout-rank` | `prompts/scout.md` | 0.9 | 0.1 |
| `second-opinion` | `prompts/worker.md` | 0.5 | 0.5 |
| `second-opinion-reserved` | `prompts/worker.md` | 0.5 | 0.5 |
| `vault-drop-routing` | none — log-only shadow, no row is read (fleet-ops#7766) | — | — |
| `worker-context` | RETIRED 2026-09-23 (fleet-ops#8423): 306 of its 450 rows scored 0509 runs whose repo has neither candidate file | 0.9 | 0.1 |
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
(`JEV_CASCADE_<SITE>_LO`/`_HI`) beat the table, the global
`JEV_CASCADE_LO`/`_HI` beat it next, and the mode flag can always take a
site to `off` entirely. `worker-context` has no cascade ladder; it reads
`JEV_WORKER_CONTEXT=off` (or `0`) and then makes no call and writes no row
(fleet-ops#7454).
