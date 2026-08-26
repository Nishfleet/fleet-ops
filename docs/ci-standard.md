# CI standard

The standing rule lives in the vault (`CI standard: batched, minimal, near-zero
failures`). This file is the part that belongs next to the reusable workflows
so a new check is written correctly instead of caught later.

Reusable workflows in this repo are the mechanism. Call them with `uses:`;
pass `inputs`; do not copy or override critical steps.

## PR checks (the batched standard)

`.github/workflows/reusable-pr-checks.yml` is the one job every product repo
should call. It is `workflow_call` only. Guarantees that are not optional:

- `timeout-minutes` on the job (override with the `timeout-minutes` input).
- `concurrency` + `cancel-in-progress: true` for PR/push.
- npm cache when `install-command` is set.
- docs-only PRs skip install/verify inside the job, so the check still reports.
- gitleaks (pinned binary, no license) when `scan-secrets` is true.

Same-repo caller: `uses: ./.github/workflows/reusable-pr-checks.yml`.
Other repos: `uses: Nishfleet/fleet-ops/.github/workflows/reusable-pr-checks.yml@main`.

`.github/workflows/reusable-auto-merge-arm.yml` is the matching auto-merge job.
Callers keep the `pull_request` trigger and pass `AUTO_REVERT_PAT` explicitly.

`template/.github/workflows/` is the starter caller set for a new repo.

## Required checks are pure

A required status check must be a function of the PR's own diff.

**Wrong:** `counts[marker] !== ceiling` against a committed JSON file, or any
gate that fails unless the PR runs `--update` on a shared baseline.

That shape is a global lock. Two PRs that are each legal alone collide in the
merge queue over one number. 0509's design-system ratchet (issue #1056 there)
is the textbook case.

**Right:** fail only when a count exceeds its ceiling (`>` / `<=`). Tighten
the ceiling on main after merge — a scheduled or push-triggered job, not the
contributor PR.

Same idea as ESLint `--max-warnings`, Betterer, Sorbet `srb rbi todo`, and
RuboCop `.rubocop_todo.yml`.

Exact equality is still correct for pinning a downloaded binary (sha256 of
shellcheck, gitleaks). That pin is not a shared counter every PR must edit.

## The audit

`.github/scripts/ci-standards-audit.mjs` checks every non-archived repo
from the GitHub API, resolving each repo's real default branch. It reports a
gap matrix per repo and per workflow for the rules below, and opens fix PRs
for the one gap that is safe to fix mechanically: missing `auto-revert.yml`
on repos that already have a green push-to-main CI workflow and required
checks. All other gaps are recorded with their reason, because values like
`timeout-minutes` or cache keys cannot be guessed safely without repo
context.

`.github/workflows/ci-standards-audit.yml` is the reusable caller. It is an
alert/audit, not a required check.

## The lint

`.github/scripts/required-check-purity.mjs` flags the wrong shape.

`.github/workflows/ci-required-check-purity.yml` is the reusable caller.
It is **advisory** (warn, do not block) until existing instances are fixed.
Promote with `enforce: true` after 0509#1056 lands.

## Classify before retrying

A retry is only worth a run when the failure could go away on its own.
Top teams split failures first:

- **assertion failure** (a test, a lint, a build, a deploy that errors on
  the code) -> stop. Do not re-arm, do not re-queue. The code has to change.
- **infra / network / timeout** (a flaky runner, a 5xx, a rate limit, a
  fetch that timed out) -> retry with backoff.

The mechanical signal is: the same `(workflow, job, step, assertion)`
signature failed `3` times within `6` hours. That is a
**repeat-deterministic** failure. Re-arm cannot fix it; the alert says so.

This is the rule both 2026-08-25 loops broke: "Deploy production" retried
an identical hard wrangler error 6x (11:09 -> 14:06), and 0509 PR #994
re-entered the merge queue 6x (19:51 -> 22:21) failing the same assertion
every time. Neither was retryable.

## The detector

`.github/scripts/repeat-deterministic-detector.mjs` implements the rule.
Replay a loop with `--from-json`; run it live with `--repo`.

`.github/workflows/ci-failure-telemetry.yml` is the reusable caller — the
same workflow that already runs the semantic-conflict detector, so every
repo gets both alerts from one `uses:` call. It is an alert, not a gate.

## Red on main

Auto-revert may only watch a workflow that is already green on main.
Watching a permanently-red workflow would revert every commit forever.

Detecting red is a different job. `.github/scripts/red-on-main-detector.mjs`
covers every workflow from its first run, including ones that have never
been green. A first-ever main failure is called out as merged untested
against main. The signal opens (or reuses) an issue. It does not revert.

`.github/workflows/red-on-main-detector.yml` is the reusable caller.
`.github/workflows/red-on-main-watch.yml` is the 15-minute sweep other
Nishfleet repos get via repo-standards-sync. Do not make either a
required check.
