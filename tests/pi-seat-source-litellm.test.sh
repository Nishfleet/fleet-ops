#!/usr/bin/env bash
# tests/pi-seat-source-litellm.test.sh
#
# fleet-ops#4263 P3b: workers always route through LiteLLM groups.
# Dual-path PI_SEAT_SOURCE is gone.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

pass=0
check() {
    local desc="$1"; shift
    if "$@"; then
        ok "$desc"
        (( ++pass ))
    else
        fail "$desc"
    fi
}

[[ -f "$repo_root/lib/litellm-seat.sh" ]] || fail "missing lib/litellm-seat.sh"
if [[ -f "$repo_root/lib/seat-lib.sh" ]]; then
    grep -q 'pick_seat()' "$repo_root/lib/seat-lib.sh" \
      && fail "lib/seat-lib.sh must not define pick_seat"
fi

scratch="$(mktemp -d -t seat-source.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
# shellcheck source=/dev/null
source "$repo_root/lib/litellm-seat.sh"

check "provider_remote_agent is defined (wrappers call it under set -e if-conditions)" \
    bash -c 'source "$0"; declare -F provider_remote_agent >/dev/null' "$repo_root/lib/litellm-seat.sh"
check "SPAWN_FAIL_MAX_S set after source" \
    test "${SPAWN_FAIL_MAX_S}" -gt 0
check "SPAWN_FAIL_BACKOFF_S set after source" \
    test "${SPAWN_FAIL_BACKOFF_S}" -gt 0

result=$(litellm_pick_seat "worker-cheap")
check "litellm_pick_seat worker-cheap" \
    test "$result" = "$(printf 'litellm\tworker-cheap')"

result=$(litellm_pick_seat "judge")
check "litellm_pick_seat judge" \
    test "$result" = "$(printf 'litellm\tjudge')"

result=$(litellm_pick_seat "worker-private")
check "litellm_pick_seat worker-private" \
    test "$result" = "$(printf 'litellm\tworker-private')"

check "pi-issue-run uses worker-cheap" \
    grep -q 'worker-cheap' "$repo_root/bin/pi-issue-run"
check "pi-issue-run uses worker-private" \
    grep -q 'worker-private' "$repo_root/bin/pi-issue-run"
check "pi-packet-run uses worker-private" \
    grep -q 'worker-private' "$repo_root/bin/pi-packet-run"
check "pi-scout-run uses worker-cheap" \
    grep -q 'worker-cheap' "$repo_root/bin/pi-scout-run"
check "pi-audit-run uses worker-cheap" \
    grep -q 'worker-cheap' "$repo_root/bin/pi-audit-run"
check "fleet-researcher-run uses worker-cheap" \
    grep -q 'worker-cheap' "$repo_root/bin/fleet-researcher-run"
check "agent-cron-run uses judge" \
    grep -q 'judge' "$repo_root/bin/agent-cron-run"
check "pi-issue-run does not call pick_seat" \
    bash -c '! grep -qE "\$\(pick_seat" "$0"' "$repo_root/bin/pi-issue-run"

# Proxy fallbacks own worker-capable. Leftover need_capable= trips SC2034
# on pi-issue-run and fails P14 (claim-loop-gate Test 8).
for _f in pi-issue-run pi-packet-run pi-scout-run agent-cron-run; do
    check "$_f does not assign leftover need_capable" \
        bash -c '! grep -qE "^[[:space:]]*need_capable=" "$0"' "$repo_root/bin/$_f"
done

check "pi-scout-packet-assembly stub defines litellm_pick_seat (P14 #4263)" \
    grep -q 'litellm_pick_seat()' "$repo_root/tests/pi-scout-packet-assembly.test.sh"
check "pi-scout-seat-rotation stub defines litellm_pick_seat (P14 #4263)" \
    grep -q 'litellm_pick_seat()' "$repo_root/tests/pi-scout-seat-rotation.test.sh"
check "pi-scout-seat-rotation expects --provider litellm" \
    grep -q -- '--provider litellm' "$repo_root/tests/pi-scout-seat-rotation.test.sh"

ok "pi-issue-run has no pick_seat call"
(( ++pass ))

echo "OK: $pass checks"
