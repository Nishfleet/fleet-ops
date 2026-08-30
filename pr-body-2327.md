fix(seat): terminal corpse class + absolute ladder exclusion for seat_dead seats

What changed and why:

The 2026-08-30T08:30Z heartbeat flagged
`opencode/muse-spark-1.2-contributor-free` (seat_dead=true,
consecutive_failure_count=150, http 500, failure_mode=transient_http,
usable_at +24h): "A seat classed transient_fault after 150 straight 500s
is misclassified — transient backoff keeps re-benching it forever. Either
reclassify to a terminal dead class and drop it from the ladder, or prove
the endpoint recovers."

Root cause, two halves:

1. The corpse was marked seat_dead=true (fleet-ops#2145) but its ledger
   health_class stayed `transient_fault` forever — the census/snapshot and
   the heartbeat kept reading it as a recoverable walled-transient seat.

2. The read side resurrected corpses: `seat_usable()` and the pick_seat
   excluded set both treated a seat_dead=true marker whose observed_at had
   aged past STALE_SECS (6h) as stale-and-retryable ("a stale dead marker
   is not authoritative"). Between weekly probes a corpse's observed_at
   naturally ages past 6h, so workers re-picked the guaranteed-failing
   seat every cycle and the count kept climbing (muse-spark 80 -> 150).
   The stale fail-open was a re-pick loop, not a recovery path.

Fix:

- Writer (out-of-repo extension `~/.pi/agent/extensions/seat-health.ts`,
  closure-tested from this repo like fleet-ops#2145/#1466): the moment
  `shouldMarkSeatDead` fires, the ledger health_class reclassifies to the
  TERMINAL `corpse` class — a corpse is retired, not a walled-transient
  seat. A successful probe (healthy observation) resets count -> 0,
  seat_dead -> false, class -> healthy (never a permanent bench).
- Reader (`lib/seat-lib.sh`): seat_dead=true is now an ABSOLUTE exclusion
  in `seat_usable()` and in the pick_seat excluded set — a stale
  observed_at does NOT resurrect a corpse into the ladder. Recovery is
  exclusively the weekly seat-walled-probe success (fleet-ops#2145's
  designed path). The live muse-spark ledger now reads
  `health_class:"corpse"` and the heartbeat snapshot shows it as such
  (verified: `opus-heartbeat-gather` seat row = corpse / seat_dead=true).
- Defense in depth: `bin/pi-audit-run` preflight skips the corpse class.

The endpoint cannot be proven recovered: 150 failures over 3 days across
re-auditions (fleet-ops#1224, #759, #854, #1456 — all HTTP 500, control
hy3-free returns 200 on the same endpoint), so the seat is RETIRED, not
repaired: `config/seat-caps.json` already benches
muse-spark-1.2-contributor-free at cap=0 (intentional_cap_zero stale) and
the live ledger is reclassified to corpse with seat_dead=true.

The "seat-ladder depth" context from the heartbeat (13/28 walled;
straitly x3 + minimax/MiniMax-M3 + cline hard 402 quota_exhausted): those
are vendor billing/rate walls that resolve at their own reset windows, or
mark corpse via the same rules (quota_exhausted un-cleared past 24h is a
corpse). minimax/MiniMax-M3 (c=77) is a fresh 402 (observed 2026-08-30
07:12Z) — a walled seat waiting for its reset window; once its
observation ages past 24h the corpse rules reclassify it. No cap tuning
was warranted in this PR (capacity-is-measured).

Verification (exact commands + results, re-run in this session):

- `bash tests/seat-health-seat-dead.test.sh` -> exit 0, PASS (D1-D9 +
  D10-D13; D10/D11/D13 assert the terminal `corpse` class on transient
  and quota corpses, and class rebuild on a healthy write).
- `bash tests/seat-lib.test.sh` -> exit 0, PASS (new invariant 7b:
  seat_usable and the pick_seat excluded set refuse a stale
  seat_dead=true corpse).
- Failing-then-passing (verbatim probe transcripts, run this session):
  against the PRE-fix lib (`git show origin/main:lib/seat-lib.sh`):
  `CORPSE-RESURRECTED (seat_usable rc=0) — pre-fix resurrection happens`
  (exit 1); against the fixed lib: `CORPSE-REFUSED (seat_usable rc=1)`
  (exit 0). The stale fail-open is gone: death is terminal.
- `bash tests/seat-health-classifier.test.sh` PASS,
  `tests/seat-health-quarantine.test.sh` PASS,
  `tests/seat-walled-probe.test.sh` PASS, `tests/seat-lib-aimd.test.sh`
  PASS, `tests/seat-lib-degraded.test.sh` PASS,
  `tests/pi-audit-run.test.sh` PASS (pi-audit-run touched),
  `tests/repair-rotation.test.sh` PASS,
  `tests/alert-repair-seat-walled.test.sh` PASS,
  `tests/fleet-seat-recovery.test.sh` PASS,
  `tests/fleet-seat-recovery-units.test.sh` PASS,
  `tests/fleet-seat-live-validate.test.sh` PASS,
  `tests/pi-intake-tick-seat-gate.test.sh` PASS,
  `tests/pi-scout-seat-rotation.test.sh` PASS,
  `tests/seat-noop-escalation.test.sh` PASS,
  `tests/seat-spawn-bench-clobber.test.sh` PASS,
  `tests/seat-failure-ceiling.test.sh` PASS,
  `tests/seat-caps-citation.test.sh` PASS,
  `tests/manifest-shape.test.sh` PASS, `tests/fleet-unjustified-wait.test.sh`
  PASS.
- `shellcheck -S error lib/seat-lib.sh bin/pi-audit-run
  tests/seat-lib.test.sh tests/seat-health-seat-dead.test.sh` -> clean.
- `sgscan` (security scan of the diff) -> "No new security findings", rc=0.
- PR gates: `prove-one-run-check` SKIP (no unit/timer/workflow added);
  `fleet-exec-review-canary` OK; `fleet-organ-heartbeat-check` SKIP (no
  organ touched); `fleet-no-agent-names-check` OK;
  `fleet-token-efficiency-check` OK; `fleet-wipe-lessons-check scan`
  clean. crgate: skip locally (CodeRabbit not signed in on this host);
  the PR's CI CodeRabbit review covers it.
- Live state (this session): against the LIVE ledger,
  `seat_usable opencode/muse-spark-1.2-contributor-free` returns rc=1 and
  logs `[2026-08-30T09:38:29Z] seat opencode/muse-spark-1.2-
  contributor-free: UNUSABLE (seat_dead=true, class=corpse)`;
  `python3 /home/nish/.local/libexec/opus-heartbeat-gather` seat row for
  the slug now reads `health_class:"corpse"` (was transient_fault),
  `seat_dead:true`, wall_class `corpse`.
- `tests/ci-standards-audit.test.sh` on this worktree reaches the
  reachable-set gate and fails on THREE test files
  (fleet-loose-ends-canary.test.sh, pi-issue-run-hang-stall-bench.test.sh,
  unit-escalation-write-retry-absorb.test.sh) that are unregistered at
  HEAD too — PRE-EXISTING on main (reproduced on a clean origin/main
  checkout in this session), already tracked as Nishfleet/fleet-ops#2318
  (open); not owned by this issue, not fixed here (it needs workflow
  scope which the worker App cannot push).

run-proof: real end-to-end runs — (1) live
`seat_usable` against `/home/nish/workspaces/agent-state/lanes/seats/opencode__muse-spark-1.2-contributor-free.json`
returns UNUSABLE (seat_dead=true, class=corpse) after the fix;
(2) `python3 /home/nish/.local/libexec/opus-heartbeat-gather` snapshot
row for the slug reads `health_class:"corpse"` (was transient_fault);
(3) seat-health-seat-dead.test.sh D10-D13 and seat-lib.test.sh 7b pass
locally (exits 0). No unit/timer/workflow added by this PR.

mechanism: regression tests shipped in-PR prove the guard fires — the
extension closure test (corpse class on transient+quota corpses, healthy
recovery rebuilds class) and the read-side seat-lib invariant 7b (stale
corpse refused by seat_usable and the excluded set; pre-fix code fails
it). This is the mechanical prevention for the misclassification class.

Closes #2327