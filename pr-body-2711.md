fix(canary): claims-aware frozen-queue gate so a zero-dispatch/nonzero-claim window is no longer misclassified frozen (fleet-ops#2711)

The opus-heartbeat launcher's `queue_frozen()` gate (introduced by fleet-ops#1453) decides whether the narrow `--unit repair-*` direct-dispatch lever is allowed. The earlier gate was:

```
waste.dispatches_last_2h <= 1  AND  fleet.ready_work > 50
```

`waste.dispatches_last_2h` measures the **alert-repair** pipeline (DISPATCH events from `alert-repair/actions.log`); pi-issue activity is recorded separately in `ready-work-claims.log` as `claims_last_2h`. The two are independent streams. The live snapshot at 2026-09-01T21:30:13Z showed exactly the broken shape: `dispatches_last_2h=0`, `claims_last_2h=28`, `ready_work=31` — alert-repair idle, pi-issue alive, ready_work one bump from the threshold. The earlier gate would have ALLOWED the lever as soon as ready_work crossed 50 despite pi-issue dispatching claims every minute, routing work to a seat via `--unit repair-*` instead of through intake. That is the exact symptom the live #1453 run needed the gate to prevent.

The fix makes the gate check BOTH pipelines:

```
waste.dispatches_last_2h <= 1
AND claims_last_2h         <= 1
AND fleet.ready_work       >  50
```

A zero-dispatch/nonzero-claim window is now classified HEALTHY (alert-repair idle, pi-issue alive) and the lever stays shut. Only when both pipelines are silent does the lever fire — bounding it to genuine queue death across both streams.

## Scope

- **live launcher** `/home/nish/.local/libexec/opus-heartbeat` (NOT repo-tracked; user-config install): `queue_frozen()` now reads `snap.claims_last_2h.n` (canonical field the heartbeat gather script populates) with a `flat.claims_last_2h` fallback for fixtures. New `OPUS_HB_FROZEN_CLAIMS` env knob (default 1) per-axis alongside `OPUS_HB_FROZEN_DISPATCHES` and `OPUS_HB_FROZEN_READY`. Gate comment block cites fleet-ops#2711 and explains why both pipelines must be silent.
- **live judge prompt** `/home/nish/.local/share/opus-heartbeat/judge-prompt.md` (NOT repo-tracked; user-config install): the gate condition paragraph now states all three conjuncts and names the zero-dispatch/nonzero-claim window as a HEALTHY state. The follow-through block unchanged (still routes through intake under any other condition).
- **`tests/opus-heartbeat-frozen-claims-gate.test.sh`** (new, live/VPS-only): 7 scenarios covering the true-frozen shape, the live #2711 false-positive shape, the both-alive shape, the `flat.claims_last_2h` fallback path, `OPUS_HB_FROZEN_CLAIMS` overrides, and source/prompt pinning. Verified by reverting the launcher fix and observing test 2 fail with the expected false-positive ALLOW.
- **`tests/opus-heartbeat-follow-through.test.sh`**: test 5 now also asserts `claims_last_2h <= 1` in the prompt's gate paragraph so a future refactor that drops the claims conjunct trips this test.
- **`tests/p14-test-listing-gate.test.sh`**: registers the new test in `live_skip` (launcher binary absent on hosted CI).

## Why both pipelines must be silent

The narrow `--unit repair-*` lever is bounded by the queue_frozen() check exactly because the heartbeat's only unfrozen lever is `gh issue create` (which routes through intake). When pi-issue is alive, intake is consuming work — the lever would feed the very intake queue that is dispatching, which is the symptom the live #1453 run needed the gate to prevent. So the fix keeps the same lever shape (still `--unit repair-*` only when frozen, still `gh issue create` otherwise) but tightens the frozen definition.

The two pipelines are independent because:
- alert-repair dispatches only when Prometheus fires (sparse, can be idle for hours on a healthy fleet).
- pi-issue dispatches every minute when ready_work > 0 (steady when the queue has work).

A snapshot can legitimately have one dark and the other bright. The earlier gate conflated them.

## Verification

Real-run evidence (live snapshot, live launcher, live prompt):

```
$ /home/nish/.local/libexec/opus-heartbeat --check-allowlist \
    'pi-systemd-run --unit repair-2711-test ...'   # under live snapshot 2026-09-01T22:xx:xxZ
SKIP-QUEUE-NOT-FROZEN line=pi-systemd-run --unit repair-2711-test ...
rc=1
```

The live snapshot has `claims_last_2h=30, dispatches=0, ready=28`. The new gate SKIPs the lever — pi-issue is alive, the lever must stay shut.

Regression test (passes against the fixed launcher, fails against the pre-fix launcher):

```
$ bash tests/opus-heartbeat-frozen-claims-gate.test.sh
OK: test 1: claims=0 + dispatches=0 + ready=300 + repair-* → ALLOW queue_frozen=1
OK: test 2: live #2711 shape (claims=30, dispatches=0, ready=300) → SKIP-QUEUE-NOT-FROZEN
OK: test 3: both pipelines alive (claims=10, dispatches=10, ready=300) → SKIP-QUEUE-NOT-FROZEN
OK: test 4: claims=20 via flat fallback (dispatches=0, ready=300) → SKIP-QUEUE-NOT-FROZEN
OK: test 5: env override OPUS_HB_FROZEN_CLAIMS=50 admits claims=30 → ALLOW
OK: test 5b: env override OPUS_HB_FROZEN_READY=500 does not bypass claims or ready at low_ready=10
OK: test 6: launcher source pins OPUS_HB_FROZEN_CLAIMS + claims_last_2h + #2711 + conjunctive gate
OK: test 7: judge prompt pins claims_last_2h <= 1 + #2711 + BOTH pipelines silent
```

All 7 scenarios pass. The test against the pre-fix launcher fails on test 2 with:
```
FAIL: test 2: expected rc=1 (the live #2711 false-positive shape), got rc=0
       (ALLOW queue_frozen=1 line=pi-systemd-run --unit repair-2711-chain ...)
```
which is the false positive the issue describes — fixed and pinned.

Existing opus-heartbeat tests still pass (no regression on #1453, #2517, #1382, #2152):

```
PASS: opus-heartbeat-allowlist-gate
PASS: opus-heartbeat-fabricated-transcript-gate
PASS: opus-heartbeat-follow-through          (now also asserts claims<=1)
PASS: opus-heartbeat-frozen-claims-gate      (new — fleet-ops#2711)
PASS: opus-heartbeat-replayed-frozen-snapshot
PASS: opus-heartbeat-seat-comeback
PASS: opus-heartbeat-thorough-mode
```

run-proof: bash /home/nish/workspaces/agent-worktrees/issue-fleet-ops-2711/tests/opus-heartbeat-frozen-claims-gate.test.sh — exit 0, all 7 scenarios OK (output above).

## Tradeoffs

- **Three conjuncts instead of two.** Slightly more state to read on each gate call; the snapshot already carries both fields so the cost is one extra JSON read. Negligible.
- **`flat.claims_last_2h` fallback.** The canonical source is `snap.claims_last_2h.n`; the flat field is a fallback for tests/fixtures that only carry the flat form. Either path gates the lever identically.
- **No new metric.** The two existing pipeline counters are sufficient; the gate just reads both. A new "pipeline-mismatch" metric would be belt-and-suspenders without evidence — there is no failure mode the gate doesn't already cover.

## Out of scope

- The follow-through block (filing duplicate issues) is unchanged. The two pipelines being independent is the only thing this PR fixes; the louder-fault logic still triggers when the snapshot is frozen OR when the same-class issue is open unclaimed.
- `waste.claims_last_2h` field (in `opus-heartbeat-gather`'s `waste_and_capacity()`) is currently always `None`. The canonical claims field at top-level `claims_last_2h.n` is the one the gate reads. A future PR can either populate `waste.claims_last_2h` for symmetry or remove the dead field.

Closes #2711
