fix(escalation): lock the never-'unknown unit' notify page + register the #1526 live drill (fleet-ops#1526)

The journal-evidence half of this issue already landed on main via #2399:
unit-escalation-write writes the failing unit's last journal lines
(detail.journal) plus the last error-priority lines (detail.journal_errors)
into STOP-REASON.json with the unit name always from systemd's %i, and the
rule-enforcement matrix entry exists. What #1526 still demanded (and what
this PR ships):

1. Lock the name-substitution seam that produced 'FLEET UNIT FAILED: unknown
   unit' pages. tests/fleet-heartbeat-failed-notify-threshold.test.sh gains
   scenario E: an unset MONITOR_UNIT must never page and never write per-unit
   state, and the paging scenario now rejects any 'unknown unit' text. The
   helper already refuses to page when MONITOR_UNIT is unset; systemd v250+
   sets MONITOR_UNIT for OnFailure= activations (verified live on this host,
   systemd 255 — MONITOR_UNIT + MONITOR_SERVICE_RESULT were delivered on a
   real activation), so a name-less page is now structurally impossible and
   the test locks it. Per systemd.exec(5), MONITOR_UNIT is NOT passed when
   multiple services trigger the same unit; in that case (which occurs on
   this fleet) the helper suppresses the page rather than emitting a
   name-less "unknown unit" page — the STOP-REASON path (unit-escalation@%n)
   already covers every failure with the correct unit name and evidence.
2. Register the proof pointer in config/rule-enforcement.json for the ledger
   rule led-2026-08-28-manual-evidence-pinning-and-triage-greps-fleet-op: the
   entry now cites the notify guard test and this issue's live drill.

Mechanical-fix: the regression-lock IS the prevention mechanism (fleet-ops#366
class): scenario E + the hardened scenario-A assertion prove the guard fires —
if anyone ever re-introduces a name-less page (e.g. the old
'${MONITOR_UNIT:-unknown unit}' ExecStart default of #507), the test fails
and the p14 host surfaces it on every CI run.

Verification:
- tests/fleet-heartbeat-failed-notify-threshold.test.sh: PASS (scenarios
  A-E, including the new unset-MONITOR_UNIT lock)
- tests/fleet-heartbeat-failed-notify-shape.test.sh: PASS (hosts the
  threshold test)
- tests/unit-escalation-write-journal-evidence.test.sh: PASS
- tests/escalation-units-shape.test.sh: PASS
- tests/p14-test-listing-gate.test.sh: PASS (all 311 test files accounted for;
  this PR modifies, not adds, a listed test)
- config/rule-enforcement.json parses (128 rules), diff touches only the
  evidence-pinning entry

run-proof: drill (prove-one-run) executed live 2026-08-30 —
(1) writer: `/home/nish/.local/bin/unit-escalation-write pi-transport-check.service`
with UNIT_ESCALATION_AGENT_STATE redirected to a scratch dir wrote a
STOP-REASON.json whose detail.unit = pi-transport-check.service with 5 real
journal lines and 2 real error-priority lines ("Failed to start
pi-transport-check.service"), no auditor summoned (agent-state redirected);
deployed writer is byte-identical to this PR's writer.
(2) notify: with MONITOR_UNIT delivered by a real systemd 255 OnFailure=
activation (captured: MONITOR_UNIT=<unit> + MONITOR_SERVICE_RESULT=exit-code),
the helper rendered "FLEET UNIT FAILED (1 consecutive):
pi-transport-check.service on netcup-rs2000 — check: systemctl --user status
pi-transport-check.service" through a stub hermes; with MONITOR_UNIT unset it
printed "MONITOR_UNIT unset, nothing to do" and produced no page and no state.
(3) test transcript: "OK: MONITOR_UNIT unset -> no page, no state, never
'unknown unit'".

Closes #1526