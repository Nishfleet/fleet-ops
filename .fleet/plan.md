# Plan — Nishfleet/fleet-ops#3659 (closes Nishfleet/fleet-ops#1417)

## Goal
Correct two unresolvable action@<sha> pins in `.github/workflows/ci-standards-audit.yml`, add `tests/workflow-action-pin-guard.test.sh` to lock SHA-format correctness, wire it into `ci.yml`, and close `Nishfleet/fleet-ops#1417` via PR.

## Verified baseline state
- `ci-standards-audit.yml:95` — checkout SHA `...10b181273ba90b1`. Only `10b` checkout in repo; every other workflow uses `10c...`. Real typo.
- `ci-standards-audit.yml:122` — `actions/upload-artifact@507de32f7b3f094b774c69e437be4eb0721c607a # v4.6.0`. Confirmed.
- `ci-failure-escalation.yml:111` — already uses `10c...` (PR #3678 fix intact).
- `tests/p14-test-listing-gate.test.sh` — exists and requires every `tests/*.test.sh` to be listed in `ci.yml`, hosted by a listed test, or in a known-orphan list. New test MUST be added to `ci.yml`'s `verify-command` in the same commit, or P14 goes red.

## Phase 1 — Worktree readiness + baseline checks
- [ ] phase 1: worktree `/home/nish/workspaces/agent-worktrees/issue-fleet-ops-3659` exists on `claim/issue-3659` from `origin/main`
- [ ] phase 1: `bin/fleet-wipe-lessons-check scan --root <worktree>` → green
- [ ] phase 1: `git show origin/main:.github/workflows/ci-failure-escalation.yml` confirms the `...10c...` checkout at line 111 (PR #3678 fix intact on origin)
- [ ] phase 1: read `.github/workflows/ci.yml` to confirm where the new test invocation slots

## Phase 2 — Fix the two SHA typos in `ci-standards-audit.yml`
- [ ] phase 2: line 95 changed from `actions/checkout@3d3c42e5aac5ba805825da76410b181273ba90b1 # v7.0.1` to `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`
- [ ] phase 2: line 122 changed from `actions/upload-artifact@507de32f7b3f094b774c69e437be4eb0721c607a # v4.6.0` to `actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2`
- [ ] phase 2: repo-wide `grep -rn '10b181273ba90b1\|507de32f7b3f094b774c69e437be4eb0721c607a' .github/workflows/` returns zero matches
- [ ] phase 2: no other edits in `ci-standards-audit.yml` — only the two lines

## Phase 3 — Add `tests/workflow-action-pin-guard.test.sh` and wire into `ci.yml`
- [ ] phase 3: `tests/workflow-action-pin-guard.test.sh` created (chmod +x), ~90 lines, hermetic (no network, no gh, no systemd)
- [ ] phase 3: registry-based guard — every `uses: <repo>@<sha>` pin must be 40-hex and match the canonical registry; one SHA per action repo across all workflows
- [ ] phase 3: test references fleet-ops#1296 in its header
- [ ] phase 3: `bash tests/workflow-action-pin-guard.test.sh` → EXIT 0 against the post-Phase-2 tree
- [ ] phase 3: `.github/workflows/ci.yml` `tests:` job `verify-command` list gains `bash tests/workflow-action-pin-guard.test.sh`, placed adjacent to `bash tests/reusable-workflows.test.sh`
- [ ] phase 3: `bash tests/p14-test-listing-gate.test.sh` → EXIT 0 (no orphan)

## Phase 4 — Receipt gates (all green before push)
- [ ] phase 4: `bash tests/workflow-action-pin-guard.test.sh` → EXIT 0
- [ ] phase 4: `bash tests/reusable-workflows.test.sh` → EXIT 0
- [ ] phase 4: `bash tests/p14-test-listing-gate.test.sh` → EXIT 0
- [ ] phase 4: `bin/sgscan` on the diff → no new findings
- [ ] phase 4: `bin/prove-one-run-check --body <pr-body>` → green
- [ ] phase 4: `bin/fleet-exec-review-canary --body <pr-body>` → green
- [ ] phase 4: `bin/fleet-rebuild-verify-check` → green
- [ ] phase 4: `bin/research-before-build-check --body <pr-body>` → green (no new `bin/` file — new artifact is `tests/`)
- [ ] phase 4: `bin/fleet-organ-heartbeat-check` → green
- [ ] phase 4: `bin/fleet-no-agent-names-check --pr-body <pr-body> --commit-range origin/main..HEAD` → green (NO Co-Authored-By, NO agent names)
- [ ] phase 4: `bin/fleet-token-efficiency-check` → green
- [ ] phase 4: Step 8 senior reviewer round skipped — fleet-ops is NOT a product repo per `config/intake-repos.json`

## Phase 2/3 reviewer output (record per manager protocol)
- **Act on**: none
- **Consider**: none
- **Noted**: diff scope exactly the 3 expected files; SHAs verified byte-for-byte; ci.yml edit placement and indent correct; test is hermetic, 6-line registry, both checks present, references fleet-ops#1296; P14 orphan gate green (405 tests accounted for); no agent attribution
- **Dismissed (with reason)**: whitespace-brittleness concern — registry lines matched verbatim after `sed 's/^uses: //' | sort -u`; inline `# vX.Y.Z` comments not captured by the SHA regex

## Phase 5 — Commit + push (nish3451 token) + PR + arm
- [ ] phase 5: commit authored/committed with Nish identity (workflow-file push requires nish3451 token)
- [ ] phase 5: single `fix(workflows):` commit covering all 3 files; NO Co-Authored-By trailer; NO agent names
- [ ] phase 5: `gh auth status` shows nish3451 (not nishfleet-worker) before push
- [ ] phase 5: push with `GH_TOKEN=$(gh auth token)` so the workflow-file push is accepted
- [ ] phase 5: PR opened with `Closes Nishfleet/fleet-ops#1417`; capture PR URL
- [ ] phase 5: `gh pr merge --auto --squash -R Nishfleet/fleet-ops <PR-number>` → arms
- [ ] phase 5: `bin/fleet-wipe-lessons-check worktree-remove <worktree>` (after merge)

## Files to Modify
- `.github/workflows/ci-standards-audit.yml` — two SHA fixes (lines 95, 122)
- `.github/workflows/ci.yml` — wire the new test into the P14 verify-command list

## New Files
- `tests/workflow-action-pin-guard.test.sh` — executable shell test; hermetic; locks SHA pins via registry

## Risks
- Workflow-file push needs nish3451 token (worker App has no Workflows scope)
- `tests/p14-test-listing-gate.test.sh` orphan risk if `ci.yml` edit skipped
- PR-body gates REJECT → fix body, re-run, do NOT push broken PR
- Wrong-account push → 403 at platform layer; treat as failed command, do not silent-retry
