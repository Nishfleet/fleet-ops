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
# fleet-ops#1382: opus-heartbeat THOROUGH-mode test reads VPS-local state
# (the launcher binary, the gather script, the judge prompt, and the
# thorough service unit). Live/VPS-only — cannot run in hosted CI.
live_skip[opus-heartbeat-thorough-mode.test.sh]=1
# fleet-ops#2152: opus-heartbeat-seat-comeback invokes the VPS-deployed
# opus-heartbeat-gather launcher (/home/nish/.local/libexec/), which is
# absent on hosted runners. Live/VPS-only — cannot run in hosted CI.
live_skip[opus-heartbeat-seat-comeback.test.sh]=1
# fleet-ops#2517: opus-heartbeat-fabricated-transcript-gate reads VPS-local
# state (the launcher binary at /home/nish/.local/libexec/opus-heartbeat
# and the judge prompt at /home/nish/.local/share/opus-heartbeat/
# judge-prompt.md). Live/VPS-only — cannot run in hosted CI.
live_skip[opus-heartbeat-fabricated-transcript-gate.test.sh]=1
# fleet-ops#2711: opus-heartbeat-frozen-claims-gate drives the launcher
# --check-allowlist subcommand against fixture snapshots and pins the
# live launcher + judge prompt for the claims-aware gate shape. Live/
# VPS-only — cannot run in hosted CI (launcher binary absent).
live_skip[opus-heartbeat-frozen-claims-gate.test.sh]=1
# fleet-ops#2751: opus-heartbeat-failed-units-gate drives the gather's
# --check-failed-units-gate subcommand against fixture snapshots and pins
# the installed gather at /home/nish/.local/libexec/opus-heartbeat-gather
# plus the live snapshot. Live/VPS-only — cannot run in hosted CI (gather
# script absent).
live_skip[opus-heartbeat-failed-units-gate.test.sh]=1
# fleet-ops#3189: opus-heartbeat-scout-staleness-gate drives the gather's
# --check-scout-staleness-gate subcommand against fixture snapshots and
# pins the installed gather at /home/nish/.local/libexec/opus-heartbeat-
# gather plus the live snapshot. Live/VPS-only — cannot run in hosted CI
# (gather script absent).
live_skip[opus-heartbeat-scout-staleness-gate.test.sh]=1
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
# reverted. Host it from spawn-guard.test.sh (the consolidated spawn-guard
# suite, itself hosted from rule-enforcement.test.sh — same nested-CI
# pattern as dirty-worktree-audit, fleet-ops#787) and add this named pin so
# a future drop of the host line cannot park the test on known_orphans to
# silence the generic $bad[] message — it would fail by name here first.
# fleet-ops#3300: PR #3334 consolidated the direct rule-enforcement.test.sh
# host into spawn-guard.test.sh but left this pin grepping the old host,
# so every push to main went red. The pin now targets the actual host.
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

echo "OK: p14-test-listing-gate.test.sh: P14 test list is closed"
