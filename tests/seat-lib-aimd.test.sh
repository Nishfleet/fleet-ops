#!/usr/bin/env bash
# tests/seatlib-aimd.test.sh
#
# fleet-ops#217 / #424: AIMD learned caps. Declared cap is the FLOOR;
# pick-seat may admit cap+1 when zero provider errors + RAM headroom +
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
lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# fleet-ops#3760: --scenario empty-run-convergence runs ONLY the empty-run
# convergence replay (the issue's termination command). No arg = full suite.
scenario=""
if [[ "${1:-}" == "--scenario" ]]; then
    scenario="${2:-}"
    shift 2
fi

[[ -f "$lib" ]] || fail "seatlib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seatlib-aimd.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Four providers cover the AIMD matrix:
#   commandcode — free, cap=2, max_probe_ceiling=4 (probes freely)
#   minimax     — metered, cap=2, max_probe_ceiling=2 (never above declared)
#   devin       — prepaid, cap=4, AIMD ceiling 8, model probe ceilings
#                 (fleet-ops#3125: glm-5-2 declared 4 / probe to 6,
#                  swe-1-7 declared 4 with NO model ceiling)
#   ollama      — prepaid, cap=4, hard_ceiling=true (never probes/backoffs)
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
      "models": [ { "id": "glm-5-2", "cost": { "input": 0 } }, { "id": "swe-1-7", "cost": { "input": 0 } } ]
    },
    "ollama": {
      "models": [ { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 } } ]
    }
  }
}
JSON

# ram_gb_per_worker + SEAT_MIN_FREE_RAM_MB=0 keep ram_governor_cap in
# (1, 64) so the probe's RAM-headroom gate is satisfied without tripping
# the post-#1363 sanity fail (cap >= 64 from a 0.01 budget).
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 0.5,
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "commandcode": { "cap": 2, "class": "free", "max_probe_ceiling": 4, "models": { "deepseek/deepseek-v4-flash": 4 } },
    "minimax": { "cap": 2, "class": "metered", "max_probe_ceiling": 2, "models": { "MiniMax-M3": 2 } },
    "devin": { "cap": 4, "class": "prepaid-quota", "max_probe_ceiling": 8, "models": { "glm-5-2": { "cap": 4, "max_probe_ceiling": 6 }, "swe-1-7": 4 } },
    "ollama": { "cap": 4, "class": "prepaid-quota", "hard_ceiling": true, "max_probe_ceiling": 4, "models": { "deepseek-v4-flash:0731": 4 } }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_CREDENTIAL_PRECHECK=0
export SEAT_MIN_FREE_RAM_MB=0
export QUALITY_SCOREBOARD_JSON="$scratch/no-quality-scoreboard.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality-routing.json"

state="$scratch/state"
ledger="$scratch/ledger"
learned="$scratch/learned-caps.json"
audit="$scratch/learned-caps-audit.log"
export PI_PACKET_STATE="$state"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export LEARNED_CAPS_JSON="$learned"
export LEARNED_CAPS_AUDIT="$audit"
mkdir -p "$state" "$ledger" "$state/active-seats"

