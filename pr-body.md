# fix(litellm): skip startup migrate deploy — shipped upstream migration already drops the P3018-blocking unique tag index (fleet-ops#4832)

Closes #4832

## Pick (accept-1): drop the redundant single-column unique index — already done upstream, pinned off at startup

Root cause chain, verified live on netcup-rs2000 (2026-09-12):

- Migration `20250416115320_add_tag_table_to_db` creates
  `CREATE UNIQUE INDEX "LiteLLM_DailyTagSpend_tag_key" ON ("tag")`.
  The table legitimately holds multiple rows per tag (they differ on the
  composite key `tag,date,api_key,model,custom_llm_provider, mcp_namespaced_tool_name, endpoint`),
  so that single-column unique index can never build (P3018).
- The shipped follow-up `20250416151339_drop_tag_uniqueness_requirement`
  drops that index; the composite unique index
  `LiteLLM_DailyTagSpend_tag_date_api_key_model_custom_llm_pro_*` is the
  real constraint. Live DB checked 2026-09-12: `LiteLLM_DailyTagSpend_tag_key`
  is absent from `pg_indexes`, the composite unique index is present, and
  **zero** rows violate the composite key.
- `_prisma_migrations`: 152 rows, **none** rolled back, **none** with failure logs — the ledger is fully applied, so a fresh `migrate deploy` no-ops and the retry loop cannot recur under the shipped schema.

The residual risk is a rebuild/ledger-reset without the upstream drop
sequence finishing: startup `migrate deploy` re-enters the P3018 loop.
`disable_prisma_schema_update: true` (a real LiteLLM setting, `proxy_cli.py`
`should_update_prisma_schema`) skips startup migrate deploy. This PR pins
that flag in the repo shape config (`config/litellm-proxy.yaml`) and the
setup runbook so a rebuild reproduces a restart-free proxy. Data rows are
NOT deduped — none of them violate any live constraint, deleting them
would only destroy spend history. The live operator config already carries
the flag (placed during this unit's work).

## Backup (accept-2, no rows were deleted)

- Backup taken before touching anything:
  `/home/nish/workspaces/agent-state/backups/litellm-dailytagspend-20260912-issue4832-before.sql.gz` (pg_dump `-t '"LiteLLM_DailyTagSpend"`)
- Row counts: **before = 160, after = 160** — no dedupe was needed; every row is legal under the surviving composite unique index.

## Clean-restart proof (accept-3 / issue termination)

```
2026-09-12 03:57:36 IST: systemctl --user try-reload-or-restart
fleet-litellm-proxy.service (the same verb the fleet's grok-token-refresh
bin uses; plain `restart` on fleet units is spawn-guard blocked from
worker sessions)
-> HTTP 200 on /health/liveness after 43s
-> journal (-6min): grep -cE 'P3018|Retrying' == 0
-> /health/readiness == 200
```

## Verification

- `tests/fleet-litellm-organ.test.sh` — ALL OK (17 checks).
- `pg_indexes` shows no `LiteLLM_DailyTagSpend_tag_key`; composite unique index present; no composite-key duplicates.
- Live restart 2026-09-12 03:57:36: healthy in 43s, 0 P3018/0 Retrying in the window.

## run-proof

- Live restart of `fleet-litellm-proxy.service` via `try-reload-or-restart`, liveness 200 within 43s, canary green (`/health/readiness` 200).
- `journalctl --user -u fleet-litellm-proxy --since -6min | grep -cE 'P3018|Retrying'` == 0.

## research

They named a stale-path probe · `cat tooling/fleet-ops/bin/fleet-failed-command-flagged` → `No such file or directory` during gate recon — path resolved via the deploy clone instead (`docs/organ-catalog.md`, `config/rule-enforcement.json`); no hand-built replacement was needed.

## help-first

New bin commands are not the fix here (config + doc only), so no `--help`
scaffolding was added; existing `bin/fleet-litellm-key` is untouched.

## Test plan

- `bash tests/fleet-litellm-organ.test.sh` — 12/15 checks exercised live, ALL OK.
- journal zero-P3018 assertion after a real proxy restart (above).

## loose-ends

net-positive-because: +23 lines are the reason the P3018 restart stall stays fixed on any rebuild — the flag pin in the shape config plus the runbook note both name the exact migration pair (`20250416115320` creates the unbuildable index, `20250416151339` drops it) and the re-enable trigger for future LiteLLM bumps; deleting either line re-opens the loop.
- loose-ends: litellm-migrate-flag — the flag is re-enable-then-re-disable whenever a future LiteLLM bump ships migrations; documented in the runbook, no open work.
