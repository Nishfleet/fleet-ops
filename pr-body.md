## Why

A fleet-ops PR with green fleet-ops tests was blocked by a cross-repo
failure cluster: 0509's `Deploy production` and `codex-node-checks
(merge_group)` loops were failing repeat-deterministically, nothing in
fleet-ops caused them, and the blocked PRs partly fixed them. The
stop-the-line detector must gate only the PR's OWN repo, and never fail a
fleet-ops check on a 0509 signature.

## Scope

`.github/scripts/repeat-deterministic-detector.mjs`:
- new `--block` (opt-in PR gate), `--own-repo`, `--pr-body`, `--now`.
- `selectBlockingRepeats` — a cluster blocks only when it is same-repo,
  its LAST failure is inside the now-anchored lookback, and it is not
  excluded by a fix PR referencing its tracking issue.
- `fetchSignatureIssues` / `ensureTrackingIssue` — find / file (via
  existing `bin/fleet-issue-file`) one tracking issue per same-repo
  signature.
- cross-repo repeats are advisory (reported + PR comment), never a
  failing check.
- exit 1 only when blocking repeats exist; else exit 0. Alert-only runs
  without `--block` are unchanged.
- GitHub annotations: blocking repeats are `::error`, others `::warning`.

`tests/repeat-deterministic-detector.test.sh` + new fixture
`same-repo-loop.json`: same-repo=1, cross-repo=0, Fixes#=0,
wrong-Fixes#=1, stale=0.

## Tradeoffs

- The failing repo's cross-repo tracking issue is filed by that repo's own
  detector instance (where it holds write scope); the fleet-ops gate cannot
  write across a repo boundary, so it stays advisory-only.
- Blocking is opt-in (`--block`) so the existing scheduled telemetry path
  never turns a same-repo alert into a red run by surprise.

## Blast Radius

Only the detector script and its test. Every existing invocation (telemetry
without `--block`) behaves identically (exit 0 with repeats reported). The
new gate path only activates when a caller passes `--block` + `--own-repo`.

## Verification

- `bash tests/repeat-deterministic-detector.test.sh` → all sections green,
  including the new gate section: `OK: repo-scoped blocking gate —
  same-repo=1 cross-repo=0 Fixes#=0 wrong-Fixes#=1 stale=0`.
- Exit-code contract proven by run:
  `node ... --from-json .../same-repo-loop.json --block --own-repo
  Nishfleet/fleet-ops --now 2026-09-05T04:00:00Z` → exit 1 (block).
  Same with `--pr-body` `Fixes #4242` → exit 0. Cross-repo fixture
  (`merge-queue-loop.json`) with `--own-repo Nishfleet/fleet-ops` → exit 0,
  repeats=1 blocking=0 (advisory).
- `node --check` on the .mjs → OK. `shellcheck` on the test → clean.
- Related P14 battery (`semantic-conflict-detector`, `red-on-main-detector`,
  `ci-failure-escalation-detector`, `pi-packet-guard`, `manifest-shape`,
  `intake-repos-shape`, `worker-token-fail-closed`, `required-check-purity`,
  `worker-prompt-size-ceiling`) → all green.
- `sgscan` → `No new security findings`.
- `crgate` → not signed in on this host (CodeRabbit needs `auth login`;
  noted, not performed).
- run-proof: detector exit-code contract exercised end-to-end in the fixture
  paths above (same-repo/cross-repo/fix-excluded/stale).

## Gate note

This PR edits `.github/scripts/repeat-deterministic-detector.mjs` — a
gate-path change. Per the gate-integrity rule it must NOT be self-attested;
a repository admin posts the `gate-integrity-attest:` comment after review.

## Mechanism

This fixes a detector bug. The prevention mechanism is the regression suite
in `tests/repeat-deterministic-detector.test.sh` that proves the guard
fires: same-repo blocks, cross-repo stays advisory (exit 0), a `Fixes
#<issue>` reference un-blocks, and stale clusters do not block.

net-positive-because: repo-scoped gating removes the cross-repo deadlock
(three orchestration PRs blocked on foreign 0509 clusters) while keeping
the same-repo stop-the-line signal, tested end-to-end.

Closes #3480
