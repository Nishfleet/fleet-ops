# Verification for issue #1061

## Issue
fix(failed-command): 2026-08-27t07-31-43-359z-01a04221-c07f-7cf5-9a57-c466ca62454b — failed command walked past, never flagged

## Session
- Path: /home/nish/.pi/agent/sessions/--home-nish--/2026-08-27T07-31-43-359Z_01a04221-c07f-7cf5-9a57-c466ca62454b.jsonl
- mtime: 2026-08-27T13:14Z (UTC)
- Failure: the compound bash chain
  `systemctl show restic-r2-backup.timer --property=NextElapseUSec,LastTriggerUSec,ActiveState 2>/dev/null; echo "===="; ls /var/cache/restic-live/.backup-artifact 2>&1; stat -c '%y %s' /var/cache/restic-live/.backup-artifact 2>/dev/null`
  exited 1 with `isError=true`
- toolResult text:
  ```
  LastTriggerUSec=Thu 2026-08-27 04:39:10 IST
  ActiveState=active
  ====
  ls: cannot access '/var/cache/restic-live/.backup-artifact': Permission denied

  Command exited with code 1
  ```
- `systemctl show` and `echo "===="` succeeded (their stdout is in the toolResult); `ls` failed with `Permission denied` (visible because ls uses `2>&1`); `stat` (the LAST command in the chain) failed with Permission-denied stderr silenced by `2>/dev/null` — so bash exits 1 (stat's exit code), not 2 (ls's exit code)
- The worker's next turn was a thinking-only block ("The timer ran at 04:39:10 and the artifact is owned by root. Let me try a different probe.") plus a `ls /var/cache/restic-live/ 2>&1 | head` recovery toolCall — no user-facing text named the failure

## Failure class
A compound bash chain (`;`-separated) where earlier commands succeed and a downstream `ls <path>` fails with `ls: cannot access '<path>': Permission denied` AND the chain's last command is silenced (`2>/dev/null`), so bash exits 1 (not 2) and the visible `Permission denied` line keeps the toolResult as a real failure. The worker walks past the failure with a thinking-only next turn plus a recovery toolCall (no user-facing text naming the failure). This is distinct from the existing ls / git shapes already locked:

- #794 / 4b-perm: single-command `ls -l /etc/shadow` exit 2 alone (no compound chain, no silenced tail)
- #794 / 4b-canonical: `ls <nonexistent>` exit 2 with the canonical `No such file or directory` line — exempt (live #794 exemption)
- #822: `git log <bad-ref>` ref-existence probe — exit 128, `fatal: ambiguous argument` (exempt)
- #784: `systemctl --user status` exit 3 (different command, different exit code)
- #954 / #962 / #968: `git checkout` worktree-conflict — exit 128, `fatal: 'main' is already used by worktree`
- #849 / #985: `git branch -f` worktree-ownership — exit 128, `fatal: cannot force update the branch`
- #1065: `git cherry-pick` empty commit — exit 1, NO `fatal:` line, distinct from the compound-chain shape (no ls, no Permission denied)

The compound-chain shape is exit 1 (silenced tail) with a visible `ls: cannot access '<path>': Permission denied` line. `ls` is in `LS_BENIGN_RE` but the exemption only applies for `code == 2` (canonical no-match). `Permission denied` is in `REAL_ERR_RE`, which short-circuits the no-match exemption. `BENIGN_STAGE_RE` covers only grep/rg/diff/which — `ls` is not in it. So the exit-1 path flags the failure directly via the generic `is_error or code != 0` branch. A future refactor that broadens `LS_BENIGN_RE` to `code == 1`, drops `Permission denied` from `REAL_ERR_RE`, or stops walking past compound-chain failures would silently suppress this real signal.

## Prevention Mechanisms (all verified)

