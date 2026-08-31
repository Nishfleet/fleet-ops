## What and why

`thorough.quality_shares.computed_at` sat at `2026-08-26T21:50:55Z` for 4+ days while `FleetQueueSelfMaintenanceRatioHigh` fired on it: the quality-SLO scoreboard the ratio alert is adjudicated against was silently serving old numbers. Root cause: the scoreboard generator (`bin/fleet-quality-slo` + `lib/quality-slo.py`, built in reviewed PR #578) was never merged, so `agent-state/quality-slo/snapshot.json` was a stale one-off and nothing recomputed it.

This PR makes the two things the issue requires:

1. **Recompute on the existing event.** The generator now runs as fleet-heartbeat-tier1 block 19 — every heartbeat tick recomputes the snapshot from GitHub + journals (never self-scores). No new timer or unit.
2. **Staleness >24h fails loud.** The generator louds `QUALITY-SLO-STALE` when the pre-run snapshot exceeds the 24h ceiling, and exports `fleet_quality_slo_last_computed_seconds` to a textfile gauge. A `FleetQualitySloStale` alert (`absent(...) or (time() - ...) > 86400`) fires when the recompute path dies, so a stale scoreboard is never trusted silently.

Also: MANIFEST entries, fleet-organs.json registry entry (20th organ, `absent_alert: FleetQualitySloStale`), and a CI-hosted offline test proving the stale→fresh recompute loop and the guard.

## Verification

`bash tests/quality-slo-staleness.test.sh` → tests 1-4 ALL OK (stale snapshot → rc=1 loudly / fresh → rc=0; generator on a 4-day-old pre-run snapshot louds QUALITY-SLO-STALE, recomputes fresh, writes the gauge; steady-state recompute silent + gauge written; tier1 block + rule + registry wired).

`bash tests/escalation-coverage-canary.test.sh` → nested quality-slo-staleness + other listed tests all pass on this branch.

Live exercise (scratch env, FILE_ISSUES=0): pre-run snapshot 353996s old → `LOUD [QUALITY-SLO-STALE] pre-run snapshot 353996s old (ceiling 86400s) — stale numbers were served; recomputing (fleet-ops#2444)` → new `computed_at` at run time → `fleet_quality_slo_last_computed_seconds 1788135051` written to `$PROM_FILE`.

Gates: sgscan `--base origin/main` clean; bash -n fleet-heartbeat-tier1 + fleet-quality-slo; python3 -m py_compile lib/quality-slo.py; manifest-entry check + organ-heartbeat verify confirm both `bin/fleet-quality-slo` and `lib/quality-slo.py` are wired.

run-proof: none — no new unit/timer/workflow; recompute rides the existing heartbeat tick (prove-one-run-check SKIP).

research: last30days-scale pass = repo archaeology (git log --all + gh pr view 578, live github + local checkouts) — the generator already existed as reviewed-but-unmerged PR #578, so it was resurrected as-is (adopted) rather than hand-building a new scoreboard; the alternative of leaving the orphaned snapshot un-computed was rejected because it leaves a stale scoreboard. The >24h staleness guard adopts the fleet's own established absent()/delta organ pattern (same as fleet-baseline-delta, fleet-scout, fleet-asset-census), rejected building a bespoke timer.

help-first: read bin/fleet-quality-slo + lib/quality-slo.py --help/compute subcommand — it already recomputes on invocation, so no new recompute flag was hand-built; read jq/date --help for the epoch export.

organ-heartbeat: config/fleet-organs.json entry ships with its absent() rule in the same PR.

Closes #2444
