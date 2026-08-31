# Audit — 0509#1430 re-sweep runs on a Cloudflare cron trigger, not a hand-rolled loop

Audit owner: Nishfleet/fleet-ops#2137 (WFR 2026-08-29, lens-2 quality)
Subject: Nishfleet/0509#1430 — `feat(auto-competitor): periodic re-sweep for
newly-appearing competitors (Phase 3 #1371)`, merged 2026-08-28T23:37:43Z
(+671/-0, 6 files).
Date: 2026-08-31
Auditor: fleet-ops pi-issue worker, unit `pi-issue-fleet-ops-2137`

## What this audit is

Ledger 2026-08-26 banned hand-built plumbing — "no hand-rolled
… pollers, queue daemons, or watchdog scripts. Composition is systemd
primitives + GitHub-inbuilt gates." A periodic re-sweep is exactly the
shape that ban covers; this audit verifies 0509#1430 lands on a platform
timer, not a `setInterval` / `while (true)` / `sleep()` polling loop.

The issue's acceptance criteria are deterministic (no AI-advisory):

1. Grep the re-sweep trigger for a timer/schedule binding (systemd
   timer, GitHub `on: schedule:`, or a fleet-ops cron unit).
2. Grep the re-sweep code for hand-rolled loop patterns
   (`setInterval`, `while (true)`, `sleep(`-based polling) — must find
   NONE.
3. If hand-rolled: redirect to an existing timer organ (no new
   machinery).

The issue's termination command is:

```
grep -rn "setInterval|while (true)|sleep(" <re-sweep-path>
```

returns 0 matches AND a timer/schedule binding is named.

## Verdict

**COMPLIANT.** The re-sweep runs on the existing Cloudflare Workers
cron trigger surface (no new dispatcher, no new machinery). The
termination grep returns zero matches; the timer/schedule binding is
named below.

## Method

1. Identify the re-sweep surface in 0509#1430 — the new file
   `app/lib/auto-competitor-resweep.server.ts` plus three call-site
   mods (`workers/schedule.ts`, `workers/app.ts`,
   `app/lib/monitoring.server.ts`), the new integration test
   (`tests/integration/auto-competitor-resweep.integration.test.ts`),
   and the schedule shape test (`tests/worker-schedule.test.ts`).
2. Run the issue's termination grep against every file in the re-sweep
   path on the merged tree (origin/main @ 3fa2cbe9).
3. Walk the cron trigger wiring end-to-end from `wrangler.jsonc`
   `triggers.crons` to the actual `runAutoCompetitorResweep` call.
4. Check that the in-file `for (const userId of userIds)` loop is a
   finite per-customer iteration, not an indefinite poll.

## Evidence

### 1. Termination grep — zero matches

Files in scope (6 added/modified by #1430):

- `app/lib/auto-competitor-resweep.server.ts` (new, 373 lines)
- `app/lib/monitoring.server.ts` (modified, +15)
- `tests/integration/auto-competitor-resweep.integration.test.ts` (new, 273 lines)
- `tests/worker-schedule.test.ts` (modified, +4)
- `workers/app.ts` (modified, +1)
- `workers/schedule.ts` (modified, +5)

```
$ grep -rnE "setInterval|while \(true\)|sleep\(" \
    app/lib/auto-competitor-resweep.server.ts \
    workers/app.ts \
    workers/schedule.ts \
    app/lib/monitoring.server.ts \
    tests/integration/auto-competitor-resweep.integration.test.ts \
    tests/worker-schedule.test.ts
(no output; exit 1 — zero matches)
```

The only `for`/`while` patterns in the re-sweep surface are:

- `app/lib/auto-competitor-resweep.server.ts:162` — `for (const c of
  candidates)` (finite set walk inside `dedupeAutoCompetitorCandidates`).
- `app/lib/auto-competitor-resweep.server.ts:194` — `for (const
  candidate of seedCandidates)` (finite set walk inside
  `resweepAutoCompetitors`).
- `app/lib/auto-competitor-resweep.server.ts:253` — `for (const c of
  previousSurfaced)` (finite set walk to populate `surfacedDomains`).
- `app/lib/auto-competitor-resweep.server.ts:342` — `for (const userId
  of userIds)` (finite per-paid-workspace iteration; the list itself
  is bounded by `LIMIT 10_000` on the SQL query at line ~322, and the
  cron tick is the only entry point).

None of these are polling loops. Each runs once per cron tick to
completion and returns.

### 2. Timer/schedule binding — Cloudflare Workers cron trigger

#### 2a. Cron expression in `wrangler.jsonc`

```
$ grep -A3 triggers /home/nish/workspaces/products/0509/wrangler.jsonc
  "triggers": {
    "crons": ["13 * * * *", "17 */6 * * *", "0 */3 * * *", "0 4 * * *", "0 5 * * MON"]
  },
```

`"0 4 * * *"` matches `DAILY_DIGEST_CRON` (the daily-digest schedule)
in `workers/schedule.ts`:

```
$ grep DAILY_DIGEST_CRON /home/nish/workspaces/products/0509/workers/schedule.ts
export const DAILY_DIGEST_CRON = "0 4 * * *";
```

#### 2b. `resolveScheduledTask("0 4 * * *")` enables the resweep

`workers/schedule.ts` (origin/main):

```ts
if (cron === DAILY_DIGEST_CRON) {
  return {
    kind: "monitoring",
    includeScans: false,
    includeDigests: true,
    includeMentionResweep: false,
    includeAutoCompetitorResweep: true,   // <-- 0509#1430 added this
    includeRiskAlert: true,
    digestCadence: "daily",
    digestLookbackDays: 1,
  };
}
```

#### 2c. `workers/app.ts` passes it through `runScheduledMonitoring`

`workers/app.ts` (`scheduled` handler, lines ~352–360):

```ts
ctx.waitUntil(
  observe("scheduled_monitoring", runScheduledMonitoring(env, {
    includeScans: scheduledTask.includeScans,
    includeDigests: scheduledTask.includeDigests,
    includeMentionResweep: scheduledTask.includeMentionResweep,
    includeAutoCompetitorResweep: scheduledTask.includeAutoCompetitorResweep,
    digestCadence: scheduledTask.digestCadence,
    digestLookbackDays: scheduledTask.digestLookbackDays,
    cron: controller.cron,
    scheduledTime: controller.scheduledTime,
    executionContext: ctx,
  })),
);
```

#### 2d. `runScheduledMonitoring` invokes `runAutoCompetitorResweep`

`app/lib/monitoring.server.ts` (`runScheduledMonitoring`, lines ~448–460):

```ts
let autoCompetitorResweep: AutoCompetitorResweepResult | undefined;
if (options.includeAutoCompetitorResweep) {
  const { runAutoCompetitorResweep } = await import(
    "~/lib/auto-competitor-resweep.server"
  );
  autoCompetitorResweep = await runAutoCompetitorResweep(env);
  if (
    autoCompetitorResweep &&
    (autoCompetitorResweep.newlyAppeared > 0 ||
      autoCompetitorResweep.errors > 0)
  ) {
    console.log("auto competitor resweep completed", autoCompetitorResweep);
  }
}
```

The resweep is dynamic-imported so the daily-digest path stays lean.
It runs through the existing `runScheduledMonitoring` monitoring
fan-out scheduling surface — no new dispatcher, no new cron, no new
timer.

### 3. End-to-end wiring (file/line trace)

```
wrangler.jsonc "triggers.crons" = ["13 * * * *", "17 */6 * * *", "0 */3 * * *", "0 4 * * *", "0 5 * * MON"]
                                          └─────── "0 4 * * *" matches
                                                  workers/schedule.ts:DAILY_DIGEST_CRON
                                                                 │
                                                                 ▼
                                          workers/schedule.ts:resolveScheduledTask("0 4 * * *")
                                            returns { kind: "monitoring", includeAutoCompetitorResweep: true, … }
                                                                 │
                                                                 ▼
                                          workers/app.ts:async scheduled(controller, env, ctx)
                                            observe("scheduled_monitoring",
                                              runScheduledMonitoring(env, { includeAutoCompetitorResweep: true, … }))
                                                                 │
                                                                 ▼
                                          app/lib/monitoring.server.ts:runScheduledMonitoring
                                            if (options.includeAutoCompetitorResweep)
                                              const { runAutoCompetitorResweep } = await import(
                                                "~/lib/auto-competitor-resweep.server")
                                              autoCompetitorResweep = await runAutoCompetitorResweep(env)
                                                                 │
                                                                 ▼
                                          app/lib/auto-competitor-resweep.server.ts:runAutoCompetitorResweep
                                            SELECT DISTINCT user_plan.user_id FROM … LIMIT 10_000
                                            for (const userId of userIds) { … }   // finite, per-tick
```

All five steps reuse existing organs:

- The Cloudflare cron trigger (platform primitive, not hand-rolled).
- `runScheduledMonitoring` (existing monitoring fan-out, in-tree since
  pre-#1430).
- The discovery cache (existing Phase 1 storage; the resweep reuses it
  as the surfaced-candidate store per the PR description — no new
  table).
- `MONITORING_FANOUT_MODE` gating (existing env-driven fan-out
  dispatcher).
- Paid-tier gating via `isPaidPlanFamily` (existing plan-entitlements
  helper).

The PR is +671/-0 with no `setInterval`, `while (true)`, `sleep(`,
`new cron`, `new dispatcher`, `new timer`, or `new table` introduced.

### 4. The re-sweep `for` loop is bounded, not polling

`runAutoCompetitorResweep` line ~322:

```ts
const limit = options.userLimit ?? 10_000;
const rows = await many<{ user_id: string }>(
  env,
  `
    SELECT DISTINCT user_plan.user_id
    FROM user_plan
    INNER JOIN workspace_branding ON workspace_branding.user_id = user_plan.user_id
    WHERE user_plan.plan != 'free'
      AND workspace_branding.brand_website IS NOT NULL
      AND TRIM(workspace_branding.brand_website) != ''
    ORDER BY user_plan.user_id
    LIMIT ?
  `,
  limit,
);
userIds = rows.map((row) => row.user_id);
result.users = userIds.length;

for (const userId of userIds) { … }
```

`userIds.length ≤ 10_000`. The cron tick is the only entry point. The
loop walks the list once and returns. Not a polling loop.

## Why this is fine against the ban

The 2026-08-26 hand-built plumbing ban targets ad-hoc retry loops,
cooldown timers, pollers, queue daemons, and watchdog scripts — code
that *invents its own scheduling*. 0509#1430 does the opposite: it
piggybacks on `wrangler.jsonc` `triggers.crons` (the platform's own
timer primitive) and on `runScheduledMonitoring` (the existing
monitoring fan-out entry). No new scheduling surface was created. The
new file `auto-competitor-resweep.server.ts` is pure logic plus one
bounded per-tick iteration; it has no timer, no poller, no sleep.

## Termination evidence (the issue's own acceptance)

- `grep -rnE "setInterval|while \(true\)|sleep\(" <re-sweep-path>` →
  0 matches across all 6 files in scope.
- A timer/schedule binding is named:
  `wrangler.jsonc:triggers.crons["0 4 * * *"]` →
  `workers/schedule.ts:DAILY_DIGEST_CRON` →
  `resolveScheduledTask("0 4 * * *")` →
  `runScheduledMonitoring` →
  `runAutoCompetitorResweep`.

Both termination conditions hold.

## Findings

- None — the PR is compliant on both axes.

## Provenance

- Issue: Nishfleet/fleet-ops#2137 (WFR 2026-08-29 lens-2 quality).
- Audited PR: Nishfleet/0509#1430, merged 2026-08-28T23:37:43Z, merge
  commit `3fa324fa` on `origin/main` (verified at `3fa2cbe9` on
  2026-08-31).
- Source paths inspected: 0509 `origin/main` (HEAD `3fa2cbe9`),
  local mirror at `/home/nish/workspaces/products/0509`.
- Grep commands run: deterministic, re-runnable, attached above.
- Auditor session: pi-issue worker, unit `pi-issue-fleet-ops-2137`.
