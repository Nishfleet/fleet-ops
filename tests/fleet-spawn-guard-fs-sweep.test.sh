#!/usr/bin/env bash
# fleet-ops#4896: the spawn guard blocks home-wide filesystem sweeps
# (`find /home/nish`, `grep -r ... /home/nish/workspaces`, `rg x /`) and keeps
# searches rooted inside a repo checkout or a state dir allowed.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ext="${FLEET_SPAWN_GUARD_CORE:-$here/../template/extensions/spawn-guard-core.ts}"
[[ -r "$ext" ]] || fail "spawn-guard-core.ts unreadable: $ext"
read -r -d '' SCRIPT <<'NODE' || true
const fs = require('fs');
const src = String(fs.readFileSync(process.env.SPAWN_GUARD_CORE, 'utf8'));
const m = src.match(/id:\s*"home_wide_filesystem_sweep"[\s\S]*?pattern:\s*\/(.+)\/([a-z]*),/);
if (!m) { console.error('home_wide_filesystem_sweep rule missing'); process.exit(2); }
const re = new RegExp(m[1], m[2]);
const block = [
  "find /home/nish -name '*.prom' -o -name '*detached*'",
  'find /home/nish/workspaces -name fleet-who-stopped',
  'grep -rln fleet_blocked_issue_age_seconds /home/nish/workspaces /home/nish/bin /home/nish/.local/bin',
  'grep -R foo /home/nish/.local',
  'rg fleet_blocked /home/nish',
  'find / -name pi',
  'find ~ -name x',
  'cd /tmp && find /home/nish/workspaces/ -type d',
  'sudo find / -name "*.service"',
];
const allow = [
  'find . -name x',
  'grep -rn foo lib/',
  'rg -n "alert: DetachedJobDied" config/fleet_rules.yml',
  'find /home/nish/workspaces/tooling/fleet-ops -name x',
  'rg foo /home/nish/workspaces/tooling/fleet-ops/bin',
  'find /home/nish/.local/state/pi-packet -name "*.md"',
  'ls /home/nish/workspaces',
  'grep -n foo /home/nish/workspaces/agent-state/NISH-ESCALATIONS.md',
  'cat /home/nish/.local/state/pi-packet/actions.log',
];
let bad = 0;
for (const c of block) if (!re.test(c)) { console.error('NOT BLOCKED: ' + c); bad++; }
for (const c of allow) if (re.test(c)) { console.error('WRONGLY BLOCKED: ' + c); bad++; }
process.exit(bad ? 1 : 0);
NODE
SPAWN_GUARD_CORE="$ext" node -e "$SCRIPT" || fail "home_wide_filesystem_sweep rule verdicts wrong"
ok "spawn guard blocks home-wide find/grep -r/rg sweeps and allows checkout-rooted searches (fleet-ops#4896)"
