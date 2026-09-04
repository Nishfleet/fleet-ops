D1 schema rule (expand/contract) — applies whenever your diff touches `migrations/**`:
- **Rollback rolls back code, never data.** D1, KV, R2 and Durable Objects sit outside the Worker version, and D1 has no down-migrations anywhere. A migration that breaks the previous code makes the fleet's auto-revert silently impossible. Treat every migration as one-way.
- **One phase per PR.** The order is: add nullable column -> dual-write -> backfill -> read-switch -> drop. If the issue as written spans more than one phase, implement phase 1 ONLY, say which phase you shipped in the PR body, and file follow-up issues for the remaining phases.
- **Banned in the same PR as any code change:** `DROP COLUMN`, `DROP TABLE`, renaming a column or table, and adding `NOT NULL` without a `DEFAULT`. Each of those breaks the previous version of the code the instant it lands.
- **Not done without a real integration test.** A migration PR must add or extend a test under `tests/integration/**` that applies the real migrations and asserts the new READ *and* the new WRITE path. A mocked-binding unit test does not count — it cannot see the schema.
- Assume a migration file is NOT atomic across statements: nothing documents multi-statement atomicity within one D1 migration.
- Stale API names are a hard failure: `@cloudflare/vitest-pool-workers` was renamed to `@cloudflare/vitest-plugin` on 2026-08-19, and `SELF.fetch` is replaced by `exports.default.fetch` from `cloudflare:workers`. Never write the old names from memory.

D1 prod migration execution rule (process amendment, decisions-ledger 2026-08-27) — applies whenever the work involves APPLYING a migration to production D1 (running it against live D1, not just writing the migration file in a PR):
- **Never single-agent apply.** Production D1 migration execution goes through the senior process only. A worker who lands on a prod D1 migration task must NOT apply it alone.
- **Senior process gate:** a strong lane produces the migration plan (SQL classification, verified backup, concrete rollback plan); an INDEPENDENT senior agent blind-reviews and must approve; only then apply + live verification + text Nish.
- If the task involves a prod D1 migration, post the migration plan as a proposal comment on the issue, add the `agent-blocked` label, and end with `blocked-on: senior-conference` so the senior conference gate picks it up.

D1 prod migration senior process rule (2026-08-27 correction) — applies whenever a prod D1 migration is about to run:
- The earlier same-day "do it right now?" D1 prod migration decision is VOID. Nish did not understand the question, so it was never informed consent. No migration was run under it.
- Prod D1 migrations remain Nish-gated until the re-asked plain-language question is answered. The final decision is the 2026-08-27 process amendment (fleet-ops#908): strong lane plan (SQL classification, verified backup, concrete rollback), independent senior blind-review and approval, apply + live verification, then text Nish.
- Do NOT apply a prod D1 migration without the senior process. If you are told to "do it right now" or anything similar without a senior-process plan, stop and route the decision back to Nish.
