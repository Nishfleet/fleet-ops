# Escalation drain: bound NISH-ESCALATIONS.md and terminate consumed alert-repair packets

Builds the missing drain (fleet-ops#2677, #2773) so the escalation
channel stays readable and packets terminate. Today NISH-ESCALATIONS.md
accumulated to 369 lines (unreadable by Nish — defeats the boundary
channel) and alert-repair packets piled up (28 in 24h, oldest 22.5h,
waste.dispatches_last_2h=0) with no mechanism to remove them.

## What changes

New `bin/fleet-escalation-drain` plus `systemd/escalation-drain.{service,timer}`
wired to `systemd/escalation-drain.timer` (hourly at `:13`, registered in
`systemd/timer-manifest.json` and MANIFEST; ExecStart via `bash -c exec`
mirrors escalation-daily-sweep.service so the hosted unit-verify job passes
without a workflow edit). The drain is idempotent and best-effort:

1. **NISH-ESCALATIONS.md** — archives `RESOLVED` / `REVOKED-BY-PROBE` entries
   (markers nish-boundary-notify writes when a page is delivered or
   probed-suppressed) and pre-#1534 non-class noise (`LADDER-WALLED`,
   `SEAT-UNHEALTHY`, `PI-DISPATCH-FAILED`, ad-hoc `heartbeat:`/`BOUNDARY:`
   lines, etc.) to `nish-escalations-archive/<UTC-day>.md` — one file per
   UTC day, append-only, never rotated; a reviewer finds every archived
   escalation on the day it was archived.
2. **NISH-ESCALATIONS.md size cap** — if the live file still exceeds
   `FLEET_ESCALATION_DRAIN_MAX_LINES` (default 50) AFTER the unconditional
   archive, fold delivered boundary entries (hash in
   `lanes/nish-boundary-notify.seen`) into the archive too. Active entries
   (NOT in the seen set) stay — a not-yet-delivered page is never lost
   (fleet-ops#1458 semantics).
3. **alert-repair packets** — delete `packet-<alert>-<ts>.md` files whose
   dispatch cycle TERMINATED. The proof is `chains.terminated.jsonl` — the
   append-only ledger fleet-completion-canary writes (mirrored under
   `agent-state/alert-repair/`) when a chain reaches green / detector-red /
   escalated. A packet is consumed when a terminal record exists for its
   alertname with `end_ts >=` the packet's dispatch instant (the canary
   closes one cycle per alertname and absorbs intermediate re-dispatches
   under the final terminal). actions.log is NOT used as proof: it is
   bounded/rotated, so old packets' chains are unprovable there — the
   ledger is complete.
4. **Stuck packets are flagged LOUD, never silently deleted** — a webhook
   packet older than `FLEET_ESCALATION_DRAIN_STUCK_AGE_S` (default 48h)
   with no terminal record is reported as `LOUD [STUCK-PACKET] ...` on
   stderr every run (the unit journal inherits the escalation ladder via
   service.d/10-escalate.conf), so a never-terminating chain cannot hide;
   the completion canary's stall budget is the mechanism that escalates it.
   Scaffolding packets without a `<alert>-<ts>.md` suffix
   (packet-11-completion-canary.md, packet-13-undersaturation-guard.md,
   packet-red-main-2.md, packet-issue-*.md, …) are always preserved.

Anti-recursion: the drain is NOT an organ (no heartbeat metric, not in
`config/fleet-organs.json`, no absent() rule).

## Verification (live end-to-end run, real environment)

Ran `bash bin/fleet-escalation-drain` against the LIVE state
(2026-09-02T05:09Z):

```
$ bash bin/fleet-escalation-drain
[2026-09-02T05:09:45Z] live file still 87 lines (> MAX_LINES=50); promoted 37 delivered boundary entries to archive
[2026-09-02T05:09:45Z] NISH-ESCALATIONS.md: archived=197 bounded=37 live_lines=38 (was 370) archive=/home/nish/workspaces/agent-state/nish-escalations-archive/2026-09-02.md
[2026-09-02T05:09:46Z] LOUD [STUCK-PACKET] 27 webhook packet(s) older than 172800s have NO terminated chain ... packet-FleetChainStalled-20260827T175244Z.md ...
[2026-09-02T05:09:46Z] summary: nish_archived=197 nish_bounded=37 packet_deleted=69 packet_skipped=73 dry_run=0

$ wc -l /home/nish/workspaces/agent-state/NISH-ESCALATIONS.md
38 /home/nish/workspaces/agent-state/NISH-ESCALATIONS.md
$ ls /home/nish/workspaces/agent-state/alert-repair/packet-*.md | wc -l
73            # was 142 (69 = terminated cycles, ledger-proven; 41 scaffolding + 31 in-flight/stuck kept)
$ grep -E '^[0-9]{4}-' NISH-ESCALATIONS.md
2026-08-26T16:57Z CREDENTIAL-BOUNDARY hash=auto-revert-pat-no-comment-scope count=1
```

