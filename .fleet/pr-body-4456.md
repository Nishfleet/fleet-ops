## Why

The fleet's loop watches delivery (merges, defects) but never a product OUTCOME — nothing answered "did 0509 gain a user". The judge's motives are quality > 300/day > efficiency; none is signups. The fleet can hit 300 merges/day with zero users and every gate stays green. fleet-ops#4456.

## What

Wire 0509's OWN telemetry (D1: `user`, `user_plan`, `delivery_attempt`) into the existing product-slo exporter rail. No new timer, no new organ.

**Repo (this PR):**
- `lib/fleet-product-slo.py` exports four new product-OUTCOME gauges:
  - `fleet_product_signups_24h` — users created in 0509 D1, trailing 24h
  - `fleet_product_activated_24h` — signups whose first SENT brief arrived ≤5 min
  - `fleet_product_paying_customers_total` — users on a non-free plan
  - `fleet_product_briefs_delivered_24h` — sent deliveries, trailing 24h
- Source: 0509 D1 read over the Cloudflare D1 REST API with the sanctioned VPS token (`~/.config/cloudflare/deploy-ci.env`, fleet-ops#1166). **When the source is unreachable the gauges are emitted ABSENT — never a fabricated 0** (Prometheus `absent()` surfaces the gap). Cited source: 0509 `migrations/0000_auth.sql` (`user`), `migrations/0006_plan.sql` (`user_plan`), `delivery_attempt` (`app/`).
- `tests/fleet-product-slo.test.sh` — proves outcome gauges ARE emitted with real values when reachable, and are ABSENT (not 0) when unreachable.
- Backfill of the judge packet and measure.sh are runtime files under `agent-state/fleet-landing-watch/` (hand-placed, outside this repo — same as the retired opus-heartbeat, archive/opus-heartbeat-retired-2026-09-07/README.md).

**Runtime (applied this run, not tracked in repo):**
- `measure.sh`: new `product: signups=0 activated=0 paying=6 briefs_delivered_24h=12` line (D1-sourced; `UNAVAILABLE:<why>` when unreadable, never 0).
- `fable-check.md` judge packet: product outcome is now the FIRST number read in the header, with the "two runs of signups=0 while product merges > 20 → name 'shipping without users' and stop treating merges as progress" rule.

**#1872 re-queue (Do 4):** already satisfied by live flow — Nishfleet/0509#1872 is OPEN, `agent-in-progress`, actively claimed by a live worker `pi-issue@0509-1872.service` (session growing as of 2026-09-08). Not double-claimed.

**Source citation:** 0509 D1 database `746c6e3d-…` (account `f670a698-…`); tables `user` (auth, migrations/0000_auth.sql), `user_plan` (0006_plan.sql), `delivery_attempt` (delivery). Accessed via `~/.config/cloudflare/deploy-ci.env` `CLOUDFLARE_API_TOKEN` (fleet-ops#1166).

## Scope

- Exporter + test only in this repo. measure.sh / fable-check.md are untracked runtime state; their edits are applied in this run and documented.
- No new timer, unit, workflow, or organ. Product-slo piggybacks `fleet-metrics-export.service` (existing rail, fleet-ops#2755).

## Verification

`bash tests/fleet-product-slo.test.sh` — ALL PASS (incl. new `(e)` absent-when-unreachable and `(o)` emitted-with-real-values):

```text
OK: (e) empty window emits heartbeat + zeros; unreachable outcome source stays absent
OK: outcome gauges emitted from a reachable source
OK: (o) outcome gauges emitted with real values when the source is reachable
...
OK: fleet-product-slo: throughput, lead-time-excludes-reverts, revert-rate, intake list, MANIFEST, rules, organ, console source
```

Live exporter run (worktree code, real D1):

```text
fleet_product_signups_24h 0
fleet_product_activated_24h 0
fleet_product_paying_customers_total 6
fleet_product_briefs_delivered_24h 12
```

`sgscan` (origin/main..HEAD): `No new security findings.`

Accept criterion 1 — `bash measure.sh | grep -E '^product:'`:

```text
product: signups=0 activated=0 paying=6 briefs_delivered_24h=12
```

Accept criterion 2 — fleet-metrics prom file carries `fleet_product_signups_24h` (present when the worktree code runs; goes live after merge+deploy). UNAVAILABLE path proven: with the token file absent the line prints `signups=UNAVAILABLE:no-cf-token …` (never 0).

## run-proof

- `bash tests/fleet-product-slo.test.sh` (hosted by ci-standards-audit) — one green run, ALL PHASES PASSED
- `sgscan` — No new security findings
- `/var/lib/prometheus/node-exporter/fleet-product-slo.prom` written with `fleet_product_*` gauges from a live D1 read (transient — re-overwritten by the running exporter's pre-merge code)
- `bash measure.sh | grep -E '^product:'` → `signups=0 activated=0 paying=6 briefs_delivered_24h=12`

## net-positive-because

net-positive-because: 238 net lines add product-OUTCOME observability that directly feeds the judge header and weekly fleet review — the issue's whole point is a durable product-outcome number in the loop, which no existing metric measured.

## Closes #4456
