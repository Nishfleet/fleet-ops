#!/usr/bin/env bash
# tests/p14-test-listing-gate.test.sh
#
# fleet-ops#566: P14 verify-command in .github/workflows/ci.yml is an explicit
# list. Workers cannot edit .github/workflows/**, so new tests must be invoked
# from an already-listed test file.
#
# fleet-ops#5889 (2026-09-12): that requirement structurally red'd every
# worker PR that adds a tests/*.test.sh file — the nishfleet-worker App has
# no Workflows scope, so it can never add the ci.yml listing itself
# (measured 2026-09-12 08:45Z: 10 of 21 open fleet-ops PRs red on exactly
# "... are neither in ci.yml, hosted by a listed test, live/destructive, nor
# a known orphan"). Predecessor tickets #3483, #3482, #1687 were per-file
# and never admitted; #4939 was the symptom ticket (closed superseded).
#
# Fix class 1 of #5889 (self-hosting gate), minus the ci.yml edit workers
# cannot push: this gate is itself hosted by tests/ci-standards-audit.test.sh
# (already listed in ci.yml), so the gate now RUNS every otherwise-unaccounted
# tests/*.test.sh instead of failing on it. A new test file is therefore
# executed in P14 without any ci.yml edit: it is reachable by construction
# through this auto-host. The live/destructive denylist (live_skip) and
# known_orphans stay explicit exceptions; live/destructive or VPS-only tests
# are exempted by editing live_skip below — and this file is a tests/*.sh,
# which the worker App CAN push.
#
# The named pins below are unchanged: a user-listed test that is dropped
# from its host still fails by name before the auto-host accounting.
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
# fleet-ops#4141: the 12 opus-heartbeat-* tests were deleted (the opus-
# heartbeat family was retired — recording rules + fable-check.md replaced
# it). No live_skip entries needed for deleted tests.
# fleet-ops#1498: memory-index-autocompact-migrated runs `systemd-analyze verify`
# on a unit whose ExecStart points to /home/nish/.local/bin/memory-index-autocompact
# (VPS-only), absent on hosted runners. Live/VPS-only — cannot run in hosted CI.
live_skip[memory-index-autocompact-migrated.test.sh]=1
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
  install-manifest-comment-purity.test.sh
  memory-ledger-supersede.test.sh
  org-ruleset-skip-detector.test.sh
  pi-issue-run-defensive-mkdir.test.sh
  pi-issue-run-mid-session-bench.test.sh
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

# fleet-ops#1309: hard-pin the host line for alert-repair-claim-mutex
# BEFORE the $bad[] accounting so a future refactor that drops the host
# line in tests/seat-lib.test.sh is caught by name. The test landed on
# main via fleet-ops#1199 (PR #1280) without a ci.yml listing or host;
# seat-lib.test.sh grew the invoke as a side effect of PR #1288
# (fleet-ops#1288, which pinned its sibling pi-packet-verdict). This
# named pin is the class-prevention so the host line cannot be dropped
# and the test cannot be parked on known_orphans to silence $bad[].
# fleet-ops#1279 stays open as the ci.yml-line follow-up (needs
# workflow scope).
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/alert-repair-claim-mutex\.test\.sh"?' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must bash-invoke alert-repair-claim-mutex.test.sh (fleet-ops#1309)"
[[ -n "${reachable[alert-repair-claim-mutex.test.sh]:-}" ]] \
  || fail "alert-repair-claim-mutex.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#1309)"
[[ -z "${known_orphan_set[alert-repair-claim-mutex.test.sh]:-}" ]] \
  || fail "alert-repair-claim-mutex.test.sh must not be a known orphan (fleet-ops#1309)"
ok "alert-repair-claim-mutex.test.sh is pinned in the P14 reachable set (fleet-ops#1309)"

# fleet-ops#1331 is a duplicate of #1309, filed 3 minutes later
# (2026-08-27T18:36:29Z vs #1309 at 18:33:00Z) while #1309 was still
# open. The same fix — host line in tests/seat-lib.test.sh (PR #1288
# leftover) plus this named pin (PR #1833, merged 2026-08-29T03:12:24Z)
# — closes both. No new code; this comment plus the closing PR is the
# receipt, same shape as the #831/#799 duplicate receipts above.
# Verified: `bash tests/ci-standards-audit.test.sh` no longer reports
# alert-repair-claim-mutex.test.sh as an unhosted orphan on origin/main.

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

# fleet-ops#5586: hard-pin the host line for reserved-classes-precedence.
# Nested host from rule-enforcement.test.sh (already in ci.yml). Named pin
# so a future drop of the host line cannot park the #5586 detector on
# known_orphans to silence the containment gate.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/reserved-classes-precedence\.test\.sh"?' \
  "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must bash-invoke reserved-classes-precedence.test.sh (fleet-ops#5586)"
[[ -n "${reachable[reserved-classes-precedence.test.sh]:-}" ]] \
  || fail "reserved-classes-precedence.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#5586)"
[[ -z "${known_orphan_set[reserved-classes-precedence.test.sh]:-}" ]] \
  || fail "reserved-classes-precedence.test.sh must not be a known orphan (fleet-ops#5586)"
