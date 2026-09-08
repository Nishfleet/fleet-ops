## Summary

fleet-ops#4217 step 2 requires: **"Stale (>15 min) => absent, and an absent() alert."** The exporter's quota family emitted `fleet_seat_quota_observed_seconds` but stamped it with *export time* (`now`) instead of the *observation time*, so it was always `0.0000` — a dying fetch that served a 25-min-old cache still looked fresh. The metric that must power the stale-quota alert could never fire because it never reported a real age, and there was no alert rule on it at all.

This closes that acceptance item:

1. **`_cached_quota_json` now returns the true observation timestamp** with the data (fresh fetch → now; stale-cache serve → the cache's own `ts`). `fleet_seat_quota_observed_seconds` therefore reports the real age of each provider's quota figure.
2. **New `FleetSeatQuotaStale` Prometheus alert rule** keys on `fleet_seat_quota_observed_seconds > 900` (15 min = `QUOTA_STALE_S`) `or absent(...)` over 5 min — the "absent() alert" the issue asks for, with severity warning.

No new units, no new organs, no new config keys. Edits inside the existing exporter (`libexec/fleet-metrics-export.py`), the existing alert file (`config/fleet_rules.yml`), and its existing test (`tests/fleet-metrics-export.test.sh`).

net-positive-because: the +110 lines are the durable missing alert capability (truthful observed_seconds stamping + a FleetSeatQuotaStale Prometheus rule + its regression test) that fleet-ops#4217 step 2 requires; it replaces a latent defect (stale quota figures masked as fresh 0s) with a working per-seat stale alert — a permanent instrumentation win, not hand-built orchestration.

## Verification

Live exporter run (read-only caches, temp output — `main()` rc=0):

```
fleet_seat_quota_observed_seconds{provider="codex",source="api"} 27.5930
fleet_seat_quota_observed_seconds{provider="cursor",source="api"} 27.2553
fleet_seat_quota_observed_seconds{provider="devin",source="api"} 143.4804
fleet_seat_quota_observed_seconds{provider="xkiro",source="api"} 27.0372
```

The values now reflect the real cache age (pre-fix: all `0.0000` regardless of data age). A provider whose fetch dies and serves cache now shows growing observed_seconds and trips `FleetSeatQuotaStale` at 15 min instead of masking a frozen figure as fresh.

Test suite (new block 12 in `tests/fleet-metrics-export.test.sh`):
```
OK: stale quota cache carries its true ts -> fleet_seat_quota_observed_seconds reports real age
OK: fleet_rules.yml has FleetSeatQuotaStale keyed on fleet_seat_quota_observed_seconds (fleet-ops#4217)
OK: fleet-ops#4217: fleet_seat_quota_observed_seconds reports real age; FleetSeatQuotaStale rule present
```

## run-proof:

- `fleet-metrics-export.test.sh` — rc=0 (full suite, incl. new block 12 asserting stale-cache ts → real observed_seconds, and the rule keyed on observed_seconds > 900).
- `seat-lib.test.sh`, `seat-lib-dispatch.test.sh`, `seat-failure-ceiling.test.sh`, `seat-quota-corpse.test.sh` — rc=0 (downstream `provider_live_reset_s` consumers unaffected).
- `alertmanager-routing-matrix.test.sh`, `fleet-rules-escalation-storm.test.sh`, `canary-effectiveness.test.sh` — rc=0 (new alert rule does not break routing/matrix).
- `sgscan` — no new security findings.
- Live exporter `main()` run — rc=0, truthful observed_seconds across codex/cursor/devin/xkiro.

organ-heartbeat: libexec/fleet-metrics-export.py (existing exporter organ), config/fleet_rules.yml (existing alert config), tests/fleet-metrics-export.test.sh (existing test organ). not-an-organ: pr-body.md

## Loose ends

- Pre-existing, unrelated: `tests/rule-enforcement.test.sh` fails on a live-vault drill (`led-2026-09-08-litellm-p3b` ledger entry missing its matrix row) — machine/vault state, no repo diff, not touched by this PR.

Closes #4217
