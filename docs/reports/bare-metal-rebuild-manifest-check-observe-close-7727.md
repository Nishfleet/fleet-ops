# Observe-close for #7727: the bare-metal rebuild manifest check is deleted

Issue #7727, filed 2026-09-18T10:57:53Z, is the heartbeat detector's alarm for one loud line:

- alarm tag `BARE-METAL-REBUILD-FAIL`
- evidence `manifest-check: 1 violation(s)`
- observed tick `2026-09-18T10:48:23Z`
- signal key `loud/bare-metal-rebuild-fail/manifest-check-violation`

The filing text says the detector-to-queue reconciler, fleet-ops#362, should close the issue only when a later heartbeat tick reports the detector green. By the time this re-claim ran, 2026-09-22T05:37:43Z, that detector, the script that printed the evidence line, and the reconciler were all gone from origin/main. Nothing is left that can emit this signal or observe it closed. This report is the close record, same convention as #7710, PR #8170, and #7445.

The possible-duplicate banner pointing at #7706, score 0.49, is a different alarm. #7706 is the failed-command-swallowed filing cooldown, closed 2026-09-22. It does not share this signal key.

## What was found

1. The exact evidence string had one producer. In `bin/fleet-bare-metal-rebuild` at parent of `63b6b250c`, `manifest_check` ended with `fail "manifest-check: $violations violation(s)"`, and `fail` wrote `LOUD [BARE-METAL-REBUILD-FAIL]`. The weekly drill, `bin/fleet-bare-metal-rebuild-drill`, called `fleet-bare-metal-rebuild --manifest-check` and turned a non-zero exit into its own `MANIFEST-DRILL` line. No other file in that tree printed `manifest-check: N violation(s)`.

2. The drill unit and script were deleted the same morning, before the filing tick. `b7d63866f`, 2026-09-18 14:44 IST, `09:14 UTC`, removed `bin/fleet-bare-metal-rebuild-drill`, `systemd/fleet-bare-metal-rebuild-drill.service`, and the timer. The alarm tick is `10:48:23Z`, so the tick is the heartbeat reporting a line already written, not a drill that still existed in git.

3. The rebuild script and its manifest were deleted later the same day. `63b6b250c`, 2026-09-18 18:09 IST, removed `bin/fleet-bare-metal-rebuild` at 596 lines, `config/bare-metal-rebuild-manifest.json` at 244 lines, `lib/bare-metal-masked-units.sh`, `docs/bare-metal-rebuild.md`, and `tests/fleet-bare-metal-rebuild.test.sh`. The commit message records that the script never rebuilt this box. `git merge-base --is-ancestor` is true for `b7d63866f` and `63b6b250c` against HEAD `1359397b2`.

4. The filer is deleted too. `ca33faa96`, 2026-09-18 16:39 IST, deleted `bin/fleet-heartbeat` and `bin/fleet-heartbeat-tier1`. `a437f7be6`, 2026-09-18 16:47 IST, deleted `lib/detector-queue-reconciler.py`. Both commits are ancestors of HEAD. There is no heartbeat tick left to go green, and no reconciler left to close the issue on a green tick.

5. The string is gone from live code. `git grep BARE-METAL-REBUILD-FAIL HEAD` over `bin/`, `systemd/`, `config/`, `tests/`, `lib/`, `libexec/`, and `prompts/` returned no hits. `git ls-tree -r HEAD` does not contain `bin/fleet-bare-metal-rebuild`, `bin/fleet-bare-metal-rebuild-drill`, `config/bare-metal-rebuild-manifest.json`, `docs/bare-metal-rebuild.md`, `lib/bare-metal-masked-units.sh`, `lib/detector-queue-reconciler.py`, `systemd/fleet-bare-metal-rebuild-drill.service`, `systemd/fleet-bare-metal-rebuild-drill.timer`, `bin/fleet-heartbeat`, or `bin/fleet-heartbeat-tier1`. Remaining mentions are historical notes in `docs/organ-catalog.md`, `docs/design/hand-built-vs-off-the-shelf.md`, and `docs/reports/wait-online-mechanism-match-7075.md`.

6. The host has no leftover organ. `systemctl --user status` for `fleet-bare-metal-rebuild-drill.service`, its timer, and `fleet-bare-metal-rebuild.service` all returned `could not be found`. `~/.config/systemd/user/` and `/etc/systemd/system/` have no matching unit files. `~/.local/bin/fleet-bare-metal-rebuild` and `fleet-bare-metal-rebuild-drill` are absent. `journalctl --user -u fleet-bare-metal-rebuild-drill.service` since 2026-09-17 has no entries. `~/.local/state/fleet-bare-metal-rebuild-drill` does not exist. `~/.local/state/fleet-heartbeat/triage.md` has no `BARE-METAL-REBUILD` or `manifest-check` line, so the original single violation, which of the checks inside `manifest_check` incremented the counter, is not recoverable. That does not matter. The function that counted it is not on main.

## Why the filing close rule cannot run

The issue body says not to close on PR merge, and to wait for the reconciler to see a green heartbeat tick. That reconciler and that tick were deleted on 2026-09-18. Re-adding either one would undo the glue sweep. The close path that replaced them is the PR `Closes #7727` trailer. GitHub closes the issue. That is the same path recorded for the merged-PR observe-to-close row in `docs/organ-catalog.md`.

The manifest check was a static inventory of a rebuild package that was never used to rebuild this box. It is not the restic restore proof. `restic-r2-restore-test.service` is failed as of 2026-09-22 06:05 IST. That failure is already issue #8009. It is a different unit and a different signal. This record does not claim the backup proof is green, and it does not change that unit.

## Acceptance verification, 2026-09-22T05:37:43Z, netcup-rs2000

| Check | Result |
|---|---|
| Deletion commits on HEAD `1359397b2` | `git merge-base --is-ancestor` yes for `b7d63866f`, `63b6b250c`, `ca33faa96`, `a437f7be6` |
| Named paths on HEAD | `git ls-tree -r HEAD` for the ten paths in finding 5: all absent |
| Live-code tag | `git grep BARE-METAL-REBUILD-FAIL` over `bin systemd config tests lib libexec prompts`: no hits |
| User failed units | `systemctl --user list-units --state=failed`: 0 loaded units |
| Named units | three `could not be found` |
| Installed binaries | both paths absent |
| Drill journal | no entries since 2026-09-17 |
| Replacement rule file | `promtool check rules config/fleet_rules.yml`: SUCCESS, 14 rules. `ResticRestoreProofStale` is present. `LitellmPgDumpStale` is not in the file |
| Readiness | `curl 127.0.0.1:4000/health/readiness` returned `{"status":"healthy","db":"connected"}` |
| Seat gauges | 9 `litellm_deployment_state` rows, 0 nonzero |
| Live timers | `fleet-sync.timer` last 11:06 IST, `pi-intake@0509.timer` last 11:05 IST, `pi-scout@fleet-ops.timer` last 08:00 IST |
| Sibling alarm | #8009 is open for the failed restic restore-test unit. Out of scope here |
| False duplicate | #7706 closed 2026-09-22, different signal |

## Residual

`~/.local/state/fleet-heartbeat/` still exists. No file on main reads it for this alarm, and `triage.md` does not contain the loud line. Left in place. No follow-up is filed for the manifest check. There is no rebuild script, drill, heartbeat, or reconciler left to repair. The failed restic restore stays on #8009.
