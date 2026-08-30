#!/usr/bin/env python3
"""SLO error-budget computation (stdlib only).

Shared library for fleet SLO budget math. No I/O, no Prometheus client —
pure arithmetic so every owner module computes the same numbers from the
same inputs. Imported by libexec/fleet-metrics-export.py.

Google SRE Workbook, Chapter 5 (Alerting on SLOs):
- An SLO target T over a window W has an error budget of (1-T)*W (ratio
  SLOs, "above") or T*W (gauge SLOs, "below").
- The exporter emits compliance / target / budget_total / budget_consumed
  / budget_remaining as point-in-time gauges every scrape. The budget
  gauges are a snapshot: with elapsed=window, remaining>0 means "current
  compliance meets target this instant" — the SMOOTH verdict's signal.
- Burn-rate ALERTS live in config/fleet_rules.yml and are computed by
  Prometheus, NOT this library. Because the source is a sampled gauge
  (not an event counter), the canon translates to:
  * RATIO SLOs (main_green, seat_availability, 0509, digest): multiwindow
    burn-rate over avg_over_time(fleet_slo_compliance[W]) —
    burn_rate = (1 - avg_over_time(compliance[W])) / (1 - target),
    fast burn = 14.4x (1h AND 5m), slow burn = 1x (6h AND 30m).
  * THRESHOLD-GAUGE SLOs (waste_ratio, gh_rate_limit_headroom,
    chain_repair_latency): the error-budget ratio model does not fit a
    single threshold gauge (Workbook applies burn-rate to ratio SLIs);
    these get canonical threshold-window alerts (value beyond target for
    a sustained window) instead.

Only severity=page reaches Nish's phone (fleet-ops#1534 phone chokepoint),
and that is reserved for RepairDispatchDown; SLO burn is critical/warning
so it auto-repairs, never pages a human.
"""

from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class SLOBudget:
    """Computed error budget for one SLO over its measurement window."""
    slo_id: str
    target: float
    window_seconds: float
    compliance: float          # 0..1 (ratio "above"); value/target (gauge "below")
    elapsed_seconds: float     # time elapsed in current window
    budget_total: float        # (1 - target) * window ("above") or target * window ("below")
    budget_consumed: float     # budget used so far
    budget_remaining: float    # budget_total - budget_consumed

    def is_within_budget(self) -> bool:
        return self.budget_remaining > 0


def compute_budget(
    slo_id: str,
    target: float,
    window_seconds: float,
    compliance: float,
    elapsed_seconds: float,
    direction: str = "above",      # "above" = higher compliance is good (ratio SLOs)
                                   # "below" = lower value is good (gauge SLOs like waste_ratio)
) -> SLOBudget:
    """Compute error budget for a ratio or gauge SLO.

    Args:
        slo_id: SLO identifier
        target: SLO target (0..1 for ratio; threshold for gauge)
        window_seconds: measurement window duration
        compliance: current compliance (0..1 for ratio; actual/target for "below")
        elapsed_seconds: time elapsed in current window
        direction: "above" (target is minimum good ratio) or "below" (target is max)

    Returns:
        SLOBudget with total/consumed/remaining. Burn rates are NOT computed
        here — Prometheus derives them from the consumed gauge via increase().
    """
    if direction == "above":
        # Ratio SLO: target is minimum good ratio (e.g., 0.99).
        # Error budget = (1 - target) * window; consumed = (1 - compliance) * elapsed.
        budget_total = (1.0 - target) * window_seconds
        budget_consumed = max(0.0, (1.0 - compliance) * elapsed_seconds)
    else:
        # Gauge SLO (e.g., waste_ratio <= 0.10): target is the max allowed value.
        # compliance = actual/target (>1 means over budget). Budget = target * window;
        # consumed = (compliance - 1) * target * elapsed when over, else 0.
        budget_total = target * window_seconds
        if compliance > 1.0:
            budget_consumed = (compliance - 1.0) * target * elapsed_seconds
        else:
            budget_consumed = 0.0

    budget_remaining = budget_total - budget_consumed
    return SLOBudget(
        slo_id=slo_id,
        target=target,
        window_seconds=window_seconds,
        compliance=compliance,
        elapsed_seconds=elapsed_seconds,
        budget_total=budget_total,
        budget_consumed=budget_consumed,
        budget_remaining=budget_remaining,
    )


