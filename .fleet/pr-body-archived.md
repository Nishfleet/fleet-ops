## Summary

PR #4998 merged the `FleetSloSeatAvailSlowBurn` auto-file-or-link mechanism for #4773, but it never fired in production: `prometheus-am-executor` sends `AMX_ALERT_<i>_START` as a **Unix epoch integer** (e.g. `1789051780`, confirmed by every recent packet file), while the merged `_slowburn_firing_seconds` parsed it as ISO 8601 (`%Y-%m-%dT%H:%M:%S`) → `ValueError` → `None` → `skip-short` every tick. The live alert has been firing since 2026-09-08T09:51:03Z (2+ days) with zero linked critical-path claims — the exact fault the issue's `metric:` names.

The termination tests passed only because they mocked `AMX_ALERT_1_START` as ISO 8601, which does not match what AMX sends. The test masked the bug.

This fixes the parser to accept epoch integers (AMX's production format) with ISO 8601 kept for backward-compat, and switches the test to epoch `+%s` so it reflects production reality and would have caught this bug. No new organ/timer/service/canary; the skip-list entry, mutex, and class-park paths are untouched.

- `libexec/alert-repair-dispatch` `_slowburn_firing_seconds`: epoch-first parsing (digits, optional trailing `Z`/`.fff`) with ISO 8601 fallback; fail-safe `None` on unparseable; comment cites the packet-file evidence.
- `tests/alert-repair-slo-slowburn-skip.test.sh`: `two_h_ago`/`ten_m_ago` now emit epoch seconds (`+%s`, BSD fallback); (a)/(b)/(c)/(d) assertions intact; added case (e) proving an ISO 8601 start also files (backward-compat).

## accept (from issue)

1. First checks for an existing open `critical-path` item by signal key before filing — links instead of double-filing. ✓ (merged #4998 code, unchanged)
2. Routes through existing organs (`libexec/alert-repair-dispatch` + `fleet-issue-file` + `gh`); no new timer/service/dispatcher/canary. ✓
3. Does NOT raise the alert-repair skip-list entry. ✓
4. Notifies am-executor via the alert-repair dispatch path; never pages Nish. ✓
5. Prevention mechanism: test proves (a) >1h + no claim → files exactly one; (b) >1h + live claim → links, idempotent across 2nd tick; (c) ≤1h → plain skip; (d) multi-alert index lookup; (e) ISO 8601 start also works. Now with epoch (production format) so it actually catches the bug. ✓
6. No money decision; no seat top-up/buy/re-scale. ✓

## Verification

Termination command (from the issue body):
```
cd /home/nish/workspaces/tooling/fleet-ops
bash tests/alert-repair-slo-slowburn-skip.test.sh
bash tests/alert-repair-claim-mutex.test.sh
```
Result: both exit 0.

`bash tests/alert-repair-slo-slowburn-skip.test.sh`:
```
OK: dispatcher SKIP_SET contains FleetSloMainGreenSlowBurn (one occurrence in literal)
OK: FleetSloMainGreenSlowBurn: dispatcher SKIP reason=skip-list, no DISPATCH, no spawn
OK: fleet-ops#2672 slow-burn skip-list lock passes
OK: (c) firing <=1h: SKIP reason=skip-list, no file, no link, no spawn
OK: (a) firing >1h + no existing claim: FILED exactly one #4773, no spawn, no DISPATCH
OK: (b) firing >1h + live claim: LINK #4242 + heartbeat, no file; idempotent across 2nd tick
OK: (d) multi-alert: SlowBurn at idx2 (>1h) FILED using its own start, not idx1's short decoy
OK: (e) ISO 8601 start also works (backward-compat): FILED exactly one
OK: fleet-ops#4773 slowburn file-or-link both directions + idempotence pass
```

`bash tests/alert-repair-claim-mutex.test.sh`: exit 0 (skip-list lock for SlowBurn still holds, no spawn).

Adjacent organs (no regression):
- `bash tests/signal-reconcile.test.sh` → exit 0
- `python3 -c "import py_compile; py_compile.compile('libexec/alert-repair-dispatch', doraise=True)"` → OK
- `python3 -c "import yaml; yaml.safe_load(open('config/fleet_rules.yml'))"` → OK

Production-realism proof: the live alert's `startsAt 2026-09-08T09:51:03Z` → epoch `1788861063` now parses to ~194735s firing (>>3600s threshold), so the mechanism will FILE on the next AMX tick instead of `skip-short`. Pre-fix, the alert-repair actions.log showed the 15:52:27Z tick ran "(slowburn file-or-link attempted)" with NO `FILED`/`LINK` line.

run-proof: `bash tests/alert-repair-slo-slowburn-skip.test.sh && bash tests/alert-repair-claim-mutex.test.sh` (both green, exit 0).

## Test plan

- [x] `bash tests/alert-repair-slo-slowburn-skip.test.sh` — both directions + idempotence + multi-alert index + ISO backward-compat (epoch format now matches production)
- [x] `bash tests/alert-repair-claim-mutex.test.sh` — skip-list lock holds, no spawn
- [x] adjacent signal-reconcile / compile / yaml-parse tests green

Relates to #4773

net-positive-because: fixes a proven production bug (the merged #4998 mechanism never fired — epoch vs ISO timestamp parse) by extending the existing organ's parser, and makes the prevention-mechanism test match AMX's real epoch format so it cannot mask the bug again; no new organ/timer/service/canary is added.

loose-ends: none — after merge, the next AMX tick (6h repeat_interval) will file/link exactly one critical-path claim for the live 2-day alert; the manager verifies that on main post-merge.
