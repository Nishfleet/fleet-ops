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
# fleet-ops#5912: declared-fork extensions must be regular files identical to
# the repo template under ~/.pi/agent/extensions — a 2026-09-19 `ln -sf` pass
# re-symlinked them to stock and dropped the fleet rules silently. VPS-only
# (reads ~/.pi); skips in hosted CI.
live_skip[pi-extensions-forks-live.test.sh]=1
# fleet-ops#4141: the 12 opus-heartbeat-* tests were deleted (the opus-
# heartbeat family was retired — recording rules + fable-check.md replaced
# it). No live_skip entries needed for deleted tests.
# fleet-ops#1740 added gh-webhook-receiver-live-e2e.test.sh (live webhook →
# Prometheus → alert e2e) but omitted the live_skip entry, leaving main red
# on this required gate. The test skips gracefully in hosted CI (no live
# receiver/Prometheus) and only runs on the VPS, so live_skip is the correct
# classification, not a ci.yml listing (which would need workflow scope).
# fleet-ops#4263 P3b: the pick-seat / AIMD / ledger tests retired with the
# routing library are DELETED, not parked here. Seven entries below used to
# name files the 2026-09-18 sweep had already removed — fleet-ops#6003.
# fleet-ops#6003: an entry naming a file that no longer exists is not an
# exemption, it is a hole — the list reads healthy while the file is gone,
# and nothing checked. The stale-file check further down now fails on it.
live_skip[seat-caps-zero-yield.test.sh]=1
live_skip[seat-caps-citation.test.sh]=1
live_skip[seat-caps-citation-rule6-replay.test.sh]=1
# Hosted CI has no promtool and no live fleet-work.slice. These two were
# auto-hosted once earlier P14 steps stopped dying at findings-measure-line
# (fleet-ops#6257). They are VPS-only.
live_skip[ci-queue-alerts.test.sh]=1
live_skip[fleet-work-slice-tasksmax.test.sh]=1

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
# fleet-ops#6003: ten entries here also named files the sweep had deleted
# (agent-cron-failure-reason, the four fleet-heartbeat-*, fleet-researcher,
# install-manifest-comment-purity, pi-issue-run-defensive-mkdir,
# pi-issue-run-mid-session-bench, pi-scout-seat-rotation). Only the two tests
# that are actually on disk and genuinely orphaned stay.
known_orphans=(
  org-ruleset-skip-detector.test.sh
  verify-fleet-sync-pat.test.sh
)

declare -A known_orphan_set
for t in "${known_orphans[@]}"; do
  known_orphan_set[$t]=1
done

# fleet-ops#1331 is a duplicate of #1309, filed 3 minutes later
# (2026-08-27T18:36:29Z vs #1309 at 18:33:00Z) while #1309 was still
# open. The same fix — host line in tests/seat.lib.test.sh (PR #1288
# leftover) plus this named pin (PR #1833, merged 2026-08-29T03:12:24Z)
# — closes both. No new code; this comment plus the closing PR is the
# receipt, same shape as the #831/#799 duplicate receipts above.
# Verified: `bash tests/ci-standards-audit.test.sh` no longer reports
# alert-repair-claim-mutex.test.sh as an unhosted orphan on origin/main.

# fleet-ops#5586: hard-pin reserved-classes-precedence into the reachable set.
# It used to be hosted from rule-enforcement.test.sh, which the glue sweep
# deleted with the rule matrix; the test itself is still live and still the
# #5586 containment detector, so it is now listed in ci.yml directly and the
# host-line grep (which pointed at the deleted host) is gone. The two
# assertions below are the part that actually matters: the detector must stay
# reachable and must never be parked on known_orphans to silence the gate.
[[ -n "${reachable[reserved-classes-precedence.test.sh]:-}" ]] \
  || fail "reserved-classes-precedence.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#5586)"
[[ -z "${known_orphan_set[reserved-classes-precedence.test.sh]:-}" ]] \
  || fail "reserved-classes-precedence.test.sh must not be a known orphan (fleet-ops#5586)"
ok "reserved-classes-precedence.test.sh is pinned in the P14 reachable set (fleet-ops#5586)"

