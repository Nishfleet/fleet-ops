# fleet-ops#5140 — plan

Manager-mode plan (difficulty: heavy). Branch `claim/issue-5140`, base `origin/main`
(`b581df4ca`). 131 product PRs merged in 24h have not reached a customer for 28h and
every dashboard says the opposite. One PR, four phases, manager opens and arms it.

## Manager amendments

- 2026-09-10: the original phase 1 (repo discovery + emission framework) and phase 2
  (real product measurement) are merged into ONE worker phase. Both edit the same
  ~200 lines of `lib/fleet-deploy-quality.py`; a split would leave phase 1 shipping a
  deliberately fake `up=0` for 0509 and phase 2 immediately replacing it, which is
  churn, not an independently reviewable slice.
- 2026-09-11: phases 2 (rule + exporter HELP) and 3 (fixture test + host line +
  rule-unit test) are merged into ONE worker phase — a rule without its firing
  test is not independently reviewable, and the new fixture test cannot pass
  before the gauge/rule it asserts exists. Phase 1 landed as 6ba1c5001 before a
  worker restart; this run picks up from it (session-pickup: prior plan and
  commit are authoritative).

## Review adjudication — phase 1 (reviewer pass, verdict BLOCK)

Act on (went to the retry worker):
- `subprocess.TimeoutExpired` escapes `_run` (`SubprocessError`, not `OSError`):
  a timed-out fetch skips `_PRODUCT_FETCHES_THIS_RUN += 1` and turns the designed
  narrow merges-outage into whole-repo `up=0`. Fix: catch
  `(OSError, subprocess.SubprocessError)` in `_run`.
- `tests/fleet-metrics-export.test.sh` `m.main()` heredocs resolve the real
  `config/intake-repos.json` -> 0509 and can spend real `gh` calls and write
  `deploy-quality-*-0509.json` into the production cache dir — exposure added by
  this diff. Fix: pin `FLEET_DQ_REPOS_JSON` to a fleet-ops-only fixture at those
  call sites.
- `_read_cache` raises `AttributeError` on valid-JSON non-dict cache files
  (list/str hit `c.get`), bricking the family permanently incl. the two new
  product cache files. Fix: `isinstance(c, dict)` guard.

Consider / Noted (recorded, not re-delegated):
- Product latency pairs a merge to a run by completion time only; a green run
  created before the merge but completing after it counts (biases latency low).
  Matches this issue's literal spec — follow-up material, not this PR.
- `fleet_deployment_quality_up{repo=<product>} 0` has no alert consumer —
  `DeploymentQualityStale` is `repo="fleet-ops"` scoped. Filed as a follow-up
  issue by the manager (unmeasurable-product-repo tripwire needs a warning rule).
- `_product_blocked` prints the LOWER-BOUND stderr line even on the
  all-createdAt-missing NaN path; `product_workflows` coerces a `null` override
  to the string "None"; `product_repos` is silent when `repos` is not a list.
  Cosmetic; noted for a future cleanup.
- `compute_product` trusts upstream repo-name sanitisation for cache paths;
  only `prom_lines` calls it today — defense-in-depth re-check deferred.
- Verified by reviewer and NOT issues: streak logic (trailing non-green only,
  in-flight fails closed, list-end = lower bound never clamped), one HELP/TYPE
  per name, fleet-ops rows first and byte-identical labels, prom_lines has no
  reachable raise, product gh budget separate from `_GH_FETCHED_THIS_RUN`,
  RUNS_TTL=120 < 5-min tick satisfies the 15-min visibility floor.

## Phases

- [ ] phase 1: `lib/fleet-deploy-quality.py` becomes multi-repo: `fleet-ops` exactly
      as today, plus every repo in `config/intake-repos.json` with `product: true`.
      A declared product repo that cannot be measured emits NaN for its gauges and
      `fleet_deployment_quality_up{repo="<r>"} 0` — never a silent absence.
- [ ] phase 1: for a GitHub-deployed product repo, measure the workflow that gates
      production (0509: workflow name `Deploy production`).
      `fleet_deployment_latency_seconds{repo="0509"}` = merge -> first green deploy;
      `fleet_deploy_blocked_duration_seconds{repo="0509",workflow=...}` = age of the
      current run of consecutive non-green `Deploy production` runs, 0 when the newest
      run is green. A 28h stall must be visible within 15 minutes of the stall starting.
