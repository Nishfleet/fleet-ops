# SLO Framework Design - Candidate B: Decentralized SLO Ownership

## Overview
Each SLO is owned by its natural exporter/module. No central SLO registry. Each module emits its own SLO compliance + budget burn metrics using a shared library. Alert rules reference metrics directly. Quality ratchet reads from a known metric pattern.

## SLO Ownership Map

| SLO | Owner Module | Metric Source |
|-----|--------------|---------------|
| main_green | fleet-metrics-export | fleet_main_ci_green (already exported) |
| chain_repair_latency | fleet-completion-canary | New: chain repair duration histogram |
| 0509_user_journey | 0509's own exporter (new) | 0509 journey success/failure counters |
| digest_delivery | daily-digest exporter (new) | digest delivered/attempted counters |
| waste_ratio | fleet-waste-export | fleet_waste_ratio (already exported) |
| seat_availability | fleet-metrics-export | fleet_pi_seat_healthy + fleet_pi_seat_total (new) |
| gh_rate_limit_headroom | fleet-metrics-export | fleet_gh_rate_limit_remaining/limit (already exported) |

## Shared Library: lib/slo-budget.py
```python
"""Shared SLO budget computation (stdlib only)."""

def compute_budget(target, window_seconds, good_events, total_events):
    """Return (compliance, budget_total, budget_consumed, budget_remaining, burn_rates)."""
    compliance = good_events / total_events if total_events > 0 else 1.0
    budget_total = (1 - target) * window_seconds
    budget_consumed = (1 - compliance) * window_seconds * (elapsed / window_seconds)
    budget_remaining = budget_total - budget_consumed
    # Burn rates computed from time-series of budget_consumed
    return {
        "compliance": compliance,
        "budget_total": budget_total,
        "budget_consumed": budget_consumed,
        "budget_remaining": budget_remaining,
        "burn_rate_1h": ...,  # requires time-series state
        "burn_rate_6h": ...,
        "burn_rate_3d": ...,
    }
```

## Exported Metrics (per SLO, by owner)
Each owner emits (following naming convention `fleet_slo_<metric>{slo="<id>"}`):
- `fleet_slo_compliance{slo="main_green"}` - from fleet-metrics-export
- `fleet_slo_error_budget_remaining{slo="main_green"}` - from fleet-metrics-export
- `fleet_slo_burn_rate_1h{slo="main_green"}` - from fleet-metrics-export
- `fleet_slo_burn_rate_6h{slo="main_green"}` - from fleet-metrics-export
- `fleet_slo_burn_rate_3d{slo="main_green"}` - from fleet-metrics-export
- (same pattern for other SLOs from their owners)

## Alert Rules (fleet_rules.yml)
Static rules per SLO, thresholds computed from targets:
```yaml
# main_green (target 99% over 1w)
- alert: SLOMainGreenFastBurn1h
  expr: fleet_slo_burn_rate_1h{slo="main_green"} > 14.4
  for: 2m
  labels:
    severity: critical
    slo: main_green
    burn_window: 1h
  annotations:
    summary: "main_green SLO fast burn (1h): 2% budget consumed in 1h"

- alert: SLOMainGreenFastBurn6h
  expr: fleet_slo_burn_rate_6h{slo="main_green"} > 6
  for: 15m
  labels:
    severity: critical
    slo: main_green
    burn_window: 6h

- alert: SLOMainGreenSlowBurn6h
  expr: fleet_slo_burn_rate_6h{slo="main_green"} > 1
  for: 1h
  labels:
    severity: warning
    slo: main_green
    burn_window: 6h

- alert: SLOMainGreenSlowBurn3d
  expr: fleet_slo_burn_rate_3d{slo="main_green"} > 1
  for: 6h
  labels:
    severity: warning
    slo: main_green
    burn_window: 3d
```
(Repeat for each SLO with adjusted thresholds)

## Quality Ratchet Integration
- Weekly Fleet Review queries `fleet_slo_error_budget_remaining{slo=...}` for all SLOs
- Ratchet logic in WFR prompt (not code): "If any SLO has >50% budget remaining for 4 weeks, propose tightening"
- SLO-specific notch/stop_at documented in WFR prompt or a small config

## Alert Quality Review (WFR Input)
- alert-repair-dispatch extends actions.log with alert outcomes
- New exporter (or fleet-metrics-export) computes per-alert stats:
  - `fleet_alert_fired_total{alertname="X"}` - count of firings
  - `fleet_alert_action_total{alertname="X"}` - count leading to repair dispatch
  - `fleet_alert_false_positive_total{alertname="X"}` - count dismissed as noise
- WFR prompt includes "Alert Quality" lens reviewing these stats

## Pros
- Follows existing fleet pattern: each organ owns its metrics
- No central config coupling
- Each SLO can evolve independently
- Natural ownership: CI health by CI exporter, seat health by seat exporter
- Smaller, focused changes per module

## Cons
- Inconsistent implementation risk across modules
- Harder to audit all SLOs at once
- Quality ratchet must query multiple metric families
- Alert rules duplicated across SLOs (no templating)
- New exporters needed for 0509 journey and digest delivery
- Burn-rate computation duplicated or requires shared library

## Implementation Path
1. Create lib/slo-budget.py shared library
2. Extend fleet-metrics-export.py for main_green, seat_availability, gh_rate_limit
3. Extend fleet-completion-canary for chain_repair_latency
4. Create 0509 journey exporter (new)
5. Create digest delivery exporter (new) or extend daily-digest
6. Extend fleet-waste-export for waste_ratio SLO metrics
7. Add alert rules to fleet_rules.yml (one block per SLO)
8. Update fleet-organs.json for new organs
9. WFR prompt updates for ratchet + alert quality
10. Tests per module

## Key Difference from Candidate A
- **Candidate A**: Central config drives everything. Exporter is the single compute engine. Adding an SLO = editing JSON.
- **Candidate B**: Each SLO lives in its natural home. Adding an SLO = editing the owner module + rules. Shared library for budget math only.

## Hybrid Approach (Synthesis)
Use Candidate A's centralized config for SLO *definitions* (targets, windows, notch sizes) but Candidate B's ownership for *metric emission*. The config defines "what" and "how much", each owner module computes "how" using the shared budget library. Alert rules are generated from config (or kept static but documented as derived from config).