## Summary
- Re-verify the commandcode minimax/minimax-m3-free corpse. Snapshot 2026-09-06T12:30:16Z observed_at 2026-09-06T09:02:03.335Z: a 403 credentials_bad corpse with no bench_reason. That observed_at is one minute BEFORE the #3603 bench_reason fix in PR #3927 merged 2026-09-06T09:03Z — this issue is the exact fail-open detection bug #3603/#3927 already closed.
- The seat is already durably retired and auditable: cap=0 + intentional_cap_zero=corpse (fleet-ops#2700), parked ledger with bench_reason AND usable_at set (fleet-ops#2716/#3669), physical corpse ledger moved to lanes/seats-corpse-retired-2026-09-06T15:15:47Z/ by fleet-seat-comeback-release.
- The 403 is the provider's permanent free-slug retirement ("The free MiniMax M3 and M2.7 models have been retired"), not a billing wall and not a credential fault. The commandcode credential is LIVE — control probe commandcode/poolside/laguna-s-2.1-free returns PONG in the same window.
- No money spend: nothing to re-auth, no spend required; the only remedy (paid M3) is a paid tier and stays out of scope.

## Verification: real run results 2026-09-06T18:34Z
- Credential live: `pi --print --no-session --provider commandcode --model poolside/laguna-s-2.1-free 'Reply with exactly: PONG'` -> PONG, exit 0.
- Ledger parked + auditable: lanes/seats/commandcode__minimax_minimax-m3-free.json health_class=parked, seat_dead=true, failure_mode=corpse_retired, bench_reason="corpse-retired: cap=0 corpse bench, pick_seat never offers (durable, fleet-ops#2716/#3669)", bench_until=2036-09-03T15:15:47Z, usable_at=2036-09-03T15:15:47Z, consecutive_failure_count=0.
- Read-side authority: `seat_usable commandcode/minimax/minimax-m3-free` -> UNUSABLE (seat_dead=true, class=parked), rc=1 — pick_seat cannot offer the seat.
- Metric: `curl 127.0.0.1:9090/api/v1/query?query=fleet_pi_seat_dead_credential_total` -> 0. FleetDeadCredentialSeats absent from Alertmanager /api/v2/alerts (count 0).
- Retirement journal: `journalctl --user -u 'fleet-seat-comeback-release*'` shows parked-ledger commandcode/minimax/minimax-m3-free parked (bench_reason set, bench_until=2036-09-03T15:15:47Z) at 2026-09-06T15:15:47Z with the physical corpse moved to lanes/seats-corpse-retired-2026-09-06T15:15:47Z/ and no re-observation since.

## Tests
- JSON valid: `python3 -c "import json; json.load(open('config/seat-caps.json'))"` -> JSON valid.
- `bash tests/seat-caps-citation.test.sh` -> OK: rules 1-6 enforced, JSON parses (exit 0).
- `bash tests/seat-caps-citation-rule6-replay.test.sh` -> OK: live config accepted (exit 0).
- `bash tests/fleet-free-roster-canary.test.sh` -> OK: all scenarios incl. scenario19b production-lock pin (exit 0) + scenario13 worker_memory.
- `bash bin/sgscan` -> No new security findings.

## run-proof

run-proof: scenario19b in tests/fleet-free-roster-canary.test.sh pins cap=0 + intentional_cap_zero=corpse; live seat_usable UNUSABLE rc=1; journalctl RETIRED event; metric 0.
- scenario19b in tests/fleet-free-roster-canary.test.sh pins cap=0 + intentional_cap_zero=corpse production lock.
- With bench_reason now recorded (#3603/#3927), the fail-open corpse detector no longer re-files this durably-benched corpse — no re-observation in fleet-seat-comeback-release journal across subsequent ticks.
- organ-heartbeat: config/seat-caps.json not-an-organ: data-only comment append, no runnable organ touched.
- loose-ends-canary: none — sibling stale duplicates #3940/#3947/#3982 remain separate open issues owned by their own claims.

Closes #3963
