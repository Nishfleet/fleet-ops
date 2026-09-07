#!/usr/bin/env bash
# tests/fleet-spawn-guard-provider-shim.test.sh
#
# fleet-ops#3126 (P10-bypass closure): the devin and cursor providers are CLI
# shims that shell out to a vendor binary (`devin`, `cursor-agent`) with
# `--permission-mode dangerous`. That binary runs its OWN agent with its OWN
# tools, so Pi never sees a bash call from inside the vendor session and the
# Pi-side guards (bash-spawn-hook.ts -> spawn-guard-core.ts, protected-paths,
# permission-gate) are all blind on those seats. Proven 2026-08-25:
# `git stash push` RAN on the devin seat with no SPAWN_BLOCKED line.
#
# The closure (orchestrator decision 2026-09-07): the provider shims refuse
# dangerous operations in the prompt BEFORE execing the vendor binary, via the
# shared template/extensions/provider-spawn-guard.ts module. This test pins:
#   1. The shared module's dangerous-rule matrix (git stash, rm -rf under
#      $HOME/workspaces, credential-path writes, systemctl restarts, the 0509
#      wrangler-deploy block) — allow/block matrix, same pattern as
#      fleet-spawn-guard-stash-readonly.test.sh (fleet-ops#754).
#   2. Both provider shims import assertPromptSafe and call it before the
#      vendor spawnSync, so the guard is actually wired into the live path.
#
# Runs offline in CI (no live box, no GitHub App needed). Reads the repo copy
# of the module, not the live install, so a regression in the repo fails here
# before it ever reaches the VPS.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
module="$repo_root/template/extensions/provider-spawn-guard.ts"
devin="$repo_root/template/extensions/devin-provider/index.ts"
cursor="$repo_root/template/extensions/cursor-provider/index.ts"

ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$module" ]] || fail "missing shared guard module: $module"
[[ -f "$devin" ]]  || fail "missing devin shim: $devin"
[[ -f "$cursor" ]] || fail "missing cursor shim: $cursor"

# --- 1. dangerous-rule matrix ----------------------------------------------
read -r -d '' SCRIPT <<'NODE' || true
const fs = require('fs');
const path = process.env.PROVIDER_GUARD;
const src = String(fs.readFileSync(path, 'utf8'));
// Isolate the rules array so greedy regexes cannot bleed into the guidance
// map or later rules.
const arrStart = src.indexOf('const PROVIDER_DANGEROUS_RULES');
const arrEnd = src.indexOf('];', arrStart);
if (arrStart < 0 || arrEnd < 0) {
  console.error('could not find PROVIDER_DANGEROUS_RULES array in ' + path);
  process.exit(2);
}
const block = src.slice(arrStart, arrEnd + 2);
// Each entry: { id: "...", pattern: /<body>/<flags> } — body may contain
// escaped \/ sequences, so match non-slash/non-backslash runs plus escaped
// chars, then the closing /flags followed by , or }.
const entryRe = /id:\s*"([^"]+)"\s*,\s*pattern:\s*\/((?:[^\/\\]|\\.)*)\/([a-z]*)\s*[},]/g;
const rules = {};
let mm;
while ((mm = entryRe.exec(block))) {
  rules[mm[1]] = new RegExp(mm[2], mm[3]);
}
const required = [
  'git_stash_forbidden',
  'systemctl_restart_slice',
  'systemctl_restart_fleet_unit',
  'credential_path_write',
  'rm_rf_home_or_workspaces',
  'wrangler_deploy_0509',
];
for (const id of required) {
  if (!rules[id]) { console.error('missing rule: ' + id); process.exit(2); }
}
// Must BLOCK.
const blockCases = [
  ['git_stash_forbidden', 'git stash push -m probe'],
  ['git_stash_forbidden', 'git stash'],
  ['rm_rf_home_or_workspaces', 'rm -rf /home/nish/workspaces/foo'],
  ['credential_path_write', 'echo x > /home/nish/fleet2/etc/devin.env'],
  ['credential_path_write', 'tee /home/nish/.env'],
  ['systemctl_restart_slice', 'systemctl restart fleet-work.slice'],
  ['systemctl_restart_fleet_unit', 'systemctl restart fleet-heartbeat.service'],
  ['wrangler_deploy_0509', 'wrangler deploy'],
  ['wrangler_deploy_0509', 'npm run deploy'],
];
// Must ALLOW.
const allowCases = [
  'git stash list',
  'git stash show',
  'rm -rf /tmp/scratch',
  'echo hello',
  'systemctl status fleet-work.slice',
  'git status',
];
const failures = [];
for (const [id, c] of blockCases) {
  if (!rules[id].test(c)) failures.push('blocked-but-allowed (' + id + '): ' + JSON.stringify(c));
}
for (const c of allowCases) {
  const hit = Object.keys(rules).find(id => rules[id].test(c));
  if (hit) failures.push('allowed-but-blocked by ' + hit + ': ' + JSON.stringify(c));
}
if (failures.length) { console.error(failures.join('\n')); process.exit(1); }
console.log('provider-shim guard blocks git stash, rm -rf, credential writes, systemctl restart, wrangler deploy; allows safe shapes');
NODE

out=$(PROVIDER_GUARD="$module" node -e "$SCRIPT" 2>&1) || fail "$out"
ok "$out"

# --- 2. both provider shims wire the guard before the vendor spawnSync ------
for shim in "$devin" "$cursor"; do
  provider_dir="$(dirname "$shim")"
  provider_name="$(basename "$provider_dir")"
  grep -q 'assertPromptSafe' "$shim" \
    || fail "$provider_name/index.ts does not import assertPromptSafe"
  grep -q 'assertPromptSafe(prompt)' "$shim" \
    || fail "$provider_name/index.ts does not call assertPromptSafe(prompt) before execing the vendor binary"
  ok "$provider_name/index.ts wires assertPromptSafe(prompt) before the vendor spawnSync"
done

echo "ALL OK: provider-shim spawn guard wired into devin + cursor, dangerous ops refused"