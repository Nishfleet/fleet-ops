#!/usr/bin/env bash
# tests/spawn-guard-wrangler-precision.test.sh
#
# fleet-ops#5700 closure test (the #5418 #1466 pattern: in-repo test driving
# the real extension code). The wrangler_deploy_0509 guard in
# template/extensions/spawn-guard-core.ts (the source the live install is
# deployed from — see config/pi-extensions-allowlist.json, id
# "spawn-guard-core") tested its regex against the FULL command text, so a
# read-only command that merely MENTIONED a deploy phrase inside a quoted
# string or a heredoc body was blocked: `grep -rn "…wrangler deploy"`,
# `rg -n "wrangler deploy"`, `cat > /tmp/pr-body.md <<'EOF' …` with a PR body
# quoting the gate — 98 logged blocks, majority false positives, and the
# scout that FILED #5700 was SPAWN_BLOCKED three times while filing it. The
# same raw match also refused `npx wrangler deploy --dry-run --outdir …`,
# the one legitimate local pre-push verification for a wrangler change.
#
# This test imports the real TypeScript module (node --experimental-strip-
# types — the guard fix is STRUCTURAL, not a single regex, so source-regex
# extraction like fleet-spawn-guard-stash-readonly.test.sh cannot pin it)
# and drives the exported wranglerDeployExecutableEntry + the live
# evaluateBashToolCall path. Pinned BOTH ways per the issue's accept list:
#
# ALLOW (new precision):
#   - deploy tokens only inside quoted strings / heredoc bodies:
#     grep/rg patterns, cat-heredoc PR bodies (the logged 2026-09-11
#     17:45 / 18:55 / 22:17 shapes).
#   - `wrangler deploy|versions upload ... --dry-run` with no non-dry-run
#     deploy entry point elsewhere in the command (the logged
#     2026-09-12T01:20:13Z shape).
# BLOCK (teeth kept):
#   - all four entry points in executable position: wrangler deploy,
#     wrangler versions upload, npm run deploy,
#     node scripts/deploy-production.mjs.
#   - dry-run mixed with a real deploy entry point in a separator sibling
#     (`wrangler deploy --dry-run && npm run deploy` is a deploy).
#   - the `sh|bash -c 'wrangler deploy'` quote-wrapper bypass.
#   - unchanged 0509 scoping and FLEET_BREAKGLASS_DEPLOY_0509=1 breakglass,
#     pinned END-TO-END through evaluateBashToolCall.
#
# CI safety: the 0509 scope is exercised against the fake cwd
# /tmp/fleet-test-fake-0509, never a real 0509 worktree; nothing deploys;
# the only evaluateBashToolCall case that actually writes the append-only
# spawn-block log is the real-deploy-block one, so the evidence log gains
# at most one clearly-marked /tmp line.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

ext="${FLEET_SPAWN_GUARD_CORE:-$here/../template/extensions/spawn-guard-core.ts}"
[[ -r "$ext" ]] || fail "spawn-guard-core.ts unreadable: $ext"

NODE_BIN="${FLEET_SPAWN_GUARD_NODE:-node}"
if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
	fail "node missing ($NODE_BIN)"
fi
node_major=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[0], 10))')
node_minor=$("$NODE_BIN" -e 'console.log(Number.parseInt(process.versions.node.split(".")[1], 10))')
if [[ "$node_major" -lt 22 ]] || { [[ "$node_major" -eq 22 ]] && [[ "$node_minor" -lt 6 ]]; }; then
	fail "node $node_major.$node_minor too old; need >= 22.6 for --experimental-strip-types"
fi

mkdir -p /tmp/fleet-test-fake-0509

