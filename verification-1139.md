# Verification for issue #1139

## Issue
fix(failed-command): 2026-08-27t12-01-49-555z-01a04319-09f3-7bed-ae2e-447e2307d778 — failed command walked past, never flagged

## Session
- Path: /home/nish/.pi/agent/sessions/--home-nish--/2026-08-27T12-01-49-555Z_01a04319-09f3-7bed-ae2e-447e2307d778.jsonl
- mtime: 2026-08-27T12:07:45Z (UTC)
- Failure: `edit` tool returned `isError=true` with `No changes made to /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1001/prompts/worker.md. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected.` (details={}, no `Command exited with code` line)
- The worker was editing `prompts/worker.md` in the issue-fleet-ops-1001 worktree. `newText` already equalled the file text, so the intended change never landed.
- The next turn was cause-explaining prose ("The text is already the same. Let me check what's actually there:") plus a grep, then another grep, then four empty assistant turns. Cause prose names WHY the file was unchanged, never that the call failed.
- Worker did not name the failure in user-facing text

## Failure class
`edit` tool result with `No changes made to <path>. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected.` (`isError=true`, `details={}`, no `Command exited with code` line), walked past with cause-explaining prose plus silent `grep` recovery. This is the third sibling of the edit-unmatch family already locked under `tests/fleet-failed-command-edit-unmatch.test.sh`:

- 0 matches -> `Could not find the exact text` (#956, #965)
- N matches -> `Found N occurrences` (#1053)
- matched, but no-op -> `produced identical content` (#1139, this one)

The no-op shape is the one most likely to be waved through as a benign "nothing broke". It is not: the worker asked for an edit and the edit did not happen.

## Prevention Mechanisms (All Verified)

### 1. Detector auto-files ticket
- lib/failed-command-flagged.py detects `edit` `isError=true` with the "produced identical content" message as a real swallowed failure (no exemption — the `edit` tool is NOT in the `read` "Offset N is beyond end of file" exemption family)
- Already filed this issue (#1139) on the heartbeat tick

### 2. Tests prove guard fires
- tests/fleet-failed-command-edit-unmatch.test.sh scenarios 10-14 (shipped in PR #1226):
  - Live #1139 shape: no-op edit + cause-explaining prose + grep probes + empty turns -> flagged
  - same shape with only a silent grep recovery -> flagged (anti-exemption lock)
  - same shape plus a later "the edit call failed" user-facing flag -> clean
  - worker.md must cite fleet-ops#1139, the no-op wording, and the cause-prose
  - lib/failed-command-flagged.py must cite fleet-ops#1139 and the no-op wording

### 3. Citation chain (prompt + detector docstring + CI host)
- prompts/worker.md cites fleet-ops#1139, the live `No changes made ... produced identical content` wording, and that "The text is already the same" is a cause, not a flag
- lib/failed-command-flagged.py docstring and the `result_failed()` no-exemption note cite fleet-ops#1139
- tests/seat-lib.test.sh nests tests/fleet-failed-command-edit-unmatch.test.sh (line 2131)

### 4. Observe-to-close wired
- The session mtime (2026-08-27T12:07:45Z) ages out of the 24h window at 2026-08-28T12:07:45Z
- A forward-looking detector scan (`--now 2026-08-28T12:30:00Z`) shows the 01a04319 slug in `skipped_old`, NOT in `findings` — the condition observe-to-close requires to comment the `resolved-at` marker
- The next production heartbeat tick after the age-out will comment `resolved-at: signal: failed-command-flagged/2026-08-27t12-01-49-555z-01a04319-09f3-7bed-ae2e-447e2307d778` on this issue, and a subsequent tick will close it
- This is the standard observe-to-close path (fleet-ops#650, same two-tick shape as #521, #957, #1051, #1065)

## Verification Results

```bash
# Detector scan - live session is currently a finding (edit no-op shape)
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20
# -> 01a04319 slug IS in findings, snippet = "No changes made to /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1001/prompts/worker.md. The replacement produced identical content. This might indicate an issue with special characters or the"
# -> scanned=2150 old=1382 grace=133 findings=91

# Forward-looking scan (after 24h age-out at 2026-08-28T12:07:45Z)
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20 --now "2026-08-28T12:30:00Z"
# -> 01a04319 slug is in skipped_old, NOT in findings (observe-to-close condition met)
# -> scanned=520 old=3146 grace=0 findings=48

# Edit-unmatch regression test (locks the class, including #1139 scenarios 10-14)
bash tests/fleet-failed-command-edit-unmatch.test.sh
# -> OK: live #1139: no-op edit with cause-explaining prose recovery is flagged
# -> OK: #1139: no-op edit is not a benign probe — silent recovery still flagged
# -> OK: #1139: no-op edit plus later user-facing flag is clean
# -> OK: worker.md cites fleet-ops#1139, the no-op wording, and the cause-prose
# -> OK: lib/failed-command-flagged.py cites fleet-ops#1139 and the no-op wording
# -> OK: fleet-failed-command-edit-unmatch: live #956/#1079/#1053/#1139 edit unmatch drills

# Main detector suite
bash tests/fleet-failed-command-flagged.test.sh
# -> OK: rc canary, grep/ls/which/git no-match exemption, auto-file dedupe, closed-dedup reopen, in-flight grace guard, observe-to-close
```

## Session Status
Session mtime (2026-08-27T12:07:45Z) is <24h before the verification time (2026-08-27T18:25:42Z). The detector scan with a forward-looking `--now 2026-08-28T12:30:00Z` shows the slug in `skipped_old` (not in `findings`), which is the condition observe-to-close requires to comment the `resolved-at` marker. Once the natural 24h age-out elapses at 2026-08-28T12:07:45Z, the next production heartbeat tick (within 30 min) will comment `resolved-at: signal: failed-command-flagged/2026-08-27t12-01-49-555z-01a04319-09f3-7bed-ae2e-447e2307d778` on this issue, and a subsequent tick will close it.

## Mechanism Status
mechanism-impossible: all prevention mechanisms already exist and are verified — detector auto-files (`bin/fleet-failed-command-flagged`), regression test (`tests/fleet-failed-command-edit-unmatch.test.sh`, scenarios 10-14 for the live #1139 no-op edit walk-past), citation chain locked (prompt + detector docstring + CI host), observe-to-close wired (standard fleet-ops#650 path). The lock shipped in PR #1226. No `lib/failed-command-flagged.py` detection-logic change is required — the detector already flags `edit` `isError=true` with the "produced identical content" message via the generic `is_error` path with no exemption. The issue closes via the standard observe-to-close path once the session ages past 24h.

## Cross-references
- #956 / #965 / #1053: the other two siblings of the edit-unmatch family (0-match and N-match). The class lock lives in tests/fleet-failed-command-edit-unmatch.test.sh
- #1226: the lock PR that added scenarios 10-14, the prompt citation, and the detector no-exemption note
- #650: observe-to-close two-tick shape
- #1051 / #957 / #1065: sibling verify PRs for already-locked classes

Relates to #1139
