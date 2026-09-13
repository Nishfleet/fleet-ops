Closes #5444

## Problem

`pi-packet-failed@.service` — the OnFailure= terminal state for any packet whose
restarts are exhausted (pi-packet@ StartLimitBurst, pi-systemd-run transients) —
ran a single `logger` line into a syslog nobody reads. An exhausted packet died
silently: no ledger row, no judge surface, no queue entry (Nish, 2026-09-11:
"NO SILENT FAILURES AND AUTO RESUME ALWAYS"). #5442's silent-drop sweep covered
bin/lib but not systemd/.

## Fix (extend, don't add)

The unit now ExecStarts MANIFEST-installed `bin/pi-packet-failed`, which keeps
the original syslog line and adds three durable records:

1. findings-ledger row `{source_organ: pi-packet, disposition: carried_over,
   ref: <failed unit>, evidence_ref: last 5 journal lines}` via the shipped
   single-writer helper (`lib/findings_ledger.py`, fleet-ops#5443) — direct
   append of the identical schema (same finding_id) when the helper is absent,
   so a missing helper never means a lost row. MANIFEST installs the helper to
   `~/.local/lib/pi-packet/findings_ledger.py`, the path the handler
   auto-detects.
2. LOUD `[PI-PACKET-FAILED]` line in the heartbeat triage file
   (`FLEET_HEARTBEAT_TRIAGE`) that the heartbeat/judges read every tick.
3. When the unit carried `PI_DEADMAN_DELIVERABLE` (what `pi-systemd-run
   --deliverable` sets; also recovered from the dispatch ledger so a GC'd
   transient still proves its promise): file-or-update a fleet-ops issue
   titled after the packet via `bin/fleet-issue-file` (filing-time dedupe,
   `signal: pi-packet-exhausted/<unit>`), labelled `agent-ready` — the packet
   re-enters the queue instead of dying.

Wiring: `bin/pi-systemd-run` adds `pi-packet-failed@<unit>` alongside the
existing `unit-escalation@` in the transient OnFailure; the template
(`pi-packet@.service`) already declares `OnFailure=pi-packet-failed@%i.service`.
A required write that fails exits non-zero so the global escalate drop-in
still summons the senior auditor — the recorder itself is loud. A self-trigger
guard keeps the recorder from ledger/issue-looping on its own instances.
Unit ExecStart keeps the #154 runner-safe `/bin/bash -c 'exec …'` shape.

## Salvage

Resumed the previous attempt's banked work: claim/issue-5444 tip 1207a878c
(closed, never-merged PR #5483) — 8 commits, all #5444-scoped — squash-landed
on 6b85547c as 7aadf0f4e. #5483's only red check was NOT this diff: the
fleet-ops#5045 test died with `tail: write error: Broken pipe` after all its
subtests printed OK (run 34649832780, 2026-09-11T21:36Z) — a pre-existing test
race, now tracked as #6328. That test no longer exists in today's tests/, and
base 6b85547c's own ci.yml is green (run 34741208465, 2026-09-13T05:48Z).

## Verification

- `bash tests/pi-packet-failed.test.sh` — exit 0, 13 OK lines: --help prints
  usage; wiring (unit ExecStart + pi-systemd-run OnFailure + MANIFEST);
  syslog line kept; triage LOUD line; ledger row schema
  (source_organ/disposition/ref/evidence/finding_id); agent-ready re-queue
  issue via fleet-issue-file; non-deliverable -> records without an issue;
  helper single-writer path; helper duplicate rc=3 durable (no re-append);
  genuine helper failure -> loud WARN + direct-append fallback;
  required-write failure loud (exit 1) while other sinks still land; missing
  arg non-zero; live drill (real systemd stub unit -> OnFailure -> handler ->
  triage + ledger + agent-ready issue). Run twice: once on the banked tip,
  once after the squash onto 6b85547c — green both times.
- `bash tests/pi-systemd-run.test.sh` — exit 0 (nests the drill so CI runs it
  without a workflow edit; its +6 lines assert the transient OnFailure wiring).
- `bash tests/manifest-shape.test.sh`,
  `tests/install-manifest-comment-purity.test.sh`,
  `tests/manifest-required-bins.test.sh` — all pass.
- `systemd-analyze verify --man=no --recursive-errors=no
  systemd/pi-packet-failed@.service` — exit 0.
- Live real-helper run (not the test fixture), 2026-09-13T07:03Z: two handler
  executions against the shipped `lib/findings_ledger.py` — exactly 1 ledger
  row (source_organ=pi-packet, disposition=carried_over,
  ref=pi-packet@salvage-verify-5444.service, evidence=journal-availability
  note); second run logged `skip: duplicate, rc=3) — ledger durable, no
  re-append`; row finding_id 512330abbc246382 equals
  `findings_ledger.finding_id('pi-packet', <unit>, <title>)` — MATCH.
- `sgscan --base origin/main` — no new security findings.

run-proof: bash tests/pi-packet-failed.test.sh exit 0 (13 OK lines) including
the live systemd stub-unit drill on this VPS; bash tests/pi-systemd-run.test.sh
exit 0; live shipped-helper ledger dedupe 2026-09-13T07:03Z (2 runs -> 1 row,
skip: duplicate rc=3, finding_id MATCH 512330abbc246382); ci.yml green on base
6b85547c (run 34741208465, 2026-09-13T05:48:32Z).

research: official docs checked (systemd.unit OnFailure/StartLimitBurst man pages + the shipped lib/findings_ledger.py contract); alternatives compared and decided — retrier-in-unit rejected (Nish 2026-08-24: "No hand-built orchestration. Ever."), heartbeat-side journal tailing rejected (the triage file is already the judges' read), adopted the record-only handler reusing the existing findings-ledger helper and the existing fleet-issue-file queue path.

help-first: --help read before use (the new handler's usage; sgscan --help; prove-one-run-check usage) — existing tools insufficient: unit-escalation@/stop-escalation@ only escalate, pi-detached-deadman owns the clean-stop-no-deliverable verdict, and nothing records the exhausted-StartLimitBurst terminal state (the #5442 sweep explicitly skipped systemd/).

organ-heartbeat: systemd/pi-packet-failed@.service not-an-organ: OnFailure
one-shot recorder, no timer or heartbeat loop.

loose-ends: #6328 — the #5045 Broken-pipe P14 race that sank PR #5483,
pre-existing and out of #5444's scope, kept queued there.
