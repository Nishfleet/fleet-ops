# SLO Framework Design - Synthesis (Chosen: Hybrid A+B)

## Decision
**Candidate A (Centralized Config) wins as the primary structure** because the issue explicitly asks to "Define 5-7 SLOs as data in fleet-ops" — a centralized JSON config is the direct interpretation. However, we graft Candidate B's **shared budget library** and **ownership-aware metric emission** to avoid a monolithic exporter.

## Synthesized Design

### 1. Central Config: `config/slo-definitions.json`
Single source of truth for SLO targets, windows, notches, stop_at, and metric source mapping. Each SLO declares:
- `id`, `name`, `description`
- `target` (0..1 for ratio SLOs, or threshold with `direction` for gauge SLOs)
- `window` (duration string, e.g., "1w") + `window_seconds`
- `metric_source` (PromQL query or metric name the owner emits)
- `aggregation` (how to compute compliance from source)
- `ratchet`: `{notch, stop_at, min_weeks_unspent}`

### 2. Shared Library: `lib/slo-budget.py`
Pure-Python stdlib module with:
- `compute_budget(target, window_seconds, compliance, elapsed_seconds)` → budget dict
- `compute_burn_rates(budget_consumed_series)` → {1h, 6h, 3d} burn rates
- `format_prometheus(metric_prefix, slo_id, budget_dict)` → metric lines
- No I/O, no Prometheus client — just math. Owner modules import and use it.

### 3. Owner Modules Emit SLO Metrics
Each SLO's natural owner imports `lib.slo_budget` and emits the standard metric family:
```
fleet_slo_compliance{slo="<id>"}
fleet_slo_target{slo="<id>"}
fleet_slo_error_budget_total{slo="<id>"}
fleet_slo_error_budget_consumed{slo="<id>"}
fleet_slo_error_budget_remaining{slo="<id>"}
fleet_slo_burn_rate_1h{slo="<id>"}
fleet_slo_burn_rate_6h{slo="<id>"}
fleet_slo_burn_rate_3d{slo="<id>"}
```

**Ownership map:**
| SLO | Owner | Implementation |
|-----|-------|----------------|
| main_green | fleet-metrics-export | Uses existing fleet_main_ci_green |
| chain_repair_latency | fleet-completion-canary | New duration histogram from alert-repair chains |
| 0509_user_journey | fleet-metrics-export | New: gh search for 0509 journey issues (or 0509 exporter) |
| digest_delivery | fleet-metrics-export | New: daily-digest success/failure from journal |
| waste_ratio | fleet-waste-export | Uses existing fleet_waste_ratio |
| seat_availability | fleet-metrics-export | Uses existing fleet_pi_seat_healthy + new fleet_pi_seat_total |
| gh_rate_limit_headroom | fleet-metrics-export | Uses existing fleet_gh_rate_limit_remaining/limit |

### 4. Alert Rules: `config/fleet_rules.yml`
Generated from config (or statically written but *documented as derived from config*). Each SLO gets 4 alerts:
- **FastBurn1h** (severity=critical/page): burn_rate_1h > 14.4 for 2m
- **FastBurn6h** (severity=critical): burn_rate_6h > 6 for 15m
- **SlowBurn6h** (severity=warning): burn_rate_6h > 1 for 1h
- **SlowBurn3d** (severity=warning): burn_rate_3d > 1 for 6h

Severity mapping:
- `main_green`, `chain_repair_latency`, `0509_user_journey` → FastBurn = page
- Others → FastBurn = critical

### 5. Quality Ratchet Integration
- WFR prompt reads `fleet_slo_error_budget_remaining{slo=...}` for all SLOs
- If `remaining/total > 0.5` for `min_weeks_unspent` (default 4) consecutive weeks → propose tightening target by `notch`
- Ratchet proposals filed as issues with `signal: wfr-action/slo-ratchet/<slo_id>`
- Config `slo-definitions.json` updated via PR (not auto)

### 6. Alert Quality Review (WFR Input)
- `alert-repair-dispatch` logs outcome per alert: `DISPATCH`, `SKIP`, `FALSE_POSITIVE`
- `fleet-metrics-export` computes from actions.log (last 7d):
  - `fleet_alert_fired_total{alertname="X"}`
  - `fleet_alert_action_total{alertname="X"}`
  - `fleet_alert_false_positive_total{alertname="X"}`
  - `fleet_alert_action_rate{alertname="X"}` = action/fired
- WFR prompt includes "Alert Quality" lens: reviews top 10 noisiest alerts
- Alerts with `action_rate < 0.1` or `false_positive_rate > 0.5` get tuning proposals

### 7. Organ Registration
Each owner module that emits SLO metrics registers its heartbeat in `fleet-organs.json`:
- `fleet-metrics-export` → adds SLO metrics to existing organ
- `fleet-completion-canary` → adds chain_repair_latency heartbeat
- `fleet-waste-export` → adds waste_ratio SLO heartbeat

### 8. Opus Duty Officer SMOOTH Verdict
- Weekly Fleet Review computes: `all(fleet_slo_error_budget_remaining > 0)`
- If true → "SMOOTH: all SLOs within budget"
- If false → lists SLOs with budget exhaustion + burn rate
- This arithmetic verdict replaces subjective judgment

## Grafted from Candidate B (Loser)
- **Shared budget library** (`lib/slo-budget.py`) — avoids duplicating burn-rate math
- **Ownership-aware emission** — each module computes its own compliance using the library
- **Natural metric sources** — no forced centralization of data collection

## Rejected from Candidate A
- Monolithic exporter computing ALL SLOs — too much coupling, violates organ ownership
- Centralized PromQL in config — hard to test, debug, and evolve

## Rejected from Candidate B
- No central config — contradicts "Define as data" requirement
- Fully duplicated alert rules — maintenance burden
- No unified ratchet integration point

## Implementation Order
1. `lib/slo-budget.py` - shared math library
2. `config/slo-definitions.json` - SLO registry
3. `fleet-metrics-export.py` - add main_green, seat_availability, gh_rate_limit, waste_ratio, digest_delivery SLO metrics
4. `fleet-completion-canary.py` - add chain_repair_latency SLO metrics
5. `fleet-waste-export.py` - add waste_ratio SLO metrics (if not in fleet-metrics-export)
6. `config/fleet_rules.yml` - add 28 alert rules (7 SLOs × 4 burn windows)
7. `config/fleet-organs.json` - register SLO heartbeats
8. `prompts/weekly-fleet-review.md` - add SLO budget review + alert quality lenses
9. Tests for each component
10. Verification run

## Files to Create/Modify
- NEW: `lib/slo-budget.py`
- NEW: `config/slo-definitions.json`
- MODIFY: `libexec/fleet-metrics-export.py`
- MODIFY: `bin/fleet-completion-canary.py`
- MODIFY: `libexec/fleet-waste-export.py`
- MODIFY: `config/fleet_rules.yml`
- MODIFY: `config/fleet-organs.json`
- MODIFY: `prompts/weekly-fleet-review.md`
- MODIFY: `MANIFEST`
- NEW: `tests/slo-budget.test.sh`
- MODIFY: `tests/fleet-metrics-export.test.sh`
- MODIFY: `tests/fleet-completion-canary.test.sh`
- MODIFY: `tests/fleet-waste-ledger.test.sh`