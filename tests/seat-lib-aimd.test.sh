#!/usr/bin/env bash
# tests/seat-lib-aimd.test.sh
#
# fleet-ops#217 / #424: AIMD learned caps. Declared cap is the FLOOR;
# pick_seat may admit cap+1 when zero provider errors + RAM headroom +
# room below max_probe_ceiling, and backs off to ~0.5x on a fresh 429.
# Learned ceiling persists in learned-caps.json with evidence and decays
# toward re-probing after the bench expires. hard_ceiling rows never probe.
#
# Acceptance (stubbed), proven here — including one cap RAISE after re-land
# (invariant 1), not a leftover audit line from 2026-08-26:
#   1. green window -> cap+1 admitted (additive probe) + learned state + audit.
#   2. injected 429 -> halve + bench + audit line (multiplicative backoff).
#   3. metered provider never probes above declared max (max_probe_ceiling).
#   4. hard_ceiling: never probes, never backs off below declared.
#   5. bench expiry -> decay toward the floor (re-probe from declared).
#
# Pure unit test: scratch models.json + seat-caps.json + ledger + learned-caps
# + active-seats registry. No pi, no real fleet, no network. systemd probing
# is disabled (PI_SEAT_LIB_CHECK_SYSTEMD=0) so seeded registry files survive.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-lib-aimd.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Three providers cover the AIMD matrix:
#   commandcode — free, cap=2, max_probe_ceiling=4 (probes freely)
#   minimax     — metered, cap=2, max_probe_ceiling=2 (never above declared)
#   devin       — prepaid, cap=4, hard_ceiling=true (never probes/backoffs)
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "commandcode": {
      "models": [ { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0 } } ]
    },
    "minimax": {
      "models": [ { "id": "MiniMax-M3", "cost": { "input": 0 } } ]
    },
    "devin": {
      "models": [ { "id": "glm-5-2", "cost": { "input": 0 } } ]
    }
  }
}
JSON

# ram_gb_per_worker tiny so ram_governor_cap returns a huge number -> RAM
# headroom is always available (the probe's headroom gate is satisfied).
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 0.01,
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "commandcode": { "cap": 2, "class": "free", "max_probe_ceiling": 4, "models": { "deepseek/deepseek-v4-flash": 4 } },
    "minimax": { "cap": 2, "class": "metered", "max_probe_ceiling": 2, "models": { "MiniMax-M3": 2 } },
    "devin": { "cap": 4, "class": "prepaid-quota", "hard_ceiling": true, "max_probe_ceiling": 4, "models": { "glm-5-2": 4 } }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_CREDENTIAL_PRECHECK=0

state="$scratch/state"
ledger="$scratch/ledger"
learned="$scratch/learned-caps.json"
audit="$scratch/learned-caps-audit.log"
export PI_PACKET_STATE="$state"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export LEARNED_CAPS_JSON="$learned"
export LEARNED_CAPS_AUDIT="$audit"
mkdir -p "$state" "$ledger" "$state/active-seats"

# Registry files MUST match pi-*.json (the _seat_live_registry_files glob).
seed_active() {
    local prov="$1" n="$2" i
    for (( i = 0; i < n; i++ )); do
        jq -nc --arg p "$prov" --arg m "seed" --arg u "pi-seed-$prov-$i" \
            '{provider:$p, model:$m, unit:$u, started_at:"2026-08-26T00:00:00Z"}' \
            > "$state/active-seats/pi-seed-$prov-$i.json"
    done
}

write_ledger() {
    local prov="$1" mdl="$2" hc="$3" observed="$4" usable="$5" bench="${6:-}"
    local f
    f=$(bash -c 'source "$0" 2>/dev/null; seat_ledger_path "$1" "$2"' "$lib" "$prov" "$mdl")
    mkdir -p "$(dirname "$f")"
    if [[ -n "$bench" ]]; then
        jq -nc --arg p "$prov" --arg m "$mdl" --arg hc "$hc" --arg obs "$observed" \
            --arg ua "$usable" --arg bu "$bench" \
            '{provider:$p, model:$m, health_class:$hc, seat_dead:false, observed_at:$obs, usable_at:$ua, bench_until:$bu}' > "$f"
    else
        jq -nc --arg p "$prov" --arg m "$mdl" --arg hc "$hc" --arg obs "$observed" \
            --arg ua "$usable" \
            '{provider:$p, model:$m, health_class:$hc, seat_dead:false, observed_at:$obs, usable_at:$ua}' > "$f"
    fi
}

run() {
    bash -c 'source "$0"; "$@"' "$lib" "$@"
}