def format_prometheus(budget: SLOBudget, prefix: str = "fleet_slo") -> list[str]:
    """Format SLOBudget as Prometheus textfile sample lines (no HELP/TYPE)."""
    labels = f'slo="{budget.slo_id}"'
    return [
        f'{prefix}_compliance{{{labels}}} {budget.compliance:.6f}',
        f'{prefix}_target{{{labels}}} {budget.target:.6f}',
        f'{prefix}_error_budget_total{{{labels}}} {budget.budget_total:.3f}',
        f'{prefix}_error_budget_consumed{{{labels}}} {budget.budget_consumed:.3f}',
        f'{prefix}_error_budget_remaining{{{labels}}} {budget.budget_remaining:.3f}',
    ]


def format_prometheus_help_type(prefix: str = "fleet_slo") -> list[str]:
    """HELP/TYPE lines for the standard SLO metric families (emit once)."""
    return [
        f"# HELP {prefix}_compliance Current SLO compliance (0..1 ratio, or value/target for gauge SLOs).",
        f"# TYPE {prefix}_compliance gauge",
        f"# HELP {prefix}_target SLO target value.",
        f"# TYPE {prefix}_target gauge",
        f"# HELP {prefix}_error_budget_total Total error budget for the measurement window (seconds).",
        f"# TYPE {prefix}_error_budget_total gauge",
        f"# HELP {prefix}_error_budget_consumed Error budget consumed so far in the window (seconds). Burn-rate alerts use increase() over this gauge.",
        f"# TYPE {prefix}_error_budget_consumed gauge",
        f"# HELP {prefix}_error_budget_remaining Error budget remaining in the window (seconds).",
        f"# TYPE {prefix}_error_budget_remaining gauge",
        f"# HELP {prefix}_instrumented 1 if this SLO's source metric is wired and compliance is live; 0 if pending a source metric (never burns).",
        f"# TYPE {prefix}_instrumented gauge",
    ]


if __name__ == "__main__":
    # Self-test (run: python3 lib/slo_budget.py)
    # 99% target over 1w, 50% elapsed, 98.5% compliance (burning budget).
    b = compute_budget("test_slo", 0.99, 604800, 0.985, 302400)
    assert abs(b.budget_total - 6048.0) < 0.1, b.budget_total
    assert abs(b.budget_consumed - 4536.0) < 0.1, b.budget_consumed
    assert abs(b.budget_remaining - 1512.0) < 0.1, b.budget_remaining
    assert not b.is_within_budget() is False  # 1512 > 0 → within budget
    print("compute_budget (above): OK")

    # Gauge SLO: waste_ratio target 0.10, actual 0.12 (compliance=1.2), 50% elapsed.
    # consumed = (1.2-1)*0.10*302400 = 6048; total = 0.10*604800 = 60480;
    # remaining = 54432 > 0 → within weekly budget (instant violation, budget not exhausted).
    b2 = compute_budget("waste", 0.10, 604800, 1.2, 302400, direction="below")
    assert abs(b2.budget_total - 60480.0) < 0.1, b2.budget_total
    assert abs(b2.budget_consumed - 6048.0) < 0.1, b2.budget_consumed
    assert b2.is_within_budget() is True
    print("compute_budget (below): OK")

    # Gauge SLO within budget: actual 0.08 (compliance=0.8 < 1).
    b3 = compute_budget("waste_ok", 0.10, 604800, 0.8, 302400, direction="below")
    assert b3.budget_consumed == 0.0
    assert b3.is_within_budget() is True
    print("compute_budget (below, within): OK")

    # format_prometheus emits exactly 5 sample lines.
    lines = format_prometheus(b)
    assert len(lines) == 5, lines
    assert all("test_slo" in ln for ln in lines)
    assert any(ln.startswith("fleet_slo_compliance") for ln in lines)
    print("format_prometheus: OK")

    ht = format_prometheus_help_type()
    assert any("fleet_slo_instrumented" in ln for ln in ht)
    assert sum(1 for ln in ht if ln.startswith("# TYPE")) == 6
    print("format_prometheus_help_type: OK")

    print("All self-tests passed")
