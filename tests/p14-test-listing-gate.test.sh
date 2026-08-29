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
live_skip[pi-worker-execstart-live.test.sh]=1
# fleet-ops#1453: opus-heartbeat tests read VPS-local state (the launcher
# binary at /home/nish/.local/libexec/opus-heartbeat and the judge prompt
# at /home/nish/.local/share/opus-heartbeat/judge-prompt.md). They are
# live/VPS-only and cannot run in hosted CI.
live_skip[opus-heartbeat-allowlist-gate.test.sh]=1
live_skip[opus-heartbeat-follow-through.test.sh]=1
live_skip[opus-heartbeat-replayed-frozen-snapshot.test.sh]=1
# fleet-ops#1740 added gh-webhook-receiver-live-e2e.test.sh (live webhook →
# Prometheus → alert e2e) but omitted the live_skip entry, leaving main red
# on this required gate. The test skips gracefully in hosted CI (no live
# receiver/Prometheus) and only runs on the VPS, so live_skip is the correct
# classification, not a ci.yml listing (which would need workflow scope).
live_skip[gh-webhook-receiver-live-e2e.test.sh]=1

# Existing tests that are not yet listed or hosted. These pre-date the gate.
# When a test is listed or hosted, remove it from this list.
#
# fleet-ops#700: the following two tests USED to be in this list and were
# removed when worker-token-fail-closed.test.sh (already listed in ci.yml
# verify-command) began bash-invoking them:
#   - pi-issue-run-failure-reason.test.sh (hosted for fleet-ops#568)
#   - pi-issue-run-tried-reset.test.sh     (hosted for fleet-ops#567)
# They must stay out of known_orphans, or this gate's stale-entry check
# below fails. The "stale entries" check (further down in this file) is
# the class-prevention mechanism — if a future change re-adds them, the
# gate fails with their basenames in the FAIL message.
known_orphans=(
  agent-cron-failure-reason.test.sh
  failure-mechanism-gate.test.sh
  fleet-heartbeat-degraded-lane-glob.test.sh
  fleet-heartbeat-failed-units-recover.test.sh
  fleet-heartbeat-orphan-distinguish.test.sh
  fleet-heartbeat-red-pr-repair.test.sh
  fleet-researcher.test.sh
  heartbeat-watchman.test.sh
  install-manifest-comment-purity.test.sh
  memory-ledger-supersede.test.sh
  org-ruleset-skip-detector.test.sh
  pi-issue-run-defensive-mkdir.test.sh
  pi-issue-run-mid-session-bench.test.sh
  pi-packet-run.test.sh
  pi-scout-seat-rotation.test.sh
  pi-transport-check-dropin-428.test.sh
  verify-fleet-sync-pat.test.sh
)

declare -A known_orphan_set
for t in "${known_orphans[@]}"; do
  known_orphan_set[$t]=1
done

# fleet-ops#777: hard-pin the host line for dirty-worktree-audit BEFORE
# the $bad[] accounting so a future refactor that drops the host line
# in tests/rule-enforcement.test.sh is caught by name. The $bad[] check
# below also fails (test becomes unhosted), but its message is generic
# ("1 test file(s) are neither ..."). This named check runs first so
# the operator gets the issue number in the FAIL line.
#
# Provenance: fleet-ops#824 first observed dirty-worktree-audit as
# unaccounted in the P14 reachable set; the immediate host landed in
# tests/rule-enforcement.test.sh via fleet-ops#787 (PR #883) and this
# named pin layered on top via fleet-ops#777 (PR #901). #824 stayed
# open because neither fix PR included "Closes #824"; this comment
# plus the closing PR is the receipt.
#
# fleet-ops#831 was filed on 2026-08-27T04:45:45Z as a duplicate of
# #824 (same FAIL class, same test) and never independently fixed; it
# closed via this PR (no new code, the host line and named pin above
# already do the work). #824 provenance was re-anchored in PR #924.
#
# fleet-ops#799 is the ORIGINAL issue in this pile (filed
# 2026-08-27T02:21:00Z, before #824 at 02:53:41Z and #831 at
# 03:13:59Z): "tests/dirty-worktree-audit.test.sh is orphaned (not
# run in CI)", surfaced while implementing fleet-ops#660. The fix
# (host line via PR #883, named pin via PR #901) landed before #799
# was re-queued, so #799 stayed open with no remaining work — the
# test is hosted from rule-enforcement.test.sh and is not in
# known_orphans. This comment plus the closing PR is the receipt;
# no new code, same as #831.
#
# class-prevention: the named FAIL is the loudest signal; a future
# worker who sees "1 test file(s) are neither ..." and parks the
# test on known_orphans to silence the message would now also fail
# the named pin below (in the bypass-class section).
#
# The grep is anchored to a real `bash $here/...` invocation, not a
# comment: a future "comment out the host line to silence the gate"
# trick would still be caught by $bad[] but should be caught by name
# here too. Use `^[[:space:]]*bash` to skip commented lines.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/dirty-worktree-audit\.test\.sh"?' \
  "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must bash-invoke dirty-worktree-audit.test.sh (fleet-ops#777)"
