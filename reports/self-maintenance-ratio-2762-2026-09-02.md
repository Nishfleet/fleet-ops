# Self-maintenance ratio 0.75-0.77 — queue quantification + close-duplicates first run (fleet-ops#2762)

Report date: 2026-09-02
Issue: fleet-ops#2762 — FleetQueueSelfMaintenanceRatioHigh firing since 2026-08-29T04:00:44Z,
FleetSelfMaintenanceRegression since 2026-09-01T05:26:12Z. Ask: quantify the agent-ready
queue split (self vs product) and close the duplicate self-repair items.
Host: netcup-rs2000

## Live quantification (2026-09-02T20:00Z, after this run's closes)

Open `agent-ready` issues by repo:

- fleet-ops: 17 — all fleet self-repair (seat corpses/credential walls, main-CI-red,
  gap-audit, heartbeat, queue/ratio). Was 19 before the closes below.
- 0509: 10 (product-repo work). inish-site: 1. Total: 28.

Instant self fraction = **17/28 = 0.607**, below the 0.64 alert threshold. The
7d-average integrators still read 0.750 (agent-ready) / 0.770 (ready-work) —
lagging window (fleet-ops#2171) — so the alerts keep firing until the window
drains. Same live state as the sibling reports (fleet-ops#2729 report
2026-09-02: 17/28 agent-ready; fleet-ops#2906 report: 19 fleet-ops + 10 0509 + 1 inish-site),
with counts drifting as auto-filers land.

Merges (24h, exporter snapshot): self 18 / product 13 / total 31 = 0.58.

## Close-duplicates drain — first real run

The drain merged in PR #2900 (close-duplicates subcommand in lib/issue-file.py,
heartbeat block 21) had never executed against the live queue: the deploy-clone
is deploy-blocked (below), so production block 21 has not run. This report runs
the merged code (origin/main @ c0143349) directly.

Dry-run first (zero writes): 14 clusters, 2 agent-ready closes, 36 protected
comment-only markers.

Real run (`FLEET_CLOSE_DUPLICATES_OK=1 python3 lib/issue-file.py close-duplicates -R Nishfleet/fleet-ops`):

- CLOSED fleet-ops#2816 -> #1296 (score 0.91) — main-CI-red duplicate
- CLOSED fleet-ops#2849 -> #1296 (score 0.91) — main-CI-red duplicate
- 36 duplicate-of marker comments on protected members (agent-in-progress /
  agent-blocked untouched — no active work or Nish-gated item was closed)
- Re-dry-run after the run: 0 further closes — idempotent, backlog exhausted

The two closes are exactly the repeated-claim lines the alert flagged: fleet-ops
only, claims not converging because duplicates sat agent-ready and were
re-claimed. Both closed with evidence comments.

## Remaining levers (already filed elsewhere)

- Production cadence of the drain: heartbeat block 21 cannot run while the
  deploy-clone is dirty / off-main. deploy-audit.log shows repeated
  `deploy-blocked why="dirty tracked files; checkout on fix/gap-closure-drill-method
  not main"` since at least 2026-09-02T17:45Z. Trackers: fleet-ops#2858 (deploy
  block), fleet-ops#2910 (deploy-clone reset wipes the live seat-caps hot-patch;
  durable fix PR #2835 P14-blocked, grok restore #2839 waiting on Nish).
- Seat-corpse / seat-availability cluster scores below the 0.65 token-overlap
  threshold — semantic clustering follow-up fleet-ops#2899.
- Seat corpses are money/credentials (Nish-reserved, fleet-ops#2667).

## Verification

- `gh search issues --label agent-ready --state open` per repo before/after:
  fleet-ops 19 -> 17, 0509 10, inish-site 1, total 28.
- Drain dry-run then real run transcripts: output JSON `closed=2 commented=36
  dry_run=false ok=true`; re-run dry-run `closed=0`.
- `gh issue view 2816/2849` — state CLOSED, stateReason COMPLETED, last comment
  "Closing as duplicate of Nishfleet/fleet-ops#1296 (score=0.91)".
- Prometheus (live): `avg_over_time(fleet_queue_self_maintenance_ratio[7d])` =
  0.7503 (agent-ready) / 0.7700 (ready-work); both FleetQueueSelfMaintenanceRatioHigh
  still firing at those values (expected lagging integrator).