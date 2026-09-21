# Observe-close for #7445 — heartbeat failures and the dead-PR precheck: every organ the issue names is deleted from main

Issue #7445 (filed 2026-09-17 during read-only checks for #7404) reported
two failed user units on netcup-rs2000:

- `fleet-heartbeat.service` — tier1 rc=1; several canary return codes were
  1; the detector-queue reconciler returned 1. Last fail 14:52:02Z.
- `fleet-merged-pr-close.service` — its dead-PR `ExecStartPre` reported PR
  #6888 as conflicting with parent #5870 (closed), then returned 1. Last
  fail 14:54:07Z. Related existing alarm: #6994.

Acceptance as written: identify current causes, link existing alarms, repair
through normal PR gates where needed, and show successful runs without
suppressing the detectors.

By the time this re-claim ran (2026-09-21), every organ the issue names had
already been deleted from main in the 2026-09-18 glue sweep, and both
specific defects the report describes were fixed independently before their
organs were retired. No new code is needed; this report is the resolution
record, following the #6467 and #7511 observe-close convention.

## What was found

1. **The heartbeat tower is deleted.** `ca33faa96` (2026-09-18T16:39 IST,
   "the unit IS the worker — collapse intake/worker/scout to pi --print")
   deleted `bin/fleet-heartbeat`, `bin/fleet-heartbeat-tier1` (3,185 lines),
   `-tier2`, `-auditor`, `-low-water-mark`, `-red-pr-repair`,
   `-undersaturation`, plus `systemd/fleet-heartbeat.service`/`.timer` and
   `prompts/heartbeat.md`. `README.md` §"Fleet heartbeat — DELETED
   2026-09-18" records the rationale: the work moved to the organs that
   already did it — `pi-intake@<repo>.timer`, the PR auto-merge workflow,
   and the `SystemUnitFailed` rule in `config/fleet_rules.yml`. No producer
   of the 14:52:02Z failure is left to fail.

2. **The standalone canaries are deleted.** `19b805df2`
   ("second-cut-A: delete the standalone fleet canaries", 2026-09-18T16:42
   IST) removed `bin/gh-webhook-canary.py`, `bin/fleet-work-supply-canary`,
   their units and tests. Its own message names the issue's symptom
   exactly: "cf-token-canary, worker-app-canary and
   fleet-pi-extensions-canary were never files — inline tier1 blocks, three
   of which returned rc=1 every tick."

