## Why

The 2026-09-04T16:30Z snapshot paged three dead opencode seats. Two of those
were already retired (hy3-free, x-preview-f-free at cap=0). The third,
mimo-v2.5-free, had a real HTTP 429 retry window that the comeback-release
organ then wiped in the same sweep.

Live journal of fleet-seat-comeback-release.service at 16:30:04Z:

```
probe opencode/mimo-v2.5-free failed (rc=1)
skip rebench opencode/mimo-v2.5-free: wall moved to the future (2026-09-04T16:45:04.204Z)
CORPSED opencode/mimo-v2.5-free (count=27 >= 25, source=comeback_release_corpse)
```

The extension set usable_at +15min. corpse_seat then rewrote the ledger to
failure_mode=comeback_never_released with usable_at=null. 27 failures, no
retry clock. That is the comeback_never_released the issue names.

The two 401s were not a dead opencode credential. hy3-free and
x-preview-f-free were already cap=0. ling-3.0-flash-fin-free on the same
provider was healthy. A 401 on a retired slug is not a re-auth action.
Re-auth is Nish-reserved (account/credential). This PR does not touch
auth.json.

## Scope

- `bin/fleet-seat-comeback-release`: after a failed probe, skip the
  count-based corpse write when the ledger already holds a future wall
  (the extension re-anchored this sweep). jq/rename failures still corpse.
- `libexec/fleet-metrics-export.py` `_read_dead_credentials`: count only
  enrolled (model cap>0) seats. Fail open if seat-caps.json is unreadable.
- `config/fleet_rules.yml` FleetDeadCredentialSeats description matches.
- Regression tests: test 19 on the 16:30Z mimo shape; cap=0 hy3/x-preview
  excluded from the dead-cred total.

Out of scope: re-auth of the opencode credential (control seat was
healthy), rewriting seat-health.ts (out of repo), retiring mimo (it is
still enrolled, cap=1; a 429 is a quota wall, not a corpse).

Related open tickets #3188 and #3229 cover the same mimo never-released
class. This PR ships the prevention for that class. Those tickets stay
open until their own workers drain them.

## Tradeoffs

Count-based corpse still fires on the next sweep if that sweep's probe
does not re-anchor (no HTTP window). Test 10 still pins that path. The
skip is only for a wall that is already in the future.

## Blast radius

The one safety fact: a future `usable_at` written by the extension this
sweep is no longer overwritten to null. Proven by running the real bin
against the 16:30Z mimo fixture (script-ran, then reproduced on the named
deliverable). Callers of `_read_dead_credentials` still see enrolled 401s;
cap=0 rows drop out. Fail-open on unreadable caps keeps a genuine enrolled
401 visible.

## Verification

Named run of the deliverable (the 16:30Z mimo shape against the real bin):

```
PI_SEAT_HEALTH_LEDGER_DIR=/tmp/issue-3301-run/seats \
  FLEET_SEAT_COMEBACK_STATE=/tmp/issue-3301-run/state.json \
  FLEET_SEAT_COMEBACK_PROM=/tmp/issue-3301-run/out.prom \
  FLEET_SEAT_COMEBACK_NOW=2026-08-30T12:00:00Z \
  PI_BIN=/tmp/issue-3301-run/pi-fail-reanchor-429 \
  bash bin/fleet-seat-comeback-release
```

exit=0. Log:

```
skip rebench opencode/mimo-v2.5-free: wall moved to the future (2026-08-30T12:15:04.204Z)
skip corpse opencode/mimo-v2.5-free: extension re-anchored a future wall this sweep — retry window stands (fleet-ops#3301)
sweep complete: probed=1 released=0 expired_after=0
```

Ledger after: health_class=rate_limited, failure_mode=rate_limit,
usable_at=2026-08-30T12:15:04.204Z, consecutive_failure_count=27,
seat_dead=false. The 429 window stands.

16:37Z retired snapshot + live seat-caps through `_read_dead_credentials`:
dead_credential_total=0 (hy3/x-preview cap=0, mimo not credentials_bad).

`bash tests/fleet-seat-comeback-release.test.sh` ALL OK including test 19.

`bash tests/fleet-metrics-export.test.sh` ALL OK including the cap=0
exclusion and fail-open.

SKIP: crgate (CodeRabbit is not signed in on this machine).

run-proof: named run of bin/fleet-seat-comeback-release against the
16:30Z mimo fixture, exit 0, skip-corpse log line, ledger usable_at kept.

loose-ends-canary: pr:nishfleet/fleet-ops#3301 stale-worker-pr

Closes #3301