- [ ] phase 1: no new timer, no new unit, no new service — ride the existing 5-minute
      `fleet-metrics-export` tick; the extra lookup uses the existing cache/TTL envelope
      and a hard-capped product gh budget that leaves `_GH_FETCHED_THIS_RUN` untouched.
- [ ] phase 2: new rule `ProductDeployStalled` (severity warning, NOT critical, must not
      page Nish): `fleet_deploy_blocked_duration_seconds{repo!="fleet-ops"} > 3600 for:
      15m`, annotation naming the repo, the workflow, the age and the newest red run URL.
- [ ] phase 2: emit a separate `fleet_product_deploy_green{repo}` gauge; do NOT change
      `fleet_main_ci_green` semantics — document in its HELP text that it tracks the
      workflow literally named `CI` only, and that deploy greenness is
      `fleet_product_deploy_green`.
- [ ] phase 3: regression test under `tests/` using the existing `FLEET_DQ_*` seams:
      a fixture of the last three `Deploy production` runs failed-failed-failed for 0509
      asserts `fleet_deploy_blocked_duration_seconds{repo="0509"} > 0` and a 0509 series
      in `prom_lines()`. No live gh call, no network.
- [ ] phase 3: do not raise, lower or silence any existing alert threshold — prove all
      five existing `fleet_deploy_quality` rules are byte-identical, and run the full
      existing `tests/fleet-deploy-quality.test.sh` green.

---

## Notes for the implementer

Read `lib/fleet-deploy-quality.py` (801 lines) in full before starting. Its module
docstring documents the env seams and the gh budget; keep both up to date.

### R1. Repo list resolution (in-repo, installed, and offline)

`compute(env)` and everything it calls stays byte-for-byte as today: it is the
fleet-ops payload and the existing test pins its numbers. Add a *separate* product
path next to it.

Resolve the product set with the proven `_INTAKE_CANDIDATES` pattern from
`lib/fleet-product-slo.py:172-177` (do not invent a new mechanism):

```python
_INTAKE_CANDIDATES = (
    FLEET_DQ_REPOS_JSON (env, highest priority)
    , Path(__file__).resolve().parents[1] / "config" / "intake-repos.json"   # in-repo / tests
    , f"{HOME}/workspaces/tooling/fleet-ops-deploy-clone/config/intake-repos.json"
    , f"{HOME}/workspaces/tooling/fleet-ops/config/intake-repos.json"
    , f"{HOME}/.local/share/fleet-ops/config/intake-repos.json"
)
```

`product_repos(env)` returns the sorted names of `repos[]` entries with
`product is True`, excluding `fleet-ops`, sanitised against `^[A-Za-z0-9._-]+$`
(these names become cache filenames — never let an unsanitised name through).
Missing/unparseable file -> `[]` plus one stderr line
(`deploy-quality: intake-repos.json not found (fleet-ops only this scrape)`).
Never raise, never invent a repo, never fall back to "all repos".

Workflow resolution — a declared table, because `intake-repos.json` carries no
workflow field and probing costs a gh call per repo per scrape:

```python
# Repos whose production gate is a GitHub Actions workflow. The value is the
# workflow name `gh run list --workflow` expects (the workflow's `name:`).
# A product repo absent from this table cannot be measured and is reported as
# up=0 rather than silently skipped (fleet-ops#5140 accept 1). env seam:
# FLEET_DQ_DEPLOY_WORKFLOWS = path to a JSON object overriding this table.
PRODUCT_DEPLOY_WORKFLOWS = {"0509": "Deploy production"}
```

A product repo with no entry -> NaN gauges + `fleet_deployment_quality_up{repo} 0`
+ a stderr line. That is the tripwire to add the entry; it is not a bug.

**Every product repo in `intake-repos.json` must appear in the output.** That is
the "never a silent absence" rule.

### R2. Emission shape (`prom_lines`)

`prom_lines(env)` becomes the single entry point and **must not raise**:

1. fleet-ops payload: `try: p = compute(env)` -> `except Exception as exc:` log
   `deploy-quality: fleet-ops ...: {exc}` and build a failed payload (every gauge
   `None`, `up=0`). Do **not** re-raise: the exporter's own fallback is for a
   module load failure, and a second HELP/TYPE block for the same metric name
   breaks the one-HELP-per-name discipline that
   `tests/fleet-metrics-export.test.sh:1035-1045` enforces over full `main()`
   output.
