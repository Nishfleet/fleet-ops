## Why

The 8 named CONFLICTING PRs are already CLOSED or MERGED. Prevention prompt text landed in #4488, but `tests/weekly-fleet-review.test.sh` did not grep it, so the namecheck could vanish without CI failing. This PR is the #366 test gate, and `Closes #4471` lets GitHub close the owner-authored record that observe-to-close must leave open.

## Scope

- `tests/weekly-fleet-review.test.sh` now requires the L1 strings: `Stale CONFLICTING-PR namecheck (fleet-ops#4471)`, `mergeable:CONFLICTING`, `older than 7 days`, and the pinned `gh pr list` query.
- No prompt edit. No new `bin/`. No organ.

Named PRs (live `gh pr view --json state`): #4308 CLOSED, #3912 CLOSED, #3289 CLOSED, #2087 MERGED, #2029 CLOSED, #1582 MERGED, #1282 CLOSED, #9 CLOSED.

Open CONFLICTING left: #4422 and #4192, both excluded by this issue's dedupe. Weekly namecheck owns them once they are 7 days old.

## Tradeoffs

Prompt-only prevention stays; this PR does not extend `bin/fleet-dead-pr-detector` (that detector is parent-resolved CONFLICTING PRs, a different class). The issue accepted the weekly-review prompt path.

## Blast Radius

Only the weekly-fleet-review prompt-contract test. A deleted namecheck section fails CI. Runtime weekly review behaviour is unchanged.

## Verification

```
$ bash tests/weekly-fleet-review.test.sh
OK: (f) prompt locks the 5-action cap, signal, blind 8-lens structure (incl. SECURITY), claimed-work-only, baseline-delta input, #4471 CONFLICTING namecheck
OK: weekly-fleet-review: matrix, MANIFEST, agent-cron-run slug, timer, install, prompt contract, role gate, stubbed run
(exit 0)

$ # negative: strip the heading, grep fails
$ sed '/Stale CONFLICTING-PR namecheck (fleet-ops#4471)/d' prompts/weekly-fleet-review.md | grep -q 'Stale CONFLICTING-PR namecheck (fleet-ops#4471)'; echo rc=$?
rc=1

$ sgscan --base origin/main
No new security findings. (exit 0)
```

The `crgate --agent` call failed with exit 3: CodeRabbit is not signed in on this machine.

run-proof: `tests/weekly-fleet-review.test.sh` exit 0 (matrix + MANIFEST + prompt contract including #4471 namecheck + stubbed agent-cron-run). No unit/timer/workflow diff.

research: no new `bin/` files. Official docs consulted: `gh pr list --help` (JSON fields include mergeable, updatedAt; `--state open` is the default-open listing the prompt pins). Existing rails: `bin/fleet-dead-pr-detector` flags CONFLICTING PRs whose parent issue already resolved — different class than 7-day-old open-origin CONFLICTING PRs, so the weekly prompt remains the #4471 path.

help-first: `gh pr list --help`, `bin/prove-one-run-check --help`, `bin/research-before-build-check --help`, `sgscan --help`, `bin/fleet-organ-heartbeat-check --help`, `bin/fleet-token-efficiency-check --help`, `bin/fleet-exec-review-canary --help`.

organ-heartbeat: tests/weekly-fleet-review.test.sh not-an-organ: prompt-contract test lock, no heartbeat metric

net-positive-because: +15/-2 on the existing test so the #4488 prompt section cannot be deleted without CI failing; no new machinery.

loose-ends: crgate-unsigned

Closes #4471
