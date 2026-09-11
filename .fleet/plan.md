# .fleet/plan.md — fleet-ops#5141 (unit pi-issue-fleet-ops-5141, manager mode)

Issue: seat registry reaps LIVE Type=oneshot workers after 300s in SubState=start — cap accounting goes blind and over-admits.
Salvage: one unpushed commit 47e53982f on claim/issue-5141 (base 7f6193aea, stale vs origin/main) already carries the accept-1/2 fix + new test.
Branch: claim/issue-5141. Never push main. Plan by stock planner (2026-09-11); phases amended only by the manager.

## Checklist
- [x] phase 1: accept 1 — `_seat_registry_unit_live` bounds a Type=oneshot activating/start unit by its own TimeoutStartUSec (`systemctl --user show <unit> --property=TimeoutStartUSec`), 3300s constant only as infinity/0/unparseable fallback, fail-closed kept for ExecMainStartTimestampMonotonic=0 and SubState=auto-restart — preserved through rebase onto origin/main per the semantic gate.
- [x] phase 1: accept 2 — the hardcoded `SubState=="start"`→300s branch is gone from the started-process path (grep gate: zero hits), remaining only as the sanctioned ExecMain=0/auto-restart bounds, with comments citing #5141 + #993/#1361.
- [ ] phase 2: accept 4 — regression test `tests/seat-registry-liveness.test.sh` with stubbed systemctl: (a) activating/start at 400s and 40min → LIVE, (b) 50min → reaped, (c) ExecMainStartTimestampMonotonic=0 for 6min → reaped, (d) activating/auto-restart → not live — all green post-fix, and (a) proven failing against current main (recorded sha) via extracted-tree run.
- [ ] phase 3: accept 3 — fail-loud drift test: the liveness bound must not fall below `TimeoutStartSec` in `systemd/pi-issue@.service`, demonstrated by forcing TimeoutStartSec=60min and watching the suite red, then restoring byte-identical.
- [ ] phase 4: accept 5 — diff vs origin/main touches no cap: `config/seat-caps.json` unchanged, no `seat_max_concurrent`/`target_concurrent`/ram-governor edits anywhere in the PR.
- [ ] phase 4: accept 6 — no new timer, no new unit, no new file in `~/.config/systemd/user`: the diff adds only `tests/seat-registry-liveness.test.sh` and touches no `systemd/`/`*.timer`/`*.service` path.

## Phase details (from planner — workers execute these verbatim)

