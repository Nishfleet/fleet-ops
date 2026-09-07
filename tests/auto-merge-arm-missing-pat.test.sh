#!/usr/bin/env bash
# tests/auto-merge-arm-missing-pat.test.sh
#
# fleet-ops#1081: a missing AUTO_REVERT_PAT must NOT fail the auto-merge-arm
# check. The PR still lands — the opener's own `gh pr merge --auto --squash`
# (the worker's mandatory arm step) arms merge-on-green, and a human can
# always click the green button. A red check on every PR in a repo that never
# set the secret is permanent noise over a non-blocker.
#
# This regression locks the missing-PAT branch in the reusable workflow:
#   - it emits a ::notice:: (not ::error::)
#   - it exits 0 (not 1)
#   - the caller's header comment no longer claims "fails LOUD"
#
# The stop-the-line freeze branch (frozen=true) already exits 0 by design;
# this test does not touch that path.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

arm="$repo_root/.github/workflows/reusable-auto-merge-arm.yml"
caller="$repo_root/.github/workflows/auto-merge-arm.yml"

[[ -f "$arm" ]] || fail "missing $arm"
[[ -f "$caller" ]] || fail "missing $caller"

# --- the missing-PAT branch must exit 0, not 1 ---------------------------
# Extract the "Arm auto-merge" step body and assert its shape. We grep the
# step block (from the step name to the end of file) so the assertions are
# scoped to the arm step, not the freeze step above it.
step_body=$(sed -n '/- name: Arm auto-merge/,$p' "$arm")

[[ -n "$step_body" ]] || fail "could not locate the 'Arm auto-merge' step in $arm"

# The missing-PAT branch must NOT exit 1.
if printf '%s' "$step_body" | grep -Eq '^\s*exit 1\b'; then
  fail "reusable-auto-merge-arm.yml 'Arm auto-merge' step still exits 1 on the missing-PAT path (fleet-ops#1081): a missing PAT is not a merge blocker and must not paint every PR red"
fi
ok "arm step has no 'exit 1' on the missing-PAT path"

# The missing-PAT branch must emit ::notice::, not ::error::.
if printf '%s' "$step_body" | grep -q '::error::AUTO_REVERT_PAT'; then
  fail "reusable-auto-merge-arm.yml still emits ::error:: for a missing AUTO_REVERT_PAT (fleet-ops#1081): use ::notice:: so the check stays green"
fi
printf '%s' "$step_body" | grep -q '::notice::AUTO_REVERT_PAT' \
  || fail "reusable-auto-merge-arm.yml must emit ::notice::AUTO_REVERT_PAT on the missing-PAT path (fleet-ops#1081)"
ok "arm step emits ::notice:: (not ::error::) for a missing PAT"

# The missing-PAT branch must exit 0 so the check is green.
printf '%s' "$step_body" | grep -Eq '^\s*exit 0\b' \
  || fail "reusable-auto-merge-arm.yml missing-PAT branch must exit 0 so the check stays green (fleet-ops#1081)"
ok "arm step exits 0 on the missing-PAT path"

# The actual merge command must still run when the PAT IS present — guard
# against a refactor that drops the gh pr merge line.
printf '%s' "$step_body" | grep -q 'gh pr merge' \
  || fail "reusable-auto-merge-arm.yml must still run 'gh pr merge --auto --squash' when the PAT is present"
ok "arm step still runs gh pr merge when the PAT is present"

# --- the caller's header comment must not claim "fails LOUD" -------------
# The stale "If the PAT is missing the run fails LOUD ... the correct
# fallback" line described the old (wrong) behavior and must be gone.
if grep -q 'fails LOUD' "$caller"; then
  fail "auto-merge-arm.yml caller still claims the run 'fails LOUD' on a missing PAT (fleet-ops#1081): that behavior was removed"
fi
ok "caller header comment no longer claims 'fails LOUD' on a missing PAT"

echo "OK: auto-merge-arm missing-PAT behavior is green-by-design (fleet-ops#1081)"
