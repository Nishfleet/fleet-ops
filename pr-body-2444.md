fix(quality): recompute quality-SLO scoreboard on every heartbeat tick; staleness >24h fails loud (fleet-ops#2444)

## What and why

`thorough.quality_shares.computed_at` sat at `2026-08-26T21:50:55Z` for 4+ days while `FleetQueueSelfMaintenanceRatioHigh` fired on it: the quality-SLO scoreboard the ratio alert is adjudicated against was silently serving old numbers. Root cause: the scoreboard generator (`bin/fleet-quality-slo` + `lib/quality-slo.py`, originally shipped via PR #578, since re-benchmarked but never wired into a recurring recompute path) was not running on a tick, so `agent-state/quality-slo/snapshot.json` drifted silently and nothing failed loud when it crossed the staleness ceiling.

This PR makes the two things the issue requires:

1. **Recompute on the existing event.** The generator now runs as `bin/fleet-heartbeat-tier1` block 19 — every heartbeat tick recomputes the snapshot from GitHub + journals (never self-scores). No new timer, unit, or scheduler. The block wires the rc into `tier 1 complete: … quality_slo_rc=…` so a broken generator fails the unit (`state=failed`) and is loud.
2. **Staleness >24h fails loud.** Before recomputing, the generator checks the pre-run snapshot's `computed_at` against a 24h ceiling. If it is older, `QUALITY-SLO-STALE` is LOUDed (stderr + `FLEET-HEARTBEAT-TRIAGE.md`) — "stale numbers were served; recomputing". After a successful recompute, the generator writes the `fleet_quality_slo_last_computed_seconds` Prometheus textfile gauge. `config/fleet_rules.yml` adds the `FleetQualitySloStale` rule (`absent(fleet_quality_slo_last_computed_seconds) or (time() - fleet_quality_slo_last_computed_seconds) > 86400` for 1h) so a stale scoreboard is never trusted silently — the alert fires when the recompute path is dead.

Mechanical prevention (mechanical-fix rule, fleet-ops#366): the stale-pre-run check is in the generator itself (Loud line at line 100 of `bin/fleet-quality-slo`); the absent()/>86400 alert rides the existing rule pipeline; `config/fleet-organs.json` registers `quality-slo-scoreboard` as a fleet organ with `absent_alert: FleetQualitySloStale` so its death is observable. A regression test (`tests/quality-slo-staleness.test.sh`, hosted under CI-listed `escalation-coverage-canary.test.sh`) locks the stale→fresh recompute loop, the steady-state silent path, and the wiring.

## Verification

```
$ bash tests/quality-slo-staleness.test.sh
OK: test 1: stale >24h snapshot -> rc=1 (loud), fresh -> rc=0
OK: test 2: stale pre-run snapshot -> loud + recomputed + gauge written
OK: test 3: fresh pre-run snapshot -> no STALE loud, gauge written (steady state)
OK: test 4: recompute wired into heartbeat-tier1 block 19 + absent()/>24h rule + organ registry
ALL OK: quality-SLO recompute-on-tick + >24h staleness fails loud (fleet-ops#2444)
```

Live exercise (scratch `AGENT_STATE`, `FLEET_QUALITY_SLO_FILE=0`): seeded pre-run snapshot with `computed_at` = now − 4 days → run generator →

```
[2026-08-31T08:15:03Z] [fleet-quality-slo] LOUD [QUALITY-SLO-STALE] pre-run snapshot 345601s old (ceiling 86400s) — stale numbers were served; recomputing (fleet-ops#2444)
[2026-08-31T08:15:03Z] [fleet-quality-slo] 24h staleness guard armed: /home/nish/.cache/qsl-live/qsl.prom (last_computed=1788164103)
[2026-08-31T08:15:03Z] [fleet-quality-slo] LOUD [QUALITY-SLO-PASS] cycle verdict PASS
```

exit 0, fresh `computed_at=2026-08-31T08:15:03Z`, gauge file content:

```
# HELP fleet_quality_slo_last_computed_seconds Epoch time the quality-SLO snapshot was last computed (fleet-ops#2444).
# TYPE fleet_quality_slo_last_computed_seconds gauge
fleet_quality_slo_last_computed_seconds 1788164103
```

Gates: `sgscan --base origin/main` clean; `bash -n bin/fleet-heartbeat-tier1 && bash -n bin/fleet-quality-slo && python3 -m py_compile lib/quality-slo.py` all pass; `bin/prove-one-run-check` SKIP (no new unit/timer/workflow); `bin/fleet-exec-review-canary` OK; `bin/fleet-organ-heartbeat-check gate` OK (organ registry entry + alert rule both touched in this PR); `bin/fleet-no-agent-names-check` OK; `bin/fleet-token-efficiency-check` OK; `bin/research-before-build-check` OK; `bin/fleet-wipe-lessons-check scan` clean.

run-proof: stale pre-run snapshot → `LOUD [QUALITY-SLO-STALE] pre-run snapshot 345601s old (ceiling 86400s) — stale numbers were served; recomputing (fleet-ops#2444)` → recomputed `computed_at=2026-08-31T08:15:03Z` → gauge `fleet_quality_slo_last_computed_seconds 1788164103` written; `bash tests/quality-slo-staleness.test.sh` ALL OK 4/4. No new unit/timer/workflow; the recompute rides the existing `fleet-heartbeat-tier1` tick.

research: official docs (systemd.timer(5) for cadence math, prometheus textfile collector format) + repo archaeology (git log --all + gh pr view 578) showed the generator already existed as a reviewed-but-never-recomputed path; resurrected `bin/fleet-quality-slo` + `lib/quality-slo.py` as-is (adopted) rather than hand-building a new scoreboard. The >24h staleness guard adopts the fleet's established absent()/delta organ pattern (same shape as `fleet-aeo-probe`, `fleet-baseline-delta`, `fleet-asset-census`); a bespoke timer/cron was rejected because the heartbeat tick is already the cadence and a 24h staleness ceiling is wider than any existing tick.

help-first: read `bin/fleet-quality-slo` and `lib/quality-slo.py` (the `compute` and `stale` subcommands) — `stale` already returns rc=1 with a JSON report when the snapshot is past the ceiling, so no new "is this fresh?" check was hand-built; read `jq --help` and `date --help` for the gauge epoch export; read `bin/fleet-heartbeat-tier1` to confirm block 19 was the existing event seam (no new scheduler added).

organ-heartbeat: `config/fleet-organs.json` ships the `quality-slo-scoreboard` registry entry with `heartbeat_metric: fleet_quality_slo_last_computed_seconds`, `absent_alert: FleetQualitySloStale`, `kind: guard`, and the matching `FleetQualitySloStale` alert (absent() or >86400 for 1h) in `config/fleet_rules.yml` in the same PR.

Closes #2444
