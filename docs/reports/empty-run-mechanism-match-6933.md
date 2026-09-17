# Empty-run mechanism match for #6933

Issue #6933 asks to file or match a mechanism for the incident in #2934.
The match is #2934 itself, implemented by [PR #2948](https://github.com/Nishfleet/fleet-ops/pull/2948).
GitHub reports that PR merged on 2026-09-02 at 21:04:36 UTC, before the
2026-09-14 audit report. No new count-window change is needed.

## Mechanism

The current code is in `lib/litellm-seat.sh`:

- `mark_seat_empty_run` reads the durable bench marker before the health
  ledger. An empty-run marker uses `EMPTY_RUN_COUNT_WINDOW_S`; a spawn
  failure marker uses `EMPTY_RUN_MARKER_FRESH_S`.
- It takes the greater prior count from the marker and ledger, increments
  it, and writes both the fault ledger and bench marker. A healthy HTTP
  observation cannot erase the count held in the separate marker.
- `seat_usable` checks the bench marker before accepting healthy ledger
  data, so the seat remains excluded until its bench expires.

The mechanism already has the regression test
`tests/seat-empty-run-intermittent-count.test.sh`. Its CI host is
`tests/ci-standards-audit.test.sh`, with the host pinned by
`tests/p14-test-listing-gate.test.sh`.

## Verification

On 2026-09-17, ran:

```sh
bash tests/seat-empty-run-intermittent-count.test.sh
```

Result: exit 0, all eight named cases passed, plus the summary assertion.
The test uses the real library with scratch state and no network or systemd:

- Two empty runs separated by a simulated 6120 seconds retain count 1 to 2,
  despite an intervening healthy HTTP-200 ledger write.
- A third empty run reaches the test ceiling of 3 and makes `seat_usable`
  reject the seat. This run observed a 21600-second bench, not a claimed
  24-hour bench.
- Expired counts reset. Same-class spawn failures keep their shorter window.
  Cross-class cases preserve or discard counts according to marker type.

The tested source was worktree base
`5a2f457663ce87122412054bc3bcdeb415769ea2`, also the observed `origin/main`
head. This is offline code proof, not a claim of a live provider replay or
an install performed by this PR. The local clone is shallow; an ancestry
check for the historical PR merge SHA returned 1 and is not used as proof.
The PR merge date above comes from GitHub's PR record.

## Disposition

Match #6933 to #2934 / PR #2948 and its existing regression test. Keep the
current freshness logic. No new checker, timer, configuration, or runtime
code is required. This report supplies the missing audit link, not a new
seat repair.
