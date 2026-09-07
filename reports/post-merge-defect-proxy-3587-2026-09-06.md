# QualityPostMergeDefectsCeiling firing at 74.07 — defect-class analysis + mechanism fix (fleet-ops#3587)

Report date: 2026-09-06
Issue: fleet-ops#3587 — "QualityPostMergeDefectsCeiling firing at 74.07 since 2026-09-05T08:46Z"
Host: netcup-rs2000

## Alert snapshot (2026-09-05T08:46:19Z, issue body)

- `QualityPostMergeDefectsCeiling` firing on **repo=0509**
- `fleet_product_quality_post_merge_defects_per_100{repo="0509"}` = **74.0740740** (= 20/27)
- ceiling = 40.0 (`config/quality-ratchet.json` `ceilings.0509.post_merge_defects_per_100`)
- `FleetSelfMaintenanceRegression` pending at -0.284
- `FleetQueueSelfMaintenanceRatioHigh` firing continuously since 2026-08-29 at 0.716/0.735

## What the metric measured (the broken proxy)

`lib/fleet-product-slo.py` `compute_repo_slo` counted a merge as a post-merge
defect when:

```python
if pr.issue_created_ts is not None and pr.issue_created_ts > week_cut:
    defect_merges += 1
```

`pr.issue_created_ts` is the `createdAt` of the **closing issue the PR was
built to solve** (from `closingIssuesReferences`). The check is "the PR's own
issue was filed within the trailing 7 days" — which is just **normal
throughput** (an issue filed and resolved within a week), not a defect.

The fleet's normal flow is: issue filed → worker claims it → PR merges
closing it, often within days. So ~74% of merges closed an in-week issue and
were flagged as "defects". The proxy conflated "issue is recent" with "issue
is a defect report".

## Defect classes driving the 74 (live cache, 0509, trailing 7d)

Source: `agent-state/fleet-metrics/product-slo-cache.json` (fetched 2026-09-05),
62 in-week 0509 merges flagged as "defects" by the old proxy, classified by PR
title prefix:

| PR class | Count | Share | Real defect? |
|----------|-------|-------|--------------|
| fix      | 32    | 52.5% | No — closes its own in-week original issue |
| feat     | 17    | 27.9% | No — feature work |
| docs     | 3     | 4.9%  | No |
| test     | 3     | 4.9%  | No |
| BET      | 2     | 3.3%  | No |
| ci / other | 4   | 6.5%  | No |

**Top class: normal `fix:`/`feat:`/`test:`/`docs:` PRs closing their own
in-week original issue** — 100% of the count is false positive.

A 25-PR live sample confirmed **0 of 25** flagged 0509 PRs close a
defect-labeled (`bug`/`design-defect`/`deploy-regression`/`red-on-main`) issue.
The alert-repair run on 2026-09-05T11:21Z independently found "0509 7d=59
merges/43 flagged, **0 issues after merge**, 1 revert(1.7<4.5) => not real
defect outflow".

## Mechanism-level fix (this PR)

The only signal that separates a defect report from the PR's own original ask
is the **issue label** — timestamps cannot (every PR closes an issue filed
before it merges). The fix changes the proxy to count a merge as a
post-merge defect only when it closes an in-week issue carrying a defect-class
label:

```python
DEFECT_ISSUE_LABELS = frozenset(
    {"bug", "defect", "regression", "design-defect", "deploy-regression", "red-on-main"}
)
...
if (pr.defect_issue_created_ts is not None
        and pr.defect_issue_created_ts > week_cut):
    defect_merges += 1
```

- `MergedPR.defect_issue_created_ts` = earliest `createdAt` among closing
  issues that carry a defect-class label (None when no closing issue is a
  defect report).
- The GraphQL `closingIssuesReferences` fragment now fetches
  `labels(first: 20) { name }` so the exporter can see them.
- The cache round-trips the new field.

Effect: 0509's `post_merge_defects_per_100` drops from ~52-74 to ~0 (no
bug-labeled closing issues in the live sample), below the 40 ceiling →
`QualityPostMergeDefectsCeiling` clears on the next export tick. Real
defects (a merge that closes a `bug`-labeled issue filed this week) are still
counted.

## Scope boundary

The broader ceiling redesign — `sessions_to_pr_pct` proxy, baseline-seeded
ceilings, and a replay backtest drill — is fleet-ops#3759 (agent-ready). This
PR fixes only the top false-positive class driving the 74 (the defect-count
proxy), which is the mechanism feeding the live alert and the
self-maintenance narrative. #3759 should be narrowed to the remaining
sessions/ceiling/drill work.

## Verification

- `bash tests/fleet-product-slo.test.sh` — green; the (k) fixture now proves
  a `feat:`/`fix:` PR closing a non-defect in-week issue is NOT counted, and
  a `fix:` PR closing a `bug`-labeled in-week issue IS counted.
- `bash tests/quality-ratchet.test.sh`, `tests/quality-slo-staleness.test.sh`,
  `tests/fleet-metrics-export.test.sh` — green.
- `bin/sgscan` — no new security findings.
