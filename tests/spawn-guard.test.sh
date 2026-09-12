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
bash "$here/fleet-spawn-guard-fs-sweep.test.sh"
# fleet-ops#5589: `systemctl restart|stop` on a .slice is blocked
# flags-tolerantly (the pre-#5589 rule missed `systemctl --user restart`
# and all of `stop`), with a dated drasl-et-al allowlist; the fleet-unit
# rule gets the same flags-gap fix.
bash "$here/fleet-spawn-guard-slice-lifecycle.test.sh"
# fleet-ops#3111 (part 5): the no-local-bin-clobber lint proves no test
# writes into the real ~/.local/bin / ~/.local/lib/node_modules / ~/.pi
# (the 2026-09-03 clobber shape). Hosted here with the other spawn-guard
# drills so P14 runs it without a workflow-file edit.
bash "$here/tests-no-local-bin-clobber.test.sh"

# fleet-ops#3126 revert (2026-09-07): no provider shim may gate on prompt text.
# PR #4356 added a pre-exec prompt scan (assertPromptSafe) to the devin and
# cursor shims and took both seats down. Pi embeds AGENTS.md verbatim into the
# system prompt (dist/core/system-prompt.js -> <project_instructions>), and the
# fleet's own standing rules quote the forbidden commands, so every run tripped
# git_stash_forbidden before the vendor binary was ever spawned.
# Proven live 2026-09-07T17:35Z: pi --print --provider devin --model glm-5-2
# with the benign packet "Reply with the single word OK." exited 1 with
# SPAWN_BLOCKED and no vendor spawn.
# A prompt is prose, not a command stream: standing rules and issue bodies
# quote the blocked shapes, and the vendor agent's own mid-session tool calls
# never pass through the shim at all — so the scan bought the outage and did
# not close the bypass.
repo_root="$(cd "$here/.." && pwd)"
for shim in devin-provider cursor-provider; do
  shim_file="$repo_root/template/extensions/$shim/index.ts"
  [[ -f "$shim_file" ]] || { echo "FAIL: missing provider shim: $shim_file" >&2; exit 1; }
  if grep -q 'assertPromptSafe\|provider-spawn-guard' "$shim_file"; then
    echo "FAIL: $shim gates on prompt text — the fleet-ops#3126 outage shape" >&2
    exit 1
  fi
done
if [[ -e "$repo_root/template/extensions/provider-spawn-guard.ts" ]]; then
  echo "FAIL: provider-spawn-guard.ts is back — prompt-scanning bricks the devin + cursor seats" >&2
  exit 1
fi
echo "OK: no provider shim gates on prompt text (fleet-ops#3126 revert pinned)"
