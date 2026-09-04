fix(reclaim): infra deaths skip WORK cap; class ladder before blocking (fleet-ops#3310)

## What changed and why

Five packets hit the 4/8 reclaim caps because devin killed every run at 1801s
and the hang watchdog took the rest; they were parked "for senior conference"
for 4 hours and no conference ran. Root cause: every death — including
infrastructure deaths the worker could never have avoided — incremented the
same `.reclaim-count` WORK cap, and hitting the cap parked the issue with
`blocked-on: nish-decision` (a conference never ran, so nothing unblocked).

This PR splits the counters and replaces the first-cap block with a seat-class
ladder, per the required scope (no new ledger, no new unit; retry stays
systemd's Restart=/StartLimitBurst; infra classification reuses the detectors
seat-lib.sh already has):

- `bin/pi-issue-run` classifies each death via `is_infra_death()` — rc=124
  (hang watchdog), rc=143 (signal), `is_mid_session_death`, `is_spawn_etimeout`
  (spawnSync ETIMEDOUT / connect timeout), a `no seat available` exit, or a
  hard-ceiling provider whose elapsed is within 30s of `PI_HANG_TIMEOUT_S` —
  and writes a `.last-death-class` marker (`infra`/`work`). Empty-run
  exhaustion stays `work`.
- `bin/pi-issue-failed-reap` consumes the marker: `infra` deaths increment a
  new `.infra-death` counter and leave `.reclaim-count` (the WORK cap)
  untouched; `work` deaths (or an absent marker, back-compat with pre-3310
  deaths) increment `.reclaim-count` exactly as before. On CLOSED reap and on
  shipped success, `.prefer-class` / `.infra-death` / `.last-death-class` are
  cleared so a fresh claim cycle starts clean.
- `lib/pi-intake-tick.sh`: when the WORK cap fires, the next claim is forced
  onto a different seat CLASS via a per-issue `.prefer-class` ladder:
  prepaid -> metered -> senior, each rung resetting reclaim-count to 1 so the
  new class gets a fresh budget. Only when the ladder is exhausted (senior
  already tried) does intake block — and then with
  `blocked-on: orchestrator` (the senior conference is the orchestrator's
  job), not the old `blocked-on: nish-decision`. Infra deaths never reach the
  WORK cap at all, so a provider storm can no longer park the issue.
- `lib/seat-lib.sh`: `pick_seat` honors `PI_PICK_PREFER_CLASS`
  (prepaid/metered/senior), reusing the existing class buckets and the #3121
  senior ladder when it lands; an empty preferred class falls through to the
  normal yield ladder so a depleted class never stalls the work item.
  `pi-issue-run` reads `.prefer-class` and exports `PI_PICK_PREFER_CLASS` per
  claim.
- Prevention mechanism (mechanical-fix rule): `tests/fleet-ops-3310-infra-death-class-switch.test.sh`
  is a 17-test gate, Tests 12–17 being a replay drill that RUNS the real
  `pi-issue-run` (fake pi binary: rc=124 hang, rc=1 work, no-seat) and the
  real `pi-issue-failed-reap` (stubbed gh/systemctl) against scratch dirs and
  asserts the counter split end-to-end — so a future regression that re-mixes
  the counters fails CI. Hosted from `tests/ci-standards-audit.test.sh` (the
  P14 suite) + pinned in `tests/p14-test-listing-gate.test.sh`.

## Verification

Each gate was run live on `claim/issue-3310` (worktree
`/home/nish/workspaces/agent-worktrees/issue-fleet-ops-3310`, base origin/main
76d23494) with the recorded result:

| Command | Result |
|---|---|
| `bash tests/fleet-ops-3310-infra-death-class-switch.test.sh` | `ALL OK: fleet-ops#3310 infra-death classification + work-cap class switch (incl. replay drill)` — 17/17 OK, exit 0 |
| `bash tests/fleet-ops-2462-claim-cap.test.sh` | `ALL OK: fleet-ops#2462 reclaim-count cap + systemic-failure skip`, exit 0 |
| `bash tests/p14-test-listing-gate.test.sh` | `OK: p14-test-listing-gate.test.sh: P14 test list is closed`, exit 0 |
| `bash tests/ci-standards-audit.test.sh` (host suite, 57 tests) | exit 0 |
| `/home/nish/.local/bin/sgscan` | `No new security findings.` exit 0 |
| shellcheck (on pi-issue-run, pi-issue-failed-reap, pi-intake-tick) | clean — inside Test 11 of the 3310 gate |

run-proof: transcript — replay drill inside
`tests/fleet-ops-3310-infra-death-class-switch.test.sh`: Test 12 runs the real
`pi-issue-run` with a fake pi that hang-dies (rc=124) and asserts
`.last-death-class=infra`; Test 15 runs the real `pi-issue-failed-reap`
against a stubbed gh/systemctl and asserts `.infra-death=1` with
`.reclaim-count` absent — the provider-storm case that previously parked
fleet-ops#3310's five packets now leaves the WORK cap untouched.

Note: local `crgate` (CodeRabbit CLI) could not run — `CodeRabbit is not
signed in on this machine` (exit 3). This host has no CodeRabbit auth;
CodeRabbit review runs on the PR itself. Flagged, not walked past.

Closes #3310