### 1. Detector auto-files ticket
- `lib/failed-command-flagged.py` detects the compound-chain `ls` Permission-denied + silenced-tail shape via the generic `is_error or code != 0` path (no exemption matches: `LS_BENIGN_RE` requires code==2, `BENIGN_STAGE_RE` does not cover `ls`, `REAL_ERR_RE` matches `Permission denied`)
- Already filed this issue (#1061) on the heartbeat tick

### 2. Tests prove guard fires
- `tests/fleet-failed-command-compound-ls-permission-denied.test.sh`: 7/7 scenarios pass
  - Live #1061 shape: compound bash chain with `ls` Permission denied + silenced stat tail exit 1, thinking-only + toolCall recovery -> flagged
  - Same shape plus later user-facing flag -> clean
  - Cross-check: single-command `ls -l /etc/shadow` exit 2 (live #794 / 4b-perm contrast) -> flagged
  - Cross-check: `ls <nonexistent>` exit 2 canonical no-match probe (live #794 exemption) -> not flagged
  - worker.md cites fleet-ops#1061 and the live compound-ls Permission-denied wording (prompt-side lock)
  - lib/failed-command-flagged.py docstring cites fleet-ops#1061 (detector-side lock)
  - seat-lib.test.sh nests the file (CI cannot gain a P14 line)

### 3. Citation chain (prompt + detector docstring + CI host)
- `prompts/worker.md` cites fleet-ops#1061, names the compound bash chain shape, the `ls: cannot access '<path>': Permission denied` line, and the silenced-tail exit-1 detail (scenario 5)
- `lib/failed-command-flagged.py` docstring cites fleet-ops#1061, names the compound-chain shape and the distinctness from #794 / #822 / #954 / #962 / #968 / #849 / #985 / #1065 (scenario 6)
- `tests/seat-lib.test.sh` nests `tests/fleet-failed-command-compound-ls-permission-denied.test.sh` (scenario 7)

### 4. Observe-to-close wired
- The session mtime (2026-08-27T13:14Z) ages out of the 24h window at 2026-08-28T13:14Z
- A forward-looking detector scan (`--now 2026-08-28T13:30:00Z`) shows the 01a04221 slug in `skipped_old`, NOT in `findings` — the condition observe-to-close requires to comment the `resolved-at` marker
- The next production heartbeat tick after the age-out will comment `resolved-at: signal: failed-command-flagged/2026-08-27t07-31-43-359z-01a04221-c07f-7cf5-9a57-c466ca62454b` on this issue, and a subsequent tick will close it
- This is the standard observe-to-close path (fleet-ops#650, same two-tick shape as #521)

## Verification Results

```bash
# Detector scan - live session is currently a finding (compound-chain ls Permission denied)
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20
# -> 01a04221-c07f slug IS in findings, snippet = "LastTriggerUSec=Thu 2026-08-27 04:39:10 IST ActiveState=active ==== ls: cannot access '/var/cache/restic-live/.backup-artifact': Permission denied   Command exited with code 1"

# Forward-looking scan (after 24h age-out at 2026-08-28T13:14Z)
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20 --now "2026-08-28T13:30:00Z"
# -> 01a04221-c07f slug is in skipped_old, NOT in findings (observe-to-close condition met)

# New dedicated regression test
bash tests/fleet-failed-command-compound-ls-permission-denied.test.sh
# -> OK: all 7 scenarios pass (incl. live #1061 compound-chain ls Permission denied walk-past, citation lock, CI host)

# CI host (the new file is nested)
bash tests/seat-lib.test.sh
# -> OK: nested CI host green, compound-ls-permission-denied test wired in

# Existing detector suite (no regression)
bash tests/fleet-failed-command-flagged.test.sh
# -> OK: rc canary, grep/ls/which/git no-match exemption, auto-file dedupe, closed-dedup reopen, in-flight grace guard, observe-to-close

# Existing ls / systemctl shapes (no regression)
bash tests/fleet-failed-command-systemctl-status-failed.test.sh
# -> OK: live #784 status-failed + flag drill
```

## Session Status
Session mtime (2026-08-27T13:14Z) is <24h before the verification time (2026-08-27T15:47Z). The detector scan with a forward-looking `--now 2026-08-28T13:30:00Z` shows the slug in `skipped_old` (not in `findings`), which is the condition observe-to-close requires to comment the `resolved-at` marker. Once the natural 24h age-out elapses at 2026-08-28T13:14Z, the next production heartbeat tick (within 30 min) will comment `resolved-at: signal: failed-command-flagged/2026-08-27t07-31-43-359z-01a04221-c07f-7cf5-9a57-c466ca62454b` on this issue, and a subsequent tick will close it.

## Mechanism Status
mechanism-impossible: all prevention mechanisms already exist or are shipped in this PR — detector auto-files (`bin/fleet-failed-command-flagged`), regression test (`tests/fleet-failed-command-compound-ls-permission-denied.test.sh`, 7 scenarios incl. live #1061), citation chain locked (prompt + detector docstring + CI host), observe-to-close wired (standard fleet-ops#650 path). No `lib/failed-command-flagged.py` detection-logic change is required — the detector already flags the compound-chain `ls` Permission-denied + silenced-tail exit-1 shape via the generic `is_error or code != 0` path (REAL_ERR_RE matches `Permission denied`); the gap was the dedicated regression test + three-place citation lock so a future refactor that broadens the ls exemption, drops `Permission denied` from REAL_ERR_RE, or stops walking past compound-chain failures is caught. The issue closes via the standard observe-to-close path once the session ages past 24h.

## Cross-references
- #794 / 4b-perm: single-command `ls -l /etc/shadow` exit 2 (no compound chain) — sibling ls shape locked under `tests/fleet-failed-command-flagged.test.sh`
- #794 / 4b-canonical: `ls <nonexistent>` exit 2 canonical no-match probe — the exemption pinned in scenario 4
- #822: `git log <bad-ref>` ref-existence probe exemption — distinct family, not in the same scenario
- #784: `systemctl --user status` exit 3 — distinct command / exit code, locked under `tests/fleet-failed-command-systemctl-status-failed.test.sh`
- #954 / #962 / #968: git-checkout worktree-conflict shape (exit 128, `fatal: 'main' is already used by worktree`)
- #849 / #985: git-branch-force worktree-ownership shape (exit 128, `fatal: cannot force update the branch`)
- #1065: git-cherry-pick empty commit shape (exit 1, NO `fatal:` line, NO ls Permission denied) — sibling exit-1 shape locked under `tests/fleet-failed-command-git-cherry-pick-empty.test.sh`
- #650: observe-to-close two-tick shape

Relates to #1061