ok "reserved-classes-precedence.test.sh is pinned in the P14 reachable set (fleet-ops#5586)"

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
# fleet-ops#3244 (PR #3334): rule-enforcement now hosts the spawn-guard
# nested suite (spawn-guard.test.sh) which itself hosts stash-readonly and
# the sudo-write drill; the pin follows the new two-level host chain.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/spawn-guard\.test\.sh"?' \
  "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must bash-invoke spawn-guard.test.sh (fleet-ops#308)"
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-spawn-guard-stash-readonly\.test\.sh"?' \
  "$here/spawn-guard.test.sh" \
  || fail "spawn-guard.test.sh must bash-invoke fleet-spawn-guard-stash-readonly.test.sh (fleet-ops#308)"
[[ -n "${reachable[fleet-spawn-guard-stash-readonly.test.sh]:-}" ]] \
  || fail "fleet-spawn-guard-stash-readonly.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#308)"
[[ -z "${known_orphan_set[fleet-spawn-guard-stash-readonly.test.sh]:-}" ]] \
  || fail "fleet-spawn-guard-stash-readonly.test.sh must not be a known orphan (fleet-ops#308)"
ok "fleet-spawn-guard-stash-readonly.test.sh is pinned in the P14 reachable set (fleet-ops#308)"

# fleet-ops#2071: hard-pin the host lines for the two intake-tick tests that
# PR #2068 hosted from tests/pi-intake-run.test.sh (already listed in ci.yml)
# without adding named pins. The blind-audit report at 2026-08-29T15:26:31Z
# caught the transient red (the host landed 2 minutes later at 15:28:30Z), but
# the class-prevention was missing: a future drop of either host line could
# park the test on known_orphans to silence the generic $bad[] message. These
# named pins fail by name first, same shape as every other hosted test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/pi-intake-tick-escalate-senior-exclusion\.test\.sh"?' \
  "$here/pi-intake-run.test.sh" \
  || fail "pi-intake-run.test.sh must bash-invoke pi-intake-tick-escalate-senior-exclusion.test.sh (fleet-ops#2071)"
[[ -n "${reachable[pi-intake-tick-escalate-senior-exclusion.test.sh]:-}" ]] \
  || fail "pi-intake-tick-escalate-senior-exclusion.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#2071)"
[[ -z "${known_orphan_set[pi-intake-tick-escalate-senior-exclusion.test.sh]:-}" ]] \
  || fail "pi-intake-tick-escalate-senior-exclusion.test.sh must not be a known orphan (fleet-ops#2071)"
ok "pi-intake-tick-escalate-senior-exclusion.test.sh is pinned in the P14 reachable set (fleet-ops#2071)"

grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/pi-intake-tick-claim-set-e-guard\.test\.sh"?' \
  "$here/pi-intake-run.test.sh" \
  || fail "pi-intake-run.test.sh must bash-invoke pi-intake-tick-claim-set-e-guard.test.sh (fleet-ops#2071)"
[[ -n "${reachable[pi-intake-tick-claim-set-e-guard.test.sh]:-}" ]] \
  || fail "pi-intake-tick-claim-set-e-guard.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#2071)"
[[ -z "${known_orphan_set[pi-intake-tick-claim-set-e-guard.test.sh]:-}" ]] \
  || fail "pi-intake-tick-claim-set-e-guard.test.sh must not be a known orphan (fleet-ops#2071)"
ok "pi-intake-tick-claim-set-e-guard.test.sh is pinned in the P14 reachable set (fleet-ops#2071)"

# fleet-ops#1165: hard-pin the host line for the protected-verifier
# vacation park test. Hosted from tests/pi-intake-run.test.sh (already in
# P14). Named pin so a future drop of the host line cannot park the test
# on known_orphans to silence the generic $bad[] message — it fails by
# name here first, same shape as every other hosted test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/pi-intake-tick-protected-verifier-vacation\.test\.sh"?' \
  "$here/pi-intake-run.test.sh" \
  || fail "pi-intake-run.test.sh must bash-invoke pi-intake-tick-protected-verifier-vacation.test.sh (fleet-ops#1165)"
[[ -n "${reachable[pi-intake-tick-protected-verifier-vacation.test.sh]:-}" ]] \
  || fail "pi-intake-tick-protected-verifier-vacation.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#1165)"
[[ -z "${known_orphan_set[pi-intake-tick-protected-verifier-vacation.test.sh]:-}" ]] \
  || fail "pi-intake-tick-protected-verifier-vacation.test.sh must not be a known orphan (fleet-ops#1165)"
ok "pi-intake-tick-protected-verifier-vacation.test.sh is pinned in the P14 reachable set (fleet-ops#1165)"

# fleet-ops#2462: hard-pin the host line for fleet-ops-2462-claim-cap. The
# test landed on main in PR #2482 (the #2462 fix PR) without a ci.yml listing
# and was hosted from tests/ci-standards-audit.test.sh (already in P14) —
# the worker App cannot push .github/workflows/** so the host was the only
# path. P14 ran red on "1 test file(s) are neither in ci.yml, hosted by a
# listed test, live/destructive, nor a known orphan:
# fleet-ops-2462-claim-cap.test.sh". This named pin is class-prevention so
# a future drop of the host line cannot park the test on known_orphans to
# silence the generic $bad[] message — it fails by name here first, same
# shape as every other hosted test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-ops-2462-claim-cap\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-ops-2462-claim-cap.test.sh (fleet-ops#2462)"
[[ -n "${reachable[fleet-ops-2462-claim-cap.test.sh]:-}" ]] \
  || fail "fleet-ops-2462-claim-cap.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#2462)"
[[ -z "${known_orphan_set[fleet-ops-2462-claim-cap.test.sh]:-}" ]] \
  || fail "fleet-ops-2462-claim-cap.test.sh must not be a known orphan (fleet-ops#2462)"
ok "fleet-ops-2462-claim-cap.test.sh is pinned in the P14 reachable set (fleet-ops#2462)"

# fleet-ops#3310: hard-pin the host line for fleet-ops-3310-infra-death-class-switch.
# Same class-prevention shape as the #2462 pin: the test is hosted from
# tests/ci-standards-audit.test.sh (already in P14) because the worker App
# cannot push .github/workflows/**; a future drop of the host line must fail
# by name here instead of parking the test on known_orphans.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-ops-3310-infra-death-class-switch\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-ops-3310-infra-death-class-switch.test.sh (fleet-ops#3310)"
[[ -n "${reachable[fleet-ops-3310-infra-death-class-switch.test.sh]:-}" ]] \
  || fail "fleet-ops-3310-infra-death-class-switch.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#3310)"
[[ -z "${known_orphan_set[fleet-ops-3310-infra-death-class-switch.test.sh]:-}" ]] \
  || fail "fleet-ops-3310-infra-death-class-switch.test.sh must not be a known orphan (fleet-ops#3310)"
ok "fleet-ops-3310-infra-death-class-switch.test.sh is pinned in the P14 reachable set (fleet-ops#3310)"

# fleet-ops#3268 (child of waste-cut #3128): hard-pin the host line for
# fleet-close-and-archive-repo. The test landed on main in PR #3740 without
# a ci.yml listing and was hosted from tests/ci-standards-audit.test.sh
# (already in P14) — the worker App cannot push .github/workflows/** so the
# host was the only path. P14 ran red on "1 test file(s) are neither in
# ci.yml, hosted by a listed test, live/destructive, nor a known orphan:
# fleet-close-and-archive-repo.test.sh". This named pin is class-prevention
# so a future drop of the host line cannot park the test on known_orphans to
# silence the generic $bad[] message — it fails by name here first, same
# shape as every other hosted test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-close-and-archive-repo\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-close-and-archive-repo.test.sh (fleet-ops#3268)"
[[ -n "${reachable[fleet-close-and-archive-repo.test.sh]:-}" ]] \
  || fail "fleet-close-and-archive-repo.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#3268)"
[[ -z "${known_orphan_set[fleet-close-and-archive-repo.test.sh]:-}" ]] \
  || fail "fleet-close-and-archive-repo.test.sh must not be a known orphan (fleet-ops#3268)"
ok "fleet-close-and-archive-repo.test.sh is pinned in the P14 reachable set (fleet-ops#3268)"

# fleet-ops#2475 (PR #2193 follow-up): hard-pin the host line for
# unit-escalation-write-pi-issue-exclusion. The test landed on main in this
# PR without a ci.yml listing and was hosted from tests/ci-standards-audit.test.sh
# (already in P14) — the worker App cannot push .github/workflows/** so the
# host was the only path. P14 would run red on "1 test file(s) are neither in
# ci.yml, hosted by a listed test, live/destructive, nor a known orphan:
# unit-escalation-write-pi-issue-exclusion.test.sh". This named pin is
# class-prevention so a future drop of the host line cannot park the test
# on known_orphans to silence the generic $bad[] message — it fails by name
# here first, same shape as every other hosted test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/unit-escalation-write-pi-issue-exclusion\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke unit-escalation-write-pi-issue-exclusion.test.sh (fleet-ops#2475)"
[[ -n "${reachable[unit-escalation-write-pi-issue-exclusion.test.sh]:-}" ]] \
  || fail "unit-escalation-write-pi-issue-exclusion.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#2475)"
[[ -z "${known_orphan_set[unit-escalation-write-pi-issue-exclusion.test.sh]:-}" ]] \
  || fail "unit-escalation-write-pi-issue-exclusion.test.sh must not be a known orphan (fleet-ops#2475)"
ok "unit-escalation-write-pi-issue-exclusion.test.sh is pinned in the P14 reachable set (fleet-ops#2475)"

# fleet-ops#3368: hard-pin the host line for
# fleet-rules-escalation-storm. The test landed in this PR without a ci.yml
# listing and was hosted from tests/ci-standards-audit.test.sh (already in
# P14) — the worker App cannot push .github/workflows/** so the host was the
# only path. This named pin is class-prevention so a future drop of the host
# line cannot park the test on known_orphans to silence the generic $bad[]
# message — it fails by name here first, same shape as every other hosted
# test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-rules-escalation-storm\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-rules-escalation-storm.test.sh (fleet-ops#3368)"
[[ -n "${reachable[fleet-rules-escalation-storm.test.sh]:-}" ]] \
  || fail "fleet-rules-escalation-storm.test.sh must be hosted by a listed test (fleet-ops#3368)"
[[ -z "${known_orphan_set[fleet-rules-escalation-storm.test.sh]:-}" ]] \
  || fail "fleet-rules-escalation-storm.test.sh must not be a known orphan (fleet-ops#3368)"
ok "fleet-rules-escalation-storm.test.sh is pinned in the P14 reachable set (fleet-ops#3368)"

# fleet-ops#2694 (PR #2796 follow-up): hard-pin the host line for
# alert-repair-outcome-metric. The test landed on main in PR #2796 (the
# #2694 fix PR) without a ci.yml listing or a host, leaving this gate red
# ("1 test file(s) are neither in ci.yml, hosted by a listed test,
# live/destructive, nor a known orphan: alert-repair-outcome-metric.test.sh")
# for every push to main from 08:05Z on. It was hosted from
# tests/ci-standards-audit.test.sh (already listed in ci.yml) — the worker
# App cannot push .github/workflows/** so the host was the only path. This
# named pin is class-prevention so a future drop of the host line cannot
# park the test on known_orphans to silence the generic $bad[] message — it
# fails by name here first, same shape as every other hosted test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/alert-repair-outcome-metric\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke alert-repair-outcome-metric.test.sh (fleet-ops#2694)"
[[ -n "${reachable[alert-repair-outcome-metric.test.sh]:-}" ]] \
  || fail "alert-repair-outcome-metric.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#2694)"
[[ -z "${known_orphan_set[alert-repair-outcome-metric.test.sh]:-}" ]] \
  || fail "alert-repair-outcome-metric.test.sh must not be a known orphan (fleet-ops#2694)"
ok "alert-repair-outcome-metric.test.sh is pinned in the P14 reachable set (fleet-ops#2694)"

# fleet-ops#2768 (PR #2873 follow-up): hard-pin the host line for
# dispatch-ledger-fixture-sweep. The test landed in PR #2873 without a
# ci.yml listing or a host, leaving this gate red ("1 test file(s) are
# neither in ci.yml, hosted by a listed test, live/destructive, nor a
# known orphan: dispatch-ledger-fixture-sweep.test.sh", run 33662643290).
# Hosted from tests/ci-standards-audit.test.sh (already listed in ci.yml)
# — the worker App cannot push .github/workflows/** so the host is the
# only path. This named pin is class-prevention so a future drop of the
# host line cannot park the test on known_orphans to silence the generic
# $bad[] message — it fails by name here first, same shape as every other
# hosted test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/dispatch-ledger-fixture-sweep\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke dispatch-ledger-fixture-sweep.test.sh (fleet-ops#2768)"
[[ -n "${reachable[dispatch-ledger-fixture-sweep.test.sh]:-}" ]] \
  || fail "dispatch-ledger-fixture-sweep.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#2768)"
[[ -z "${known_orphan_set[dispatch-ledger-fixture-sweep.test.sh]:-}" ]] \
  || fail "dispatch-ledger-fixture-sweep.test.sh must not be a known orphan (fleet-ops#2768)"
ok "dispatch-ledger-fixture-sweep.test.sh is pinned in the P14 reachable set (fleet-ops#2768)"

# fleet-ops#2902 (PR #2885 follow-up): hard-pin the host line for
# fleet-deploy-quality. The test landed on main in PR #2885 (the #2758
# deploy-quality SLO fix) without a ci.yml listing or a host, leaving this
# gate red ("2 test file(s) are neither in ci.yml, hosted by a listed test,
# live/destructive, nor a known orphan: fleet-deploy-quality.test.sh
# fleet-issue-file-close-duplicates.test.sh"). Hosted from
# tests/ci-standards-audit.test.sh (already listed in ci.yml) — the worker
# App cannot push .github/workflows/** so the host is the only path. This
# named pin is class-prevention so a future drop of the host line cannot
# park the test on known_orphans to silence the generic $bad[] message —
# it fails by name here first, same shape as every other hosted test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-deploy-quality\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-deploy-quality.test.sh (fleet-ops#2902)"
[[ -n "${reachable[fleet-deploy-quality.test.sh]:-}" ]] \
  || fail "fleet-deploy-quality.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#2902)"
[[ -z "${known_orphan_set[fleet-deploy-quality.test.sh]:-}" ]] \
  || fail "fleet-deploy-quality.test.sh must not be a known orphan (fleet-ops#2902)"
ok "fleet-deploy-quality.test.sh is pinned in the P14 reachable set (fleet-ops#2902)"

# fleet-ops#5140: hard-pin the host line for fleet-product-deploy-0509.
# The test is hosted from tests/ci-standards-audit.test.sh (already listed
# in ci.yml) — the worker App cannot push .github/workflows/** so the host
# is the only path. This named pin is class-prevention so a future drop of
# the host line cannot park the test on known_orphans to silence the
# generic $bad[] message — it fails by name here first, same shape as
# every other hosted test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-product-deploy-0509\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-product-deploy-0509.test.sh (fleet-ops#5140)"
[[ -n "${reachable[fleet-product-deploy-0509.test.sh]:-}" ]] \
  || fail "fleet-product-deploy-0509.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#5140)"
[[ -z "${known_orphan_set[fleet-product-deploy-0509.test.sh]:-}" ]] \
  || fail "fleet-product-deploy-0509.test.sh must not be a known orphan (fleet-ops#5140)"
ok "fleet-product-deploy-0509.test.sh is pinned in the P14 reachable set (fleet-ops#5140)"

# fleet-ops#2902 (PR #2900 follow-up): hard-pin the host line for
# fleet-issue-file-close-duplicates. The test landed on main in PR #2900
# (the #2762 close-duplicates drain fix) without a ci.yml listing or a
# host, leaving this gate red (same 2-orphan FAIL as fleet-deploy-quality
# above). Hosted from tests/ci-standards-audit.test.sh (already listed in
# ci.yml) — the worker App cannot push .github/workflows/** so the host is
# the only path. This named pin is class-prevention so a future drop of
# the host line cannot park the test on known_orphans to silence the
# generic $bad[] message — it fails by name here first, same shape as every
# other hosted test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-issue-file-close-duplicates\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-issue-file-close-duplicates.test.sh (fleet-ops#2902)"
[[ -n "${reachable[fleet-issue-file-close-duplicates.test.sh]:-}" ]] \
  || fail "fleet-issue-file-close-duplicates.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#2902)"
[[ -z "${known_orphan_set[fleet-issue-file-close-duplicates.test.sh]:-}" ]] \
  || fail "fleet-issue-file-close-duplicates.test.sh must not be a known orphan (fleet-ops#2902)"
ok "fleet-issue-file-close-duplicates.test.sh is pinned in the P14 reachable set (fleet-ops#2902)"

# fleet-ops#3161: hard-pin the host line for the close-duplicates regression
# test. Same shape as the #2902 pin above — the test is hosted from
# ci-standards-audit.test.sh (already listed in ci.yml) because the worker
# App cannot push .github/workflows/**. This named pin is class-prevention
# so a future drop of the host line cannot park the test on known_orphans.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-issue-file-close-duplicates-regression-3161\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-issue-file-close-duplicates-regression-3161.test.sh (fleet-ops#3161)"
[[ -n "${reachable[fleet-issue-file-close-duplicates-regression-3161.test.sh]:-}" ]] \
  || fail "fleet-issue-file-close-duplicates-regression-3161.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#3161)"
[[ -z "${known_orphan_set[fleet-issue-file-close-duplicates-regression-3161.test.sh]:-}" ]] \
  || fail "fleet-issue-file-close-duplicates-regression-3161.test.sh must not be a known orphan (fleet-ops#3161)"
ok "fleet-issue-file-close-duplicates-regression-3161.test.sh is pinned in the P14 reachable set (fleet-ops#3161)"

# fleet-ops#3728: hard-pin the host line for the close-duplicates idempotency
# test (already-marked skip). Same shape as the #3161 pin above — the test
# is hosted from ci-standards-audit.test.sh (already listed in ci.yml)
# because the worker App cannot push .github/workflows/**. This named pin
# is class-prevention so a future drop of the host line cannot park the
# test on known_orphans to silence the generic $bad[] message.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-issue-file-close-duplicates-idempotent\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-issue-file-close-duplicates-idempotent.test.sh (fleet-ops#3728)"
[[ -n "${reachable[fleet-issue-file-close-duplicates-idempotent.test.sh]:-}" ]] \
  || fail "fleet-issue-file-close-duplicates-idempotent.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#3728)"
[[ -z "${known_orphan_set[fleet-issue-file-close-duplicates-idempotent.test.sh]:-}" ]] \
  || fail "fleet-issue-file-close-duplicates-idempotent.test.sh must not be a known orphan (fleet-ops#3728)"
ok "fleet-issue-file-close-duplicates-idempotent.test.sh is pinned in the P14 reachable set (fleet-ops#3728)"

# fleet-ops#5622: hard-pin the host line for the stuck-packet test.
# Same shape as the #5620 pin — the test is hosted from
# ci-standards-audit.test.sh (already listed in ci.yml) because the worker
# App cannot push .github/workflows/**. Parking it on known_orphans to
# silence the generic message must also fail by name below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/alert-repair-stuck-packet\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke alert-repair-stuck-packet.test.sh (fleet-ops#5622)"
[[ -n "${reachable[alert-repair-stuck-packet.test.sh]:-}" ]] \
  || fail "alert-repair-stuck-packet.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#5622)"
[[ -z "${known_orphan_set[alert-repair-stuck-packet.test.sh]:-}" ]] \
  || fail "alert-repair-stuck-packet.test.sh must not be a known orphan (fleet-ops#5622)"
ok "alert-repair-stuck-packet.test.sh is pinned in the P14 reachable set (fleet-ops#5622)"

# fleet-ops#5620: hard-pin the host line for the repo-scope dedupe test.
# Same shape as the #3728 pin above — the test is hosted from
# ci-standards-audit.test.sh (already listed in ci.yml) because the worker
# App cannot push .github/workflows/**. This named pin is class-prevention
# so a future drop of the host line cannot park the test on known_orphans.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-issue-file-dedupe-repo-scope\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-issue-file-dedupe-repo-scope.test.sh (fleet-ops#5620)"
[[ -n "${reachable[fleet-issue-file-dedupe-repo-scope.test.sh]:-}" ]] \
  || fail "fleet-issue-file-dedupe-repo-scope.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#5620)"
[[ -z "${known_orphan_set[fleet-issue-file-dedupe-repo-scope.test.sh]:-}" ]] \
  || fail "fleet-issue-file-dedupe-repo-scope.test.sh must not be a known orphan (fleet-ops#5620)"
ok "fleet-issue-file-dedupe-repo-scope.test.sh is pinned in the P14 reachable set (fleet-ops#5620)"

# fleet-ops#5496: hard-pin the host line for the dedupe-comment idempotence
# test (the live #5464 spam: 848+ identical comments). Same shape as the
# #5620 pin above — the test is hosted from ci-standards-audit.test.sh
# (already listed in ci.yml) because the worker App cannot push
# .github/workflows/**. This named pin is class-prevention so a future
# drop of the host line cannot park the test on known_orphans.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-issue-file-dedupe-comment-idempotent\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-issue-file-dedupe-comment-idempotent.test.sh (fleet-ops#5496)"
[[ -n "${reachable[fleet-issue-file-dedupe-comment-idempotent.test.sh]:-}" ]] \
  || fail "fleet-issue-file-dedupe-comment-idempotent.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#5496)"
[[ -z "${known_orphan_set[fleet-issue-file-dedupe-comment-idempotent.test.sh]:-}" ]] \
  || fail "fleet-issue-file-dedupe-comment-idempotent.test.sh must not be a known orphan (fleet-ops#5496)"
ok "fleet-issue-file-dedupe-comment-idempotent.test.sh is pinned in the P14 reachable set (fleet-ops#5496)"

# fleet-ops#5666: hard-pin the host line for the closed-canonical dedupe
# test (the #5652 -> #5666 stale-observation re-filing). Same shape as the
# #5496 pin above — the test is hosted from ci-standards-audit.test.sh
# (already listed in ci.yml) because the worker App cannot push
# .github/workflows/**. This named pin is class-prevention so a future
# drop of the host line cannot park the test on known_orphans.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-issue-file-dedupe-closed-canonical\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-issue-file-dedupe-closed-canonical.test.sh (fleet-ops#5666)"
[[ -n "${reachable[fleet-issue-file-dedupe-closed-canonical.test.sh]:-}" ]] \
  || fail "fleet-issue-file-dedupe-closed-canonical.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#5666)"
[[ -z "${known_orphan_set[fleet-issue-file-dedupe-closed-canonical.test.sh]:-}" ]] \
  || fail "fleet-issue-file-dedupe-closed-canonical.test.sh must not be a known orphan (fleet-ops#5666)"
ok "fleet-issue-file-dedupe-closed-canonical.test.sh is pinned in the P14 reachable set (fleet-ops#5666)"

# fleet-ops#2902 (PR #2905 follow-up): hard-pin the host line for
# worktree-leaky-test-containment. The test landed on main in PR #2905
# (the #2769 containment detector fix) without a ci.yml listing or a host.
# The p14 gate was ALREADY red on the two orphans above, so #2905's
# leftover slipped in unmasked — exactly the impact this issue describes
# ("the gate that is supposed to prevent unhosted tests is itself red on
# main, masking new violations"). Hosted from
# tests/ci-standards-audit.test.sh (already listed in ci.yml) — the worker
# App cannot push .github/workflows/** so the host is the only path. This
# named pin is class-prevention so a future drop of the host line cannot
# park the test on known_orphans to silence the generic $bad[] message —
# it fails by name here first, same shape as every other hosted test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/worktree-leaky-test-containment\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke worktree-leaky-test-containment.test.sh (fleet-ops#2902)"
[[ -n "${reachable[worktree-leaky-test-containment.test.sh]:-}" ]] \
  || fail "worktree-leaky-test-containment.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#2902)"
[[ -z "${known_orphan_set[worktree-leaky-test-containment.test.sh]:-}" ]] \
  || fail "worktree-leaky-test-containment.test.sh must not be a known orphan (fleet-ops#2902)"
ok "worktree-leaky-test-containment.test.sh is pinned in the P14 reachable set (fleet-ops#2902)"

# fleet-ops#2772 (PR #2857 follow-up): hard-pin the host line for
# fleet-ops-2772-claim-loop-gate. The test landed on main in PR #2857 (the
# #2772 fix PR) without a ci.yml listing or a host, leaving this gate red
# ("1 test file(s) are neither in ci.yml, hosted by a listed test,
# live/destructive, nor a known orphan: fleet-ops-2772-claim-loop-gate.test.sh")
# on main from 17:09Z on. It is hosted from
# tests/pi-intake-tick-reclaim-cooldown.test.sh (already listed in ci.yml) —
# the worker App cannot push .github/workflows/** so the host was the only
# path. This named pin is class-prevention so a future drop of the host
# line cannot park the test on known_orphans to silence the generic $bad[]
# message — it fails by name here first, same shape as every other hosted
# test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-ops-2772-claim-loop-gate\.test\.sh"?' \
  "$here/pi-intake-tick-reclaim-cooldown.test.sh" \
  || fail "pi-intake-tick-reclaim-cooldown.test.sh must bash-invoke fleet-ops-2772-claim-loop-gate.test.sh (fleet-ops#2772)"
[[ -n "${reachable[fleet-ops-2772-claim-loop-gate.test.sh]:-}" ]] \
  || fail "fleet-ops-2772-claim-loop-gate.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#2772)"
[[ -z "${known_orphan_set[fleet-ops-2772-claim-loop-gate.test.sh]:-}" ]] \
  || fail "fleet-ops-2772-claim-loop-gate.test.sh must not be a known orphan (fleet-ops#2772)"
ok "fleet-ops-2772-claim-loop-gate.test.sh is pinned in the P14 reachable set (fleet-ops#2772)"

# fleet-ops#4273: hard-pin the host line for
# fleet-ops-4273-escalation-never-nish-decision. The escalation-class
# regression test (neither #2462 nor #2772 escalation may emit
# nish-decision; the reserved-class path still can) is hosted from
# tests/pi-intake-tick-reclaim-cooldown.test.sh (already listed in ci.yml) —
# the worker App cannot push .github/workflows/** so the host was the only
# path. This named pin is class-prevention so a future drop of the host
# line cannot park the test on known_orphans to silence the generic $bad[]
# message — it fails by name here first, same shape as every other hosted
# test above.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-ops-4273-escalation-never-nish-decision\.test\.sh"?' \
  "$here/pi-intake-tick-reclaim-cooldown.test.sh" \
  || fail "pi-intake-tick-reclaim-cooldown.test.sh must bash-invoke fleet-ops-4273-escalation-never-nish-decision.test.sh (fleet-ops#4273)"
[[ -n "${reachable[fleet-ops-4273-escalation-never-nish-decision.test.sh]:-}" ]] \
  || fail "fleet-ops-4273-escalation-never-nish-decision.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#4273)"
[[ -z "${known_orphan_set[fleet-ops-4273-escalation-never-nish-decision.test.sh]:-}" ]] \
  || fail "fleet-ops-4273-escalation-never-nish-decision.test.sh must not be a known orphan (fleet-ops#4273)"
ok "fleet-ops-4273-escalation-never-nish-decision.test.sh is pinned in the P14 reachable set (fleet-ops#4273)"

# fleet-ops#3873: hard-pin the host line for the per-seat-timeout test. It
# is hosted from pi-issue-run-failure-reason.test.sh (already in P14 via
# worker-token-fail-closed.test.sh) because the worker App has no
# Workflows scope to add a ci.yml line. Hosting on the #568 failure-reason
# host mirrors pi-issue-run-tried-reset.test.sh. Named pin so a future drop
# of the host line cannot park the test on known_orphans to silence the
# generic $bad[] message — it fails by name here first.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/pi-issue-run-per-seat-timeout\.test\.sh"?' \
  "$here/pi-issue-run-failure-reason.test.sh" \
  || fail "pi-issue-run-failure-reason.test.sh must bash-invoke pi-issue-run-per-seat-timeout.test.sh (fleet-ops#3873)"
[[ -n "${reachable[pi-issue-run-per-seat-timeout.test.sh]:-}" ]] \
  || fail "pi-issue-run-per-seat-timeout.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#3873)"
[[ -z "${known_orphan_set[pi-issue-run-per-seat-timeout.test.sh]:-}" ]] \
  || fail "pi-issue-run-per-seat-timeout.test.sh must not be a known orphan (fleet-ops#3873)"
ok "pi-issue-run-per-seat-timeout.test.sh is pinned in the P14 reachable set (fleet-ops#3873)"

# fleet-ops#5045: hard-pin the host line for the mention-strand park test.
# It is hosted from pi-intake-tick-reclaim-cooldown.test.sh (already listed
# in ci.yml) because the worker App has no Workflows scope to add a ci.yml
# line — same intake dispatch family as the #4540 host there. Named pin so
# a future drop of the host line cannot park the test on known_orphans to
# silence the generic $bad[] message — it fails by name here first.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/pi-intake-tick-mention-strand-park\.test\.sh"?' \
  "$here/pi-intake-tick-reclaim-cooldown.test.sh" \
  || fail "pi-intake-tick-reclaim-cooldown.test.sh must bash-invoke pi-intake-tick-mention-strand-park.test.sh (fleet-ops#5045)"
[[ -n "${reachable[pi-intake-tick-mention-strand-park.test.sh]:-}" ]] \
  || fail "pi-intake-tick-mention-strand-park.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#5045)"
[[ -z "${known_orphan_set[pi-intake-tick-mention-strand-park.test.sh]:-}" ]] \
  || fail "pi-intake-tick-mention-strand-park.test.sh must not be a known orphan (fleet-ops#5045)"
ok "pi-intake-tick-mention-strand-park.test.sh is pinned in the P14 reachable set (fleet-ops#5045)"

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

# fleet-ops#5889: auto-host instead of fail. Any test not reachable from a
# ci.yml listing and not explicitly exempt (live/destructive, known orphan)
# is executed right here, so a worker PR that adds a new test with NO
# ci.yml change turns the P14 check green — and the new test actually
# runs. This deletes the per-file listing requirement (the gate IS the
# glob host; the ci.yml-edit variant of class 1 is impossible for the
# worker App token, which lacks Workflows scope).
if (( ${#bad[@]} > 0 )); then
  auto_host_failures=()
  for t in "${bad[@]}"; do
    echo "auto-host (fleet-ops#5889): bash tests/$t"
    if ! bash "$here/$t"; then
      auto_host_failures+=("$t")
    fi
  done
  if (( ${#auto_host_failures[@]} > 0 )); then
    {
      echo "FAIL: ${#auto_host_failures[@]} auto-hosted test file(s) failed via the #5889 glob host:"
      for t in "${auto_host_failures[@]}"; do
        echo "  $t"
      done
      echo "Fix the test, or (live/destructive/VPS-only) add it to the live_skip denylist in tests/p14-test-listing-gate.test.sh (worker-writable)."
    } >&2
    exit 1
  fi
  ok "auto-hosted ${#bad[@]} unaccounted test file(s) via the #5889 glob host: ${bad[*]}"
fi

ok "all ${#all_tests[@]} test files accounted for (listed+hosted: $reachable_count, live skip: $live_count, known orphan: $known_count, auto-hosted: ${#bad[@]})"

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

# fleet-ops#1309: bypass-class after $bad[] — parking the test on
# known_orphans to silence the generic "1 test file(s) are neither..."
# message must fail by name. The early pin above is the loud named
# failure; these checks are the second line so a future worker who
# comments out the early pin still cannot park the test.
[[ -n "${reachable[alert-repair-claim-mutex.test.sh]:-}" ]] \
  || fail "alert-repair-claim-mutex.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#1309)"
[[ -z "${known_orphan_set[alert-repair-claim-mutex.test.sh]:-}" ]] \
  || fail "alert-repair-claim-mutex.test.sh must not be a known orphan (fleet-ops#1309)"
ok "alert-repair-claim-mutex.test.sh is in the P14 reachable set, not parked on known_orphans (fleet-ops#1309)"

# Self-check: this file is hosted by ci-standards-audit, not by ci.yml.
grep -Fq 'bash "$here/p14-test-listing-gate.test.sh"' "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must host p14-test-listing-gate.test.sh"
ok "p14-test-listing-gate.test.sh is hosted by ci-standards-audit.test.sh"

# fleet-ops#2920 (PR #2937 follow-up): hard-pin the host line for
# fleet-ops-drift-metrics-dropin in ci-standards-audit so a future
# refactor that drops it is caught by name. The test landed on main
# via PR #2937 without a ci.yml listing or a host; the reachable-set
# check below also fails, but this named check runs first so the
# operator gets the issue number in the FAIL line. class-prevention:
# parking it on known_orphans to silence the generic message must
# also fail by name below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-ops-drift-metrics-dropin\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-ops-drift-metrics-dropin.test.sh (fleet-ops#2920)"
[[ -n "${reachable[fleet-ops-drift-metrics-dropin.test.sh]:-}" ]] \
  || fail "fleet-ops-drift-metrics-dropin.test.sh must be hosted by a listed test (fleet-ops#2920)"
[[ -z "${known_orphan_set[fleet-ops-drift-metrics-dropin.test.sh]:-}" ]] \
  || fail "fleet-ops-drift-metrics-dropin.test.sh must not be a known orphan (fleet-ops#2920)"
ok "fleet-ops-drift-metrics-dropin.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#2920)"

# fleet-ops#2934 (PR #2948 follow-up): hard-pin the host line for
# seat-empty-run-intermittent-count in ci-standards-audit so a future
# refactor that drops it is caught by name. Same class-prevention as the
# drift test above: parking it on known_orphans to silence the generic
# message must also fail by name below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/seat-empty-run-intermittent-count\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke seat-empty-run-intermittent-count.test.sh (fleet-ops#2934)"
[[ -n "${reachable[seat-empty-run-intermittent-count.test.sh]:-}" ]] \
  || fail "seat-empty-run-intermittent-count.test.sh must be hosted by a listed test (fleet-ops#2934)"
[[ -z "${known_orphan_set[seat-empty-run-intermittent-count.test.sh]:-}" ]] \
  || fail "seat-empty-run-intermittent-count.test.sh must not be a known orphan (fleet-ops#2934)"
ok "seat-empty-run-intermittent-count.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#2934)"

# fleet-ops#3666 (PR #3769 follow-up): hard-pin the host line for
# seat-empty-run-park-persists in ci-standards-audit so a future refactor
# that drops it is caught by name. Same class-prevention as the drift test
# above: parking it on known_orphans to silence the generic message must
# also fail by name below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/seat-empty-run-park-persists\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke seat-empty-run-park-persists.test.sh (fleet-ops#3666)"
[[ -n "${reachable[seat-empty-run-park-persists.test.sh]:-}" ]] \
  || fail "seat-empty-run-park-persists.test.sh must be hosted by a listed test (fleet-ops#3666)"
[[ -z "${known_orphan_set[seat-empty-run-park-persists.test.sh]:-}" ]] \
  || fail "seat-empty-run-park-persists.test.sh must not be a known orphan (fleet-ops#3666)"
ok "seat-empty-run-park-persists.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#3666)"

# fleet-ops#3730: hard-pin the host line for seat-empty-run-count-persists-new-issue.
# The empty-run counter must persist across a re-seat cycle (a new issue id
# must not reset it to 1) and the seat must be held until a non-empty run
# proves it. Hosted from ci-standards-audit (already in P14); named pin so a
# future drop of the host line fails by name and cannot be parked on orphans.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/seat-empty-run-count-persists-new-issue\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke seat-empty-run-count-persists-new-issue.test.sh (fleet-ops#3730)"
[[ -n "${reachable[seat-empty-run-count-persists-new-issue.test.sh]:-}" ]] \
  || fail "seat-empty-run-count-persists-new-issue.test.sh must be hosted by a listed test (fleet-ops#3730)"
[[ -z "${known_orphan_set[seat-empty-run-count-persists-new-issue.test.sh]:-}" ]] \
  || fail "seat-empty-run-count-persists-new-issue.test.sh must not be a known orphan (fleet-ops#3730)"
ok "seat-empty-run-count-persists-new-issue.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#3730)"

# fleet-ops#3295 (PR #3352 follow-up): hard-pin the host line for
# pi-intake-tick-umbrella-exclusion in pi-intake-run (already listed in
# ci.yml) so a future refactor that drops it is caught by name. PR #3352
# added the test without a ci.yml listing or a host, leaving main red on
# the generic "1 test file(s) are neither ..." FAIL from run 33908689540
# (P14 red on every push since). This named pin is class-prevention:
# parking it on known_orphans to silence the generic message must also
# fail by name below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/pi-intake-tick-umbrella-exclusion\.test\.sh"?' \
  "$here/pi-intake-run.test.sh" \
  || fail "pi-intake-run.test.sh must bash-invoke pi-intake-tick-umbrella-exclusion.test.sh (fleet-ops#3295)"
[[ -n "${reachable[pi-intake-tick-umbrella-exclusion.test.sh]:-}" ]] \
  || fail "pi-intake-tick-umbrella-exclusion.test.sh must be hosted by a listed test (fleet-ops#3295)"
[[ -z "${known_orphan_set[pi-intake-tick-umbrella-exclusion.test.sh]:-}" ]] \
  || fail "pi-intake-tick-umbrella-exclusion.test.sh must not be a known orphan (fleet-ops#3295)"
ok "pi-intake-tick-umbrella-exclusion.test.sh host line in pi-intake-run.test.sh is pinned (fleet-ops#3295)"

# fleet-ops#3254 (part 1/4, PR part of the self-limiting-budget split):
# hard-pin the host line for pi-intake-tick-self-maint-cap in
# pi-intake-run (already listed in ci.yml) so a future refactor that drops
# it is caught by name. Same class-prevention: parking it on known_orphans
# to silence the generic message must also fail by name below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/pi-intake-tick-self-maint-cap\.test\.sh"?' \
  "$here/pi-intake-run.test.sh" \
  || fail "pi-intake-run.test.sh must bash-invoke pi-intake-tick-self-maint-cap.test.sh (fleet-ops#3254)"
[[ -n "${reachable[pi-intake-tick-self-maint-cap.test.sh]:-}" ]] \
  || fail "pi-intake-tick-self-maint-cap.test.sh must be hosted by a listed test (fleet-ops#3254)"
[[ -z "${known_orphan_set[pi-intake-tick-self-maint-cap.test.sh]:-}" ]] \
  || fail "pi-intake-tick-self-maint-cap.test.sh must not be a known orphan (fleet-ops#3254)"
ok "pi-intake-tick-self-maint-cap.test.sh host line in pi-intake-run.test.sh is pinned (fleet-ops#3254)"

# fleet-ops#1520: hard-pin the host line for curator-journal-cap in
# ci-standards-audit so a future refactor that drops it is caught by
# name. The live dump was fixed in memory-compound#9; this test is the
# fleet-ops class lock. Hosted from tests/ci-standards-audit.test.sh
# (already listed in ci.yml) because the worker App cannot push
# .github/workflows/**. Parking it on known_orphans to silence the
# generic message must also fail by name below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/curator-journal-cap\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke curator-journal-cap.test.sh (fleet-ops#1520)"
[[ -n "${reachable[curator-journal-cap.test.sh]:-}" ]] \
  || fail "curator-journal-cap.test.sh must be hosted by a listed test (fleet-ops#1520)"
[[ -z "${known_orphan_set[curator-journal-cap.test.sh]:-}" ]] \
  || fail "curator-journal-cap.test.sh must not be a known orphan (fleet-ops#1520)"
ok "curator-journal-cap.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#1520)"

# fleet-ops#3273: hard-pin the host line for install-manifest-bak-sprawl in
# ci-standards-audit so a future refactor that drops it is caught by name.
# Hosted from tests/ci-standards-audit.test.sh (already listed in ci.yml)
# because the worker App cannot push .github/workflows/**. Parking it on
# known_orphans to silence the generic message must also fail by name below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/install-manifest-bak-sprawl\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke install-manifest-bak-sprawl.test.sh (fleet-ops#3273)"
[[ -n "${reachable[install-manifest-bak-sprawl.test.sh]:-}" ]] \
  || fail "install-manifest-bak-sprawl.test.sh must be hosted by a listed test (fleet-ops#3273)"
[[ -z "${known_orphan_set[install-manifest-bak-sprawl.test.sh]:-}" ]] \
  || fail "install-manifest-bak-sprawl.test.sh must not be a known orphan (fleet-ops#3273)"
ok "install-manifest-bak-sprawl.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#3273)"

# fleet-ops#5602: hard-pin the host line for
# fleet-ops-drift-sprawl-quarantine in ci-standards-audit so a future
# refactor that drops it is caught by name. Hosted from
# tests/ci-standards-audit.test.sh (already listed in ci.yml) because the
# worker App cannot push .github/workflows/**. Parking it on known_orphans
# to silence the generic message must also fail by name below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-ops-drift-sprawl-quarantine\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-ops-drift-sprawl-quarantine.test.sh (fleet-ops#5602)"
[[ -n "${reachable[fleet-ops-drift-sprawl-quarantine.test.sh]:-}" ]] \
  || fail "fleet-ops-drift-sprawl-quarantine.test.sh must be hosted by a listed test (fleet-ops#5602)"
[[ -z "${known_orphan_set[fleet-ops-drift-sprawl-quarantine.test.sh]:-}" ]] \
  || fail "fleet-ops-drift-sprawl-quarantine.test.sh must not be a known orphan (fleet-ops#5602)"
ok "fleet-ops-drift-sprawl-quarantine.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#5602)"

# fleet-ops#4948: hard-pin the host line for install-check-content-equivalent in
# ci-standards-audit so a future refactor that drops it is caught by name.
# Hosted from tests/ci-standards-audit.test.sh (already listed in ci.yml)
# because the worker App cannot push .github/workflows/**. Parking it on
# known_orphans to silence the generic message must also fail by name below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/install-check-content-equivalent\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke install-check-content-equivalent.test.sh (fleet-ops#4948)"
[[ -n "${reachable[install-check-content-equivalent.test.sh]:-}" ]] \
  || fail "install-check-content-equivalent.test.sh must be hosted by a listed test (fleet-ops#4948)"
[[ -z "${known_orphan_set[install-check-content-equivalent.test.sh]:-}" ]] \
  || fail "install-check-content-equivalent.test.sh must not be a known orphan (fleet-ops#4948)"
ok "install-check-content-equivalent.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#4948)"

# fleet-ops#3285: hard-pin the host line for daily-digest in
# ci-standards-audit so a future refactor that drops it is caught by name.
# The spend-line replay drill landed in this PR without a ci.yml listing
# (the worker App cannot push .github/workflows/**), so it is hosted from
# tests/ci-standards-audit.test.sh (already listed in ci.yml). Parking it
# on known_orphans to silence the generic message must also fail by name
# below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/daily-digest\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke daily-digest.test.sh (fleet-ops#3285)"
[[ -n "${reachable[daily-digest.test.sh]:-}" ]] \
  || fail "daily-digest.test.sh must be hosted by a listed test (fleet-ops#3285)"
[[ -z "${known_orphan_set[daily-digest.test.sh]:-}" ]] \
  || fail "daily-digest.test.sh must not be a known orphan (fleet-ops#3285)"
ok "daily-digest.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#3285)"

# fleet-ops#4394: hard-pin the host line for fleet-duty-officer-recording.
# Hosted from tests/ci-standards-audit.test.sh (already listed in ci.yml)
# because the worker App cannot push .github/workflows/**. Parking it on
# known_orphans to silence the generic message must also fail by name.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-duty-officer-recording\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke fleet-duty-officer-recording.test.sh (fleet-ops#4394)"
[[ -n "${reachable[fleet-duty-officer-recording.test.sh]:-}" ]] \
  || fail "fleet-duty-officer-recording.test.sh must be hosted by a listed test (fleet-ops#4394)"
[[ -z "${known_orphan_set[fleet-duty-officer-recording.test.sh]:-}" ]] \
  || fail "fleet-duty-officer-recording.test.sh must not be a known orphan (fleet-ops#4394)"
ok "fleet-duty-officer-recording.test.sh is pinned in the P14 reachable set (fleet-ops#4394)"

# fleet-ops#362: hard-pin the host line for signal-reconcile in
# ci-standards-audit.test.sh. The detector->queue reconciler test is hermetic
# and hosted here (workers cannot push .github/workflows/**); the pin is
# class-prevention so a future drop of the host line cannot park the test on
# known_orphans to silence the generic $bad[] message — it fails by name first.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/signal-reconcile\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke signal-reconcile.test.sh (fleet-ops#362)"
[[ -n "${reachable[signal-reconcile.test.sh]:-}" ]] \
  || fail "signal-reconcile.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#362)"
[[ -z "${known_orphan_set[signal-reconcile.test.sh]:-}" ]] \
  || fail "signal-reconcile.test.sh must not be a known orphan (fleet-ops#362)"
ok "signal-reconcile.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#362)"


# fleet-ops#5059: hard-pin the host line for helper-symlink-resolution in
# ci-standards-audit so a future refactor that drops it is caught by name.
# Hosted from tests/ci-standards-audit.test.sh (already listed in ci.yml)
# because the worker App cannot push .github/workflows/**. Parking it on
# known_orphans to silence the generic message must also fail by name below.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/helper-symlink-resolution\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke helper-symlink-resolution.test.sh (fleet-ops#5059)"
[[ -n "${reachable[helper-symlink-resolution.test.sh]:-}" ]] \
  || fail "helper-symlink-resolution.test.sh must be hosted by a listed test (fleet-ops#5059)"
[[ -z "${known_orphan_set[helper-symlink-resolution.test.sh]:-}" ]] \
  || fail "helper-symlink-resolution.test.sh must not be a known orphan (fleet-ops#5059)"
ok "helper-symlink-resolution.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#5059)"

# fleet-ops#5072: hard-pin the host line for console-truth-pytest in
# console-tile-verify.test.sh (itself hosted by ci-standards-audit.test.sh,
# which ci.yml lists). The console-truth pytest suite guards the fleet-ops#4996
# argv regression class, and it ran on nothing automatic before this host; the
# worker App cannot push .github/workflows/**, so the host line is the only
# gate path. Parking it on known_orphans to silence the generic $bad[] message
# must also fail by name here first, same shape as every other hosted test.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/console-truth-pytest\.test\.sh"?' \
  "$here/console-tile-verify.test.sh" \
  || fail "console-tile-verify.test.sh must bash-invoke console-truth-pytest.test.sh (fleet-ops#5072)"
[[ -n "${reachable[console-truth-pytest.test.sh]:-}" ]] \
  || fail "console-truth-pytest.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#5072)"
[[ -z "${known_orphan_set[console-truth-pytest.test.sh]:-}" ]] \
  || fail "console-truth-pytest.test.sh must not be a known orphan (fleet-ops#5072)"
ok "console-truth-pytest.test.sh host line in console-tile-verify.test.sh is pinned (fleet-ops#5072)"

# fleet-ops#5588: hard-pin the host line for one-fleet-rule-pointer.test.sh in
# ci-standards-audit.test.sh (itself listed in ci.yml). The consolidation
# detector guards the one-fleet title+pointer shape in canonical + rendered
# targets; the worker App cannot push .github/workflows/**, so the host line
# is the only gate path. Parking it on known_orphans must also fail by name
# here, same shape as every other hosted test.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/one-fleet-rule-pointer\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke one-fleet-rule-pointer.test.sh (fleet-ops#5588)"
[[ -n "${reachable[one-fleet-rule-pointer.test.sh]:-}" ]] \
  || fail "one-fleet-rule-pointer.test.sh must be hosted by a listed test (fleet-ops#5588)"
[[ -z "${known_orphan_set[one-fleet-rule-pointer.test.sh]:-}" ]] \
  || fail "one-fleet-rule-pointer.test.sh must not be a known orphan (fleet-ops#5588)"
ok "one-fleet-rule-pointer.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#5588)"

# fleet-ops#5748: hard-pin the host line for live-state-doctrine-precedence
# in ci-standards-audit so a future refactor that drops it is caught by name.
# The test (PR #5755) landed without a ci.yml listing or a host and P14 ran
# red on "1 test file(s) are neither in ci.yml, hosted by a listed test,
# live/destructive, nor a known orphan: live-state-doctrine-precedence.test.sh"
# (run 34670719563). The worker App cannot push .github/workflows/**, so the
# host line is the only path. Parking it on known_orphans to silence the
# generic $bad[] message must also fail by name here first, same shape as
# every other hosted test.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/live-state-doctrine-precedence\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke live-state-doctrine-precedence.test.sh (fleet-ops#5748)"
[[ -n "${reachable[live-state-doctrine-precedence.test.sh]:-}" ]] \
  || fail "live-state-doctrine-precedence.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#5748)"
[[ -z "${known_orphan_set[live-state-doctrine-precedence.test.sh]:-}" ]] \
  || fail "live-state-doctrine-precedence.test.sh must not be a known orphan (fleet-ops#5748)"
ok "live-state-doctrine-precedence.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#5748)"

# fleet-ops#5870: hard-pin the host line for measure-attest-waiting in
# ci-standards-audit so a future refactor that drops it is caught by name.
# The test landed on the claim branch without a ci.yml listing or a host
# and P14 ran red on "1 test file(s) are neither in ci.yml, hosted by a
# listed test, live/destructive, nor a known orphan: measure-attest-waiting.test.sh"
# (run 34687524771). The worker App cannot push .github/workflows/**, so
# the host line is the only path. Parking it on known_orphans to silence
# the generic $bad[] message must also fail by name here first, same shape
# as every other hosted test.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/measure-attest-waiting\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke measure-attest-waiting.test.sh (fleet-ops#5870)"
[[ -n "${reachable[measure-attest-waiting.test.sh]:-}" ]] \
  || fail "measure-attest-waiting.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#5870)"
[[ -z "${known_orphan_set[measure-attest-waiting.test.sh]:-}" ]] \
  || fail "measure-attest-waiting.test.sh must not be a known orphan (fleet-ops#5870)"
ok "measure-attest-waiting.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#5870)"

echo "OK: p14-test-listing-gate.test.sh: P14 test list is closed"
