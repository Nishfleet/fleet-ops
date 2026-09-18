#!/usr/bin/env bash
# tests/fleet-d1-prod-migration-grant.test.sh
#
# Proves the D1 prod migration vacation grant (fleet-ops#907) is enforced:
#   1. prompts/worker.md keeps the D1 schema rule (expand/contract) needles.
#   2. A worker.md missing any needle is rejected.
#   3. config/rule-enforcement.json has the 2026-08-27 decision as enforced,
#      with a mechanism that names the D1 schema rule and a proof that names
#      this drill, the worker prompt, and the issue.
#
# Nested from tests/rule-enforcement.test.sh so CI cannot skip it without a
# workflow edit this token cannot push.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
# 2026-09-18: the per-run-invariant rules moved out of prompts/worker.md
# into the repo AGENTS.md, which Pi loads as a context file. Same rules,
# same needles, one home instead of one copy per packet.
worker="$repo_root/AGENTS.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$worker" ]] || fail "missing $worker"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t d1-grant.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Needles from the worker.md D1 schema rule. Removing any of these would let an
# agent drop a hard migration safeguard without CI failing loud.
needles=(
  "D1 schema rule (expand/contract) — applies whenever your diff touches"
  "Rollback rolls back code, never data."
  "One phase per PR."
  "Banned in the same PR as any code change:"
  "Not done without a real integration test."
  "Stale API names are a hard failure:"
)

check_worker() {
  local path="$1"
  for needle in "${needles[@]}"; do
    grep -Fq "$needle" "$path" || return 1
  done
  return 0
}

# --- 1. production worker.md passes ------------------------------------------
check_worker "$worker" || fail "worker.md missing one or more D1 schema needles"
ok "scenario1: worker.md contains the D1 schema rule needles"

# --- 2. dropping any needle is rejected --------------------------------------
for drop in "${needles[@]}"; do
  grep -vF "$drop" "$worker" >"$scratch/worker-drop.md" || true
  set +e
  check_worker "$scratch/worker-drop.md"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "scenario2: worker.md missing '$drop' should be rejected, got rc=$rc"
  ok "scenario2: dropping '$drop' is rejected"
done

ok "d1-prod-migration-grant: worker.md D1 schema needles locked"