# $1 = invariant name; $2 = expected ALLOW|BLOCK; $3 = command
expect() {
	local name="$1" want="$2" cmd="$3" out
	out=$(FLEET_TEST_CMD="$cmd" "$NODE_BIN" --experimental-strip-types --no-warnings=ExperimentalWarning \
		--input-type=module -e "
import { wranglerDeployExecutableEntry } from ${ext@Q};
const cmd = process.env.FLEET_TEST_CMD;
const entry = wranglerDeployExecutableEntry(cmd);
console.log(entry ? 'BLOCK:' + entry : 'ALLOW');
" 2>&1) || { echo "FAIL: node run failed for [$name]"; echo "$out" >&2; exit 1; }
	if [[ "$want" == "ALLOW" ]]; then
		[[ "$out" == "ALLOW" ]] || fail "[$name] expected ALLOW (quoted mention/dry-run), got: $out"
		ok "ALLOW: $name"
	else
		[[ "$out" == BLOCK:* ]] || fail "[$name] expected BLOCK, got: $out"
		ok "BLOCK: $name"
	fi
}

### ALLOW: the logged false-positive classes + dry-run precision ###
expect "grep mentioning deploy phrase in quoted pattern (2026-09-11T17:45:33Z shape)" ALLOW \
	'grep -rn -iE "netcup|runner.*unit|systemd.*wrangler deploy" /tmp/x'
expect "rg grepping FOR wrangler references (2026-09-11T22:17:52Z shape)" ALLOW \
	"rg -n 'assets.upload|wrangler deploy|npm run deploy' template/extensions/"
expect "cat heredoc PR body mentioning deploy phrases (2026-09-11T18:55:14Z shape)" ALLOW \
	$'cat > /tmp/pr-body-x.md <<\'EOF\'\nEvidence: `npx wrangler deploy --outdir x` was blocked, `npm run deploy` remains blocked.\nBlah npm run deploy and `node scripts/deploy-production.mjs` names.\nEOF\necho written'
expect "dry-run deploy invocation (2026-09-12T01:20:13Z shape)" ALLOW \
	"npx wrangler deploy --dry-run --outdir /tmp/wr-dry-2985"
expect "bare wrangler deploy --dry-run" ALLOW \
	"wrangler deploy --dry-run"
expect "versions upload --dry-run" ALLOW \
	"wrangler versions upload --dry-run --outdir /tmp/x"
expect "dry-run after cd" ALLOW \
	"cd /tmp/fleet-test-fake-0509 && npx wrangler deploy --dry-run"
expect "dry-run with outdir flag and extra flags" ALLOW \
	"wrangler deploy --dry-run --outdir /tmp/x 2>&1"

### BLOCK: four entry points executable position + mix / bypass shapes ###
expect "wrangler deploy executable position" BLOCK \
	"wrangler deploy"
expect "npx wrangler deploy WITHOUT --dry-run" BLOCK \
	"npx wrangler deploy --outdir /tmp/wr-2985"
expect "wrangler versions upload (real)" BLOCK \
	"wrangler versions upload --commitish main"
expect "npm run deploy entry point" BLOCK \
	"npm run deploy"
expect "npm run deploy with extra args" BLOCK \
	"npm run deploy -- --dry-run"
expect "node scripts/deploy-production.mjs entry point" BLOCK \
	"node scripts/deploy-production.mjs"
expect "dry-run next to a real deploy entry point (separator sibling)" BLOCK \
	"wrangler deploy --dry-run && npm run deploy"
expect "cd into 0509 then real deploy" BLOCK \
	"cd /home/nish/workspaces/products/0509 && wrangler deploy"
expect "sh -c quote-wrapper bypass stays blocked (quoted but EXECUTED)" BLOCK \
	"sh -c 'wrangler deploy'"
expect "bash -c bypass blocked" BLOCK \
	"bash -c 'wrangler deploy'"

### Unchanged scoping + breakglass pinned end-to-end (LIVE path) ###
node_e2e=$("$NODE_BIN" --experimental-strip-types --no-warnings=ExperimentalWarning \
	--input-type=module -e "
import { evaluateBashToolCall } from ${ext@Q};
// 1. Unchanged 0509 scoping: cwd without /0509/ and command without any
//    0509 mention is NOT blocked (a future edit that silently widens the
//    scope to every fleet dir fails loud here).
const out = evaluateBashToolCall({command: 'wrangler deploy --outdir /tmp/x', cwd: '/tmp', env: {}});
console.log('SCOPE_OUTSIDE=' + (out ? 'BLOCK' : 'ALLOW'));
// 2. Breakglass honored end-to-end.
const bg = evaluateBashToolCall({command: 'wrangler deploy', cwd: '/tmp/fleet-test-fake-0509', env: {FLEET_BREAKGLASS_DEPLOY_0509: '1'}});
console.log('BREAKGLASS=' + (bg ? 'BLOCK' : 'ALLOW'));
// 3. Live verdicts in a 0509-scoped cwd: dry-run allowed, real deploy blocked.
const dry = evaluateBashToolCall({command: 'npx wrangler deploy --dry-run --outdir /tmp/x', cwd: '/tmp/fleet-test-fake-0509', env: {}});
const real = evaluateBashToolCall({command: 'wrangler deploy', cwd: '/tmp/fleet-test-fake-0509', env: {}});
console.log('DRYRUN_LIVE=' + (dry ? 'BLOCK:' + dry.reason : 'ALLOW'));
console.log('REALDEPLOY_LIVE=' + (real ? 'BLOCK:' + real.reason : 'ALLOW'));
" 2>&1) || { echo "FAIL: node e2e run failed"; echo "$node_e2e" >&2; exit 1; }
grep -q '^SCOPE_OUTSIDE=ALLOW' <<<"$node_e2e" || fail "outside-0509 scope should stay ALLOW (unchanged scoping): $node_e2e"
grep -q '^BREAKGLASS=ALLOW' <<<"$node_e2e" || fail "breakglass env should allow: $node_e2e"
grep -q '^DRYRUN_LIVE=ALLOW' <<<"$node_e2e" || fail "dry-run live verdict should be ALLOW: $node_e2e"
grep -q '^REALDEPLOY_LIVE=BLOCK' <<<"$node_e2e" || fail "wrangler deploy live verdict should be BLOCK: $node_e2e"
ok "scoping/breakglass/dry-run pinned end-to-end via evaluateBashToolCall"
echo "$node_e2e"

echo "ALL OK: wrangler_deploy_0509 precision (fleet-ops#5700)"
