#!/usr/bin/env bash
# tests/fleet-spawn-guard-stash-readonly.test.sh
#
# Pins fleet-ops#754: the live spawn-guard git_stash_forbidden rule must
# let read-only `git stash list` / `git stash show` through and still
# block every mutating form (bare `git stash`, pop, apply, push, drop,
# clear, branch, create, store).
#
# The spawn guard lives OUTSIDE this repo at
# ~/.pi/agent/extensions/spawn-guard-core.ts — a proven global Pi
# extension (see config/pi-extensions-allowlist.json, id
# "spawn-guard-core"). The standing rule it enforces is "never pop
# another agent's stash"; listing or showing a stash does not touch it.
# Before #754 the pattern was /\bgit\s+stash\b/i, which also refused
# `git stash list` / `git stash show` and produced a false
# swallowed-failure ticket (the live #648 class).
#
# This test is the class-prevention mechanism: it reads the live source,
# extracts the git_stash_forbidden regex, and evaluates it against the
# allow/block matrix below. A regression that re-broadens the regex to
# block `git stash list` fails loud here.
#
# Hosted CI (no ~/.pi/agent/extensions) skips the live join, mirroring
# scenario 9 of fleet-pi-extensions-canary.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

ext="${FLEET_SPAWN_GUARD_CORE:-$HOME/.pi/agent/extensions/spawn-guard-core.ts}"

if [[ ! -f "$ext" ]]; then
	ok "live spawn-guard-core.ts absent (hosted CI) — skip"
	exit 0
fi

[[ -r "$ext" ]] || fail "spawn-guard-core.ts present but unreadable: $ext"

read -r -d '' SCRIPT <<'NODE' || true
const fs = require('fs');
const path = process.env.SPAWN_GUARD_CORE;
const src = String(fs.readFileSync(path, 'utf8'));
// Locate: { id: "git_stash_forbidden", pattern: /<body>/<flags> }
const m = src.match(/id:\s*"git_stash_forbidden"[^/]*\/(.+?)\/([a-z]+)\s*\}/);
if (!m) {
	console.error('could not find git_stash_forbidden pattern in ' + path);
	process.exit(2);
}
const re = new RegExp(m[1], m[2]);
const allow = [
	'git stash list',
	'git stash show',
	'git stash show -p stash@{0}',
	'git stash show stash@{1}',
	'git stash list --format=%gs',
];
const block = [
	'git stash',
	'git stash pop',
	'git stash apply',
	'git stash push',
	'git stash push -m "x"',
	'git stash drop',
	'git stash clear',
	'git stash branch foo',
	'git stash create',
	'git stash store',
	'git stash; echo done',
	'git stash && echo done',
];
const failures = [];
for (const c of allow) if (re.test(c)) failures.push('allowed-but-blocked: ' + JSON.stringify(c));
for (const c of block) if (!re.test(c)) failures.push('blocked-but-allowed: ' + JSON.stringify(c));
if (failures.length) {
	console.error(failures.join('\n'));
	process.exit(1);
}
console.log('stash list/show allowed; stash/pop/apply/push/drop/clear/branch/create/store blocked');
NODE

out=$(SPAWN_GUARD_CORE="$ext" node -e "$SCRIPT" 2>&1) || fail "$out"
ok "$out"
