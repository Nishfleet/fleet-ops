# Plan — fleet-ops#4995: product deploy-freshness metric + ProductDeployStale alert

Manager-mode plan (difficulty: heavy). One phase line per acceptance bullet.

## Phase 1: lib/fleet-deploy-quality.py — product freshness fetch + emit
- [ ] [accept 1] `lib/fleet-deploy-quality.py` emits `fleet_product_deploy_last_success_seconds{repo="<r>"}` and `fleet_product_deploy_up{repo="<r>"}` for every enrolled product repo (intake-repos.json `repos[]` minus `config/self-maintenance-repos.json`), appended by the EXISTING `libexec/fleet-metrics-export.py::_emit_deploy_quality` hook on the existing 5-min fleet-metrics-export tick — no new timer, no new unit, no new service, no exporter edit.
- [ ] [accept 1] resolve the repo list by REUSING `lib/fleet-product-slo.py::load_product_repos()` (lazy `importlib.util` load of the hyphenated sibling, same pattern as the exporter's `_deploy_quality_mod()` at libexec/fleet-metrics-export.py:5205); overridable by `FLEET_DQ_PRODUCT_REPOS`; an unreadable intake file yields `[]` and never raises.
- [ ] [accept 2] count a success ONLY when the run is push-triggered on the default branch with conclusion `success`: call exactly `gh run list -R Nishfleet/<repo> --workflow <FLEET_DQ_PRODUCT_WORKFLOW:-deploy-production.yml> --event push --branch <FLEET_DQ_PRODUCT_BRANCH:-main> --status success --limit 1 --json conclusion,createdAt,event,headBranch,url`; re-reject in code any returned row whose `conclusion`/`event`/`headBranch` is not success/push/main, so a PR-head success can never count and a `cancelled` run can never count.
- [ ] [accept 2] on a failed or unparsable GitHub read for a repo, emit `fleet_product_deploy_up{repo="<r>"} 0` and `fleet_product_deploy_last_success_seconds{repo="<r>"} NaN` for THAT repo only, leaving the other repos' values intact.
- [ ] [accept 2] no-success-ever is truthful, not fake: when the read succeeds and no qualifying run exists, emit `fleet_product_deploy_up{repo="<r>"} 1` with `fleet_product_deploy_last_success_seconds{repo="<r>"} +Inf`.
- [ ] carry `run_url` (the LAST SUCCESS run URL) as a label on BOTH gauges so the `and` in the Phase 2 expression vector-matches and the annotation can render `{{ $labels.run_url }}`; that label is stable for the whole outage, so `for: 15m` can actually complete (a label tracking the newest ATTEMPTED run would reset the timer on every failing run and the alert would never fire).
- [ ] [accept 4] spend at most ONE additional gh subprocess per scrape: add a NEW module-global guard `_DQ_PRODUCT_GH_FETCHED_THIS_RUN` — the existing `_cached()`/`_GH_FETCHED_THIS_RUN` slot is already burned by the fleet-ops family, so `_cached()` must NOT be used for the product path; pick the repo whose product cache entry is OLDEST (never-fetched first), fetch only that one, serve every other repo from cache, keeping a scrape well under 60s.
- [ ] [accept 4] cache per repo under `FLEET_DQ_PRODUCT_CACHE_DIR` (default `$FLEET_DQ_CACHE_DIR`/`$AGENT_STATE/fleet-metrics`) as `deploy-quality-product-<repo>.json` holding the last-success EPOCH, `run_url` and `fetched_ts`; recompute `now - epoch` every scrape so a cached value never freezes the freshness age; TTL/stale envelope mirrors GH_TTL/GH_STALE (1800s/7200s).
- [ ] [accept 6] never raise out of `prom_lines()`: wrap the whole product block so a per-repo failure degrades to that repo's `up 0` + NaN seconds and an enrollment/import failure degrades to zero product lines, keeping the exporter green.
- [ ] [accept 6] import-safety: the new fetch failure path emits NaN seconds + `fleet_product_deploy_up ... 0` (no exception, no partial or malformed line), so the existing `_emit_deploy_quality` contract at libexec/fleet-metrics-export.py:5429 is unchanged.
- [ ] render `+Inf` correctly: the existing `_fmt()` uses `repr(round(v, 3))`, which prints `inf`, not the Prometheus literal `+Inf`; give the two new gauges an explicit `+Inf`/NaN branch instead of routing infinity through `_fmt()`.
- [ ] add the new env seams and extend the module docstring's seam list: `FLEET_DQ_PRODUCT_REPOS`, `FLEET_DQ_PRODUCT_RUNS` (JSON map repo -> the `gh run list --json` array; skips gh entirely), `FLEET_DQ_PRODUCT_CACHE_DIR`, `FLEET_DQ_PRODUCT_WORKFLOW` (default `deploy-production.yml`), `FLEET_DQ_PRODUCT_BRANCH` (default `main`).
- [ ] no MANIFEST change: `lib/fleet-deploy-quality.py` is already MANIFEST entry line 199; leave MANIFEST untouched.

## Phase 2: config/fleet_rules.yml — ProductDeployStale
- [ ] [accept 3] add `ProductDeployStale` to the existing deploy-quality rule group in `config/fleet_rules.yml` (group starts ~line 1367) with `expr: fleet_product_deploy_up == 1 and fleet_product_deploy_last_success_seconds > 10800`, `for: 15m`, `labels: severity: warning, service: fleet`.
- [ ] [accept 3] its annotations name the failing-run entry point `https://github.com/Nishfleet/{{ $labels.repo }}/actions/workflows/deploy-production.yml`, render the last good deploy via `{{ $labels.run_url }}`, and carry the phrase "product production deploy is stale — merges are not reaching users".
- [ ] [accept 7] do NOT change the `shipped_24h` tile's number: touch nothing that computes or exports the shipped tile, and prove with `git diff` that no shipped-24h line appears in the PR.
- [ ] [accept 8] no new control-plane alert: `fleet_deployment_*{repo="fleet-ops"}` metrics, thresholds and the `DeploymentLatencyHigh` / `DeploymentQualityStale` / `DeployBlockedStuck` rules stay byte-identical, and their existing tests must still pass untouched.
- [ ] keep `promtool check rules config/fleet_rules.yml` green after the edit.

## Phase 3: tests/fleet-deploy-quality.test.sh — fixture-driven assertions + promtool FIRES/SILENT
- [ ] [accept 5] add two scenarios to the section-7 embedded `promtool test rules "$scratch/fdq.test.yml"` block, driven by `input_series` fixtures (no network): last success 4h ago (`fleet_product_deploy_last_success_seconds{repo="0509",run_url="..."} 14400` together with the matching `fleet_product_deploy_up` series) -> `ProductDeployStale` FIRES; last success 5m ago (`300`, same companion) -> SILENT (`exp_alerts: []`).
- [ ] [accept 5] both scenarios run through that existing embedded block (no new test file, no new harness) and `promtool check rules config/fleet_rules.yml` stays green within the same run.
- [ ] give both fixture series IDENTICAL `{repo, run_url}` labels — `and` matches on the full label set, so mismatched labels make the rule silently never fire.
- [ ] add a fixture-driven module assertion block: `$scratch/product-runs.json` (repo -> `gh run list --json` array) plus `FLEET_DQ_PRODUCT_REPOS`, `FLEET_DQ_PRODUCT_RUNS`, `FLEET_DQ_PRODUCT_CACHE_DIR`, `FLEET_DQ_NOW`; assert the exact emitted product lines through `prom_lines()` and through the real exporter's `_emit_deploy_quality()`.
- [ ] assert the gh budget with a stub `gh` on PATH that appends one line per invocation: one scrape with 3 product repos issues exactly ONE product gh subprocess, and a warm-cache scrape issues zero.
- [ ] assert the filters: a PR-head success row and a `cancelled` row never set `last_success_seconds`; the no-success-ever fixture emits `fleet_product_deploy_up ... 1` + `+Inf`.
- [ ] assert the failure path: a dead gh (`FLEET_DQ_GH=/nonexistent/gh`) emits `fleet_product_deploy_up{...} 0` + NaN seconds while the exporter still exits clean with the fleet-ops family present.
- [ ] resolve the promtool annotation rendering ONCE, empirically: run a scratch copy of the test rules file, read the rendered annotations, and paste the observed `exp_annotations` into the committed test instead of guessing.
- [ ] prove it green end to end: `bash tests/fleet-deploy-quality.test.sh` exits 0 with the new scenarios and every pre-existing scenario.

## Review log

## Notes
- Acceptance tags map one-to-one: accept 1,2,4,6 -> Phase 1; accept 3,7,8 -> Phase 2; accept 5 -> Phase 3.
- `.fleet/plan.md` overwrites the stale fleet-ops#4894 install-compare plan.
- After implementation, verify live truth and paste the output into the PR: `bash tests/fleet-deploy-quality.test.sh` and `promtool check rules config/fleet_rules.yml`.
- PR-only: no merge, no deploy, branch off main, PR body carries `Closes #4995`.
