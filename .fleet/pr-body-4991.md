fix(failed-command): lock the edits.0: must be object schema-validation sibling (Relates to #4991)

## Summary

The fleet-ops#4819 worker session (2026-09-09T21-00-52-059z_fleet-ops-4819-1788987651753950355.jsonl) called the `edit` tool on `bin/fleet-seat-comeback-release` with the whole `edits` array serialized as a JSON-encoded STRING instead of an array of objects:

```
Validation failed for tool "edit":
  - edits.0: must be object

Received arguments:
{
  "edits": "[{\"newText\": ...}]",
  "path": "..."
}
```

isError=true, details={}, no "Command exited with code" line — the harness rejected the call BEFORE dispatch because the worker's own arguments were malformed. The recovery was three empty assistant turns followed by cause-prose — "The edit tool needs the edits as an array of objects, not a JSON string" — plus a successful retry. That prose names the CAUSE (the malformed `edits` argument shape), never the FAILURE (the edit call returned isError=true), so the detector correctly flags it as a swallowed failure (fleet-ops#535 / fleet-ops#1052).

This is the SIBLING schema-validation shape of fleet-ops#1286 (omitted top-level `path` field): same edit tool, same reject-before-dispatch class, different wording — here `edits` is a string, so `edits.0` is not an object. The detector already catches it via the generic isError path. This PR locks the shape with a regression test (mechanical-fix, fleet-ops#366) and extends the lib docstring/comment locks so a future refactor cannot add a "schema validation is a negative result" exemption for it.

Scope: regression test + lib citations only. No detector logic change, no new machinery, no unit/timer/workflow. Closing is observe-to-close (fleet-ops#362): the reconciler closes #4991 only when the detector reports green on a real heartbeat tick after the session ages out of the 24h window — never on PR merge.

## Prior art

- fleet-ops#1286 `tests/fleet-failed-command-edit-schema-validation.test.sh` — the missing-top-level-field schema-validation shape this extends.
- fleet-ops#956 / #965 / #1053 / #1139 / #1173 — the other edit-failure shapes (0-match, many-match, no-op, multi-edit array), all covered by dedicated regression tests.
- Fleet-ops#4819's own detector (bin/fleet-failed-command-flagged) generated the alarm this PR responds to.

## Verification

Reproduced the detector on the live session first:
```
$ python3 lib/failed-command-flagged.py scan --root <session dir> --window-hours 48 --grace-minutes 0
1 finding: Validation failed for tool "edit": - edits.0: must be object  ...
exit: 0 (a real finding — the alarm is live)
```
Then the extended regression test and the full failed-command family:

```
$ bash tests/fleet-failed-command-edit-schema-validation.test.sh
OK: live #4991: edits-as-string schema validation with cause-prose recovery is flagged
OK: edits-as-string schema validation plus a later user-facing flag is clean
OK: lib/failed-command-flagged.py cites fleet-ops#4991 and the edits-as-string wording
OK: lib/failed-command-flagged.py docstring cites fleet-ops#4991
OK: fleet-failed-command-edit-schema-validation: live #1286 + #4991 edit schema-validation drills
exit: 0
```
```
$ for t in tests/fleet-failed-command-edit-unmatch.test.sh tests/fleet-failed-command-edit-array-unmatch.test.sh tests/fleet-failed-command-flagged.test.sh tests/fleet-failed-command-dedup-open-list.test.sh tests/fleet-failed-command-observe-duplicate-open.test.sh tests/fleet-failed-command-no-agent-names-reject.test.sh tests/fleet-failed-command-gh-pr-json-piped-python-load.test.sh; do bash "$t" || exit 1; done
OK (8/8) — no regressions in the edit-failure family or the detector core
```
```
$ bash tests/seat-lib.test.sh        # the CI composite
exit: 0 (ALL OK, includes the extended schema-validation drills)
```
```
$ bash bin/sgscan
No new security findings.  exit: 0
$ python3 -m py_compile lib/failed-command-flagged.py  # syntax clean
```

run-proof: tests/fleet-failed-command-edit-schema-validation.test.sh (11 drills, 4 new for #4991), full tests/seat-lib.test.sh composite green, sgscan clean, py_compile clean — all on the live-deploy lineage.

research: the sibling boundary is documented as a contrast pair inside lib/failed-command-flagged.py itself (#1286 missing-path vs #4991 edits-as-string, same reject-before-dispatch class), and the test asserts both shapes are flagged while a real user-facing flag stays clean.

net-positive-because: the +129 net lines are the regression fixture pinning the new sibling shape (the mechanical fix, fleet-ops#366) plus the lib citation paragraph; no runtime logic changed and no machinery added.

Relates to #4991