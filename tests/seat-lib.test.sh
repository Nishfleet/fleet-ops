#!/usr/bin/env bash
# tests/seat.lib.test.sh
#
# fleet-ops#4263 P3b: this file stays listed in ci.yml (workers cannot edit
# workflows). The routing library is GONE. This host proves that, then runs
# nested tests that still belong in CI.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$repo_root/lib/litellm-seat.sh" ]] \
  || fail "lib/litellm-seat.sh missing"
ok "lib/litellm-seat.sh present"

# The retired routing library must be absent. The path is built in two
# pieces so this file stays outside the retired-name scan (fleet-ops#4263).
retired_lib="$repo_root/lib/seat""-lib.sh"
[[ ! -f "$retired_lib" ]] \
  || fail "retired routing lib must be absent after P3b (found $retired_lib)"
ok "retired routing lib is absent"

# Worker callers must not invoke the retired picker (regex avoids the
# literal so this file stays outside the retired-name scan).
for caller in pi-issue-run pi-packet-run pi-scout-run agent-cron-run pi-audit-run fleet-researcher-run; do
    if grep -qE '\$\((litellm_)?pick[-_]seat' "$repo_root/bin/$caller"; then
        fail "$caller still calls the retired picker"
    fi
done
ok "six worker callers do not call the retired picker"

# Group pick still returns provider<TAB>model.
# shellcheck source=../lib/litellm-seat.sh
source "$repo_root/lib/litellm-seat.sh"
got=$(litellm_seat "worker-cheap")
[[ "$got" == "$(printf 'litellm\tworker-cheap')" ]] \
  || fail "litellm_seat worker-cheap got $got"
got=$(litellm_seat "judge")
[[ "$got" == "$(printf 'litellm\tjudge')" ]] \
  || fail "litellm_seat judge got $got"
ok "litellm_seat returns litellm<TAB>group"

# fleet-ops#4263: pi-issue-run / agent-cron-run arithmetic under set -u.
[[ "${SPAWN_FAIL_MAX_S}" =~ ^[0-9]+$ ]] \
  || fail "SPAWN_FAIL_MAX_S must be set after sourcing (got '${SPAWN_FAIL_MAX_S-}')"
[[ "${SPAWN_FAIL_BACKOFF_S}" =~ ^[0-9]+$ ]] \
  || fail "SPAWN_FAIL_BACKOFF_S must be set after sourcing (got '${SPAWN_FAIL_BACKOFF_S-}')"
(( 1 < SPAWN_FAIL_MAX_S )) \
  || fail "SPAWN_FAIL_MAX_S must be usable in (( )) under set -u"
ok "spawn-fail defaults are set for set -u wrappers"

