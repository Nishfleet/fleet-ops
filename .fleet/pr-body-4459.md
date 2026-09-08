feat(spend): rate card in seat-caps, measure.sh usd_24h, fleet_usd_24h prom metric, per-session USD in the prepaid-usage counter (fleet-ops#4459)

## Summary

The fleet knows merges/day but nothing about $/merge across seats. This
closes the blind spot with the existing rails (prepaid-usage counter, session
jsonl usage, seat-caps, fleet-metrics export) — no new timer, no new organ.

1. **Rate card** in `config/seat-caps.json`: per-token USD per 1M input /
   output / cached on the metered/prepaid seats that carry real session usage
   (crof, minimax, runinfra, entrim, straitly, xai-oauth), each with a
   `_rate_card` source citing the config/pi-models.json cost field and a date
   (sr-never-vibes compliant). Flat prepaid seats carry `flat_usd_per_month`
   (left `null` where no documented figure exists — reported UNAVAILABLE, never
   a fabricated $0). `jq '.providers.crof.usd_per_1m_input'` is now non-null
   with a source (acceptance).
2. **`measure.sh`** (repo root): prints `usd_24h: metered=<n> flat_share=<n>
   unavailable=<seats>` and `usd_per_merged_pr: <n>` — consumed by the judge
   header's third line (product: → waste: → usd_24h: per the fable header
   order) and the weekly seat table. Metered USD is session usage tokens × rate
   card; free seats are measurably $0; unreadable seats are named UNAVAILABLE.
   `bash measure.sh | grep -E '^usd_24h:'` prints metered and flat_share
   (acceptance).
3. **`fleet_usd_24h`** (+ `fleet_usd_per_merged_pr`) in
   `libexec/fleet-metrics-export.py`, emitted from the same
   `lib/fleet_usd.py` math measure.sh uses so the two cannot drift.
   `fleet_usd_24h` is present in the exported prom family (acceptance).
4. **Per-session USD spend line**: `bin/pi-issue-run` records the session's
   USD (usage × rate card) into the existing `prepaid-usage/<provider>.json`
   counter as a new `usd` field at run end. A seat with no rate card records
   `usd="UNAVAILABLE:no-rate-card"` — never a fabricated $0 (required).
5. **Weekly review** (`prompts/weekly-fleet-review.md` L3 lens): the seat
   table is now a $/merged-PR-per-seat read and names the worst seat by $/merge.

The math is centralized in `lib/fleet_usd.py` so measure.sh, the prom exporter,
and the per-session counter all share one rate-card computation.

## Verification

Accepted on a fixture session dir (1M in / 1M out / 1M cached tokens, crof):

    $ bash tests/fleet-usd-spend.test.sh
    OK: rate card present + dated sources (crof, minimax, runinfra, entrim, straitly, xai-oauth)
    OK: measure.sh prints: usd_24h: metered=0.1830 flat_share=0.0000 unavailable=none
    OK: lib/fleet_usd.py computes 0.183 for 1M/1M/1M crof (matching rate card)
    OK: exporter emits fleet_usd_24h + fleet_usd_per_merged_pr
    OK: no-rate-card seat records UNAVAILABLE (not a fabricated $0)
    PASS

    $ bash measure.sh | grep -E '^usd_24h:'
    usd_24h: metered=19.7985 flat_share=0.0000 unavailable=...

    $ jq '.providers.crof.usd_per_1m_input' config/seat-caps.json
    0.08

run-proof:
- `bash tests/fleet-usd-spend.test.sh` → PASS (offline fixture, no gh/prom/systemd)
- `bash tests/seat-caps-citation.test.sh` → all scenarios pass (rate card carries dated + measured citation)
- `bash tests/seat-lib.test.sh` → 80 passed, 0 failed (seat-lib change)
- `bash tests/fleet-metrics-export.test.sh` → main() emits (includes MANIFEST assertion, unchanged)
- `bash tests/pi-issue-run-tried-reset.test.sh` → rc=0 (pi-issue-run success-path change)
- `bin/sgscan` → "No new security findings"

test plan: `bash tests/fleet-usd-spend.test.sh` is the new offline pin; run it
before merge. The judge/header and weekly wiring consume measure.sh output and
are verified at the next judge run (out-of-repo agent-state).

net-positive-because: the rate card, the shared USD math, and the prom metric
are the durable measurement rails the whole $/merge project depends on; the
lines added are config/pricing + one new measure.sh + one lib module + tests.
No new timer/organ/unit.

research: official/published provider pricing already lives in
config/pi-models.json cost fields (the in-repo authority) — adopted that over
hand-retyping dashboard numbers; compared against the existing fleet_seat_spend_usd
(usage.cost-based) rail and generalized it to token-based rate pricing so seats
without usage.cost can still be priced (fleet-ops#4459, #3283).
help-first: read pi-models.json cost fields and the existing fleet-metrics-export
usage.cost parser (libexec/fleet-metrics-export.py) before building; they did
not already produce a rate-card X tokens USD or a usd_24h / $/merge line, so
measure.sh + lib/fleet_usd.py were the smallest addition.

Closes #4459
