#!/usr/bin/env bash
# tests/fleet-spawn-guard-slice-lifecycle.test.sh
#
# fleet-ops#5589 (rulebook redteam 2026-09-11): the AGENTS.md hard line
# "Never `systemctl restart` a slice — it bounces every unit inside it" had
# no mechanical guard that actually fired. The pre-#5589 rule
# (systemctl_restart_slice) required `restart` to sit directly after
# `systemctl`, so `systemctl --user restart user-1000.slice` — the exact
# shape the finding names; user-1000.slice carries ~54 live timers/units —
# slipped through, and `stop` was not covered at all.
#
# This test pins the replacement systemctl_slice_lifecycle rule:
#   - flags-tolerant (`systemctl --user|--system|-M ... restart|stop`),
#   - covers BOTH restart and stop,
#   - honors the dated allowlist escape (drasl et al, see the rule comment
#     in template/extensions/spawn-guard-core.ts),
#   - blocks conservatively on mixed targets (one non-allowlisted slice
#     anywhere in the argument span blocks the whole command),
# and the same flags-gap fix on systemctl_restart_fleet_unit, whose verb
# set now covers stop on fleet units too (fleet-ops#5605).
#
# Reads the REPO template (the source the MANIFEST deploys from), not the
# live install, so hosted CI covers the rules the same way
# fleet-spawn-guard-fs-sweep.test.sh does. A regression that re-narrows the
# pattern to `systemctl\s+restart` or drops the allowlist fails loud here.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ext="${FLEET_SPAWN_GUARD_CORE:-$here/../template/extensions/spawn-guard-core.ts}"
[[ -r "$ext" ]] || fail "spawn-guard-core.ts unreadable: $ext"

read -r -d '' SCRIPT <<'NODE' || true
const fs = require('fs');
const src = String(fs.readFileSync(process.env.SPAWN_GUARD_CORE, 'utf8'));
function grab(id) {
  // The rule may be one-line or multi-line; the body can contain escaped
  // `\/` sequences, so capture greedily up to the LAST `/flags` on the
  // regex line — same extraction as fleet-spawn-guard-sudo-write.test.sh.
  const m = src.match(new RegExp('id:\\s*"' + id + '"[\\s\\S]*?\\/(.+)\\/([a-z]+)\\s*,'));
  if (!m) { console.error('could not find ' + id + ' pattern in ' + process.env.SPAWN_GUARD_CORE); process.exit(2); }
  return new RegExp(m[1], m[2]);
}
const slice = grab('systemctl_slice_lifecycle');
const fleet = grab('systemctl_restart_fleet_unit');

// Must BLOCK — the bounce shape in every flag/verb/target arrangement.
const block_slice = [
  'systemctl restart user-1000.slice',
  'systemctl --user restart user-1000.slice',
  'systemctl --user stop user-1000.slice',
  'systemctl stop fleet-work.slice',
  'sudo systemctl restart user-1000.slice',
  'systemctl restart app-litellm.slice',
  'systemctl --user restart app-fleet-gap-closure-auditor.slice',
  'systemctl --user restart --no-block user-1000.slice',
  'systemctl restart user-1000.slice && echo ok',
  'systemctl restart foo.slice drasl.slice',
  'systemctl restart drasl.slice user-1000.slice',
];
// Must ALLOW — the dated allowlist escape (drasl et al), non-slice units,
// and read-only forms.
const allow_slice = [
  'systemctl restart drasl.slice',
  'systemctl stop drasl.slice',
  'systemctl --user restart drasl.slice',
  'systemctl restart nginx.service',
  'systemctl status user-1000.slice',
  'systemctl cat user-1000.slice',
  'systemctl --user list-timers --all',
  'journalctl -u user-1000.slice',
];
// systemctl_restart_fleet_unit: same flags-gap fix, restart verb unchanged.
const block_fleet = [
  'systemctl restart fleet-heartbeat.service',
  'systemctl --user restart fleet-heartbeat.service',
  'systemctl restart implementation-worker-pi.service',
  // fleet-ops#5605: stop of fleet units is covered too.
  'systemctl --user stop fleet-heartbeat.service',
  'systemctl stop implementation-worker-pi.service',
];
const allow_fleet = [
  'systemctl restart nginx.service',
  'systemctl --user status fleet-heartbeat.service',
  'systemctl --user stop nginx.service',
];

let bad = 0;
for (const c of block_slice) if (!slice.test(c)) { console.error('NOT BLOCKED by systemctl_slice_lifecycle: ' + JSON.stringify(c)); bad++; }
for (const c of allow_slice) if (slice.test(c)) { console.error('WRONGLY BLOCKED by systemctl_slice_lifecycle: ' + JSON.stringify(c)); bad++; }
for (const c of block_fleet) if (!fleet.test(c)) { console.error('NOT BLOCKED by systemctl_restart_fleet_unit: ' + JSON.stringify(c)); bad++; }
for (const c of allow_fleet) if (fleet.test(c)) { console.error('WRONGLY BLOCKED by systemctl_restart_fleet_unit: ' + JSON.stringify(c)); bad++; }
if (bad) process.exit(1);
console.log('slice restart/stop blocked flags-tolerantly (drasl et al allowlist honored, mixed targets conservative); fleet-unit rule flags-tolerant, restart+stop');
NODE
out=$(SPAWN_GUARD_CORE="$ext" node -e "$SCRIPT" 2>&1) || fail "$out"
ok "$out"
