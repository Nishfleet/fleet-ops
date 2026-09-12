feat(routing): phase-based model routing in the packet lifecycle (fryxell harness loop)

Implements the detection + classification layer for fleet-ops#1383 — a
declarative `phases:` manifest in packets that folds into the existing
keystone routing machinery (#1133/#1167) rather than building a custom
phase router (per #1260: coordinate, don't fork).

**What changed:**
- `lib/seat-lib.sh`: New `packet_has_phases()` function detects a
  `phases: plan=capable,work=commodity,...` manifest line in packets.
  `packet_difficulty()` returns `keystone` when a phases manifest is
  present, routing the packet through capable-seat-first keystone rules.
  `record_seat_selection()` accepts an optional phases argument for
  the waste ledger (#1211 — attribute frontier-token share to capable
  phases vs commodity work).
- `bin/agent-cron-run`, `bin/pi-issue-run`, `bin/pi-issue-start`,
  `bin/pi-packet-run`: Harness scripts detect and pass phases manifests
  to seat selection.
- `prompts/intake.md`: Updated to document the phases manifest format.
- `tests/keystone-routing.test.sh`: +45 lines covering phases detection,
  keystone-class routing, and waste-ledger attribution.

**Verification:**
```
bash tests/keystone-routing.test.sh
bash tests/seat-lib.test.sh
shellcheck -x lib/seat-lib.sh bin/pi-issue-run bin/pi-issue-start bin/pi-packet-run bin/agent-cron-run
```
All passed on the VPS.

Credit: Scott Fryxell, 'The Harness Is the Thing' working loop
(explore → plan → work → critique → promote).

Closes #1383