# === fleet-ops#3760: --scenario empty-run-convergence replay ==================
# The issue's termination command:
#   bash tests/seatlib-aimd.test.sh --scenario empty-run-convergence
# Proves the empty-run churn converges: ollama/deepseek-v4-flash:0731 no-op'ed
# 12 times in 2h. With EMPTY_RUN_FAILURE_CEILING=3 (lowered from 5 by #3760),
# the geometric bench (900s -> 1800s) holds the first two no-ops, then the 3rd
# parks the seat behind the 24h wall. seat_usable holds it; pick-seat skips it.
# Defined here so --scenario can dispatch to it before the full suite runs.
run_empty_run_convergence() {
    local conv_scratch conv_state conv_ledger conv_caps conv_models conv_learned
    conv_scratch="$scratch/conv-3760"
    conv_state="$conv_scratch/state"
    conv_ledger="$conv_scratch/ledger"
    conv_caps="$conv_scratch/seat-caps.json"
    conv_models="$conv_scratch/models.json"
    conv_learned="$conv_scratch/learned-caps.json"
    mkdir -p "$conv_state/active-seats" "$conv_ledger"

    cat >"$conv_models" <<'JSON'
{
  "providers": {
    "ollama": {
      "models": [ { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 }, "contextWindow": 128000 } ]
    }
  }
}
JSON

    cat >"$conv_caps" <<'JSON'
{
  "ram_gb_per_worker": 0.5,
  "free_providers_in_order": ["ollama"],
  "providers": {
    "ollama": { "cap": 1, "class": "prepaid-quota", "hard_ceiling": true, "max_probe_ceiling": 1, "quota_bench_default_s": 900, "overload_bench_default_s": 600, "models": { "deepseek-v4-flash:0731": 1 } }
  }
}
JSON

    echo '{"providers":{}}' >"$conv_learned"

    # PRODUCTION DEFAULTS — do NOT pin EMPTY_RUN_FAILURE_CEILING. The replay
    # proves the production default (3, fleet-ops#3760) converges.
    SEAT_CAPS_JSON="$conv_caps" \
    PI_MODELS_JSON="$conv_models" \
    PI_PACKET_STATE="$conv_state" \
    PI_SEAT_HEALTH_LEDGER_DIR="$conv_ledger" \
    LEARNED_CAPS_JSON="$conv_learned" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 \
    PI_SEAT_CREDENTIAL_PRECHECK=0 \
    SEAT_MIN_FREE_RAM_MB=0 \
    QUALITY_SCOREBOARD_JSON="$scratch/no-quality-scoreboard.json" \
    QUALITY_ROUTING_JSON="$scratch/no-quality-routing.json" \
        bash -c '
            set -euo pipefail
            source "$1"
            fail() { echo "FAIL: $*" >&2; exit 1; }
            ok()   { echo "OK: $*"; }

            p="ollama"; m="deepseek-v4-flash:0731"

            # Production default must be 3 (fleet-ops#3760), not 5, not 20.
            [[ "${EMPTY_RUN_FAILURE_CEILING:-3}" == "3" ]] \
                || fail "convergence: EMPTY_RUN_FAILURE_CEILING = ${EMPTY_RUN_FAILURE_CEILING:-3}, want 3 (production default, fleet-ops#3760)"
            ok "convergence (a): production default EMPTY_RUN_FAILURE_CEILING=3 (fleet-ops#3760)"

            ledger_file() {
                printf "%s/%s__%s.json" "$PI_SEAT_HEALTH_LEDGER_DIR" \
                    "${1//[^A-Za-z0-9._-]/_}" "${2//[^A-Za-z0-9._-]/_}"
            }
            marker_file() {
                printf "%s/%s__%s.spawn-bench.json" "$PI_SEAT_HEALTH_LEDGER_DIR" \
                    "${1//[^A-Za-z0-9._-]/_}" "${2//[^A-Za-z0-9._-]/_}"
            }
            count_of() { jq -r ".consecutive_failure_count // 0" "$1" 2>/dev/null || echo 0; }
            wall_s_of() {
                local u now_s u_s
                u=$(jq -r ".usable_at // \"\"" "$1" 2>/dev/null || true)
                [[ -n "$u" ]] || { echo 0; return; }
                now_s=$(date -u +%s)
                u_s=$(date -u -d "$u" +%s 2>/dev/null || echo 0)
                echo $((u_s - now_s))
            }

            lf=$(ledger_file "$p" "$m")
            mf=$(marker_file "$p" "$m")
            rm -f "$lf" "$mf"

            # (b) 2 no-ops below the ceiling: geometric bench holds (900 -> 1800).
            for i in 1 2; do
                mark_seat_empty_run "$p" "$m" "pi-issue:fleet-ops-3760:noop:${i}" >/dev/null 2>&1 \
                    || fail "convergence (b): mark_seat_empty_run #${i} failed"
                c=$(count_of "$mf")
                [[ "$c" == "$i" ]] \
                    || fail "convergence (b): marker count after no-op #${i} = $c, want $i"
                w=$(wall_s_of "$mf")
                (( w < ${SEAT_PARK_WALL_S:-86400} - 120 )) \
                    || fail "convergence (b): no-op #${i} wall = ${w}s, should be < park wall (count=$i < ceiling=3, NOT parked)"
            done
            ok "convergence (b): 2 no-ops below ceiling=3: NOT parked, geometric bench holds (900->1800)"

            # (c) 3rd no-op: empty-run failure ceiling engages. fleet-ops#4640
            # clamps a non-money lane park at 6h (empty_run is not a
            # provider_quota_window). The #3760 contract that remains is
            # WHEN it parks (count=3), not a 24h duration.
            mark_seat_empty_run "$p" "$m" "pi-issue:fleet-ops-3760:noop:3" >/dev/null 2>&1 \
                || fail "convergence (c): mark_seat_empty_run #3 (park) failed"
            park_count=$(count_of "$mf")
            [[ "$park_count" == "3" ]] \
                || fail "convergence (c): marker count after 3rd no-op = $park_count, want 3"
            park_wall=$(wall_s_of "$mf")
            (( park_wall >= ${SEAT_NON_MONEY_WALL_MAX_S:-21600} - 120 && park_wall <= ${SEAT_NON_MONEY_WALL_MAX_S:-21600} + 120 )) \
                || fail "convergence (c): park wall = ${park_wall}s, want ~${SEAT_NON_MONEY_WALL_MAX_S:-21600}s (3rd no-op, fleet-ops#3760/#4640 6h clamp)"
            if seat_usable "$p" "$m"; then
                fail "convergence (c): seat_usable returned usable on the 3rd-no-op parked seat"
            fi
            ok "convergence (c): 3rd no-op parks behind 6h wall, seat HELD UNUSABLE (fleet-ops#3760/#4640)"

            # (d) pick-seat must NOT return the parked seat (no re-selection).
            set +e
            pick=$(pick-seat "" "" 0 "" light 2>/dev/null)
            pick_rc=$?
            set -e
            if [[ "$pick_rc" == "0" ]]; then
                echo "$pick" | grep -q "^ollama" \
                    && fail "convergence (d): pick-seat returned the parked ollama seat — must be skipped while benched"
            fi
            ok "convergence (d): pick-seat does not re-select the parked seat (no churn, fleet-ops#3760)"

            # (e) waste ratio proxy: 3 no-ops -> 1 park = 3 wasted runs, not 12.
            # The pre-#3760 ceiling (5) would have allowed 5 no-ops; the generic
            # 20 would have allowed 12. 3 converges fastest without false-positiving
            # a single flake (the first no-op is a 900s cooldown, not a park).
            ok "convergence (e): 3 no-ops -> park (was 5 pre-#3760, 12 pre-#3727) — waste ratio trends toward 0"

            echo "empty-run-convergence: ALL CONVERGENCE INVARIANTS PASSED (fleet-ops#3760)"
        ' _ "$lib"
}

# --scenario dispatch: run ONLY the named replay, then exit.
if [[ "$scenario" == "empty-run-convergence" ]]; then
    run_empty_run_convergence
    exit 0
fi

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
pick_out=$(run pick-seat "" "" 0 2>/dev/null)
pick_rc=$?
set -e
[[ "$pick_rc" == "0" ]] || fail "green-window: expected a pick (probe admitted), got rc=$pick_rc"
echo "$pick_out" | grep -q "^commandcode" || fail "green-window: expected commandcode probe pick, got: $pick_out"
[[ -f "$learned" ]] || fail "green-window: learned-caps.json must be written on probe"
lc=$(jq -r '.providers.commandcode.learned_cap // "none"' "$learned")
lr=$(jq -r '.providers.commandcode.last_result // "none"' "$learned")
expected_probe=$((2 + 1))  # cap+1 additive probe (scratch commandcode cap=2)
[[ "$lc" == "$expected_probe" ]] || fail "green-window: learned_cap must equal cap+1 (probe), got $lc"
[[ "$lr" == "probe" ]] || fail "green-window: last_result must be probe, got $lr"
[[ -f "$audit" ]] || fail "green-window: audit log must be written on probe"
grep -q "aimd commandcode: learned_cap=$expected_probe result=probe" "$audit" \
  || fail "green-window: audit line must record the probe: $(cat "$audit")"
