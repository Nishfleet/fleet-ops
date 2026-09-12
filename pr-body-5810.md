A red-main repair PR must not wait its turn. `repair-queue-jump.mjs` gives every repair-labelled PR a head-of-queue enqueue (`jump:true`) instead of the plain `gh pr merge --auto` tail-append, plus an hourly reconciler safeguard, so the fix can never again sit behind the 14 queue entries whose group builds fail on the very bug it fixes.

## Why

2026-09-12: FleetMainRed fired 04:07Z. The repair lane opened 0509#3191 at 04:58Z — green, mergeable — armed auto-merge, and landed at the END of a 14-entry merge queue whose every group build failed on the bug #3191 fixed. It sat 57 minutes until a human ran dequeue + `enqueuePullRequest(jump:true)` by hand at 05:55Z. That hand step is the blind spot this PR closes.

## What

Three parts, all gated on one label family (the issue's `required:` bullets):

- **`.github/scripts/repair-queue-jump.mjs`** — the label-gated helper.
  - `enqueue --repo O/N --pr N` (entry jump): resolves the PR + queue in ONE GraphQL read; if the repair PR is queued mid-queue it is dequeued and re-enqueued at the head — the exact hand step run on #3191. Non-repair / no-queue / refused jump exit with fallback codes so the caller's plain armed auto-merge stands as the floor; a helper fault exits 2 loudly.
  - `sweep --repo O/N` (reconciler safeguard): when the queue HEAD has waited > 30 min and a repair-labelled PR waits behind it, the repair PR is jumped; a GREEN repair PR that never reached the queue is enqueued at the head directly (the issue's primary path). One `gh pr list` per repo per tick; the queue snapshot read only happens when a repair-labelled open PR exists — App rate-limit budget respected.
  - Gate: ONLY the `repair:` label prefix qualifies. `blocked-by-judge`, `no-auto-merge`, and `[no-merge]` titles refuse the jump even on a repair-labelled PR. `jump:true` never bypasses required checks — it only re-positions; the group build and the branch ruleset still gate the merge. No `--admin`, no force-merge.
- **`bin/fleet-heartbeat-tier1`**: block 2 labels every `revert/*` head `repair:main-red` on sight (consumer repos' inlined auto-revert.yml cannot be edited from here) and entry-jumps a repair-labelled PR right after its arm; new block 2b runs the sweep per enrolled repo. Failures log and never block the arm path.
- **`.github/scripts/auto-revert.sh`**: labels its own `revert/*` PR `repair:main-red` and entry-jumps it right after the arm (best effort; the hourly sweep retries a refused jump).
- **`libexec/alert-repair-dispatch`**: the alert-repair packet now instructs the repair worker to label + jump its own fix PR — the hop the orchestrator did by hand at 05:55Z.
- **`tests/repair-queue-jump.test.sh`** (hosted under `tests/seat-lib.test.sh`, CI): replays the 2026-09-12 14-entry incident snapshot (`tests/fixtures/repair-queue-jump/queue-2026-09-12.json`) and asserts #3191 is the selected jump and nothing else; stubbed-`gh` drills the dequeue + `enqueue(jump:true)` mutation shape (fields verified against the live schema 2026-09-12: `EnqueuePullRequestInput` = `pullRequestId` + `jump`; `DequeuePullRequestInput` = `id`), the guard refusals, and the sweep paths.
- **`docs/ci-standard.md`**: the auto-merge mechanics doc gains the repair-jump contract.

## Verification

- `bash tests/repair-queue-jump.test.sh` — ALL TESTS PASSED (label gate; the 2026-09-12 incident snapshot selects exactly #3191 with the head waited ~57 min; sweep guards; mutation shape; CLI drills; heartbeat/label/auto-revert wiring).
- `bash tests/seat-lib.test.sh` — PASS (full P3b CI-host chain, including the new repair-queue-jump test and #6037's re-hosted suite).
- `bash tests/fleet-heartbeat-rc-propagation.test.sh`, `bash tests/fleet-heartbeat-alarm-rc-decoupling.test.sh`, `bash tests/auto-revert-required-check-gate.test.sh`, `bash tests/alert-repair-claim-mutex.test.sh`, `bash tests/alert-repair-flagship-seat.test.sh` — all PASS (my two touched behaviour files' existing gates).
- `sgscan --base origin/main` — no new security findings (rc=0).
- Local drift note: while this was in flight, #6037 landed on main (re-host of #5993's dropped tests); this branch was re-based onto the true tip (32bed3c17). The #6037 rewrite already fixed the stale `seat.lib.test.sh` nesting-grep this branch's earlier salvage had patched; the only surviving touch here is the one-line repair-queue-jump CI-host registration in the re-hosted `tests/seat-lib.test.sh`.

## run-proof

- run-proof: `bash tests/repair-queue-jump.test.sh` → `ALL TESTS PASSED`; `bash tests/seat-lib.test.sh` → PASS (this file is the listed CI host: the same chain runs as a required P14 check on this PR's CI run).
CI: the P14 suite runs the P14 suite runs `tests/repair-queue-jump.test.sh` via `tests/seat-lib.test.sh` on this PR's CI run — the workflow run on this PR is the proof.

## Mechanism notes

net-positive-because: one 414-line helper + 85 heartbeat lines replaces a recurring human hand-step (every red-main incident needs a manual dequeue + jump:true, proven again at 05:55Z today); zero new systemd units, timers, workflows, labels, or languages — it runs inside the existing hourly fleet-heartbeat-tier1 pass and the existing repair lanes, and the 30-min head-wait safeguard deletes the human-on-call's 05:55Z step.

- organ-heartbeat: bin/fleet-heartbeat-tier1, libexec/alert-repair-dispatch, .github/scripts/auto-revert.sh not-an-organ: none of the three is a registered organ in config/fleet-organs.json (registry files[] lists only libexec/fleet-metrics-export.py, systemd units, and other exporters/guards); no absent() rule owed.
- drill: the acceptance's live drill ("a labelled PR on a test repo lands at the head") runs in a comment on this PR when possible; no repo in the org other than 0509 has a merge queue, and creating a merge-queue ruleset needs Administration, which this unit's App token does not carry. The queue-jump contract itself is proven by the incident-snapshot test plus the mutation-shape drill in tests/repair-queue-jump.test.sh.
- loose-ends: 5810-live-queue-jump-drill — the live head-of-queue drill on a merge-queue repo (only Nishfleet/0509 has one; needs a quiet queue window).

Closes #5810
