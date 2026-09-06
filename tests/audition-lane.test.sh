#!/usr/bin/env bash
# tests/audition-lane.test.sh
#
# fleet-ops#3322: audition lane — every new candidate seat gets cap 1 on
# LIGHT issues for 10 sessions, measured by the yield ledger; never on
# prepaid weekly quotas.
#
# Proves, offline (no gh, no prometheus, no systemd):
#   1. seat_is_audition returns 0 for a seat with audition: true (provider
#      and model level) and 1 for a non-audition seat.
#   2. pick_seat skips an audition seat when difficulty is not light.
#   3. pick_seat admits an audition seat when difficulty is light (count mode).
#   4. The count-mode walk (PICK_SEAT_COUNT_SLOTS=1) also skips audition
#      seats for non-light difficulty.
#   5. audition_inject_and_retire injects a new candidate as cap 1,
#      audition: true, light only, into the LIVE caps.
#   6. Injection is idempotent (a second run does not duplicate).
#   7. Prepaid providers are never auditioned (defence in depth).
#   8. A dropped candidate is not re-injected within the 30-day cooldown.
#   9. Retirement at 10 sessions removes the seat and records the drop.
#  10. Retirement at $1 cost removes the seat.
#  11. The verdict issue is filed via fleet-issue-file (stubbed).
#  12. Promotion at fleet median files a promote verdict.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"
intake="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
[[ -f "$intake" ]] || fail "pi-intake-tick.sh not found: $intake"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t audition-lane.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
export QUALITY_SCOREBOARD_JSON="$scratch/no-quality-scoreboard.json"
export QUALITY_ROUTING_JSON="$scratch/no-quality-routing.json"

# Stub fleet-issue-file so no real GitHub writes happen.
issue_file_log="$scratch/issue-file.log"
: >"$issue_file_log"
mkdir -p "$scratch/bin"
cat >"$scratch/bin/fleet-issue-file" <<'SH'
#!/usr/bin/env bash
echo "fleet-issue-file: $*" >>"${ISSUE_FILE_LOG:?}"
exit 0
SH
chmod +x "$scratch/bin/fleet-issue-file"
export ISSUE_FILE_LOG="$issue_file_log"
export FLEET_ISSUE_FILE="$scratch/bin/fleet-issue-file"

# Extract the audition functions (lines 582-808) from the intake tick.
# This captures the env-var block + all 3 functions WITHOUT the top-level
# call at line 811 (which would run the tick). We source seat-lib first so
# _seat_caps_loaded and load_seat_caps are available.
audition_funcs="$scratch/audition-funcs.sh"
sed -n '582,808p' "$intake" > "$audition_funcs"
# Prepend _tick_dir so the _ISSUE_FILE_BIN path resolves.
sed -i '1i_tick_dir="'"$repo_root"'/lib"' "$audition_funcs"
bash -n "$audition_funcs" || fail "extracted audition funcs have syntax errors"

# --- models.json with an audition candidate + a non-audition seat ---
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "mergegateway": {
      "models": [
        { "id": "deepseek/deepseek-v4-flash", "cost": { "input": 0.3, "output": 1.2 } },
        { "id": "minimax/minimax-m3", "cost": { "input": 0.3, "output": 1.2 } }
      ]
    },
    "ollama": {
      "models": [
        { "id": "deepseek-v4-flash:0731", "cost": { "input": 0 } }
      ]
    },
    "devin": {
      "models": [
        { "id": "glm-5-2", "cost": { "input": 0 } }
      ]
    }
  }
}
JSON

# --- seat-caps.json with an audition seat (provider-level) + a normal seat ---
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "ollama": { "cap": 2, "class": "free", "models": { "deepseek-v4-flash:0731": 2 } },
    "devin":  { "cap": 1, "class": "prepaid-quota", "models": { "glm-5-2": 1 } },
    "mergegateway": {
      "cap": 1,
      "class": "metered",
      "audition": true,
      "audition_started": "2026-09-06T00:00:00Z",
      "models": {
        "deepseek/deepseek-v4-flash": { "cap": 1, "audition": true }
      }
    }
  }
}
JSON

