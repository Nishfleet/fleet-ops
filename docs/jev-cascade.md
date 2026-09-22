# Jev cascade gating (fleet-ops#7396)

The cascade pattern for the Jev epic (#7370). Call Jev in front of an
existing expensive-model call. Act on its answer when the probability
lands at or beyond the configured lo/hi bands. Call the current model
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
   (skip the   model             (skip the
   big model)                    big model)
```

- `p` is the probability on the site's typed boolean question, field
  `answers.<question>.probability` in the POST response.
- `hi` and `lo` come from the environment only. Per-site
  `JEV_CASCADE_<SITE>_HI` and `_LO` win, then `JEV_CASCADE_HI` and
  `JEV_CASCADE_LO`. Both must be numbers from 0 to 1, and lo must be
  strictly below hi. Any other state means there is no band. The call
  stays uncertain and the current model runs. The September 2026
  benchmark recorded NO-GO at every threshold it tried, including
  p>=0.9 (docs/jev-benchmark-2026-09.md). This pattern ships with no
  default lo or hi. `config/jev-bands.json` was deleted in
  fleet-ops#8234. These two sites do not read it. A band a benchmark
  did not measure is not a band. fleet-ops#7909 is the open re-run.
  Leave the env vars unset until that re-run records a go row.
- Each call appends one JSON line to
  `~/.local/state/pi-packet/jev/<site>.jsonl`. Fields: `ts`, `site`,
  `ref`, `mode`, `advisory_only`, `answers`, `probabilities`, `band`,
  `band_lo`, `band_hi`, `would_skip`, `skipped`, `big_model`, `usage`,
  `ms`, plus the site fields below. `would_skip` means a confident band
  would have short-circuited. `skipped` means it did. `big_model` names
  the call that would have been spent. Create the file mode 0600. Never
  write the seat key into the row.

## Modes

`JEV_CASCADE_<SITE>` beats the global `JEV_CASCADE`. One flag per site.
Off restores the prior behaviour.

| value | Jev called | row logged | big model |
|---|---|---|---|
| unset / `shadow` / `1` | yes | yes | always runs |
| `0` / `off` | no | no | always runs, same as before this pattern |
| `act` | yes | yes | skipped on a confident band, and only when lo and hi are both set |

`shadow` is the default. Jev's answer does not change what runs, so no
answer is a hard gate. `act` is a later flip, after a benchmark go row
with measured thresholds, and it arrives by setting the env vars.
Failure (no key, timeout, malformed response, probability missing or
outside 0..1) falls through to the current model.

## The one POST

Both sites call the proxy pass-through. The proxy is the client. Do not
add a helper, a second key file, or a copy of this call in a program.

The LiteLLM virtual key is `LITELLM_JEV_KEY` in
`~/.config/fleet-ops/seats/typesafe-jev.env`. Read it inside the curl.
Never print it. Never export it as a generic gateway key. Never send
the Vercel key to this port. The proxy adds that key upstream.

`curl -sS --max-time 30 127.0.0.1:4000/jev -H "Authorization: Bearer $(sed -n 's/^LITELLM_JEV_KEY=//p' ~/.config/fleet-ops/seats/typesafe-jev.env)" -H 'content-type: application/json' -d '<json>'`

Body shape:
`{"model":"typesafe-ai/jev","state":{...},"questions":{"<id>":{"type":"boolean","instructions":"..."}}}`.

`band` is `hi` when p >= hi, `lo` when p <= lo, `mid` when lo < p < hi,
and `none` when lo or hi is unset. `advisory_only` is true unless the
mode is `act`.

## Wired sites

1. `intake-seat-smoke`, `prompts/intake.md` step 2, on a past
   `re-open-<timestamp>-<seat>` gate. Question `smoke_will_pass`. The
   big model is `pi --print --provider litellm --model <seat>`. In
   `act`, a confident yes or a confident no is the probe verdict and
   that `pi --print` is skipped. Shadow always runs the probe. The row
   carries `smoke_ok` whenever the probe ran. `would_skip` is true on
   either confident edge.

2. `alert-dispatch`, `prompts/alert-repair.md`, after the live alert is
   fetched and before any repair. Question `needs_repair_session`. The
   only skip band is a confident no (p <= lo). Severity `nish` or
   `page` does not call Jev and does not skip. `systemd/alert-repair@.service`
   has already started `pi --print --model worker-cheap` before this
   prompt runs. The pre-session exit lived in `bin/am-executor-claim`,
   which fleet-ops#8234 deleted. `skipped` stays false here.
   `would_skip` records the confident no. An `act` confident no exits
   before the repair steps. That stops the repair actions. It does not
   refund the session that is already running. The row also carries
   `alertname`, `severity`, and `prior_dispatches`.

## Report

After 100 rows on a site, the share of calls that never reached the big
model is `sum(skipped) / n` while the site is in `act`. In `shadow`,
`sum(would_skip) / n` is the projection. On `alert-dispatch` the share
is 0, because the session is the big model and it has already started.
Read `smoke_ok` on intake rows, and `severity` plus `prior_dispatches`
on alert rows, before proposing an `act` flip.

## Rollback

`JEV_CASCADE_<SITE>=0` or `JEV_CASCADE=0` restores prior behaviour at
that site. No Jev call, no row, the current model always runs. Shadow
mode leaves the repair and the probe unchanged.