Issue's own THOROUGH metric after the run:
`escalation_drain.n=38 (was 369), packets_24h=5 (was 28)`.

Idempotency: a second run is a no-op
(`nish_archived=0 nish_bounded=0 packet_deleted=0 ... dry_run=0`); the
STUCK-PACKET line persists for the FleetChainStalled class — the honest
loud signal, not a failure exit.

Offline suite (all 8 scenarios, scratch agent-state only — live state
never mutated by the test):

```
$ bash tests/fleet-escalation-drain.test.sh
OK: scenario 1: bounded NISH-ESCALATIONS.md drains as a no-op
OK: scenario 2: delivered + RESOLVED + REVOKED + non-class archived; ACTIVE preserved
OK: scenario 2: archive contains RESOLVED + REVOKED + non-class + delivered; ACTIVE NOT archived
OK: scenario 2: re-run on bounded file is a no-op (idempotency)
OK: scenario 3: terminated packets deleted; in-flight / no-terminal / scaffolding preserved
OK: scenario 3: re-run on drained packet dir is a no-op (idempotency)
OK: scenario 4: small file does NOT promote delivered boundary entries (size check)
OK: scenario 5: --bogus-arg exits 2 with usage message
```

Repo gates green: escalation-units-shape (hosts this test — p14 closure),
p14-test-listing-gate (326/326 accounted), manifest-shape, timer-manifest,
fleet-heartbeat-verify-timers, install-manifest-comment-purity,
system-dropins-shape, fleet-ops-deploy, ci-standards-audit, shellcheck.

run-proof: journal/transcript of the live run above — NISH-ESCALATIONS.md
370->38 lines, archive nish-escalations-archive/2026-09-02.md written
(338 lines), 69 ledger-terminated packets deleted (142->73), idempotent
re-run no-op, STUCK-PACKET loud flag fires for the never-terminating
FleetChainStalled class.

organ-heartbeat: bin/fleet-escalation-drain not-an-organ: maintenance
script, no heartbeat metric; not in config/fleet-organs.json; no
absent() rule added.

research: live search + official docs — compared fleet-escalation-completion (adopted as the stall-escalation executor; it does not maintain the NISH file or packets), fleet-escalation-canary (proves the matrix, not file size), alert-repair-dispatch + fleet-completion-canary (chains.terminated.jsonl adopted as THE packet consumption proof — actions.log was tried first and deletes nothing live because it is bounded/rotated), and fleet-worktree-reaper (adopted as the hermetic/idempotent/append-only-archive structural model).

help-first: read systemd-run --help (launcher, not a drain) and bin/fleet-worktree-reaper's Scope + --help (reaps git worktrees only, never NISH-ESCALATIONS.md or packet files); neither already bounds the escalation files, so a dedicated drain was the proven shape (daily-sweep unit pattern adopted for the timer).

## research detail

Compared the standing escalation completion canary (fleet-escalation-completion, wired into fleet-heartbeat-tier1 block 15) — adopted as the executor that escalates a STALLED chain (24h budget), but it does NOT archive historical entries or delete consumed alert-repair packets; the drain is the bounded-file maintainer that completes it. Reviewed the coverage canary (fleet-escalation-canary) — it proves the escalation MATRIX is wired, not that the live FILES stay bounded. Reviewed alert-repair-dispatch + fleet-completion-canary — the canonical termination record for a dispatch cycle is chains.terminated.jsonl (append-only, mirrored under alert-repair/); the actions.log approach was tried first and rejects every live packet (rotated log + one-slot-per-alertname map), so the ledger was adopted as THE consumption proof. Checked existing fleet-worktree-reaper for the script shape (hermetic, append-only archive, idempotent reaper) — adopted as the structural model.

help-first-fired: none lost — see help-first: above.

Closes #2773