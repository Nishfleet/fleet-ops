# Pending: P11-B portable standards reusable workflows

The nishfleet-worker App cannot push `.github/workflows/**`, so the callable
workflow files live here until a token with Workflows scope (Nish) moves them.

Move these five files to `.github/workflows/` on `Nishfleet/fleet-ops` and
delete this directory:

- `reusable-gitleaks.yml` — standalone `Gitleaks` required context
- `reusable-semgrep.yml` — standalone `semgrep` required context
- `reusable-review-gate.yml` — rationed `review:deep` label gate
- `reusable-auto-enqueue.yml` — arms the merge queue for green PRs
- `repo-standards-apply.yml` — weekly standards sweep + green-PR enqueue

The standards library and apply script (`.github/scripts/repo-standards.*` and
`enqueue-green-prs.mjs`) already point at the `.github/workflows/` paths, so
consumer-repo thin callers should only be written after these files have moved.

The shape test is `tests/p11b-pending-or-callable.test.sh` (hosted by
`tests/reusable-workflows.test.sh`). It checks whichever location the
workflows currently occupy.