export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_PACKET_STATE="$scratch/state"
mkdir -p "$PI_PACKET_STATE"
ledger="$scratch/ledger"
mkdir -p "$ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"

# Helper: run a bash snippet with seat-lib sourced and caps loaded.
run_seat() {
    bash -c '
set -euo pipefail
source "'"$lib"'"
export PI_MODELS_JSON="'"$PI_MODELS_JSON"'"
export SEAT_CAPS_JSON="'"$SEAT_CAPS_JSON"'"
export PI_PACKET_STATE="'"$PI_PACKET_STATE"'"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
export QUALITY_SCOREBOARD_JSON="'"$QUALITY_SCOREBOARD_JSON"'"
export QUALITY_ROUTING_JSON="'"$QUALITY_ROUTING_JSON"'"
export PI_SEAT_HEALTH_LEDGER_DIR="'"$PI_SEAT_HEALTH_LEDGER_DIR"'"
load_seat_caps
'"$1"'
' 2>&1
}

# Helper: run audition_inject_and_retire with given env.
run_audition() {
    bash -c '
set -euo pipefail
source "'"$lib"'"
export SEAT_CAPS_JSON="'"$SEAT_CAPS_JSON"'"
export SEAT_YIELD_JSON="'"$SEAT_YIELD_JSON"'"
export PI_MODEL_CANDIDATES_JSON="'"$PI_MODEL_CANDIDATES_JSON"'"
export PI_AUDITION_DROPPED_JSON="'"$PI_AUDITION_DROPPED_JSON"'"
export FLEET_ISSUE_FILE="'"$FLEET_ISSUE_FILE"'"
export ISSUE_FILE_LOG="'"$ISSUE_FILE_LOG"'"
export PI_PACKET_STATE="'"$PI_PACKET_STATE"'"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0
load_seat_caps
source "'"$audition_funcs"'"
audition_inject_and_retire
' 2>&1
}

# --- 1. seat_is_audition ----------------------------------------------------
# seat_is_audition returns 1 for non-audition seats, which trips set -e in
# the bash -c subshell. Use `|| true` so the rc is captured.
set +e
out=$(run_seat 'seat_is_audition "mergegateway" "deepseek/deepseek-v4-flash" && echo "rc=0" || echo "rc=1"')
set -e
echo "$out" | grep -q "rc=0" || fail "seat_is_audition should return 0 for audition seat (got: $out)"
ok "seat_is_audition returns 0 for audition seat"

set +e
out=$(run_seat 'seat_is_audition "ollama" "deepseek-v4-flash:0731" && echo "rc=0" || echo "rc=1"')
set -e
echo "$out" | grep -q "rc=1" || fail "seat_is_audition should return 1 for non-audition seat (got: $out)"
ok "seat_is_audition returns 1 for non-audition seat"

# --- 2. pick_seat skips audition seat for heavy difficulty ------------------
set +e
out=$(run_seat 'pick_seat "" "" 1 "" heavy 2>/dev/null || true')
set -e
if echo "$out" | grep -q "mergegateway"; then
  fail "audition seat must NOT be picked for heavy (got: $out)"
fi
ok "pick_seat skips audition seat for heavy difficulty"

# --- 3. pick_seat count-mode admits audition seat for light -----------------
set +e
out=$(run_seat 'PICK_SEAT_COUNT_SLOTS=1 pick_seat "" "" 0 "" light 2>/dev/null || true')
set -e
echo "$out" | grep -qE '^[0-9]+$' || fail "count-mode light should return a number (got: $out)"
count=$(echo "$out" | tail -1)
(( count >= 1 )) || fail "audition seat should count as a light slot (got count=$count)"
ok "pick_seat count-mode admits audition seat for light (count=$count)"

