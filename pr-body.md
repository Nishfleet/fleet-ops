## What changed

Filing-time same-problem dedupe for all auto-filed issues.

- **`bin/fleet-issue-file`** (new) — a drop-in for `gh issue create` that all
  auto-filers route through. It scores a candidate against open issues using
  normalized token overlap plus a key-path / unit-name match (cheap, no ML),
  then either **comments** on the existing issue (above threshold),
  **files with a `possible-duplicate-of` marker** (borderline), or **files
  clean**.
- **`lib/issue-file.py`** (new) — the scorer + `file` / `score` / `sweep`
  subcommands.
- **`reports/issue-1212-sweep-2026-08-27.json`** (new) — the backlog sweep run
  against the open queue: **11 duplicate clusters** found (Opus's 28-redo
  cluster partially surfaces, as required).
- **`tests/issue-file.test.sh`** (new) — 8 scenarios proving the mechanism
  offline (duplicate / key-path boost / unrelated-new / borderline-marker /
  above-threshold-comment / sweep clustering / fake-gh create-vs-comment /
  auto-filer wiring).
- Routed every auto-filer in `bin/` **and** the two `.github/scripts`
  detectors (`auto-revert.sh`, `ci-failure-escalation-detector.mjs`) through
  the helper instead of raw `gh issue create`. `prompts/*` filing instructions
  updated to use the helper. MANIFEST installs the new `bin/` + `lib/` pair.

Note on gate-owned paths: this diff edits `.github/scripts/auto-revert.sh` and
`.github/scripts/ci-failure-escalation-detector.mjs` (a gate-owned path). Both
edits are routing-only — they replace the raw `gh issue create` call with the
dedupe helper; no test is removed and no gate step is softened. No attestation
comment is posted by this worker.

## Verification

- `bash tests/issue-file.test.sh` → **exit 0** (all 8 scenarios OK).
- `bash tests/fleet-blind-audit.test.sh` → exit 0
- `bash tests/fleet-exec-review-canary.test.sh` → exit 0
- `bash tests/fleet-findings-queued.test.sh` → exit 0
- `bash tests/fleet-failed-command-flagged.test.sh` → exit 0
- `bash tests/scout-futility.test.sh` → exit 0
- `bash tests/canonical-checkout-guard.test.sh` → exit 0
- `bash tests/fleet-ops-deploy.test.sh` → exit 0
- `bash tests/gate-integrity.test.sh` → 80 passed, 0 failed
- `shellcheck -x bin/fleet-issue-file` (and every changed `bin/` file) → clean

run-proof: `bash tests/issue-file.test.sh` in the worktree runs the real
`bin/fleet-issue-file` + `lib/issue-file.py` end-to-end (fake-gh exercises the
actual comment-vs-create branch) and exits 0; the same test is hosted from
`tests/ci-standards-audit.test.sh` so P14 runs it. No systemd unit, timer, or
workflow is added by this PR.

Note: `tests/ci-standards-audit.test.sh` fails on **origin/main** because
`tests/fleet-worker-prompt-gh-pr-view-unknown-field.test.sh` (added in #1352)
was never registered in ci.yml, never hosted by a listed test, and never added
to `known_orphans`. This is pre-existing and unrelated to #1212 — filed as
**#1367**.

research: last30days live search ("GitHub issues automatic duplicate detection dedupe filing time") compared GitHub's native inline duplicate detection (GA ~mid-2026, UI-only — does not gate the CLI/API `gh issue create` path the fleet's auto-filers use; rejected), embeddings/AI duplicate-detection GitHub Actions (need a Workflows file the worker token cannot push; rejected), and `gh issue create` itself (adopted as the underlying create call, but it has no dedupe) — a cheap normalized-token-overlap + key-path/unit-name scorer (adopted in `lib/issue-file.py`) is the smallest change that fully solves the problem.

help-first: ran `gh issue create --help` (and `gh issue --help`) — gh has no dedupe flag and always creates a new issue, so it does not already do this; GitHub's native duplicate detection is UI-only and not exposed via `gh`, which is why a small helper was built.

Closes #1212
