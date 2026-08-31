## Why

fleet-ops#2462: issue #1526 was re-claimed 27 times in 24h, each dispatch
running a pi worker that hit provider-wide 503/429/500 storms across every
seat. The reclaim cooldown (15 min) broke the tight spawn-die-respawn loop,
but did not stop the item from draining the seat pool one cooldown at a
time — each re-claim picked a fresh seat that also failed, and the next
tick re-claimed again after 15 min. Net effect: dispatches_last_2h stalled
while the item recycled indefinitely.

The root cause is NOT a packet/prompt defect (the archived packets were
all well-formed, 331–885 B). It is a systemic provider outage that every
seat hit simultaneously, but the fleet had no mechanism to stop re-claiming
an item once it had exhausted the seat pool, and no way to distinguish an
item-caused empty run from a seat-caused one.

## Scope

Three concrete mechanisms, shipped together:

1. **Claim cap (requirement c):** `MAX_RECLAIMS` env var (default 8) in
   `lib/pi-intake-tick.sh`. Before claiming, intake counts the issue's
   entries in the claims log + the per-issue reclaim-count file. After the
   cap, intake skips the issue and escalates it to `agent-blocked` with a
   `blocked-on: nish-decision` line so a senior reviews why every seat
   fails. The counter is initialised to 1 on first claim
   (`pi-intake-tick.sh` → `pi-issue-run` success path), incremented by
   `pi-issue-failed-reap` on each failed re-claim, and reset on issue close
   (`fleet-merged-pr-close`) or on worker success.

2. **Systemic-failure skip (requirement b):** `bin/pi-issue-failed-reap`
   detects when every tried seat is benched (all seats failed with provider
   errors for the same item) and writes a `.systemic` marker. Intake
   respects it: `skipped-systemic-failure` holds re-claims for
   `RECLAIM_COOLDOWN_S` so the seat pool can recover from the provider
   storm before the next attempt. The marker is cleared after expiry or on
   close.

3. **Reclaim-count tracking:** a per-issue file at
   `$ATTEMPTS_DIR/pi-issue-<repo>-<N>.reclaim-count` across all three
   code paths, with the same lifecycle as the existing reclaim-cooldown
   marker.

Tests: `tests/fleet-ops-2462-claim-cap.test.sh` — 11 static/grep tests
pinning each mechanism across `pi-intake-tick.sh`, `pi-issue-failed-reap`,
`pi-issue-run`, and `fleet-merged-pr-close`.

## Verification

- `bash -n` on all 4 modified files: exit 0
- `tests/fleet-ops-2462-claim-cap.test.sh`: ALL OK (11 tests)
- `tests/pi-intake-tick-reclaim-cooldown.test.sh`: ALL OK (9 tests, no regres)
- `tests/pi-intake-tick-claims-log.test.sh`: ALL OK (5 tests, no regres)
- `tests/pi-issue-run-noop-bench.test.sh`: ALL OK
- `tests/pi-issue-failed-reap-cooldown.test.sh`: ALL OK
- `sgscan --name-status`: No new security findings
- `fleet-exec-review-canary`: OK (Verification/run-proof receipt present)
- `fleet-no-agent-names-check`: OK
- `fleet-token-efficiency-check`: OK (no anti-patterns)
- `fleet-wipe-lessons-check scan`: clean

run-proof: bash tests/fleet-ops-2462-claim-cap.test.sh + bash -n on all touched files

## Tradeit

- The claim cap (8) is a tunable: too low and legitimate long-running issues
  get escalated; too high and the starvation risk returns. 8 gives ~2h of
  recovery (15 min cooldown × 8) which covers a typical provider storm
  window without locking out real work.
- The systemic-failure check reads the seat-health ledger via `seat_usable`
  from `seat-lib.sh`, the same authority the worker uses. If the lib is
  absent (CI), the check is skipped (fail-open).
- This does not change the reclamation cooldown or the seat-bench mechanism
  — it adds a second, harder backstop on the item side.

## Blast Radius

- `lib/pi-intake-tick.sh`: the reclaim-count and systemic checks run only
  on the `agent-ready` → `agent-in-progress` path. They are gated by file
  existence (no file = count 0, no marker = proceed) so they are invisible
  when no state files exist (fresh issues, first claim).
- `bin/pi-issue-failed-reap`: the reclaim-count increment and systemic
  detection run only in the OPEN branch (after branch delete). The CLOSED
  branch only does `rm -f` (idempotent, no error on missing).
- `bin/pi-issue-run`: the reclaim-count init runs only when the file is
  absent (first claim). The reset on success runs only on the
  `--print` exit-0 path, which was already the success path.
- `bin/fleet-merged-pr-close`: the reset runs only inside the `OK_TO_CLOSE`
  gate (production heartbeat only).
