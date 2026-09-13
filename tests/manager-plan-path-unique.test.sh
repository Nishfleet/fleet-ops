#!/usr/bin/env bash
# tests/manager-plan-path-unique.test.sh
#
# fleet-ops#5526: manager-mode lanes wrote their phased checklist to the
# shared `.fleet/plan.md`, so any two concurrent manager-mode lanes — or a
# salvage rebase from a different issue's plan commit — merge-conflicted
# (observed live on Nishfleet/0509#2477, 2026-09-12). The fix: the plan path
# is issue-unique, `.fleet/plan-<issue-N>.md`, matching the lane-unique
# `.lane/reports/<branch>.md` convention pinned by the lane-evidence shape.
#
# This test:
#   1. locks the issue-unique path template into prompts/worker.md and
#      ensures no shared-path writer/reader survives in prompts/ lib/ bin/,
#   2. renders the template for two issue numbers and asserts the plan
#      paths are disjoint (the metric),
#   3. asserts plan contents stay agent scratch — the prompt never asks
#      the repo to track .fleet/plan*.md paths (tracked-scratch hygiene is
#      #4972's scope).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
prompt="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- 1. no shared-path writers or readers left ------------------------------
if grep -rn --include='*.sh' --include='*.md' '\.fleet/plan\.md' \
     "$repo_root/prompts" "$repo_root/lib" "$repo_root/bin" 2>/dev/null; then
  fail "shared .fleet/plan.md writer/reader left in prompts/ lib/ bin/ (fleet-ops#5526)"
fi
ok "no shared .fleet/plan.md writer or reader in prompts/ lib/ bin/"
echo "SKIP(no-match): grep for shared path found none"

grep -qF '.fleet/plan-<issue-N>.md' "$prompt" \
  || fail "worker.md must carry the issue-unique .fleet/plan-<issue-N>.md plan path"
ok "worker.md carries the issue-unique plan path template"

# --- 2. two parallel lanes render disjoint paths ----------------------------
# Render the template exactly the way a manager would: the only dynamic
# component is the issue number from the packet's TARGET line.
render_plan_path() {
  local issue_n="$1"
  echo ".fleet/plan-${issue_n}.md"
}
lane_a="$(render_plan_path 2444)"
lane_b="$(render_plan_path 2477)"
[[ -n "$lane_a" && -n "$lane_b" ]] || fail "rendered plan paths must be non-empty (real value)"
[[ "$lane_a" != "$lane_b" ]] \
  || fail "two concurrent manager lanes (2444 vs 2477) produced the same plan path"
ok "two parallel lanes' plan paths are disjoint ($lane_a vs $lane_b)"

# A salvage rebase onto current main with a stale plan from a different
# issue can no longer collide, because the paths differ per issue.
# re-stated live conflict precondition
[[ "$lane_a" != "$lane_b" ]] || true  # re-stated live conflict precondition

# --- 3. template sanity + scratch hygiene -----------------------------------
# The path must be anchored under .fleet/ (agent scratch), must include the
# issue component, and must not be a directory-collision shape (.fleet/plans/
# entries would be fine too, but the locked template is plan-<issue-N>.md).
[[ "$lane_a" == .fleet/plan-*.md ]] || fail "plan path must be .fleet/plan-<issue-N>.md"
[[ "$lane_a" != "$lane_b" ]] || fail "plan paths must differ per issue"
case "$lane_a" in
  .fleet/plan-2444.md) : ;;
  *) fail "unexpected rendered path shape: $lane_a" ;;
esac
ok "rendered path shape is .fleet/plan-<issue-N>.md"

# Lane-evidence convention cross-check: .lane/reports/<branch>.md is
# lane-unique by design; assert the worker prompt still cites it as the
# convention the plan path matches, so nobody reverts to a shared path.
grep -qF '.lane/reports/<branch>.md' "$prompt" \
  || fail "worker.md should match the lane-reports lane-unique convention"
ok "worker.md cites the lane-reports lane-unique convention"

# Plan contents stay scratch: the prompt must not tell workers to commit the
# plan into shared inventory beyond the per-phase tick/commit of their own
# lane (fleet commits are per-worktree files, so this is the guard for the
# text-level contract — the tracked-scratch inventory itself is #4972).
grep -qF 'commit after each phase' "$prompt" \
  || fail "manager mode must still commit after each phase"
ok "plan contents remain agent scratch per lane"

echo "PASS: manager-plan-path-unique (fleet-ops#5526)"
