#!/usr/bin/env bash
# tests/repair-rung.test.sh
#
# fleet-ops#4639: reserved repair rung. When pick-seat returns NO USABLE
# SEAT or usable slots < 2 for >= 2 consecutive intake ticks, intake may
# claim critical-path fleet-ops issues on a rung exempt from yield caps
# and the light-only/audition filter. Worker pick-seat falls back to
# litellm judge -> mergegateway audition -> cursor keystone at cap 1 and
# never a money-walled seat. The rung disarms when pick-seat returns a
# usable seat for DISARM_AFTER (default 2) consecutive ticks (fleet-ops#4820).
#
# Hosted by tests/pi-intake-run.test.sh (CI already lists that file).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
lib="$repo_root/lib/litellm-seat.sh"
run="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
[[ -f "$lib" ]] || fail "lib/litellm-seat.sh missing"
[[ -f "$run" ]] || fail "bin/pi-issue-run missing"

# --- 1. intake pins ---
grep -qF 'PI_INTAKE_REPAIR_RUNG_AFTER="${PI_INTAKE_REPAIR_RUNG_AFTER:-2}"' "$tick" \
    || fail "PI_INTAKE_REPAIR_RUNG_AFTER default 2 missing"
grep -qF 'PI_INTAKE_REPAIR_RUNG_MAX_CONCURRENT="${PI_INTAKE_REPAIR_RUNG_MAX_CONCURRENT:-2}"' "$tick" \
    || fail "PI_INTAKE_REPAIR_RUNG_MAX_CONCURRENT default 2 missing"
grep -qF 'PI_INTAKE_REPAIR_RUNG_DISARM_AFTER="${PI_INTAKE_REPAIR_RUNG_DISARM_AFTER:-2}"' "$tick" \
    || fail "PI_INTAKE_REPAIR_RUNG_DISARM_AFTER default 2 missing"
grep -qF 'REPAIR-RUNG armed:' "$tick" || fail "REPAIR-RUNG armed log missing"
grep -qF 'REPAIR-RUNG disarmed:' "$tick" || fail "REPAIR-RUNG disarmed log missing"
grep -qF 'REPAIR-RUNG released:' "$tick" || fail "REPAIR-RUNG released log missing"
grep -qF 'REPAIR-RUNG: claimed critical-path issue' "$tick" \
    || fail "REPAIR-RUNG claim log missing"
grep -qF 'skipped-repair-rung (rung claims critical-path fleet-ops only' "$tick" \
    || fail "critical-path-only filter missing"
grep -qF 'seat-rung: repair' "$tick" || fail "packet seat-rung marker missing"
grep -qF 'allow-repair-rung' "$tick" || fail "yield-cap exemption missing"
ok "intake pins: knobs, arm/release/claim logs, critical-path filter, packet marker"

# --- 2. pick-seat + pi-issue-run pins ---
grep -qF '_pick_repair_rung_seat' "$lib" || fail "pick-seat repair-rung ladder missing"
grep -qF 'Never a money-walled seat' "$lib" || fail "money-wall refusal comment missing"
grep -qF 'PI_REPAIR_RUNG' "$run" || fail "pi-issue-run PI_REPAIR_RUNG missing"
grep -qF 'seat-rung:[[:space:]]*repair' "$run" \
    || fail "pi-issue-run does not read seat-rung: repair"
ok "pick-seat + pi-issue-run pins"

# --- 3. two-tick drill (arm after tick 2, release when slots return) ---
scratch="$(mktemp -d -t repair-rung.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

stubs="$scratch/seatlib-stub.sh"
cat >"$stubs" <<'SH'
#!/usr/bin/env bash
total_seat_cap() { echo 8; }
issue_seat_cap() { echo 5; }
load_seat_caps() { return 0; }
worker_memory_for_difficulty() { return 1; }
worker_env_for_repo() { return 1; }
litellm_seat() {
    if [[ "${PICK_SEAT_COUNT_SLOTS:-0}" == "1" ]]; then
        echo "${STUB_LIGHT_SLOTS:-0}"
        return 0
    fi
    if [[ "${STUB_HEAVY:-0}" == "1" ]]; then
        printf 'cursor\tcursor-grok-4.6-high\n'
        return 0
    fi
    return 1
}
precedence_band_phase() { echo "band"; }
precedence_band_pending_clear() { true; }
precedence_band_pending_starvation_clear() { true; }
precedence_band_is_leverage_issue() { return 1; }
precedence_band_allow_claim() { echo "allow-repair-rung"; return 0; }
product_first_export_product_ratio() { return 0; }
product_first_is_self_maintenance() { return 1; }
product_first_ratio() { echo "0.1"; }
product_first_hold() { return 1; }
SH
chmod +x "$stubs"

