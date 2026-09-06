## Scope

fleet-ops#3637: `firing_alerts` tile disputes Prometheus (7 firing). The
console tile writer (`generate.py collect_firing_alerts`) counts Prometheus
`/api/v1/alerts` where `state==firing` (Watchdog excluded), but the verifier's
ground truth (`verify.py run_alerts_am`) counted Alertmanager `/api/v2/alerts`
where `state` is `active`/`firing`.

Those are two legitimately-different views of the alert stack: Alertmanager
deduplicates, suppresses (silences/inhibits) and groups alerts, and a firing
alert can land in Prometheus before Alertmanager has received it. So a tile
that faithfully mirrors Prometheus was falsely DISPUTED (ConsoleLying) every
time the two sources diverged — exactly the class of lie #2532 warned not to
paper over by widening tolerance.

## Fix

Point the `firing_alerts` verifier at the SAME Prometheus endpoint the tile
claims to mirror, applying the SAME filter as the writer (`state==firing`,
Watchdog excluded). This is the #2805 same-source re-query pattern already
used for `shipped_24h`: a lying writer still DISPUTES (verify re-derives the
count independently from Prometheus), but a true tile stays green.

- `verify.py`: `SPECS["firing_alerts"]` runner `alerts_am` -> `alerts_prom`;
  `run_alerts_am` (Alertmanager) -> `run_alerts_prom` (Prometheus
  `/api/v1/alerts`, `state==firing`, Watchdog excluded); removed the now-unused
  `AM_URL` constant; `cmd` text now names the Prometheus query.
- `tests/console-tile-verify.test.sh`: renamed the runner stub and added an
  offline parity lock (spec uses `alerts_prom` + `/api/v1/alerts`, `api/v2/alerts`
  absent; `run_alerts_prom` counts firing non-Watchdog, duplicate instances
  kept, pending excluded, never queries 9093).
- `tests/console-shipped-24h-race.test.sh`: renamed the runner stub.

## Verification

Live 2026-09-06 ~13:46Z — the writer and the NEW verifier were each run
against the live Prometheus `/api/v1/alerts` and agree:

- writer  (Prometheus /api/v1/alerts firing, non-Watchdog): 5
- verifier (same Prometheus query, same filter):            5
- PARITY writer == verifier == 5 -> no dispute on the live query.

- Injecting a lie (`firing_alerts.count=999`) against live Prometheus still
  DISPUTES: `mismatch firing_alerts: 1`, `disputed: True`,
  `reason: count displayed 999.0 vs verify 5.0` (a real lie is caught).
- A true tile (5) stays `disputed=False` / mismatch 0.

`run-proof` suite: `tests/console-tile-verify.test.sh` green (incl. the new
parity lock + tile-truth drill), `tests/console-shipped-24h-race.test.sh`
green, `tests/ci-standards-audit.test.sh` green, `tests/fleet-metrics-export.test.sh`
green, `bin/sgscan` no new findings, `python3 -m py_compile verify.py` OK.

`research:` established pattern — the same-source re-query was already the
#2805 fix for the `shipped_24h` tile dispute (#2690), and the #2532 directive
is to fix the collector/source mismatch rather than widen tolerance.
`help-first:` no new `bin/` file; existing verification paths all reused.

Closes #3637
