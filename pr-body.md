Raise free-lane caps and add GitHub API rate limit as a concurrency governor (fleet-ops#1350).

## What changed

- `config/seat-caps.json`: raised free-lane caps and AIMD probe ceilings from live concurrency-tolerance probes.
  - `bai` cap 2 -> 4 (deepseek-v4-flash, measured clean to n=5).
  - `commandcode` cap 2 -> 4 (minimax-m3-free, measured clean to n=5).
  - `opencode` cap 1 -> 3 (hy3-free, measured clean to n=5).
  - `hetzner` cap stays 2 (concurrent probes timeout; re-probe before raising).
  - Cursor stays 1 (known single-flight).
- `libexec/fleet-metrics-export.py`: fetches `gh api rate_limit` once per run, emits `fleet_gh_rate_limit_*` Prometheus metrics, and writes a side-car JSON state file for the intake throttle.
- `lib/pi-intake-tick.sh`: gates issue claims on the side-car state; holds claims this tick when any consumed resource (core/search/graphql) is below 20%. Missing or stale state fail-open (and now logs that it is failing open) so a dead exporter does not freeze the fleet.
- `config/fleet_rules.yml`: adds `FleetGhRateLimitAbsent` (organ heartbeat) and `FleetGhRateLimitLowSustained` (6h trend) alerts.
- `tests/seat-lib-aimd.test.sh`: updated AIMD ceiling assertions to match the raised free-lane caps.
- `tests/fleet-gh-rate-limit.test.sh` + `tests/pi-intake-gh-rate-limit.test.sh` (CI-hosted by `fleet-metrics-export.test.sh` and `pi-intake-run.test.sh`): offline coverage for the rate-limit metrics and the intake throttle.

## Target state

- 15-25 concurrent workers, load <12, zero 429-storms.
- GitHub API budget is a soft ceiling: intake throttles before the remaining core/search/graphql budget drops below 20%, and a sustained-low trend alert fires if any resource stays under 20% for 6+ hours.

## Verification

run-proof: tests/fleet-gh-rate-limit.test.sh

```
$ cd /home/nish/workspaces/agent-worktrees/issue-fleet-ops-1350
$ bash tests/fleet-gh-rate-limit.test.sh
OK: healthy rate-limit emits metrics + sidecar; low=0, binding floor=20/30
OK: exhausted rate-limit (<20% on search) sets low=1, sidecar=5/30
OK: fleet-ops#1350 gh rate-limit metrics + sidecar verified

$ bash tests/pi-intake-gh-rate-limit.test.sh
OK: low=1 holds claims and exits 0
OK: low=0 continues without holding
OK: missing gh rate-limit state is fail-open

$ bash tests/seat-lib-aimd.test.sh
All AIMD invariants passed.

$ bash tests/pi-intake-run.test.sh
ALL OK: intake-tick spawn post-condition + start-limit healer

$ bash tests/fleet-metrics-export.test.sh
ALL OK: fleet-metrics-export #1136 logic pinned

$ bash tests/seat-lib.test.sh
ALL OK
```
