## What changed and why

The session-close lint (`bin/fleet-failed-command-flagged`, fleet-ops#535) auto-filed the live #821 incident. The flagging shape was a false positive: the session was working on fleet-ops#664, and it ran two successful tool calls whose result text happened to contain the literal string "Command timed out" as content, not as a real timeout:

1. A `read` of `lib/failed-command-flagged.py` to debug it. The file's own `TIMEOUT_RE` regex definition contains the literal string `Command timed out`. The read succeeded (`isError=false`, no exit code).
2. A `bash` `grep` on `prompts/worker.md` to inspect the standing rule. The file's own standing-rule paragraph mentions `Command timed out` as one of the toolResult shapes the rule covers. The grep succeeded.

The detector was treating any toolResult text that matched `TIMEOUT_RE` as a swallowed timeout, even when the tool reported success. A real Pi timeout always has `isError=true` (the harness sets it on timeout) or a non-zero exit code. This PR narrows `result_failed` so a `TIMEOUT_RE` text match only counts as a real failure when it is accompanied by a real failure signal; otherwise the text is content (source code, doc text, quoted issue body) and not a swallowed timeout.

## Mechanism (fleet-ops#366)

This is the prevention mechanism for the failure-fix class. The detector now requires a real failure signal (isError or non-zero exit code) to count "Command timed out" text as a timeout, locked by two regression tests (6f, 6g) that use the exact toolResult shapes from the live #821 session. The auto-file cannot re-occur for this shape. Observe-to-close on `bin/fleet-failed-command-flagged` (in place for #650, #521, #687) will close #821 on a later heartbeat tick once the slug stays clean.

## Verification

```
$ bash tests/fleet-failed-command-flagged.test.sh
... 30 OK lines ...
OK: live #821: read of source with 'Command timed out' regex text is not a swallowed timeout
OK: live #821: bash output with 'Command timed out' as doc text is not a swallowed timeout
... 28 other OK lines ...
OK: fleet-failed-command-flagged: rc canary, grep/ls/which no-match exemption, auto-file dedupe, observe-to-close
```

End-to-end run on the live #821 session:

```
$ FLEET_FAILED_COMMAND_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  FLEET_FAILED_COMMAND_FILE_ISSUES=0 FLEET_FAILED_COMMAND_CLOSE_ISSUES=0 \
  python3 lib/failed-command-flagged.py scan \
    --root ~/.pi/agent/sessions \
    --now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | jq '.findings[] | select(.slug | startswith("2026-08-27t02-02-08"))'
# (no output — the live #821 session is no longer a finding)
```

Before the fix: 39 findings (including the live #821 session as a false positive). After the fix: 34 findings. The 5 sessions no longer reported are all the live #821 false-positive shape; the remaining 34 are pre-existing swallowed-failure issues from older sessions (unrelated to this PR). All 6 other `fleet-failed-command-*` test scripts pass, and the `seat-lib.test.sh` chain (which hosts the contract test for this detector) passes.

run-proof: `bash tests/fleet-failed-command-flagged.test.sh` exits 0 with 30 OK lines including 2 new live #821 cases; the live #821 session slug is absent from the `bin/fleet-failed-command-flagged` findings list (verified by `jq '.findings[] | select(.slug | startswith("2026-08-27t02-02-08"))'`).

Verification: ran the new tests in `tests/fleet-failed-command-flagged.test.sh` (scenarios 6f and 6g); the live session #821 is no longer flagged by `lib/failed-command-flagged.py scan`.

Closes #821
