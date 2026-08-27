#!/usr/bin/env bash
# tests/fleet-volume-lane-order-canary.test.sh
#
# Proves the volume front-of-ladder canary (fleet-ops#1178) offline:
#   1. Clean locked prefix + live volume seats + seat-lib wire -> exit 0, OK.
#   2. Missing volume_providers_in_order -> exit 1, LOUD.
#   3. Wrong prefix order -> exit 1.
#   4. Volume provider cap=0 -> exit 1.
#   5. Volume provider empty models -> exit 1.
#   6. cursor in the volume prefix -> exit 1.
#   7. seat-lib without SEAT_VOLUME_ORDER / volume_seats -> exit 1.
#   8. xai-oauth in models.json but missing from seat-caps -> exit 0, files.
#   9. Dedup: open issue with the marker -> no second create.
#  10. Production seat-caps is clean.
#  11. Heartbeat-tier1 wires the canary and propagates a fail-loud.
#  12. pick_seat prefers volume prefix over leftover free (runtime proof).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-volume-lane-order-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"
[[ -f "$lib" ]] || fail "missing: $lib"

scratch="$(mktemp -d -t volume-lane-order-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_VOLUME_ORDER_REPO="Nishfleet/fleet-ops"
export FLEET_VOLUME_ORDER_FILE=1
export FLEET_OPS_REPO="$repo_root"

gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export PATH="$scratch:$PATH"

write_caps() { cat >"$scratch/seat-caps.json"; }
write_models() { cat >"$scratch/models.json"; }
write_seat_lib() { cat >"$scratch/seat-lib.sh"; }

base_caps() {
  write_caps <<'JSON'
{
  "volume_providers_in_order": ["ollama", "devin", "commandcode", "cline"],
  "free_providers_in_order": ["commandcode", "hetzner"],
  "prepaid_providers_in_order": ["ollama", "devin", "cline", "cursor"],
  "providers": {
    "ollama": {
      "cap": 4,
      "class": "prepaid-quota",
      "models": { "deepseek-v4-flash:0731": 4 }
    },
    "devin": {
      "cap": 4,
      "class": "prepaid-quota",
      "models": { "glm-5-2": 4 }
    },
    "commandcode": {
      "cap": 2,
      "class": "free",
      "models": { "deepseek/deepseek-v4-flash": 2 }
    },
    "cline": {
      "cap": 2,
      "class": "prepaid-quota",
      "models": { "cline-pass/minimax-m3": 2 }
    },
    "cursor": {
      "cap": 1,
      "class": "prepaid-quota",
      "models": { "cursor-grok-4.6-high": 1 }
    },
    "hetzner": {
      "cap": 2,
      "class": "free",
      "models": { "Qwen/Qwen3.6-35B-A3B-FP8": 2 }
    }
  }
}
JSON
}

base_models() {
  write_models <<'JSON'
{
  "providers": {
    "ollama": { "models": [ { "id": "deepseek-v4-flash:0731" } ] },
    "devin": { "models": [ { "id": "glm-5-2" } ] },
    "commandcode": { "models": [ { "id": "deepseek/deepseek-v4-flash" } ] },
    "cline": { "models": [ { "id": "cline-pass/minimax-m3" } ] },
    "xai-oauth": { "models": [ { "id": "grok-4.6" } ] }
  }
}
JSON
}

# Minimal seat-lib stub that still contains the runtime markers the canary
# greps for. Production tests use the real lib.
base_seat_lib() {
  write_seat_lib <<'SH'
#!/usr/bin/env bash
# stub: carries the volume-order markers
SEAT_VOLUME_ORDER=$(jq -r '.volume_providers_in_order // [] | join(" ")' "$SEAT_CAPS_JSON")
volume_seats=()
# volume_providers_in_order read above
SH
}

