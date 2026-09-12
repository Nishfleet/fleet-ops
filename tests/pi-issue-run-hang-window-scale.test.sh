#!/usr/bin/env bash
# tests/pi-issue-run-hang-window-scale.test.sh
#
# fleet-ops#4602: mark_seat_hang_bench used a FLAT 180s window. devin/glm-5-2
# deterministically drew ~2401s (~40 min) per pick, so the seat was re-offered
# ~3 min after each hang and hung again — 16 LONG-HANG ETIMEDOUT events between
# 2026-09-08T09:07Z and 2026-09-09T01:02Z, each burning a worker or scout slot
# (the 0509 scout itself died this way at 01:02:28Z).
#
# The window must scale to the OBSERVED hang when the caller measured one,
# WITHOUT weakening either the flat default (no measurement -> still 180s) or
# the SEAT_FAILURE_CEILING park.
#
# Runs offline: stubbed seat-caps, scratch ledger dir, no network, no pi.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing: $lib"

scratch="$(mktemp -d -t hang-window-scale.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# fleet-ops#568 class lock: every pi-issue-run-*.test.sh must stub the App
# identity mint (WORKER_TOKEN_BIN + nishfleet-worker.env), so a fixture that
# forgets it dies at DEAD APP IDENTITY before the path it owns. This test
# exercises mark_seat_hang_bench directly and never mints a token, but it
# lives under the same glob and carries the same stub.
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"

stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
echo 'export GH_TOKEN=ghs_stub_token_for_tests'
STUB
chmod +x "$stub_bin/worker-token"
export WORKER_TOKEN_BIN="$stub_bin/worker-token"

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "devin": {
      "cap": 3,
      "class": "prepaid-quota",
      "models": {
        "glm-5-2": 3
      }
    }
  }
}
JSON

ledger="$scratch/ledger"
mkdir -p "$ledger"
marker="$ledger/devin__glm-5-2.json"

bench_call() {
    # bench_call <observed_s> <state_subdir>
    local observed="$1" state="$2"
    rm -f "$marker"
    set +e
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    PI_SEAT_HEALTH_LEDGER_DIR="$ledger" \
    PI_PACKET_STATE="$scratch/$state" \
    bash -c 'source "$0"; load_seat_caps; mark_seat_hang_bench "$1" "$2" "$3" "$4"' \
        "$lib" "devin" "glm-5-2" \
        'pi exited 1: spawnSync /home/nish/.local/bin/pi ETIMEDOUT' \
        "$observed" >/dev/null 2>&1
    local rc=$?
    set -e
    return $rc
}

delta_now() {
    local bu bu_s now_s
    bu=$(jq -r '.bench_until' "$marker")
    bu_s=$(date -u -d "$bu" +%s 2>/dev/null || echo 0)
    now_s=$(date -u +%s)
    echo $(( bu_s - now_s ))
}

# --- case 1: observed 2401s hang -> window must cover the observed draw -----
bench_call 2401 "state-scaled" || fail "scaled: mark_seat_hang_bench rc!=0"
[[ -f "$marker" ]] || fail "scaled: marker MUST be written"

ws=$(jq -r '.hang_window_s' "$marker")
(( ws >= 2000 )) || fail "scaled: hang_window_s must be >= 2000 for a 2401s observed hang, got '$ws' (flat-180 regression)"

d=$(delta_now)
(( d >= 2000 )) || fail "scaled: bench_until must be >= now+2000s, got delta=${d}s"

hc=$(jq -r '.health_class' "$marker")
fm=$(jq -r '.failure_mode' "$marker")
[[ "$hc" == "hang_bench" ]] || fail "scaled: health_class expected hang_bench, got '$hc'"
[[ "$fm" == "hang_no_response" ]] || fail "scaled: failure_mode expected hang_no_response, got '$fm'"
ok "observed 2401s hang -> window=${ws}s, bench_until=now+${d}s"

# --- case 2: the seat stays skipped for that window ------------------------
set +e
SEAT_CAPS_JSON="$scratch/seat-caps.json" \
PI_SEAT_HEALTH_LEDGER_DIR="$ledger" \
PI_PACKET_STATE="$scratch/state-usable" \
bash -c 'source "$0"; load_seat_caps; seat_usable "$1" "$2"' \
    "$lib" "devin" "glm-5-2" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scaled: seat_usable must rc=1 (unusable) while the scaled hang bench is fresh, got rc=$rc"
ok "seat_usable rejects devin/glm-5-2 while the scaled bench holds"

# --- case 3: pick-seat must not re-offer it -------------------------------
set +e
picked=$(SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    PI_SEAT_HEALTH_LEDGER_DIR="$ledger" \
    PI_PACKET_STATE="$scratch/state-pick" \
    bash -c 'source "$0"; load_seat_caps; pick-seat "" "" 0' "$lib" 2>/dev/null)
set -e
if [[ "$picked" == *"devin"* && "$picked" == *"glm-5-2"* ]]; then
    fail "scaled: pick-seat re-offered the benched seat within its observed hang window (got '$picked') — this is the #4602 slot burn"
fi
ok "pick-seat does not re-offer devin/glm-5-2 inside the scaled window"

# --- case 4: no measurement -> flat 180s default preserved -----------------
bench_call 0 "state-flat" || fail "flat: mark_seat_hang_bench rc!=0"
ws2=$(jq -r '.hang_window_s' "$marker")
[[ "$ws2" == "180" ]] || fail "flat: with no observed elapsed the default MUST stay 180, got '$ws2' (do not widen the default)"
d2=$(delta_now)
(( d2 > 150 && d2 < 210 )) || fail "flat: bench_until expected ~now+180s, got delta=${d2}s"
ok "no measurement -> flat 180s default preserved (window=${ws2}s)"

# --- case 5: a shorter observed hang never shrinks the default -------------
bench_call 42 "state-short" || fail "short: mark_seat_hang_bench rc!=0"
ws3=$(jq -r '.hang_window_s' "$marker")
[[ "$ws3" == "180" ]] || fail "short: a 42s observed hang must NOT shrink the 180s floor, got '$ws3'"
ok "short observed hang (42s) does not shrink the 180s floor"

echo "PASS: tests/pi-issue-run-hang-window-scale.test.sh"
