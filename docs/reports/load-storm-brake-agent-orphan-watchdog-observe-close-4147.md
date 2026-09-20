# Observe-close for #4147 — load-storm-brake + agent-orphan-watchdog retirement: delivered by #4192, runtime gate met 2026-09-20/21

fleet-ops#4147 (owner-authored, umbrella #4140 row 8, `band-multiplier: 4`)
retired the last two hand-built load-path executors —
`~/.local/libexec/load-storm-brake` (197 lines) and
`~/.local/libexec/agent-orphan-watchdog` (179 lines) — live-only host
files never tracked in this repo, in favor of stock systemd: `systemd-oomd`,
`CPUWeight`/`IOWeight`, and cgroup scoping (every agent launch inside a
scope/service with `KillMode=control-group`, so orphaned descendants cannot
exist). Nish's acceptance named four arms: (1) replacement live and proven
with one real run; (2) the hand-built files, units, timers, backups and prom
writers WIPED (rm, not parked, not `.bak`; git history is the archive); (3)
one line appended to the vault never-rebuild ledger
(`_system/shared-memory/retired-mechanisms.md`); (4) grep proves no
reference remains.

PR #4192 (merged 2026-09-09T00:58:10Z, squash merge
`9e8ef39b3397d23f255bce54124705e0a3ac099f`, branch `claim/issue-4147`)
delivered all four arms and the design doc's row 8 record
(`docs/design/hand-built-vs-off-the-shelf.md` — row 8 and its detail
section read **DONE (retired 2026-09-07, #4147)**). Its trailer was
`Relates to #4147` — a mention under the fleet-ops#3231 delivery rules,
not a closer — so GitHub never closed the issue. That is the whole reason
#4147 re-entered the claimable pool three times on 2026-09-07 (two
StartLimitBurst claim releases), drew two hourly bursts of `spec-gate:
refused agent-ready` refusals (2026-09-07→08 and 2026-09-12, last
09-12T11:52:57Z) until the body gained its line-anchored `accept:` /
`moves:` lines the same day, collected two observe-to-close notices —
"merged PR #4192 is not closing it", then the same for #6207 — and was
finally parked under `awaiting-runtime-gate` by the fleet-ops#5048
detector — "protected issue + delivered work awaiting a runtime gate". The
runtime gate those claims kept pending is exactly what this record
performs: the four acceptance arms re-verified live on netcup-rs2000 at
2026-09-20T19:20–19:55Z. Every arm still holds; no code change remains to
ship. This report is the resolution record, matching the established
observe-close pattern (the #6799 record, PR #7968; the #6499 record,
PR #7965; the #4142 repo-sync record, PR #7979; the #6665 record, also
on main). It is authored on `claim/issue-4147` — this run re-issued the
claim at 2026-09-20T19:19:21Z and re-based onto origin/main `c913082aa`
for this record; no salvage commit existed to cherry-pick (the 2026-09-07
released claim branches left no `origin-wip` salvage refs, and the deliver
landed on main with #4192).

## What was found

1. **The delivery is merged and ancestor-verified.**
   `gh pr view 4192 --json state,mergeCommit` → MERGED
   2026-09-09T00:58:10Z, squash `9e8ef39b3397d23f255bce54124705e0a3ac099f`;
   `git merge-base --is-ancestor 9e8ef39b3397 origin/main` → yes at
   origin/main `c913082aa` on 2026-09-20. The PR's body itself states the
   wipe, the ledger append, the umbrella row and the remaining-mentions
   policy ("Remaining mentions are the retirement record (design doc
   row 8) and the deletion pin test itself").
2. **Arm 1 — replacement live and proven with one real run (this one).**
   `systemctl is-active systemd-oomd` → active. Worker units run scoped:
   this record's own run executed inside
   `user.slice/user-1000.slice/user@1000.service/app.slice/app-pi\x2dissue.slice/pi-issue@fleet-ops-4147.service`
   (`systemctl --user show pi-issue@fleet-ops-4147.service` →
   `KillMode=control-group`, `ActiveState=activating`, started
   2026-09-21T00:49:28 IST). The agent slice carries
   `ManagedOOMMemoryPressure=kill` (systemd-oomd pressure-kills the worker
   slice itself). `systemctl show user-1000.slice -p CPUWeight` →
   `CPUWeight=60`; the interactive tmux child scopes run
   `KillMode=control-group` and `CPUWeight=300` via the
   `~/.config/systemd/user/tmux-spawn-*.scope.d/50-interactive-cpu-priority.conf`
   drop-in. Orphans cannot exist because nothing in the launch path
   detaches from its cgroup; the brake and watchdog had nothing left to
   watch.
3. **Arm 2 — wiped with rm, nothing parked.** Probed live on
   netcup-rs2000 2026-09-20: `~/.local/libexec/load-storm-brake`,
   `~/.local/libexec/agent-orphan-watchdog`,
   `~/.config/systemd/user/agent-governor-orphan-watchdog.timer`,
   `~/.config/systemd/user/agent-governor-orphan-watchdog.service`, and
   the leftover stamp `~/.local/state/systemd/stamp-agent-governor-
   orphan-watchdog.timer` — all absent (`test -e` → false on each);
   `systemctl --user list-unit-files | grep -iE 'storm|orphan|watchdog'`
   → no matching unit files; `systemctl --user list-timers --all` → no
   matching timers (10 timers total, none related). No `.bak` or parked
   copies: git history is the archive, and the scripts were never tracked
   in a repo (live-only files), so the history lives in the umbrella
   repair records and the #4192 review trail.
4. **Arm 3 — vault never-rebuild ledger line present.**
   `_system/shared-memory/retired-mechanisms.md` line 11 reads:
   "- load-storm-brake + agent-orphan-watchdog (~/.local/libexec/load-storm-brake,
   ~/.local/libexec/agent-orphan-watchdog, agent-governor-orphan-watchdog.timer,
   fleet-ops#4147) | hand-built load-storm brake + all-agents orphan janitor; every
   agent launch now runs as a scope/service (KillMode=control-group) so orphans
   cannot exist, and systemd-oomd + CPUWeight/IOWeight prevent load storms |
   systemd-oomd + CPUWeight/IOWeight + cgroup scoping (systemd-run --scope,
   KillMode=control-group) | 2026-09-07 | do not rebuild unless systemd-oomd is
   unavailable AND cgroup scoping cannot prevent orphaned descendants
   (fleet-ops#4147)" — what, why retired, what replaced it, date, and the
   do-not-rebuild-unless reason, all in one line as required.

## Acceptance verification (2026-09-20T19:20–19:55Z, netcup-rs2000)

| Arm | Probe | Result |
|---|---|---|
| 1 replacement live | `systemctl is-active systemd-oomd` | active |
| 1 replacement live | `systemctl --user show pi-issue@fleet-ops-4147.service -p KillMode` | `control-group` (unit running this record's own verification) |
| 1 replacement live | `systemctl show user-1000.slice -p CPUWeight` | `CPUWeight=60` |
| 1 replacement live | `systemctl --user show <tmux-spawn-….scope> -p KillMode -p CPUWeight` | `control-group`, `CPUWeight=300` |
| 1 replacement live | `systemctl --user show 'app-pi\x2dissue.slice' -p ManagedOOMMemoryPressure` | `kill` (oomd pressure-kills the worker slice) |
| 2 wiped | `test -e` over the five host paths (scripts, unit files, stamp) | all false → wiped |
| 2 wiped | `systemctl --user list-unit-files` / `list-timers --all` greps for `storm\|orphan\|watchdog` | no matching unit files, no matching timers |
| 3 ledger | `grep -n '4147' _system/shared-memory/retired-mechanisms.md` | line 11 present with all five fields |
| 4 grep | repo-wide `rg -i 'load-storm-brake\|agent-orphan-watchdog'` at origin/main `c913082aa` | only `docs/design/hand-built-vs-off-the-shelf.md` rows 41, 156, 158, 316, 348 — the retirement record itself |

Arm 4, stated precisely: zero references to either mechanism name remain
in `bin/`, `libexec/`, `lib/`, `config/`, `prompts/`, `systemd/` or
`tests/` at origin/main; the only matches are the design doc's row-8
retirement record, which is the point of the record — the archive the
issue demands rather than residue. `config/fleet_rules.yml` carries no
load-storm alert rule and `config/alertmanager.yml` no storm route for
these mechanisms (both were edited by #4192); the only incidental
`LoadStorm` mentions are historical strings inside
`config/seat-caps.json` comment fields, which attribute prevention to
"oomd + CPUWeight/IOWeight + cgroup scoping (fleet-ops#4147)" — context
for admission-charge history, not a live reference to a wiped mechanism.

## Why no code change applies

Both live arms presuppose the two live-only host scripts, which left the
host on 2026-09-07 with the #4192 delivery — before either script was
ever tracked by any repo. The repo-side residue (the deletion pin
test the #4192 body added as a belt,
`tests/load-storm-brake-agent-orphan-watchdog-deleted.test.sh`) was itself
swept on 2026-09-18 by `68e0954e7` ("cut(glue): delete 5 uncalled lib
files, 1 dead prompt, 2 dead configs, 14 orphan tests", ancestor of
origin/main — verified) together with the rest of the orphan test suite;
the suite deletion is the fleet-ops#7828-era cut with gates moving to
GitHub built-ins. Re-adding either the scripts or their pin would
reinstate a deliberate #4140/4147 decision — the replacement is live and
stock, and the retirement record + git history are the archive the
acceptance arms name. There is no surface on main left to edit toward
this issue's closer; the umbrella row is DONE and stayed DONE at
origin/main.

## Verification

- `gh pr view 4192 -R Nishfleet/fleet-ops --json state,mergedAt,mergeCommit,files`
  → MERGED 2026-09-09T00:58:10Z, squash `9e8ef39b3397…`; trailer
  `Relates to #4147` (no closing keyword).
- `git merge-base --is-ancestor 9e8ef39b33… origin/main` → yes (origin/main
  `c913082aa`, 2026-09-20); `git merge-base --is-ancestor 68e0954e7
  origin/main` → yes (orphan-test sweep, 2026-09-18T21:46:00+05:30).
- `git ls-remote origin refs/heads/claim/issue-4147` at claim time
  → `b20776708…` (origin/main's tip then); no `origin-wip` salvage refs
  matching `4147` exist.
- Live on netcup-rs2000 (2026-09-20T19:20–19:55Z): systemd-oomd active;
  `pi-issue@fleet-ops-4147.service` shows `KillMode=control-group`;
  `user-1000.slice` `CPUWeight=60`; tmux-spawn scope drop-in
  `50-interactive-cpu-priority.conf` with `CPUWeight=300` +
  `KillMode=control-group`; `app-pi-issue.slice`
  `ManagedOOMMemoryPressure=kill`; all five residue paths absent; no
  matching unit files or timers.
- Fleet alive while on this check: `litellm /health/readiness` → healthy,
  db connected; `litellm_deployment_state` gauges all 0.0;
  `systemctl --user list-units --state=failed` → empty; 10 user timers
  listed (fleet-sync, fleet-metrics-export, pi-intake×2, pi-scout×2,
  daily-digest, branch-prune, tmpfiles, launchpadlib) with no
  storm/orphan/watchdog entries; load 1.30 on an idle-fleet-healthy box.
- The deletion pin test's absence explained for the record: swept by
  `68e0954e7` with 13 sibling orphan tests — repo-side belt removed by a
  superseding cut, not lost; the arms that pin it (wiped paths, ledger
  line, design row) all re-verified live in this record anyway.

run-proof: probes above ran live on netcup-rs2000 2026-09-20T19:20–19:55Z
against origin/main `c913082aa`; merge ancestry via `git merge-base
--is-ancestor`; PR state/trailer via `gh pr view`; host unit and timer
state via `systemctl --user`; docs-only record — no unit, timer,
workflow, script or code path touched.

loose-ends: none — docs-only resolution record for a retirement already
delivered and merged (#4192); the protected issue's close travels via
this record's `Closes #4147` trailer on merge.
