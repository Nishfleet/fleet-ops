## Summary

Product delivery SLOs for 0509 (and any future intake product repo): weekly throughput, median issue→merge lead time, and 28-day revert rate, exported continuously and wired into the console.

**What changed**
- `lib/fleet-product-slo.py` — computes the three SLOs + `fleet_product_merged_24h` from a cached gh GraphQL search; product repos = `config/intake-repos.json` repos[] minus `config/self-maintenance-repos.json`.
- Piggybacks `fleet-metrics-export.service` via `systemd/fleet-metrics-export.service.d/product-slo.conf` (no new timer). Accept §5's dedicated hourly `fleet-product-slo.{service,timer}` is rejected as a new organ — the exporter already runs every 5 min and every sibling effectiveness exporter uses this pattern.
- `config/fleet_rules.yml` — `FleetProductSloAbsent`, `ProductThroughputStalled`, `ProductLeadTimeDegrading`, `ProductRevertRateHigh`.
- `config/fleet-organs.json` — `product-slo` organ with heartbeat `fleet_product_slo_last_run_seconds`.
- Console `shipped_24h` now reads `fleet_product_merged_24h` (generate + verify + shell + truth-drill), fixing the #2690 two-source dispute by making product delivery the single source of truth.

**architect skipped: depth-1 worker**

**Design choice (piggyback vs new timer):** piggyback wins. Same cadence as scout/intake/canary effectiveness; MANIFEST + organ registry already encode "no new timer"; a dedicated hourly unit would add a second heartbeat path for the same facts.

## Verification

```
bash tests/fleet-product-slo.test.sh
# OK: (a)(b)(c) throughput / lead-time-excludes-reverts / revert_rate
# OK: (d) respects intake-repos.json product repo list (fleet-ops excluded)
# OK: (e) empty window emits heartbeat + zeros
# OK: (f) main() fixture end-to-end textfile
# OK: (g) MANIFEST + drop-in wiring; no new timer
# OK: (h)(i) rules + organ registry
# OK: (j) console shipped_24h reads fleet_product_merged_24h
# OK: promtool check rules

bash tests/console-shipped-24h-race.test.sh
# OK: console-shipped-24h-race.test.sh

# Live run (Execution IS the review)
python3 lib/fleet-product-slo.py
# product-slo: wrote .../fleet-product-slo.prom (0509:tp=104,lt=0.17,rr=0.063,24h=4)

XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user start fleet-metrics-export.service
journalctl --user -u fleet-metrics-export.service --since '1 min ago' | grep product-slo
# product-slo: wrote /var/lib/prometheus/node-exporter/fleet-product-slo.prom (0509:tp=104,lt=0.17,rr=0.063,24h=4)

curl -s 127.0.0.1:9100/metrics | grep fleet_product_
# fleet_product_throughput_weekly{repo="0509"} 104
# fleet_product_lead_time_days{repo="0509"} 0.167859
# fleet_product_revert_rate{repo="0509"} 0.062937
# fleet_product_merged_24h{repo="0509"} 4
# fleet_product_slo_last_run_seconds ...

# Console tile matches gh spot (accept verify)
# collect_shipped() -> count=4, items=[{repo: Nishfleet/0509, count: 4}]
# gh api search/issues q='repo:Nishfleet/0509 is:merged merged:>=<24h> type:pr' -> 4
```

run-proof: journalctl --user -u fleet-metrics-export.service — `product-slo: wrote /var/lib/prometheus/node-exporter/fleet-product-slo.prom (0509:tp=104,lt=0.17,rr=0.063,24h=4)` after drop-in install + `systemctl --user start fleet-metrics-export.service`; curl 127.0.0.1:9100/metrics shows all five `fleet_product_*` series.

research: last30days + house pattern — compared (1) dedicated hourly `fleet-product-slo.{service,timer}` as written in accept §5, (2) piggyback on `fleet-metrics-export` like scout/intake/canary effectiveness (#2756/#2759/#2757), (3) fold into `libexec/fleet-metrics-export.py` itself. (2) won: deletion-first / no new organ, same 5-min cadence, existing MANIFEST drop-in rail. (1) lost as a second heartbeat path. (3) lost because the effectiveness siblings already established the drop-in module boundary and a 28d GraphQL fetch should not block the 5-min fleet.prom write on cache miss.

help-first: ran `systemctl --user cat fleet-metrics-export.service` and read `lib/scout-effectiveness.py --help`/module docstring + `MANIFEST` drop-in comments; existing piggyback rail already does continuous export — a new `bin/` wrapper is unnecessary (helper lives under `lib/` like the siblings).

loose-ends-canary: pr:nishfleet/fleet-ops#2755 stale-worker-pr

Pre-existing filed (not fixed here): Nishfleet/fleet-ops#2920 — live metrics-export drop-ins missing scout-effectiveness + intake-effectiveness.

Closes #2755
