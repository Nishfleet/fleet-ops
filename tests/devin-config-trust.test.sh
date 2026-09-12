#!/usr/bin/env bash
# tests/devin-config-trust.test.sh
#
# fleet-ops#4825: the Devin CLI rejects every workspace with
# "Refusing to run in an untrusted workspace" when the managed config carries
# the wrong key. The vendor error message tells you to set
# `respect_workspace_trust: false`, but the CONFIG field the CLI actually reads
# is `skip_workspace_trust`. The fleet carried the wrong key for ~28h, walling
# the devin prepaid seat (glm-5-2 / swe-1-7). This test pins:
#
#   1. The repo-managed overlay (template/devin-config.json) carries the CORRECT
#      key `skip_workspace_trust: true` and NOT the misleading
#      `respect_workspace_trust`.
#   2. install.sh's ensure_devin_config_trust() merges the correct key into a
#      live config that has the wrong key, drops the wrong key, and preserves
#      existing account fields.
#   3. The seatlib detector is_workspace_trust_error matches the literal
#      "Refusing to run in an untrusted workspace".
#   4. mark_seat_config_fault_bench writes a config_fault ledger entry that is
#      NEVER retired (seat_dead=false), proving config/trust faults are
#      infrastructure, not seat yield.
#   5. classify_death_error classifies the trust literal as
#      `config_fault_trust`, not `unknown` (so the fast-death fallthrough does
#      not re-bench it as an ordinary failure).
#
# Runs entirely offline: stubbed seat-caps.json, ledger dir, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t devin-config-trust.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# ============================================================================
# 1. Repo-managed overlay carries the CORRECT key
# ============================================================================
overlay="$repo_root/template/devin-config.json"
[[ -f "$overlay" ]] || fail "template/devin-config.json not found at $overlay"

overlay_key=$(jq -r '.skip_workspace_trust // "MISSING"' "$overlay")
[[ "$overlay_key" == "true" ]] \
    || fail "overlay must have skip_workspace_trust=true, got '$overlay_key' (fleet-ops#4825: the vendor error message says respect_workspace_trust, but the CLI reads skip_workspace_trust)"

# The misleading key MUST NOT be the managed key.
misleading=$(jq -r '.respect_workspace_trust // "ABSENT"' "$overlay")
[[ "$misleading" == "ABSENT" ]] \
    || fail "overlay must NOT carry respect_workspace_trust (the misleading key the vendor error message suggests); fleet-ops#4825"
ok "overlay: skip_workspace_trust=true, respect_workspace_trust absent (fleet-ops#4825)"

# ============================================================================
# 2. install.sh ensure_devin_config_trust() merges correctly
# ============================================================================
install_src="$repo_root/install.sh"
[[ -x "$install_src" ]] || fail "install.sh not executable: $install_src"

# install.sh has no main guard (it runs `exit "$rc"` at the end), so sourcing
# it would run the full install. Extract just the function body and eval it.
# Also set `here` so the function's $here/template/devin-config.json resolves.
func_body=$(sed -n '/^ensure_devin_config_trust() {/,/^}$/p' "$install_src")
[[ -n "$func_body" ]] || fail "could not extract ensure_devin_config_trust() from install.sh"

# 2a. Fresh box: no live config -> seed from overlay.
fresh_home="$scratch/fresh-home"
mkdir -p "$fresh_home"
HOME="$fresh_home" here="$repo_root" bash -c 'eval "$1"; ensure_devin_config_trust' _ "$func_body" >/dev/null 2>&1
fresh_cfg="$fresh_home/.config/devin/config.json"
[[ -f "$fresh_cfg" ]] || fail "fresh box: ensure_devin_config_trust did not seed $fresh_cfg"
fresh_key=$(jq -r '.skip_workspace_trust // "MISSING"' "$fresh_cfg")
[[ "$fresh_key" == "true" ]] || fail "fresh box: seeded config must have skip_workspace_trust=true, got '$fresh_key'"
ok "install.sh: fresh box seeded with skip_workspace_trust=true"

