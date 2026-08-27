#!/usr/bin/env bash
# tests/fleet-worker-prompt-gh-pr-view-unknown-field.test.sh
#
# fleet-ops#1193: a `gh pr view <N> -R ... --json <fields>` command with an
# unknown field (e.g. `merged` instead of the valid `mergedAt`) is rejected by
# `gh` with `Unknown JSON field: "<field>"` and a non-zero exit. When the call
# is piped through `2>&1 | head`, the harness reports `isError: false` (head
# exits 0) so the failure is masked and the worker walks past it. The detector
# cannot catch this (the #1048/#1122 isError contract), so the prevention is
# worker-side: prompts/worker.md must warn about the class and that piping
# masks the exit code.
#
# This test locks the wording so a future overwrite of the prompt cannot
# silently drop the warning (same grep-lock shape as
# tests/fleet-failed-command-gh-issue-view-unknown-field.test.sh and
# tests/pstack-worker-prompt.test.sh).
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
prompt="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$prompt" ]] || fail "missing $prompt"

grep -q 'gh pr view' "$prompt" \
  || fail "worker.md must warn about gh pr view --json invalid-field (fleet-ops#1193)"
ok "worker.md warns about gh pr view --json invalid-field"

grep -q 'Unknown JSON field' "$prompt" \
  || fail "worker.md must cite the gh pr view mergedAt/merged class (fleet-ops#1193)"
ok "worker.md cites the mergedAt/merged class"

grep -q '2>&1 | head' "$prompt" \
  || fail "worker.md must warn that piping gh pr view through head masks the exit code (fleet-ops#1193)"
ok "worker.md warns that piping through head masks the exit code"

grep -q 'isError: false' "$prompt" \
  || fail "worker.md must state the isError:false pipe-mask consequence (fleet-ops#1193)"
ok "worker.md states the isError:false pipe-mask consequence"

ok "worker-prompt gh pr view unknown-field wording locked (fleet-ops#1193)"