prior_art_stub="$scratch/prior-art-claim-check"
cat >"$prior_art_stub" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$prior_art_stub"

write_rl() {
    cat >"$scratch/gh-rate-limit.json" <<JSON
{
  "low": 0,
  "remaining": 3000,
  "limit": 5000,
  "resource": "core",
  "reset": $(( $(date +%s) + 3600 )),
  "fetched_at": $(date +%s)
}
JSON
}
write_rl

gh() {
    if [[ "$1" == "issue" && "$2" == "list" ]]; then
        printf '%s\n' '[{"number":4639,"title":"seat deadlock","labels":[{"name":"agent-ready"},{"name":"critical-path"}]},{"number":4820,"title":"ordinary-work","labels":[{"name":"agent-ready"}]}]'
        return 0
    fi
    return 0
}
git() {
    if [[ "$1" == "-C" ]]; then shift 2; fi
    if [[ "$1" == "fetch" || "$1" == "ls-remote" || "$1" == "push" ]]; then
        return 0
    fi
    return 0
}
systemctl() { echo "inactive"; return 0; }
export -f gh git systemctl

printf 'test-worker-prompt\n' >"$scratch/worker.md"

run_tick() {
    mkdir -p "$scratch/secondary" "$scratch/run" "$scratch/pi-issues" "$scratch/umbrella"
    env \
        GITHUB_ACTIONS=true \
        HOME="$scratch" \
        XDG_RUNTIME_DIR="$scratch/run" \
        PI_INTAKE_LOCKDIR="$scratch" \
        PI_INTAKE_DEBOUNCE_SEC=0 \
        PI_INTAKE_RECONCILER_PROM="$scratch/reconciler" \
        PI_INTAKE_UMBRELLA_PROM="$scratch/umbrella/fleet-umbrella-dispatch" \
        PI_INTAKE_CLAIMS_LOG="$scratch/claims.log" \
        PI_INTAKE_WORKER_PROMPT="$scratch/worker.md" \
        PI_INTAKE_GH_RATE_LIMIT_STATE="$scratch/gh-rate-limit.json" \
        PI_INTAKE_GH_RATE_LIMIT_MAX_AGE=120 \
        PI_INTAKE_GH_SECONDARY_STATE_DIR="$scratch/secondary" \
        PI_INTAKE_ISSUE_STATE_DIR="$scratch/pi-issues" \
        PI_INTAKE_REPAIR_RUNG_STATE="$scratch/repair-rung-state" \
        PI_INTAKE_SCOUT_ON_EMPTY=0 \
        PI_INTAKE_SCOUT_LOW_WATER=0 \
        SEAT_LIB="$stubs" \
        PRECEDENCE_BAND_LIB="$stubs" \
        PRIOR_ART_CLAIM_CHECK="$prior_art_stub" \
        STUB_LIGHT_SLOTS="${STUB_LIGHT_SLOTS:-0}" \
        STUB_HEAVY="${STUB_HEAVY:-0}" \
        FLEET_ISSUE_REPO="Nishfleet/fleet-ops" \
        bash "$tick" fleet-ops 2>&1
}

out1="$(STUB_LIGHT_SLOTS=0 STUB_HEAVY=0 run_tick)" || true
echo "$out1" | grep -qF 'holding claims this tick' \
    || fail "tick 1 must hold (strike 1), got: $out1"
echo "$out1" | grep -qF 'REPAIR-RUNG armed' \
    && fail "tick 1 must NOT arm the rung, got: $out1"
ok "tick 1: hold, rung closed"

out2="$(STUB_LIGHT_SLOTS=0 STUB_HEAVY=0 run_tick)" || true
echo "$out2" | grep -qF 'REPAIR-RUNG armed' \
    || fail "tick 2 must arm the rung, got: $out2"
ok "tick 2: REPAIR-RUNG armed"

out3="$(STUB_LIGHT_SLOTS=3 STUB_HEAVY=1 run_tick)" || true
echo "$out3" | grep -qF 'REPAIR-RUNG recovery 1/2' \
    || fail "tick 3 first recovered seat must be recovery 1/2, got: $out3"
echo "$out3" | grep -qF 'REPAIR-RUNG disarmed' \
    && fail "tick 3 must not disarm yet, got: $out3"
ok "tick 3: recovery 1/2, still armed"

out4="$(STUB_LIGHT_SLOTS=3 STUB_HEAVY=1 run_tick)" || true
echo "$out4" | grep -qF 'REPAIR-RUNG disarmed' \
    || fail "tick 4 second usable-seat tick must disarm, got: $out4"
echo "$out4" | grep -qF 'cursor	cursor-grok-4.6-high' \
    || fail "disarm log must name the seat that cleared it, got: $out4"
ok "tick 4: REPAIR-RUNG disarmed with the clearing seat"

