#!/usr/bin/env bash
# tests/quality-routing.test.sh
#
# Proves fleet-ops#457 quality-weighted routing:
#   (b) fixture lane over the revert-rate cut is skipped for heavy work
#       and still picked for light work
#   (c) the same lane is restored for heavy work once metrics recover
#   missing snapshot does not change pick_seat (do not brick the ladder)
#   contracts: pick_seat hook + MANIFEST + nested CI host
#
# Offline. Uses a scratch models/caps map so live seat-caps cannot leak.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"
py="$repo_root/lib/quality-routing.py"
thresholds="$repo_root/config/quality-routing.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$py" ]] || fail "missing $py"
[[ -f "$thresholds" ]] || fail "missing $thresholds"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch=$(mktemp -d -t quality-routing.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    },
    "commandcode": {
      "models": [
        { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama", "commandcode"],
  "providers": {
    "ollama": { "cap": 2, "class": "free", "models": { "deepseek-v4-flash:0731": 2 } },
    "commandcode": { "cap": 2, "class": "free", "models": { "deepseek/deepseek-v4-flash": 2 } }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export QUALITY_ROUTING_JSON="$thresholds"
export QUALITY_ROUTING_PY="$py"
export PI_SEAT_CREDENTIAL_PRECHECK=0

pick() {
    local capable="$1"
    export PI_PACKET_STATE="$scratch/state-$capable-$$"
    export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
    mkdir -p "$PI_PACKET_STATE" "$PI_SEAT_HEALTH_LEDGER_DIR"
    bash -c 'source "$0"; load_seat_caps; pick_seat "" "" "'"$capable"'"' "$lib" 2>/dev/null
}

# --- missing snapshot: no cuts ---------------------------------------------
export QUALITY_SCOREBOARD_JSON="$scratch/missing.json"
out=$(pick 1) || fail "missing snapshot must still pick a heavy seat"
[[ "$out" == "ollama	deepseek-v4-flash:0731" ]] \
  || fail "missing snapshot expected ollama first, got: $out"
ok "(pre) missing snapshot does not cut (ollama still first for heavy)"

# --- (b) injected regression: ollama over revert cut -----------------------
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$scratch/snapshot.json" <<JSON
{
  "generated_at": "$now_iso",
  "lanes": {
    "ollama/deepseek-v4-flash:0731": {
      "role": "builder",
      "revert_rate": 0.12,
      "defect_rate": 0.10,
      "overturn_rate": 0.0
    },
    "commandcode/deepseek/deepseek-v4-flash": {
      "role": "builder",
      "revert_rate": 0.01,
      "defect_rate": 0.05,
      "overturn_rate": 0.0
    }
  }
}
JSON
export QUALITY_SCOREBOARD_JSON="$scratch/snapshot.json"

bans=$(python3 "$py" heavy-bans --thresholds "$thresholds" --scoreboard "$scratch/snapshot.json")
[[ "$bans" == "ollama/deepseek-v4-flash:0731" ]] \
  || fail "heavy-bans should name ollama, got: $bans"
ok "(b) evaluator bans the over-threshold lane"

heavy=$(pick 1) || fail "heavy pick after regression must still find a seat"
[[ "$heavy" == "commandcode	deepseek/deepseek-v4-flash" ]] \
  || fail "(b) heavy work must skip ollama, got: $heavy"
ok "(b) fixture regression: heavy work routes away from ollama"

light=$(pick 0) || fail "light pick must succeed"
[[ "$light" == "ollama	deepseek-v4-flash:0731" ]] \
  || fail "(b) light work must still use ollama, got: $light"
ok "(b) fixture regression: light work still uses ollama"

# --- (c) recovery: rates back under cut ------------------------------------
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$scratch/recovered.json" <<JSON
{
  "generated_at": "$now_iso",
  "lanes": {
    "ollama/deepseek-v4-flash:0731": {
      "role": "builder",
      "revert_rate": 0.01,
      "defect_rate": 0.05,
      "overturn_rate": 0.0
    }
  }
}
JSON
export QUALITY_SCOREBOARD_JSON="$scratch/recovered.json"
recovered=$(pick 1) || fail "recovered heavy pick must succeed"
[[ "$recovered" == "ollama	deepseek-v4-flash:0731" ]] \
  || fail "(c) recovered ollama must be first again, got: $recovered"
ok "(c) recovery drill: cap/heavy routing restores on measured improvement"

# --- contracts -------------------------------------------------------------
grep -q 'QUALITY_HEAVY_BAN' "$lib" \
  || fail "seat-lib.sh must honour QUALITY_HEAVY_BAN in pick_seat"
grep -q 'bin/fleet-role-gate-audit' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install fleet-role-gate-audit"
grep -q 'config/quality-routing.json' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install quality-routing.json"
grep -Fq 'bash "$here/quality-routing.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "contracts: pick_seat hook, MANIFEST, nested CI host"

ok "quality-routing: missing-snapshot, regression-cut, recovery"
