# Pending: triage-close workflow for unclaimed unlabeled issues

Owner: Nishfleet/fleet-ops#3311.

## Why

On 2026-09-04 fleet-ops had 301 open issues, 139 unlabeled, 96 blocked. The
orchestrator closed 100+ by hand with the note `triage-closed-2026-09-04`.
This parks the mechanical replacement: GitHub's own `actions/stale` (the
standard, maintained action), zero custom code, a daily scheduled sweep.

Nish 2026-09-04 (battle-tested only): do NOT write this as a heartbeat
section. Use `actions/stale` with the exact parameters in `stale.yml`.

## What is in this directory

| file | role |
|---|---|
| `stale.yml` | The parked workflow. The nishfleet-worker App cannot push `.github/workflows/**`, so it lives here until a token with Workflows scope lands it at `.github/workflows/stale.yml`. |
| `README.md` | This file. |

## How the sweep behaves

- **Target:** unlabeled auto-filed issues. `only-issue-labels` is empty so
  the action sees every issue; `exempt-issue-labels` keeps the live queue
  and the landing set out of the drain (`critical-path`, `landing-0904`,
  `umbrella`, `agent-in-progress`, `agent-ready`, `escalate-senior`,
  `research-delta`, `red-on-main`, `stop-the-line`).
- **Timing:** `days-before-stale: 2`, `days-before-close: 0` — an issue idle
  48h (no activity on `updated_at`) is closed in the same run that marks it
  stale. PRs are never marked stale or closed (`-1` for both PR inputs).
- **Close note:** `triage-closed: unclaimed 48h; re-filed automatically if
  the condition recurs / re-file with a moves: line if it still matters`.
  `actions/stale` cannot template a date, so the literal `<date>` from the
  triage-closed convention is dropped; the re-file rule line is the contract
  the reader and the reconciler need.
- **API budget:** `operations-per-run: 30` (the action's default). The
  action is stateful — a capped run continues from the first unprocessed
  issue on the next schedule, so a big backlog drains across runs without
  exceeding the per-run cap.
- **Schedule:** daily 04:17 UTC (`17 4 * * *`), between
  repo-standards-sync (03:17) and ci-standards-audit (05:17).
- **Scope:** `contents: read`, `issues: write`, `pull-requests: write` only.
  Public repo, free Actions minutes, not a required check.

## How to land this (Nish / Workflows scope required)

The nishfleet-worker App has no `workflows` permission, so this file cannot
land under `.github/workflows/` on this PR. A token with that scope (Nish)
should:

1. `git mv docs/pending-stale/stale.yml .github/workflows/stale.yml`.
2. The test `tests/stale-pending-or-callable.test.sh` is already hosted from
   `tests/reusable-workflows.test.sh`, which is in the P14 `verify-command`
   of `.github/workflows/ci.yml` — no CI edit needed for it to keep running
   from the callable path once the file moves.
3. Delete `docs/pending-stale/`.
4. Workflow files are gate-owned paths: post the `gate-integrity-attest`
   comment (a different identity from the one that authored the change).

Until then, `tests/stale-pending-or-callable.test.sh` shape-locks the parked
source and validates every `with:` input name against the pinned
`actions/stale` action.yml (fetched at the pinned SHA).