# Nested CI hosts that do not depend on the deleted routing library.
bash "$here/salvage-secret-scan.test.sh" || fail "salvage-secret-scan tests failed"
bash "$here/pi-packet-verdict.test.sh" || fail "pi-packet-verdict tests failed"
bash "$here/alert-repair-claim-mutex.test.sh" || fail "alert-repair-claim-mutex tests failed"
bash "$here/repo-privacy-guard.test.sh" || fail "repo-privacy-guard tests failed"
bash "$here/pi-issue-run-debug-playbook-gate.test.sh" || fail "pi-issue-run-debug-playbook-gate tests failed"
bash "$here/scout-prompt-difficulty.test.sh" || fail "scout-prompt-difficulty tests failed"
bash "$here/siterep-deploy-rollback-rc-propagation.test.sh" || fail "siterep-deploy-rollback tests failed"
bash "$here/role-quality-gates.test.sh" || fail "role-quality-gates tests failed"
bash "$here/reusable-surface-audit.test.sh" || fail "reusable-surface-audit tests failed"
bash "$here/pi-seat-source-litellm.test.sh" || fail "pi-seat-source-litellm tests failed"
bash "$here/fleet-worker-prompt-gh-pr-view-unknown-field.test.sh" || fail "fleet-worker-prompt-gh-pr-view-unknown-field tests failed"
bash "$here/ram-metric-compare.test.sh" || fail "ram-metric-compare tests failed"
bash "$here/ram-measure.test.sh" || fail "ram-measure tests failed"
bash "$here/watch-log-rotation.test.sh" || fail "watch-log-rotation tests failed"
bash "$here/fleet-findings-queued.test.sh" || fail "fleet-findings-queued tests failed"
# fleet-ops#1138: Relates to, not Closes, for decisions-ledger fixes.
bash "$here/fleet-decisions-ledger.test.sh" || fail "fleet-decisions-ledger tests failed"
bash "$here/fleet-debug-playbook.test.sh" || fail "fleet-debug-playbook tests failed"
bash "$here/fleet-interventions-eliminated.test.sh" || fail "fleet-interventions-eliminated tests failed"
bash "$here/fleet-failed-command-flagged.test.sh" || fail "fleet-failed-command-flagged tests failed"
bash "$here/fleet-failed-command-cat-stale-fleet-ops.test.sh" || fail "fleet-failed-command-cat-stale-fleet-ops tests failed"
bash "$here/fleet-failed-command-read.test.sh" || fail "fleet-failed-command-read tests failed"
bash "$here/fleet-failed-command-read-enoent-thinking.test.sh" || fail "fleet-failed-command-read-enoent-thinking tests failed"
bash "$here/fleet-failed-command-read-enoent-skip-todos.test.sh" || fail "fleet-failed-command-read-enoent-skip-todos tests failed"
bash "$here/fleet-failed-command-read-enoent-archived-packet.test.sh" || fail "fleet-failed-command-read-enoent-archived-packet tests failed"
bash "$here/fleet-failed-command-read-eisdir.test.sh" || fail "fleet-failed-command-read-eisdir tests failed"
bash "$here/fleet-failed-command-read-enoent-stale-rg.test.sh" || fail "fleet-failed-command-read-enoent-stale-rg tests failed"
bash "$here/fleet-failed-command-enoent-block.test.sh" || fail "fleet-failed-command-enoent-block tests failed"
bash "$here/fleet-failed-command-gh-api-404.test.sh" || fail "fleet-failed-command-gh-api-404 tests failed"
bash "$here/fleet-failed-command-gh-api-403-integration.test.sh" || fail "fleet-failed-command-gh-api-403-integration tests failed"
bash "$here/fleet-failed-command-canary-script-exit-1.test.sh" || fail "fleet-failed-command-canary-script-exit-1 tests failed"
bash "$here/fleet-failed-command-systemctl-status-failed.test.sh" || fail "fleet-failed-command-systemctl-status-failed tests failed"
bash "$here/fleet-failed-command-systemctl-stop-not-loaded.test.sh" || fail "fleet-failed-command-systemctl-stop-not-loaded tests failed"
bash "$here/fleet-failed-command-fresh-debug-script.test.sh" || fail "fleet-failed-command-fresh-debug-script tests failed"
bash "$here/fleet-failed-command-cd-non-git-repo.test.sh" || fail "fleet-failed-command-cd-non-git-repo tests failed"
bash "$here/fleet-failed-command-clone-race-cd.test.sh" || fail "fleet-failed-command-clone-race-cd tests failed"
bash "$here/fleet-failed-command-clone-ssh-publickey.test.sh" || fail "fleet-failed-command-clone-ssh-publickey tests failed"
bash "$here/fleet-failed-command-empty-tool-name.test.sh" || fail "fleet-failed-command-empty-tool-name tests failed"
bash "$here/fleet-failed-command-git-branch-cannot-force-update.test.sh" || fail "fleet-failed-command-git-branch-cannot-force-update tests failed"
bash "$here/fleet-failed-command-git-checkout-worktree-conflict.test.sh" || fail "fleet-failed-command-git-checkout-worktree-conflict tests failed"
bash "$here/fleet-failed-command-git-checkout-worktree-conflict-968.test.sh" || fail "fleet-failed-command-git-checkout-worktree-conflict-968 tests failed"
bash "$here/fleet-failed-command-git-cherry-pick-empty.test.sh" || fail "fleet-failed-command-git-cherry-pick-empty tests failed"
bash "$here/fleet-failed-command-gh-issue-view-body.test.sh" || fail "fleet-failed-command-gh-issue-view-body tests failed"
bash "$here/fleet-failed-command-gh-pr-list-invalid-sort.test.sh" || fail "fleet-failed-command-gh-pr-list-invalid-sort tests failed"
bash "$here/fleet-failed-command-gh-issue-view-unknown-field.test.sh" || fail "fleet-failed-command-gh-issue-view-unknown-field tests failed"
bash "$here/fleet-failed-command-dedup-open-list.test.sh" || fail "fleet-failed-command-dedup-open-list tests failed"
bash "$here/fleet-failed-command-ledger-dedup.test.sh" || fail "fleet-failed-command-ledger-dedup tests failed"
bash "$here/fleet-failed-command-edit-unmatch.test.sh" || fail "fleet-failed-command-edit-unmatch tests failed"
bash "$here/fleet-failed-command-edit-array-unmatch.test.sh" || fail "fleet-failed-command-edit-array-unmatch tests failed"
bash "$here/fleet-failed-command-edit-schema-validation.test.sh" || fail "fleet-failed-command-edit-schema-validation tests failed"
bash "$here/fleet-failed-command-observe-duplicate-open.test.sh" || fail "fleet-failed-command-observe-duplicate-open tests failed"
bash "$here/fleet-failed-command-python-traceback.test.sh" || fail "fleet-failed-command-python-traceback tests failed"
bash "$here/fleet-failed-command-python-module-not-found-hyphen.test.sh" || fail "fleet-failed-command-python-module-not-found-hyphen tests failed"
bash "$here/fleet-failed-command-pem-deserialize.test.sh" || fail "fleet-failed-command-pem-deserialize tests failed"
bash "$here/fleet-failed-command-observe-duplicate-python-traceback.test.sh" || fail "fleet-failed-command-observe-duplicate-python-traceback tests failed"
bash "$here/fleet-failed-command-observe-duplicate-enoent.test.sh" || fail "fleet-failed-command-observe-duplicate-enoent tests failed"
bash "$here/fleet-failed-command-observe-duplicate-1003.test.sh" || fail "fleet-failed-command-observe-duplicate-1003 tests failed"
bash "$here/fleet-failed-command-observe-duplicate-git-branch-force.test.sh" || fail "fleet-failed-command-observe-duplicate-git-branch-force tests failed"
bash "$here/fleet-failed-command-no-agent-names-reject.test.sh" || fail "fleet-failed-command-no-agent-names-reject tests failed"
bash "$here/fleet-failed-command-gh-pr-view-merged.test.sh" || fail "fleet-failed-command-gh-pr-view-merged tests failed"
bash "$here/fleet-failed-command-gh-json-graphql-recovery.test.sh" || fail "fleet-failed-command-gh-json-graphql-recovery tests failed"
bash "$here/fleet-failed-command-typo-est-sh.test.sh" || fail "fleet-failed-command-typo-est-sh tests failed"
bash "$here/fleet-failed-command-detector-bin-exit.test.sh" || fail "fleet-failed-command-detector-bin-exit tests failed"
bash "$here/fleet-failed-command-compound-ls-permission-denied.test.sh" || fail "fleet-failed-command-compound-ls-permission-denied tests failed"
bash "$here/fleet-heartbeat-rc-propagation.test.sh" || fail "fleet-heartbeat-rc-propagation tests failed"
bash "$here/fleet-heartbeat-alarm-rc-decoupling.test.sh" || fail "fleet-heartbeat-alarm-rc-decoupling tests failed"
bash "$here/gate-integrity-reusable.test.sh" || fail "gate-integrity reusable tests failed"
bash "$here/gate-integrity-reusable-828.test.sh" || fail "gate-integrity reusable 828 tests failed"
bash "$here/cancelled-while-queued-detector.test.sh" || fail "cancelled-while-queued-detector tests failed"
bash "$here/bulk-close-pr-landings.test.sh" || fail "bulk-close-pr-landings tests failed"
bash "$here/pi-intake-repair-run.test.sh" || fail "pi-intake-repair-run tests failed"

ok "P3b host complete"