2. each product repo: `try: pp = compute_product(repo, workflow, env)` -> on
   failure, a failed payload for that repo only (never for its siblings).
3. emit `# HELP`/`# TYPE` **exactly once per metric name**, then the series
   grouped so **fleet-ops comes first**: iterate metric names in order, and for
   each metric emit the fleet-ops row first, then the product rows.
   `tests/fleet-deploy-quality.test.sh:287-294` uses `line.startswith(name + " ")`
   + `break` — a product row emitted before a fleet-ops row silently supplies the
   wrong value.

Metric-by-metric contract:

| metric | fleet-ops | product repo |
|---|---|---|
| `fleet_deployment_latency_seconds` | unchanged | `{repo="<r>"}` |
| `fleet_deployment_rollback_rate` | unchanged | **no series** (auto-revert is fleet-ops machinery) |
| `fleet_deployment_time_to_detect_seconds` | unchanged | **no series** (reads `alert-repair/actions.log`) |
| `fleet_deployment_success_rate` | unchanged | **no series** (same) |
| `fleet_deploy_blocked_duration_seconds` | unchanged `{repo="fleet-ops"}` | `{repo="<r>",workflow="<w>"}` |
| `fleet_deployment_quality_up` | unchanged | `{repo="<r>"}` |
| `fleet_deployment_total` / `fleet_deployment_revert_total` | unchanged | **no series** |
| `fleet_product_deploy_green` | **no series** | `{repo="<r>"}` |
| `fleet_product_deploy_last_red_run_info` | **no series** | `{repo="<r>",workflow="<w>",url="<u>"} 1` |

Fleet-ops series must stay byte-identical in name **and label set** — do not add a
`workflow` label to `{repo="fleet-ops"}`. Absence (not a NaN row) is the honest
answer for the three fleet-ops-only metrics on a product repo; say so in the HELP
text for those three.

New HELP strings (keep them one line each, exporter style):

- `fleet_deploy_blocked_duration_seconds` -> `"Age in seconds of the current non-green deploy episode per measured repo: fleet-ops = run of consecutive DEPLOY-BLOCKED fleet-deploy-check cycles; a GitHub-deployed product repo = age of the current run of consecutive non-green production-deploy runs (an in-flight run counts as non-green), 0 when the newest run is green, NaN when the repo could not be measured this scrape. fleet-ops#2725, fleet-ops#5140."`
- `fleet_deployment_quality_up` -> `"1 when the deploy-quality computation succeeded for this repo this scrape, 0 when it failed (that repo's gauges are NaN). fleet-ops#2758, fleet-ops#5140."`
- `fleet_product_deploy_green` -> `"1 when the newest run of this repo's production-deploy workflow concluded success, 0 when it did not, NaN when the repo could not be measured this scrape. Deploy greenness lives here; fleet_main_ci_green tracks only the workflow literally named \"CI\". fleet-ops#5140."`
- `fleet_product_deploy_last_red_run_info` -> `"1 on the newest non-green run of a product repo's production-deploy workflow, carrying that run's url so ProductDeployStalled can name it; absent when the newest run is green or the repo could not be measured this scrape. fleet-ops#5140."`

`fleet_deployment_latency_seconds` help gains a clause: `... per measured repo:
fleet-ops = mergedAt -> first green fleet-deploy-check cycle; a product repo =
mergedAt -> first green production-deploy run.`

### R3. Product measurement (`compute_product(repo, workflow, env)`)

Runs source. `gh run list --repo Nishfleet/<r> --workflow <workflow> --limit 30
--json databaseId,status,conclusion,createdAt,updatedAt,url`. Seam
`FLEET_DQ_DEPLOY_RUNS` = path to a JSON **object** `{repo: [run, ...]}` (runs
newest-irst). Cache file `deploy-quality-runs-<repo>.json` under
`FLEET_DQ_CACHE_DIR`, TTL `RUNS_TTL = 120` (shorter than the 5-min tick, so the
list is refetched every tick and a new stall is visible on the next tick),
stale `RUNS_STALE = 3600`.