# --- invariant 1: green window -> cap+1 admitted (additive probe) ---------
rm -f "$state/active-seats"/*.json "$ledger"/*.json "$learned" "$audit"
write_ledger commandcode "deepseek/deepseek-v4-flash" healthy "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "null"
write_ledger devin "glm-5-2" credentials_bad "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "null"
seed_active commandcode 2
set +e
pick_out=$(run pick_seat "" "" 0 2>/dev/null)
pick_rc=$?
set -e
[[ "$pick_rc" == "0" ]] || fail "green-window: expected a pick (probe admitted), got rc=$pick_rc"
echo "$pick_out" | grep -q "^commandcode" || fail "green-window: expected commandcode probe pick, got: $pick_out"
[[ -f "$learned" ]] || fail "green-window: learned-caps.json must be written on probe"
lc=$(jq -r '.providers.commandcode.learned_cap // "none"' "$learned")
lr=$(jq -r '.providers.commandcode.last_result // "none"' "$learned")
[[ "$lc" == "3" ]] || fail "green-window: learned_cap must be 3 (cap+1 probe), got $lc"
[[ "$lr" == "probe" ]] || fail "green-window: last_result must be probe, got $lr"
[[ -f "$audit" ]] || fail "green-window: audit log must be written on probe"
grep -q "aimd commandcode: learned_cap=3 result=probe" "$audit" \
  || fail "green-window: audit line must record the probe: $(cat "$audit")"
ok "green window: cap+1 probe admitted, learned_cap=3, audit line written"

# --- invariant 2: injected 429 -> halve + bench + audit (backoff) ---------
rm -f "$state/active-seats"/*.json "$ledger"/*.json "$learned" "$audit"
future=$(date -u -d "+30 minutes" +%Y-%m-%dT%H:%M:%SZ)
write_ledger commandcode "deepseek/deepseek-v4-flash" rate_limited "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$future"
set +e
eff=$(run effective_provider_cap commandcode 2>/dev/null)
set -e
[[ "$eff" == "1" ]] || fail "backoff: effective cap must halve 2->1 on fresh 429, got $eff"
[[ -f "$learned" ]] || fail "backoff: learned-caps.json must be written on backoff"
lc=$(jq -r '.providers.commandcode.learned_cap // "none"' "$learned")
lr=$(jq -r '.providers.commandcode.last_result // "none"' "$learned")
bu=$(jq -r '.providers.commandcode.bench_until // "none"' "$learned")
[[ "$lc" == "1" ]] || fail "backoff: learned_cap must be 1 (halved), got $lc"
[[ "$lr" == "backoff" ]] || fail "backoff: last_result must be backoff, got $lr"
[[ "$bu" != "none" && "$bu" != "null" ]] || fail "backoff: bench_until must be set, got $bu"
grep -q "aimd commandcode: learned_cap=1 result=backoff" "$audit" \
  || fail "backoff: audit line must record the backoff: $(cat "$audit")"
seed_active commandcode 1
set +e
probe_rc=0
run _aimd_probe_admitted commandcode 1 1 2>/dev/null || probe_rc=$?
set -e
[[ "$probe_rc" != "0" ]] || fail "backoff: a 429'd provider must not admit a probe"
ok "injected 429: cap halved 2->1, bench_until set, audit line written, no probe admitted"

# --- invariant 3: metered provider never probes above declared max --------
rm -f "$state/active-seats"/*.json "$ledger"/*.json "$learned" "$audit"
write_ledger minimax "MiniMax-M3" healthy "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "null"
seed_active minimax 2
set +e
probe_rc=0
run _aimd_probe_admitted minimax 2 2 2>/dev/null || probe_rc=$?
set -e
[[ "$probe_rc" != "0" ]] || fail "metered: minimax must not admit a probe above declared cap (ceiling=2=declared)"
jq -nc '{providers: {minimax: {learned_cap: 99, last_result: "probe", last_at: "2026-08-26T00:00:00Z"}}}' > "$learned"
set +e
eff=$(run effective_provider_cap minimax 2>/dev/null)
set -e
[[ "$eff" == "2" ]] || fail "metered: effective cap must clamp to max_probe_ceiling=2, got $eff"
ok "metered: never probes above declared max (ceiling=2), learned cap clamped"

# --- invariant 4: hard_ceiling — never probes, never backs off ------------
rm -f "$state/active-seats"/*.json "$ledger"/*.json "$learned" "$audit"
write_ledger devin "glm-5-2" rate_limited "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$future"
set +e
eff=$(run effective_provider_cap devin 2>/dev/null)
set -e
[[ "$eff" == "4" ]] || fail "devin hard_ceiling: effective cap must stay 4 even on 429, got $eff"
[[ ! -f "$learned" ]] || fail "devin hard_ceiling: must NOT write learned state (no probe, no backoff)"
seed_active devin 4
set +e
probe_rc=0
run _aimd_probe_admitted devin 4 4 2>/dev/null || probe_rc=$?
set -e
[[ "$probe_rc" != "0" ]] || fail "devin hard_ceiling: must not admit a probe"
ok "devin hard_ceiling: cap stays 4 on 429, no probe, no learned state"

# --- invariant 5: bench expiry -> decay toward the floor ------------------
rm -f "$state/active-seats"/*.json "$ledger"/*.json
past=$(date -u -d "-10 minutes" +%Y-%m-%dT%H:%M:%SZ)
jq -nc --arg bu "$past" '{providers: {commandcode: {learned_cap: 1, last_result: "backoff", bench_until: $bu, last_at: "2026-08-26T00:00:00Z"}}}' > "$learned"
: > "$audit"
set +e
eff=$(run effective_provider_cap commandcode 2>/dev/null)
set -e
[[ "$eff" == "2" ]] || fail "decay: effective cap must return to declared=2 after bench expiry, got $eff"
lr=$(jq -r '.providers.commandcode.last_result // "none"' "$learned")
[[ "$lr" == "decay" ]] || fail "decay: last_result must be decay, got $lr"
grep -q "aimd commandcode: learned_cap=2 result=decay" "$audit" \
  || fail "decay: audit line must record the decay: $(cat "$audit")"
ok "bench expiry: decays to declared=2 (re-probe from floor), audit line written"

echo "All AIMD invariants passed."
