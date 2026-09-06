## What

Close fleet-ops#3730: `ollama/deepseek-v4-flash:0731` empty-run churn. The 2026-09-05 snapshot reset the empty-run counter (count=4 at 20:17Z -> count=1 at 20:56Z), so the geometric bench cycled 900s -> 1800s -> 7200s and re-offered the dead seat within the hour, burning issue runs.

## How

The mechanism (`mark_seat_empty_run` count-merge persisted in the clobber-proof spawn-bench marker; `seat_usable` probe-gated hold from #3737) already lives in `lib/seat-lib.sh`. What was missing was a regression test that pins the exact #3730 contract end-to-end through `pick_seat` (the routing authority), so the counter-persistence-and-hold cannot silently regress.

New test `tests/seat-empty-run-count-persists-new-issue.test.sh` proves, for two simulated issues sharing the `ollama` provider:
1. Issue A empty-run -> marker count=1, backoff 900s (base).
2. New (fresh-issue) re-seat while the bench is active -> `pick_seat` reroutes to the healthy seat, never re-offers the benched deepseek seat.
3. Bench forced to wall_end but marker still fresh + the seat's latest evidence -> `pick_seat` still holds the seat (probe-gated re-admission, no fail-open) until a non-empty run proves it.
4. New issue empty-runs the SAME seat again -> count persists 1 -> 2, backoff escalates 900 -> 1800. It does **not** reset to 1 on a new issue id (the #3730 churn signature).

Hosted under `tests/ci-standards-audit.test.sh` (already in the P14 test list) with a named pin in `tests/p14-test-listing-gate.test.sh`, so CI runs it without a workflow-file edit.

No code change to `lib/seat-lib.sh` (mechanism verified present and correct). No new `bin/` organs. No migrations.

## Verification

Real run of the new test (scratch ledger/state, no network, no systemd):

```
OK: (1) issue A empty run: marker count=1, backoff=900s (base, geometric ladder starts at 1)
OK: (2) new issue B, bench active: pick_seat never re-offered the benched seat across 5 fresh-issue re-seats
OK: (3) new issue B, bench expired but marker is latest evidence (probe-gated hold): pick_seat never re-offered the benched seat across 5 fresh-issue re-seats
OK: (4) new-issue re-seat count persisted: count=2 (1->2), backoff=1800s (900->1800) — counter NOT reset on a new issue id (fleet-ops#3730)
OK: seat empty-run counter persists across a new-issue re-seat cycle and the seat is held until a non-empty run proves it (fleet-ops#3730)
```

`tests/seat-empty-run-count-persists-new-issue.test.sh` -> exit 0.

## run-proof

- Unit: `bash tests/seat-empty-run-count-persists-new-issue.test.sh` -> exit 0 (5 OK)
- Unit: `bash tests/p14-test-listing-gate.test.sh` -> exit 0 (`P14 test list is closed`; includes the new named pin)
- Unit: `bash tests/ci-standards-audit.test.sh` (host) -> exit 0
- Unit: sibling seat tests still green: `seat-empty-run-bench-sticks` (10 OK), `seat-empty-run-intermittent-count`, `seat-empty-run-park-persists`, `seat-empty-run-clobber-park`, `seat-noop-escalation` -> all exit 0
- Gate: `./bin/sgscan` on the changed files -> `No new security findings`
- Gate: `shellcheck` on the new test -> clean; `bash -n` -> OK
- Gate: `bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` -> `OK: no agent attribution detected`
- Pre-existing (not from this PR, reproduces on clean origin/main): nested `alert-repair-claim-mutex` timing/class-park flake inside `seat-lib.test.sh` -> exit 1. Unrelated to this change.

## Test plan

Covered by the unit run above: the new test drives `pick_seat` (not just `seat_usable`) for the fresh-issue re-seat, and asserts both the counter persists (1->2) and the seat is held (probe-gate) until a non-empty run proves it. P14 listing gate and the host test both pass, so the test runs in CI.

Closes #3730
