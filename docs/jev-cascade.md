# Jev cascade gating (fleet-ops#7396)

The cascade pattern for the Jev epic (#7370): put Jev in front of an
existing expensive-model call site, act on its answer when the probability
lands at or beyond the configured lo/hi bands, and call the current model
only in the uncertain band between them.

```
            ┌─────────────┐
            │  call Jev   │  POST 127.0.0.1:4000/jev, one typed question
            └──────┬──────┘
                   │ p
        ┌──────────┼──────────┐
   p <= lo      lo < p < hi    p >= hi
   confident    uncertain      confident
   "no"         band           "yes"
        │           │               │
   act on no   call the current  act on yes
   (skip the   model, as today   (skip the
   big model)  (never skipped)   big model)
```

- `p` is the probability on the site's typed question (`boolean` today).
- `hi`/`lo` come from the one table `config/jev-bands.json`
  (`sites.<site>.act_hi` / `.review_lo` — fleet-ops#7439,
  docs/jev-bands.md is the authority). Site code carries no local
  threshold constants. Env overrides remain for rollback: per-site
  `JEV_CASCADE_<SITE>_HI` / `_LO`, then global `JEV_CASCADE_HI` /
  `JEV_CASCADE_LO`. Shipped values are 0.9 / 0.1, the fleet's standing
  Jev act bands. Never invent a threshold: a band a benchmark did not
  measure is not a band.
- Every call appends one JSONL row to
  `~/.local/state/pi-packet/jev/<site>.jsonl`: `{ts, site, ref, mode,
  advisory_only, state_sha256, answers, probabilities, band, band_lo,
  band_hi, would_skip, skipped, big_model, usage, ms}` plus site fields.
  `would_skip` = the band would have short-circuited; `skipped` = it
  actually did (act mode only). `big_model` names the call that would have
  been spent.

## Modes

`JEV_CASCADE_<SITE>` beats the global `JEV_CASCADE`. One flag per site; off
restores the exact prior behaviour.

| value | Jev called | row logged | big model |
|---|---|---|---|
| unset / `shadow` / `1` | yes | yes | always runs |
| `0` / `off` | no | no | always runs (identical to before) |
| `act` | yes | yes | skipped on a confident band |

`shadow` is the default and is advisory by construction: the shipped tree
never lets Jev's answer change what runs, so no answer is a hard gate. `act`
is the benchmark-gated flip — set it for a site only after the matching
benchmark (fleet-ops#7371 / 0509#3531) records a go row with measured
thresholds, in a separate change. Jev failure (no key, timeout, malformed
response, invalid probability) always falls through to the current model.

## Wired sites

1. `alert-dispatch` — `bin/am-executor-claim`, between the singleflight
   claim and the `pi --print --model worker-cheap` repair session it
   summons for every Alertmanager firing. Question `needs_repair_session`
   over the alert payload plus prior-dispatch counts; a confident `no`
   (p <= lo) is the skip. Boundary severities (`nish`, `page`) never gate.
2. `intake-seat-smoke` — `prompts/intake.md` step 2 `re-open-*-<seat>`
   date gates. The block owns the `pi --print --model <seat>` live probe;
   `smoke_will_pass` confident `yes`/`no` is the probe verdict in `act`
   mode. Rows carry the real `smoke_ok` outcome whenever the probe ran —
   instant ground truth for scoring.

## Report

After 100 rows across a site, report the share of calls that never reached the big model: `sum(skipped)` in `act`, or `sum(would_skip)` as the projection in `shadow`. Read alongside the row's outcome fields
(`smoke_ok`, `prior_dispatches`) to score whether the skipped calls were
correct before any `act` flip is proposed.

## Rollback

`JEV_CASCADE_<SITE>=0` (or `JEV_CASCADE=0`) restores prior behaviour at that
site — no Jev call, no row, the current model always runs. Shadow mode is
inert by construction; there is nothing else to unwind.
