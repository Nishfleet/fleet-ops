#!/usr/bin/env bash
# tests/seat-lib-bench-truth-cap.test.sh
#
# fleet-ops#5285: benches lie. A quota bench built ONLY from the provider's
# static quota_bench_default_s is not an advertised reset — no provider
# reset was parsed or observed live — so mark_seat_quota_bench must cap the
# window at SEAT_QUOTA_BENCH_DEFAULT_MAX_S (default 900s = 15 min, the
# bench-truth probe cadence). The lived class: devin/swe-1-7 benched
# bench_window_s=518400 (6 DAYS) on a minutes-scale 429 and devin/swe-2-high
# benched 15360s (4h16m) on a "reset in 2…" misparse.
#   1. a default-driven window (no parsed reset, no live quota) is capped
#      at 900s even after #3531 geometric escalation over the default.
#   2. a PARSED advertised reset keeps its window (that is an advertised
#      reset; the bench-truth probe corrects a lying advertisement within
#      one 15-min cycle).
#
# Pure unit test — no pi, no network, no live systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-lib-btc.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
export QUALITY_SCOREBOARD_JSON="$scratch/no-quality.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality.json"
echo '{}' >"$scratch/no-quality.json"

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "devin": { "models": [{ "id": "glm-5-2", "cost": { "input": 0 } }] }
  }
}
JSON

# The lived default: cline-style 604800 (6 days) fallback, cap > 0.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "providers": {
    "devin": {
      "cap": 4,
      "class": "corp",
      "quota_bench_default_s": 604800,
      "models": { "glm-5-2": 4 }
    }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
ledger="$scratch/ledger"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state"
mkdir -p "$PI_PACKET_STATE"

# shellcheck disable=SC1090
source "$lib"

# --- 1. default-driven window is capped at the bench-truth max -------------
mark_seat_quota_bench devin glm-5-2 "" \
  || fail "1: mark_seat_quota_bench must write the bench"
f="$ledger/devin__glm-5-2.json"
[[ -f "$f" ]] || fail "1: bench ledger missing: $f"
now_e=$(date -u +%s)
bu=$(jq -r '.bench_until' "$f")
bu_e=$(date -u -d "$bu" +%s 2>/dev/null || echo 999999999999)
remain=$(( bu_e - now_e ))
# cap 900s + small clock slack; the lived bug wrote 6 days.
if (( remain > 960 )); then
  fail "1: default-driven bench window must be capped at ~900s, got remain=${remain}s (bench_until=$bu) — the 6-day phantom bench class (fleet-ops#5285)"
fi
(( remain > 0 )) || fail "1: bench_until must be in the future, got $bu"
ok "1: default-driven window capped at 15 min before the first truth probe (remain=${remain}s)"

# --- 2. parsed advertised reset keeps its window ---------------------------
rm -f "$f"
# An advertised reset of 2h in the 429 text is a real provider claim.
mark_seat_quota_bench devin glm-5-2 "rate limit exceeded, resets in 2 hours" \
  || fail "2: mark_seat_quota_bench must write the bench for a parsed window"
[[ -f "$f" ]] || fail "2: bench ledger missing for parsed window"
bu=$(jq -r '.bench_until' "$f")
bu_e=$(date -u -d "$bu" +%s 2>/dev/null || echo 0)
remain=$(( bu_e - now_e ))
src=$(jq -r '.source' "$f")
[[ "$src" == "provider_quota_window" ]] \
  || fail "2: parsed window must keep wall_source=provider_quota_window, got $src"
if (( remain < 3600 )); then
  fail "2: a parsed advertised reset must NOT be capped at 900s (it is an advertisement the probe corrects), got remain=${remain}s"
fi
ok "2: parsed advertised reset keeps its window (remain=${remain}s, source=$src)"

echo "ALL OK: bench-truth writer cap (fleet-ops#5285): default-driven quota benches capped at 15 min, advertised resets kept"
