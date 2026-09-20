#!/usr/bin/env bash
# tests/dependency-review-workflow.test.sh — fleet-ops#6829
#
# Pins .github/workflows/dependency-review.yml, the Dependency Review gate
# adopted from GitHub's documented supply-chain practice: every pull request
# is diffed against known vulnerabilities and fails at severity high for
# runtime-scoped dependencies. The registration mechanism is this pin test
# (the same pattern tests/secret-scan-workflow.test.sh uses for the gitleaks
# gate): the workflow cannot silently disappear or be gutted without a red
# test.
#
# Drills:
#   1. The workflow exists and fires on pull_request + merge_group — the
#      queue is the only merge path on fleet-ops main, so a gate that does
#      not listen to merge_group cannot bind the merge.
#   2. actions/dependency-review-action is SHA-pinned (v4.9.0), never a
#      floating tag — the pin-and-bump pairing is dependabot's bump half.
#   3. Gate config: fail-on-severity: high + fail-on-scopes: runtime, and
#      the merge_group base/head SHAs are wired into base-ref/head-ref.
#   4. Gate shape: no job-level `if:`/`needs:` (a skipped required context
#      still satisfies branch protection), empty top-level permissions, and
#      the job grants contents: read only.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
wf="$repo_root/.github/workflows/dependency-review.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$wf" ]] || fail "missing $wf"
ok "dependency-review.yml exists"

# --- Drill 1: triggers ------------------------------------------------------
for needle in \
  'name: Dependency Review' \
  'pull_request:' \
  'merge_group:'; do
  grep -qF -- "$needle" "$wf" || fail "workflow missing trigger/name line: $needle"
done
ok "triggers on pull_request + merge_group"

# --- Drill 2: SHA-pinned action, never a floating tag ------------------------
grep -qF 'actions/dependency-review-action@2031cfc080254a8a887f58cffee85186f0e49e48 # v4.9.0' "$wf" \
  || fail "dependency-review-action is not pinned to the v4.9.0 commit SHA"
grep -qE 'dependency-review-action@v[0-9]' "$wf" \
  && fail "floating tag reference to dependency-review-action — pin the commit SHA"
ok "action pinned by commit SHA (v4.9.0), no floating tag"

# --- Drill 3: gate config + merge_group wiring -------------------------------
for needle in \
  'fail-on-severity: high' \
  'fail-on-scopes: runtime' \
  'base-ref: ${{ github.event.merge_group.base_sha || '"''"' }}' \
  'head-ref: ${{ github.event.merge_group.head_sha || '"''"' }}'; do
  grep -qF -- "$needle" "$wf" || fail "workflow missing gate-config line: $needle"
done
ok "fail-on-severity=high, fail-on-scopes=runtime, merge_group base/head wired"

# --- Drill 4: gate shape ------------------------------------------------------
awk '/^  dependency-review:/{f=1} f' "$wf" | grep -qE '^    (if|needs):' \
  && fail "dependency-review job has a job-level if:/needs: — a skipped required context still satisfies branch protection"
grep -qF 'permissions: {}' "$wf" \
  || fail "top-level permissions must be {} (least privilege)"
awk '/^  dependency-review:/{f=1} f' "$wf" | grep -qF 'contents: read' \
  || fail "dependency-review job missing contents: read"
ok "no job-level if/needs; permissions {} top-level; job grants contents: read only"

echo "PASS: dependency-review-workflow"
