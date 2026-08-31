## What changed and why

Issue #2531 reported both xai-oauth Grok seats dead (401 credentials_bad,
observed 11:29:42Z) and a hand-marked-dead poolside free seat
(commandcode/poolside/laguna-s-2.1-free, 4x 503 overloaded_error, 06:50Z).

Live verification on 2026-08-31 ~12:29Z shows nothing is dead:

- **Grok seats**: the stored refresh token was still valid. The existing
  `grok-token-refresh` 4h timer refreshed the access token at 11:36:46Z
  (outcome=success, `fleet_grok_token_refresh_last_success_seconds 1788176206`),
  ~7 min after the 401. A direct probe of the subscription proxy
  `cli-chat-proxy.grok.com/v1/models` with the current access token returns
  HTTP 200 and lists grok-4.6 / grok-4.5. Both seat ledgers have been
  `health_class=healthy, seat_dead=false` since 11:57:56Z. No device flow
  and no Nish escalation were needed.
- **Poolside seat**: STALE, not dead. A 1-token `pi --print --provider
  commandcode --model poolside/laguna-s-2.1-free "Reply with exactly: OK"`
  probe succeeded (rc=0, reply OK); the seat-health extension then wrote the
  healthy observation (http 200, seat_dead=false,
  observed_at 2026-08-31T12:29:26.902Z) to the seat ledger.

The Grok heal path (expired access token, valid refresh token -> timer
refreshes -> seat healthy) is already drilled by `tests/grok-token-refresh.test.sh`
(24 scenarios). The undrilled seam this incident exposed was the bash side
of the poolside revival: a seat hand-marked `seat_dead=true` after a
TRANSIENT overload (not a corpse) is excluded by `seat_usable`/`pick_seat`
until a fresh healthy observation lands — the exact mechanism that revived
it. This PR locks that re-admission with the literal 2026-08-31 incident
ledger shapes as a new invariant 7c in `tests/seat-lib.test.sh`
(refusal while dead -> pick_seat refrains -> healthy observation lands ->
`seat_usable` re-admits -> `pick_seat` picks the lane). No runtime code,
no new organs, no workflow edits.

## Verification

- `bash tests/seat-lib.test.sh` -> exit 0, 834 OK (3 new 2531-poolside
  assertions) before this change: 831 OK.
- Live xai-oauth probe: `curl -w '%{http_code}' cli-chat-proxy.grok.com/v1/models`
  with the current `xai-oauth` access token -> `200` (body lists grok-4.6, grok-4.5).
- Live poolside probe: `timeout 60 pi --print --provider commandcode --model
  poolside/laguna-s-2.1-free "Reply with exactly: OK"` -> rc=0, reply `OK`;
  ledger rewritten to 200/healthy/seat_dead=false at 12:29:26.902Z.
- Ledger evidence:
  - `agent-state/lanes/seats/xai-oauth__grok-4.5.json` / `...grok-4.6.json`:
    health_class=healthy, seat_dead=false, observed_at 11:57:56Z.
  - `agent-state/lanes/seats/commandcode__poolside_laguna-s-2.1-free.json`:
    health_class=healthy, seat_dead=false, observed_at 12:29:26.902Z.
- Refresh organ evidence: `/var/lib/prometheus/node-exporter/fleet-grok-token-refresh.prom`
  shows outcome=success, last_success 1788176206 (11:36:46Z).

run-proof: journal/transcript — see Verification (no unit/timer/workflow added by this PR; the
drill runs under the already-listed `tests/seat-lib.test.sh` in ci.yml).

Closes #2531