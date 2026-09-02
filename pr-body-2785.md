## What

FleetDeadCredentialSeats fired value=3 at 2026-09-02T04:20:34Z for three seats. Each was probed live and re-classified; all three credentials are alive, the alert has cleared (`fleet_pi_seat_dead_credential_total` = 0 on a fresh exporter run), and no seat needed retiring. The seat map rows now carry dated 2026-09-02 re-verification evidence refreshed with live re-probes at 18:36-19:12Z.

| seat | 401 observed | live probe 2026-09-02 | verdict |
|---|---|---|---|
| xai-oauth/grok-4.5 | 05:26:52Z | PONG rc=0, http 200, ledger healthy seat_dead=false (observed 19:12:19Z) | SELF-HEALED — grok-token-refresh rotated access+refresh at 13:15:20Z (journal `OK access rotated, refresh rotated, expires_in=21600s, access_sha256_prefix=451e77827c13de1e`); no interactive re-auth needed. Cap stays 0 (restore parked on fleet-ops#2839, blocked-on: nish-decision). |
| xai-oauth/grok-4.6 | 05:26:52Z | PONG rc=0, http 200, ledger healthy seat_dead=false (observed 19:12:23Z) | SELF-HEALED — same rotation. Cap stays 0 (fleet-ops#2839). |
| commandcode/deepseek/deepseek-v4-flash | 04:17:42Z | HTTP 400 `insufficient credits` (n=4 total across re-probes) | NOT a credential fault — the control probe poolside/laguna-s-2.1-free returns PONG on the same key (credential LIVE); the slug is on the known #1890 money wall. No seat_dead ledger entry exists, so it is not inflating the dead-credential count. Cap stays 2 (do not flip without closing #1890). |

## Why

The alert's own triage (fleet_rules.yml, added fleet-ops#2667) says: probe the seat live AND a second model on the same provider as a control. If the control succeeds, the credential is fine and the model-level state decides. That is what happened here:

- Both xai-oauth seats recovered on their own via the existing refresh path (pi-grok auto-refresh on 401 + the grok-token-refresh organ, rotation observed 13:15:20Z). The 401s were a token-expiry window, not a revoked credential.
- commandcode deepseek-v4-flash is the known credit-exhaustion money wall owned by #1890; the morning 401 escalated a corpse ledger that the quarantine/comeback path already retired out of the live roster. Current ledgers: `xai-oauth__grok-4.5.json` / `xai-oauth__grok-4.6.json` healthy seat_dead=false http 200; no `commandcode__deepseek_deepseek-v4-flash.json` at all.

No cap changes: grok 0->1/1 restore is money-adjacent (SuperGrok sub renewal) and explicitly parked on fleet-ops#2839 (blocked-on: nish-decision). The commandcode deepseek row stays at 2 per the standing #1890 boundary.

## What changed

- `config/seat-caps.json`: appended a dated 2026-09-02 fleet-ops#2785 re-verification to `providers.commandcode._comment_2667` (deepseek-v4-flash: money wall, control PONG, credential live, cap 2) and to `providers["xai-oauth"]._grok_402_note` (both grok seats self-healed via rotation at 13:15:20Z, live 200 PONG, caps stay 0 pending #2839). No cap change, no model change, no new slug.

## mechanism

Mechanism already exists; this PR proves it fires. The dead-credential metric + alert were regression-guarded in fleet-ops#2667 (PR #2741): `tests/fleet-metrics-export.test.sh` seeds corpse/healthy ledger shapes and asserts the count is right (corpse counted, healthy/stale seat_dead=false not counted); `_read_dead_credentials()` is the gate. The alert-repair loop already auto-files the FleetDeadCredentialSeats ticket; seats that self-heal (xai-oauth) or are money-walled with a live credential (commandcode deepseek, #1890) are the re-verify-and-record class, same as fleet-ops#2695 (PR #2807). No new organ, no new checker — net machinery unchanged.

## Verification

Live probes (2026-09-02 ~18:36-19:12Z, re-run this session):

```
$ pi --print --provider xai-oauth --model grok-4.5 'reply PONG'       -> PONG ; RC=0
$ pi --print --provider xai-oauth --model grok-4.6 'reply PONG'       -> PONG ; RC=0
$ pi --print --provider commandcode --model deepseek/deepseek-v4-flash 'reply PONG'  (n=4 total)
  -> 400: {"message":"You have insufficient credits to make this request...","type":"invalid_request_error","code":"BAD_REQUEST"}
$ pi --print --provider commandcode --model poolside/laguna-s-2.1-free 'reply PONG'   # control
  -> PONG ; RC=0
```

Seat ledgers after the probes (seat-health extension wrote after_provider_response):

```
xai-oauth__grok-4.5.json: health_class=healthy seat_dead=false http_status=200 observed_at=2026-09-02T19:12:19Z
xai-oauth__grok-4.6.json: health_class=healthy seat_dead=false http_status=200 observed_at=2026-09-02T19:12:23Z
commandcode-deepseek ledger: absent (no dead entry, not counted)
```

run-proof: live exporter run (the exact code `fleet-metrics-export.service` runs, OUT patched to a temp path so the prod textfile is untouched) against the real seat ledger:

```
$ python3 libexec/fleet-metrics-export.py (m.OUT=/tmp/2785-fme/fleet.prom)
wrote /tmp/2785-fme/fleet.prom (23 timers, seat_healthy=1)
hc ping branch=healthy status=200
rc = 0
$ grep fleet_pi_seat_dead_credential /tmp/2785-fme/fleet.prom
fleet_pi_seat_dead_credential_total 0
(no per-seat fleet_pi_seat_dead_credential series)
```

Token rotation that healed the xai seats (journal, `journalctl --user -u grok-token-refresh.service`):

```
Sep 02 18:45:19Z [grok-token-refresh] refresh needed: access expires in -6065s (TTL_S=1800)
Sep 02 18:45:20Z [grok-token-refresh] OK access rotated, refresh rotated, expires_in=21600s, access_sha256_prefix=451e77827c13de1e
```

Repo checks:

```
$ python3 -c "import json; json.load(open('config/seat-caps.json')); print('JSON valid')"   -> JSON valid
$ promtool check rules config/fleet_rules.yml           -> SUCCESS: 70 rules found (exit 0)
$ bash tests/seat-caps-citation.test.sh                 -> EXIT 0 (scenario7 pins xai-oauth grok cap=0 rows dated)
$ bash tests/fleet-metrics-export.test.sh               -> EXIT 0
$ bash tests/seat-health-seat-dead.test.sh              -> EXIT 0
$ bash tests/fleet-free-roster-canary.test.sh           -> EXIT 0
$ /home/nish/.local/bin/sgscan                          -> No new security findings
```

Closes #2785