# --- 4. count-mode skips audition seat for heavy ----------------------------
# Clear the watch log so we get a fresh skip line.
rm -f "$PI_PACKET_STATE/watch.log"
set +e
out=$(run_seat 'PICK_SEAT_COUNT_SLOTS=1 pick_seat "" "" 1 "" heavy 2>/dev/null || true')
set -e
grep -q "audition seat — light issues only" "$PI_PACKET_STATE/watch.log" 2>/dev/null \
  || fail "audition seat should be skipped with light-only log for heavy"
ok "count-mode skips audition seat for heavy (light-only log present)"

# --- 5. audition_inject_and_retire injects a new candidate ------------------
inject_caps="$scratch/inject-caps.json"
cat >"$inject_caps" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "ollama": { "cap": 2, "class": "free", "models": { "deepseek-v4-flash:0731": 2 } },
    "devin":  { "cap": 1, "class": "prepaid-quota", "models": { "glm-5-2": 1 } }
  }
}
JSON

candidates="$scratch/model-candidates.json"
cat >"$candidates" <<'JSON'
{
  "candidates": [
    { "provider": "mergegateway", "model": "deepseek/deepseek-v4-flash", "class": "metered" },
    { "provider": "inferx", "model": "deepseek-v4-flash", "class": "metered" }
  ]
}
JSON

dropped="$scratch/audition-dropped.json"
yield="$scratch/seat-yield.json"
echo '{}' >"$dropped"
echo '{}' >"$yield"

export SEAT_CAPS_JSON="$inject_caps"
export SEAT_YIELD_JSON="$yield"
export PI_MODEL_CANDIDATES_JSON="$candidates"
export PI_AUDITION_DROPPED_JSON="$dropped"
export AUDITION_DROPPED_JSON="$dropped"

run_audition >/dev/null

jq -e '.providers.mergegateway.audition == true' "$inject_caps" >/dev/null 2>&1 \
  || fail "mergegateway should be injected with audition: true"
jq -e '.providers.mergegateway.cap == 1' "$inject_caps" >/dev/null 2>&1 \
  || fail "mergegateway should be injected with cap 1"
jq -e '.providers.mergegateway.models["deepseek/deepseek-v4-flash"].audition == true' "$inject_caps" >/dev/null 2>&1 \
  || fail "model should be injected with audition: true"
jq -e '.providers.mergegateway.audition_started != null' "$inject_caps" >/dev/null 2>&1 \
  || fail "audition_started should be set"
jq -e '.providers.inferx.audition == true' "$inject_caps" >/dev/null 2>&1 \
  || fail "inferx should be injected with audition: true"
ok "audition_inject_and_retire injects new candidates as cap 1, audition: true"

# --- 6. idempotent injection ------------------------------------------------
run_audition >/dev/null
provider_count=$(jq '.providers | length' "$inject_caps")
[[ "$provider_count" == "4" ]] || fail "idempotent: expected 4 providers, got $provider_count"
ok "idempotent injection (second run adds nothing)"

# --- 6b. injection adds a model to an EXISTING provider ---------------------
# A candidate on a provider already in the LIVE caps (e.g. opencode) must add
# the model to that provider's models map with audition: true, without touching
# the provider's existing models or its provider-level audition flag.
existing_caps="$scratch/existing-caps.json"
cat >"$existing_caps" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["opencode"],
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "opencode": { "cap": 3, "class": "free", "models": { "deepseek-v4-flash-free": 1 } },
    "devin":  { "cap": 1, "class": "prepaid-quota", "models": { "glm-5-2": 1 } }
  }
}
JSON
cat >"$candidates" <<'JSON'
{
  "candidates": [
    { "provider": "opencode", "model": "nemotron-3.5-lightning-free", "class": "free" }
  ]
}
JSON
echo '{}' >"$dropped"

