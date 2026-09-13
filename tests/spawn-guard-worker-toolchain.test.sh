#!/usr/bin/env bash
# tests/spawn-guard-worker-toolchain.test.sh
#
# fleet-ops#5902: the worker memory-budget rule (no tsc -b / vitest --coverage /
# npm run typecheck / npm run test:coverage inside a worker) is enforced by
# spawn-guard-core, not just by prose. Worker context is the pi-issue@ cgroup;
# FLEET_WORKER_CONTEXT=1|0 overrides it here so the test is hermetic.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ext="${FLEET_SPAWN_GUARD_CORE:-$here/../template/extensions/spawn-guard-core.ts}"
[[ -r "$ext" ]] || fail "spawn-guard-core.ts unreadable: $ext"
NODE_BIN="${FLEET_SPAWN_GUARD_NODE:-node}"
command -v "$NODE_BIN" >/dev/null 2>&1 || fail "node missing ($NODE_BIN)"

expect() {
	local name="$1" want="$2" ctxflag="$3" cmd="$4" out
	out=$(FLEET_TEST_CMD="$cmd" FLEET_WORKER_CONTEXT="$ctxflag" "$NODE_BIN" --experimental-strip-types --no-warnings=ExperimentalWarning \
		--input-type=module -e "
import { workerToolchainBlock } from ${ext@Q};
const r = workerToolchainBlock({ command: process.env.FLEET_TEST_CMD, cwd: '/tmp', env: process.env });
console.log(r ? 'BLOCK:' + r : 'ALLOW');
" 2>&1) || { echo "FAIL: node run failed for [$name]"; echo "$out" >&2; exit 1; }
	if [[ "$want" == "ALLOW" ]]; then
		[[ "$out" == "ALLOW" ]] || fail "[$name] expected ALLOW, got: $out"
		ok "ALLOW: $name"
	else
		[[ "$out" == BLOCK:worker_toolchain_ban* ]] || fail "[$name] expected BLOCK worker_toolchain_ban, got: $out"
		ok "BLOCK: $name"
	fi
}
# The exact 2026-09-12 shape from pi-issue@0509-3014.
expect "npx tsc -b with heap flag (0509-3014 shape)" BLOCK 1 \
	"cd /home/nish/workspaces/agent-worktrees/issue-0509-3014 && NODE_OPTIONS=--max-old-space-size=3072 npx tsc -b"
expect "bare tsc --build" BLOCK 1 "tsc --build"
expect "vitest run --coverage" BLOCK 1 "npx vitest run --coverage --project node"
expect "npm run typecheck" BLOCK 1 "npm run typecheck"
expect "npm run test:coverage" BLOCK 1 "npm run test:coverage"
expect "npm test -- --coverage" BLOCK 1 "npm test -- --coverage"
expect "chained after a green step" BLOCK 1 "npm run lint && npm run typecheck"
# Allowed: the coverage-free targeted run the rule prescribes, and non-worker sessions.
expect "coverage-free vitest run" ALLOW 1 "npx vitest run --configLoader runner --project node --changed origin/main"
expect "tsc --noEmit on one file is not tsc -b" ALLOW 1 "npx tsc --noEmit -p tsconfig.json"
expect "grep FOR the banned phrase" ALLOW 1 "grep -rn 'tsc -b' prompts/"
expect "quoted mention in a PR body heredoc" ALLOW 1 $'cat > /tmp/body.md <<\'EOF\'\nCI owns typecheck: never `npm run typecheck` in a worker.\nEOF'
expect "same command outside a worker session" ALLOW 0 "npx tsc -b"
echo "PASS: spawn-guard worker toolchain ban"
