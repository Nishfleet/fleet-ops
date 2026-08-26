#!/usr/bin/env bash
# tests/reusable-workflows.test.sh
#
# Shape-lock the central reusable CI set (fleet-ops #20):
#   1. reusable-pr-checks.yml and reusable-auto-merge-arm.yml are workflow_call.
#   2. Every job in those files has timeout-minutes.
#   3. Path filters are not on the trigger (a skipped required check freezes PRs).
#   4. fleet-ops CI calls reusable-pr-checks for the tests job.
#   5. The template callers point at Nishfleet/fleet-ops, not a copy of the steps.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

pr_checks="$repo_root/.github/workflows/reusable-pr-checks.yml"
auto_arm="$repo_root/.github/workflows/reusable-auto-merge-arm.yml"
ci="$repo_root/.github/workflows/ci.yml"
caller_arm="$repo_root/.github/workflows/auto-merge-arm.yml"
template_ci="$repo_root/template/.github/workflows/ci.yml"
template_arm="$repo_root/template/.github/workflows/auto-merge-arm.yml"

[[ -f "$pr_checks" ]] || fail "missing $pr_checks"
[[ -f "$auto_arm" ]] || fail "missing $auto_arm"
[[ -f "$template_ci" ]] || fail "missing $template_ci"
[[ -f "$template_arm" ]] || fail "missing $template_arm"

grep -q 'workflow_call:' "$pr_checks" || fail "reusable-pr-checks.yml must declare workflow_call"
grep -q 'workflow_call:' "$auto_arm" || fail "reusable-auto-merge-arm.yml must declare workflow_call"
ok "both reusable workflows declare workflow_call"

# Trigger-level path filters on a required check skip the whole workflow.
# Job-level gating lives in a run: step named "Detect code changes".
if grep -E '^[[:space:]]+paths:' "$pr_checks"; then
  fail "reusable-pr-checks.yml must not path-filter the trigger"
fi
ok "reusable-pr-checks.yml has no trigger-level paths: filter"

if grep -F 'run: ${{ inputs.install-command }}' "$pr_checks" \
  || grep -F 'run: ${{ inputs.verify-command }}' "$pr_checks"; then
  fail "install/verify commands must go through env: (semgrep run-shell-injection)"
fi
ok "install/verify commands are not interpolated in run:"

grep -q 'timeout-minutes:' "$pr_checks" || fail "reusable-pr-checks.yml job must set timeout-minutes"
grep -q 'timeout-minutes:' "$auto_arm" || fail "reusable-auto-merge-arm.yml job must set timeout-minutes"
grep -q 'cancel-in-progress: true' "$pr_checks" || fail "reusable-pr-checks.yml must cancel superseded PR runs"
ok "timeouts and PR concurrency are present"

grep -q 'uses: ./.github/workflows/reusable-pr-checks.yml' "$ci" \
  || fail "ci.yml tests job must call reusable-pr-checks.yml in this repo"
grep -q 'scan-secrets: false' "$ci" \
  || fail "fleet-ops must not double-run gitleaks while the required Gitleaks job still exists"
ok "fleet-ops CI calls reusable-pr-checks (secrets scan left on the required Gitleaks job)"

grep -q 'uses: ./.github/workflows/reusable-auto-merge-arm.yml' "$caller_arm" \
  || fail "auto-merge-arm.yml must call reusable-auto-merge-arm.yml"
grep -q 'secrets.AUTO_REVERT_PAT' "$caller_arm" \
  || fail "auto-merge-arm.yml must pass AUTO_REVERT_PAT explicitly"
if grep -q 'secrets: inherit' "$caller_arm" "$template_arm" "$template_ci" "$ci"; then
  fail "callers must not use secrets: inherit"
fi
ok "fleet-ops auto-merge-arm calls the reusable workflow"

grep -q 'uses: Nishfleet/fleet-ops/.github/workflows/reusable-pr-checks.yml@main' "$template_ci" \
  || fail "template ci.yml must call Nishfleet/fleet-ops reusable-pr-checks.yml@main"
grep -q 'uses: Nishfleet/fleet-ops/.github/workflows/reusable-auto-merge-arm.yml@main' "$template_arm" \
  || fail "template auto-merge-arm.yml must call Nishfleet/fleet-ops reusable-auto-merge-arm.yml@main"
# Callers pass inputs; they must not inline npm ci / gitleaks install.
if grep -E 'npm ci|gitleaks git|actions/setup-node' "$template_ci" | grep -v 'install-command\|verify-command\|node-version'; then
  fail "template ci.yml looks like it copied reusable steps instead of passing inputs"
fi
ok "template callers point at fleet-ops and pass inputs"

echo "OK: reusable workflow set is shape-locked"
