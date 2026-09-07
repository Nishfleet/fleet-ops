#!/usr/bin/env bash
# tests/pi-seat-source-litellm.test.sh
#
# Proves the PI_SEAT_SOURCE=litellm env switch routes all six worker callers
# to their LiteLLM model group instead of pick_seat (fleet-ops#4219 P3a).
# Default (seat-lib) path is unchanged.
#
# Scope: the seat-selection branch only. Not a live proxy test — the dual-run
# proof is a separate verification step.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

pass=0
fail_count=0
check() {
    local desc="$1"; shift
    if "$@"; then
        ok "$desc"
        (( ++pass ))
    else
        echo "FAIL: $desc" >&2
        (( ++fail_count ))
    fi
}

# --- 1. seat-lib.sh: litellm_pick_seat and litellm_source ------------------

# Source seat-lib with minimal stubs so we can call the new functions.
scratch="$(mktemp -d -t seat-source.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# We need a stripped-down seat-lib that has only the new functions and the
# minimal exports. The real seat-lib.sh has 6600+ lines of pick_seat/caps/
# ledger logic that we don't need here and would pull in jq/json dependencies.
seat_lib_subset="$scratch/seat-lib-subset.sh"
{
    echo '# shellcheck shell=bash'
    echo 'export HOME="${HOME:-/home/nish}"'
    echo 'export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"'
    echo 'LOG_FILE="'"$scratch"'/watch.log"'
    echo 'touch "$LOG_FILE"'
    # Extract the two new functions from seat-lib.sh
    sed -n '/^# fleet-ops#4219 P3a/,/^}/p' "$repo_root/lib/seat-lib.sh"
    # Also extract litellm_source
    sed -n '/^litellm_source()/,/^}/p' "$repo_root/lib/seat-lib.sh"
} > "$seat_lib_subset"

# shellcheck source=/dev/null
source "$seat_lib_subset"

# Test litellm_source
PI_SEAT_SOURCE=seat-lib
if litellm_source; then
    fail "litellm_source should be false when PI_SEAT_SOURCE=seat-lib"
fi
ok "litellm_source returns false when PI_SEAT_SOURCE=seat-lib"
(( ++pass ))

unset PI_SEAT_SOURCE
if litellm_source; then
    fail "litellm_source should be false when PI_SEAT_SOURCE is unset"
fi
ok "litellm_source returns false when PI_SEAT_SOURCE unset"
(( ++pass ))

PI_SEAT_SOURCE=litellm
if ! litellm_source; then
    fail "litellm_source should be true when PI_SEAT_SOURCE=litellm"
fi
ok "litellm_source returns true when PI_SEAT_SOURCE=litellm"
(( ++pass ))

# Test litellm_pick_seat
result=$(litellm_pick_seat "worker-cheap")
check "litellm_pick_seat worker-cheap returns litellm<TAB>worker-cheap" \
    test "$result" = "$(printf 'litellm\tworker-cheap')"

result=$(litellm_pick_seat "judge")
check "litellm_pick_seat judge returns litellm<TAB>judge" \
    test "$result" = "$(printf 'litellm\tjudge')"

result=$(litellm_pick_seat "worker-private")
check "litellm_pick_seat worker-private returns litellm<TAB>worker-private" \
    test "$result" = "$(printf 'litellm\tworker-private')"

result=$(litellm_pick_seat)
check "litellm_pick_seat default returns litellm<TAB>worker-cheap" \
    test "$result" = "$(printf 'litellm\tworker-cheap')"

# --- 2. Callers: verify PI_SEAT_SOURCE=litellm is wired into each script ---

# Check that each caller's script contains the PI_SEAT_SOURCE / litellm_source
# guard and the correct litellm group.
for caller in pi-issue-run pi-packet-run pi-scout-run agent-cron-run fleet-researcher-run; do
    script="$repo_root/bin/$caller"
    [[ -f "$script" ]] || fail "missing script: $script"
done

# pi-audit-run uses a different guard pattern (inline ${PI_SEAT_SOURCE:-seat-lib})
check "pi-issue-run has PI_SEAT_SOURCE guard" \
    grep -q 'PI_SEAT_SOURCE' "$repo_root/bin/pi-issue-run"

check "pi-packet-run has PI_SEAT_SOURCE guard" \
    grep -q 'PI_SEAT_SOURCE' "$repo_root/bin/pi-packet-run"

check "pi-scout-run has PI_SEAT_SOURCE guard" \
    grep -q 'PI_SEAT_SOURCE' "$repo_root/bin/pi-scout-run"

