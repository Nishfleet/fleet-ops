## What

The heartbeat detector→queue reconciler (`lib/detector-queue-reconciler.py`)
auto-filed a never-green alarm for `CLAIM-CLOSED-RESET` (#5008) and its atomic
sibling `CLAIM-CLOSED-CLEANUP` (#5007).

`bin/pi-issue-failed-reap` writes `CLAIM-CLOSED-CLEANUP` then
`CLAIM-CLOSED-RESET` on **every** real reap of a CLOSED issue (live evidence:
instance=0509-2347 repo=Nishfleet/0509, tick 2026-09-10T15:48:43Z) as the
successful post-merge cleanup — the claim branch is already deleted, the
`agent-in-progress` label already removed, packets archived, and the dead
worker's per-issue state files (reclaim-count / systemic / infra-death /
prefer-class / last-death-class) reset so a re-opened issue starts fresh.

Both lines carry a `repo=` key, so `derive_signals()` derives per-repo keys
`loud/claim-closed-cleanup/<repo>` and `loud/claim-closed-reset/<repo>`.
Because every future closed-issue reap re-emits the same key, observe-to-close
can never go green and the reconciler refiles the alarm forever — exactly the
never-green loop already fixed for `CLAIM-REAP-STARTED` (#4918),
`CLAIM-RELEASED` (#4930) and `PACKETS-ARCHIVED` (#4955).

## Change

- Add `CLAIM-CLOSED-CLEANUP` and `CLAIM-CLOSED-RESET` to the reconciler's
  `SKIP_TAGS` (same class as the other reaper-completion tags). The actionable
  reaper failures (`CLAIM-REAP-BRANCH-FAIL` / `LABEL-FAIL` / `PARSE-FAIL` /
  `NO-GH`) still queue.
- `tests/signal-reconcile.test.sh`: scenarios `9m` / `9m-close`
  (CLEANUP) and `9n` / `9n-key` / `9n-close` (RESET) proving neither is queued,
  that the RESET key is repo-scoped and constant across instances, and that
  stale filed issues still observe-to-close once skipped even while their LOUD
  lines keep firing.

This is the tactical one-at-a-time addition the current pattern calls for.
The larger fail-closed registry + guard is tracked separately as #4983
(`needs-orchestrator`, out of scope here).

## Verification

- `bash tests/signal-reconcile.test.sh` → `OK: all signal-reconcile scenarios
  passed` (includes new 9m/9m-close/9n/9n-key/9n-close).
- `bash tests/pi-issue-failed-reap.test.sh` → all scenarios pass (the CLOSED
  branch that emits the two lines is untouched).
- `sgscan` → `No new security findings.`

organ-heartbeat: lib/detector-queue-reconciler.py not-an-organ: not a fleet
organ (timer/exporter/guard/canary) — the gate exits SKIP. tests/
signal-reconcile.test.sh likewise.

run-proof: tests/signal-reconcile.test.sh (9m, 9m-close, 9n, 9n-key,
9n-close); tests/pi-issue-failed-reap.test.sh; sgscan clean. No timer/workflow
touched.

## Test plan

Run `bash tests/signal-reconcile.test.sh`; expect `OK: all signal-reconcile
scenarios passed`. After merge, the next heartbeat tick should observe-to-close
#5008 (and #5007) and stop re-filing them on future CLOSED-issue reaps.

Closes #5008
Relates to #5007