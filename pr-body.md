fix(seat): flatten empty-run bench to a flat 15-min no-op cooldown

What changed and why:

Issue fleet-ops#2343 asked two things:
(1) permanently retire seat_dead=true corpses instead of re-probing them;
(2) make the empty-run classifier distinguish a provider no-op from a real
    quota wall so the escalating backoff does not churn healthy seats.

Ask (1) was already delivered by #2344 (fleet-ops#2327, merged
2026-08-30T09:41:41Z, 11 min after this issue was filed against the
09:30:15Z snapshot): seat_dead=true is a TERMINAL exclusion in both
seat_usable() and the pick_seat excluded set (a stale observed_at does not
resurrect a corpse), the ledger reclassifies to the terminal corpse class,
and minimax/MiniMax-M3 (quota_exhausted) reclassifies via the corpse rules
once its 402 observation ages past the 24h quota age. Recovery is solely
the weekly seat-walled-probe success. Verified on current main:
lib/seat-lib.sh seat_usable() lines 1280-1292 and the roster seat_dead
exclusion at lines 2189-2220 are the #2327 absolute exclusions.

This PR ships ask (2) — the empty-run classifier fix. A provider no-op
(pi exits 0, stdout < OUT_MIN) is NOT a quota/rate/5xx wall: the
fleet-ops#1408 count ladder (900 -> 1800 -> 3600 -> 7200s) churned HEALTHY
seats — openrouter/deepseek/deepseek-v4-flash-0731 produced 3 empty runs
in 2h (fleet-ops-1384, stdout=0B), was benched 900s and re-seated
in-process each time, and the ladder kept extending a working seat's bench
to hours after a handful of no-ops. The classification was already correct
(pi-issue-run routes no-ops to mark_seat_empty_run and real spawn walls to
mark_seat_spawn_fail); only the bench-by-count escalation was wrong for
the no-op class.

Fix:
- mark_seat_empty_run now benches a FLAT EMPTY_RUN_BACKOFF_S (900s) at
  every count; the fleet-ops#1408 count ladder is removed for empty runs.
- The count still merges for observability and for the fleet-ops#1362
  failure-ceiling park — 60 consecutive no-ops still park the seat behind
  the 24h wall (the extreme dead-seat guard), so a truly broken seat is
  still retired from the retry loop while an occasionally-no-op'ing
  healthy seat stays on a flat 15-min cooldown.
- mark_seat_spawn_fail (real walls: non-zero exit, HTTP 429/402/500,
  spawn ETIMEDOUT) keeps the escalating ladder — that churn breaker is
  still correct for genuine walls.
- EMPTY_RUN_BACKOFF_CAP_S (the 2h cap) is removed; nothing referenced it
  outside lib/seat-lib.sh and the updated test.

Mechanism: the updated tests are the regression drill that proves the
guard fires — seat-noop-escalation.test.sh asserts the FLAT cooldown
(900s at counts 1, 2, 3 and 8), and seat-failure-ceiling.test.sh still
proves the 60-failure park fires for empty runs (mark_seat_empty_run is
one of its five run_park_case marker types). Reintroducing the ladder
fails the first drill red.

Verification (exact commands + results, run in this session):

- `bash tests/seat-noop-escalation.test.sh` -> exit 0, PASS:
  spawn-fail escalates 300 -> 600 -> 1200 -> cap 3600 (unchanged); empty
  run FLAT at 900s for counts 1, 2, 3 and after 8 no-ops (no ladder).
- `bash tests/seat-failure-ceiling.test.sh` -> exit 0, PASS:
  empty-run park case parks at count=60 with the 24h wall, metric
  emitted, seat_usable holds (the #1362 guard still fires).
- `bash tests/pi-issue-run-noop-bench.test.sh` -> exit 0, PASS:
  provider no-op (exit 0, 0B stdout) benches via mark_seat_empty_run,
  usable_at = +900s flat cooldown, pick_seat reroutes to a healthy seat;
  verdict empty-run (tools=0) same; in-process retry unchanged.
- `bash tests/seat-spawn-bench-clobber.test.sh` -> exit 0, PASS
  (mark_seat_empty_run clobber-proof bench marker survives).
- `bash tests/seat-lib.test.sh` -> exit 0, PASS (host suite incl. all
  seat tests above, seat-walled-probe, quarantine, degraded, dispatch).
- `bash tests/ci-standards-audit.test.sh` -> exit 0, PASS (incl. the
  P14 test-listing gate and loose-ends canary scenarios).
- `shellcheck -S error lib/seat-lib.sh bin/pi-issue-run
  tests/seat-noop-escalation.test.sh tests/pi-issue-run-noop-bench.test.sh
  tests/seat-lib.test.sh` -> clean, rc=0.
- `sgscan` -> "No new security findings", rc=0.
- crgate: skipped locally (CodeRabbit not signed in on this host, same as
  #2344); the PR's CI CodeRabbit review covers it.

run-proof: no systemd unit, timer, path unit, or GitHub workflow added in
this PR; the run is the repo test suite above, all green.

loose-ends-canary: none (PR is armed for auto-merge on open).

Closes #2343