# 2b. Live config with the WRONG key + account fields -> merge correct, drop wrong, preserve account.
live_home="$scratch/live-home"
live_cfg_dir="$live_home/.config/devin"
mkdir -p "$live_cfg_dir"
live_cfg="$live_cfg_dir/config.json"
cat >"$live_cfg" <<'JSON'
{
  "respect_workspace_trust": false,
  "devin.org_id": "fleet-test-org-12345",
  "some_other_setting": "preserve-me"
}
JSON
HOME="$live_home" here="$repo_root" bash -c 'eval "$1"; ensure_devin_config_trust' _ "$func_body" >/dev/null 2>&1
merged_key=$(jq -r '.skip_workspace_trust // "MISSING"' "$live_cfg")
[[ "$merged_key" == "true" ]] \
    || fail "live config: ensure_devin_config_trust must merge skip_workspace_trust=true, got '$merged_key'"
wrong_key=$(jq -r '.respect_workspace_trust // "ABSENT"' "$live_cfg")
[[ "$wrong_key" == "ABSENT" ]] \
    || fail "live config: ensure_devin_config_trust must drop the misleading respect_workspace_trust key, still present"
org_id=$(jq -r '."devin.org_id" // "MISSING"' "$live_cfg")
[[ "$org_id" == "fleet-test-org-12345" ]] \
    || fail "live config: ensure_devin_config_trust must preserve existing account fields, devin.org_id lost"
other=$(jq -r '.some_other_setting // "MISSING"' "$live_cfg")
[[ "$other" == "preserve-me" ]] \
    || fail "live config: ensure_devin_config_trust must preserve other fields, some_other_setting lost"
ok "install.sh: live config merged (skip_workspace_trust=true, respect_workspace_trust dropped, account fields preserved)"

# 2c. Live config already correct -> idempotent (still true, no data loss).
HOME="$live_home" here="$repo_root" bash -c 'eval "$1"; ensure_devin_config_trust' _ "$func_body" >/dev/null 2>&1
idem_key=$(jq -r '.skip_workspace_trust // "MISSING"' "$live_cfg")
[[ "$idem_key" == "true" ]] || fail "idempotent: skip_workspace_trust must stay true on re-run"
idem_org=$(jq -r '."devin.org_id" // "MISSING"' "$live_cfg")
[[ "$idem_org" == "fleet-test-org-12345" ]] || fail "idempotent: account fields must survive re-run"
ok "install.sh: idempotent re-run preserves skip_workspace_trust=true and account fields"

# ============================================================================
# 3. seatlib: is_workspace_trust_error matcher
# ============================================================================
lib="$repo_root/lib/litellm-seat.sh"
[[ -f "$lib" ]] || fail "seatlib.sh not found: $lib"

