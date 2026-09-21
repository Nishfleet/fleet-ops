#!/usr/bin/env bash
# tests/permission-gate-worker-toolchain.test.sh
#
# fleet-ops#5902/#4891: the worker memory-budget rule (no tsc -b /
# vitest --coverage / npm run typecheck / npm run test:coverage inside a
# worker) is enforced by permission-gate.ts, not just by prose. The guard
# lived in spawn-guard-core.ts until the 2026-09-18 glue sweep (7c2b2beac)
# deleted it as collateral; it was re-homed into the permission-gate fork on
# 2026-09-21. Worker context is a fleet *-issue@ cgroup (pi-issue@,
# devin-issue@, cursor-issue@); FLEET_WORKER_CONTEXT=1|0 overrides it here so
# the test is hermetic.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ext="${FLEET_PERMISSION_GATE:-$here/../template/extensions/permission-gate.ts}"
[[ -r "$ext" ]] || fail "permission-gate.ts unreadable: $ext"
NODE_BIN="${FLEET_PERMISSION_GATE_NODE:-node}"
command -v "$NODE_BIN" >/dev/null 2>&1 || fail "node missing ($NODE_BIN)"

expect() {
	local name="$1" want="$2" ctxflag="$3" cmd="$4" out
	out=$(FLEET_TEST_CMD="$cmd" FLEET_WORKER_CONTEXT="$ctxflag" "$NODE_BIN" --experimental-strip-types --no-warnings=ExperimentalWarning \
		--input-type=module -e "
import { workerToolchainBlock } from ${ext@Q};
const r = workerToolchainBlock({ command: process.env.FLEET_TEST_CMD, env: process.env });
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

# --- fleet-ops#7381: secret_print block -------------------------------------
# The 2026-09-17 pi-issue-fleet-ops-7072 leak shape: an improvised presence
# check whose payload was "token: ${GH_TOKEN:+set}${GH_TOKEN:-EMPTY}" — the
# :- expansion prints the VALUE. The gate must block the print idioms and
# allow the prescribed `test -n` check, prose mentions, single-quoted
# literals, and send-not-print uses (curl -H).
secret() {
	local name="$1" want="$2" cmd="$3" out
	out=$(FLEET_TEST_CMD="$cmd" "$NODE_BIN" --experimental-strip-types --no-warnings=ExperimentalWarning \
		--input-type=module -e "
import { secretPrintBlock } from ${ext@Q};
const r = secretPrintBlock(process.env.FLEET_TEST_CMD);
console.log(r ? 'BLOCK:' + r : 'ALLOW');
" 2>&1) || { echo "FAIL: node run failed for [$name]"; echo "$out" >&2; exit 1; }
	if [[ "$want" == "ALLOW" ]]; then
		[[ "$out" == "ALLOW" ]] || fail "[$name] expected ALLOW, got: $out"
		ok "ALLOW: $name"
	else
		[[ "$out" == BLOCK:secret_print* ]] || fail "[$name] expected BLOCK secret_print, got: $out"
		ok "BLOCK: $name"
	fi
}

secret "7381 incident shape: :- expansion in echo" BLOCK \
	'echo "token: ${GH_TOKEN:+set}${GH_TOKEN:-EMPTY}"'
# fleet-ops#7463: the shape pi-issue-fleet-ops-7438 actually ran on 2026-09-17
# — same :- leak, lowercase branch, a trailing sed pipe, and the prescribed
# `[ -n "$GH_TOKEN" ]` check in the SAME call. The allowed check must not
# rescue the print: the call blocks.
secret "7463 incident shape: :- expansion with sed tail + allowed -n in one call" BLOCK \
	'echo "token: ${GH_TOKEN:+set}${GH_TOKEN:-empty}" | sed '"'"'s/.*/&/'"'"' ; [ -n "$GH_TOKEN" ] && echo "TOKEN OK" || echo "TOKEN EMPTY"'
secret "bare echo of the var" BLOCK 'echo "$GH_TOKEN"'
secret "printf of a key var" BLOCK 'printf '"'"'%s'"'"' "$LITELLM_MASTER_KEY"'
secret "printenv names the var without a dollar" BLOCK 'printenv GH_TOKEN'
secret "bare env dump into a pipe" BLOCK 'env | grep -i token'
secret "env -u VAR with no command still dumps the rest" BLOCK 'env -u GH_TOKEN'
secret "env assignments only is an env print" BLOCK 'env FOO=bar -0'
secret "declare -p prints the value" BLOCK 'declare -p GH_TOKEN'
secret "export -p dumps all exports" BLOCK 'export -p'
secret "set -x with a secret expansion in the same call" BLOCK \
	'set -x; gh api /rate_limit -H "Authorization: Bearer $GH_TOKEN"'
secret "unquoted heredoc embeds the token in a PR body" BLOCK \
	$'gh pr create --body "$(cat <<EOF\nleak: $GH_TOKEN\nEOF\n)"'
secret "subshell echo inside an argument" BLOCK 'x="$(echo "v=$GH_TOKEN")"; printf "%s" "$x"'

secret "prescribed presence check (the fix)" ALLOW 'test -n "$GH_TOKEN" || { echo "GH_TOKEN empty — stop"; exit 1; }'
secret "prose mention: commit message quoting the idiom" ALLOW \
	'git commit -m "fix: ban the echo + $GH_TOKEN output idiom (fleet-ops#7381)"'
secret "single-quoted literal is data, not an expansion" ALLOW \
	"echo 'literal \$GH_TOKEN text'"
secret "send-not-print: curl auth header" ALLOW \
	'curl -s -H "Authorization: Bearer $GH_TOKEN" https://api.github.com/rate_limit'
secret "env as a prefix runner is not a dump" ALLOW \
	'env -u GH_TOKEN sh -c "test -n \"\$GH_TOKEN\""'
secret "unit ExecStart mint shape" ALLOW \
	'GH_TOKEN=$(gh token generate --token-only); [ -n "$GH_TOKEN" ] || { echo "app token mint failed" >&2; exit 1; }; export GH_TOKEN'
secret "quoted heredoc keeps the idiom as text" ALLOW \
	$'cat <<'"'"'EOF'"'"'\nnever expand "token: ${GH_TOKEN:+set}${GH_TOKEN:-EMPTY}"\nEOF'
secret "comment carrying the var name" ALLOW 'echo done # token var is GH_TOKEN'
secret "set -x without a secret in the call" ALLOW 'set -x; npm test'

# --- fleet-ops#7448: auth-status / auth-token class --------------------------
# The second leak in the same 2026-09-17 pi-issue-fleet-ops-7440 run: the
# auth-status subcommand's env-var account line carries the token value, and
# the auth-token subcommand prints it outright (verified live 2026-09-21).
# The #7381 rule above covers the `${GH_TOKEN:-...}` half of that issue.
secret "7440 second leak: auth-status piped through head" BLOCK \
	'gh auth status 2>&1 | head -10'
secret "auth-status with a global flag before the subcommand" BLOCK \
	'gh --nopager auth status'
secret "auth-token prints the credential outright" BLOCK 'gh auth token'
secret "auth-token inside a command substitution" BLOCK \
	't=$(gh auth token); test -n "$t"'
secret "relative-path gh binary is the same command" BLOCK 'bin/gh auth status'
secret "auth-status behind a runner prefix" BLOCK 'timeout 5 gh auth status'
secret "prose: the ban named in a commit message" ALLOW \
	'git commit -m "fix: forbid the auth-status output (fleet-ops#7448)"'
secret "auth logout prints no credential" ALLOW 'gh auth logout'
secret "auth login --with-token reads the credential instead" ALLOW \
	'gh auth login --with-token < /tmp/t'
echo "PASS: permission-gate worker toolchain ban + secret_print"
