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
#  18. observe-to-close keeps xai-oauth unwired while seat-caps lacks the row.
#  18b. observe-to-close CLOSES xai-oauth unwired once the seat-caps row lands
#      (fleet-ops#1268 mechanical fix — the always-active arm was wrong).
#  18c/18d. cap-zero-stale-reason closes on cap>0 / stays open on stale reason.

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
  *"issue close"*)
    # observe-to-close path: record every close call so tests can assert.
    printf '%s\n' "$*" >>"${GH_CLOSE_LOG:-/dev/null}"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export GH_CLOSE_LOG="$scratch/gh.close.log"
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
grep -F -- 'exit "$volume_order_canary_rc"' "$tier1" >/dev/null \
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

unset PI_SEAT_LIB_CHECK_SYSTEMD PI_MODELS_JSON SEAT_CAPS_JSON
unset PI_SEAT_HEALTH_LEDGER_DIR PI_PACKET_STATE PI_ACTIVE_SEATS_DIR

# --- 13. observe-to-close: open volume_providers_in_order missing, signal now clean ---
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
base_caps; base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: volume_providers_in_order missing\n' \
  '[{number: 1269, title: "volume lane order: volume_providers_in_order missing", body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario13: clean tick must exit 0, got rc=$env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #1269' <<<"$env_out" \
  || fail "scenario13: must close #1269 ($env_out)"
grep -q 'issue close.*1269' "$GH_CLOSE_LOG" \
  || fail "scenario13: gh issue close must be called for #1269 (log=$(cat "$GH_CLOSE_LOG"))"
ok "scenario13: closed #1269 once volume_providers_in_order is the locked prefix"
unset GH_OPEN_ISSUES

# --- 14. observe-to-close: open volume_providers_in_order missing, signal still active ---
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
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
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: volume_providers_in_order missing\n' \
  '[{number: 1269, title: "volume lane order: volume_providers_in_order missing", body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario14: missing csv must still exit 1, got rc=$env_rc ($env_out)"
# A NEW issue is filed in this scenario (the canary re-detects the
# missing field), so the open list now has #1269 as the original AND
# #999 as a freshly filed one. observe_to_close must keep #1269 because
# the signal is still active (csv still missing), and must NOT close it
# just because we are filing a new ticket.
if grep -q 'observe-to-close: CLOSED issue #1269' <<<"$env_out"; then
    fail "scenario14: must NOT close #1269 when signal still active ($env_out)"
fi
grep -q 'observe-to-close: keep #1269' <<<"$env_out" \
  || fail "scenario14: must log keep for #1269 ($env_out)"
# Note: a fresh file_finding also runs; we only assert #1269 stays open
# here. The newly filed issue lives in a separate marker shape and the
# canary does not get to re-evaluate it on the same tick.
ok "scenario14: kept #1269 open when volume_providers_in_order still missing"
unset GH_OPEN_ISSUES

# --- 15. observe-to-close: open <provider> cap-zero, cap is now >0 ---
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
base_caps
jq '.providers.devin.cap = 2' "$scratch/seat-caps.json" >"$scratch/seat-caps.tmp" \
  && mv "$scratch/seat-caps.tmp" "$scratch/seat-caps.json"
base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: devin cap-zero\n' \
  '[{number: 1290, title: "volume lane order: devin cap=0 (cannot lead)", body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario15: cap>0 must exit 0, got rc=$env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #1290' <<<"$env_out" \
  || fail "scenario15: must close #1290 ($env_out)"
ok "scenario15: closed <provider> cap-zero issue once cap is raised"
unset GH_OPEN_ISSUES

# --- 16. observe-to-close: open <provider> empty-models, models now populated ---
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
base_caps
jq '.providers.commandcode.models = {"deepseek/deepseek-v4-flash": 1}' \
  "$scratch/seat-caps.json" >"$scratch/seat-caps.tmp" \
  && mv "$scratch/seat-caps.tmp" "$scratch/seat-caps.json"
base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: commandcode empty-models\n' \
  '[{number: 1291, title: "volume lane order: commandcode has no allowlisted models", body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario16: models populated must exit 0, got rc=$env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #1291' <<<"$env_out" \
  || fail "scenario16: must close #1291 ($env_out)"
ok "scenario16: closed empty-models issue once models map is non-empty"
unset GH_OPEN_ISSUES

# --- 17. observe-to-close: open cursor in-volume-prefix, cursor now excluded ---
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
base_caps
jq '.volume_providers_in_order = ["ollama","devin","commandcode","cline"]' \
  "$scratch/seat-caps.json" >"$scratch/seat-caps.tmp" \
  && mv "$scratch/seat-caps.tmp" "$scratch/seat-caps.json"
base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: cursor in-volume-prefix\n' \
  '[{number: 1292, title: "volume lane order: cursor must not be in the volume prefix", body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario17: cursor removed must exit 0, got rc=$env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #1292' <<<"$env_out" \
  || fail "scenario17: must close #1292 ($env_out)"
ok "scenario17: closed in-volume-prefix issue once cursor is excluded"
unset GH_OPEN_ISSUES

# --- 18. observe-to-close: xai-oauth unwired kept while seat-caps still missing the row ---
# Live #1268 class: the canary-filed ticket stays open while the wire is
# absent. base_caps has no providers.xai-oauth, so signal_still_active
# must return active and observe-to-close must keep the issue.
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
base_caps; base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: xai-oauth unwired\n' \
  '[{number: 1268, title: "volume lane order: wire xai-oauth into seat-caps", body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario18: xai detector tick must stay green, got rc=$env_rc ($env_out)"
grep -q 'observe-to-close: keep #1268' <<<"$env_out" \
  || fail "scenario18: must keep #1268 while still unwired ($env_out)"
if [[ -s "$GH_CLOSE_LOG" ]] && grep -q '1268' "$GH_CLOSE_LOG"; then
    fail "scenario18: must NOT call issue close on #1268 while unwired (log=$(cat "$GH_CLOSE_LOG"))"
fi
ok "scenario18: xai-oauth unwired kept open while seat-caps still missing the row"
unset GH_OPEN_ISSUES

# --- 18b. observe-to-close: xai-oauth unwired CLOSES once the seat-caps row lands ---
# The mechanical fix for live #1268. PR #1257 (and #1163) put providers.xai-oauth
# on main; observe-to-close must now drain the canary-filed ticket instead of
# hard-coding the signal as always-active. Hand-filed #1163 (no marker) is
# ignored by parse_marker and stays on its own close path.
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
base_caps
jq '.providers["xai-oauth"] = {
  "cap": 1,
  "class": "prepaid-quota",
  "quota_window": "weekly",
  "models": { "grok-4.6": 1, "grok-4.5": 1 }
} | .prepaid_providers_in_order += ["xai-oauth"]' \
  "$scratch/seat-caps.json" >"$scratch/seat-caps.tmp" \
  && mv "$scratch/seat-caps.tmp" "$scratch/seat-caps.json"
base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: xai-oauth unwired\n' \
  '[{number: 1268, title: "volume lane order: wire xai-oauth into seat-caps", body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario18b: wired xai must exit 0, got rc=$env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #1268' <<<"$env_out" \
  || fail "scenario18b: must close #1268 once xai-oauth is wired ($env_out)"
ok "scenario18b: xai-oauth unwired closed once seat-caps row is present (fleet-ops#1268)"
unset GH_OPEN_ISSUES

# --- 18c. observe-to-close: xai-oauth cap-zero-stale-reason closes when cap>0 ---
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
base_caps
jq '.providers["xai-oauth"] = {
  "cap": 1,
  "class": "prepaid-quota",
  "models": { "grok-4.6": 1 }
}' "$scratch/seat-caps.json" >"$scratch/seat-caps.tmp" \
  && mv "$scratch/seat-caps.tmp" "$scratch/seat-caps.json"
base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: xai-oauth cap-zero-stale-reason\n' \
  '[{number: 1300, title: "volume lane order: xai-oauth cap=0 needs a fresh dated reason", body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario18c: cap>0 must exit 0, got rc=$env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #1300' <<<"$env_out" \
  || fail "scenario18c: must close #1300 once cap>0 ($env_out)"
ok "scenario18c: xai-oauth cap-zero-stale-reason closed once cap is raised"
unset GH_OPEN_ISSUES

# --- 18d. observe-to-close: xai-oauth cap-zero-stale-reason kept when cap=0 + stale reason ---
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
base_caps
jq '.providers["xai-oauth"] = {
  "cap": 0,
  "class": "prepaid-quota",
  "reason": "parked 2026-08-20 before the revival",
  "models": {}
}' "$scratch/seat-caps.json" >"$scratch/seat-caps.tmp" \
  && mv "$scratch/seat-caps.tmp" "$scratch/seat-caps.json"
# models.json still has xai-oauth so the detector would re-file; for
# observe-to-close we only care that the open ticket stays open.
base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: xai-oauth cap-zero-stale-reason\n' \
  '[{number: 1301, title: "volume lane order: xai-oauth cap=0 needs a fresh dated reason", body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
# Detector will also file (or dedup) on this tick; exit must stay 0.
[[ "$env_rc" == "0" ]] || fail "scenario18d: detector tick must stay green, got rc=$env_rc ($env_out)"
grep -q 'observe-to-close: keep #1301' <<<"$env_out" \
  || fail "scenario18d: must keep #1301 while cap=0 + stale reason ($env_out)"
if [[ -s "$GH_CLOSE_LOG" ]] && grep -q '1301' "$GH_CLOSE_LOG"; then
    fail "scenario18d: must NOT close #1301 while signal active (log=$(cat "$GH_CLOSE_LOG"))"
fi
ok "scenario18d: xai-oauth cap-zero-stale-reason kept while cap=0 + stale reason"
unset GH_OPEN_ISSUES

# --- 19. observe-to-close: issue without the marker is ignored ---
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
base_caps; base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
# Body has no marker; canary must not close it even though seat-caps is clean.
jq -n '[{number: 42, title: "unrelated open issue", body: "no marker here"}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario19: clean tick must exit 0, got rc=$env_rc ($env_out)"
if [[ -s "$GH_CLOSE_LOG" ]]; then
    fail "scenario19: must not close issues without the marker (log=$(cat "$GH_CLOSE_LOG"))"
fi
ok "scenario19: issue without marker is ignored by observe-to-close"
unset GH_OPEN_ISSUES

# --- 20. observe-to-close: FLEET_VOLUME_ORDER_FILE=0 disables both file and close ---
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
base_caps; base_models; base_seat_lib
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: volume_providers_in_order missing\n' \
  '[{number: 1269, title: "volume lane order: volume_providers_in_order missing", body: $b}]' >"$GH_OPEN_ISSUES"
FLEET_VOLUME_ORDER_FILE=0 run_canary
[[ "$env_rc" == "0" ]] || fail "scenario20: clean tick must exit 0, got rc=$env_rc ($env_out)"
if [[ -s "$GH_CLOSE_LOG" ]]; then
    fail "scenario20: must not close when FLEET_VOLUME_ORDER_FILE=0 (log=$(cat "$GH_CLOSE_LOG"))"
fi
if grep -q 'issue close' "$gh_log"; then
    fail "scenario20: must not even call gh when FLEET_VOLUME_ORDER_FILE=0 (gh=$(cat "$gh_log"))"
fi
ok "scenario20: FLEET_VOLUME_ORDER_FILE=0 disables both file and close"
unset GH_OPEN_ISSUES

# --- 21. observe-to-close: seat-lib wire issue is closed once seat-lib has the markers ---
: >"$gh_log"; : >"$triage"; : >"$GH_CLOSE_LOG"
base_caps; base_models
# Stub seat-lib WITHOUT volume markers, then run the canary; the gate
# fails and the canary files a no-volume-bucket issue. Then we swap
# the stub to one WITH the markers, set up a matching open issue, and
# run the canary again: gate passes, observe-to-close must drain.
write_seat_lib <<'SH'
#!/usr/bin/env bash
SEAT_FREE_ORDER=""
SH
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nvolume-lane-order-canary: seat-lib no-volume-bucket\n' \
  '[{number: 1293, title: "volume lane order: pick_seat missing volume_seats bucket", body: $b}]' >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario21a: missing seat-lib wire must fail, got rc=$env_rc"
# Now wire seat-lib; the canary must close #1293.
base_seat_lib
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario21b: wired seat-lib must exit 0, got rc=$env_rc ($env_out)"
grep -q 'observe-to-close: CLOSED issue #1293' <<<"$env_out" \
  || fail "scenario21b: must close #1293 once seat-lib is wired ($env_out)"
ok "scenario21: seat-lib wire issue closed once pick_seat carries the volume markers"
unset GH_OPEN_ISSUES

ok "fleet-volume-lane-order-canary: missing, mismatch, cap, models, cursor, seat-lib wire, xai detector, dedup, production clean, heartbeat, pick_seat, observe-to-close"