Merges source. Reuse `_merged_records`' shape but per repo: seam
`FLEET_DQ_PRODUCT_MERGED` = path to a JSON object `{repo: [{mergedAt}]}`; live
path `gh pr list --repo Nishfleet/<r> --state merged --search "merged:>=<cutoff>
base:main" --limit 5000 --json number,mergedAt`; cache
`deploy-quality-merged-<repo>.json`, TTL `GH_TTL`, stale `GH_STALE`.

gh budget. **Leave `_GH_FETCHED_THIS_RUN` and `_cached()`'s legacy branch exactly
as they are.** Add a second, explicitly capped budget:

```python
_PRODUCT_FETCHES_THIS_RUN = 0
MAX_PRODUCT_FETCHES_PER_SCRAPE = 2
PRODUCT_GH_TIMEOUT = 15
```

and a `_cached_product(cache_path, ttl, stale, fetcher, env)` that consults the
counter instead of the boolean (increment it whether the fetch succeeds or fails,
matching the legacy flag). Order the product compute path **runs first, merges
second**. Record in the commit message why the alternatives were rejected: (a) a
new drop-in `ExecStart` process = a new organ, forbidden by accept 6 and it
splits the family; (b) reading `lib/fleet-product-slo.py`'s merged-PR cache = a
hidden cross-module cache contract. Worst added wall time is 15s per fetch and
`systemd/fleet-metrics-export.service` sets no `TimeoutStartSec` (systemd default
90s) — note that in the PR body.

