# Escalation drain: bound NISH-ESCALATIONS.md and alert-repair packets

Builds the missing drain (fleet-ops#2677, #2773) so the escalation
channel stays readable. Today, NISH-ESCALATIONS.md accumulates
indefinitely (369 lines as of the issue snapshot) and alert-repair
packets linger after consumption (28 in 24h, oldest 22.5h old,
waste.dispatches_last_2h=0). Both files are append-only with no
maintenance path.

## What changes

New `bin/fleet-escalation-drain` plus `systemd/escalation-drain.{service,timer}`
wired to `escalation-drain.timer` (hourly at `:13`). The drain is
idempotent and best-effort:

1. **NISH-ESCALATIONS.md** — archives ` RESOLVED ` and ` REVOKED-BY-PROBE `
   entries (markers nish-boundary-notify writes when a page is delivered or
   probed-suppressed) and pre-#1534 non-class noise (`LADDER-WALLED`,
   `SEAT-UNHEALTHY`, `PI-DISPATCH-FAILED`, ad-hoc `heartbeat:`/`BOUNDARY:`,
   etc.) to `nish-escalations-archive/<UTC-day>.md`. One file per UTC day,
   append-only, never rotated — reviewer finds every archived escalation
   on the day it was archived.
2. **NISH-ESCALATIONS.md size cap** — if the live file still exceeds
   `FLEET_ESCALATION_DRAIN_MAX_LINES` (default 50) AFTER the unconditional
   archive, fold delivered boundary entries (hash in
   `lanes/nish-boundary-notify.seen`) into the archive too. Active
   entries (NOT in the seen set) stay so a not-yet-delivered page is
   never lost.
3. **alert-repair packets** — delete `packet-*.md` files that have a
   complete chain in `actions.log` (DISPATCH AND RESOLVED|FAILED) AND
   are older than `FLEET_ESCALATION_DRAIN_PACKET_MIN_AGE_S` (default
   3600s = 1h, so a redispatch loop never loses its packet mid-cycle).
   Skip-list: canary/guard scaffolding without `<alert>-<ts>.md` suffix
   is preserved (e.g. `packet-11-completion-canary.md`,
   `packet-13-undersaturation-guard.md`, `packet-red-main-2.md`).

Anti-recursion: this drain is NOT an organ (no heartbeat metric, not in
`config/fleet-organs.json`). The systemd timer that runs it inherits
`service.d/10-escalate.conf`; a genuine fail-loud exit (jq missing, etc.)
climbs the SENIOR-AUDITOR rail. A clean run with nothing to do is rc=0
silent.

## Verification

Live end-to-end run against the canonical NISH-ESCALATIONS.md file
(370 lines, pre-#1534 noise + 36 delivered MONEY-BOUNDARY entries +
many non-class lines) — drain executed, archive written, live file
bounded to 38 lines containing only the active (not-yet-delivered)
CREDENTIAL-BOUNDARY entry:

```
$ cp /tmp/nish-before.md $AS/NISH-ESCALATIONS.md
$ bash bin/fleet-escalation-drain
[2026-09-02T04:26:50Z] [fleet-escalation-drain] live file still 87 lines (> MAX_LINES=50); promoted 37 delivered boundary entries to archive
[2026-09-02T04:26:50Z] [fleet-escalation-drain] NISH-ESCALATIONS.md: archived=197 bounded=37 live_lines=38 (was 370) archive=/home/nish/workspaces/agent-state/nish-escalations-archive/2026-09-02.md
[2026-09-02T04:26:51Z] [fleet-escalation-drain] summary: nish_archived=197 nish_bounded=37 packet_deleted=0 packet_skipped=141 dry_run=0

$ wc -l $AS/NISH-ESCALATIONS.md
38 $AS/NISH-ESCALATIONS.md
$ grep -E "^[0-9]{4}" $AS/NISH-ESCALATIONS.md | wc -l
1
$ grep -E "^[0-9]{4}" $AS/NISH-ESCALATIONS.md
2026-08-26T16:57Z CREDENTIAL-BOUNDARY hash=auto-revert-pat-no-comment-scope count=1
```

Idempotency: re-running the drain on the now-bounded file is a no-op:

```
$ bash bin/fleet-escalation-drain
[2026-09-02T04:26:52Z] [fleet-escalation-drain] summary: nish_archived=0 nish_bounded=0 packet_deleted=0 packet_skipped=141 dry_run=0
```

All 7 scenarios pass offline (`bash tests/fleet-escalation-drain.test.sh`):

```
OK: scenario 1: bounded NISH-ESCALATIONS.md drains as a no-op
OK: scenario 2: delivered + RESOLVED + REVOKED + non-class archived; ACTIVE preserved
OK: scenario 2: archive contains RESOLVED + REVOKED + non-class + delivered; ACTIVE NOT archived
OK: scenario 2: re-run on bounded file is a no-op (idempotency)
OK: scenario 3: consumed+old packet deleted; in-flight/fresh/no-chain/scaffolding preserved
OK: scenario 4: small file does NOT promote delivered boundary entries (size check)
OK: scenario 5: --bogus-arg exits 2 with usage message
```

run-proof: drain executed end-to-end on the live 370-line
NISH-ESCALATIONS.md, archive file written, live file bounded to 38
lines, re-run idempotent no-op; all 7 offline test scenarios pass.

organ-heartbeat: bin/fleet-escalation-drain not-an-organ: maintenance script, no heartbeat metric; not in config/fleet-organs.json; not adding an absent() rule.

## research:

Compared the standing escalation completion canary (fleet-escalation-completion,
already wired into fleet-heartbeat-tier1 block 15) — adopted as the executor
that escalates a STALLED chain (24h budget), but it does NOT archive
historical entries or delete consumed alert-repair packets; the new drain is
the bounded-file maintainer that completes it. Reviewed the coverage canary
(fleet-escalation-canary) — it proves the escalation MATRIX is wired, not
that the live FILES stay bounded. Reviewed alert-repair-dispatch — it WRITES
packet files but never deletes them; a separate drain is the proven shape (the
dispatcher is a hot-path worker, the drain is hourly batch GC). Checked
existing fleet-worktree-reaper for the script shape (hermetic, append-only
archive, idempotent reaper) — adopted as the structural model.

help-first: ran `systemd-run --help` (hourly timer via OnCalendar=*:13
matches the existing escalation-daily-sweep.timer pattern at
`systemd/escalation-daily-sweep.timer:8`); ran `bin/fleet-escalation-completion
--help` (no --help output; the script is not invoked by flag, only by
heartbeat-tick) — fleet-escalation-completion does not maintain
NISH-ESCALATIONS.md or alert-repair/packet-*.md; it only verifies STOP-REASON
chains terminate. Verified `bin/fleet-worktree-reaper --help` — confirms the
existing reaper is for git worktrees only (Scope section line 65-70), not
for the escalation files; a separate drain is the proven shape.

Closes #2773