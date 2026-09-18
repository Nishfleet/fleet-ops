#!/usr/bin/env bash
# tests/fleet-d1-migration-senior-process.test.sh
#
# Proves the D1 prod migration senior process enforcer (fleet-ops#906):
#   1. prompts/worker.md carries the senior process rule and voids the
#      2026-08-27 "do it right now" D1 prod migration decision.
#   2. prompts/scout.md carries the senior process in the D1 schema gate.
#   3. config/rule-enforcement.json marks the correction row as enforced
#      and names the prompt files + this test.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
# 2026-09-18: the per-run-invariant rules moved out of prompts/worker.md
# into the repo AGENTS.md, which Pi loads as a context file. Same rules,
# same needles, one home instead of one copy per packet.
worker="$repo_root/AGENTS.md"
scout="$repo_root/prompts/scout.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$worker" ]] || fail "missing $worker"
[[ -f "$scout" ]] || fail "missing $scout"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v grep >/dev/null 2>&1 || fail "grep missing"

# Worker prompt must void the earlier decision and require the senior process.
grep -q 'D1 prod migration senior process rule' "$worker" \
  || fail "worker.md must name the D1 prod migration senior process rule"
grep -q 'VOID' "$worker" \
  || fail "worker.md must void the 2026-08-27 'do it right now' decision"
grep -q 'independent senior blind-review' "$worker" \
  || fail "worker.md must require independent senior blind-review"
grep -q 'verified backup' "$worker" \
  || fail "worker.md must require verified backup"
grep -q 'concrete rollback' "$worker" \
  || fail "worker.md must require concrete rollback"
grep -q 'live verification' "$worker" \
  || fail "worker.md must require live verification"
grep -q 'text Nish' "$worker" \
  || fail "worker.md must require text Nish"
ok "worker.md carries the D1 prod migration senior process rule"

# Scout prompt must require the senior process in the D1 schema gate.
grep -q 'D1 prod migration senior process' "$scout" \
  || fail "scout.md must name the D1 prod migration senior process"
grep -q 'independent senior blind-review' "$scout" \
  || fail "scout.md must require independent senior blind-review"
grep -q 'verified backup' "$scout" \
  || fail "scout.md must require verified backup"
grep -q 'concrete rollback' "$scout" \
  || fail "scout.md must require concrete rollback"
grep -q 'text Nish' "$scout" \
  || fail "scout.md must require text Nish"
ok "scout.md carries the D1 prod migration senior process rule"

ok "d1-migration-senior-process: worker.md + scout.md prompt gate locked"
