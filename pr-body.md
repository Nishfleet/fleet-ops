## Summary

`scout-futility-check` now measures the work buffer in **hours of runway**, not raw issue count. It reuses the existing `lib/work-supply.sh` math (trailing 6h consumption rate from closed `agent-ready` issues) so the detector escalates when the fleet has less than 12 hours of banked work at the current drain rate.

- `runway_hours = ready_count / consumption_rate` over a 6h window.
- Reset threshold: `runway >= SCOUT_FUTILITY_BUFFER_H` (default 12h) or net runway increase.
- Item-count floor preserved: when no closes are observed, `work_supply_hours` falls back to `ready_count` as hours, so a stalled repo cannot claim infinite runway from zero consumption.
- The `led-2026-08-28-runway-measured-in-time` rule-enforcement matrix row is updated to `enforced`.

No new units, timers, or workflows are added; this is a formula + config change in the existing `scout-futility-check` organ.

## Verification

- `bash tests/scout-futility.test.sh` — OK (including new scenario16 that proves 12 ready items with high drain = 6h runway and escalates)
- `bash tests/fleet-work-supply-canary.test.sh` — OK
- `bash tests/rule-enforcement.test.sh` — OK
- `python3 lib/rule-enforcement.py validate-matrix --matrix config/rule-enforcement.json` — OK
- `python3 lib/rule-enforcement.py join --rules /home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md --ledger /home/nish/workspaces/tooling/nish-vault/_system/shared-memory/decisions-ledger.md --matrix config/rule-enforcement.json` — OK
- `sgscan --base origin/main` — no new security findings

run-proof: tests/scout-futility.test.sh scenario16 and rule-enforcement tests passed

Closes #1515
