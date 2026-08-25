#!/usr/bin/env bash
# tests/exec-review-prompt.test.sh
#
# Locks the fleet-ops#31 contract: the issue-worker prompt carries the
# run → queue bugs → fix → re-run inner loop. The loop is agentic and
# lives in the prompt. A bash retry wrapper is forbidden.
#
# Invariants:
#   1. prompts/worker.md names "Execution IS the review".
#   2. FAILURE, SKIP, and PRE-EXISTING appear as distinct buckets.
#   3. The inner-loop cap is 5 (measured: the worked example needed 4).
#   4. The prompt forbids a bash retry wrapper.
#   5. Review gates run only after a clean run.
#   6. No bin/exec-review dispatcher exists (no-hand-built-orchestration).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
prompt="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$prompt" ]] || fail "missing $prompt"

grep -q 'Execution IS the review' "$prompt" \
  || fail "worker.md must name Execution IS the review"
ok "names Execution IS the review"

for bucket in FAILURE SKIP PRE-EXISTING; do
  grep -q "$bucket" "$prompt" || fail "worker.md must name $bucket as a distinct bucket"
done
ok "FAILURE, SKIP, and PRE-EXISTING are distinct"

grep -q 'Cap: 5 inner-loop rounds' "$prompt" \
  || fail "worker.md must cap the inner loop at 5 rounds"
ok "inner-loop cap is 5"

grep -q 'Do not add a bash retry wrapper' "$prompt" \
  || fail "worker.md must forbid a bash retry wrapper"
ok "forbids a bash retry wrapper"

grep -q 'Only after a clean run' "$prompt" \
  || fail "worker.md must route review gates only after a clean run"
ok "review gates follow a clean run"

grep -q 'Then run the Execution IS the review inner loop' "$prompt" \
  || fail "step 5 must invoke the inner loop before tests/sgscan"
ok "step 5 invokes the inner loop"

[[ ! -e "$repo_root/bin/exec-review" ]] \
  || fail "bin/exec-review must not exist (no-hand-built-orchestration)"
[[ ! -e "$repo_root/systemd/exec-review@.service" ]] \
  || fail "systemd/exec-review@.service must not exist (inner loop is agentic, not Restart=)"
ok "no exec-review dispatcher"

echo "OK: worker.md carries the execution-is-review inner loop"
