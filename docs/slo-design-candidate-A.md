# SLO Framework Design - Candidate A: Centralized SLO Registry

## Overview
A single `config/slo-definitions.json` defines all fleet SLOs as data. The fleet-metrics-export.py reads this config, computes compliance and budget burn for each SLO, and emits standardized metric families. Alert rules in fleet_rules.yml reference these metrics with templated thresholds derived from the SLO targets.

## SLO Definitions (config/slo-definitions.json)
```json
{
  "slo_version": 1,
  "window": "1w",
  "window_seconds": 604800,
  "slos": [
    {
      "id": "main_green",
      "name": "Main Branch CI Green",
      "description": "Percentage of time default-branch CI is green across enrolled repos",
      "target": 0.99,
      "metric_source": "fleet_main_ci_green",
      "aggregation": "ratio_over_time",
      "good_events_query": "sum(rate(fleet_main_ci_green==1[1w]))",
      "total_events_query": "sum(rate(fleet_main_ci_green[1w]))"
    },
    {
      "id": "chain_repair_latency",
      "name": "Alert-Repair Chain Failure-to-Fix Time",
      "description": "Time from alert firing to repair worker completion (p95 ≤ target)",
      "target": 0.95,
      "target_unit": "seconds",
      "metric_source": "fleet_chain_repair_duration_seconds",
      "aggregation": "quantile_over_time",
      "quantile": 0.95,
      "threshold_seconds": 1800
    },
    {
      "id": "0509_user_journey",
      "name": "0509 User Journey Success",
      "description": "Success rate of critical 0509 user journeys",
      "target": 0.995,
      "metric_source": "fleet_0509_journey_success",
      "aggregation": "ratio_over_time",
      "good_events_query": "sum(rate(fleet_0509_journey_success==1[1w]))",
      "total_events_query": "sum(rate(fleet_0509_journey_total[1w]))"
    },
    {
      "id": "digest_delivery",
      "name": "Digest Delivery Success",
      "description": "Daily/weekly digest delivery success rate",
      "target": 0.99,
      "metric_source": "fleet_digest_delivered_total",
      "aggregation": "ratio_over_time",
      "good_events_query": "sum(rate(fleet_digest_delivered_total[1w]))",
      "total_events_query": "sum(rate(fleet_digest_attempted_total[1w]))"
    },
    {
      "id": "waste_ratio",
      "name": "Waste Ratio Ceiling",
      "description": "Fleet waste ratio (empty runs + salvage bleed) stays below ceiling",
      "target": 0.10,
      "target_direction": "below",
      "metric_source": "fleet_waste_ratio",
      "aggregation": "max_over_time",
      "threshold": 0.10
    },
    {
      "id": "seat_availability",
      "name": "Pi Seat Availability",
      "description": "Percentage of enrolled seats that are healthy and available",
      "target": 0.90,
      "metric_source": "fleet_pi_seat_healthy",
      "aggregation": "ratio_over_time",
      "good_events_query": "sum(rate(fleet_pi_seat_healthy==1[1w]))",
      "total_events_query": "sum(rate(fleet_pi_seat_total[1w]))"
    },
    {
      "id": "gh_rate_limit_headroom",
      "name": "GitHub API Rate Limit Headroom",
      "description": "Minimum remaining rate limit across core/search/graphql as % of limit",
      "target": 0.20,
      "target_direction": "above",
      "metric_source": "fleet_gh_rate_limit_remaining",
      "aggregation": "min_over_time",
      "threshold_pct": 0.20
    }
  ]
}
```

## Exported Metrics (per SLO)
For each SLO, the exporter emits:
- `fleet_slo_compliance{slo="<id>"}` - current compliance (0..1, or >1 for "below" targets)
- `fleet_slo_target{slo="<id>"}` - the SLO target value
- `fleet_slo_error_budget_total{slo="<id>"}` - total error budget for the window (1-target)*window
- `fleet_slo_error_budget_consumed{slo="<id>"}` - budget consumed so far in window
- `fleet_slo_error_budget_remaining{slo="<id>"}` - budget remaining (total - consumed)
- `fleet_slo_burn_rate_1h{slo="<id>"}` - budget consumption rate over 1h (as multiple of normal)
- `fleet_slo_burn_rate_6h{slo="<id>"}` - budget consumption rate over 6h
- `fleet_slo_burn_rate_3d{slo="<id>"}` - budget consumption rate over 3d

## Multi-Window Burn-Rate Alerts (fleet_rules.yml)
For each SLO with target T over window W (1w = 604800s):

**Fast Burn (pages the rail - severity=page for critical SLOs, severity=critical for others):**
- 1h window: burn rate ≥ 14.4x (consumes 2% of total budget in 1h)
  - `fleet_slo_burn_rate_1h{slo="X"} > 14.4` for 2m
- 6h window: burn rate ≥ 6x (consumes 5% of total budget in 6h)
  - `fleet_slo_burn_rate_6h{slo="X"} > 6` for 15m

**Slow Burn (feeds review - severity=warning):**
- 6h window: burn rate ≥ 1x (consumes 10% of total budget in 6h)
  - `fleet_slo_burn_rate_6h{slo="X"} > 1` for 1h
- 3d window: burn rate ≥ 1x (consumes 10% of total budget in 3d)
  - `fleet_slo_burn_rate_3d{slo="X"} > 1` for 6h

## Quality Ratchet Integration
- Weekly Fleet Review reads `fleet_slo_error_budget_remaining` for each SLO
- If `remaining / total > 0.5` for 4 consecutive weeks → tighten target by one notch
- Notch sizes defined per SLO in config/slo-definitions.json
- Minimum targets (stop_at) also defined per SLO

## Alert Quality Review (WFR Input)
- New metric family: `fleet_alert_quality{alertname="X", outcome="fired|action|false_positive"}`
- Weekly Fleet Review prompt includes alert quality lens
- Alerts with high false-positive rate or low action rate get tuned/deleted

## Pros
- Single source of truth for SLO definitions
- Easy to add/modify SLOs without code changes
- Consistent metric naming and alert patterns
- Quality ratchet operates on uniform data structure
- Audit trail: SLO changes are config diffs

## Cons
- fleet-metrics-export.py becomes more complex
- New metric sources needed for some SLOs (0509 journey, digest delivery, chain repair)
- Centralized config creates coupling
- Exporter must compute time-window aggregations (may need PromQL or local state)

## Implementation Path
1. Create config/slo-definitions.json
2. Extend fleet-metrics-export.py with SLO computation module
3. Add metric emission for each SLO
4. Add alert rules to fleet_rules.yml (templated from SLO config)
5. Update fleet-organs.json with SLO exporter organ
6. Add quality ratchet integration in weekly-fleet-review prompt
7. Add alert quality metrics and WFR lens
8. Tests for SLO computation, alert rules, ratchet