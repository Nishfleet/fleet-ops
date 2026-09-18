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
bash "$here/pi-packet-verdict.test.sh" || fail "pi-packet-verdict tests failed"
bash "$here/repo-privacy-guard.test.sh" || fail "repo-privacy-guard tests failed"
bash "$here/scout-prompt-difficulty.test.sh" || fail "scout-prompt-difficulty tests failed"
bash "$here/reusable-surface-audit.test.sh" || fail "reusable-surface-audit tests failed"
# fleet-ops#449 lock: fleet-blindspot-count had no CI host (its lock grepped a
# mangled path that never existed); hosted here per its own contract.
# fleet-ops#4263 fallout: #5993 dropped these host lines (113 -> 71), so the
# tests silently left CI; restored verbatim from the pre-#5993 host.
bash "$here/gate-integrity.test.sh" || fail "gate-integrity tests failed"
bash "$here/gate-integrity-config.test.sh" || fail "gate-integrity config tests failed"
bash "$here/seat-caps-citation.test.sh" || fail "seat-caps-citation tests failed"
bash "$here/seat-caps-citation-rule6-replay.test.sh" \
  || fail "seat-caps-citation rule6 replay tests failed"
bash "$here/keystone-routing.test.sh" || fail "keystone-routing tests failed"
bash "$here/senior-review-routing.test.sh" || fail "senior-review-routing tests failed"
bash "$here/seat-caps-zero-yield.test.sh" || fail "seat-caps-zero-yield tests failed"
bash "$here/watch-log-rotation.test.sh" || fail "watch-log-rotation tests failed"
# fleet-ops#1138: Relates to, not Closes, for decisions-ledger fixes.
bash "$here/gate-integrity-reusable.test.sh" || fail "gate-integrity reusable tests failed"
bash "$here/gate-integrity-reusable-828.test.sh" || fail "gate-integrity reusable 828 tests failed"
bash "$here/cancelled-while-queued-detector.test.sh" || fail "cancelled-while-queued-detector tests failed"
bash "$here/bulk-close-pr-landings.test.sh" || fail "bulk-close-pr-landings tests failed"

# fleet-ops#5810: a red-main repair PR must enter a merge queue at the head
# (jump:true), never tail-append behind entries whose group builds fail on
# the bug it fixes. Workers cannot add a P14 line in .github/workflows/ci.yml;
# this file is the listed CI host for the new repair-queue-jump test.
bash "$here/repair-queue-jump.test.sh" || fail "repair-queue-jump tests failed"

ok "P3b host complete"
