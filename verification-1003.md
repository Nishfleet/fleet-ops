# Verification for issue #1003

## Issue
fix(failed-command): 2026-08-27t05-16-15-343z-01a041a5-ba6f-771c-9de4-d9ddaa6a54b0 — failed command walked past, never flagged

## Session
- Path: /home/nish/.pi/agent/sessions/--home-nish--/2026-08-27T05-16-15-343Z_01a041a5-ba6f-771c-9de4-d9ddaa6a54b0.jsonl
- mtime: 2026-08-27T05:28:30Z (UTC)
- Failure: `gh issue view 844 --comments --json author,body,createdAt | python3 -c ... d['comments']` crashed with `KeyError: 'comments'` + "Command exited with code 1"
- The `--json` filter omitted the `comments` field, the python probe indexed `d['comments']` on the issue object, and the worker walked past it with a toolCall-only re-probe
- Worker did not name the failure in user-facing text

## Prevention Mechanisms (All Verified)

### 1. Detector auto-files ticket
- lib/failed-command-flagged.py detects python tracebacks (`KeyError`, `NameError`, `ModuleNotFoundError`, etc.) + exit 1 as real failures
- The live `KeyError: 'comments'` wording is in the same family as `KeyError: 'input_domain'` (live #957), but the `gh issue view --json | python3 -c d['comments']` pipe is a distinct shape; the detector treats both as walked-past failures
- Already filed this issue (#1003) on heartbeat tick

### 2. Tests prove guard fires
- tests/fleet-failed-command-python-traceback.test.sh: 8/8 scenarios pass
  - Live #957 shape: python3 -c KeyError with toolCall-only recovery -> flagged
  - python3 << EOF KeyError with thinking-only recovery -> flagged
  - python3 KeyError with later unrelated prose -> flagged
  - python3 KeyError with later user-facing flag -> clean
  - **live #1003 shape**: gh --json + python3 KeyError: 'comments' walked past -> flagged
  - worker.md cites fleet-ops#957, fleet-ops#1003 and the live KeyError wordings
  - lib/failed-command-flagged.py docstring cites fleet-ops#957, fleet-ops#1003 and the python traceback family
  - seat-lib.test.sh hosts test

### 3. Observe-to-close wired
- tests/fleet-failed-command-observe-duplicate-1003.test.sh: 7/7 scenarios pass
  - Green tick comments resolved-at on both leftover duplicates (#1003, #1019), not first-only
  - Later tick closes both leftover duplicates
  - Still-dirty slug leaves both leftover duplicates open
  - worker.md cites #1003, #1019, and names the leftover-duplicate test file
  - lib/failed-command-flagged.py docstring cites #1003 / #1019 and names the leftover-duplicate test file
  - seat-lib.test.sh hosts the file
- The 01a041a5 leftover-duplicate drain is a 2-issue pile (sibling of the 6-issue 01a03e38 pile locked under tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh, the 5-issue 01a03dee pile locked under tests/fleet-failed-command-observe-duplicate-open.test.sh, the 6-issue 01a03e61 pile locked under tests/fleet-failed-command-observe-duplicate-enoent.test.sh, and the 2-issue 01a04105 pile locked under tests/fleet-failed-command-observe-duplicate-git-branch-force.test.sh)

### 4. Citation chain (prompt + detector docstring + CI host)
- prompts/worker.md cites fleet-ops#957, fleet-ops#1003 and the live KeyError wordings (scenario 6 of tests/fleet-failed-command-python-traceback.test.sh)
- lib/failed-command-flagged.py docstring cites fleet-ops#957, fleet-ops#1003 and the python traceback family (scenario 7)
- tests/seat-lib.test.sh nests tests/fleet-failed-command-python-traceback.test.sh (scenario 8)
- Same three-place citation lock for the leftover-duplicate drain (worker.md, detector docstring, seat-lib.test.sh host)

## Verification Results

```bash
# Detector scan - no finding for aged-out session (forward-looking at 2026-08-28T05:30:00Z)
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20 --now "2026-08-28T05:30:00Z"
# -> 01a041a5-ba6f slug is in skipped_old, NOT in findings
# -> scanned=661 old=2649 grace=0 findings=38

# Same scan, now (the slug is still in findings because session is 8.85h old, <24h)
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20 --now "2026-08-27T14:20:00Z"
# -> 01a041a5-ba6f slug IS in findings, IS the 01a041a5 sibling (sibling slug 01a041a5-63db is also in findings; both age out together)
# -> scanned=2143 old=1139 grace=23 findings=62

# Test runs
bash tests/fleet-failed-command-python-traceback.test.sh
# -> OK: all 8 scenarios pass (incl. live #1003 gh --json + python3 KeyError: 'comments' walk-past)

bash tests/fleet-failed-command-observe-duplicate-1003.test.sh
# -> OK: all 7 scenarios pass (green tick comments resolved-at on both leftover duplicates, later tick closes both)

bash tests/seat-lib.test.sh
# -> OK: nested CI host green, python-traceback test wired in, observe-duplicate-1003 test wired in

bash tests/fleet-failed-command-flagged.test.sh
# -> OK: rc canary, grep/ls/which/git no-match exemption, auto-file dedupe, closed-dedup reopen, in-flight grace guard, observe-to-close
```

## Session Status
Session mtime (2026-08-27T05:28:30Z) is <24h before current time (2026-08-27T14:20:00Z, verification time). The detector scan with a forward-looking `--now 2026-08-28T05:30:00Z` shows the slug in `skipped_old` (not in `findings`), which is the condition observe-to-close requires to comment the `resolved-at` marker. Once the natural 24h age-out elapses at 2026-08-28T05:28:30Z, the next production heartbeat tick (within 30 min) will comment `resolved-at: signal: failed-command-flagged/2026-08-27t05-16-15-343z-01a041a5-ba6f-771c-9de4-d9ddaa6a54b0` on this issue and the sibling #1019, and a subsequent tick will close both.

The 01a041a5 sibling session `01a041a5-63db-7998-8039-bd1c99d95db6` is a separate signal slug and a separate issue; it will close on its own observe-to-close path.

## Mechanism Status
mechanism-impossible: all prevention mechanisms already exist and verified — detector auto-files (`bin/fleet-failed-command-flagged`), regression test (`tests/fleet-failed-command-python-traceback.test.sh`, 8 scenarios incl. live #1003), citation chain locked (prompt + detector docstring + CI host), observe-to-close wired (`tests/fleet-failed-command-observe-duplicate-1003.test.sh`, 7 scenarios for the 01a041a5 leftover-duplicate pile). The work shipped via PR #1125 (mechanism) and PR #1129 (sibling verify pattern for the 01a03e38 pile). No new code change is required; the issue closes via the standard observe-to-close path once the session ages past 24h.

## Cross-references
- #957: original python3 KeyError/Traceback walked-past class (verify-PR is #1129, mechanism via #1064 + #1094)
- #966, #971: 01a03e38 leftover-duplicate siblings (drain test under tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh)
- #1019: sibling issue for the same 01a041a5 session signal (search-index delay, fleet-ops#951)
- #976, #981: 01a03e38 sibling verify-PRs (#1115 for #976, drain test covers #981)

Relates to #1003
