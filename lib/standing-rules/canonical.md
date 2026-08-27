<!-- CANONICAL: standing-rules canonical source -->
<!-- Edit ONLY the regions between SECTION markers. The generator in
     bin/render-standing-rules rebuilds the marked regions in
     ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md from this file. -->

<!-- SECTION: idle-fleet-alarm -->
## Fleet live state — read before scoping work

The old `.idle-fleet-alarm.json` banner is GONE. It lived in the fleet control
plane, which was deleted on 2026-08-23 ("Everything runs through Pi, directly.
No launchers." — vault `global-standing-rules.md`). Do not look for it, and do
not trust any stale copy you find: `agent-state/lanes/` now holds only
`pi-seat-health.json`.

Check live state directly instead, in this order:

1. `systemctl --user list-units --state=failed` — must be EMPTY. Anything failed
   is a fault you own repairing in this turn. (Needs
   `XDG_RUNTIME_DIR=/run/user/$(id -u)` set, or it silently returns nothing.)
2. `cat /home/nish/workspaces/agent-state/lanes/pi-seat-health.json` — the Pi
   seat's last observed provider/model, HTTP status and `health_class`. Check
   `observed_at` is recent before believing it.
3. `uptime` for load, and merged-PR counts per repo for actual throughput.

A missing or unparseable state file is itself a finding — report it, never treat
it as "no news is good news".
<!-- END SECTION: idle-fleet-alarm -->

<!-- SECTION: one-fleet-rule -->
## One fleet (Nish, 2026-08-21; machinery superseded 2026-08-23)

**No second dispatcher, ever.** A second fleet spends its effort on itself
(fleet2 hit 64% self-maintenance while fleet1 landed 452 product items in the
same window). Success metric stays: merged product PRs/day (baseline 133 on
2026-08-14).

The fleet1 machinery this rule named — `agent-state/lanes` lane-manager, idle
alarm, stall watchdogs, improvement loops — was DELETED on 2026-08-23 and
replaced by Pi (see routing below). The principle stands; the implementation is
gone. Do not rebuild a dispatcher. Full history: vault
`_system/shared-memory/global-standing-rules.md` -> "One fleet" and
"Everything runs through Pi".
<!-- END SECTION: one-fleet-rule -->

<!-- SECTION: nish-preimplementation-contract -->
## Mandatory pre-implementation contract

Before implementation work, automatically read and follow `/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/pre-implementation-contract.md`. This is non-negotiable for {{SURFACE_PREIMPLEMENT_PHRASE}}. For non-trivial work, investigate first, present Goal, Blocking questions, Assumptions, and Plan, then stop for Nish's approval. Only the contract's tiny obvious-change proportionality exception permits immediate implementation.
<!-- END SECTION: nish-preimplementation-contract -->
