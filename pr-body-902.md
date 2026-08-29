## Summary

The empty-run fix for #902 landed in #1679 (wrapper-side: `is_empty_run` in
`bin/pi-issue-run` + `mark_seat_empty_run` in `lib/seat-lib.sh`) and #1466
(classifier-side: `seat-health.ts` `empty_run` mode). All three of Nish's
requirements are met:

1. **Classify tools=0+no-text as a retryable lane fault** — `is_empty_run`
   detects a `PACKET-VERDICT tools=0` run with no final text; `mark_seat_empty_run`
   benches the seat with `failure_mode=empty_run`, `health_class=transient_fault`,
   `EMPTY_RUN_BACKOFF_S=900` (15 min), matching the 429-like cooldown.
2. **Auto-reroute to the next healthy seat** — empty run exits 1 so systemd
   `Restart=on-failure` re-seats; `pick_seat` skips the benched seat via
   `usable_at` and picks the next healthy one.
3. **Auto re-eligible after cooldown** — `usable_at = now + 900s`, fail-opens
   after; no manual re-arm, no permanent demotion, no two-strikes charge to
   the packet (the strike is on the seat, not the packet).

#1679 used `Relates to #902` (not `Closes`), so the issue stayed open. This
PR closes that linkage gap AND wires the regression test into CI so a future
regression is caught.

## What this PR changes

- **`tests/seat-lib.test.sh`**: hosts `pi-issue-run-noop-bench.test.sh` (the
  #902 regression test) so it runs in CI. Hosted here (not
  `ci-standards-audit.test.sh`) because `seat-lib.test.sh` is listed directly
  in `ci.yml` and runs independent of the `p14-test-listing-gate`, so the
  regression test runs even while pre-existing orphan-listing gaps (#1792)
  keep that gate red.
- **`tests/p14-test-listing-gate.test.sh`**: removes
  `pi-issue-run-noop-bench.test.sh` from `known_orphans` (it is now hosted,
  no longer an orphan).

No new machinery: the fix code (`bin/pi-issue-run`, `lib/seat-lib.sh`) and
the regression test (`tests/pi-issue-run-noop-bench.test.sh`) already landed
in #1679. This PR only wires the existing test into CI and closes the issue.

## Verification

```
$ bash tests/pi-issue-run-noop-bench.test.sh
OK: no-op -> mark_seat_spawn_fail called for devin/glm-5-2
OK: ledger usable_at is in the future
OK: intake re-spawn pick_seat skips devin/glm-5-2 and picks devin/swe-1-7
OK: pi-issue-run no-op benches the seat so re-seat picks a different seat
OK: empty-run -> mark_seat_empty_run called for devin/swe-1-7
OK: ledger failure_mode=empty_run usable_at=+900s (~15 min cooldown)
OK: pick_seat skips the empty-run seat and re-routes to devin/glm-5-2
OK: empty-run (tools=0 + no final text) fails loudly, benches 15 min, re-routes to the next seat
EXIT=0

$ bash tests/seat-lib.test.sh   # CI host chain: ci.yml -> seat-lib -> noop-bench
EXIT=0   # noop-bench ran inside seat-lib.test.sh and passed

$ bash tests/seat-health-classifier.test.sh   # sibling #1466 classifier half
OK: inv1: 2xx + empty body classifies as transient_fault
OK: inv2: classifyCliOutput('', 0) returns transient_fault
OK: inv3: 2xx + real content still classifies as healthy
EXIT=0
```

The p14-test-listing-gate still exits 1 on 3 pre-existing orphan tests
unrelated to this PR (`staleness-checker`, `open-question-sweep-deleted`,
`gh-webhook-receiver-live-e2e`); filed as #1792. P14 is not a required
check (PR #1791 merged with P14 red), so this does not block merge.

Closes #902
