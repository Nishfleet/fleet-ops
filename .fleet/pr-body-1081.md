## What

A missing `AUTO_REVERT_PAT` no longer fails the `auto-merge-arm` check. The reusable workflow emits a `::notice::` and exits 0 instead of `::error::` + `exit 1`. The PR still lands — the opener's own `gh pr merge --auto --squash` (the worker's mandatory arm step) arms merge-on-green, and a human can always click the green button. The PAT only closes the GITHUB_TOKEN-merge push-trigger gap, which the opener's own arm already covers. Failing loud here painted every PR red in PAT-less repos (e.g. inish-site#139) over a non-blocker.

- `.github/workflows/reusable-auto-merge-arm.yml`: missing-PAT branch → `::notice::` + `exit 0` (was `::error::` + `exit 1`); `gh pr merge` line unchanged.
- `.github/workflows/auto-merge-arm.yml`: caller header comment updated (stale "fails LOUD ... the correct fallback" removed).
- `tests/auto-merge-arm-missing-pat.test.sh`: new regression test (fails on pre-fix code, passes on the fix).
- `.github/workflows/ci.yml`: register the new test.

## Verification

All run on the VPS worktree (`/home/nish/workspaces/agent-worktrees/issue-fleet-ops-1081`, branch `claim/issue-1081`, base `58918b49`):

- `bash tests/auto-merge-arm-missing-pat.test.sh` → exit 0, 6 OK lines.
- Against pre-fix code (main's `reusable-auto-merge-arm.yml` + `auto-merge-arm.yml` in a temp copy): `FAIL: ... still exits 1 on the missing-PAT path` (exit 1) — the test catches the bug it locks.
- `bash tests/reusable-workflows.test.sh` → `OK: reusable workflow set is shape-locked` (exit 0).
- `bash tests/auto-revert-required-check-gate.test.sh` → `all fleet-stale-auto-revert-sweep cases passed` (exit 0).
- `bash tests/stop-the-line-detector.test.sh` → `all stop-the-line cases passed` (exit 0).
- `bash tests/orphan-workflow-detector.test.sh` → `OK: all orphan-workflow-detector tests passed` (exit 0).
- `bash tests/ci-standards-audit.test.sh` → `ALL OK: fleet-litellm-organ` (exit 0).
- YAML validity: `ci.yml`, `reusable-auto-merge-arm.yml`, `auto-merge-arm.yml` all parse (PyYAML).
- `sgscan --base origin/main` → `No new security findings.` (exit 0).

run-proof: `bash tests/auto-merge-arm-missing-pat.test.sh` exit 0 (6 OK lines); pre-fix run exit 1 (FAIL on the missing-PAT path); `sgscan --base origin/main` exit 0.

net-positive-because: the +18/-3 diff is a regression test (71 lines) plus a 3-line workflow behavior change; the test is the durable lock that keeps the missing-PAT path green-by-design, and the workflow change removes a permanent red check on every PR in PAT-less repos.

## Gates

- `prove-one-run-check` → SKIP (no new unit/timer/workflow; net-positive covered by `net-positive-because:`).
- `fleet-exec-review-canary --body` → OK (Verification + run-proof present).
- `fleet-no-agent-names-check` → OK.
- `fleet-token-efficiency-check` → OK.
- `fleet-organ-heartbeat-check` → SKIP (no organ diff).
- `research-before-build-check` → SKIP (no new `bin/` file).
- `fleet-wipe-lessons-check scan` → clean.

Closes #1081
