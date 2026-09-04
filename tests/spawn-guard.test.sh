#!/usr/bin/env bash
# tests/spawn-guard.test.sh
#
# Spawn guard regression suite. The live guard lives in
# ~/.pi/agent/extensions/spawn-guard-core.ts (see
# config/pi-extensions-allowlist.json, id "spawn-guard-core"). This suite
# runs the allow/block matrices for the dangerous shapes the guard must
# refuse, and proves safe shapes still pass.
#
# fleet-ops#754: git stash list/show allowed; pop/apply/push/drop/clear/
# branch/create/store blocked.
#
# fleet-ops#3244: any `sudo` whose argv writes into ~/.local/bin,
# ~/.local/lib/node_modules, ~/.pi, or /etc/systemd — via
# install/cp/tee/mv/ln/redirect/dd or a /dev/null source — is blocked.
# Non-sudo writes and /tmp targets are allowed.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$here/fleet-spawn-guard-stash-readonly.test.sh"
bash "$here/fleet-spawn-guard-sudo-write.test.sh"
# fleet-ops#3111: static lint pinning the test-side of the same class — no
# test file may install/cp/ln/mv/tee/redirect a file into the real
# ~/.local/bin / ~/.local/lib/node_modules / ~/.pi. The 2026-09-03 incident
# was a worker stubbing a binary via `sudo install ... /dev/null
# /home/nish/.local/bin/pi`, clobbering the pi symlink and starving the
# fleet for 33h. The live spawn-guard blocks the runtime shape; this lint
# blocks the test-source shape. Hosted here (not a new ci.yml line) so the
# worker token does not need workflow scope.
bash "$here/tests-no-local-bin-clobber.test.sh"
