## Live Cursor quota read via VPS-native accessToken (fleet-ops#4217)

Adds the Cursor seat to the `fleet_seat_quota_*` metric family using a VPS-native API read — no browser scrape, no Mac dependency.

The Cursor `GetCurrentPeriodUsage` endpoint (`api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`) answers a POST with the Bearer accessToken already present on this VPS at `~/.config/cursor/auth.json` (the same token the Cursor CLI uses). This is the endpoint OpenUsage's Cursor provider calls (`Sources/OpenUsage/Providers/Cursor/CursorUsageClient.swift`). The payload carries `planUsage.totalPercentUsed` (percent USED across the billing cycle) and `billingCycleEnd` (epoch-milliseconds).

- `remaining_pct = 100 - totalPercentUsed`
- `reset_s = seconds until billingCycleEnd`
- window = `monthly` (the billing cycle)

This is a VPS-native API read (`source="api"`), so it satisfies the "no Mac step" and "no observed-only" requirements for the Cursor seat directly.

## Verification

Live run of the exporter from this worktree (2026-09-07):

```
$ python3 libexec/fleet-metrics-export.py
wrote /var/lib/prometheus/node-exporter/fleet.prom (26 timers, seat_healthy=1)
```

run-proof: the metric is live in Prometheus:

```
$ curl -s "http://localhost:9090/api/v1/query" --data-urlencode 'query=fleet_seat_quota_remaining_pct{provider="cursor"}'
{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"fleet_seat_quota_remaining_pct","provider":"cursor","source":"api","window":"monthly"},"value":[1788789212.062,"38.3374"]}]}}
```

The exact credential-free curl the fetcher performs (token read from `~/.config/cursor/auth.json`, not printed):

```
POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
Authorization: Bearer <accessToken from ~/.config/cursor/auth.json>
Content-Type: application/json
body: {}
```

Response (live): `planUsage.totalPercentUsed=61.66` → `remaining_pct=38.34`, `billingCycleEnd=1790049771000` (2026-09-22, matching the seat-caps.json billing-cycle note).

Metric line produced:

```
fleet_seat_quota_remaining_pct{provider="cursor",window="monthly",source="api"} 38.3374
fleet_seat_quota_reset_seconds{provider="cursor",window="monthly",source="api"} 1260573.2437
fleet_seat_quota_observed_seconds{provider="cursor",source="api"} 0.0000
```

## Tests

- `tests/fleet-metrics-export.test.sh` — extended with a `_fetch_cursor_usage` mapping test (stubbed token + urlopen, no network). Full suite: 144 OK, exit 0.
- Full CI test list (72 tests) run locally: all pass.
- `bin/sgscan`: no new security findings.

net-positive-because: adds one VPS-native quota read (Cursor) to the existing `fleet_seat_quota_*` family, closing a seat the parent issue's acceptance requires; the added lines are the fetcher + its test, both inside existing organs.

loose-ends: remaining seats (Devin, Grok, Ollama, Z.ai, OpenCode, RunInfra, ZenMux, Cline, Straitly, MiniMax, CommandCode) tracked in #4232 (browser-dashboard) and #4233 (credential-blocked API); parent #4217 stays open until all seats have a live figure.

Relates to #4217
Relates to #4232
