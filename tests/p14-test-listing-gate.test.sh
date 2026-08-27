#!/usr/bin/env bash
# tests/p14-test-listing-gate.test.sh
#
# fleet-ops#566: P14 verify-command in .github/workflows/ci.yml is an explicit
# list. Workers cannot edit .github/workflows/**, so new tests must be invoked
# from an already-listed test file. This gate proves the list is closed:
# every tests/*.test.sh is either listed in ci.yml, transitively invoked from a
# listed test, or explicitly allowed as a live/destructive test or a known
# existing orphan. New tests that are none of these fail this gate.
#
# Hosted by tests/ci-standards-audit.test.sh so it runs in CI without a
# workflow-file edit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

ci_yml="$repo_root/.github/workflows/ci.yml"
[[ -f "$ci_yml" ]] || fail "missing $ci_yml"

# Basename-only set of test files listed directly in ci.yml verify-command.
direct_listed() {
  grep -oE 'bash tests/[A-Za-z0-9._-]+\.test\.sh' "$ci_yml" \
    | awk -F/ '{print $NF}' | sort -u
}

# Print the basenames of tests/*.test.sh files a given test file invokes.
invoked_children() {
  local f="$1" line after token
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == bash* ]] || continue
    # Drop any trailing inline comment.
    after="${line%%#*}"
    after="${after#bash}"
    after="${after#"${after%%[![:space:]]*}"}"
    # Remove surrounding/dangling quotes so $here/... and tests/... parse.
    after="${after//\"/}"
    after="${after//\'/}"
    if [[ "$after" =~ ([A-Za-z0-9._-]+\.test\.sh) ]]; then
      token="${BASH_REMATCH[1]}"
      if [[ -f "$here/$token" ]]; then
        printf '%s\n' "$token"
      fi
    fi
  done <"$f"
}

# Build the transitive closure of listed and hosted tests.
declare -A reachable
pending=()
for t in $(direct_listed); do
  [[ -f "$here/$t" ]] || fail "listed test not on disk: $t"
  reachable[$t]=1
  pending+=("$t")
done

while ((${#pending[@]} > 0)); do
  current="${pending[0]}"
  pending=("${pending[@]:1}")
  for child in $(invoked_children "$here/$current"); do
    if [[ -z "${reachable[$child]:-}" ]]; then
      reachable[$child]=1
      pending+=("$child")
    fi
  done
done

# Live/destructive tests that are intentionally not run in hosted CI.
declare -A live_skip
live_skip[worker-token-live.test.sh]=1

# Existing tests that are not yet listed or hosted. These pre-date the gate.
# When a test is listed or hosted, remove it from this list.
known_orphans=(
  agent-cron-failure-reason.test.sh
  failure-mechanism-gate.test.sh
  fleet-free-roster-canary.test.sh
  fleet-heartbeat-auditor.test.sh
  fleet-heartbeat-degraded-lane-glob.test.sh
  fleet-heartbeat-failed-units-recover.test.sh
  fleet-heartbeat-orphan-distinguish.test.sh
  fleet-heartbeat-red-pr-repair.test.sh
  fleet-researcher.test.sh
  heartbeat-watchman.test.sh
  install-manifest-comment-purity.test.sh
  memory-ledger-supersede.test.sh
  org-ruleset-skip-detector.test.sh
  paid-flash-canary.test.sh
  pi-issue-run-defensive-mkdir.test.sh
  pi-issue-run-failure-reason.test.sh
  pi-issue-run-mid-session-bench.test.sh
  pi-issue-run-noop-bench.test.sh
  pi-issue-run-tried-reset.test.sh
  pi-packet-run.test.sh
  pi-scout-seat-rotation.test.sh
  pi-transport-check-dropin-428.test.sh
  verify-fleet-sync-pat.test.sh
)

declare -A known_orphan_set
for t in "${known_orphans[@]}"; do
  known_orphan_set[$t]=1
done

shopt -s nullglob
all_tests=("$here"/*.test.sh)
shopt -u nullglob

bad=()
reachable_count=0
live_count=0
known_count=0

for f in "${all_tests[@]}"; do
  t="$(basename "$f")"
  if [[ -n "${reachable[$t]:-}" ]]; then
    reachable_count=$((reachable_count + 1))
    continue
  fi
  if [[ -n "${live_skip[$t]:-}" ]]; then
    live_count=$((live_count + 1))
    continue
  fi
  if [[ -n "${known_orphan_set[$t]:-}" ]]; then
    known_count=$((known_count + 1))
    continue
  fi
  bad+=("$t")
done

if (( ${#bad[@]} > 0 )); then
  {
    echo "FAIL: ${#bad[@]} test file(s) are neither in ci.yml, hosted by a listed test, live/destructive, nor a known orphan:"
    for t in "${bad[@]}"; do
      echo "  $t"
    done
    echo "Add the test to ci.yml (requires workflow scope) or invoke it from a listed test."
  } >&2
  exit 1
fi

ok "all ${#all_tests[@]} test files accounted for (listed+hosted: $reachable_count, live skip: $live_count, known orphan: $known_count)"

# The known-orphan list must not contain tests that have become reachable.
stale=()
for t in "${known_orphans[@]}"; do
  if [[ -n "${reachable[$t]:-}" ]]; then
    stale+=("$t")
  fi
done
if (( ${#stale[@]} > 0 )); then
  {
    echo "FAIL: known_orphans contains test(s) that are now listed or hosted. Remove them:"
    for t in "${stale[@]}"; do
      echo "  $t"
    done
  } >&2
  exit 1
fi
ok "known-orphan list is accurate (no stale entries)"

# Self-check: this file is hosted by ci-standards-audit, not by ci.yml.
grep -Fq 'bash "$here/p14-test-listing-gate.test.sh"' "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must host p14-test-listing-gate.test.sh"
ok "p14-test-listing-gate.test.sh is hosted by ci-standards-audit.test.sh"

echo "OK: p14-test-listing-gate.test.sh: P14 test list is closed"
