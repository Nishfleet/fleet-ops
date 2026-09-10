Wipe the Straitly seat everywhere — cap 0 retirement (fleet-ops#4887)

Retire the Straitly seat everywhere after Nish ordered "wipe straitly"
(2026-09-10). Both metered senior seats returned 402 (xai Grok Build
balance exhausted; Straitly "credit balance is exhausted"). Fable already
capped it to 0 live so the fleet stops drawing; this PR makes the repo
carry the same wipe so a deploy can never resurrect it.

## Scope (issue steps 1-7)

1. **config/seat-caps.json** — straitly provider block deleted; removed
   from ordering lists; top-level history comment added:
   `2026-09-10 straitly wiped (Nish): 402 credit exhausted, seat retired`.
2. **config/entitled-seats.json + config/rule-enforcement.json** — every
   straitly entry removed; `led-straitly-ds4-pro-workers` enforcement row
   retired; `python3 lib/rule-enforcement.py validate-matrix` → `OK: 128 rules`.
3. **LiteLLM template (config/litellm-proxy.yaml)** — worker-cheap
   straitly deployment and the `straitly` provider-budget row removed.
4. **systemd** — straitly references removed from `codex-sol@.service` and
   `fleet-seat-comeback-release.service`; Sol logic preserved.
5. **models.json** — straitly already absent from `config/pi-models.json`
   on main AND from the live `~/.pi/agent/models.json` (verified
   `grep -in straitly` → rc=1 on both); no change needed in this PR. The
   API key in `~/.pi/agent/auth.json` stays untouched and unprinted.
6. **Vault** — `_system/shared-memory/retired-mechanisms.md` carries the
   dated 402 retirement note (verified live).
7. **Tests** — `grep -rn -i straitly config systemd | grep -v _comment`
   = **0 hits** (issue termination gadget requires `== 0`).

Also retired with the seat (mechanical retirement, no new machinery):
`bin/fleet-straitly-ds4-pro-canary` + its test, heartbeat-tier1 block 25,
and the MANIFEST entry. Net machinery trends negative (one canary, one
test, one enforcement row, one LiteLLM deployment, one provider block
removed).

## Verification

- `python3 lib/rule-enforcement.py validate-matrix --matrix config/rule-enforcement.json` → `OK: matrix valid (128 rules)` (rc=0)
- `bash tests/fleet-litellm-organ.test.sh` → `ALL OK: fleet-litellm-organ` (rc=0)
- `bash tests/fleet-token-economy.test.sh` → `minimax is metered (last bucket); straitly retired` (rc=0)
- `bash tests/rule-enforcement.test.sh` → fails ONLY on the pre-existing
  `remeasure-4891-timer.timer missing from manifest` live-state drift
  (fleet-ops#4952, filed separately); unrelated to this diff — the timer
  is not in MANIFEST on main either, and this PR does not touch it. All
  straitly-related assertions in the suite pass.
- Termination gadget: `grep -rn -i straitly config systemd | grep -v _comment` → **0** (issue requires `== 0`).
- `bin/fleet-no-agent-names-check --commit-range origin/main..HEAD` → `OK: no agent attribution detected` (rc=0).

## run-proof

- unit/timer: `python3 lib/rule-enforcement.py validate-matrix` → `OK: matrix valid (128 rules)`.
- `bash tests/fleet-litellm-organ.test.sh` → `ALL OK: fleet-litellm-organ` (16 checks).
- `bash tests/fleet-token-economy.test.sh` → green (rc=0).
- Termination gadget `grep -rn -i straitly config systemd | grep -v _comment | wc -l` → `0`.

## research

No new `bin/` files added (one retired: `bin/fleet-straitly-ds4-pro-canary`).
No hand-built orchestration; the change is pure data/config retirement
(seat-caps, entitled-seats, rule-enforcement, litellm template, two
systemd unit comments, MANIFEST, one canary + its test). The CLAIM-RELEASED
detector-queue-reconciler change that an earlier draft carried was dropped
— it is already in main via fleet-ops#4940.

## help-first

No new mechanism introduced; `--help` not applicable (deletion-only PR).

loose-ends: remeasure-4891-timer manifest drift filed as fleet-ops#4952
(pre-existing, unrelated).

Closes #4887
