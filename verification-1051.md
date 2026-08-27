# Verification for issue #1051

## Issue
fix(failed-command): 2026-08-27t06-15-38-145z-01a041dc-17a1-729a-a9ec-9ab5649f8bea — failed command walked past, never flagged

## Session
- Path: /home/nish/.pi/agent/sessions/--home-nish--/2026-08-27T06-15-38-145Z_01a041dc-17a1-729a-a9ec-9ab5649f8bea.jsonl
- mtime: 2026-08-27T12:20:07Z (UTC)
- Failure: `edit` tool returned `isError=true` with `Could not find the exact text in /home/nish/workspaces/agent-worktrees/issue-fleet-ops-952/tests/fleet-failed-command-flagged.test.sh. The old text must match exactly including all whitespace and newlines.` (details={}, no `Command exited with code` line)
- The worker was editing `tests/fleet-failed-command-flagged.test.sh` in the issue-fleet-ops-952 worktree with a stale `oldText` (referencing a `6i. live #953` section that did not match the file's current content)
- The worker's next turns were `thinking` blocks ("The edit failed because the exact text didn't match. Let me read the exact content around line 720...") plus `read` toolCalls to find the right text — no user-facing text named the failure
- Later user-facing prose (line 75: "All tests pass including the new test case", line 83: "Now let me commit and push the change") moved on without naming the edit failure
- Worker did not name the failure in user-facing text

## Failure class
`edit` tool result with `Could not find the exact text in <path>. The old text must match exactly including all whitespace and newlines.` (`isError=true`, `details={}`, no `Command exited with code` line), walked past with a `thinking` + `read` recovery turn. This is the SAME class as fleet-ops#956 / #965 (the 01a03dee edit-unmatch session), already locked under `tests/fleet-failed-command-edit-unmatch.test.sh`. The 01a041dc session is a fresh occurrence of that class on a different file path (`tests/fleet-failed-command-flagged.test.sh` in the issue-fleet-ops-952 worktree, vs `discover_v2.py` in the 01a03dee session). The shape is identical: stale `oldText` -> edit `isError=true` exact-text message -> silent `read`/`thinking` recovery -> later unrelated prose that moves on.

## Prevention Mechanisms (All Verified)

### 1. Detector auto-files ticket
- lib/failed-command-flagged.py detects `edit` `isError=true` with the "Could not find the exact text" message as a real swallowed failure (no exemption — the `edit` tool is NOT in the `read` "Offset N is beyond end of file" exemption family)
- Already filed this issue (#1051) on the heartbeat tick

### 2. Tests prove guard fires
- tests/fleet-failed-command-edit-unmatch.test.sh: 4/4 scenarios pass
  - Live #956 shape: edit unmatch + silent read/grep recovery -> flagged
  - edit unmatch with later thinking-only recovery -> still flagged
  - edit unmatch with later unrelated user-facing prose -> still flagged (this is the 01a041dc shape: line 75 "All tests pass..." moves on without naming the failure)
  - edit unmatch plus a later user-facing flag -> clean

### 3. Citation chain (prompt + detector docstring + CI host)
- prompts/worker.md cites fleet-ops#956, fleet-ops#965 and the live `edit` "Could not find the exact text" wording
- lib/failed-command-flagged.py docstring cites fleet-ops#956, #965, #970, #975, #980 (the 01a03dee edit-unmatch pile) and pins that NO exemption is added for the `edit` exact-text shape
- tests/seat-lib.test.sh nests tests/fleet-failed-command-edit-unmatch.test.sh (line 1850)

### 4. Observe-to-close wired
- The session mtime (2026-08-27T12:20:07Z) ages out of the 24h window at 2026-08-28T12:20:07Z
- A forward-looking detector scan (`--now 2026-08-28T12:45:00Z`) shows the 01a041dc slug in `skipped_old`, NOT in `findings` — the condition observe-to-close requires to comment the `resolved-at` marker
- The next production heartbeat tick after the age-out will comment `resolved-at: signal: failed-command-flagged/2026-08-27t06-15-38-145z-01a041dc-17a1-729a-a9ec-9ab5649f8bea` on this issue, and a subsequent tick will close it
- This is the standard observe-to-close path (fleet-ops#650, same two-tick shape as #521, #957, #1065)

## Verification Results

```bash
# Detector scan - live session is currently a finding (edit-unmatch shape)
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20
# -> 01a041dc-17a1 slug IS in findings, snippet = "Could not find the exact text in /home/nish/workspaces/agent-worktrees/issue-fleet-ops-952/tests/fleet-failed-command-flagged.test.sh..."
# -> scanned=2118 old=1241 grace=0 findings=69

# Forward-looking scan (after 24h age-out at 2026-08-28T12:20:07Z)
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20 --now "2026-08-28T12:45:00Z"
# -> 01a041dc-17a1 slug is in skipped_old, NOT in findings (observe-to-close condition met)
# -> scanned=208 old=3174 grace=0 findings=19

# Edit-unmatch regression test (locks the class)
bash tests/fleet-failed-command-edit-unmatch.test.sh
# -> OK: all 4 scenarios pass (incl. live #956 edit 'Could not find the exact text' walk-past, thinking-only recovery, unrelated-prose, flagged-is-clean)

# Main detector suite
bash tests/fleet-failed-command-flagged.test.sh
# -> OK: rc canary, grep/ls/which/git no-match exemption, auto-file dedupe, closed-dedup reopen, in-flight grace guard, observe-to-close
```

Note on `tests/seat-lib.test.sh`: the CI host currently exits 1 at the `ram-metric-compare` test (line 1723) with `FAIL: ram_gb_per_worker must be 1.5 (got 0.6)` — a PRE-EXISTING fault on origin/main where scenario 4 of `tests/ram-metric-compare.test.sh` still expects 1.5 after PR #1168 right-sized the value to 0.6. That fault is unrelated to this issue and is filed separately. The `fleet-failed-command-edit-unmatch` host line (seat-lib.test.sh line 1850) sits after the failing `ram-metric-compare` host (line 1723); under `set -e` the script aborts before reaching it. The edit-unmatch test itself passes when run directly (above), and the host wiring is present at line 1850.

## Session Status
Session mtime (2026-08-27T12:20:07Z) is <24h before the verification time (2026-08-27T15:56Z). The detector scan with a forward-looking `--now 2026-08-28T12:45:00Z` shows the slug in `skipped_old` (not in `findings`), which is the condition observe-to-close requires to comment the `resolved-at` marker. Once the natural 24h age-out elapses at 2026-08-28T12:20:07Z, the next production heartbeat tick (within 30 min) will comment `resolved-at: signal: failed-command-flagged/2026-08-27t06-15-38-145z-01a041dc-17a1-729a-a9ec-9ab5649f8bea` on this issue, and a subsequent tick will close it.

## Mechanism Status
mechanism-impossible: all prevention mechanisms already exist and are verified — detector auto-files (`bin/fleet-failed-command-flagged`), regression test (`tests/fleet-failed-command-edit-unmatch.test.sh`, 4 scenarios incl. the live #956 edit-unmatch walk-past shape that covers this session), citation chain locked (prompt + detector docstring + CI host), observe-to-close wired (standard fleet-ops#650 path). No `lib/failed-command-flagged.py` detection-logic change is required — the detector already flags `edit` `isError=true` with the "Could not find the exact text" message via the generic `is_error` path with no exemption. The 01a041dc session is a fresh occurrence of the class already locked under #956 / #965 (the 01a03dee edit-unmatch pile). The issue closes via the standard observe-to-close path once the session ages past 24h.

## Cross-references
- #956 / #965 / #970 / #975 / #980: the 01a03dee edit-unmatch pile — the class lock lives in tests/fleet-failed-command-edit-unmatch.test.sh (shape) and tests/fleet-failed-command-observe-duplicate-open.test.sh (leftover-duplicate drain)
- #650: observe-to-close two-tick shape
- #957 / #1065: sibling verify PRs for already-locked classes (python-traceback, cherry-pick empty)

Relates to #1051
