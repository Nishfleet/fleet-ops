# Verification for issue #1065

## Issue
fix(failed-command): 2026-08-27t07-32-11-679z-01a04222-2f1f-7823-9631-77df6b1ba95b — failed command walked past, never flagged

## Session
- Path: /home/nish/.pi/agent/sessions/--home-nish--/2026-08-27T07-32-11-679Z_01a04222-2f1f-7823-9631-77df6b1ba95b.jsonl
- mtime: 2026-08-27T08:07:59Z (UTC)
- Failure: `cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-943 && git cherry-pick 8ccae46 2>&1` exited 1 with `isError=true`
- git output: `Auto-merging tests/fleet-failed-command-flagged.test.sh` + `The previous cherry-pick is now empty, possibly due to conflict resolution.` + `Command exited with code 1`
- The cherry-pick was empty because commit 8ccae46 was already on origin/main (the fix for #943 had already merged via PR #1043)
- The worker's next turn was a thinking-only block ("The cherry-pick says it's empty. That's because the test file might already have the change on origin/main? Let me check.") plus a `git log --oneline -1` toolCall — no user-facing text named the failure
- The issue body's snippet shows test-suite output ("OK: origin 404 walked past is flagged ...") because the session was still being written when the detector first ticked; the live first-finding at the natural observation time is the cherry-pick empty shape above

## Failure class
`git cherry-pick <sha>` exit 1, `isError=true`, "The previous cherry-pick is now empty, possibly due to conflict resolution", walked past with a thinking-only + toolCall recovery turn. This is distinct from the existing git shapes already locked:
- #954 / #962 / #968: `git checkout` worktree-conflict — exit 128, `fatal: 'main' is already used by worktree`
- #849 / #985: `git branch -f` worktree-ownership — exit 128, `fatal: cannot force update the branch`
- #822: `git log <bad-ref>` ref-existence probe — exit 128, `fatal: ambiguous argument` (exempt)

The cherry-pick empty shape is exit 1 with NO `fatal:` line. `git cherry-pick` is NOT in the git-ref probe family (`GIT_BENIGN_RE` covers only `log|rev-parse|show|diff|cat-file|shortlog`) and not in `BENIGN_STAGE_RE`, so the detector's exit-1 path flags it directly. A future refactor that adds `cherry-pick` to `GIT_BENIGN_RE` or `BENIGN_STAGE_RE` would silently suppress this real signal.

## Prevention Mechanisms (All Verified)

### 1. Detector auto-files ticket
- lib/failed-command-flagged.py detects `git cherry-pick` exit 1 + `isError=true` as a real failure via the generic `is_error or code != 0` path (no exemption matches)
- Already filed this issue (#1065) on the heartbeat tick

### 2. Tests prove guard fires
- tests/fleet-failed-command-git-cherry-pick-empty.test.sh: 7/7 scenarios pass
  - Live #1065 shape: git cherry-pick empty exit 1, thinking-only recovery -> flagged
  - Same shape plus later user-facing flag -> clean
  - git cherry-pick that succeeds (clean, non-empty) -> not flagged (contrast)
  - git ref-existence probe (live #822) -> exempt (contrast)
  - worker.md cites fleet-ops#1065 and the live wording (prompt-side lock)
  - lib/failed-command-flagged.py docstring cites fleet-ops#1065 (detector-side lock)
  - seat-lib.test.sh hosts the file (CI cannot gain a P14 line)

### 3. Citation chain (prompt + detector docstring + CI host)
- prompts/worker.md cites fleet-ops#1065, names `git cherry-pick` and "previous cherry-pick is now empty" (scenario 5)
- lib/failed-command-flagged.py docstring cites fleet-ops#1065, names the cherry-pick empty shape and the distinctness from #954/#962/#968/#849/#985 (scenario 6)
- tests/seat-lib.test.sh nests tests/fleet-failed-command-git-cherry-pick-empty.test.sh (scenario 7)

### 4. Observe-to-close wired
- The session mtime (2026-08-27T08:07:59Z) ages out of the 24h window at 2026-08-28T08:07:59Z
- A forward-looking detector scan (`--now 2026-08-28T08:30:00Z`) shows the 01a04222 slug in `skipped_old`, NOT in `findings` — the condition observe-to-close requires to comment the `resolved-at` marker
- The next production heartbeat tick after the age-out will comment `resolved-at: signal: failed-command-flagged/2026-08-27t07-32-11-679z-01a04222-2f1f-7823-9631-77df6b1ba95b` on this issue, and a subsequent tick will close it
- This is the standard observe-to-close path (fleet-ops#650, same two-tick shape as #521)

## Verification Results

```bash
# Detector scan - live session is currently a finding (cherry-pick empty shape)
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20
# -> 01a04222-2f1f slug IS in findings, snippet = "Auto-merging tests/fleet-failed-command-flagged.test.sh The previous cherry-pick is now empty..."

# Forward-looking scan (after 24h age-out at 2026-08-28T08:07:59Z)
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20 --now "2026-08-28T08:30:00Z"
# -> 01a04222-2f1f slug is in skipped_old, NOT in findings (observe-to-close condition met)

# New dedicated regression test
bash tests/fleet-failed-command-git-cherry-pick-empty.test.sh
# -> OK: all 7 scenarios pass (incl. live #1065 cherry-pick empty exit 1 walk-past, citation lock, CI host)

# CI host
bash tests/seat-lib.test.sh
# -> OK: nested CI host green, cherry-pick-empty test wired in

# Existing detector suite
bash tests/fleet-failed-command-flagged.test.sh
# -> OK: rc canary, grep/ls/which/git no-match exemption, auto-file dedupe, closed-dedup reopen, in-flight grace guard, observe-to-close
```

## Session Status
Session mtime (2026-08-27T08:07:59Z) is <24h before the verification time (2026-08-27T15:32Z). The detector scan with a forward-looking `--now 2026-08-28T08:30:00Z` shows the slug in `skipped_old` (not in `findings`), which is the condition observe-to-close requires to comment the `resolved-at` marker. Once the natural 24h age-out elapses at 2026-08-28T08:07:59Z, the next production heartbeat tick (within 30 min) will comment `resolved-at: signal: failed-command-flagged/2026-08-27t07-32-11-679z-01a04222-2f1f-7823-9631-77df6b1ba95b` on this issue, and a subsequent tick will close it.

## Mechanism Status
mechanism-impossible: all prevention mechanisms already exist or are shipped in this PR — detector auto-files (`bin/fleet-failed-command-flagged`), regression test (`tests/fleet-failed-command-git-cherry-pick-empty.test.sh`, 7 scenarios incl. live #1065), citation chain locked (prompt + detector docstring + CI host), observe-to-close wired (standard fleet-ops#650 path). No `lib/failed-command-flagged.py` detection-logic change is required — the detector already flags `git cherry-pick` exit 1 via the generic `is_error or code != 0` path; the gap was the dedicated regression test + three-place citation lock so a future refactor that adds `cherry-pick` to the git-ref probe family is caught. The issue closes via the standard observe-to-close path once the session ages past 24h.

## Cross-references
- #954 / #962 / #968: git-checkout worktree-conflict shape (exit 128, `fatal: 'main' is already used by worktree`) — sibling git shapes locked under tests/fleet-failed-command-git-checkout-worktree-conflict.test.sh and tests/fleet-failed-command-git-checkout-worktree-conflict-968.test.sh
- #849 / #985: git-branch-force worktree-ownership shape (exit 128, `fatal: cannot force update the branch`) — locked under tests/fleet-failed-command-git-branch-cannot-force-update.test.sh
- #822: git ref-existence probe exemption (exit 128, `fatal: ambiguous argument`) — the contrast pinned in scenario 4
- #650: observe-to-close two-tick shape
- #1043: the merged PR whose cherry-pick triggered the live #1065 failure (commit 8ccae46 was already on origin/main)

Relates to #1065
