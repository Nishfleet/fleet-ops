## Why

fleet-ops#5140: 0509's production deploy had not gone green since
2026-09-09T17:03Z — 28h+ at filing — while `fleet_product_merged_24h
{repo="0509"}` read 131 and `fleet_main_ci_green` read green. 131 merged PRs
reached no customer, and nothing measured it: the deploy-quality family was
hardcoded to the fleet-ops VPS `fleet-deploy-check` pipeline, and
`fleet_main_ci_green` tracks the workflow literally named `CI`, not 0509's
`Deploy production` gate. No metric, no rule, no repair lane.

## What

- `lib/fleet-deploy-quality.py` is multi-repo. fleet-ops payload is
  byte-identical (existing test pins its numbers); every `product: true` repo
  in `config/intake-repos.json` now gets its own series via the proven
  `_INTAKE_CANDIDATES` seam chain (`FLEET_DQ_REPOS_JSON` env first).
- Per product repo: `fleet_deployment_latency_seconds{repo}` (merge -> first
  green production-deploy run, merges older than run coverage excluded),
  `fleet_deploy_blocked_duration_seconds{repo,workflow}` (trailing non-green
  streak age, 0 when the newest run is green, logged lower bound when the
  streak exceeds the fetched window), `fleet_deployment_quality_up{repo}`,
  `fleet_product_deploy_green{repo}`, and
  `fleet_product_deploy_last_red_run_info{repo,workflow,url} 1` (emitted only
  while the newest run is non-green — the URL lives on this info series so it
  never mints a new duration series and starves the rule's `for:` timer).
- A declared product repo that cannot be measured emits NaN gauges +
  `fleet_deployment_quality_up{repo} 0` — never a silent absence.
- New rule `ProductDeployStalled`, severity **warning** (must not page Nish):
  `fleet_deploy_blocked_duration_seconds{repo!="fleet-ops"} > 3600 for: 15m`.
  Annotations name the repo, the workflow, the age, and the newest red run URL
  (read off the info series via the `query` template function). The five
  existing fleet_deploy_quality rules are byte-identical.
- `fleet_main_ci_green` HELP text now says it tracks only the workflow
  literally named `CI`; deploy greenness is `fleet_product_deploy_green`.
  Semantics unchanged (accept 4).
- gh budget: product fetches run on their own capped counter
  (`MAX_PRODUCT_FETCHES_PER_SCRAPE=2`, runs first then merges, 15s timeout,
  RUNS_TTL=120s < the 5-min tick) leaving `_GH_FETCHED_THIS_RUN` untouched.
  No new timer, unit or service — the existing `fleet-metrics-export` tick
  carries it (accept 6). Worst added wall time 2x15s inside the unit's 90s
  default `TimeoutStartSec`.
- `tests/fleet-product-deploy-0509.test.sh` (new, hermetic — FLEET_DQ_* file
  seams only, `FLEET_DQ_GH=/nonexistent/gh`): red-streak -> blocked>0 +
  fleet-ops-first ordering + a second product repo degrading to NaN/up=0
  without touching siblings + one HELP/TYPE per name; green-newest ->
  blocked 0. Hosted from `ci-standards-audit.test.sh`; named pin added to
  `p14-test-listing-gate.test.sh` so a dropped host line fails by name.
- `tests/fleet-metrics-export.test.sh` + `tests/fleet-gh-rate-limit.test.sh`:
  `FLEET_DQ_REPOS_JSON` pinned to a fleet-ops-only fixture so `main()`
  heredocs can never resolve the live intake set, spend real gh calls, or
  write product cache files into the production cache dir (phase-1 review
  act-on).
- Phase-1 reviewer act-ons also landed: `_run` catches
  `(OSError, subprocess.SubprocessError)` so a gh timeout degrades to the
  stale-cache path instead of whole-repo up=0; `_read_cache` guards
  `isinstance(c, dict)` so a valid-JSON non-dict cache file cannot
  AttributeError-brick the family.

## Verification

```
bash tests/fleet-deploy-quality.test.sh      # all pass, incl. promtool rule
                                             # tests: fires >3600s/15m at
                                             # warning, silent on green and
                                             # on repo="fleet-ops"
bash tests/fleet-product-deploy-0509.test.sh # all pass (red + green scrapes)
bash tests/fleet-metrics-export.test.sh      # all pass (53 OK checks)
bash tests/fleet-gh-rate-limit.test.sh       # all pass
bash tests/p14-test-listing-gate.test.sh     # P14 list closed
bash tests/ci-standards-audit.test.sh        # pass (hosts the new test)
bash tests/fleet-rules-severity-page.test.sh # pass — still exactly one
                                             # severity=page alert
python3 -c "import ast;ast.parse(open('lib/fleet-deploy-quality.py').read())"
```

Live run on the VPS (module against the real intake config + gh):

```
$ python3 lib/fleet-deploy-quality.py --prom | grep 'repo="0509"'
fleet_deployment_latency_seconds{repo="0509"} NaN
fleet_deploy_blocked_duration_seconds{repo="0509",workflow="Deploy production"} 18851.726
fleet_deployment_quality_up{repo="0509"} 1
fleet_product_deploy_green{repo="0509"} 0
fleet_product_deploy_last_red_run_info{repo="0509",workflow="Deploy production",url="https://github.com/Nishfleet/0509/actions/runs/34553464836"} 1
stderr: deploy-quality: 0509 non-green streak reaches the end of the fetched
run list — blocked duration is a LOWER BOUND
```

The stall this issue was filed for is now a live metric: 0509 deploys blocked
for >= 5.2h (lower bound — streak exceeds the 30-run window),
`fleet_product_deploy_green 0`, newest red run URL carried on the info series.

run-proof: `python3 lib/fleet-deploy-quality.py --prom` on the VPS emits the
`repo="0509"` family above with the real blocked duration and the newest red
run URL; `promtool test rules` fires `ProductDeployStalled` at warning past
3600s/15m and stays silent on green.

net-positive-because: the acceptance criteria require a new metric family for
every product repo, a new alert rule, and a new hermetic test — new
measurement surface cannot be a deletion.

organ-heartbeat: libexec/fleet-metrics-export.py node_textfile_mtime_seconds FleetMetricsExportMissing (kept; also serves gh-rate-limit organ's fleet_gh_rate_limit_fetched_seconds / FleetGhRateLimitAbsent — both absent() rules unchanged)
organ-heartbeat: lib/fleet-deploy-quality.py not-an-organ: a module measured BY the metrics-export organ, not a scheduled unit of its own; fleet-ops#1010 status-A.

loose-ends: fleet-ops#5250 (filed — `fleet_deployment_quality_up{repo=<product>} 0`
has no alert consumer yet; needs a warning-severity unmeasurable-repo rule)

Closes #5140