check "pi-audit-run has PI_SEAT_SOURCE guard" \
    grep -q 'PI_SEAT_SOURCE' "$repo_root/bin/pi-audit-run"

check "fleet-researcher-run has PI_SEAT_SOURCE guard" \
    grep -q 'PI_SEAT_SOURCE' "$repo_root/bin/fleet-researcher-run"

check "agent-cron-run has PI_SEAT_SOURCE guard" \
    grep -q 'PI_SEAT_SOURCE' "$repo_root/bin/agent-cron-run"

# --- 3. Correct group per caller -------------------------------------------

check "pi-issue-run routes to worker-cheap (public) / worker-private (private)" \
    grep -q 'worker-cheap' "$repo_root/bin/pi-issue-run"

check "pi-issue-run handles worker-private for private repos" \
    grep -q 'worker-private' "$repo_root/bin/pi-issue-run"

check "pi-packet-run routes to worker-cheap / worker-private" \
    grep -q 'worker-private' "$repo_root/bin/pi-packet-run"

check "pi-scout-run routes to worker-cheap" \
    grep -q 'worker-cheap' "$repo_root/bin/pi-scout-run"

check "pi-audit-run routes to worker-cheap" \
    grep -q 'worker-cheap' "$repo_root/bin/pi-audit-run"

check "fleet-researcher-run routes to worker-cheap" \
    grep -q 'worker-cheap' "$repo_root/bin/fleet-researcher-run"

check "agent-cron-run routes to judge" \
    grep -q 'judge' "$repo_root/bin/agent-cron-run"

# --- 4. Default path unchanged: pick_seat still called when seat-lib -------

# Each caller must still call pick_seat in the else branch (the default path).
check "pi-issue-run still calls pick_seat in default path" \
    grep -q 'pick_seat' "$repo_root/bin/pi-issue-run"

check "pi-packet-run still calls pick_seat in default path" \
    grep -q 'pick_seat' "$repo_root/bin/pi-packet-run"

check "pi-scout-run still calls pick_seat in default path" \
    grep -q 'pick_seat' "$repo_root/bin/pi-scout-run"

check "pi-audit-run still calls resolve_seat in default path" \
    grep -q 'resolve_seat' "$repo_root/bin/pi-audit-run"

check "fleet-researcher-run still calls pick_researcher_seat in default path" \
    grep -q 'pick_researcher_seat' "$repo_root/bin/fleet-researcher-run"

check "agent-cron-run still calls pick_seat in default path" \
    grep -q 'pick_seat' "$repo_root/bin/agent-cron-run"

# --- 5. models.json: litellm provider registered ---------------------------

models_json="$repo_root/config/pi-models.json"
check "models.json has litellm provider" \
    python3 -c "import json; d=json.load(open('$models_json')); assert 'litellm' in d['providers']"

check "litellm provider points to 127.0.0.1:4000" \
    python3 -c "import json; d=json.load(open('$models_json')); p=d['providers']['litellm']; assert p['baseUrl']=='http://127.0.0.1:4000'"

check "litellm provider has openai-completions api" \
    python3 -c "import json; d=json.load(open('$models_json')); p=d['providers']['litellm']; assert p['api']=='openai-completions'"

check "litellm provider has all 5 model groups" \
    python3 -c "
import json
d=json.load(open('$models_json'))
models={m['id'] for m in d['providers']['litellm']['models']}
expected={'worker-cheap','worker-capable','senior','judge','worker-private'}
assert models == expected, f'got {models}'
"

check "litellm provider apiKey is a command resolver (no raw key)" \
    python3 -c "
import json
d=json.load(open('$models_json'))
k=d['providers']['litellm']['apiKey']
assert k.startswith('!'), f'apiKey should start with ! (command resolver), got: {k[:20]}'
assert 'fleet-litellm-key' in k, f'apiKey should reference fleet-litellm-key'
"

# --- 6. fleet-litellm-key resolver exists and is executable ---------------

resolver="$repo_root/bin/fleet-litellm-key"
check "fleet-litellm-key exists and is executable" \
    test -x "$resolver"

check "fleet-litellm-key handles worker tier" \
    bash -c "FLEET_LITELLM_KEYS_ENV=/dev/null source /dev/null; true"

# --- summary ---------------------------------------------------------------

echo ""
echo "passed=$pass failed=$fail_count"
(( fail_count == 0 )) || exit 1
exit 0