# Minimal seat-caps.json so seatlib loads.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["devin"],
  "providers": {
    "devin": {
      "cap": 4, "class": "subscription",
      "quota_bench_default_s": 900,
      "models": {"glm-5-2": 4, "swe-1-7": 4}
    }
  },
  "error_classes": {
    "quota_bench": {
      "matcher": "is_quota_cap_error",
      "writer": "mark_seat_quota_bench",
      "default_window_s_seconds": "quota_bench_default_s",
      "trigger_order": 2,
      "description": "Hard cap / quota wall."
    }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "glm-5-2", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 },
        { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON
export PI_MODELS_JSON="$scratch/models.json"

# Offline: no live systemd units in cap accounting.
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export SEAT_LIVE_QUOTA_PROM="$scratch/no-live-quota.prom"

LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_PACKET_STATE="$scratch/state"
export XDG_RUNTIME_DIR="$scratch/xdg"
mkdir -p "$XDG_RUNTIME_DIR"

# 3a. Matcher matches the exact literal.
set +e
bash -c 'source "$0"; load_seat_caps; is_workspace_trust_error "$1" "$2"' \
    "$lib" "Refusing to run in an untrusted workspace" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_workspace_trust_error must match the literal 'Refusing to run in an untrusted workspace' (rc=$rc)"
ok "is_workspace_trust_error: matches 'Refusing to run in an untrusted workspace'"

# 3b. Matcher matches the literal embedded in a larger error blob.
set +e
bash -c 'source "$0"; load_seat_caps; is_workspace_trust_error "$1" "$2"' \
    "$lib" "" "Error: Refusing to run in an untrusted workspace. Set skip_workspace_trust in config." >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_workspace_trust_error must match the literal inside a larger error blob (rc=$rc)"
ok "is_workspace_trust_error: matches literal embedded in larger error blob"

# 3c. Matcher does NOT match a quota error (no false positive).
set +e
bash -c 'source "$0"; load_seat_caps; is_workspace_trust_error "$1" "$2"' \
    "$lib" "INFERENCE_CAP_ERROR: weekly limit" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "is_workspace_trust_error must NOT match a quota error (rc=$rc)"
ok "is_workspace_trust_error: does not match quota error (no false positive)"

# 3d. Matcher does NOT match empty input.
set +e
bash -c 'source "$0"; load_seat_caps; is_workspace_trust_error "$1" "$2"' \
    "$lib" "" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "is_workspace_trust_error must NOT match empty input (rc=$rc)"
ok "is_workspace_trust_error: does not match empty input"

# ============================================================================
# 4. mark_seat_config_fault_bench: config_fault ledger, NEVER retired
# ============================================================================
rm -f "$LEDGER"/*.json 2>/dev/null || true
trust_text="Refusing to run in an untrusted workspace"
set +e
bash -c 'source "$0"; load_seat_caps; mark_seat_config_fault_bench "$1" "$2" "$3"' \
    "$lib" "devin" "glm-5-2" "$trust_text" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "mark_seat_config_fault_bench must return 0 on success (rc=$rc)"

ledger_file="$LEDGER/devin__glm-5-2.json"
[[ -f "$ledger_file" ]] || fail "mark_seat_config_fault_bench did not create ledger at $ledger_file"

hc=$(jq -r '.health_class' "$ledger_file")
[[ "$hc" == "config_fault" ]] \
    || fail "mark_seat_config_fault_bench must write health_class=config_fault, got '$hc'"

fm=$(jq -r '.failure_mode' "$ledger_file")
[[ "$fm" == "config_fault_trust" ]] \
    || fail "mark_seat_config_fault_bench must write failure_mode=config_fault_trust, got '$fm'"

# CRITICAL (fleet-ops#4825): a config/trust fault is INFRASTRUCTURE, never
# seat yield. The seat must NOT be retired — seat_dead stays false.
seat_dead=$(jq -r '.seat_dead' "$ledger_file")
[[ "$seat_dead" == "false" ]] \
    || fail "mark_seat_config_fault_bench must write seat_dead=false (config fault is infrastructure, NOT yield/corpse), got '$seat_dead'"

# The bench must have a usable_at in the future (short bench so pick-seat dodges it).
usable_at=$(jq -r '.usable_at // "MISSING"' "$ledger_file")
[[ "$usable_at" != "MISSING" ]] || fail "mark_seat_config_fault_bench must write usable_at, missing"
bench_until=$(jq -r '.bench_until // "MISSING"' "$ledger_file")
[[ "$bench_until" != "MISSING" ]] || fail "mark_seat_config_fault_bench must write bench_until, missing"

lec=$(jq -r '.last_error_class // "MISSING"' "$ledger_file")
[[ "$lec" == "config_fault_trust" ]] \
    || fail "mark_seat_config_fault_bench must write last_error_class=config_fault_trust, got '$lec'"

ok "mark_seat_config_fault_bench: health_class=config_fault, failure_mode=config_fault_trust, seat_dead=false (NOT retired), usable_at set"

# ============================================================================
# 4b. mark_seat_config_fault_bench: repeated calls do NOT escalate to corpse
# ============================================================================
# A config fault that fires 100 times must STILL not be seat_dead. This is the
# core of the issue: config/trust faults are infrastructure, never yield.
set +e
for _ in $(seq 1 100); do
    bash -c 'source "$0"; load_seat_caps; mark_seat_config_fault_bench "$1" "$2" "$3"' \
        "$lib" "devin" "swe-1-7" "$trust_text" >/dev/null 2>&1
done
set -e
ledger_file2="$LEDGER/devin__swe-1-7.json"
[[ -f "$ledger_file2" ]] || fail "repeated calls: ledger not created at $ledger_file2"
seat_dead2=$(jq -r '.seat_dead' "$ledger_file2")
[[ "$seat_dead2" == "false" ]] \
    || fail "mark_seat_config_fault_bench must NEVER set seat_dead=true even after 100 calls (config fault is infrastructure, NOT yield); got seat_dead=$seat_dead2 after 100 calls"
count2=$(jq -r '.consecutive_failure_count' "$ledger_file2")
[[ "$count2" == "100" ]] \
    || fail "repeated calls: consecutive_failure_count must be 100, got '$count2'"
ok "mark_seat_config_fault_bench: 100 repeated calls NEVER retire the seat (seat_dead=false, count=100) — config fault is infrastructure, not yield"

# ============================================================================
# 5. classify_death_error classifies the trust literal as config_fault_trust
# ============================================================================
out_file="$scratch/death-out.txt"
err_file="$scratch/death-err.txt"
printf 'Refusing to run in an untrusted workspace\n' >"$out_file"
: >"$err_file"

set +e
dec_out=$(bash -c 'source "$0"; load_seat_caps; classify_death_error "$1" "$2" "$3"' \
    "$lib" "$out_file" "$err_file" "" 2>/dev/null)
set -e
dec_cls=$(printf '%s\n' "$dec_out" | sed -n '1p')
[[ "$dec_cls" == "config_fault_trust" ]] \
    || fail "classify_death_error must classify the trust literal as config_fault_trust, got '$dec_cls'"
ok "classify_death_error: trust literal -> config_fault_trust (not unknown, not quota_cap)"

# 5b. A quota error must NOT be misclassified as config_fault_trust.
printf 'INFERENCE_CAP_ERROR: weekly limit. resets in 1d 11h\n' >"$out_file"
: >"$err_file"
set +e
dec_out=$(bash -c 'source "$0"; load_seat_caps; classify_death_error "$1" "$2" "$3"' \
    "$lib" "$out_file" "$err_file" "" 2>/dev/null)
set -e
dec_cls=$(printf '%s\n' "$dec_out" | sed -n '1p')
[[ "$dec_cls" == "quota_cap" ]] \
    || fail "classify_death_error must classify a quota error as quota_cap, got '$dec_cls'"
ok "classify_death_error: quota error -> quota_cap (not config_fault_trust)"

# ============================================================================
# 6. Regression pin: the config key name is skip_workspace_trust
# ============================================================================
# This is the regression test the issue explicitly requests. The vendor error
# message says respect_workspace_trust, but the CLI reads skip_workspace_trust.
# If a future change renames the key back to the misleading form, this fails.
[[ -f "$overlay" ]] || fail "overlay file must exist for the regression pin"
pin_key=$(jq -r 'keys | .[]' "$overlay" | sort | head -1)
[[ "$pin_key" == "skip_workspace_trust" ]] \
    || fail "REGRESSION PIN (fleet-ops#4825): the managed config key must be 'skip_workspace_trust', not '$pin_key'. The vendor error message says respect_workspace_trust but the CLI reads skip_workspace_trust — do not be misled again."
ok "REGRESSION PIN (fleet-ops#4825): managed config key is 'skip_workspace_trust' (not the misleading respect_workspace_trust)"

echo
echo "ALL OK: devin-config-trust.test.sh (fleet-ops#4825)"
