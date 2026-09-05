# Verification for issue #957

## Issue
fix(failed-command): 2026-08-26t13-18-31-426z-01a03e38-e602-737c-b399-576dcf48d08e — failed command walked past, never flagged

## Session
- Path: /home/nish/.pi/agent/sessions/--home-nish--/2026-08-26T13-18-31-426Z_01a03e38-e602-737c-b399-576dcf48d08e.jsonl
- mtime: 2026-08-26T13:21:13Z (UTC)
- Failure: python3 -c probe crashed with `KeyError: 'input_domain'` + "Command exited with code 1"
- Worker did not name the failure in user-facing text

## Prevention Mechanisms (All Verified)

### 1. Detector auto-files ticket
- lib/failed-command-flagged.py detects Python tracebacks + exit 1 as real failures
- Already filed this issue (#957) on heartbeat tick

### 2. Tests prove guard fires
- tests/fleet-failed-command-python-traceback.test.sh: 8/8 scenarios pass
  - Live #957 shape: python3 -c KeyError with toolCall-only recovery -> flagged
  - python3 << EOF KeyError with thinking-only recovery -> flagged
  - python3 KeyError with later unrelated prose -> flagged
  - python3 KeyError with later user-facing flag -> clean
  - live #1003 shape: gh --json + python3 KeyError: 'comments' walked past -> flagged
  - worker.md cites fleet-ops#957, fleet-ops#1003 and the live KeyError wordings
  - lib/failed-command-flagged.py docstring cites fleet-ops#957, fleet-ops#1003 and the python traceback family
  - seat-lib.test.sh hosts test

### 3. Observe-to-close wired
- tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh: 8/8 scenarios pass
  - Green tick comments resolved-at on all 6 leftover duplicates (#952, #957, #966, #971, #976, #981)
  - Later tick closes all 6 leftovers
  - Still-dirty slug leaves all 6 open
  - Citation locks for #966, #971 in worker.md, detector docstring, seat-lib.test.sh

### 4. Citation chain (prompt + detector docstring + CI host)
- prompts/worker.md cites fleet-ops#957, fleet-ops#1003 and the live KeyError wordings (scenario 6 of the test)
- lib/failed-command-flagged.py docstring cites fleet-ops#957, fleet-ops#1003 and the python traceback family (scenario 7)
- tests/seat-lib.test.sh nests tests/fleet-failed-command-python-traceback.test.sh (scenario 8)

## Verification Results

```bash
# Detector scan - no finding for aged-out session
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20 --now "2026-08-27T13:35:00Z"
# -> 01a03e38 slug is in skipped_old, not findings
# -> scanned=2091 old=1137 grace=38 findings=60

# Test runs
bash tests/fleet-failed-command-python-traceback.test.sh
# -> OK: all 8 scenarios pass

bash tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh
# -> OK: all 8 scenarios pass

bash tests/seat-lib.test.sh
# -> OK: nested CI host green, python-traceback test wired in

bash tests/fleet-failed-command-flagged.test.sh
# -> OK: rc canary, grep/ls/which/git no-match exemption, auto-file dedupe, closed-dedup reopen, in-flight grace guard, observe-to-close
```

## Session Status
Session mtime (2026-08-26T13:21:13Z) is >24h before verification time (2026-08-27T13:35:00Z).
Detector is clean for this slug. The `resolved-at: signal: failed-command-flagged/2026-08-26t13-18-31-426z-01a03e38-e602-737c-b399-576dcf48d08e` marker was already commented on the issue at 2026-08-27T11:48:08Z (fleet-ops#650 observe-to-close, first tick). The next heartbeat tick (within ~10 minutes of verification) will see the slug as `skipped_old` and the marker as already present, and will close the issue.

## Mechanism Status
mechanism-impossible: all prevention mechanisms already exist and verified — detector auto-files, tests prove guard fires, observe-to-close wired, citation chain locked. The work shipped via PRs #1064 (live #957 shape lock + scenarios 1-4 + prompt-side lock) and #1094 (detector docstring citation lock). The leftover-duplicate drain test for the 01a03e38 pile ships under #966 and #971. No further code change is required; the issue closes via the standard observe-to-close path.

## Cross-references
- #976: sibling issue for the same session signal (verify-PR is PR #1115)
- #952, #966, #971, #981: other leftover duplicates in the 01a03e38 pile (all closed via observe-to-close drain test)

Relates to #957