ok "dirty-worktree-audit.test.sh host line in rule-enforcement.test.sh is pinned (fleet-ops#777)"

# fleet-ops#1460: hard-pin the host line for timer-manifest BEFORE
# the $bad[] accounting so a future refactor that drops the host line
# in tests/rule-enforcement.test.sh is caught by name. The test landed
# on main via PR #1490's chain without a ci.yml listing or host; this
# named pin is the class-prevention so the host cannot be deleted
# without a named FAIL.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/timer-manifest\.test\.sh"?' \
  "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must bash-invoke timer-manifest.test.sh (fleet-ops#1460)"
ok "timer-manifest.test.sh host line in rule-enforcement.test.sh is pinned (fleet-ops#1460)"

# fleet-ops#1200: hard-pin the host line for pi-packet-verdict BEFORE
# the $bad[] accounting so a future refactor that drops the host line
# in tests/seat-lib.test.sh is caught by name. The test landed on main
# via PR #1159 without a host; seat-lib.test.sh grew the invoke as a
# leftover of PR #1231. This named pin is the class-prevention so that
# leftover cannot be deleted without a named FAIL.
#
# These checks run before $bad[] because `reachable` and
# `known_orphan_set` are already populated. A sibling leftover
# (alert-repair-claim-mutex.test.sh, fleet-ops#1279) currently makes
# $bad[] non-empty, which would skip any pin placed after that exit.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/pi-packet-verdict\.test\.sh"?' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must bash-invoke pi-packet-verdict.test.sh (fleet-ops#1200)"
[[ -n "${reachable[pi-packet-verdict.test.sh]:-}" ]] \
  || fail "pi-packet-verdict.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#1200)"
[[ -z "${known_orphan_set[pi-packet-verdict.test.sh]:-}" ]] \
  || fail "pi-packet-verdict.test.sh must not be a known orphan (fleet-ops#1200)"
ok "pi-packet-verdict.test.sh is pinned in the P14 reachable set (fleet-ops#1200)"

