#!/usr/bin/env bash
# tests/fleet-spawn-guard-sudo-write.test.sh
#
# fleet-ops#3111: the live spawn-guard must block any `sudo` whose argv writes
# into the pi transport paths (~/.local/bin, ~/.local/lib/node_modules, ~/.pi,
# /etc/systemd) and any /dev/null source into /home/nish. The 2026-09-03
# incident was a worker running
#   sudo install -D -m 0755 /dev/null /home/nish/.local/bin/pi
# while stubbing binaries for a test — it replaced the pi symlink with a 0-byte
# root-owned regular file and starved the fleet for 33h. sudoers is
# `nish ALL NOPASSWD: all`, so any worker can write root anywhere; this rule
# blocks the dangerous shape at the spawn boundary.
#
# The spawn guard lives OUTSIDE this repo at
# ~/.pi/agent/extensions/spawn-guard-core.ts (see config/pi-extensions-
# allowlist.json, id "spawn-guard-core"). This test reads the live source,
# extracts the sudo_write_protected_path and sudo_devnull_into_home regexes,
# and evaluates them against the allow/block matrix below — the same pattern
# as fleet-spawn-guard-stash-readonly.test.sh (fleet-ops#754). A regression
# that drops either rule fails loud here.
#
# Hosted CI (no ~/.pi/agent/extensions) skips the live join, mirroring
# fleet-spawn-guard-stash-readonly.test.sh scenario 9.

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
function grab(id) {
  // The rule may be one-line (`{ id: "x", pattern: /body/i }`) or multi-line
  // (`{ id: "x",\n  pattern:\n    /body/i,`). The body can contain escaped
  // `\/` sequences, so capture greedily up to the LAST `/flags` on the regex
  // line. [\s\S]*? crosses the newlines between id and pattern.
  const m = src.match(new RegExp('id:\\s*"' + id + '"[\\s\\S]*?\\/(.+)\\/([a-z]+)\\s*,'));
  if (!m) { console.error('could not find ' + id + ' pattern in ' + path); process.exit(2); }
  return new RegExp(m[1], m[2]);
}
const prot = grab('sudo_write_protected_path');
const devnull = grab('sudo_devnull_into_home');

// Must BLOCK — the clobber shape and its siblings.
const block_prot = [
  'sudo install -D -m 0755 /dev/null /home/nish/.local/bin/pi',
  'sudo install -D -m 0755 ./build/pi /home/nish/.local/bin/pi',
  'sudo cp /tmp/x /home/nish/.local/bin/pi',
  'sudo mv /tmp/x /home/nish/.local/bin/pi',
  'sudo ln -sf /tmp/x /home/nish/.local/bin/pi',
  'sudo tee /home/nish/.local/bin/pi',
  'sudo bash -c "echo > /home/nish/.local/bin/pi"',
  'sudo install -D -m 0644 x /home/nish/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js',
  'sudo cp x /home/nish/.pi/agent/extensions/spawn-guard-core.ts',
  'sudo install -D -m 0644 drop.conf /etc/systemd/user/pi-transport-check.service.d/20.conf',
  'sudo install -D -m 0644 drop.conf /etc/systemd/system/foo.service',
  'sudo dd if=/dev/zero of=/home/nish/.local/bin/pi',
];
const block_devnull = [
  'sudo install -D -m 0755 /dev/null /home/nish/.local/bin/pi',
  'sudo cp /dev/null /home/nish/somefile',
  'sudo install -m 0755 /dev/null /home/nish/.local/bin/foo',
];
// Must ALLOW — non-sudo writes (the guard is sudo-scoped), and sudo into /tmp.
const allow = [
  'install -D -m 0755 /dev/null /home/nish/.local/bin/pi',   // no sudo — not this guard
  'sudo install -D -m 0755 /dev/null /tmp/pi-stub/pi',        // /tmp, not $HOME
  'sudo cp /tmp/x /tmp/pi-stub/pi',
  'sudo apt-get install -y foo',
  'sudo systemctl daemon-reload',
  'echo hi > /home/nish/.local/bin/pi',                       // no sudo
];

const failures = [];
for (const c of block_prot) if (!prot.test(c)) failures.push('prot blocked-but-allowed: ' + JSON.stringify(c));
for (const c of block_devnull) if (!devnull.test(c)) failures.push('devnull blocked-but-allowed: ' + JSON.stringify(c));
for (const c of allow) {
  if (prot.test(c)) failures.push('prot allowed-but-blocked: ' + JSON.stringify(c));
  if (devnull.test(c)) failures.push('devnull allowed-but-blocked: ' + JSON.stringify(c));
}
if (failures.length) { console.error(failures.join('\n')); process.exit(1); }
console.log('sudo writes into ~/.local/bin, ~/.local/lib/node_modules, ~/.pi, /etc/systemd blocked; /dev/null into /home/nish blocked; non-sudo + /tmp allowed');
NODE

out=$(SPAWN_GUARD_CORE="$ext" node -e "$SCRIPT" 2>&1) || fail "$out"
ok "$out"
