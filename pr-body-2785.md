## What

FleetDeadCredentialSeats fired value=3 at 2026-09-02T04:20:34Z for three seats. Each was probed live and re-classified; all three credentials are alive, the alert has cleared (fleet_pi_seat_dead_credential_total = 0), and no seat needed retiring. The seat map rows now carry dated 2026-09-02 re-verification evidence.

| seat | 401 observed | live probe 2026-09-02 ~16:5xZ | verdict |
|---|---|---|---|
| xai-oauth/grok-4.5 | 05:26:52Z | PONG, http 200, ledger healthy seat_dead=false | SELF-HEALED — headless refresh rotated access+refresh at 13:15:20Z (journal `OK access rotated, refresh rotated, expires_in=21600s`); no interactive re-auth needed. Cap stays 0 (restore is money-adjacent, parked on fleet-ops#2839 nish-decision). |
| xai-oauth/grok-4.6 | 05:26:52Z | PONG, http 200, ledger healthy seat_dead=false | SELF-HEALED — same rotation. Cap stays 0 (fleet-ops#2839). |
| commandcode/deepseek/deepseek-v4-flash | 04:17:42Z | HTTP 400 `insufficient credits` (n=3) | NOT a credential fault — the control probe poolside/laguna-s-2.1-free returns PONG on the same key (credential LIVE); the slug is on the known #1890 money wall. The corpse ledger it escalated (05:38:59Z, 401) is quarantined; live roster carries no entry, so it is not inflating the dead-credential count. Cap stays 2 (do not flip without closing #1890). |

## Why

The alert's own triage (fleet_rules.yml, added fleet-ops#2667) says: probe the seat live AND a second model on the same provider as a control. If the control succeeds, the credential is fine and the model-level state decides. That is what happened here:

- Both xai-oauth seats recovered on their own via the existing refresh path (pi-grok auto-refresh on 401 + the grok-token-refresh organ). The 401s were a transient token-expiry window, not a revoked credential.
- commandcode deepseek-v4-flash is the known credit-exhaustion money wall owned by #1890 (already documented in `_comment_2667`); the transient 401 this morning escalated a corpse ledger that the comeback/quarantine path already retired out of the live roster.

No cap changes: grok 0->1/1 restore is money-adjacent and is explicitly parked on fleet-ops#2839 (blocked-on: nish-decision). The commandcode deepseek row stays at 2 per the standing #1890 boundary.

## What changed

- `config/seat-caps.json`: appended a dated 2026-09-02 fleet-ops#2785 re-verification to `providers.commandcode._comment_2667` (deepseek-v4-flash: money wall, control PONG, credential live, cap 2) and to `providers["xai-oauth"]._grok_402_note` (both grok seats self-healed via rotation at 13:15:20Z, live 200 PONG, caps stay 0 pending #2839). No cap change, no model change, no new slug.

## mechanism

Mechanism already exists; this PR proves it fires. The dead-credential metric + alert were regression-guarded in fleet-ops#2667 (PR #2741): `tests/fleet-metrics-export.test.sh` seeds corpse and healthy ledger shapes and asserts the count is right (corpse counted, healthy/stale-seat_dead=false not counted). `_read_dead_credentials()` is the gate. That mechanism is why the alert cleared and the live ledger scan returns 0. The alert-repair loop already auto-files the FleetDeadCredentialSeats ticket; seats that self-heal (xai-oauth) or are money-walled with a live credential (commandcode deepseek, #1890) are the re-verification-and-record class, same as fleet-ops#2695 (PR #2807). No new organ, no new checker — net machinery unchanged.

## Verification

Live probes (2026-09-02):

```
$ pi --print --provider xai-oauth --model grok-4.5 'reply PONG'
PACKET-VERDICT tools=1 class=worked ; EXIT=0  (ledger http 200 healthy after)
$ pi --print --provider xai-oauth --model grok-4.6 'reply PONG'
PONG ; EXIT=0  (ledger http 200 healthy after)
$ pi --print --provider commandcode --model deepseek/deepseek-v4-flash 'reply PONG'  (n=3)
400: {"message":"You have insufficient credits to make this request...","code":"BAD_REQUEST"}
$ pi --print --provider commandcode --model poolside/laguna-s-2.1-free 'reply PONG'   # control
PONG ; EXIT=0
```

run-proof: live exporter run against the real ledger and timers — `fleet_pi_seat_dead_credential_total 0`, no per-seat `fleet_pi_seat_dead_credential` series (the alert's own metric source, same code the `fleet-metrics-export.service` runs):

```
$ python3 <runner through libexec/fleet-metrics-export.py>
wrote /tmp/2785-fme-*/fleet.prom (23 timers, seat_healthy=1)
fleet_pi_seat_dead_credential_total 0
main rc = 0
```

Token rotation that healed the xai seats (journal):

```
Sep 02 13:15:20Z [grok-token-refresh] refresh needed: access expires in -6065s
Sep 02 13:15:20Z [grok-token-refresh] OK access rotated, refresh rotated, expires_in=21600s
```

Repo checks:

```
$ python3 -c "import json; json.load(open('config/seat-caps.json')); print('JSON valid')"   -> JSON valid
$ promtool check rules config/fleet_rules.yml  -> SUCCESS: 58 rules found (exit 0)
$ bash tests/seat-caps-citation.test.sh        -> EXIT 0 (scenario7 pins xai-oauth grok cap=0 rows dated)
$ bash tests/fleet-metrics-export.test.sh      -> EXIT 0
$ bash tests/seat-health-seat-dead.test.sh     -> EXIT 0
$ bash tests/fleet-free-roster-canary.test.sh  -> EXIT 0
$ /home/nish/.local/bin/sgscan on the diff     -> No new security findings
```

PRE-EXISTING (verified identical on a clean origin/main checkout, unrelated to this comment-only diff): `tests/seat-lib.test.sh` -> exit 1 at the hosted `alert-repair-claim-mutex.test.sh` step. The live host currently has FleetMainRed firing and class-parked (`reason=class-park until=2026-09-03T14:07:17Z`), and that test expects a DISPATCH line, so it cannot pass in this live window. Reproduces on origin/main unchanged.

organ-heartbeat: no new organ — this edits comment fields inside the existing seat map; no new candidate-organ file, no absent-rule change.

loose-ends-canary: pr:nishfleet/fleet-ops#2785 stale-worker-pr

Closes #2785