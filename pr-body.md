## What changed and why

Child of #3127 (part 1/4). Adds ONE reviewer round before the auto-merge arm for product repos, using the stock `reviewer` subagent.

- **prompts/worker.md**: new step 8 "Reviewer round (product repos only)" precedes the auto-merge arm (now step 9). For repos in `config/intake-repos.json` marked `product` (0509, siterep-public, inish-site), the worker runs `Use reviewer to review the diff origin/main...HEAD against the issue acceptance and the repo tests` on the strongest usable seat from the yield ledger (#3122), never the worker's own seat. Findings land in the review-adjudication buckets (Act on / Consider / Noted / Dismissed-with-reason) in the PR body; Act-on items are fixed before arming. One round only; no loops.
- **config/intake-repos.json**: marks 0509, siterep-public, inish-site as `product: true` (the trigger set for the reviewer round).
- **tests/worker-prompt-reviewer-round.test.sh** (new): locks the reviewer-round contract in worker.md and the product marking in intake-repos.json. Hosted in `tests/pi-issue-start.test.sh` (workers have no Workflows permission, so it rides an existing CI-listed host).
- **prompts/worker.md**: trims redundant failed-command prose to keep the worker packet under the 32768B size ceiling (fleet-ops#1902) after the step-8 addition.

Sibling parts own the depth-1 spawn guard (#3265), the fleet-ops exemption (#3266), and the senior-seat mechanism (#3267); this PR does not re-implement those.

## Verification

Exact commands and observed output:

```
$ bash tests/worker-prompt-reviewer-round.test.sh
OK: worker.md carries the reviewer prompt
OK: reviewer round (step 8) precedes the auto-merge arm (step 9)
OK: review-adjudication buckets (Act on / Consider / Noted / Dismissed-with-reason) present
OK: reviewer round is one round only; no loops
OK: intake-repos.json marks 0509, siterep-public, inish-site as product
OK: CI host exists (ci.yml listed=0 pi-issue-start hosted=1)
OK: empty-host drill trips (neither host matches empty files)
worker-prompt-reviewer-round: PASS

$ bash tests/worker-prompt-size-ceiling.test.sh
OK: worker packet is 32764B, under 32768B ceiling
OK: longest worker.md line is 1776B, under 4096B per-line cap
OK: core failed-command rule, no-match-probe exception, and lint pointer all present
worker-prompt-size-ceiling: PASS

$ bash tests/pi-issue-start.test.sh   # hosts the new test
PASS

$ bash tests/intake-repos-shape.test.sh
PASS

$ for f in tests/fleet-failed-command-*.test.sh tests/intake-repos-shape.test.sh tests/fleet-product-slo.test.sh tests/worker-prompt-*.test.sh; do bash "$f"; done
failures: 0
```

All 40+ `tests/fleet-failed-command-*.test.sh` and worker-prompt tests that lock worker.md lines pass after the prose trim (verified individually).

`sgscan` reports "No new security findings."

net-positive-because: adds a documented review step and a contract-locking test; removes (trims) no functionality — the worker packet stays under the proven ceiling.

moves: product_merges_per_day

Closes #3264