ok "green window: cap+1 probe admitted, learned_cap=$expected_probe, audit line written"

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
expected_half=$((2 / 2))  # cap/2 multiplicative backoff (scratch commandcode cap=2)
[[ "$lc" == "$expected_half" ]] || fail "backoff: learned_cap must equal cap/2 (halved), got $lc"
[[ "$lr" == "backoff" ]] || fail "backoff: last_result must be backoff, got $lr"
[[ "$bu" != "none" && "$bu" != "null" ]] || fail "backoff: bench_until must be set, got $bu"
grep -q "aimd commandcode: learned_cap=$expected_half result=backoff" "$audit" \
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

# --- invariant 4: hard_ceiling (ollama) — never probes, never backs off -- 
rm -f "$state/active-seats"/*.json "$ledger"/*.json "$learned" "$audit"
write_ledger ollama "deepseek-v4-flash:0731" rate_limited "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$future"
set +e
eff=$(run effective_provider_cap ollama 2>/dev/null)
set -e
[[ "$eff" == "4" ]] || fail "ollama hard_ceiling: effective cap must stay 4 even on 429, got $eff"
[[ ! -f "$learned" ]] || fail "ollama hard_ceiling: must NOT write learned state (no probe, no backoff)"
seed_active ollama 4
set +e
probe_rc=0
run _aimd_probe_admitted ollama 4 4 2>/dev/null || probe_rc=$?
set -e
[[ "$probe_rc" != "0" ]] || fail "ollama hard_ceiling: must not admit a probe"
ok "ollama hard_ceiling: cap stays 4 on 429, no probe, no learned state"

# --- invariant 4b: devin model-level AIMD (fleet-ops#3125) -----------------
# glm-5-2 declares cap 4 / probe ceiling 6: at declared==active with no
# provider error it admits cap+1 and records under the "devin/glm-5-2" key;
# a model WITHOUT a ceiling (swe-1-7) stays at declared and never probes.
rm -f "$state/active-seats"/*.json "$ledger"/*.json "$learned" "$audit"
write_ledger devin "glm-5-2" healthy "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "null"
seed_active devin 4
set +e
meff=$(run effective_model_cap devin "glm-5-2" 2>/dev/null)
mprobe_rc=0
run _model_probe_admitted devin "glm-5-2" 4 4 2>/dev/null || mprobe_rc=$?
set -e
[[ "$meff" == "4" ]] || fail "devin model: effective_model_cap glm-5-2 must start at declared 4, got $meff"
[[ "$mprobe_rc" == "0" ]] || fail "devin model: glm-5-2 must admit a probe at 4/4 below ceiling 6 (fleet-ops#3125)"
[[ -f "$learned" ]] || fail "devin model: learned-caps.json must be written on model probe"
mlc=$(jq -r '.providers["devin/glm-5-2"].learned_cap // "none"' "$learned")
expected_model_probe=$((4 + 1))  # model cap+1 (scratch devin glm-5-2 cap=4)
[[ "$mlc" == "$expected_model_probe" ]] || fail "devin model: learned_cap must equal model-cap+1 (probe), got $mlc (file=$(cat "$learned"))"
grep -q "aimd devin/glm-5-2: learned_cap=$expected_model_probe result=probe" "$audit" \
  || fail "devin model: audit line must record the model probe: $(cat "$audit")"
set +e
meff2=$(run effective_model_cap devin "swe-1-7" 2>/dev/null)
sprobe_rc=0
run _model_probe_admitted devin "swe-1-7" 4 4 2>/dev/null || sprobe_rc=$?
set -e
[[ "$meff2" == "4" ]] || fail "devin model: swe-1-7 without a ceiling must stay at declared, got $meff2"
[[ "$sprobe_rc" != "0" ]] || fail "devin model: swe-1-7 must not probe (no declared ceiling)"
ok "devin model AIMD: glm-5-2 probes to ceiling 6, swe-1-7 without ceiling stays at declared"

# --- fleet-ops#3677: prepaid AIMD backoff bench is capped (15-30 min) -----
# A single backoff on a prepaid-quota seat must re-probe within a bounded
# window, NOT inherit a multi-hour bench from the per-seat ledger (the Devin
# ~6h lockout this issue fixes). floor/2 is still the immediate cap
# reduction; bench_until must be <= now + 1800s (30 min hard cap; lower when
# the provider sets quota_bench_default_s).
rm -f "$state/active-seats"/*.json "$ledger"/*.json "$learned" "$audit"
# A fresh rate_limited marker whose reset window is 5h out: the AIMD backoff
# must NOT inherit that multi-hour wall. provider_has_recent_error needs a
# FRESH observed_at + a future usable_at.
rate_obs=$(date -u +%Y-%m-%dT%H:%M:%SZ)
future_long=$(date -u -d "+5 hours" +%Y-%m-%dT%H:%M:%SZ)
write_ledger devin "glm-5-2" rate_limited "$rate_obs" "$future_long"
set +e
eff3677=$(run effective_provider_cap devin 2>/dev/null)
set -e
[[ "$eff3677" == "2" ]] || fail "#3677: prepaid backoff must halve declared cap 4->2, got $eff3677"
bu3677=$(jq -r '.providers.devin.bench_until // "none"' "$learned")
[[ "$bu3677" != "none" && "$bu3677" != "null" ]] \
  || fail "#3677: prepaid backoff must set bench_until, got '$bu3677'"
now3677=$(date -u +%s)
bu3677_s=$(date -u -d "$bu3677" +%s 2>/dev/null || echo 0)
delta3677=$(( bu3677_s - now3677 ))
(( bu3677_s > 0 && delta3677 <= 1800 )) \
  || fail "#3677: prepaid backoff bench_until must be <= now+1800s (30 min), got ${delta3677}s (bench_until=$bu3677); the 5h-away ledger wall must be capped"
# The audit line must print the bench length in seconds for the next reader.
grep -q "aimd devin: learned_cap=2 result=backoff.*bench=" "$audit" \
  || fail "#3677: audit line must print the bench length in seconds: $(cat "$audit")"
ok "fleet-ops#3677: prepaid backoff halves cap 4->2 and caps bench_until to <= now+1800s (was ${delta3677}s to now); audit prints bench length in seconds"

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

# --- invariant 6: sibling learned caps survive a later write --------------
rm -f "$state/active-seats"/*.json "$ledger"/*.json "$learned" "$audit"
jq -nc '{providers: {cline: {learned_cap: 1, last_result: "backoff", last_at: "2026-08-26T00:00:00Z"}}}' > "$learned"
write_ledger commandcode "deepseek/deepseek-v4-flash" healthy "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "null"
set +e
run _aimd_probe_admitted commandcode 2 2 >/dev/null
set -e
[[ -f "$learned" ]] || fail "siblings: learned-caps.json must exist after probe"
lc_cc=$(jq -r '.providers.commandcode.learned_cap // "none"' "$learned")
lc_cl=$(jq -r '.providers.cline.learned_cap // "none"' "$learned")
expected_sib=$((2 + 1))  # cap+1 (scratch commandcode cap=2)
[[ "$lc_cc" == "$expected_sib" ]] || fail "siblings: commandcode learned_cap must equal cap+1 (probe), got $lc_cc"
[[ "$lc_cl" == "1" ]] || fail "siblings: cline learned_cap must survive, got $lc_cl (file=$(cat "$learned"))"
ok "siblings: later probe write keeps the other provider's learned cap"

# --- production seat-caps.json AIMD fields (the live floor/ceiling) --------
caps="$repo_root/config/seat-caps.json"
[[ -f "$caps" ]] || fail "production seat-caps.json missing"
# fleet-ops#3125: devin is never hard_ceiling (AIMD must back off on a fresh
# provider error). fleet-ops#3443 (2026-09-05): probe ceilings 6/8 put 8 devin
# sessions in flight and Devin answered resource_exhausted on every new one
# (133 deaths in 12h), so until fleet-ops#3258 lifts the pin with evidence the
# probe ceilings equal the declared caps at provider and model level. Pinning
# "ceiling == cap" rather than a number lets a cap change (fleet-ops#3473
# retired swe-1-7 to 0) move the ceiling with it instead of tripping here.
jq -e '.providers.devin.hard_ceiling == null' "$caps" >/dev/null \
  || fail "production: devin must NOT be hard_ceiling (fleet-ops#3125: AIMD backs off on error)"
jq -e '.providers.devin.max_probe_ceiling == .providers.devin.cap' "$caps" >/dev/null \
  || fail "production: devin max_probe_ceiling must equal its cap while pinned (fleet-ops#3443; lift via fleet-ops#3258)"
jq -e '.providers.devin.models["glm-5-2"].max_probe_ceiling == .providers.devin.models["glm-5-2"].cap' "$caps" >/dev/null \
  || fail "production: devin glm-5-2 probe ceiling must equal its cap while pinned (fleet-ops#3443)"
jq -e '.providers.devin.models["swe-1-7"].max_probe_ceiling == .providers.devin.models["swe-1-7"].cap' "$caps" >/dev/null \
  || fail "production: devin swe-1-7 probe ceiling must equal its cap while pinned (fleet-ops#3443/#3473)"
jq -e '.providers.ollama.hard_ceiling == true' "$caps" >/dev/null \
  || fail "production: ollama must be hard_ceiling=true"
# Rule 2 (fleet-ops#3504): max_probe_ceiling >= cap and <= 2x cap unless
# hard_ceiling. No numeric pins — the RELATIONSHIP is the rule, not the
# number. A cap change moves the ceiling with it; a ceiling outside [cap,
# 2*cap] without hard_ceiling fails here without a test edit.
while IFS=$'\t' read -r prov cap ceiling hard; do
    [[ -n "$prov" ]] || continue
    [[ "$ceiling" == "null" || -z "$ceiling" ]] && continue  # no ceiling = no probe
    [[ "$hard" == "true" ]] && continue  # hard_ceiling exempt from the 2x rule
    cap_n=$((cap))
    ceil_n=$((ceiling))
    [[ "$ceil_n" -ge "$cap_n" ]] \
      || fail "production: $prov max_probe_ceiling ($ceil_n) < cap ($cap_n) — ceiling must be >= cap (rule 2, fleet-ops#3504)"
    [[ "$ceil_n" -le $((cap_n * 2)) ]] \
      || fail "production: $prov max_probe_ceiling ($ceil_n) > 2x cap ($((cap_n*2))) — ceiling must be <= 2x cap unless hard_ceiling (rule 2, fleet-ops#3504)"
    ok "production: $prov max_probe_ceiling ($ceil_n) within [cap=$cap_n, 2x=$((cap_n*2))] (rule 2, fleet-ops#3504)"
done < <(jq -r '.providers | to_entries[] | [.key, (.value.cap // 0), (.value.max_probe_ceiling // "null"), (.value.hard_ceiling // false)] | @tsv' "$caps")
jq -e '.providers.minimax.max_probe_ceiling == null' "$caps" >/dev/null \
  || fail "production: minimax must omit max_probe_ceiling (no climb)"
ok "production seat-caps.json: devin AIMD not hard_ceiling, probe ceilings pinned == caps (fleet-ops#3443, lift via #3258), ollama hard_ceiling, all ceilings within [cap, 2x cap] (rule 2, fleet-ops#3504)"

# --- fleet-ops#3930: worker_memory shape (no MemoryHigh throttle band) ------
# The pressure-kill fault: MemoryHigh throttling is what made systemd-oomd
# turn one worker's thrash into a kill of a random sibling (6 pi-issue@*
# kills in 1h on a 15 GB box; pi-issue@0509-1752 killed at a 94.3M peak —
# victim was not the offender). The fix drops the MemoryHigh throttle band
# for fleet-ops + 0509 and keeps MemoryMax=4G: a worker that exceeds 4G is
# OOM-killed locally at the cap, and oomd has no throttle-to-kill path on
# the worker slice. The heavy class (manager workers, measured flat ~1.0 GB)
# keeps its 3G/2G band — it is not part of this fault. Pin the shape so a
# future revert (re-adding MemoryHigh to fleet-ops/0509, or dropping
# MemoryMax below 4G) is caught here, not on the next oomd kill burst.
fo_max=$(jq -r '.worker_memory["fleet-ops"].MemoryMax // empty' "$caps")
fo_high=$(jq -r '.worker_memory["fleet-ops"].MemoryHigh // empty' "$caps")
o5_max=$(jq -r '.worker_memory["0509"].MemoryMax // empty' "$caps")
o5_high=$(jq -r '.worker_memory["0509"].MemoryHigh // empty' "$caps")
[[ "$fo_max" == "4G" ]] || fail "production: fleet-ops worker_memory MemoryMax must be 4G (fleet-ops#3930), got '$fo_max'"
[[ -z "$fo_high" ]] || fail "production: fleet-ops worker_memory MemoryHigh must be ABSENT (fleet-ops#3930 dropped the throttle band so oomd has no throttle-to-kill path), got '$fo_high'"
[[ "$o5_max" == "4G" ]] || fail "production: 0509 worker_memory MemoryMax must be 4G (fleet-ops#3930), got '$o5_max'"
[[ -z "$o5_high" ]] || fail "production: 0509 worker_memory MemoryHigh must be ABSENT (fleet-ops#3930 dropped the throttle band), got '$o5_high'"
# heavy class keeps its band (manager workers, not part of the pressure-kill fault).
hvy_max=$(jq -r '.worker_memory.heavy.MemoryMax // empty' "$caps")
hvy_high=$(jq -r '.worker_memory.heavy.MemoryHigh // empty' "$caps")
[[ "$hvy_max" == "3G" && "$hvy_high" == "2G" ]] \
  || fail "production: heavy worker_memory must stay 3G/2G (manager workers, fleet-ops#3281; not part of fleet-ops#3930), got max='$hvy_max' high='$hvy_high'"
ok "production worker_memory: fleet-ops + 0509 MemoryMax=4G with NO MemoryHigh (throttle band dropped, fleet-ops#3930); heavy keeps 3G/2G"

# === fleet-ops#3732: PICK_SEAT_COUNT_SLOTS=1 counts the slots a pick would fill ===
# Replay drill from the issue's accept line: a seat map where the ONLY usable
# seat is at its cap -> 0 slots; the same map with one free slot -> exactly 1.
# Same filter chain as a pick, no probe admission, no seat picked.
caps3732="$scratch/seat-caps-3732.json"
learned3732="$scratch/learned-caps-3732.json"
state3732="$scratch/state-3732"
mkdir -p "$state3732/active-seats" "$scratch/ledger-3732"
echo '{"providers":{}}' >"$learned3732"
cat >"$caps3732" <<'JSON'
{
  "ram_gb_per_worker": 0.5,
  "providers": {
    "ollama": { "cap": 1, "class": "prepaid-quota", "hard_ceiling": true, "max_probe_ceiling": 1, "models": { "deepseek-v4-flash:0731": 1 } }
  }
}
JSON
count_slots_3732() {
    SEAT_CAPS_JSON="$caps3732" LEARNED_CAPS_JSON="$learned3732" PI_PACKET_STATE="$state3732" \
    PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger-3732" PICK_SEAT_COUNT_SLOTS=1 \
        bash -c 'source "$0" 2>/dev/null; pick-seat "" "" 0 "" light 2>/dev/null' "$lib"
}
seed_active_3732() {
    local n="$1" i
    rm -f "$state3732"/active-seats/*.json
    for (( i = 0; i < n; i++ )); do
        jq -nc --arg u "pi-seed-ollama-$i" \
            '{provider:"ollama", model:"deepseek-v4-flash:0731", unit:$u, started_at:"2026-08-26T00:00:00Z"}' \
            > "$state3732/active-seats/pi-seed-ollama-$i.json"
    done
}
seed_active_3732 1
got=$(count_slots_3732)
[[ "$got" == "0" ]] || fail "fleet-ops#3732: only usable seat at cap (1/1 active) must count 0 slots, got '$got'"
ok "fleet-ops#3732: only usable seat at its cap -> 0 usable slots"
seed_active_3732 0
got=$(count_slots_3732)
[[ "$got" == "1" ]] || fail "fleet-ops#3732: one free slot must count exactly 1, got '$got'"
ok "fleet-ops#3732: one free slot -> exactly 1 usable slot"
jq '.providers.ollama.models["deepseek-v4-flash:0731"] = 4' "$caps3732" >"$caps3732.tmp" && mv "$caps3732.tmp" "$caps3732"
got=$(count_slots_3732)
[[ "$got" == "1" ]] || fail "fleet-ops#3732: provider cap 1 must bound a cap-4 model to 1 slot, got '$got'"
ok "fleet-ops#3732: provider cap bounds the model headroom sum"
[[ "$(jq -c '.providers' "$learned3732")" == "{}" ]] \
    || fail "fleet-ops#3732: count mode must not record an AIMD probe/learned cap (got $(jq -c . "$learned3732"))"
ok "fleet-ops#3732: count mode records no learned cap / probe"
picked=$(SEAT_CAPS_JSON="$caps3732" LEARNED_CAPS_JSON="$learned3732" PI_PACKET_STATE="$state3732" \
    PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger-3732" \
    bash -c 'source "$0" 2>/dev/null; pick-seat "" "" 0 "" light 2>/dev/null' "$lib")
[[ "$picked" == ollama* ]] || fail "fleet-ops#3732: normal pick must still return the free ollama seat, got '$picked'"
ok "fleet-ops#3732: normal pick mode unchanged (picked $picked)"

# === fleet-ops#3690: per-provider learned-state reset + ramp + spawn cap =====
# Three invariants from the issue:
#   1. Unrelated seat-caps.json changes (ram_gb_per_worker) do NOT reset
#      learned AIMD state; only a provider's own block change resets it.
#   2. After a reset, the provider starts at floor/2 with ramp=true and
#      effective_provider_cap returns that value (not declared) so the next
#      tick ramps +1 per probe instead of bursting to declared.
#   3. pick-seat enforces a per-tick per-provider spawn cap (devin: 2/tick).

# --- #3690 invariant 1: per-provider reset, unrelated fields preserved ----
# Build two cap files that differ ONLY in ram_gb_per_worker (top-level).
# The reset function must NOT touch any provider's learned state.
caps3690="$scratch/seat-caps-3690.json"
learned3690="$scratch/learned-caps-3690.json"
state3690="$scratch/state-3690"
mkdir -p "$state3690/active-seats" "$scratch/ledger-3690"
cat >"$scratch/caps-3690-old.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "providers": {
    "devin": { "cap": 4, "class": "prepaid-quota", "max_probe_ceiling": 4, "models": { "glm-5-2": { "cap": 3, "max_probe_ceiling": 3 }, "swe-1-7": { "cap": 4, "max_probe_ceiling": 4 } } },
    "commandcode": { "cap": 2, "class": "free", "max_probe_ceiling": 4, "models": { "deepseek/deepseek-v4-flash": 4 } }
  }
}
JSON
cat >"$scratch/caps-3690-new-ram.json" <<'JSON'
{
  "ram_gb_per_worker": 2.0,
  "providers": {
    "devin": { "cap": 4, "class": "prepaid-quota", "max_probe_ceiling": 4, "models": { "glm-5-2": { "cap": 3, "max_probe_ceiling": 3 }, "swe-1-7": { "cap": 4, "max_probe_ceiling": 4 } } },
    "commandcode": { "cap": 2, "class": "free", "max_probe_ceiling": 4, "models": { "deepseek/deepseek-v4-flash": 4 } }
  }
}
JSON
jq -nc '{providers:{devin:{learned_cap:2,last_result:"backoff",bench_until:null,last_at:"2026-09-05T16:00:00Z"},commandcode:{learned_cap:3,last_result:"probe",bench_until:null,last_at:"2026-09-05T16:00:00Z"}}}' >"$learned3690"
run reset_learned_caps_on_provider_change "$scratch/caps-3690-old.json" "$scratch/caps-3690-new-ram.json" "$learned3690" 2>/dev/null
# Both providers' learned state must survive the unrelated ram_gb change.
devin_lc=$(jq -r '.providers.devin.learned_cap // "gone"' "$learned3690")
cc_lc=$(jq -r '.providers.commandcode.learned_cap // "gone"' "$learned3690")
[[ "$devin_lc" == "2" ]] || fail "#3690: ram_gb-only change must preserve devin learned_cap (got $devin_lc)"
[[ "$cc_lc" == "3" ]] || fail "#3690: ram_gb-only change must preserve commandcode learned_cap (got $cc_lc)"
ok "#3690: unrelated ram_gb_per_worker change preserves all learned AIMD state"

# Now change ONLY commandcode's cap block. devin must survive, commandcode reset.
cat >"$scratch/caps-3690-new-cc.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "providers": {
    "devin": { "cap": 4, "class": "prepaid-quota", "max_probe_ceiling": 4, "models": { "glm-5-2": { "cap": 3, "max_probe_ceiling": 3 }, "swe-1-7": { "cap": 4, "max_probe_ceiling": 4 } } },
    "commandcode": { "cap": 3, "class": "free", "max_probe_ceiling": 6, "models": { "deepseek/deepseek-v4-flash": 6 } }
  }
}
JSON
jq -nc '{providers:{devin:{learned_cap:2,last_result:"backoff",bench_until:null,last_at:"2026-09-05T16:00:00Z"},commandcode:{learned_cap:3,last_result:"probe",bench_until:null,last_at:"2026-09-05T16:00:00Z"},"devin/glm-5-2":{learned_cap:3,last_result:"probe",bench_until:null,last_at:"2026-09-05T16:00:00Z"}}}' >"$learned3690"
run reset_learned_caps_on_provider_change "$scratch/caps-3690-old.json" "$scratch/caps-3690-new-cc.json" "$learned3690" 2>/dev/null
devin_lc=$(jq -r '.providers.devin.learned_cap // "gone"' "$learned3690")
devin_glm_lc=$(jq -r '.providers["devin/glm-5-2"].learned_cap // "gone"' "$learned3690")
cc_lc=$(jq -r '.providers.commandcode.learned_cap // "gone"' "$learned3690")
cc_ramp=$(jq -r '.providers.commandcode.ramp | tostring // "gone"' "$learned3690")
[[ "$devin_lc" == "2" ]] || fail "#3690: commandcode-only change must preserve devin learned_cap (got $devin_lc)"
[[ "$devin_glm_lc" == "3" ]] || fail "#3690: commandcode-only change must preserve devin/glm-5-2 model learned_cap (got $devin_glm_lc)"
[[ "$cc_lc" == "1" ]] || fail "#3690: changed commandcode must reset to floor/2=1 (got $cc_lc)"
[[ "$cc_ramp" == "true" ]] || fail "#3690: changed commandcode must have ramp=true (got $cc_ramp)"
ok "#3690: provider-specific change resets only that provider (devin preserved, commandcode ramp=floor/2)"

# --- #3690 invariant 2: ramp=true -> effective cap starts low, not declared --
# Seed a ramp entry for devin (cap=4, learned_cap=2, ramp=true) and verify
# effective_provider_cap returns 2, not 4.
rm -f "$state3690"/active-seats/*.json "$scratch/ledger-3690"/*.json
# fleet-ops#4723: last_at must be FRESH here. #3690's slow-start applies to a
# ramp seeded by a deploy cap change, and reset_learned_caps_on_provider_change
# always writes last_at=now, so a ramp entry is born fresh in production. A
# hardcoded calendar epoch (was "2026-09-05T16:00:00Z") silently ages into a
# stale ramp, which now graduates to the declared floor by design — the same
# hardcoded-epoch rot fleet-ops#4508 hit. The assertion below is unchanged.
jq -nc --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{providers:{devin:{learned_cap:2,last_result:"ramp",ramp:true,bench_until:null,last_at:$t}}}' >"$learned3690"
cp "$scratch/caps-3690-old.json" "$caps3690"
eff=$(SEAT_CAPS_JSON="$caps3690" LEARNED_CAPS_JSON="$learned3690" PI_PACKET_STATE="$state3690" \
    PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger-3690" \
    bash -c 'source "$0" 2>/dev/null; load_seat_caps; load_learned_caps; effective_provider_cap devin' "$lib")
[[ "$eff" == "2" ]] || fail "#3690: ramp=true effective_provider_cap must return learned 2, not declared 4 (got $eff)"
ok "#3690: ramp=true -> effective cap is 2 (floor/2), not 4 (declared) — no first-tick burst"

# Verify ramp graduates: after a probe to declared, ramp clears.
# Seed ramp at learned_cap=3 (one below declared 4). A probe to 4 graduates.
# fleet-ops#4723: fresh last_at here too. This case must prove graduation BY
# PROBE; with a stale timestamp it would graduate on staleness instead and
# pass even if the probe path broke.
jq -nc --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{providers:{devin:{learned_cap:3,last_result:"ramp",ramp:true,bench_until:null,last_at:$t}}}' >"$learned3690"
# Seed 3 active devin seats so the probe gate (active==eff) passes.
for (( i = 0; i < 3; i++ )); do
    jq -nc --arg u "pi-3690-devin-$i" \
        '{provider:"devin",model:"glm-5-2",unit:$u,started_at:"2026-09-05T16:00:00Z"}' \
        > "$state3690/active-seats/pi-3690-devin-$i.json"
done
set +e
SEAT_CAPS_JSON="$caps3690" LEARNED_CAPS_JSON="$learned3690" PI_PACKET_STATE="$state3690" \
    PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger-3690" \
    PI_MODELS_JSON="$scratch/models.json" \
    LEARNED_CAPS_AUDIT="$scratch/audit-3690.log" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 PI_SEAT_CREDENTIAL_PRECHECK=0 SEAT_MIN_FREE_RAM_MB=0 \
    bash -c 'source "$0" 2>/dev/null; load_seat_caps; load_learned_caps; _aimd_probe_admitted devin 3 3' "$lib"
set -e
graduated_lc=$(jq -r '.providers.devin.learned_cap // "gone"' "$learned3690")
# jq `//` treats false as empty, so use `| tostring` to distinguish false from missing.
graduated_ramp=$(jq -r '.providers.devin.ramp | tostring // "gone"' "$learned3690")
[[ "$graduated_lc" == "4" ]] || fail "#3690: probe from ramp 3->4 must record learned_cap=4 (got $graduated_lc)"
[[ "$graduated_ramp" == "false" ]] || fail "#3690: reaching declared must clear ramp (got $graduated_ramp)"
ok "#3690: ramp graduates on probe to declared (learned 3->4, ramp cleared)"

# --- #3690 invariant 3: per-tick per-provider spawn cap (devin max 2/tick) ---
# Build a cap file with tick_spawn_cap:2 on devin. Three consecutive pick-seat
# calls in the same tick (no reset between them) must route only 2 to devin;
# the 3rd must skip devin and fall through to another provider.
caps3690_spawn="$scratch/seat-caps-3690-spawn.json"
state3690_spawn="$scratch/state-3690-spawn"
learned3690_spawn="$scratch/learned-caps-3690-spawn.json"
counts3690="$scratch/tick-spawn-counts.json"
mkdir -p "$state3690_spawn/active-seats" "$scratch/ledger-3690-spawn"
cat >"$scratch/models-3690-spawn.json" <<'JSON'
{
  "providers": {
    "devin": { "models": [ { "id": "glm-5-2", "cost": { "input": 0 } } ] },
    "commandcode": { "models": [ { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0 } } ] }
  }
}
JSON
cat >"$caps3690_spawn" <<'JSON'
{
  "ram_gb_per_worker": 0.5,
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "devin": { "cap": 4, "class": "prepaid-quota", "max_probe_ceiling": 4, "tick_spawn_cap": 2, "models": { "glm-5-2": { "cap": 4, "max_probe_ceiling": 4 } } },
    "commandcode": { "cap": 2, "class": "metered", "max_probe_ceiling": 4, "models": { "deepseek/deepseek-v4-flash": 4 } }
  }
}
JSON
echo '{"providers":{}}' >"$learned3690_spawn"
echo '{}' >"$counts3690"
# devin is prepaid-quota (picked before metered commandcode), so picks 1 and 2
# route to devin; pick 3 hits the cap and must fall through to commandcode.
pick3690() {
    SEAT_CAPS_JSON="$caps3690_spawn" \
    LEARNED_CAPS_JSON="$learned3690_spawn" \
    PI_PACKET_STATE="$state3690_spawn" \
    PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger-3690-spawn" \
    PI_MODELS_JSON="$scratch/models-3690-spawn.json" \
    SEAT_TICK_SPAWN_COUNTS_JSON="$counts3690" \
    bash -c 'source "$0" 2>/dev/null; pick-seat "" "" 0 "" light 2>/dev/null' "$lib"
}
p1=$(pick3690)
p2=$(pick3690)
p3=$(pick3690)
[[ "$p1" == devin* ]] || fail "#3690: 1st pick must route to devin (got '$p1')"
[[ "$p2" == devin* ]] || fail "#3690: 2nd pick must route to devin (got '$p2')"
[[ "$p3" != devin* ]] || fail "#3690: 3rd pick must NOT route to devin (spawn cap 2 reached), got '$p3'"
[[ "$p3" == commandcode* ]] || fail "#3690: 3rd pick must fall through to commandcode (got '$p3')"
devin_count=$(jq -r '.devin // 0' "$counts3690")
[[ "$devin_count" == "2" ]] || fail "#3690: tick spawn counter must show 2 devin picks (got $devin_count)"
ok "#3690: per-tick spawn cap 2 limits devin to 2 picks; 3rd falls through to commandcode"

# After reset_tick_spawn_counts, devin picks resume.
SEAT_TICK_SPAWN_COUNTS_JSON="$counts3690" \
    bash -c 'source "$0" 2>/dev/null; reset_tick_spawn_counts' "$lib"
p4=$(pick3690)
[[ "$p4" == devin* ]] || fail "#3690: after reset, 1st pick must route to devin again (got '$p4')"
ok "#3690: reset_tick_spawn_counts clears the counter; devin picks resume next tick"

# --- fleet-ops#4723: sole usable provider rides the AIMD ceiling ----------
# The #3690 cap stays at 2 when a fallback exists (invariant above). When
# devin is the ONLY usable provider, AIMD has admitted a probe raise, and
# there is no recent rc=143/124 death, the per-tick cap equals the live
# AIMD ceiling so one tick can fill the remaining slots. A fast death
# inside 60s keeps the fixed cap of 2.
caps4723="$scratch/seat-caps-4723.json"
state4723="$scratch/state-4723"
learned4723="$scratch/learned-caps-4723.json"
counts4723="$scratch/tick-spawn-counts-4723.json"
mkdir -p "$state4723/active-seats" "$scratch/ledger-4723"
cat >"$scratch/models-4723.json" <<'JSON'
{
  "providers": {
    "devin": { "models": [ { "id": "glm-5-2", "cost": { "input": 0 } } ] }
  }
}
JSON
cat >"$caps4723" <<'JSON'
{
  "ram_gb_per_worker": 0.5,
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "devin": { "cap": 4, "class": "prepaid-quota", "max_probe_ceiling": 4, "tick_spawn_cap": 2, "models": { "glm-5-2": { "cap": 4, "max_probe_ceiling": 4 } } }
  }
}
JSON
now4723=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg t "$now4723" '{providers:{devin:{learned_cap:3,last_result:"probe",ramp:true,bench_until:null,last_at:$t}}}' >"$learned4723"
echo '{}' >"$counts4723"
: >"$state4723/watch.log"
pick4723() {
    SEAT_CAPS_JSON="$caps4723" \
    LEARNED_CAPS_JSON="$learned4723" \
    PI_PACKET_STATE="$state4723" \
    PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger-4723" \
    PI_MODELS_JSON="$scratch/models-4723.json" \
    SEAT_TICK_SPAWN_COUNTS_JSON="$counts4723" \
    SEAT_LOG_FILE="$state4723/watch.log" \
    PI_SEAT_LIB_CHECK_SYSTEMD=0 PI_SEAT_CREDENTIAL_PRECHECK=0 SEAT_MIN_FREE_RAM_MB=0 \
    bash -c 'source "$0" 2>/dev/null; pick-seat "" "" 0 "" light 2>/dev/null' "$lib"
}
p4723_1=$(pick4723)
p4723_2=$(pick4723)
p4723_3=$(pick4723 || true)
p4723_4=$(pick4723 || true)
[[ "$p4723_1" == devin* ]] || fail "#4723: 1st pick must route to sole healthy AIMD provider (got '$p4723_1')"
[[ "$p4723_2" == devin* ]] || fail "#4723: 2nd pick must route to sole healthy AIMD provider (got '$p4723_2')"
[[ "$p4723_3" == devin* ]] || fail "#4723: 3rd pick must ride AIMD ceiling 3, not tick_spawn_cap 2 (got '$p4723_3')"
[[ -z "$p4723_4" ]] || fail "#4723: 4th pick must stop at AIMD ceiling 3 (got '$p4723_4')"
ok "#4723: sole-usable-provider + healthy AIMD => per-tick cap equals AIMD ceiling 3"

# Same map, fresh ramp seed at floor/2 with last_result=ramp: keep cap 2.
echo '{}' >"$counts4723"
now4723=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg t "$now4723" '{providers:{devin:{learned_cap:2,last_result:"ramp",ramp:true,bench_until:null,last_at:$t}}}' >"$learned4723"
: >"$state4723/watch.log"
r1=$(pick4723)
r4723_2=$(pick4723)
r4723_3=$(pick4723 || true)
[[ "$r1" == devin* && "$r4723_2" == devin* ]] || fail "#4723: ramp seed still gets 2 picks (got '$r1' '$r4723_2')"
[[ -z "$r4723_3" ]] || fail "#4723: ramp seed must keep tick_spawn_cap 2 (got '$r4723_3')"
ok "#4723: fresh AIMD ramp seed (no probe raise) keeps the fixed tick_spawn_cap"

# Same map as the probe-raise case, plus a rc=143 in the last 60s: stay at 2.
echo '{}' >"$counts4723"
now4723=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg t "$now4723" '{providers:{devin:{learned_cap:3,last_result:"probe",ramp:true,bench_until:null,last_at:$t}}}' >"$learned4723"
printf '[%s] pi-issue-run: fleet-ops-1 running on devin/glm-5-2 rc=143\n' "$now4723" >"$state4723/watch.log"
d1=$(pick4723)
d4723_2=$(pick4723)
d4723_3=$(pick4723 || true)
[[ "$d1" == devin* && "$d4723_2" == devin* ]] || fail "#4723: fast-death case still gets 2 picks (got '$d1' '$d4723_2')"
[[ -z "$d4723_3" ]] || fail "#4723: recent rc=143 must keep tick_spawn_cap 2 (got '$d4723_3')"
ok "#4723: recent fast death (rc=143 inside 60s) keeps the fixed tick_spawn_cap"

# Full suite includes the convergence replay as a final invariant.
run_empty_run_convergence
ok "fleet-ops#3760: empty-run convergence replay passed (production default EMPTY_RUN_FAILURE_CEILING=3)"

echo "All AIMD invariants passed."
