#!/usr/bin/env bash
# tests/p11b-pending-or-callable.test.sh
#
# P11-B portable standards workflows may live in docs/pending-p11b/ while the
# nishfleet-worker PR is open, then move to .github/workflows/ when a token with
# Workflows scope lands them. This test checks either location and calls the
# repo-standards script tests. Nishfleet/fleet-ops issue #469.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

# Prefer the callable path; fall back to the pending dir.
if [ -d "$repo_root/.github/workflows" ]; then
  wf_dir="$repo_root/.github/workflows"
  fallback_dir="$repo_root/docs/pending-p11b"
  for f in reusable-gitleaks.yml reusable-semgrep.yml reusable-review-gate.yml \
           reusable-auto-enqueue.yml repo-standards-apply.yml; do
    if [ -f "$wf_dir/$f" ]; then
      echo "using callable path: .github/workflows/$f"
    elif [ -f "$fallback_dir/$f" ]; then
      echo "using pending path: docs/pending-p11b/$f"
    else
      fail "$f not found in .github/workflows/ or docs/pending-p11b/"
    fi
  done
elif [ -d "$repo_root/docs/pending-p11b" ]; then
  echo "using pending path: docs/pending-p11b/"
else
  fail "no .github/workflows/ or docs/pending-p11b/ directory found"
fi

# Resolve a file path, preferring the callable location.
resolve_wf() {
  local f="$1"
  if [ -f "$repo_root/.github/workflows/$f" ]; then
    echo "$repo_root/.github/workflows/$f"
  else
    echo "$repo_root/docs/pending-p11b/$f"
  fi
}

for wf in reusable-gitleaks.yml reusable-semgrep.yml \
          reusable-review-gate.yml reusable-auto-enqueue.yml; do
  path="$(resolve_wf "$wf")"
  [[ -f "$path" ]] || fail "$wf not found"
  grep -q 'workflow_call:' "$path" || fail "$wf must declare workflow_call"
  grep -q 'timeout-minutes:' "$path" || fail "$wf job must set timeout-minutes"
  if grep -F 'run:' "$path" | grep -F '${{ inputs'; then
    fail "$wf interpolates inputs inside a run: block"
  fi
  ok "$wf shape (workflow_call + timeout-minutes + no run-shell-injection)"
done

apply_path="$(resolve_wf repo-standards-apply.yml)"
[[ -f "$apply_path" ]] || fail "repo-standards-apply.yml not found"
grep -q 'timeout-minutes:' "$apply_path" || fail "repo-standards-apply.yml job must set timeout-minutes"
ok "repo-standards-apply.yml timeout-minutes is present"

# The README must exist while the workflows are parked.
readme="$repo_root/docs/pending-p11b/README.md"
if [ -f "$readme" ]; then
  grep -q '.github/workflows/' "$readme" || fail "README must name the target .github/workflows/ paths"
  ok "README documents the workflow-scoped landing path"
fi

# Run the repo-standards script tests.
bash "$here/repo-standards.test.sh"

echo "OK: P11-B workflows are shape-correct and repo-standards tests pass"
