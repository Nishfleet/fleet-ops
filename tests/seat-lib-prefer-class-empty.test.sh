#!/usr/bin/env bash
# tests/seat-lib-prefer-class-empty.test.sh
#
# fleet-ops#5281: with PI_PICK_PREFER_CLASS=prepaid and EVERY prepaid seat
# benched, the prefer-class bucket copy ("${prepaid_seats[@]:-}") expanded to
# ONE empty-string element: chosen was set-but-empty, model_class_of "" ""
# hit SEAT_PROVIDER_CLASS[""] -> "SEAT_PROVIDER_CLASS: bad array subscript"
# on stderr, and pick_seat logged "prefer-class=prepaid routing to " (empty)
# on every depleted-class pick. The fix copies buckets with the set-u-safe
# form (${X[@]+"${X[@]}"}), so an empty bucket stays empty and the pick falls
# through to the normal class ladder (free-first) with no stderr noise.
#
# Proves, with all prepaid seats benched and .prefer-class=prepaid set:
#   1. No "bad array subscript" on stderr.
#   2. No "routing to " prefer-class line (the bucket is empty, not a
#      phantom seat).
#   3. The ladder still proceeds: pick_seat succeeds on a non-prepaid seat.
#
# Offline. Scratch models/caps/ledgers so live state cannot leak.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch=$(mktemp -d -t seat-lib-prefer-class-empty.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM
HOME="$scratch/home"
LEDGER="$scratch/ledger"
mkdir -p "$HOME" "$LEDGER"

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [ { "id": "glm-5-2", "cost": { "input": 0 }, "contextWindow": 200000 } ]
    },
    "xai-oauth": {
      "models": [ { "id": "grok-4.6", "cost": { "input": 0 }, "contextWindow": 200000 } ]
    },
    "commandcode": {
      "models": [ { "id": "poolside/laguna-s-2.1-free", "cost": { "input": 0 }, "contextWindow": 200000 } ]
    }
  }
}
JSON

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["commandcode"],
  "prepaid_providers_in_order": ["devin", "xai-oauth"],
  "walled_comeback": {
    "min_probe_interval_s": 900,
    "rate_limit_s": 900,
    "daily_quota_s": 3600,
    "monthly_quota_s": 86400,
    "free_balance_exhausted_s": 86400,
    "credentials_bad_s": 604800
  },
  "providers": {
    "devin": { "cap": 2, "class": "prepaid-quota", "models": { "glm-5-2": 1 } },
    "xai-oauth": { "cap": 2, "class": "prepaid-quota", "models": { "grok-4.6": 1 } },
    "commandcode": { "cap": 2, "class": "free", "models": { "poolside/laguna-s-2.1-free": 1 } }
  }
}
JSON

export HOME
export PI_PACKET_STATE="$scratch/state"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_SEAT_CREDENTIAL_PRECHECK=0
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export SEAT_LOG_FILE="$scratch/seat-lib.log"
export SEAT_LIVE_QUOTA_PROM="$scratch/no-live-quota.prom"
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
mkdir -p "$PI_PACKET_STATE"

lf() { printf '%s/%s__%s.json' "$LEDGER" "${1//[^A-Za-z0-9._-]/_}" "${2//[^A-Za-z0-9._-]/_}"; }

# Bench EVERY prepaid seat (quota wall) so the prepaid bucket comes back empty.
for pm in "devin glm-5-2" "xai-oauth grok-4.6"; do
    set -- $pm
    bash -c 'source "$0"; mark_seat_quota_bench "$1" "$2" "HTTP 429 quota resets in 2h" >/dev/null' \
        "$lib" "$1" "$2" || fail "bench $1/$2 failed"
    [[ -s "$(lf "$1" "$2")" ]] || fail "bench $1/$2 wrote no ledger"
done

# A pick with the depleted prefer-class: capture stderr AND stdout.
out=$(bash -c 'source "$0"; load_seat_caps; PI_PICK_PREFER_CLASS=prepaid PI_PICK_ROLE=scout pick_seat "" "" 0 "" "" "light"' \
    "$lib" 2>"$scratch/stderr.txt") || fail "prefer-class pick with depleted prepaid bucket must still succeed via the ladder"
err=$(cat "$scratch/stderr.txt")

# --- 1. no bad array subscript ---------------------------------------------
if grep -q 'bad array subscript' "$scratch/stderr.txt"; then
    fail "1: stderr still has 'bad array subscript': $err"
fi
ok "1: no SEAT_PROVIDER_CLASS bad-array-subscript on stderr"

# --- 2. no phantom 'routing to <empty>' line --------------------------------
if grep -q 'routing to *$' "$scratch/stderr.txt" || grep -q 'routing to $' "$scratch/stderr.txt"; then
    fail "2: prefer-class phantom 'routing to ' line present: $err"
fi
if grep -q 'prefer-class=prepaid routing to' "$scratch/stderr.txt"; then
    fail "2b: prefer-class log fired for an empty bucket: $err"
fi
ok "2: empty prefer-class bucket logs nothing (no phantom routing line)"

# --- 3. the ladder still proceeds (free-first) ------------------------------
[[ "$out" == "commandcode"$'\t'"poolside/laguna-s-2.1-free" ]] \
    || fail "3: ladder expected commandcode/poolside/laguna-s-2.1-free, got: $out"
ok "3: ladder proceeds to the free seat when the preferred class is depleted"

# --- 4. non-empty bucket still routes (no regression) -----------------------
# Un-bench devin/glm-5-2: prefer-class=prepaid must route to it again.
rm -f "$(lf devin glm-5-2)"
out2=$(bash -c 'source "$0"; load_seat_caps; PI_PICK_PREFER_CLASS=prepaid PI_PICK_ROLE=scout pick_seat "" "" 0 "" "" "light"' \
    "$lib" 2>"$scratch/stderr2.txt") || fail "4: prefer-class pick with a live prepaid seat must succeed"
[[ "$out2" == "devin"$'\t'"glm-5-2" ]] \
    || fail "4: prefer-class=prepaid expected devin/glm-5-2, got: $out2"
grep -q 'prefer-class=prepaid routing to devin' "$scratch/stderr2.txt" \
    || fail "4b: routing log must fire for a live prepaid pick: $(cat "$scratch/stderr2.txt")"
ok "4: live prepaid seat still routes via prefer-class (log fires, seat chosen)"

echo "ALL PASS"