3. **The detector-queue reconciler is deleted.** `a437f7be6`
   ("second-cut-B: delete the fleet-state reconcilers …", 2026-09-18T16:47
   IST) deleted `lib/detector-queue-reconciler.py`. The rc=1 it returned
   was fixed first, the same day the issue observed it: `bd8b02aa4`
   (#7479 / PR #7558, 2026-09-17T21:03Z) made a cap hit a LOUD warning that
   returns 0 and changed the tier1 guard from `>=2` to `!=0`, so a real
   reconciler failure propagates instead of being swallowed.

4. **The merged-PR-close rail and its dead-PR detector are deleted.**
   `0dc5dd4ac` ("GitHub closes the issue — drop the observe-to-close
   sweep", 2026-09-18T16:55 IST) removed `bin/fleet-merged-pr-close` (692
   lines), `bin/fleet-dead-pr-detector` (439 lines),
   `systemd/fleet-merged-pr-close.service`/`.timer` and both test suites.
   This is the same deletion already recorded as an observe-close for
   #6467 — `docs/reports/fleet-merged-pr-close-rail-observe-close-6467.md`
   (PR #7964, #6467 closed 2026-09-20). The rail whose `ExecStartPre`
   failed has no rail left to fail.

5. **The parent-attribution defect the issue asks to verify was fixed
   before the detector was deleted.** `f43e5823f` (fleet-ops#7694 / PR
   #7703, 2026-09-18T09:24Z) and `590531bce` (2026-09-18T14:57 IST)
   deleted the "closed parent implies dead" rule. The detector's final
   header states it plainly: "A closed issue cited by a PR is EVIDENCE, not
   a parent … Parent state is therefore never consulted as a death signal
   again." That rule had produced 96 of the unit's 106 failures in the 7
   days to 2026-09-18 — the #6888/#5870 mis-citation class this issue
   observed. The issue's requested check ("verify that parent attribution
   is correct before any cleanup") is satisfied by that fix; no cleanup is
   owed.

6. **Related alarm #6994 is closed.** "alarm: UNIT-FAILED — still failed
   after repair n=6 [loud/unit-failed/fleet-merged-pr-close.service]"
   closed 2026-09-17T16:05:07Z.

7. **The named dead PR resolved itself.** PR #6888 is CLOSED (not merged)
   at 2026-09-17T16:01:25Z; its cited parent #5870 closed 2026-09-12. No
   PR was closed merely because a referenced issue was closed — the
   false-positive rule was removed, and #6888 left the scan on its own
   state change (the class only lists `--state open`).

8. **No live reference remains on main.** Greps over origin/main for
   `fleet-heartbeat`, `fleet-merged-pr-close`, `fleet-dead-pr-detector`
   and `detector-queue-reconciler` hit only historical observe-close
   records under `docs/reports/`, dated design/audit docs, `.fleet/`
   fixtures, and two non-live comments: the provenance note in
   `bin/fleet-claim-release:14` describing where its orphan-pass logic came
   from, and a deleted-organ list in `tests/intake-gate-release.test.sh:6`.
   `lib/` carries no reconciler; `systemd/` carries no
   heartbeat/canary/merged-pr-close unit.

9. **The host carries no live organ.** Every named unit is unknown to
   systemd, `~/.config/systemd/user/` holds no matching file, and
   `list-timers` shows none. The `~/.local/state/fleet-heartbeat/` state
   directory survives as inert residue (last file write 2026-09-18 18:56);
   no file on main reads it (`FLEET_HEARTBEAT_LOG_DIR` has zero hits in
   `bin/ libexec/ systemd/ config/ tests/`).

## Why the acceptance arms do not apply as written

"Repair through normal PR gates" presupposes a live organ to patch.
`bin/fleet-heartbeat-tier1`, the inline canary blocks, the reconciler and the
`bin/fleet-merged-pr-close` rail with its `bin/fleet-dead-pr-detector`
`ExecStartPre` are all gone from main; re-adding any of them would reinstate
the very cuts the 2026-09-18 sweep adjudicated. "Show successful runs
without suppressing the detectors" is likewise unreachable as a heartbeat
tick — there is no heartbeat tick. What replaces it is the live surviving
detection surface, which is demonstrably healthy and was never suppressed:
`SystemUnitFailed` in `config/fleet_rules.yml` (18 rules, `promtool` green)
pages on any failed unit, `pi-intake@<repo>.timer` picks up queued work, and
the PR auto-merge path is a GitHub workflow. The final states of both
defects confirm no suppression happened: the reconciler's rc=1 was fixed
openly in #7558 and the dead-PR mis-citation in #7703 before the sweep
retired their carriers.

## Acceptance verification (2026-09-21T21:42:34Z, netcup-rs2000)

| Check | Result |
|---|---|
| Deletion commits on origin/main | `git merge-base --is-ancestor` → YES for `ca33faa96`, `19b805df2`, `0dc5dd4ac`, `a437f7be6`, `590531bce` (origin/main `29ea7c059`) |
| Heartbeat/close code on main | `git ls-tree -r origin/main` for `bin/fleet-heartbeat*`, `bin/fleet-merged-pr-close`, `bin/fleet-dead-pr-detector`, `lib/detector-queue-reconciler.py` → zero hits |
| Live-code references | `git grep` for `fleet-heartbeat`, `fleet-merged-pr-close`, `fleet-dead-pr-detector`, `detector-queue-reconciler` over `bin/ libexec/ systemd/ config/ tests/ prompts/` → two comments only (`bin/fleet-claim-release:14`, `tests/intake-gate-release.test.sh:6`); no live code, unit or config |
| Failed units | `XDG_RUNTIME_DIR=/run/user/1000 systemctl --user list-units --state=failed` → "0 loaded units listed" |
| Named units | `systemctl --user status` for `fleet-heartbeat.service`/`.timer`, `fleet-heartbeat-tier1.service`, `fleet-merged-pr-close.service`/`.timer`, `gh-webhook-canary.service`, `fleet-work-supply-canary.service` → "could not be found" ×7 |
| Unit files on host | `ls ~/.config/systemd/user/` filtered for `heartbeat|canary|merged-pr-close|reconcil` → no match |
| Surviving detection surface | `config/fleet_rules.yml` `SystemUnitFailed` present; `promtool check rules` → SUCCESS, 18 rules |
| Live timers (successful runs) | 9 user timers ticking, e.g. `fleet-sync` last 2026-09-22T03:12:04 IST, `fleet-metrics-export` last 03:10:00 IST, `pi-intake@0509` last 03:10:02 IST, `pi-scout@fleet-ops` last 00:04:17 IST |
| Related alarm | #6994 → CLOSED 2026-09-17T16:05:07Z |
| Named dead PR | #6888 → CLOSED (not merged) 2026-09-17T16:01:25Z; cited parent #5870 CLOSED 2026-09-12 |
| Sibling rail record | `docs/reports/fleet-merged-pr-close-rail-observe-close-6467.md` on main (PR #7964) |

## Residual note

The `~/.local/state/fleet-heartbeat/` directory is the deleted tower's
inert state (blocked-queue, red-pr-repair markers, deploy-audit logs). No
live file reads it, so it was left in place rather than destroyed — it is
history, not a running surface. The issue carries `agent-in-progress` from
the 2026-09-21 claim; this record's PR performs the `Closes #7445` close.
No follow-up is filed: there is no heartbeat, canary, reconciler or
merged-PR-close rail left to repair or suppress.