# (removed) fleet-ops#308 hard-pin for fleet-spawn-guard-stash-readonly.
# 7c2b2beac ("cut(extensions): delete 2,663 lines of pi extensions") deleted
# BOTH tests/fleet-spawn-guard-stash-readonly.test.sh and its host
# tests/spawn-guard.test.sh, leaving this pin and the ci.yml listing line
# asserting files that no longer exist — main went red on
# "FAIL: listed test not on disk: fleet-spawn-guard-stash-readonly.test.sh".
# The pin existed to stop the test being parked on known_orphans; with the
# test itself gone there is nothing left to park.

# (removed) the fleet-ops#2902 named pin for fleet-deploy-quality.test.sh — the
# 2026-09-18 glue sweep deleted that test along with its subject, so both
# the host-line grep and the reachable/known-orphan assertions pointed at a
# file that no longer exists and main went red on the listing gate.

# (removed) the fleet-ops#5140 named pin for fleet-product-deploy-0509.test.sh — the
# 2026-09-18 glue sweep deleted that test along with its subject, so both
# the host-line grep and the reachable/known-orphan assertions pointed at a
# file that no longer exists and main went red on the listing gate.

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

# fleet-ops#6052: hard-pin the host line for the deleted-symbol gate. It is
# hosted from ci-standards-audit.test.sh (already in ci.yml) because the
# worker App has no Workflows scope to add a ci.yml line — the #5748 hosting
# shape. The gate itself is a P14 step: on pull_request events it fails P14
# when the PR deletes a lib/ or bin/ definition that tests/ still reference
# (#5993 went red three times, one symbol at a time). Named pin so a future
# drop of the host line cannot park the test on known_orphans to silence the
# generic $bad[] message — it fails by name here first.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/deleted-symbol-gate\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke deleted-symbol-gate.test.sh (fleet-ops#6052)"
[[ -n "${reachable[deleted-symbol-gate.test.sh]:-}" ]] \
  || fail "deleted-symbol-gate.test.sh must be listed in ci.yml or hosted by a listed test (fleet-ops#6052)"
[[ -z "${known_orphan_set[deleted-symbol-gate.test.sh]:-}" ]] \
  || fail "deleted-symbol-gate.test.sh must not be a known orphan (fleet-ops#6052)"
ok "deleted-symbol-gate.test.sh is pinned in the P14 reachable set (fleet-ops#6052)"

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

# fleet-ops#6003: every exemption entry must name a file that still exists.
# The reachable-only check below cannot see a DELETED file, so a stale
# live_skip / known_orphans entry sat here unnoticed through the whole
# #5993/#6037 sweep — the gate read green while exempting nothing. This is
# that class's missing teeth; it fails by name on any future stale entry.
missing_exempt=()
for t in "${!live_skip[@]}" "${known_orphans[@]}"; do
  [[ -f "$here/$t" ]] || missing_exempt+=("$t")
