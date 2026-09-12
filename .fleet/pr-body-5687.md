## Summary

Closes the never-file gap behind the 55x/14h DEPLOY-CHECK-DIRTY-CLONE treadmill (#5687): writer forensics + clone reconcile for the record, and the accept-4 prevention mechanism (3rd consecutive LOUD recurrence auto-files a dedupe-gated issue).

### Forensics (accept 1-3) — the clone was already reconciled correctly before this PR

- Writer named (accept 1): the `lib/standing-rules/canonical.md` in-clone edit came from unit `pi-issue@fleet-ops-5588` (issue #5588, the rulebook-redteam "One fleet" packet, now CLOSED; PR #5609 is open from its `claim/issue-5588` and carries the identical one-fleet-rule title+archive-pointer consolidation). The unit is still activating (restart loop) but its issue is closed and its work is banked: commit `59b890da3` "salvage: bank uncommitted work for unit pi-issue-fleet-ops-5588" in `agent-worktrees/issue-fleet-ops-5588`.
- canonical.md (accept 2): the in-clone edit was discarded, not banked — verified: the salvage commit banks only `.fleet/pr-body-5588.md`. That is exactly the prescribed action, since PR #5609 carries the identical consolidation. main's canonical.md still carries the full section body, so nothing was lost and no salvage PR is needed.
- AGENTS.md.bak-rulebook-redteam-20260912 (accept 3): rulebook-redteam packets #5641-#5645 are all CLOSED — no active packet references the .bak, so `git clean -f` was the prescribed action; the file is gone from the clone.
- Timeline evidence: last DIRTY-CLONE LOUD 06:34:05 IST; by the 06:36:28 tick the clone was already clean (no DEPLOY-RESCUE fired in between — the newest rescue snapshot is 06:13:53 IST and contains only a stray `demo-wip.txt`); the 06:46:11 tick fast-forwarded to 34edbda86 and the deploy completed rc=0. No unit has re-dirtied the clone since.
- Issue verify lines, both green: `git -C /home/nish/workspaces/tooling/fleet-ops-deploy-clone status --porcelain` → empty (0 bytes); `journalctl --user -u fleet-deploy-check.service --since "-10min" | grep -c DIRTY-CLONE` → 0 on subsequent ticks.

### Prevention mechanism (accept 4)

`bin/fleet-deploy-check`'s DIRTY-CLONE branch now counts consecutive dirty ticks and on the 3rd consecutive recurrence auto-files one dedupe-gated issue per episode through the alarm issue-file path (`bin/fleet-issue-file`, fleet-ops#1212), with a `signal: deploy-check/dirty-clone` marker in the body. A clean tick resets the episode (so a fresh episode can file again); a failed filing logs a WARN line and retries next tick without failing the check (exit-0-always contract preserved). Behind `FLEET_DEPLOY_CHECK_DIRTY_AUTOFILE` — default OFF in the script (byte-identical behavior without it), turned on by one `Environment=` line in `systemd/fleet-deploy-check.service`, so revert is a one-line re-deploy (the issue's rollback note).

ship-phase: phase 1 of 1 — the whole mechanism; no migrations involved.

Verification:
- `bash tests/fleet-deploy-check.test.sh` → all OK lines plus 4 new blocks green: default-OFF (LOUD only, no episode state, zero issue-file invocations), 3rd-consecutive-tick files exactly once via `file -R Nishfleet/fleet-ops --title DEPLOY-CHECK-DIRTY-CLONE...` carrying the `signal:` marker, clean tick resets the episode and a fresh episode re-files on its 3rd tick, failed filing logs `WARN: DIRTY-CLONE auto-file failed` and retries next tick (non-fatal)
- `bash tests/manifest-shape.test.sh` → OK (MANIFEST unchanged; no new files)
- `systemd-analyze --user verify systemd/fleet-deploy-check.service` → exit 0
- `bin/sgscan` → "No new security findings."
- `bash -n bin/fleet-deploy-check tests/fleet-deploy-check.test.sh` → exit 0
- live box: deploy-clone porcelain empty since 06:36 IST; DIRTY-CLONE LOUD count on every subsequent tick = 0

run-proof: fleet-deploy-check.service + fleet-deploy-check.timer are existing machinery (no new unit/timer/workflow in this diff); real run proof: the full `tests/fleet-deploy-check.test.sh` suite green end-to-end on this exact diff (25 OK + PASS deploy-audit-log), and the live unit completed a real merge-to-live at 2026-09-12T01:16:42Z (`deploy completed rc=0 — live now at origin/main (34edbda8...)`) with 0 DIRTY-CLONE LOUDs on subsequent ticks.

net-positive-because: accept-4 requires new detection logic (consecutive-streak state, per-episode filing, 4 new test blocks); the mechanism is self-limiting (one filing per episode, dedupe-gated, env-flag default-off) and closes a control that shouted 55x/14h with zero filings.

organ-heartbeat: systemd/fleet-deploy-check.service not-an-organ: fleet-deploy-check is absent from config/fleet-organs.json — it is the merge-to-live gate itself, not a timer/exporter/guard/canary organ; no heartbeat metric or absent() rule changes.

loose-ends: live-unit-env — the `Environment=FLEET_DEPLOY_CHECK_DIRTY_AUTOFILE=1` line reaches the live unit only when the merge-to-live lane installs this PR (standard path: merge → fleet-ops-deploy → install.sh + daemon-reload); until then the gate keeps today's LOUD-only behavior, which is the safe default.

Closes #5687
