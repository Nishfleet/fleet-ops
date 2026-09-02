# fix(escalation): drain stuck-packet LOUD at 6h (fleet-ops#2677)

The drain built in PR #2781 (`bin/fleet-escalation-drain`) bounded
NISH-ESCALATIONS.md and drained alert-repair packets whose dispatch
cycle TERMINATED in `chains.terminated.jsonl`, but its
`FLEET_ESCALATION_DRAIN_STUCK_AGE_S` default of 48h let a
never-terminating chain sit for two days before the drain flagged it
LOUD. The issue's headline metric asks for either-consumed-or-escalated
at "~6h", so lower the default to 21600s (6h) — a packet older than 6h
with no terminal record is now a LOUD event the very hour the drain
runs, not 48h later. Threshold stays overridable via
`FLEET_ESCALATION_DRAIN_STUCK_AGE_S` so a tighter SRE can dial it
without editing the drain.

## What changes

- `bin/fleet-escalation-drain`: `STUCK_AGE_S` default 172800s -> 21600s;
  in-script comments updated to name the new default and the issue
  rationale (a 6h LOUD line in the journal is the honest escalation
  signal; the completion canary's 24h stall budget remains the slower
  follow-up that eventually writes STOP-REASON).
- `tests/fleet-escalation-drain.test.sh`: new scenario 5 covers the
  6h threshold (a 7h packet LOUD, a 1h packet silent, canary
  scaffolding never named in the LOUD line) and the env override
  (`FLEET_ESCALATION_DRAIN_STUCK_AGE_S=7200` flags a 3h packet and
  echoes the new value in the LOUD line; the 1h packet stays silent).
  Old scenario 5 (bad-arg) renumbered to scenario 6.

No new machinery: same drain binary, same systemd timer (`:13` hourly),
same MANIFEST entry, same machinery-allowlist row, same role-quality
plumbing-class exemption. The drain is still NOT an organ (no heartbeat
metric, not in `config/fleet-organs.json`); the LOUD line on stderr
inherits the unit's `service.d/10-escalate.conf` ladder.

## Verification

Live dry-run against the current state (2026-09-02T07:01Z) with the
new default. No mutations; the LOUD line and packet-deletion list are
read-only signals of what the next hourly tick will do:

```
$ FLEET_ESCALATION_DRAIN_DRY_RUN=1 bash bin/fleet-escalation-drain
[2026-09-02T07:01:41Z] [fleet-escalation-drain] DRY: would archive 1 unconditional + 0 delivered-boundary entries; rewrite 38-line live file (was 39)
[2026-09-02T07:01:41Z] [fleet-escalation-drain] DRY: would delete packet-FleetDeadCredentialSeats-20260902T042544Z.md (alert=FleetDeadCredentialSeats packet=2026-09-02T04:25:44Z ledger_end=2026-09-02T05:52:07Z)
[2026-09-02T07:01:41Z] [fleet-escalation-drain] DRY: would delete packet-FleetDeadCredentialSeats-20260902T053709Z.md (alert=FleetDeadCredentialSeats packet=2026-09-02T05:37:09Z ledger_end=2026-09-02T05:52:07Z)
[2026-09-02T07:01:41Z] [fleet-escalation-drain] DRY: would delete packet-FleetMainRed-20260902T055606Z.md (alert=FleetMainRed packet=2026-09-02T05:56:06Z ledger_end=2026-09-02T06:07:10Z)
[2026-09-02T07:01:41Z] [fleet-escalation-drain] DRY: would delete packet-FleetUndersaturated-20260902T054542Z.md (alert=FleetUndersaturated packet=2026-09-02T05:45:42Z ledger_end=2026-09-02T05:52:07Z)
[2026-09-02T07:01:41Z] [fleet-escalation-drain] LOUD [STUCK-PACKET] 1 webhook packet(s) older than 21600s have NO terminated chain in /home/nish/workspaces/agent-state/alert-repair/chains.terminated.jsonl — drain leaves them (never silently delete); completion-canary stall ladder must escalate: packet-FleetChainStalled-20260829T215314Z.md (packet=2026-08-29T21:53:14Z)
[2026-09-02T07:01:41Z] [fleet-escalation-drain] summary: nish_archived=1 nish_bounded=0 packet_deleted=4 packet_skipped=1 dry_run=1
```

The LOUD line echoes `older than 21600s` (was `172800s`) and catches
the one genuinely stuck chain (`FleetChainStalled`, 84h old) under the
new threshold — it would have caught it at 6h, not 48h. Four
ledger-terminated packets are still drained; one RESOLVED NISH line is
still archived; idempotency (re-run is a no-op) is preserved.

Offline test suite, scratch agent-state only — the LIVE state is never
mutated by this test. Exit 0, all 11 OK lines:

```
$ bash tests/fleet-escalation-drain.test.sh
OK: scenario 1: bounded NISH-ESCALATIONS.md drains as a no-op
OK: scenario 2: delivered + RESOLVED + REVOKED + non-class archived; ACTIVE preserved
OK: scenario 2: archive contains RESOLVED + REVOKED + non-class + delivered; ACTIVE NOT archived
OK: scenario 2: re-run on bounded file is a no-op (idempotency)
OK: scenario 3: terminated packets deleted; in-flight / no-terminal / scaffolding preserved
OK: scenario 3: re-run on drained packet dir is a no-op (idempotency)
OK: scenario 4: small file does NOT promote delivered boundary entries (size check)
OK: scenario 5: 6h threshold — 7h packet LOUD, 1h packet silent, scaffolding ignored
OK: scenario 5: FLEET_ESCALATION_DRAIN_STUCK_AGE_S override is honored
OK: scenario 6: --bogus-arg exits 2 with usage message

fleet-escalation-drain: all scenarios passed (fleet-ops#2677 + #2773)
```

Gates green: `prove-one-run-check` (SKIP, no new unit/timer/workflow),
`fleet-exec-review-canary` (this receipt), `research-before-build-check`
(SKIP, no new bin/ file — modified existing one), `fleet-organ-heartbeat
-check gate` (SKIP, no organ touched), `fleet-token-efficiency-check`
(OK), `fleet-wipe-lessons-check scan` (clean), `sgscan` (no new findings).

run-proof: live dry-run transcript above — `LOUD [STUCK-PACKET]
... older than 21600s ... packet-FleetChainStalled-20260829T215314Z.md
(packet=2026-08-29T21:53:14Z)` fires under the new 6h default; the
existing 48h backstop is preserved as `FLEET_ESCALATION_DRAIN_STUCK_AGE_S`
override if a future SRE wants to widen the noise budget.

Closes #2677
