## Why

The corpse ledger `opencode/muse-spark-1.2-contributor-free` (seat_dead=true, terminal "corpse" class, c=150 straight HTTP 500s, no usable_at comeback clock by construction, fleet-ops#2415) was counted in `seats_walled` (10) by the seat-roster census forever. A corpse never releases and is re-entered only by manual repair (fleet-ops#2145/#2327), so counting it walled depresses the walled/healthy census with capacity that is not coming back — and the seat-availability SLO burn (fleet-ops#1291 + FleetSloSeatAvailSlowBurn) reads a distorted walled picture.

## Scope

- **config/seat-caps.json**: retire the roster row — `intentional_cap_zero` flips `stale` -> `corpse` (cap stays 0, so the free-roster-canary lock holds; the seat is no longer a "re-audition when the external condition clears" candidate). Dated reason appended to `_muse_spark_contributor_free`.
- **lib/seat-lib.sh**: `corpse` joins the intentional cap-0 class (dead_decoy / money_only / corpse), so the cap-0 skip line classifies INTENTIONAL (never re-audition), not stale (fleet-ops#1432 classification).
- **opus-heartbeat-gather** (installed organ at `/home/nish/.local/libexec/opus-heartbeat-gather`, NOT repo-tracked — same precedent as fleet-ops#2152 / fleet-ops#2407; backup `.bak-2435-20260830T212007Z`): `seat_table()` counts a seat_dead corpse `dead` (new `dead_n` aggregate, per-row `dead` flag) and never `walled`; the per-walled-seat comeback probe (`t_seat_probes_walled_comebacks`) skips corpses entirely, mirroring `_read_comeback_overdue` in libexec/fleet-metrics-export.py. The flat view gains `seats_dead` for the delta.
- **tests**: a corpse fixture in `tests/opus-heartbeat-seat-comeback.test.sh` pins the census dead-not-walled classification (corpse row dead=true walled=false, dead_n=1, walled_n unchanged for real walls, corpse absent from the comeback probe); `tests/seat-lib.test.sh` pins `corpse` as an intentional cap-0 class in the per-pick excluded summary.

## Verification

- `bash tests/opus-heartbeat-seat-comeback.test.sh` -> ALL OK (incl. new corpse assertions).
- `bash tests/seat-lib.test.sh` -> OK (incl. `1432-capclass: cap=0 classification (2 intentional incl. corpse / 1 stale)`).
- `bash tests/seat-health-seat-dead.test.sh`, `tests/fleet-free-roster-canary.test.sh`, `tests/fleet-metrics-export.test.sh`, `tests/opus-heartbeat-thorough-mode.test.sh`, `tests/opus-heartbeat-allowlist-gate.test.sh` -> all OK.
- Full CI list (59 tests from `.github/workflows/ci.yml`) -> all pass.
- `sgscan --base origin/main` -> no new findings.
- Live run of the deliverable (the census): `OPUS_HB_STATE=<tmp> SEATS_DIR=/home/nish/workspaces/agent-state/lanes/seats python3 opus-heartbeat-gather` -> `n=28 healthy_n=17 walled_n=9 released_n=1 dead_n=1 excluded_n=9`; muse row `walled=False dead=True released=False health_class=corpse seat_dead=True` — seat absent from seats_walled (was walled_n=10 before).

run-proof: census run above (`walled_n 10 -> 9`, muse row dead=true walled=false) plus `tests/opus-heartbeat-seat-comeback.test.sh` `ALL OK`. The live census (`/home/nish/.local/state/opus-heartbeat/snapshot.json`) now shows `seats_walled=9, dead_n=1` on the next gather tick.

Closes #2435