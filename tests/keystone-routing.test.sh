#!/usr/bin/env bash
# tests/keystone-routing.test.sh
#
# Proves fleet-ops#1133: reliability-first routing for keystone packets.
#
#   1. packet_difficulty reads `difficulty: keystone` (case-insensitive).
#   2. Unmarked packets fall back to task_weight (heavy/light).
#   3. Cost-first (unmarked, need_capable=1) still picks the free lane first.
#   4. Keystone picks the strongest class first (prepaid, not commandcode).
#   5. Two strikes on a keystone packet return empty (senior conference).
#   6. One strike still returns a different capable seat.
#   7. pi-issue-run does not reset tried-seats on a keystone two-strike.
#
# Hosted by tests/seat-lib.test.sh (workers cannot add a ci.yml line).
# Offline. Scratch models/caps so live seat-caps cannot leak.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch=$(mktemp -d -t keystone-routing.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "commandcode": {
      "models": [
        { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0 }, "contextWindow": 200000 }
      ]
    },
    "cursor": {
      "models": [
        { "id": "cursor-grok-4.6-high", "cost": { "input": 0 }, "contextWindow": 200000 },
        { "id": "composer-2.5", "cost": { "input": 0 }, "contextWindow": 128000 }
      ]
    },
    "minimax": {
      "models": [
        { "id": "MiniMax-M3", "cost": { "input": 0.30 }, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["commandcode"],
  "prepaid_providers_in_order": ["cursor"],
  "providers": {
    "commandcode": { "cap": 2, "class": "free", "models": { "deepseek/deepseek-v4-flash": 2 } },
    "cursor": { "cap": 1, "class": "prepaid-quota", "models": { "cursor-grok-4.6-high": 1, "composer-2.5": 1 } },
    "minimax": { "cap": 2, "class": "metered", "models": { "MiniMax-M3": 2 } }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_SEAT_CREDENTIAL_PRECHECK=0
export QUALITY_ROUTING_JSON="$scratch/missing-quality.json"
export QUALITY_SCOREBOARD_JSON="$scratch/missing-scoreboard.json"

pick() {
    local capable="${1:-0}" difficulty="${2:-light}" tried="${3:-}"
    export PI_PACKET_STATE="$scratch/state-$capable-$difficulty-$$"
    export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
    mkdir -p "$PI_PACKET_STATE" "$PI_SEAT_HEALTH_LEDGER_DIR"
    if [[ -n "$tried" ]]; then
        bash -c 'source "$0"; load_seat_caps; pick_seat "" "" "'"$capable"'" "'"$tried"'" "'"$difficulty"'"' "$lib" 2>/dev/null
    else
        bash -c 'source "$0"; load_seat_caps; pick_seat "" "" "'"$capable"'" "" "'"$difficulty"'"' "$lib" 2>/dev/null
    fi
}

# --- 1. packet_difficulty marker ------------------------------------------
pkt="$scratch/pkt-keystone.txt"
printf 'difficulty: keystone\nImplement the completion-canary.\n' >"$pkt"
got=$(bash -c 'source "$0"; packet_difficulty "$1"' "$lib" "$pkt")
[[ "$got" == "keystone" ]] || fail "1: expected keystone, got $got"
ok "1: packet_difficulty detects difficulty: keystone"

pkt_upper="$scratch/pkt-upper.txt"
printf 'Difficulty: KEYSTONE\ncritical build\n' >"$pkt_upper"
got=$(bash -c 'source "$0"; packet_difficulty "$1"' "$lib" "$pkt_upper")
[[ "$got" == "keystone" ]] || fail "1b: case-insensitive expected keystone, got $got"
ok "1b: packet_difficulty is case-insensitive"

pkt_flag="$scratch/pkt-flag.txt"
printf 'keystone: true\n' >"$pkt_flag"
got=$(bash -c 'source "$0"; packet_difficulty "$1"' "$lib" "$pkt_flag")
[[ "$got" == "keystone" ]] || fail "1c: keystone: true expected keystone, got $got"
ok "1c: packet_difficulty accepts keystone: true"

# --- 2. fallback to task_weight -------------------------------------------
pkt_light="$scratch/pkt-light.txt"
printf 'hello probe\n' >"$pkt_light"
got=$(bash -c 'source "$0"; packet_difficulty "$1"' "$lib" "$pkt_light")
[[ "$got" == "light" ]] || fail "2: unmarked small packet expected light, got $got"
ok "2: unmarked packet falls back to task_weight (light)"

got=$(bash -c 'source "$0"; packet_difficulty "$1"' "$lib" "$scratch/no-such-packet")
[[ "$got" == "light" ]] || fail "2b: missing file expected light, got $got"
ok "2b: missing file returns light"

pkt_explicit_light="$scratch/pkt-explicit-light.txt"
printf 'difficulty: light\n' >"$pkt_explicit_light"
got=$(bash -c 'source "$0"; packet_difficulty "$1"' "$lib" "$pkt_explicit_light")
[[ "$got" == "light" ]] || fail "2c: explicit light expected light, got $got"
ok "2c: explicit difficulty: light"

# --- 3. cost-first unmarked still picks free first ------------------------
cost=$(pick 1 light) || fail "3: cost-first heavy pick must succeed"
[[ "$cost" == "commandcode	deepseek/deepseek-v4-flash" ]] \
  || fail "3: cost-first heavy expected commandcode (free first), got: $cost"
ok "3: unmarked heavy still cost-first (commandcode/free first)"

# --- 4. keystone picks prepaid grok, not free flash -----------------------
key=$(pick 1 keystone) || fail "4: keystone pick must succeed"
[[ "$key" == "cursor	cursor-grok-4.6-high" ]] \
  || fail "4: keystone expected cursor-grok-4.6-high, got: $key"
ok "4: keystone routes to prepaid grok, not commandcode"

# --- 5. two strikes escalate ----------------------------------------------
tried2="$scratch/tried-2.txt"
printf 'cursor/cursor-grok-4.6-high\nminimax/MiniMax-M3\n' >"$tried2"
set +e
two=$(pick 1 keystone "$tried2")
two_rc=$?
set -e
[[ "$two_rc" == "1" ]] || fail "5: two-strike expected rc=1, got $two_rc"
[[ -z "$two" ]] || fail "5: two-strike expected empty seat, got: $two"
ok "5: keystone two-strike returns empty (senior conference)"

# --- 6. one strike still picks --------------------------------------------
tried1="$scratch/tried-1.txt"
printf 'cursor/cursor-grok-4.6-high\n' >"$tried1"
one=$(pick 1 keystone "$tried1") || fail "6: one-strike keystone must still pick"
[[ "$one" == "minimax	MiniMax-M3" ]] \
  || fail "6: after grok strike expected metered MiniMax-M3 (free still last), got: $one"
ok "6: keystone one-strike walks metered before free"

# --- 7. pi-issue-run keeps tried-seats on keystone two-strike -------------
export HOME="$scratch/home"
mkdir -p "$HOME"
STATE_DIR="$scratch/issue-state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
ISSUES_DIR="$scratch/issues"
mkdir -p "$ISSUES_DIR"
export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
export PI_ISSUES_DIR="$ISSUES_DIR"
export PI_PACKET_SEAT_LIB="$lib"
export PI_BIN="$scratch/pi-stub"
printf '#!/usr/bin/env bash\necho should-not-run\nexit 1\n' >"$PI_BIN"
chmod +x "$PI_BIN"

inst="keystone-inst"
printf 'difficulty: keystone\nImplement the keystone build.\n' >"$ISSUES_DIR/${inst}.in"
tried="$STATE_DIR/attempts/pi-issue-${inst}.tried-seats"
printf 'cursor/cursor-grok-4.6-high\nminimax/MiniMax-M3\n' >"$tried"
[[ -s "$tried" ]] || fail "7: precondition tried-file must be non-empty"

set +e
bash "$repo_root/bin/pi-issue-run" "$inst" >/dev/null 2>&1
issue_rc=$?
set -e
[[ "$issue_rc" == 1 ]] || fail "7: pi-issue-run keystone two-strike expected rc=1, got $issue_rc"
[[ -s "$tried" ]] || fail "7: pi-issue-run RESET tried-seats on keystone two-strike (would retry cheap lanes)"
got_lines=$(grep -c . "$tried")
[[ "$got_lines" == "2" ]] || fail "7: tried-seats should stay at 2 lines, got $got_lines"
ok "7: pi-issue-run keeps tried-seats on keystone two-strike"

# --- contract: nested under the CI host -----------------------------------
grep -Fq 'bash "$here/keystone-routing.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "seat-lib.test.sh hosts this file"

grep -Fq "printf 'difficulty: keystone" "$repo_root/prompts/intake.md" \
  || fail "prompts/intake.md must write difficulty: keystone as packet line 1"
grep -Fq '} > /home/nish/.local/state/pi-issues/<repo>-N.in' "$repo_root/prompts/intake.md" \
  || fail "prompts/intake.md must still overwrite the packet with >"
if grep -qE 'worker\.md.*>> /home/nish/.local/state/pi-issues' "$repo_root/prompts/intake.md"; then
  fail "prompts/intake.md must not append (>>) worker.md onto the packet"
fi
ok "intake.md writes the keystone marker with overwrite, not append"

echo "OK: keystone-routing: marker, cost-first unchanged, strongest-first, two-strike"
exit 0