# fleet-ops#1152: hard-pin the host line for standing-rules-drift. The test
# landed on main as `test_standing_rules_drift.sh` — a name this gate does
# not scan (`*.test.sh` only), so it ran nowhere in CI while looking like a
# gate. Renamed into the suite and hosted from rule-enforcement.test.sh;
# this named pin is the class-prevention so the host line cannot be dropped
# and the test cannot be parked on known_orphans to silence $bad[].
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/standing-rules-drift\.test\.sh"?' \
  "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must bash-invoke standing-rules-drift.test.sh (fleet-ops#1152)"
[[ -n "${reachable[standing-rules-drift.test.sh]:-}" ]] \
  || fail "standing-rules-drift.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#1152)"
[[ -z "${known_orphan_set[standing-rules-drift.test.sh]:-}" ]] \
  || fail "standing-rules-drift.test.sh must not be a known orphan (fleet-ops#1152)"
ok "standing-rules-drift.test.sh is pinned in the P14 reachable set (fleet-ops#1152)"

# fleet-ops#1211: hard-pin the host line for fleet-waste-ledger. Nested
# host from ci-standards-audit.test.sh (already in P14). Named pin so a
# future drop of the host line cannot park the test on known_orphans.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-waste-ledger\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-waste-ledger.test.sh (fleet-ops#1211)"
[[ -n "${reachable[fleet-waste-ledger.test.sh]:-}" ]] \
  || fail "fleet-waste-ledger.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#1211)"
[[ -z "${known_orphan_set[fleet-waste-ledger.test.sh]:-}" ]] \
  || fail "fleet-waste-ledger.test.sh must not be a known orphan (fleet-ops#1211)"
ok "fleet-waste-ledger.test.sh is pinned in the P14 reachable set (fleet-ops#1211)"

# fleet-ops#1367: hard-pin the host line for fleet-worker-prompt-gh-pr-view-unknown-field.
# The test was added in PR #1352 without a P14 listing and was later hosted from
# tests/seat-lib.test.sh by PR #1369. This named pin is class-prevention so a
# future dropped host or a worker parking the test on known_orphans to silence a
# generic "1 test file(s) are neither..." message fails by name.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-worker-prompt-gh-pr-view-unknown-field\.test\.sh"?' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must bash-invoke fleet-worker-prompt-gh-pr-view-unknown-field.test.sh (fleet-ops#1367)"
[[ -n "${reachable[fleet-worker-prompt-gh-pr-view-unknown-field.test.sh]:-}" ]] \
  || fail "fleet-worker-prompt-gh-pr-view-unknown-field.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#1367)"
[[ -z "${known_orphan_set[fleet-worker-prompt-gh-pr-view-unknown-field.test.sh]:-}" ]] \
  || fail "fleet-worker-prompt-gh-pr-view-unknown-field.test.sh must not be a known orphan (fleet-ops#1367)"
ok "fleet-worker-prompt-gh-pr-view-unknown-field.test.sh is pinned in the P14 reachable set (fleet-ops#1367)"

# fleet-ops#308: hard-pin the host line for fleet-spawn-guard-stash-readonly.
# The test landed on main via PR #1678 (fleet-ops#754) without a ci.yml
# listing or a host, so the P14 listing gate failed on the next push to
# main ("1 test file(s) are neither in ci.yml, hosted by a listed test,
# live/destructive, nor a known orphan: fleet-spawn-guard-stash-readonly.test.sh").
# That P14 failure is what auto-revert watches, so every merge to main was
# reverted. Host it from rule-enforcement.test.sh (same nested-CI pattern
# as dirty-worktree-audit, fleet-ops#787) and add this named pin so a
# future drop of the host line cannot park the test on known_orphans to
# silence the generic $bad[] message — it would fail by name here first.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-spawn-guard-stash-readonly\.test\.sh"?' \
  "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must bash-invoke fleet-spawn-guard-stash-readonly.test.sh (fleet-ops#308)"
[[ -n "${reachable[fleet-spawn-guard-stash-readonly.test.sh]:-}" ]] \
  || fail "fleet-spawn-guard-stash-readonly.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#308)"
[[ -z "${known_orphan_set[fleet-spawn-guard-stash-readonly.test.sh]:-}" ]] \
  || fail "fleet-spawn-guard-stash-readonly.test.sh must not be a known orphan (fleet-ops#308)"
ok "fleet-spawn-guard-stash-readonly.test.sh is pinned in the P14 reachable set (fleet-ops#308)"

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

# fleet-ops#619: the auditor panel test is the only automated check that
# the admission panel lists scout-candidates, starts the three pi-audit
# units, and tallies 2-of-3. It must stay in the P14 reachable set.
# Parking it on known_orphans after dropping the host would pass the
# accounting above and silently leave the panel untested in CI.
[[ -n "${reachable[fleet-heartbeat-auditor.test.sh]:-}" ]] \
  || fail "fleet-heartbeat-auditor.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#619)"
[[ -z "${known_orphan_set[fleet-heartbeat-auditor.test.sh]:-}" ]] \
  || fail "fleet-heartbeat-auditor.test.sh must not be a known orphan (fleet-ops#619)"
ok "fleet-heartbeat-auditor.test.sh is in the P14 reachable set (fleet-ops#619)"

# fleet-ops#777/#787: dirty-worktree-audit classifies a worktree as
# landed by `ls-remote` (HEAD on origin) — the same check
# fleet-wipe-lessons uses for its deletion guard. The early pin above
# (before the $bad[] accounting) is the named-failure line of defence
# for a dropped host. These checks below cover the bypass class: a
# future worker who sees the generic "1 test file(s) are neither..."
# message and parks the test on known_orphans to silence it would
# also fail the named pin below.
[[ -n "${reachable[dirty-worktree-audit.test.sh]:-}" ]] \
  || fail "dirty-worktree-audit.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#777)"
[[ -z "${known_orphan_set[dirty-worktree-audit.test.sh]:-}" ]] \
  || fail "dirty-worktree-audit.test.sh must not be a known orphan (fleet-ops#777)"
ok "dirty-worktree-audit.test.sh is in the P14 reachable set, not parked on known_orphans (fleet-ops#777)"

# fleet-ops#1200: bypass-class after $bad[] — parking the test on
# known_orphans to silence the generic "1 test file(s) are neither..."
# message must fail by name. The early pin above is the loud named
# failure; these checks are the second line so a future worker who
# comments out the early pin still cannot park the test.
[[ -n "${reachable[pi-packet-verdict.test.sh]:-}" ]] \
  || fail "pi-packet-verdict.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#1200)"
[[ -z "${known_orphan_set[pi-packet-verdict.test.sh]:-}" ]] \
  || fail "pi-packet-verdict.test.sh must not be a known orphan (fleet-ops#1200)"
ok "pi-packet-verdict.test.sh is in the P14 reachable set, not parked on known_orphans (fleet-ops#1200)"

# Self-check: this file is hosted by ci-standards-audit, not by ci.yml.
grep -Fq 'bash "$here/p14-test-listing-gate.test.sh"' "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must host p14-test-listing-gate.test.sh"
ok "p14-test-listing-gate.test.sh is hosted by ci-standards-audit.test.sh"

echo "OK: p14-test-listing-gate.test.sh: P14 test list is closed"
