## What

`config/seat-caps.json` `providers.commandcode._comment_minimax_m3_free` gains a 2026-09-02 re-verification paragraph for `fleet-ops#2695`. The seat was already retired (cap=0, intentional_cap_zero=corpse) by `fleet-ops#2700` (merged 2026-09-01T21:10:35Z via PR #2708); #2695 is a stale duplicate of #2700 that stayed open because no PR carried `Closes #2695`. The work the issue asked for ("re-auth the commandcode credential or retire the seat from the roster; prove with a live probe") is already done; this PR stamps the row with a current-date re-verification, runs the production lock test, and closes the duplicate.

## Why

Live state (2026-09-02T09:59Z):

- `pi --print --provider commandcode --model minimax/minimax-m3-free 'reply PONG'` -> HTTP 403 FORBIDDEN, `{"message":"The free MiniMax M3 and M2.7 models have been retired. Run /model and pick MiniMax M3 or MiniMax M2.7 to keep going.","type":"permission_error","code":"FORBIDDEN"}` — same body the 2026-09-02T20:59:10Z probe in #2708 captured. The provider retired the free MiniMax M3 line permanently.
- Control probe on the same provider: `pi --print --provider commandcode --model poolside/laguna-s-2.1-free 'reply PONG'` -> `PONG` (exit 0, PACKET-VERDICT tools=0 class=no-tools, observed_at 2026-09-02T10:00:18Z). The commandcode credential is LIVE; only the slug is gone.
- `config/seat-caps.json` `providers.commandcode.models["minimax/minimax-m3-free"]` = `{"cap": 0, "intentional_cap_zero": "corpse"}` — the cap-0 + intentional_cap_zero=corpse row makes pick_seat skip the seat (corpse class is INTENTIONAL, never re-audition, fleet-ops#2435).
- `tests/fleet-free-roster-canary.test.sh` scenario19b pins the production lock: the row must stay present, capped 0, with `intentional_cap_zero=corpse`, with `_comment_minimax_m3_free` dated and citing `fleet-ops#2700`. Scenario19b is the regression guard.

`fleet_pi_seat_dead_credential_total` re-asserts 1 on every fresh probe of the dead slug because the seat-health extension re-writes the ledger. The cap-0 row keeps the seat out of selection; that corpse-survival signal is owned by `fleet-ops#2716`, not #2695 (issue scope boundary).

## What changed

- `config/seat-caps.json`: appended a 2026-09-02 re-verification paragraph to `providers.commandcode._comment_minimax_m3_free`. No cap change, no model change, no billing sibling, no new slug.

## Verification

```
$ python3 -c "import json; json.load(open('config/seat-caps.json')); print('JSON valid')"
JSON valid

$ bash tests/fleet-free-roster-canary.test.sh
... 32 OK ...
OK: scenario19b: production seat-caps keep commandcode minimax/minimax-m3-free retired at cap=0 corpse with dated reason and no billing sibling
OK: fleet-free-roster-canary: ollama carve-out, penny-for-speed, freshness, stale, cap, dedup, prod clean, deepseek-v4-flash-free bench lock, observe-to-close

$ bash tests/seat-caps-citation.test.sh
OK: seat-caps-citation: orcarouter citation pinned, order clean, JSON parses, cap=0 reasons across the fleet are dated + measured, model cap=0 reasons pinned

$ bash tests/seat-lib.test.sh
OK: 1409-fold: seat_usable per-seat UNUSABLE/'benched until' folded into one summary (0 leaked)

$ bash tests/seat-lib-aimd.test.sh
All AIMD invariants passed.

$ bash tests/seat-health-seat-dead.test.sh
OK: fleet-ops#2145/#2327/#2415 closure: corpses (transient c>=25, quota age>=24h) are seat_dead=true, reclassify to the terminal corpse class, and carry NO usable_at retry clock (the cleared clock sticks on further failures); below-threshold and healthy behaviour unchanged; a successful probe recovers

$ bash tests/credential-expiry-canary.test.sh
OK: credential-expiry-canary (fleet-ops#938 + #2134 pre-expiry probe)

$ bash tests/fleet-metrics-export.test.sh
... 45 OK ...
```

run-proof: live transcript — `pi --print --provider commandcode --model minimax/minimax-m3-free 'reply PONG'` returns 403 FORBIDDEN at 2026-09-02T09:59:04Z (PACKET-VERDICT tools=0 class=no-tools); control probe `pi --print --provider commandcode --model poolside/laguna-s-2.1-free 'reply PONG'` returns PONG at 2026-09-02T10:00:18Z in the same window. Seat ledger `/home/nish/workspaces/agent-state/lanes/seats/commandcode__minimax_minimax-m3-free.json` (re-written by the dead probe) carries `health_class=corpse seat_dead=true failure_mode=credentials_bad http_status=403 consecutive_failure_count=2 observed_at=2026-09-02T09:59:04.156Z` — the cap=0 + intentional_cap_zero=corpse row in seat-caps.json keeps pick_seat from selecting the seat; the regression guard is scenario19b.

Closes #2695