run_canary() {
  set +e
  env_out=$(
    SEAT_CAPS_JSON="$scratch/seat-caps.json" \
    FLEET_VOLUME_ORDER_MODELS_JSON="$scratch/models.json" \
    FLEET_VOLUME_ORDER_SEAT_LIB="$scratch/seat-lib.sh" \
    FLEET_VOLUME_ORDER_FILE="${FLEET_VOLUME_ORDER_FILE:-1}" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

# --- 1. clean ---------------------------------------------------------------
: >"$gh_log"; : >"$triage"
base_caps; base_models; base_seat_lib
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: clean must exit 0, got rc=$env_rc ($env_out)"
grep -q 'VOLUME-ORDER-OK' <<<"$env_out" || fail "scenario1: must log OK ($env_out)"
ok "scenario1: clean locked prefix exits 0"

# --- 2. missing volume_providers_in_order -----------------------------------
: >"$gh_log"; : >"$triage"
write_caps <<'JSON'
{
  "providers": {
    "ollama": { "cap": 4, "class": "prepaid-quota", "models": { "deepseek-v4-flash:0731": 4 } },
    "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 4 } },
    "commandcode": { "cap": 2, "class": "free", "models": { "deepseek/deepseek-v4-flash": 2 } },
    "cline": { "cap": 2, "class": "prepaid-quota", "models": { "cline-pass/minimax-m3": 2 } }
  }
}
JSON
base_models; base_seat_lib
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: missing order must exit 1, got rc=$env_rc ($env_out)"
grep -q 'VOLUME-ORDER-VIOLATION' <<<"$env_out" || fail "scenario2: must LOUD ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario2: must file (gh=$(cat "$gh_log"))"
ok "scenario2: missing volume_providers_in_order fails loud"

# --- 3. wrong prefix --------------------------------------------------------
: >"$gh_log"; : >"$triage"
base_caps
jq '.volume_providers_in_order = ["devin","ollama","commandcode","cline"]' \
  "$scratch/seat-caps.json" >"$scratch/seat-caps.tmp" \
  && mv "$scratch/seat-caps.tmp" "$scratch/seat-caps.json"
base_models; base_seat_lib
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario3: wrong order must exit 1, got rc=$env_rc ($env_out)"
grep -q 'mismatch\|expected ollama,devin' <<<"$env_out" \
  || fail "scenario3: must name the mismatch ($env_out)"
ok "scenario3: wrong prefix fails loud"

# --- 4. volume provider cap=0 -----------------------------------------------
: >"$gh_log"; : >"$triage"
base_caps
jq '.providers.devin.cap = 0' "$scratch/seat-caps.json" >"$scratch/seat-caps.tmp" \
  && mv "$scratch/seat-caps.tmp" "$scratch/seat-caps.json"
base_models; base_seat_lib
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario4: cap=0 must exit 1, got rc=$env_rc ($env_out)"
grep -q 'cap=0' <<<"$env_out" || fail "scenario4: must name cap=0 ($env_out)"
ok "scenario4: volume provider cap=0 fails loud"

# --- 5. empty models --------------------------------------------------------
: >"$gh_log"; : >"$triage"
base_caps
jq '.providers.commandcode.models = {}' "$scratch/seat-caps.json" >"$scratch/seat-caps.tmp" \
  && mv "$scratch/seat-caps.tmp" "$scratch/seat-caps.json"
base_models; base_seat_lib
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario5: empty models must exit 1, got rc=$env_rc ($env_out)"
grep -q 'empty models\|mcount=0' <<<"$env_out" || fail "scenario5: must name empty models ($env_out)"
ok "scenario5: empty models map fails loud"

# --- 6. cursor in volume prefix ---------------------------------------------
: >"$gh_log"; : >"$triage"
base_caps
jq '.volume_providers_in_order = ["ollama","devin","commandcode","cline","cursor"]' \
  "$scratch/seat-caps.json" >"$scratch/seat-caps.tmp" \
  && mv "$scratch/seat-caps.tmp" "$scratch/seat-caps.json"
base_models; base_seat_lib
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario6: cursor in prefix must exit 1, got rc=$env_rc ($env_out)"
grep -q 'cursor' <<<"$env_out" || fail "scenario6: must name cursor ($env_out)"
ok "scenario6: cursor in volume prefix fails loud"

# --- 7. seat-lib missing volume wire ----------------------------------------
: >"$gh_log"; : >"$triage"
base_caps; base_models
write_seat_lib <<'SH'
#!/usr/bin/env bash
# stub without volume markers
SEAT_FREE_ORDER=""
SH
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario7: missing seat-lib wire must exit 1, got rc=$env_rc ($env_out)"
grep -q 'SEAT_VOLUME_ORDER\|volume_seats\|volume_providers_in_order' <<<"$env_out" \
  || fail "scenario7: must name the missing wire ($env_out)"
ok "scenario7: seat-lib without volume wire fails loud"

# --- 8. xai-oauth unwired detector (tick stays green) -----------------------
: >"$gh_log"; : >"$triage"
base_caps; base_models; base_seat_lib
# models already has xai-oauth; caps does not
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario8: detector must stay exit 0, got rc=$env_rc ($env_out)"
grep -q 'VOLUME-ORDER-AVAILABLE\|xai-oauth' <<<"$env_out" \
  || fail "scenario8: must log xai-oauth available ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario8: must file wire ticket (gh=$(cat "$gh_log"))"
ok "scenario8: xai-oauth unwired detector files, tick stays green"

# --- 9. dedup ---------------------------------------------------------------
: >"$gh_log"; : >"$triage"
base_caps; base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: xai-oauth unwired\n' \
  '[{number: 42, title: "volume lane order: wire xai-oauth", body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario9: dedup must exit 0, got rc=$env_rc ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario9: must not create a second issue (gh=$(cat "$gh_log"))"
fi
grep -q 'dedup:' <<<"$env_out" || fail "scenario9: must log dedup ($env_out)"
ok "scenario9: open marker dedupes"

# --- 9b. xai-oauth coordinate dedup against an older wire ticket (#1163 shape) -
: >"$gh_log"; : >"$triage"
base_caps; base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg t 'Add revived xai-oauth (SuperGrok sub) seat to the roster/caps with alternation discipline'       --arg b $'Wire xai-oauth into seat-caps with alternation. Coordinate with ram-governor.\n'   '[{number: 1163, title: $t, body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario9b: coordinate dedup must exit 0, got rc=$env_rc ($env_out)"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario9b: must not create when #1163-shaped open issue exists (gh=$(cat "$gh_log"))"
fi
grep -q 'dedup:' <<<"$env_out" || fail "scenario9b: must log dedup ($env_out)"
ok "scenario9b: open xai-oauth wire ticket (#1163 shape) dedupes"
unset GH_OPEN_ISSUES

# --- 10. production seat-caps -----------------------------------------------
: >"$gh_log"; : >"$triage"
set +e
prod_out=$(
  SEAT_CAPS_JSON="$repo_root/config/seat-caps.json" \
  FLEET_VOLUME_ORDER_MODELS_JSON="${HOME_REAL:-/home/nish}/.pi/agent/models.json" \
  FLEET_VOLUME_ORDER_SEAT_LIB="$repo_root/lib/seat-lib.sh" \
  FLEET_VOLUME_ORDER_FILE=0 \
  FLEET_OPS_REPO="$repo_root" \
  HOME="${HOME_REAL:-/home/nish}" \
  "$bin" 2>&1
)
prod_rc=$?
set -e
[[ "$prod_rc" == "0" ]] || fail "scenario10: production must be clean, got rc=$prod_rc ($prod_out)"
grep -q 'VOLUME-ORDER-OK' <<<"$prod_out" || fail "scenario10: production must log OK ($prod_out)"
jq -e '
  .volume_providers_in_order == ["ollama","devin","commandcode","cline"]
  and (.volume_providers_in_order | index("cursor") | not)
' "$repo_root/config/seat-caps.json" >/dev/null \
  || fail "scenario10: production volume_providers_in_order must be the locked prefix"
ok "scenario10: production seat-caps is clean"

# --- 11. heartbeat + MANIFEST wiring ----------------------------------------
grep -F 'fleet-volume-lane-order-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-volume-lane-order-canary"
grep -F 'volume_order_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture volume_order_canary_rc"
grep -F -- '_propagate_crash volume_order_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the volume-order gate fails loud"
grep -q 'bin/fleet-volume-lane-order-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-volume-lane-order-canary"
ok "scenario11: heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it"

# --- 12. pick_seat runtime: volume beats leftover free ----------------------
# Fixture: hetzner (free, NOT in volume) + ollama (prepaid, IN volume).
# Without volume order, free wins. With volume order, ollama must win.
export PI_SEAT_LIB_CHECK_SYSTEMD=0
mkdir -p "$scratch/rt/ledger" "$scratch/rt/state" "$scratch/rt/active"
cat >"$scratch/rt/models.json" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [ { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 }, "contextWindow": 131072 } ]
    },
    "hetzner": {
      "models": [ { "id": "Qwen/Qwen3.6-35B-A3B-FP8", "cost": { "input": 0 }, "contextWindow": 131072 } ]
    },
    "devin": {
      "models": [ { "id": "glm-5-2", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 } ]
    },
    "commandcode": {
      "models": [ { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0 }, "contextWindow": 131072 } ]
    },
    "cline": {
      "models": [ { "id": "cline-pass/minimax-m3", "cost": { "input": 0 }, "contextWindow": 200000 } ]
    }
  }
}
JSON
cat >"$scratch/rt/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "volume_providers_in_order": ["ollama", "devin", "commandcode", "cline"],
  "free_providers_in_order": ["hetzner", "commandcode"],
  "prepaid_providers_in_order": ["ollama", "devin", "cline"],
  "providers": {
    "ollama": { "cap": 4, "class": "prepaid-quota", "models": { "deepseek-v4-flash:0731": 4 } },
    "hetzner": { "cap": 2, "class": "free", "models": { "Qwen/Qwen3.6-35B-A3B-FP8": 2 } },
    "devin": { "cap": 0, "class": "prepaid-quota", "models": { "glm-5-2": 0 }, "reason": "2026-08-27 fixture dark" },
    "commandcode": { "cap": 0, "class": "free", "models": { "deepseek/deepseek-v4-flash": 0 }, "reason": "2026-08-27 fixture dark" },
    "cline": { "cap": 0, "class": "prepaid-quota", "models": { "cline-pass/minimax-m3": 0 }, "reason": "2026-08-27 fixture dark" }
  }
}
JSON
# Stub provider_has_credential open for every provider in this offline fixture.
# seat-lib reads models.json apiKey; our fixture has none, so inject a always-yes
# by setting PI_SEAT_LIB_ASSUME_CREDS if supported — otherwise wrap via a tiny
# models.json that carries a literal apiKey.
python3 - <<'PY'
import json
from pathlib import Path
p = Path("/tmp")  # placeholder
PY
# Prefer literal apiKey in models so provider_has_credential returns true.
python3 <<PY
import json
from pathlib import Path
p = Path("$scratch/rt/models.json")
d = json.loads(p.read_text())
for prov in d["providers"].values():
    prov["apiKey"] = "test-key"
p.write_text(json.dumps(d))
PY
export PI_MODELS_JSON="$scratch/rt/models.json"
export SEAT_CAPS_JSON="$scratch/rt/seat-caps.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/rt/ledger"
export PI_PACKET_STATE="$scratch/rt/state"
export PI_ACTIVE_SEATS_DIR="$scratch/rt/active"
set +e
pick=$(bash -c 'source "$0"; load_seat_caps; pick_seat "" "" 0' "$lib" 2>/dev/null)
pick_rc=$?
set -e
[[ "$pick_rc" == "0" ]] || fail "scenario12: pick_seat must succeed, rc=$pick_rc pick=$pick"
[[ "$pick" == $'ollama\tdeepseek-v4-flash:0731' ]] \
  || fail "scenario12: volume order must prefer ollama over free hetzner, got: $pick"
ok "scenario12: pick_seat prefers volume prefix (ollama) over leftover free (hetzner)"

ok "fleet-volume-lane-order-canary: missing, mismatch, cap, models, cursor, seat-lib wire, xai detector, dedup, production clean, heartbeat, pick_seat"