`_run()` must not explode on a missing gh binary: wrap the `subprocess.run` in
`try/except OSError` and return `None` (today a missing `FLEET_DQ_GH` raises
`FileNotFoundError`, which would break `prom_lines`' no-raise contract).

blocked duration. Only `conclusion == "success"` is green. `cancelled`,
`failure`, `timed_out`, `startup_failure`, `skipped`, `neutral`, `""`
(in-flight) are all non-green — fail closed, and the live 0509 shape is exactly
`pending/cancelled/in_progress/failure`. Walk runs newest -> oldest while
non-green; `blocked_duration = now - createdAt` of the **oldest run in the
trailing non-green streak**, `0.0` when the newest run is green. If the streak
reaches the end of the fetched (limit-30) list, the value is a lower bound —
print one stderr line, never clamp to 0.

green. `1` when the newest run concluded `success`, else `0`; NaN when the repo
could not be measured.

last red run. When the newest run is non-green emit
`fleet_product_deploy_last_red_run_info{repo,workflow,url} 1`; otherwise emit no
row. No `url` label is ever placed on `fleet_deploy_blocked_duration_seconds` —
a URL that changes on every new run creates a new series, and a new series
restarts the rule's `for: 15m` timer, so the alert would never leave `pending`.
That is the 28h-invisible stall this issue exists to kill.

Latency. For each merge `m`, the first run with completion time
(`updatedAt` else `createdAt`) `>= m` and `conclusion == "success"` gives
`sample = completion - m`. Exclude merges older than the oldest fetched run
(unmeasurable — the `m < journal_start` lesson from fleet-ops#3136). p95 over
the samples via the existing `_p95`; `None` (NaN) when there are no samples.

### R4. Rule (`config/fleet_rules.yml`)

Add `ProductDeployStalled` to the **existing** `fleet_deploy_quality` group, after
`DeployBlockedStuck`. No new group, no new file:

```yaml
      # fleet-ops#5140: a product repo's production deploy has been non-green
      # for over an hour. Deliberately warning, NOT critical: a stalled product
      # deploy stalls customer-facing work, it does not page Nish. fleet-ops
      # keeps DeployBlockedStuck (>900s, critical).
      - alert: ProductDeployStalled
        expr: fleet_deploy_blocked_duration_seconds{repo!="fleet-ops"} > 3600
        for: 15m
        labels:
          severity: warning
          service: fleet
        annotations:
          summary: "{{ $labels.repo }} production deploy stalled: {{ $labels.workflow }} non-green for {{ $value | humanizeDuration }}"
          description: "..."
```

The summary/description must name the repo, the workflow, the age and the newest
red run URL. Get the URL from the info series with Prometheus' `query` template
function, e.g. `{{ with query "fleet_product_deploy_last_red_run_info" }}{{ . | first | label "url" }}{{ end }}` —
if `promtool test rules` refuses to expand it, drop that clause and say so in the
PR body; never move the URL onto the duration series.

The **five existing rules in the group must be byte-identical**:
`tests/fleet-deploy-quality.test.sh:352-437` replays their `exp_labels` and
`exp_annotations` verbatim, and `tests/fleet-rules-severity-page.test.sh:46-49`
pins exactly one `severity=page` alert in the whole file (leave it alone).

Add a rule-unit test for the new alert in `tests/fleet-deploy-quality.test.sh`
(hosted there already): fires past 3600s for 15m at `severity: warning`, silent
when the newest run is green.

### R5. Exporter (`libexec/fleet-metrics-export.py`)

Two edits only:

1. `HELP_CI` at line 196 gains the clause that it tracks the workflow literally
   named `CI` ONLY and that a repo's production-deploy greenness is
   `fleet_product_deploy_green`. No test pins this string (checked).
2. Nothing else. `_deploy_quality_mod()`, `_DQ_GAUGES` and
   `_emit_deploy_quality()` stay byte-identical — the fallback block is now only
   reached on a module load failure, which the comment should say.

`libexec/fleet-metrics-export.py` **is a registered organ**
(`config/fleet-organs.json` -> `fleet-metrics-export.service` /
`FleetMetricsExportMissing`). Touching it obliges the `absent(...)` rule to stay;
do not remove it. `lib/fleet-deploy-quality.py` is not an organ and does not
become one.

### R6. Tests

New file `tests/fleet-product-deploy-0509.test.sh` (the issue's verify block names
this exact path), hermetic: no gh, no network, `FLEET_DQ_GH=/nonexistent/gh` as
belt and braces. It must assert all of:

- fixture of the last three `Deploy production` runs failed-failed-failed for
  0509 -> `fleet_deploy_blocked_duration_seconds{repo="0509",...} > 0`
- a 0509 series appears in `prom_lines()`; fleet-ops series come first
- newest run green -> `fleet_deploy_blocked_duration_seconds{repo="0509",...} 0`
- a declared product repo with an unreadable runs source emits NaN gauges plus
  `fleet_deployment_quality_up{repo="<r>"} 0`, while the fleet-ops series still
  equals its existing pinned numbers
- `fleet_product_deploy_green{repo="0509"}` is 1 green / 0 red
- exactly one `# HELP` / `# TYPE` per metric name across the whole output

**Host the new file** from `tests/ci-standards-audit.test.sh` with a
`bash "$here/fleet-product-deploy-0509.test.sh"` line plus a short comment, in the
style of the existing `fleet-deploy-quality.test.sh` host at line 356. Without the
host line `tests/p14-test-listing-gate.test.sh` fails ("neither in ci.yml, hosted
by a listed test, live/destructive, nor a known orphan") and the worker App cannot
edit `.github/workflows/**`.

`tests/fleet-deploy-quality.test.sh`: add a fleet-ops-only `intake-repos.json`
fixture and set `FLEET_DQ_REPOS_JSON` in the section-5 and section-6 env dicts so
those runs can never reach for a live product repo. Change **nothing** else — no
existing expected number, label or annotation golden.

### R7. Verification commands

```
bash tests/fleet-deploy-quality.test.sh
bash tests/fleet-product-deploy-0509.test.sh
bash tests/fleet-metrics-export.test.sh
bash tests/p14-test-listing-gate.test.sh
bash tests/ci-standards-audit.test.sh
bash tests/fleet-rules-severity-page.test.sh
promtool check rules config/fleet_rules.yml
python3 -c "import ast;ast.parse(open('lib/fleet-deploy-quality.py').read())"
```

Live run-proof for the PR body: run the exporter once against the live box and
show the new `repo="0509"` series and the real ~28h blocked duration, e.g.
`python3 lib/fleet-deploy-quality.py --prom | grep 'repo="0509"'`.

### R8. Risks

- A second HELP/TYPE per metric name reds two tests. Emit once per name.
- Emitting a product row before its fleet-ops row silently supplies the wrong
  value to the existing first-match assertions.
- Per-repo failure must degrade that repo only; never let one repo's exception
  NaN the whole family.
- The PR will be net-positive in lines: the PR body needs a
  `net-positive-because:` line or `bin/prove-one-run-check` REJECTs it.
- Do not add `ProductDeployStalled` to `libexec/alert-repair-dispatch`'s
  `SKIP_SET`: the issue's impact section explicitly wants a repair lane for the
  product outage, and warning severity does not page Nish.
