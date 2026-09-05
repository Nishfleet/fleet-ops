thorough.backup_freshness reported `newest_backup_marker=null` while the restore-drill timer ran green — a monitor that proves the timer ran, not that a backup artifact exists. The drill now emits a dated marker the heartbeat can stat, and fails itself when that marker is absent or stale.

## What changed

- `bin/fleet-restore-drill` writes a dated artifact at `$AGENT_STATE/alert-repair/fleet-restore-drill-marker` (mtime = run timestamp, body = ISO date + status) on every run whose planes A/B/C pass. That exact path is what the opus-heartbeat thorough gather globs (`alert-repair/fleet-restore-drill*`) for `backup_freshness.newest_backup_marker`, so the heartbeat now gets a real path + mtime + age instead of null.
- New plane D: the drill fails LOUD when the marker is absent (`RESTORE-DRILL-ARTIFACT-MISSING`) or older than the timer cadence + slack (`RESTORE-DRILL-ARTIFACT-STALE`, 28800s bound on the 6h cadence). A green timer with no artifact can no longer pass.
- Self-heal: a missing/stale marker trips one LOUD failure but is rewritten when A/B/C passed, so a transient absence (fresh install, post-outage catch-up) recovers on the next 6h cycle; a marker write that keeps failing aborts the script (set -e) and stays escalated.
- `tests/fleet-restore-drill.test.sh`: green run asserts the dated marker; new scenarios prove the guard fires for absent marker (exit 1, then self-heal green) and stale marker (exit 1, then self-heal green).

## Mechanical fix (fleet-ops#366)

The prevention mechanism ships in this PR: plane D is the gate that rejects the pattern (green run with no fresh artifact), and the regression tests (scenarios J/K) prove the guard fires for both absent and stale markers.

## Verification

- `bash tests/fleet-restore-drill.test.sh` — 15/15 OK (all prior scenarios still pass, plus the new marker scenarios).
- Live run of the deliverable against production state:
  - Run 1 (marker had never existed): exit 1, `LOUD [RESTORE-DRILL-ARTIFACT-MISSING] no restore-drill artifact marker at /home/nish/workspaces/agent-state/alert-repair/fleet-restore-drill-marker — the heartbeat's newest_backup_marker would be null`, marker written after A/B/C passed.
  - Run 2: exit 0, `LOUD [RESTORE-DRILL-OK] control plane rebuildable: ... artifact marker fresh`, marker age 12s.
  - The heartbeat gather's exact glob now resolves: `newest_backup_marker = {'path': ..., 'mtime_epoch': 1788148867, 'age_s': 13}` (was null).
- run-proof: journal-style transcript of the two live runs above (run 1 transition failure + marker creation, run 2 green); planes A/B/C passed against live system restic units (all `Result=success`, timer active/fresh).

## Organ note

No new organ, no new `bin/` file, no new systemd unit/timer, and no Prometheus-exported heartbeat metric added — the marker is a file the LLM heartbeat stats at an already-globbed path, so no `absent()` fleet_rules.yml rule or fleet-organs.json registry entry is warranted. `bin/fleet-restore-drill` was already catalogued (machinery-allowlist, asset-guard-map, organ-catalog).

Closes #2471