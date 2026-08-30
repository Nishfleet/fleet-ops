feat(enforcement): pin failing-unit journal evidence into STOP-REASON (ledger 2026-08-28)

Rule-coverage gap (fleet-ops#383 canary) for the ledger rule
`led-2026-08-28-manual-evidence-pinning-and-triage-greps-fleet-op`
(decisions-ledger.md: 2026-08-28 | Manual evidence-pinning and triage
greps, fleet-ops#1521 line 5): "the escalation pipeline must attach the
failing unit's last error lines to its STOP-REASON automatically, so the
senior auditor carries the failure evidence without a hand journalctl
grep... unit-escalation-write now writes the last 5 journal lines
(detail.journal) plus the last N error-priority lines
(detail.journal_errors) into STOP-REASON.json, with the unit name always
from systemd's %i."

What changed
- bin/unit-escalation-write: added `detail.journal_errors` — the last N
  (default 5, env UNIT_ESCALATION_JOURNAL_ERRORS_LINES) error-priority
  journal lines (syslog err or higher via `journalctl -p err`) for the
  failed unit, alongside the existing `detail.journal`. Unit name remains
  the %i passed in, never a placeholder. `journal_errors` is always an
  array ([] when the unit left no error-priority lines).
- config/rule-enforcement.json: registered the ledger rule as `enforced`
  with mechanism + proof pointer. The canary block-9 join now reports it
  covered (128/128 vault rules covered, 0 uncovered).
- tests/unit-escalation-write-journal-evidence.test.sh (new): offline
  regression test locking the evidence shape — detail.journal = last 5
  lines, detail.journal_errors = last error-priority lines, unit from %i,
  and [] (never null) in the clean-journal case.

Observe-to-close: this issue is closed by the canary's observe-to-close
path once a real heartbeat tick reports the source covered (canary-covered
marker + a subsequent tick). This PR does not Closes #2392.

Verification: bash <writer-test> passed; the repo's own gates passed
(bin unit-escalation-write-retry-absorb, scout-futility-dedupe,
escalation-units-shape, rule-enforcement all rc=0); sgscan clean.
run-proof: live writer drill on the real failed unit pi-scout@0509.service
(UNIT_ESCALATION_STOP_REASON redirected to scratch so no auditor was
summoned) produced DRILL GREEN — unit=pi-scout@0509.service, journal=5
lines, journal_errors=5 real error-priority lines (first: "... Failed to
start pi-scout@0509.serv..."). Drill is the ledger-named drill ("live
writer run on a failed unit").
Relates to #2392
