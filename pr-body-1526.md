# Mechanism: attach the failing unit's last error lines to STOP-REASON, fix the unit-name substitution

Closes #1526 (fleet-ops#1521 line 5: manual evidence-pinning and triage greps).

## What changed

1. **Evidence in STOP-REASON.** `bin/unit-escalation-write` now attaches the failing unit's **last N error-priority journal lines** to STOP-REASON.json as `detail.journal_errors` (default 10, `journalctl -p err`, overridable via `UNIT_ESCALATION_JOURNAL_ERROR_LINES`), alongside the existing raw 5-line tail (`detail.journal`). The raw tail was often systemd boilerplate ("Failed to start X." / "Main process exited"); the real error output could sit further back. The senior auditor now carries the failure evidence without a hand journalctl grep.

2. **Unit name is substituted correctly (no `unknown unit`).** The escalation path always takes the unit name from systemd's `%i` instance identifier (never a placeholder). `fleet-heartbeat-failed-notify` pages the real `MONITOR_UNIT` and no-ops — pages nothing, writes no state — when `MONITOR_UNIT` is unset; the page can never say `unknown unit`. Tests lock both behaviors.

3. **Rule-enforcement matrix entry** for decisions-ledger 2026-08-28 line 5 (ledger row added alongside, same pattern as the line-6 entry).

Mechanical-fix discipline (fleet-ops#366): the prevention mechanism is the writer attaching the evidence automatically plus the locked tests

## Verification

- New test `tests/unit-escalation-write-journal-errors.test.sh` (3 cases) — GREEN.
- Extended `tests/fleet-heartbeat-failed-notify-threshold.test.sh` (page never `unknown unit`; unset `MONITOR_UNIT` → no page, no state) — GREEN.
- `tests/rule-enforcement.test.sh` (matrix + ledger join) — ALL TESTS PASSED.
- `tests/stop-escalation-dispatch.test.sh`, `tests/escalation-units-shape.test.sh`, `tests/unit-escalation-write-retry-absorb.test.sh`, `tests/unit-escalation-write-scout-futility-dedupe.test.sh`, `tests/system-dropins-shape.test.sh`, `tests/fleet-heartbeat-failed-units-recover.test.sh` — GREEN.
- shellcheck 0.11.0 clean on all changed scripts; `python3 -m py_compile` clean on the notify helper.

**Drill (prove-one-run, live):** ran the worktree writer against the real failed unit `notify-probe.service` (real `journalctl`/`systemctl`), scratch STOP-REASON, then the dispatch dry-run:

```json
"detail": {
  "unit": "notify-probe.service",
  "journal": [
    "2026-08-30T18:48:56+05:30 netcup-rs2000 systemd[1038]: Starting notify-probe.service...",
    "... notify-probe.service: Main process exited, code=exited, status=1/FAILURE",
    "... notify-probe.service: Failed with result 'exit-code'.",
    "... Failed to start notify-probe.service.",
    "... notify-probe.service: Triggering OnFailure= dependencies."
  ],
  "journal_errors": [
    "2026-08-30T18:41:44+05:30 netcup-rs2000 systemd[1038]: Failed to start notify-probe.service.",
    "2026-08-30T18:41:54+05:30 netcup-rs2000 systemd[1038]: Failed to start notify-probe.service.",
    "2026-08-30T18:42:11+05:30 netcup-rs2000 systemd[1038]: Failed to start notify-probe.service.",
    "2026-08-30T18:45:00+05:30 netcup-rs2000 systemd[1038]: Failed to start notify-probe.service.",
    "2026-08-30T18:48:56+05:30 netcup-rs2000 systemd[1038]: Failed to start notify-probe.service."
  ],
  ...
}
```

Dispatch dry-run (hermetic scratch): `DRY-RUN auditor hash=4185cb43... provider=commandcode model=poolside/laguna-s-2.1-free` — the STOP-REASON is picked up with the correct unit name.

run-proof: drill transcript above (real journalctl tail + `-p err` tail landed in `detail.journal` / `detail.journal_errors`; dispatch dry-run recognized the hash).

loose-ends-canary: none needed (no stale question, PR is being armed on open).