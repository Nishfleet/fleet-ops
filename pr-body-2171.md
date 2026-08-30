## What changed

FleetQueueSelfMaintenanceRatioHigh sat pending for ~21h and never fired: the rule demanded the raw gauge sit above 0.64 for 7 uninterrupted wall-clock days (`for: 1w`). The ratio dips whenever product issues land in the queue, and the series goes stale on every >5m export gap (it is only exported when total>0) — either event resets the `for:` timer, so the pending state could not reach firing and no alert-repair chain hop ever opened.

The fix keeps the level tripwire (0.64, the fleet2 death-number — Nish's policy, not a delta) but evaluates it on the smoothed 7-day window that the routing comment always intended:

- `expr: avg_over_time(fleet_queue_self_maintenance_ratio[7d]) > 0.64` — the trailing-week average absorbs momentary dips and export gaps, so the breach stays continuously true instead of resetting.
- `for: 6h` — certifies the smoothed breach is steady before dispatching; matches the sibling regression-trend rules' cadence.

Live grounding (this host, 2026-08-30): both queues have been 100% above 0.64 on every evaluation since the metric first exported (~22h of data), longest contiguous true-run 22.2h — short of the 1w `for:` no matter what. The trailing-7d mean is stable at ~0.87–0.89, so under the new rule the alert transitions pending→firing within 6h of the rules reload.

Not silenced: severity stays warning, service stays fleet, the alert still feeds Weekly Review scoring and the precedence-sunset question, and alert-repair-dispatch has no SKIP entry for it, so a firing breach opens a repair chain hop.

Also aligned the exporter's two doc comments (which described the rule as a TREND offset-7d alert) with the actual 7d-smoothed level shape.

## Prevention mechanism (fleet-ops#366)

The reverted class — instant value + long `for:` that never fires — is locked by a new `promtool test rules` unit test in `tests/fleet-metrics-export.test.sh`: a realistic series (ratio mostly 0.85 with recurring 0.50 dips) must reach firing within `for: 6h`. Verified both directions: the new shape passes, and the same test against the old `expr: ... > 0.64` + `for: 1w` shape FAILS (no alert at eval 12h). The grep lock was updated to the new expr so a stale `> 0.64` level cannot be reintroduced.

## Verification

Real runs, this worktree:

- `promtool check rules config/fleet_rules.yml` -> `SUCCESS: 50 rules found`
- `promtool test rules` unit test (smoothed 7d window + recurring dips) -> `SUCCESS` — the alert fires at eval 12h; same test against the OLD rule shape -> `FAILED` (got: [] — no firing)
- `bash tests/fleet-metrics-export.test.sh` -> exit 0, 20 OK (incl. the new unit-test gate)
- sibling rules tests all pass: fleet-rules-severity-page, scout-futility, fleet-waste-ledger, console-tile-verify, fleet-gh-cache-stale
- `python3 -m py_compile libexec/fleet-metrics-export.py` -> OK
- live prometheus (localhost:9090): rule currently `pending`; both queues' avg_over_time[7d] = 0.874/0.888 > 0.64, stable

run-proof: promtool test rules unit test SUCCESS (test yml generated at test time from config/fleet_rules.yml); live-rule state + avg[7d] values from `curl localhost:9090/api/v1/rules` and `api/v1/query_range` (2026-08-30T02:00Z).

Closes #2171
