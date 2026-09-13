fix(tests): root-cause the #4263-repair P14 flakes (fleet-ops#6102)

Three recorded intermittent failures, fixed at the root cause. No retries, no sleeps. Closes #6102

## Root causes

1. tests/findings-ledger.test.sh wrote a fixed /tmp/findings-ledger.test.jsonl: 5 parallel copies appended to one shared file (collided or vanished on #6012's hosted run). Every artifact now lives in a private mktemp dir; the literal /tmp/*.jsonl|json|log writes are gone from it.

2. tests/agent-cron-seat-rotation.test.sh: `cat: write error: Broken pipe` under pipefail. Two causes, both fixed: the capture-then-`printf | grep -q` pipes became here-strings, and the fake_pi heredocs (seat-rotation, workdir-guard, deploy-workdir-guard) now drain their stdin (`cat >/dev/null`) so the runner's packet writer never EPIPEs when the fake exits early. One dead `printf | head -c 0` removed in agent-cron-packet-size.test.sh.

3. tests/fleet-deploy-check.test.sh, "off-main drift must invoke the sanctioned deploy to converge": the timing assumption was deploy_in_flight(), which scans the HOST process table for any fleet-ops-deploy (the production 2-min tick, a heartbeat block 0). When one of those is mid-run, the drill tick yields instead of invoking the spy, and the fixed expectation fails. Solo it passes; under xargs -P 8 (and next to the production tick) it flakes. Fixed by asserting convergence the way the bin defines it: the sanctioned deploy ran, OR the tick yielded for one of its two sanctioned reasons (`deploy already in flight` / `lock held`). Applied at every invocation-expecting site (2b, 4, 4-rc1, 6b, 14a, 14b) plus section 7's yield-reason grep, which the same collision shadows. No sleeps, no retries: the happened-to-be-quiet-instant assumption is gone.

## Same-class sweep

- Fixed shared /tmp paths (written+read by the test, collided across parallel copies): findings-ledger, findings-measure-line, cancelled-while-queued-detector, ci-failure-escalation-detector, stop-the-line-detector, org-ruleset-skip-detector, fleet-vibes-canary. Adjudicated, no fix needed: credential-expiry-canary and fleet-bare-metal-rebuild and fleet-researcher (their /tmp defaults never fire; the tests always export a mktemp'd override), fleet-ops-deploy(-rescue) (PathChanged=/tmp/intake-repos.json is the production contract asserted as unit-file text, not a test write), fleet-failed-command-flagged (/tmp/probe.log is fixture DATA inside a recorded transcript).
- Termination grep: `grep -rnE '/tmp/[A-Za-z0-9_.-]+\.(jsonl|json|log)' tests/*.test.sh` now only matches the adjudicated never-firing seam defaults and production-contract literals above; no test-written fixed shared path remains.
- Broken-pipe class (printf|grep -q or cat| into early-exit readers under pipefail): the recorded instances fixed; the remaining `| grep -Eq`/`grep -c` sites are full-read readers (no early exit, no SIGPIPE).

## Files: tests/ only

12 test files, +168/-104. No production code, no bin/ additions, no workflows.

Verification: the three target tests pass 5/5 each under `xargs -P 8` (15/15, after a first 4/5 round exposed the section-7 shadow, fixed, re-run 15/15); each also passes solo. The 6 sweep-edited tests pass concurrently under `xargs -P 4`. sgscan: no new security findings. P14: tests-only diff; CI runs the full P14 on this PR.

run-proof: `for i in 1 2 3 4 5; doprintf; done | xargs -P 8 -n1 sh -c 'bash <test> && echo PASS'` -> 15x PASS, exit 0 (findings-ledger 5, agent-cron-seat-rotation 5, fleet-deploy-check 5); solo exits 0 for all three; batch `xargs -P 4` -> 6x PASS exit 0 (cancelled-while-queued-detector, ci-failure-escalation-detector, stop-the-line-detector, org-ruleset-skip-detector, fleet-vibes-canary, findings-measure-line); sgscan exit 0.

relates: part of #6032 (the #4263 repair fallout).

net-positive-because: the -104 is the shared-/tmp and pipe-broken redundancy the root causes made necessary to delete; the +64 is the TD+trap+export scaffolding (6 files) and the spy_ran_or_yielded convergence helper that deletes the host-race class.

loose-ends: none
