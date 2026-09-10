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
5. **models.json** — straitly already absent from config/pi-models.json on
   main (no change needed in this PR).
6. **Vault** — retired-mechanisms.md already carries the dated 402
   retirement note; the ledger "straitly approved for workers" decision was
   voided (struck) so the engagement no longer reads as a live obligation.
7. **Tests** — `grep -rn -i straitly config systemd | grep -v _comment`
   = **0 hits**. Live LiteLLM canary green.

Also retired with the seat (mechanical retirement, no new machinery):
`bin/fleet-straitly-ds4-pro-canary` + its test, heartbeat-tier1 block 25,
and the MANIFEST entry.

## Verification

- `python3 lib/rule-enforcement.py validate-matrix --matrix config/rule-enforcement.json` → `OK: matrix valid (128 rules)`
- `bash tests/fleet-litellm-organ.test.sh` → `ALL OK: fleet-litellm-organ` (exit 0)
- `bash tests/fleet-token-economy.test.sh` → `EXIT 0`
- `bash tests/rule-enforcement.test.sh` → passes (only pre-existing
  `remeasure-4891-timer.timer missing from manifest` on this box, unrelated;
  not in the diff)
- Live `fleet-litellm-health-canary` after manual start → finished
  (`proxy_up=1 status=200 census=38 expected=38 pg_up=1 redis_up=1`);
  live `~/.config/fleet-ops/litellm-proxy.yaml` already has **no** straitly.
- Termination gadget: `grep -rn -i straitly config systemd | grep -v _comment`
  → **0** (issue requires `== 0`).
- `bin/fleet-no-agent-names-check` → `OK: no agent attribution detected`.

## run-proof

- unit/timer: `fleet-litellm-health-canary.service` manual run → `Finished`
  (journal excerpt above).
- `bash tests/fleet-litellm-organ.test.sh` → `ALL OK` (live repo drill).
- `bash tests/fleet-token-economy.test.sh`, `bash tests/rule-enforcement.test.sh`.

Closes #4887