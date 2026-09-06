## fix(metrics): remove the last local-time parse in the exporter (fleet-ops#3564)

**Cause.** #3520 (console) and #3562 (`_read_seat`) converted every `observed_at`
parse to `calendar.timegm`, but the exporter still had ONE remaining
`time.mktime(time.strptime(` — the cap=0 stale reason-date parser in
`_read_cap0_stale` (`_age_from_reason`). On the +05:30 live host, `time.mktime`
reads a dated reason ~19800s older than on a UTC host — the identical 19800s IST
offset that re-armed `FleetPiSeatHealthStale` after #3520 merged. The metric
`fleet_pi_seat_health_age_seconds` is 19800s-susceptible only while any
local-time parse survives in the seat-health read path.

**Fix.** Convert `_age_from_reason` to `calendar.timegm`, eliminating the last
`time.mktime(time.strptime(` in the exporter. `grep -rn "time.mktime("` over
`lib/`, `libexec/`, `bin/` is now empty — the 19800s offset class cannot be
produced by any live parse path.

**Regression.** Two checks in `tests/fleet-metrics-export.test.sh`:
- A gate mirroring `tests/fleet-console-pi-utc.test.sh`: `! grep -q
  'time.mktime(time.strptime(' "$exporter"` fails loudly in CI if someone
  reintroduces a local-time parse, so a 19800s value fails rather than re-arming
  silently.
- A behavioral pin (section 9c): a dated cap=0 reason read under
  `TZ=Asia/Kolkata` yields the same age as under `TZ=UTC` (was offset by 19800s
  under `time.mktime`).

**Verification**
- `bash tests/fleet-metrics-export.test.sh` → rc=0, 0 FAIL. Live outputs:
  `OK: fleet-ops#3564: exporter contains no time.mktime-on-strptime local-time parse`
  `OK: cap0 stale reason-date age TZ-independent (IST=461762s UTC=461762s)`
  `OK: _read_seat parses observed_at as UTC (host-TZ independent); stale/absent -> UNKNOWN; >1800 rule present`
- `bash tests/fleet-console-pi-utc.test.sh` → PASS (console still timegm).
- Live probe: exporter run emits `fleet_pi_seat_health_age_seconds` at age
  ~9s — well under the 1800s alert threshold, from the fresh
  `/home/nish/workspaces/agent-state/lanes/pi-seat-health.json` observation.

**run-proof**
- Test unit: `fleet-metrics-export.service` / `fleet-metrics-export.timer`
  `systemctl --user list-timers` shows `fleet-metrics-export.timer` active.
- CI: `.github/workflows/ci.yml` line 282 runs `bash tests/fleet-metrics-export.test.sh`.
- `sgscan` (security): no new findings.

Closes #3564

net-positive-because: the +60/-1 net is a regression gate (a grep gate + a TZ-pin behavioral test) that permanently prevents the 19800s IST offset class from re-arming FleetPiSeatHealthStale, plus a one-line timegm change in the exporter. This is test/guard weight, not new runtime machinery — the only code change is the single mktime→timegm call-site swap.