out5="$(STUB_LIGHT_SLOTS=3 STUB_HEAVY=1 run_tick)" || true
echo "$out5" | grep -qF 'skipped-repair-rung (rung claims critical-path fleet-ops only' \
    && fail "tick 5 after disarm must not skip non-critical-path, got: $out5"
echo "$out5" | grep -qF 'ordinary-work' \
    || true
ok "tick 5: non-critical-path is not skipped-repair-rung after disarm"

# --- 4. pick-seat ladder: cursor when workers are walled; refuse money wall ---
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
export SEAT_LIVE_QUOTA_PROM="$scratch/no-live-quota.prom"
export PI_PACKET_STATE="$scratch/state"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
export FLEET_SEAT_RECOVERY_NOW="2026-09-09T12:00:00Z"
mkdir -p "$PI_PACKET_STATE/active-seats" "$PI_SEAT_HEALTH_LEDGER_DIR"

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "ollama": { "models": [ { "id": "deepseek-v4-flash:0731" } ] },
    "mergegateway": {
      "models": [
        { "id": "anthropic/claude-sonnet-5" },
        { "id": "deepseek/deepseek-v4-flash" }
      ]
    },
    "cursor": { "models": [ { "id": "cursor-grok-4.6-high" } ] },
    "litellm": { "models": [ { "id": "judge" } ] }
  }
}
JSON
cat >"$scratch/caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "providers": {
    "ollama": { "cap": 2, "class": "free", "models": { "deepseek-v4-flash:0731": 2 } },
    "mergegateway": {
      "cap": 2,
      "class": "metered",
      "models": {
        "anthropic/claude-sonnet-5": { "cap": 1, "audition": true },
        "deepseek/deepseek-v4-flash": 2
      }
    },
    "cursor": { "cap": 1, "class": "subscription", "models": { "cursor-grok-4.6-high": 1 } },
    "litellm": { "cap": 0, "class": "prepaid-quota", "models": { "judge": 0 } }
  }
}
JSON
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/caps.json"

wall_ledger() {
    local p="$1" m="$2"
    local ps ms
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    cat >"$PI_SEAT_HEALTH_LEDGER_DIR/${ps}__${ms}.json" <<JSON
{"health_class":"quota_exhausted","seat_dead":false,"observed_at":"2026-09-09T11:00:00Z","bench_until":"2026-09-10T12:00:00Z","consecutive_failure_count":4,"failure_mode":"quota_cap"}
JSON
}
wall_ledger ollama "deepseek-v4-flash:0731"
wall_ledger mergegateway "deepseek/deepseek-v4-flash"
wall_ledger mergegateway "anthropic/claude-sonnet-5"

# Without the rung, cursor is keystone-only and audition is light-only:
# a heavy pick must stall when workers are money-walled.
unset PI_REPAIR_RUNG
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick-seat "" "" 1 "" heavy' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "heavy pick without rung must stall (no worker seats), got: $out"
ok "pick-seat without PI_REPAIR_RUNG refuses keystone/audition on a heavy packet"

# With the rung, cursor (healthy, not money-walled) is offered.
export PI_REPAIR_RUNG=1
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick-seat "" "" 0 "" light' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "repair rung must pick cursor, rc=$rc out=$out"
[[ "$out" == $'cursor\tcursor-grok-4.6-high' ]] \
    || fail "repair rung must pick cursor/cursor-grok-4.6-high, got: $out"
ok "repair rung picks cursor keystone when worker seats are walled"

# Money-wall cursor: unwall the audition seat so the ladder can fall through.
rm -f "$PI_SEAT_HEALTH_LEDGER_DIR/mergegateway__anthropic_claude-sonnet-5.json"
wall_ledger cursor "cursor-grok-4.6-high"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick-seat "" "" 0 "" light' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "repair rung must fall through to audition, rc=$rc out=$out"
[[ "$out" == $'mergegateway\tanthropic/claude-sonnet-5' ]] \
    || fail "repair rung must pick mergegateway audition, got: $out"
ok "repair rung refuses money-walled cursor and picks mergegateway audition"

# Wall the audition seat too: nothing left.
wall_ledger mergegateway "anthropic/claude-sonnet-5"
set +e
out=$(bash -c 'source "$0"; load_seat_caps; pick-seat "" "" 0 "" light' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" != "0" ]] || fail "all-walled rung must stall, got: $out"
ok "repair rung stalls when every reserved seat is money-walled"

# Filter pin: non-critical-path is skipped while armed.
grep -qF 'skipped-repair-rung (rung claims critical-path fleet-ops only' "$tick" \
    || fail "non-critical-path skip missing"
ok "armed rung claims critical-path only (filter pin)"

echo ""
echo "ALL OK: repair rung (fleet-ops#4639)"
