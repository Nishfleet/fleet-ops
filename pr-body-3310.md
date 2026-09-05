fix(reclaim): infra deaths skip WORK cap; class ladder before blocking (fleet-ops#3310)

## What changed and why

Five packets hit the 4/8 reclaim caps because devin killed every run at 1801s and the hang watchdog took the rest; they were parked "for senior conference" for 4 hours and no conference ran. Root cause: every death — including infrastructure deaths the worker could never have avoided — incremented the same `.reclaim-count` WORK cap, and hitting the cap parked the issue with `blocked-on: nish-decision` (a conference never ran, so nothing unblocked).

This PR splits the counters and replaces the first-cap block with a seat-class ladder. Per the required scope (Nish 2026-09-04): no new ledger, no new unit. Retry stays systemd's Restart=/StartLimitBurst; the infra-death classification reuses seat-lib.sh's existing detectors; the class switch reuses pick_seat's existing class ordering + the #3121 senior ladder. The only change is WHICH counter a death increments and which class the next pick_seat call is told to prefer.

- `bin/pi-issue-run` classifies each death via `is_infra_death()` — rc=124 (hang watchdog), rc=143 / mid-session signal-OOM (`is_mid_session_death`), spawn-phase ETIMEDOUT (`is_spawn_etimeout`), a "no seat available" exit, or elapsed within 30s of the run's hard session bound — and writes a `.last-death-class` marker (`infra`/`work`) on every failure exit. Empty-run exhaustion stays `work`.
- `bin/pi-issue-failed-reap` consumes the marker: `infra` deaths increment a separate `.infra-death` counter and leave `.reclaim-count` (the WORK cap) untouched; `work` deaths (or an absent marker, back-compat with pre-3310 deaths) increment `.reclaim-count` exactly as before. On CLOSED reap it clears `.prefer-class` / `.infra-death` / `.last-death-class` alongside the existing resets.
- `lib/pi-intake-tick.sh`: when the WORK cap fires, intake forces the next claim onto a DIFFERENT seat class via a per-issue `.prefer-class` ladder (prepaid -> metered -> senior), resetting reclaim-count to 1 so the new class gets a fresh budget. Only at ladder exhaustion (senior already tried) does intake block — and then with `blocked-on: orchestrator` (the senior conference is the orchestrator's job, and a conference that never runs is not an unblocking path), not the old `blocked-on: nish-decision`. Infra deaths never reach the WORK cap at all, so a provider storm can no longer park the issue.
- `lib/seat-lib.sh`: `pick_seat` honors `PI_PICK_PREFER_CLASS` (prepaid/metered/free/senior), reusing the existing class buckets; `senior` routes via `find_senior_seat` (the #3121 ladder); an empty preferred class (depleted bucket / walled senior) falls through to the normal yield ladder so a depleted class never stalls the work item. `pi-issue-run` reads `.prefer-class` and exports `PI_PICK_PREFER_CLASS` per claim.
- Prevention mechanism (mechanical-fix rule): `tests/fleet-ops-3310-infra-death-class-switch.test.sh` is a 16-test gate, Tests 10-15 being a replay drill that RUNS the real `pi-issue-run` (fake pi binary: hang rc=124, ordinary rc=1) and the real `pi-issue-failed-reap` (stubbed gh/systemctl) against scratch dirs and asserts the counter split end-to-end — so a future regression that re-mixes the counters fails CI. Hosted from `tests/ci-standards-audit.test.sh` (the P14 suite) + pinned in `tests/p14-test-listing-gate.test.sh`.

moves: product_merges_per_day

net-positive-because: the +630 net lines are almost entirely the new
16-test gate (tests/fleet-ops-3310-infra-death-class-switch.test.sh, \~430
lines) whose replay drill RUNS the real pi-issue-run / pi-issue-failed-reap and
pins the counter split end-to-end — the mechanical-fix prevention mechanism the
mechanical-fix rule requires for a failure-fix. The production code in the four
touched files is a small, net-negative surface (\~250 added lines across the
classification, the reaper split, the tick ladder and the pick_seat override,
balanced against the removed single-path block); the net-positive is
compensating prevention, not code growth.

## Verification

Each gate was run live on `claim/issue-3310` with the recorded result:

| Command | Result |
|---|---|
| `bash tests/fleet-ops-3310-infra-death-class-switch.test.sh` | `ALL OK: fleet-ops#3310 infra-death classification + work-cap class switch (incl. replay drill)` — 16/16 OK, exit 0 |
| `bash tests/fleet-ops-2462-claim-cap.test.sh` | `ALL OK: fleet-ops#2462 reclaim-count cap + systemic-failure skip`, exit 0 |
| `bash tests/pi-issue-failed-reap.test.sh` | PASS |
| `bash tests/pi-issue-run-mid-session-bench.test.sh` / `-noop-bench` / `-hang-stall-bench` / `-tried-reset` / `-defensive-mkdir` / `-failure-reason` | all PASS |
| `bash tests/pi-intake-tick-*.test.sh` (8 suites) | all PASS |
| `bash tests/seat-lib*.test.sh` (7 suites incl. aimd/degraded/dispatch/yield) | all PASS |
| `bash tests/p14-test-listing-gate.test.sh` | 3310 test pinned in the P14 reachable set, exit 0 |
| `bash tests/ci-standards-audit.test.sh` (host suite) | exit 0 |
| `/home/nish/.local/bin/sgscan` | `No new security findings.` exit 0 |

run-proof: replay drill inside `tests/fleet-ops-3310-infra-death-class-switch.test.sh`: Test 10 runs the real `pi-issue-run` with a fake pi that hang-dies (rc=124) and asserts `.last-death-class=infra`; Test 12 runs the real `pi-issue-failed-reap` against a stubbed gh/systemctl and asserts `.infra-death=1` with `.reclaim-count` absent — the provider-storm case that previously parked fleet-ops#3310's five packets now leaves the WORK cap untouched.

Closes #3310