export SEAT_CAPS_JSON="$existing_caps"
export PI_MODEL_CANDIDATES_JSON="$candidates"
export PI_AUDITION_DROPPED_JSON="$dropped"
export AUDITION_DROPPED_JSON="$dropped"
run_audition >/dev/null

jq -e '.providers.opencode.models["nemotron-3.5-lightning-free"].audition == true' "$existing_caps" >/dev/null 2>&1 \
  || fail "new model should be added to existing provider with audition: true"
jq -e '.providers.opencode.models["nemotron-3.5-lightning-free"].cap == 1' "$existing_caps" >/dev/null 2>&1 \
  || fail "new model should be added with cap 1"
# The existing model is untouched.
jq -e '.providers.opencode.models["deepseek-v4-flash-free"] == 1' "$existing_caps" >/dev/null 2>&1 \
  || fail "existing model on the provider must be untouched"
# Provider-level audition flag is NOT set (only the model is auditioning).
jq -e '.providers.opencode.audition // false' "$existing_caps" >/dev/null 2>&1 \
  && fail "provider-level audition flag must NOT be set for an existing provider" \
  || true
ok "injection adds a model to an existing provider (model-level audition only)"

# --- 6c. injection bumps a cap=0 provider to 1 so the audition model can run --
zero_caps="$scratch/zero-caps.json"
cat >"$zero_caps" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["inferx"],
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "inferx": { "cap": 0, "class": "free", "intentional_cap_zero": "stale" },
    "devin":  { "cap": 1, "class": "prepaid-quota", "models": { "glm-5-2": 1 } }
  }
}
JSON
cat >"$candidates" <<'JSON'
{
  "candidates": [
    { "provider": "inferx", "model": "deepseek-v4-flash", "class": "free" }
  ]
}
JSON
echo '{}' >"$dropped"

export SEAT_CAPS_JSON="$zero_caps"
export PI_MODEL_CANDIDATES_JSON="$candidates"
export PI_AUDITION_DROPPED_JSON="$dropped"
export AUDITION_DROPPED_JSON="$dropped"
run_audition >/dev/null

jq -e '.providers.inferx.cap == 1' "$zero_caps" >/dev/null 2>&1 \
  || fail "cap=0 provider should be bumped to 1 so the audition model can run"
jq -e '.providers.inferx.models["deepseek-v4-flash"].audition == true' "$zero_caps" >/dev/null 2>&1 \
  || fail "audition model should be added to the bumped provider"
ok "injection bumps a cap=0 provider to 1 for the audition model"

# --- 7. prepaid providers are never auditioned ------------------------------
prepaid_caps="$scratch/prepaid-caps.json"
cp "$inject_caps" "$prepaid_caps"
cat >"$candidates" <<'JSON'
{
  "candidates": [
    { "provider": "mergegateway", "model": "deepseek/deepseek-v4-flash", "class": "metered" },
    { "provider": "cursor", "model": "composer-2.5", "class": "metered" }
  ]
}
JSON
# cursor is not in caps and not in prepaid_providers_in_order yet — add it.
jq '.prepaid_providers_in_order += ["cursor"]' "$prepaid_caps" > "$prepaid_caps.tmp" && mv "$prepaid_caps.tmp" "$prepaid_caps"
jq 'del(.providers.cursor)' "$prepaid_caps" > "$prepaid_caps.tmp" && mv "$prepaid_caps.tmp" "$prepaid_caps"

export SEAT_CAPS_JSON="$prepaid_caps"
export PI_MODEL_CANDIDATES_JSON="$candidates"
out=$(run_audition)
echo "$out" | grep -q "skip cursor" || fail "cursor (prepaid) should be skipped"
jq -e '.providers.cursor // empty' "$prepaid_caps" >/dev/null 2>&1 \
  && fail "cursor (prepaid) must NOT be injected" \
  || true
ok "prepaid providers are never auditioned (defence in depth)"