done
if (( ${#missing_exempt[@]} > 0 )); then
  {
    echo "FAIL: exemption list(s) name test file(s) that do not exist:"
    printf '  %s\n' "${missing_exempt[@]}"
    echo "Remove the stale live_skip / known_orphans entry — a file that is gone cannot be exempt."
  } >&2
  exit 1
fi
ok "live_skip and known_orphans name only test files that exist"

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




# (removed) the fleet-ops#3285 named pin for daily-digest.test.sh — the
# 2026-09-18 glue sweep deleted that test along with its subject, so both
# the host-line grep and the reachable/known-orphan assertions pointed at a
# file that no longer exists and main went red on the listing gate.

# (removed) the fleet-ops#4394 named pin for fleet-duty-officer-recording.test.sh — the
# 2026-09-18 glue sweep deleted that test along with its subject, so both
# the host-line grep and the reachable/known-orphan assertions pointed at a
# file that no longer exists and main went red on the listing gate.

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


# fleet-ops#4263: hard-pin the host line for pick-seat-freeze in
# ci-standards-audit.test.sh. The caller-set freeze rides on that listed
# test (the worker App cannot push .github/workflows/**); the pin is
# class-prevention so a dropped host line cannot park the freeze on
# known_orphans — it fails by name first, same shape as the other pins.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/pick-seat-freeze\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke pick-seat-freeze.test.sh (fleet-ops#4263)"
[[ -n "${reachable[pick-seat-freeze.test.sh]:-}" ]] \
  || fail "pick-seat-freeze.test.sh must be hosted by a listed test (fleet-ops#4263)"
[[ -z "${known_orphan_set[pick-seat-freeze.test.sh]:-}" ]] \
  || fail "pick-seat-freeze.test.sh must not be a known orphan (fleet-ops#4263)"
ok "pick-seat-freeze.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#4263)"

# fleet-ops#7842: hard-pin the host line for skill-bak-sprawl in
# ci-standards-audit.test.sh. The hash-verify-and-delete lock for stale
# `.bak-*` skill siblings rides on that listed test (the worker App cannot
# push .github/workflows/**); the pin is class-prevention so a dropped host
# line cannot park the lock on known_orphans — it fails by name first.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/skill-bak-sprawl\.test\.sh"?' \
  "$here/ci-standards-audit.test.sh" \
  || fail "ci-standards-audit.test.sh must bash-invoke skill-bak-sprawl.test.sh (fleet-ops#7842)"
[[ -n "${reachable[skill-bak-sprawl.test.sh]:-}" ]] \
  || fail "skill-bak-sprawl.test.sh must be hosted by a listed test (fleet-ops#7842)"
[[ -z "${known_orphan_set[skill-bak-sprawl.test.sh]:-}" ]] \
  || fail "skill-bak-sprawl.test.sh must not be a known orphan (fleet-ops#7842)"
ok "skill-bak-sprawl.test.sh host line in ci-standards-audit.test.sh is pinned (fleet-ops#7842)"

# fleet-ops#6025: hard-pin the host line for fleet-researcher-oversize in
# seat-lib.test.sh (already listed in ci.yml). The groq TPM-wall lock
# rides on that listed test (the worker App cannot push .github/workflows/**);
# the pin is class-prevention so a dropped host line cannot park the lock
# on known_orphans — it fails by name first.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-researcher-oversize\.test\.sh"?' \
  "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must bash-invoke fleet-researcher-oversize.test.sh (fleet-ops#6025)"
[[ -n "${reachable[fleet-researcher-oversize.test.sh]:-}" ]] \
  || fail "fleet-researcher-oversize.test.sh must be hosted by a listed test (fleet-ops#6025)"
[[ -z "${known_orphan_set[fleet-researcher-oversize.test.sh]:-}" ]] \
  || fail "fleet-researcher-oversize.test.sh must not be a known orphan (fleet-ops#6025)"
ok "fleet-researcher-oversize.test.sh host line in seat-lib.test.sh is pinned (fleet-ops#6025)"

# fleet-ops#6094: hard-pin the host line for fleet-researcher-failed-cycle
# in fleet-researcher-oversize.test.sh (already on a listed P14 host).
# The standing-FAIL 24h lock rides on that listed chain (the worker App
# cannot push .github/workflows/**); the pin is class-prevention so a
# dropped host line cannot park the lock on known_orphans — it fails by
# name first.
grep -Eq '^[[:space:]]*bash[[:space:]]+"?\$here/fleet-researcher-failed-cycle\.test\.sh"?' \
  "$here/fleet-researcher-oversize.test.sh" \
  || fail "fleet-researcher-oversize.test.sh must bash-invoke fleet-researcher-failed-cycle.test.sh (fleet-ops#6094)"
[[ -n "${reachable[fleet-researcher-failed-cycle.test.sh]:-}" ]] \
  || fail "fleet-researcher-failed-cycle.test.sh must be hosted by a listed test (fleet-ops#6094)"
[[ -z "${known_orphan_set[fleet-researcher-failed-cycle.test.sh]:-}" ]] \
  || fail "fleet-researcher-failed-cycle.test.sh must not be a known orphan (fleet-ops#6094)"
ok "fleet-researcher-failed-cycle.test.sh host line in fleet-researcher-oversize.test.sh is pinned (fleet-ops#6094)"

echo "OK: p14-test-listing-gate.test.sh: P14 test list is closed"
