fix(dedupe-gate): standards-drift suppression keys on the missing file (fleet-ops#4591)

## Problem

The fleet-ops#1212 filing gate (`lib/issue-file.py`) dedupes a filing against
open issues by title+body token overlap. Every standards-drift issue shares
template-identical prose, so two drift signals that differ ONLY in the missing
file (secret-scan.yml vs semgrep.yml) scored 1.00 as "duplicates" — one closed
secret-scan.yml issue (#4587) silently swallowed the semgrep.yml,
review-gate.yml and auto-enqueue.yml alarms. The dedupe keyed on the title
prefix / repo, not the concrete `standards-drift/<repo>/<file>` signal.

## Fix

`lib/issue-file.py` now treats the `standards-drift` family as one-item-per-
concrete-key: when both the candidate and an open issue carry disjoint
`signal: standards-drift/<repo>/<file>` keys (different missing file), the
shared boilerplate must not count as duplicate evidence. The score is capped
below the borderline threshold in `score_pair` so a distinct-file drift alarm
files clean (new), while a TRUE duplicate (same repo, same file — shared key)
still hits the primary-signal floor and is suppressed as before.

- New `SAME_ITEM_SIGNAL_FAMILIES = ("standards-drift",)` constant.
- New `DIVERGENT_SIGNAL_CAP` and `_same_item_signal_divergence()` helper.
- Guard applied inside `score_pair`, which feeds `best_match`, `cmd_file`,
  `cmd_score` and `cluster_issues` uniformly.

No gate-owned workflow files are touched; `fleet-escalation-canary`'s block-13
signal dedupe is unchanged.

## Verification (real runs)

```
$ bash tests/standards-drift-dedupe.test.sh
OK: distinct-file standards-drift files as new (semgrep vs secret-scan, score=0.39)
OK: distinct-file standards-drift files as new (secret-scan vs semgrep, score=0.39)
OK: same-file standards-drift still suppressed as duplicate (score=1.0)
OK: standards-drift dedupe keys on the missing file (fleet-ops#4591)
```

- `bash tests/issue-file.test.sh` (hosts the new regression test) — full PASS,
  all 8 pre-existing cases + the new hosted case 9.
- `bash tests/p14-test-listing-gate.test.sh` — PASS (P14 test list is closed;
  the new test is reached transitively via issue-file.test.sh ->
  ci-standards-audit.test.sh).
- `bin/sgscan` — no new security findings.
- Note: `tests/console-tile-verify.test.sh` fails identically on clean
  origin/main (live seat-health for minimax/MiniMax-M3) — pre-existing and
  unrelated to this change.

## run-proof
- `tests/standards-drift-dedupe.test.sh` — new regression test (hosted by
  `tests/issue-file.test.sh`).

## research / help-first
No new `bin/` file was added (only `lib/issue-file.py` + tests), so
`bin/research-before-build-check` is not applicable.

## Acceptance mapping
- [x] Dedupe/similarity key for standards-drift signals includes the file
      component (`signal: standards-drift/<repo>/<file>`), not just the repo +
      title prefix.
- [x] Prevention mechanism: regression test in `tests/` feeds two
      standards-drift signals differing only in file and asserts BOTH are
      filed (`new`), and feeds a true duplicate pair and asserts suppression
      still fires (`duplicate`).
- [x] No change to gate-owned workflow files.

Closes #4591

net-positive-because: the diff is +146 lines of durable prevention (a tested
scoring guard plus a regression test and its host line) that stops a
fleet-wide class of silently-swallowed standards-drift alarms; the git
net-positive is deliberate, not drift.