# --- 8. dropped candidate not re-injected within 30-day cooldown ------------
drop_caps="$scratch/drop-caps.json"
cat >"$drop_caps" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "ollama": { "cap": 2, "class": "free", "models": { "deepseek-v4-flash:0731": 2 } },
    "devin":  { "cap": 1, "class": "prepaid-quota", "models": { "glm-5-2": 1 } }
  }
}
JSON
cat >"$candidates" <<'JSON'
{
  "candidates": [
    { "provider": "mergegateway", "model": "deepseek/deepseek-v4-flash", "class": "metered" }
  ]
}
JSON
drop_ts=$(( $(date +%s) - 5 * 86400 ))
echo "{\"mergegateway/deepseek/deepseek-v4-flash\": $drop_ts}" >"$dropped"

export SEAT_CAPS_JSON="$drop_caps"
export PI_MODEL_CANDIDATES_JSON="$candidates"
export PI_AUDITION_DROPPED_JSON="$dropped"
export AUDITION_DROPPED_JSON="$dropped"
out=$(run_audition)
echo "$out" | grep -q "skip mergegateway" || fail "dropped candidate should be skipped (got: $out)"
jq -e '.providers.mergegateway // empty' "$drop_caps" >/dev/null 2>&1 \
  && fail "dropped candidate must NOT be re-injected within cooldown" \
  || true
ok "dropped candidate not re-injected within 30-day cooldown"

# --- 9. retirement at 10 sessions -------------------------------------------
retire_caps="$scratch/retire-caps.json"
cat >"$retire_caps" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "ollama": { "cap": 2, "class": "free", "models": { "deepseek-v4-flash:0731": 2 } },
    "devin":  { "cap": 1, "class": "prepaid-quota", "models": { "glm-5-2": 1 } },
    "mergegateway": {
      "cap": 1,
      "class": "metered",
      "audition": true,
      "audition_started": "2026-09-06T00:00:00Z",
      "models": {
        "deepseek/deepseek-v4-flash": { "cap": 1, "audition": true }
      }
    }
  }
}
JSON
cat >"$yield" <<'JSON'
{
  "mergegateway/deepseek/deepseek-v4-flash": {
    "yield": 0.3,
    "sessions": 10,
    "pr_count": 3,
    "no_pr_count": 7,
    "provisional": false,
    "cost_per_session": 0.05,
    "cost_usd": 0.50
  },
  "ollama/deepseek-v4-flash:0731": {
    "yield": 0.6,
    "sessions": 20,
    "pr_count": 12,
    "no_pr_count": 8,
    "provisional": false,
    "cost_per_session": 0.0,
    "cost_usd": 0.0
  }
}
JSON
echo '{}' >"$dropped"
: >"$issue_file_log"

export SEAT_CAPS_JSON="$retire_caps"
export SEAT_YIELD_JSON="$yield"
export PI_AUDITION_DROPPED_JSON="$dropped"
export AUDITION_DROPPED_JSON="$dropped"
export PI_MODEL_CANDIDATES_JSON="$candidates"
out=$(run_audition)
echo "$out" | grep -q "retired mergegateway" || fail "seat should be retired at 10 sessions (got: $out)"
jq -e '.providers.mergegateway // empty' "$retire_caps" >/dev/null 2>&1 \
  && fail "retired seat must be removed from caps" \
  || true
jq -e 'has("mergegateway/deepseek/deepseek-v4-flash")' "$dropped" >/dev/null 2>&1 \
  || fail "drop should be recorded in cooldown map"
grep -q "audition-failed" "$issue_file_log" 2>/dev/null \
  || fail "verdict issue (audition-failed) should be filed via fleet-issue-file"
ok "retirement at 10 sessions removes seat, records drop, files audition-failed verdict"

