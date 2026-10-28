# D1 migrations

The four D1 rules live in `AGENTS.md` → "D1" as one-line pointers. This file holds
the reasoning and the exact wording, so `AGENTS.md` stays short without a rule
being lost. Issue: nish-vault#46 item 4.

## Expand/contract, one phase per PR

**Rollback rolls back code, never data.** D1, KV, R2 and Durable Objects sit
outside the Worker version, and D1 has no down-migrations anywhere. A migration
that breaks the previous code makes the fleet's auto-revert silently impossible.
Treat every migration as one-way.

The order is:

1. add nullable column
2. dual-write
3. backfill
4. read-switch
5. drop

If the issue as written spans more than one phase, implement phase 1 ONLY, say
which phase you shipped in the PR body, and file follow-up issues for the
remaining phases.

**Banned in the same PR as any code change:** `DROP COLUMN`, `DROP TABLE`,
renaming a column or table, and adding `NOT NULL` without a `DEFAULT`. Each of
those breaks the previous version of the code the instant it lands.

Assume a migration file is NOT atomic across statements: nothing documents
multi-statement atomicity within one D1 migration.

## A migration PR adds a real integration test

The test goes under `tests/integration/**`, applies the real migrations, and
asserts the new READ _and_ the new WRITE path. A mocked-binding unit test does not
count, because it cannot see the schema.

## Applying a migration to production D1 goes through the senior process

Never single-agent apply. The gate:

1. A strong lane produces the migration plan: SQL classification, verified backup,
   concrete rollback plan.
2. An INDEPENDENT senior agent blind-reviews the plan and must approve.
3. Only then apply, verify live, and text Nish.

A worker who lands on a prod D1 migration task posts the migration plan as a
proposal comment on the issue, adds the `agent-blocked` label, and ends with
`blocked-on: senior-conference`, so the issue surfaces as waiting on a senior
decision.

## Stale API names are a hard failure

- `@cloudflare/vitest-pool-workers` was renamed to `@cloudflare/vitest-plugin` on
  2026-08-19.
- `SELF.fetch` is replaced by `exports.default.fetch` from `cloudflare:workers`.

Never write the old names from memory.
