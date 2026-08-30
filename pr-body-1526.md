fix(escalation): lock the never-'unknown unit' notify page + register the #1526 live drill (fleet-ops#1526)

The journal-evidence half of this issue already landed on main via #2399:
unit-escalation-write writes the failing unit's last journal lines
(detail.journal) plus the last error-priority lines (detail.journal_errors)
into STOP-REASON.json with the unit name always from systemd's %i, so the
senior auditor carries the failure evidence without a hand journalctl grep.
What #1526 still demanded (and what this PR ships):

1. Lock the name-substitution seam that produced 'FLEET UNIT FAILED: unknown
   unit' pages. tests/fleet-heartbeat-failed-notify-threshold.test.sh gains
   scenario E: an unset MONITOR_UNIT must never page and never write per-unit
   state, and the paging scenario now rejects any 'unknown unit' text.
   Root cause, now proven live instead of assumed: systemd v250+ delivers
   MONITOR_UNIT to an OnFailure= target only when the activation has a single
   trigger source (verified on this host, systemd 255: MONITOR_UNIT +
   MONITOR_SERVICE_RESULT were in the target's environment). When multiple
   failed units trip the same target (the exact 2026-08-28 overnight shape —
   pi-transport-check + fleet-heartbeat failed together, journal: "multiple
   trigger source candidates for exit status propagation (...) skipping"),
   MONITOR_UNIT is absent and the old ExecStart default
   '${MONITOR_UNIT:-unknown unit}' rendered 'FLEET UNIT FAILED: unknown
   unit'. The helper now refuses to page when MONITOR_UNIT is unset, so a
   name-less page is structurally impossible and the test locks it. Every
   failure is still covered with the correct name + evidence by the per-unit
   STOP-REASON path (unit-escalation@%n, %i never a placeholder).
2. Register the proof pointer in config/rule-enforcement.json for the ledger
   rule led-2026-08-28-manual-evidence-pinning-and-triage-greps-fleet-op:
   the entry now cites the notify guard test and this issue's live drill.

Mechanical-fix: the regression-lock IS the prevention mechanism (fleet-ops#366
class): scenario E + the hardened scenario-A assertion prove the guard fires —
if anyone ever re-introduces a name-less page (e.g. the old
'${MONITOR_UNIT:-unknown unit}' ExecStart default of #507), the test fails
and surfaces it on every CI run.

Verification:
- tests/fleet-heartbeat-failed-notify-threshold.test.sh: PASS (scenarios
  A-E, including the new unset-MONITOR_UNIT lock)
- tests/fleet-heartbeat-failed-notify-shape.test.sh: PASS
- tests/unit-escalation-write-journal-evidence.test.sh: PASS
- tests/escalation-units-shape.test.sh: PASS
- tests/unit-escalation-write-retry-absorb.test.sh: PASS
- tests/stop-escalation-dispatch.test.sh: PASS
- config/rule-enforcement.json parses (python3 -m json.tool), diff touches
  only the evidence-pinning entry

run-proof: drill (prove-one-run) executed live 2026-08-31 —
(1) writer: `bin/unit-escalation-write pi-transport-check.service` with
UNIT_ESCALATION_AGENT_STATE redirected to a scratch dir wrote a
STOP-REASON.json whose detail.unit = pi-transport-check.service with 5 real
journal lines and 2 real error-priority lines ("Failed to start
pi-transport-check.service"), exit 0, no auditor summoned (agent-state
redirected); deployed writer is byte-identical to this PR's writer.
(2) notify: through a stub hermes (the real messenger was never invoked),
MONITOR_UNIT="pi-transport-check.service" rendered exactly "FLEET UNIT FAILED
(1 consecutive): pi-transport-check.service on netcup-rs2000 — check:
systemctl --user status pi-transport-check.service"; with MONITOR_UNIT unset
it printed "MONITOR_UNIT unset, nothing to do", exit 0, created no state dir
and no page.
(3) systemd delivery, both shapes proven on systemd 255: single-source
OnFailure= activation delivered MONITOR_UNIT + MONITOR_SERVICE_RESULT in the
target's environment; two simultaneous failures to one target delivered NO
MONITOR_UNIT (the incident shape) — the helper's unset-guard is what makes
the name-less page impossible, and scenario E locks it.
(4) test transcript: "OK: MONITOR_UNIT unset -> no page, no state, never
'unknown unit'".

Closes #1526