# --- 10. retirement at $1 cost ----------------------------------------------
cost_caps="$scratch/cost-caps.json"
cat >"$cost_caps" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "ollama": { "cap": 2, "class": "free", "models": { "deepseek-v4-flash:0731": 2 } },
    "devin":  { "cap": 1, "class": "prepaid-quota", "models": { "glm-5-2": 1 } },
    "mergegateway": {
      "cap": 1,
      "class": "metered",
      "audition": true,
      "audition_started": "2026-09-06T00:00:00Z",
      "models": {
        "deepseek/deepseek-v4-flash": { "cap": 1, "audition": true }
      }
    }
  }
}
JSON
cat >"$yield" <<'JSON'
{
  "mergegateway/deepseek/deepseek-v4-flash": {
    "yield": 0.5,
    "sessions": 3,
    "pr_count": 2,
    "no_pr_count": 1,
    "provisional": true,
    "cost_per_session": 0.50,
    "cost_usd": 1.50
  }
}
JSON
echo '{}' >"$dropped"

export SEAT_CAPS_JSON="$cost_caps"
export SEAT_YIELD_JSON="$yield"
export PI_AUDITION_DROPPED_JSON="$dropped"
export AUDITION_DROPPED_JSON="$dropped"
out=$(run_audition)
echo "$out" | grep -q "retired mergegateway" || fail "seat should be retired at \$1 cost (3 sessions, cost 1.50) (got: $out)"
jq -e '.providers.mergegateway // empty' "$cost_caps" >/dev/null 2>&1 \
  && fail "seat over \$1 cost must be removed from caps" \
  || true
ok "retirement at \$1 cost removes seat (even below 10 sessions)"

# --- 11. promotion at fleet median ------------------------------------------
promote_caps="$scratch/promote-caps.json"
cat >"$promote_caps" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "prepaid_providers_in_order": ["devin"],
  "providers": {
    "ollama": { "cap": 2, "class": "free", "models": { "deepseek-v4-flash:0731": 2 } },
    "devin":  { "cap": 1, "class": "prepaid-quota", "models": { "glm-5-2": 1 } },
    "mergegateway": {
      "cap": 1,
      "class": "metered",
      "audition": true,
      "audition_started": "2026-09-06T00:00:00Z",
      "models": {
        "deepseek/deepseek-v4-flash": { "cap": 1, "audition": true }
      }
    }
  }
}
JSON
cat >"$yield" <<'JSON'
{
  "mergegateway/deepseek/deepseek-v4-flash": {
    "yield": 0.8,
    "sessions": 10,
    "pr_count": 8,
    "no_pr_count": 2,
    "provisional": false,
    "cost_per_session": 0.05,
    "cost_usd": 0.50
  },
  "ollama/deepseek-v4-flash:0731": {
    "yield": 0.6,
    "sessions": 20,
    "pr_count": 12,
    "no_pr_count": 8,
    "provisional": false,
    "cost_per_session": 0.0,
    "cost_usd": 0.0
  }
}
JSON
echo '{}' >"$dropped"
: >"$issue_file_log"

export SEAT_CAPS_JSON="$promote_caps"
export SEAT_YIELD_JSON="$yield"
export PI_AUDITION_DROPPED_JSON="$dropped"
export AUDITION_DROPPED_JSON="$dropped"
out=$(run_audition)
echo "$out" | grep -q "retired mergegateway" || fail "seat should be retired (verdict filed) at 10 sessions even on promotion (got: $out)"
grep -q "promote" "$issue_file_log" 2>/dev/null \
  || fail "verdict issue (promote) should be filed via fleet-issue-file (got log: $(cat "$issue_file_log"))"
# A promoted seat is NOT dropped — it must not get a 30-day cooldown entry.
jq -e 'has("mergegateway/deepseek/deepseek-v4-flash")' "$dropped" >/dev/null 2>&1 \
  && fail "promoted seat must NOT be recorded in the drop cooldown map" \
  || true
ok "promotion at fleet median files promote verdict via fleet-issue-file (no drop cooldown)"

echo
echo "ALL AUDITION-LANE TESTS PASSED"
