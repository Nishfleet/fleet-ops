# Pending: cancelled-while-queued workflow YAML

The nishfleet-worker App has no `workflows` permission, so this file
cannot land under `.github/workflows/` on this PR. A token with that
scope (Nish) should:

1. `git mv docs/pending-cancelled-while-queued/cancelled-while-queued.yml .github/workflows/`
2. Delete this directory.

The detector itself (`.github/scripts/cancelled-while-queued-detector.mjs`)
is independent of the workflow file and lands in this PR. The workflow
is the cron + workflow_call wrapper that schedules the sweep every 30
minutes. Until the workflow lands, the detector can be run by hand:

```
node .github/scripts/cancelled-while-queued-detector.mjs \
  --targets-from config/intake-repos.json \
  --dry-run --output-json /tmp/cwq.json
```

or without `--dry-run` once the issue label `cancelled-while-queued`
exists in `Nishfleet/fleet-ops` and the calling identity has
`actions: read` + `issues: write` scopes.

## Why a 30-minute schedule

GitHub's "Workflow continuity" rule (see
`https://docs.github.com/en/actions/concepts/runners/github-hosted-runners#workflow-continuity`)
discards a queued run after 45 minutes of no runner pickup. The
detector's default threshold is 30 minutes — 15 minutes before the
silent discard — so the cancel lands in run history and is observable.
A 30-minute cron is the cheapest mechanical form that still lands
inside that 45-minute window. The detector itself is stateless beyond
the open labelled issues, so a missed sweep costs nothing.

## Triggers

- `workflow_call` — any enrolled repo can call this reusable workflow
  for itself.
- `workflow_dispatch` — manual trigger from the Actions tab.
- `schedule: */30 * * * *` — every 30 minutes (see above).

## Permissions

- `actions: read` — to enumerate queued runs.
- `contents: read` — to checkout the detector.
- `issues: write` — to file and close labelled issues.