### Phase 1 — rebase salvaged commit onto origin/main, resolve lib/seat-lib.sh conflicts preserving #5141 semantics
1. Pre-flight: `git rev-parse --abbrev-ref HEAD` (claim/issue-5141); `git status --porcelain` (commit none of it); `git fetch origin`; HEAD=47e53982f, HEAD^=7f6193aea; `git log --oneline origin/main..HEAD` = exactly the one fix commit; `git log --oneline 7f6193aea..origin/main -- lib/seat-lib.sh` = 85e81dc53 ec628dec8 ec8049a94 514fda3f1. Contingency: extra salvage commits → bank msg, `git reset --soft origin/main && git commit -F /tmp/fo5141-msg` for a one-commit PR.
2. `git rebase origin/main`. Expected conflict: lib/seat-lib.sh (maybe tests/seat-lib.test.sh, trivial). Any OTHER file conflicting → `git rebase --abort` and reassess.
3. Resolve lib/seat-lib.sh by region — ours = #5141 semantics, main = everything else:
   - PI_SEAT_ACTIVATING_MAX_S comment+define: take OURS (fallback variant citing _seat_liveness_bound_s + #5141); drop main's "ActiveEnterTimestamp is the ground truth" sentence (false under the fix). Keep main's PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S block verbatim.
   - Insert region: keep OURS — `_seat_duration_to_s`, `_seat_liveness_bound_s`, the `# --- why activating is normally LIVE (fleet-ops#83, #993, #1361, #5141) ---` preamble. No duplicated narrative blocks.
   - `_seat_registry_unit_live` body: take OURS wholesale (three-way bound). Only sanctioned 300s remnants: auto-restart branch + ExecMain=0 else-branch, commented #1361/#63. The `[[ "$sub_state" == "start" ]] → 300s` branch must not survive anywhere.
   - tests/seat-lib.test.sh if conflicted: main's side for wedge/prepaid hunks; ours only for the 3-line wiring + `# fleet-ops#5141: ... worker token cannot add a P14 line in ci.yml` comment after the ram-metric-compare line; keep both nested-test lines if main added others.
4. `git add` resolved files; `GIT_EDITOR=true git rebase --continue`.
5. Post-rebase semantic gate (all must pass):
   ```bash
   bash -n lib/seat-lib.sh
   [[ $(grep -c '_seat_liveness_bound_s()' lib/seat-lib.sh) == 1 ]]
   [[ $(grep -c '_seat_duration_to_s()' lib/seat-lib.sh) == 1 ]]
   ! grep -n '\[\[ "$sub_state" == "start" \]\]' lib/seat-lib.sh
   [[ $(grep -c 'PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S:-300' lib/seat-lib.sh) == 3 ]]
   [[ $(grep -c 'fleet-ops#5141' lib/seat-lib.sh) -ge 2 ]]
   git diff --name-only origin/main..HEAD   # exactly the 3 files
   bash tests/seat-registry-liveness.test.sh
   bash tests/fleet-heartbeat-undersaturation.test.sh   # main's delegating consumer rides our helper
   ```
   Any count off → abort and re-derive. Keep the commit message of 47e53982f.

### Phase 2 — prove accept 4(a) fails on current main; all four cases green post-fix
1. Red on main (extracted tree, never the branch): record `main_sha=$(git rev-parse origin/main)`; `git archive origin/main | tar -x -C "$proof"` (mktemp dir); copy tests/seat-registry-liveness.test.sh into it; run; expect exit 1 with `FAIL: (a) activating/start 400s into a 45min TimeoutStartUSec`. Save sha + log excerpt for the PR body. If it does NOT fail on main → STOP, re-inspect main's `_seat_registry_unit_live`.
2. Green post-fix: `bash tests/seat-registry-liveness.test.sh && echo P5141-GREEN` — OK lines for (a) 400s AND 40min live, (b) 50min reaped, (c) 6min ExecMain=0 reaped, (d) auto-restart not live, plus (e)/(f) fallback cases and drift OK.

### Phase 3 — drift guard proven fail-loud, then full named-test sweep
1. Negative-proof: backup systemd/pi-issue@.service; sed TimeoutStartSec=45min → 60min; run liveness test; expect rc!=0 with `fallback 3300s < unit TimeoutStartSec 3600s`; restore backup; `git diff --stat -- systemd/` prints NOTHING; re-run test green.
2. Sweep (each rc=0): tests/seat-registry-liveness.test.sh, tests/fleet-seat-recovery-units.test.sh, tests/pi-issue-run-per-seat-timeout.test.sh, tests/seat-lib.test.sh (must show nested seat-registry-liveness OK lines; if transport gate reds locally retry `PI_SEAT_LIB_CHECK_TRANSPORT=0` as CI does). Any failure → fix on branch (amend single commit), never silence an assertion.

### Phase 4 — scope-guard audit (manager does push/PR/arm)
1. Scope guards: `git diff --name-only origin/main..HEAD` = exactly lib/seat-lib.sh, tests/seat-lib.test.sh, tests/seat-registry-liveness.test.sh; `git diff origin/main..HEAD -- config/ | grep -nE 'target_concurrent|seat_max_concurrent|ram_governor|"cap"'` → empty (CAPS-UNTOUCHED); `git diff origin/main..HEAD --name-only | grep -E 'systemd/|\.timer$|\.service$'` → empty (NO-UNITS); no ~/.config/systemd writes; `git status --porcelain` shows only pre-existing scratch.
2. sgscan: `bin/sgscan --base origin/main` → exit 0 (5 = semgrep absent locally: record, rely on CI; 1/2 blocking).
