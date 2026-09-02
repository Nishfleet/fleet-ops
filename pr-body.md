## Why

Three live faults from the 2026-09-01T21:45Z seat/chain snapshot (issue 2716),
each proven at run time below:

1. **Alert-repair verify hop stalls and never terminates.** The snapshot had
   `fleet_chain_stalled{hop="verify"}=1.0` / FleetChainStalled pending 21:38Z.
   #2708 (fleet-ops#2700) added a class-park gate to `take_ladder` that fires
   on EVERY hop; for verify it sets `verify_deadline_ts=now` (zero-grace) so
   the #1610 detector-red block drains the chain on the next tick. The code
   was correct on main but UNTESTED — the incident only pinned the run-hop
   partner via scenario 9l. This PR pins the verify partner (scenario 9m).

2. **mimo-v2.5-free comeback re-probe not firing.** The snapshot had a
   past `usable_at` with no fresh observation. The comeback-release organ
   (15-min timer) is the re-probe rail; #2638 already fixed the force-probe
   on overdue `usable_at`. Live today the seat IS being re-probed on
   schedule (evidence below). No code change needed — the durable pins for
   this class already exist (overdue-clears 6a/6b, force-probe 9/9b,
   corpse-at-threshold 10/11) and pass.

3. **commandcode/minimax/minimax-m3-free corpse survived #2708.** #2708
   retired the slug in `config/seat-caps.json` (cap 0 +
   `intentional_cap_zero=corpse`) — that stops the ROTATION only. The
   corpse LEDGER kept sitting in `lanes/seats/`, where the census
   (daily-digest "Total seen", opus-heartbeat-gather seat_table `n`, any
   capacity denominator) counts it as live roster membership. Nothing in
   the fleet physically retired a terminal corpse ledger — the draft
   machinery (fleet-ops#2469 / #2540) never merged.

## Fix (smallest durable change, on existing rails, no new machinery)

- **Corpse retirement lives in the seat-lifecycle organ that already owns
  the rest of the lifecycle.** `bin/fleet-seat-comeback-release` already
  releases walls and corpsed seats at the consecutive-failure threshold
  (#2638); it now also owns the TERMINAL step: a corpse ledger
  (`seat_dead=true`, `health_class=corpse`) whose `observed_at` is older
  than the corpse grace window (`CORPSE_GRACE_S`, default 6h) is
  atomically moved into a dated `lanes/seats-corpse-retired-<UTC-ts>/`
  audit dir on the organ's every-15-min sweep. The grace window is the
  recovery chance (a healthy observation clears a corpse, seat-lib);
  defensive holds: a corpse with a future wall clock or no `observed_at`
  is never retired. New cumulative metric
  `fleet_seat_comeback_release_retired_total` (same prom family, same
  organ heartbeat, no new rule/registry entry).
- **Latent helper bug the new path exposed, fixed:** `ts_epoch("")`
  parsed an EMPTY wall clock as "now" (GNU `date -d ""` means now), so a
  clockless corpse looked like it carried a future wall clock whenever the
  test clock differed from the wall clock, and in production made the
  empty-clock defensive-hold branch fire by accident. `ts_epoch` now
  returns empty for empty input — the honest empty-clock semantics the
  wall-clock checks were written for.
- **Verify-hop drain pin:** scenario 9m in
  `tests/fleet-completion-canary.test.sh`.

Mechanical prevention (fleet-ops#366): the retirement path ships as a
permanent step of an existing every-15-min organ (not a one-off), and the
new scenarios 13a–13d are regression pins that FAIL against the pre-change
bin (no retirement path — the lived survivor shape) and pass with it; 9m
fails on a nil `verify_deadline_ts` persist (the lived verify-stall shape).

## Adjacent required-gate fix (unblocks the merge)

The PR 2827 merge is blocked by the P14 listing gate, which has been RED
on main since #2796 merged `tests/alert-repair-outcome-metric.test.sh`
without a host (the unhosted test is flagged by every worker PR; the
prior attempt on this issue hit the same wall). One host line added:
`ci-standards-audit.test.sh` (already-listed P14 host of the sibling
alert-repair suites and of the p14 gate itself) now invokes
`alert-repair-outcome-metric.test.sh`. Locally: p14 gate `P14 test list
is closed` rc=0; `ci-standards-audit.test.sh` rc=0 with the host line
green. No test removed/skipped; no gate-owned path touched.

## Verification (all run live this session)

- `bash tests/fleet-seat-comeback-release.test.sh` → 20 OK, `ALL OK`
  (sections 13a–13d: grace hold / retirement+idempotence / future-clock
  hold / clean-roster no-op).
- `bash tests/fleet-completion-canary.test.sh` → 33 OK, incl.
  `OK: class-parked verify-hop chain drains via #1610 detector-red, rail
  stays drained (fleet-ops#2716)` (9m).
- Host + adjacent suites: `fleet-seat-recovery` rc=0 (hosts the comeback
  test), `opus-heartbeat-seat-comeback` rc=0, `seat-quota-corpse` rc=0,
  `role-quality-gates` rc=0. `p14-test-listing-gate` rc=1 on the
  PRE-EXISTING orphan `alert-repair-outcome-metric.test.sh` (unhosted,
  predates this PR; identical failure on origin/main — not touched here).
- sgscan --base origin/main: `No new security findings`. crgate: not
  signed in on this host (skipped).
- **Chain reconciler re-run (issue 1):**
  `python3 /home/nish/.local/libexec/fleet-completion-canary` rc=0 →
  `tick open_ar={'run': 2, 'dispatch': 0, 'verify': 0}
  stalled_ar={'run': 0, 'dispatch': 0, 'verify': 0}`. fleet-chains.prom
  now carries `fleet_chain_stalled{plane="alert-repair",hop="verify"} 0`.
- **Modified organ run against the LIVE ledger (issue 2/3):** the modified
  bin swept the real `lanes/seats/` clean, rc=0:
  `sweep complete: probed=0 released=0 expired_after=0 (cumulative
  released_total=102 corpse_total=0 retired_total=0)` — zero corpse
  ledgers live today, idempotent; also live already shows
  `fleet_seat_comeback_release_retired_total 0` in the production prom.
- **Issue 2 proof (mimo re-probed):**
  `opencode__mimo-v2.5-free.json` now: `health_class=rate_limited`,
  `seat_dead=false`, `usable_at=2026-09-02T14:16:05.974Z`,
  `observed_at=2026-09-02T14:01:05.974Z`,
  `consecutive_failure_count=8` — fresh observations, wall re-anchored
  into the future by the re-probe. The FleetSeatComebackOverdue chain is
  green (`fleet_chain_cycle_seconds{alertname="FleetSeatComebackOverdue",
  terminal="green"} 389` in fleet-chains.prom).
- **Issue 3 proof (corpse absent from the seat snapshot):**
  `ls lanes/seats/ | grep -i minimax` → only the LIVE seats
  (cline-pass/minimax-m3 and direct MiniMax-M3 — both `seat_dead=false`);
  the retired corpse ledger sits in the audit dir
  `lanes/seats-corpse-retired-2026-09-02T12:12:15Z/commandcode__minimax_minimax-m3-free.json`.

run-proof: journal/transcript — (a) `fleet-completion-canary` live tick
transcript above, rc=0, fleet-chains.prom hop=verify stalled=0;
(b) modified `fleet-seat-comeback-release` live ledger sweep transcript
above, rc=0, prom `fleet_seat_comeback_release_retired_total 0` written
to /var/lib/prometheus/node-exporter/fleet-seat-comeback-release.prom;
(c) hermetic 9m + 13a–13d transcripts (test OK lines above).

Closes #2716