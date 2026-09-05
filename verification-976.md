# Verification for issue #976

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
- Already filed this issue (#976) on heartbeat tick

### 2. Tests prove guard fires
- tests/fleet-failed-command-python-traceback.test.sh: 7/7 scenarios pass
  - Live #957 shape: python3 -c KeyError with toolCall-only recovery → flagged
  - python3 << EOF KeyError with thinking-only recovery → flagged
  - python3 KeyError with later unrelated prose → flagged
  - python3 KeyError with later user-facing flag → clean
  - worker.md cites fleet-ops#957
  - lib/failed-command-flagged.py docstring cites fleet-ops#957
  - seat-lib.test.sh hosts test

### 3. Observe-to-close wired
- tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh: 8/8 scenarios pass
  - Green tick comments resolved-at on all 6 leftover duplicates (#952, #957, #966, #971, #976, #981)
  - Later tick closes all 6 leftovers
  - Still-dirty slug leaves all 6 open
  - Citation locks for #966, #971 in worker.md, detector docstring, seat-lib.test.sh

## Verification Results

```bash
# Detector scan - no finding for aged-out session
python3 lib/failed-command-flagged.py scan --root ~/.pi/agent/sessions --window-hours 24 --grace-minutes 20 --now "2026-08-27T17:30:00Z"
# → No finding for slug 2026-08-26t13-18-31-426z-01a03e38-e602-737c-b399-576dcf48d08e

# Test runs
bash tests/fleet-failed-command-python-traceback.test.sh
# → OK: all 7 scenarios pass

bash tests/fleet-failed-command-observe-duplicate-python-traceback.test.sh
# → OK: all 8 scenarios pass

bash tests/seat-lib.test.sh
# → All tests pass
```

## Session Status
Session mtime (2026-08-26T13:21:13Z) is >24h before verification time (2026-08-27T17:30:00Z).
Detector is clean for this slug. Observe-to-close will comment `resolved-at` on next heartbeat tick and close on the following tick.

## Mechanism Status
mechanism-impossible: all prevention mechanisms already exist and verified — detector auto-files, tests prove guard fires, observe-to-close wired

Relates to #976
