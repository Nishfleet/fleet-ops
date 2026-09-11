## What
fleet-seat-bench-truth.service wedged Result=start-limit-hit at 2026-09-11T16:16Z under the seats-ledger path-unit storm (Closes #5471). The bin's 60s sweep debounce coalesces the side effects, but systemd still counts every queued path trigger as a start, and the installed unit at that moment was stale — it lacked the `StartLimitIntervalSec=0` the repo unit has had since #5323 — so systemd's default StartLimitBurst=5 tripped inside one 10s window and every later trigger was dropped until `reset-failed`. Fable's reset-failed was a band-aid, not the fix.

## Fix (structural, debounce owned by the unit)
- The repo unit already carries `StartLimitIntervalSec=0` in [Unit] (the #5093/#622 storm convention) — with it installed, systemd's start counter can never trip and the unit cannot re-enter failed during a write storm. No repo change needed there; this PR pins it.
- New drill test `tests/fleet-seat-bench-truth-path-storm-drill.test.sh`:
  1. repo unit keeps `StartLimitIntervalSec=0` in [Unit]; path unit carries no conflicting StartLimit.
  2. bin keeps the 60s `FLEET_SEAT_COMEBACK_SWEEP_GAP_S` debounce (coalescing layer, visible skip line).
  3. sandbox drill (CI-safe): 10 `--false-wall-only` triggers fired inside 5s in a scratch ledger → **exactly 1 full sweep + 9 debounce-skips**, every trigger exit 0.
  4. live drill (skips on hosted CI / unit not installed): stale-deploy detector — the INSTALLED unit must still contain `StartLimitIntervalSec=0` (the exact #5471 outage mode — the installed copy was stale until 19:38Z); then 10 real triggers into the watched seats dir in 5s asserting the unit never enters failed and the path unit stays active.

## Verification
- `bash tests/fleet-seat-bench-truth-path-storm-drill.test.sh` → all layers OK on the live VPS:
  - 10 triggers in 5s sandbox drill: 1 full sweep + 9 debounce-skips, elapsed 1s, all exit 0.
  - live storm: 10 triggers in 5s, unit ends `Result=success`, path unit still active, one full sweep ran.
- `sgscan` → No new security findings.
- `bin/fleet-no-agent-names-check` and `bin/fleet-exec-review-canary` pass (see run-proof below).

run-proof: fleet-seat-bench-truth-path-storm-drill.test.sh sandbox + live layers ran green pre-push (1 full sweep + 9 debounce-skips over 10 triggers in 5s; installed-unit detector green); unit state post-drill `Result=success`, `fleet-seat-bench-truth.path` active.

Test plan
- `bash tests/fleet-seat-bench-truth-path-storm-drill.test.sh` (layer 4 auto-skips on hosted CI where the user unit is absent)

research: n/a (test-only change; no new bin/ file)
help-first: n/a
organ-heartbeat: tests/fleet-seat-bench-truth-path-storm-drill.test.sh not-an-organ: pins an existing organ's unit contract, adds no new organ
loose-ends: ci-wiring — the test is not added to .github/workflows/ci.yml because the worker token cannot push workflow files (repo rule, ci.yml comment block); it runs green standalone on the VPS and on any box with user systemd; wiring it into ci.yml is a one-line CI follow-up for a workflow-capable lane
loose-ends: bench-truth-storm


## Follow-up commit (P14 reachable-set closure)
The first CI run red'd because the drill test was not reachable from any listed test (`FAIL: 1 test file(s) are neither in ci.yml, hosted by a listed test...` — p14-test-listing-gate). Fixed by hosting it in `tests/ci-standards-audit.test.sh` (the #566 mechanism: workers cannot push .github/workflows/**), which replaces the ci-wiring loose-end above — no workflow-file edit needed:
- `bash tests/p14-test-listing-gate.test.sh` → exit 0, "P14 test list is closed" (21.6s, drill now reachable)
- `bash tests/ci-standards-audit.test.sh` → ALL PASSED, exit 0 (9m10s, runs the drill as a child)
- `sgscan` → No new security findings
- `bin/fleet-no-agent-names-check --pr-body <body> --commit-range origin/main..HEAD` → "OK: no agent attribution detected"
