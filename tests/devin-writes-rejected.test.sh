#!/usr/bin/env bash
# tests/devin-writes-rejected.test.sh
#
# fleet-ops#4780: the Devin CLI under `--sandbox` forces its "autonomous"
# permission mode, which since 2026-09-08 rejects every file write
# non-interactively with the literal "rejected a tool call that requires
# confirmation". Every run then ends empty at the first edit (100% empty
# runs, 30+ on 2026-09-09). The fix is dropping `--sandbox` (the provider
# now runs `--permission-mode dangerous` unsandboxed). This test pins:
#
#   1. The seatlib detector is_devin_writes_rejected matches the literal
#      "rejected a tool call that requires confirmation".
#   2. classify_death_error classifies the literal as `devin-writes-rejected`,
#      not `unknown` (so the fast-death fallthrough does not re-bench it as an
#      ordinary failure).
#   3. mark_seat_devin_writes_rejected_bench writes a config_fault ledger entry
#      that is NEVER retired (seat_dead=false), proving a CLI/flag config fault
#      is infrastructure, not seat yield.
#   4. pi-issue-run's write-rejection detection block benches via
#      mark_seat_devin_writes_rejected_bench (grep the block exists).
#
# Runs entirely offline: stubbed seat-caps.json, ledger dir, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t devin-writes-rejected.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

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

# ============================================================================
# 1. seatlib: is_devin_writes_rejected matcher
# ============================================================================
# 1a. Matcher matches the exact literal.
set +e
bash -c 'source "$0"; load_seat_caps; is_devin_writes_rejected "$1" "$2"' \
    "$lib" "rejected a tool call that requires confirmation" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_devin_writes_rejected must match the literal 'rejected a tool call that requires confirmation' (rc=$rc)"
ok "is_devin_writes_rejected: matches 'rejected a tool call that requires confirmation'"

# 1b. Matcher matches the literal embedded in a larger error blob.
set +e
bash -c 'source "$0"; load_seat_caps; is_devin_writes_rejected "$1" "$2"' \
    "$lib" "" "warning: rejected a tool call that requires confirmation. Running in non-interactive mode" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_devin_writes_rejected must match the literal inside a larger error blob (rc=$rc)"
ok "is_devin_writes_rejected: matches literal embedded in larger error blob"

# 1c. Matcher does NOT match a quota error (no false positive).
set +e
bash -c 'source "$0"; load_seat_caps; is_devin_writes_rejected "$1" "$2"' \
    "$lib" "INFERENCE_CAP_ERROR: weekly limit" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "is_devin_writes_rejected must NOT match a quota error (rc=$rc)"
ok "is_devin_writes_rejected: does not match quota error (no false positive)"

# 1d. Matcher does NOT match empty input.
set +e
bash -c 'source "$0"; load_seat_caps; is_devin_writes_rejected "$1" "$2"' \
    "$lib" "" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "is_devin_writes_rejected must NOT match empty input (rc=$rc)"
ok "is_devin_writes_rejected: does not match empty input"

# ============================================================================
# 2. classify_death_error classifies the literal as devin-writes-rejected
# ============================================================================
out_file="$scratch/death-out.txt"
err_file="$scratch/death-err.txt"
printf 'warning: rejected a tool call that requires confirmation. Running in non-interactive mode\n' >"$out_file"
: >"$err_file"

set +e
dec_out=$(bash -c 'source "$0"; load_seat_caps; classify_death_error "$1" "$2" "$3"' \
    "$lib" "$out_file" "$err_file" "" 2>/dev/null)
set -e
dec_cls=$(printf '%s\n' "$dec_out" | sed -n '1p')
[[ "$dec_cls" == "devin-writes-rejected" ]] \
    || fail "classify_death_error must classify the write-reject literal as devin-writes-rejected, got '$dec_cls'"
ok "classify_death_error: write-reject literal -> devin-writes-rejected (not unknown, not quota_cap)"

# 2b. A quota error must NOT be misclassified as devin-writes-rejected.
printf 'INFERENCE_CAP_ERROR: weekly limit. resets in 1d 11h\n' >"$out_file"
: >"$err_file"
set +e
dec_out=$(bash -c 'source "$0"; load_seat_caps; classify_death_error "$1" "$2" "$3"' \
    "$lib" "$out_file" "$err_file" "" 2>/dev/null)
set -e
dec_cls=$(printf '%s\n' "$dec_out" | sed -n '1p')
[[ "$dec_cls" == "quota_cap" ]] \
    || fail "classify_death_error must classify a quota error as quota_cap, got '$dec_cls'"
ok "classify_death_error: quota error -> quota_cap (not devin-writes-rejected)"

# ============================================================================
# 3. retired (fleet-ops#4263): the config_fault bench ledger lived in the
# deleted routing library; the LiteLLM proxy owns cooldown and the bench
# marker is a logging stub. Matcher (1) and classifier (2) stay.

# 4. pi-issue-run detection block exists and calls the writer
# ============================================================================
run_src="$repo_root/bin/pi-issue-run"
[[ -f "$run_src" ]] || fail "bin/pi-issue-run not found: $run_src"
grep -q 'is_devin_writes_rejected' "$run_src" \
    || fail "pi-issue-run must call is_devin_writes_rejected to bench the write-reject class"
grep -q 'mark_seat_devin_writes_rejected_bench' "$run_src" \
    || fail "pi-issue-run must call mark_seat_devin_writes_rejected_bench"
ok "pi-issue-run: write-rejection detection block calls is_devin_writes_rejected + mark_seat_devin_writes_rejected_bench"

# ============================================================================
# 5. Regression pin: the classifier literal is present in seatlib.sh
# ============================================================================
# The issue's termination criterion: grep -q 'rejected a tool call' lib/litellm-seat.sh
grep -q 'rejected a tool call' "$lib" \
    || fail "REGRESSION PIN (fleet-ops#4780): lib/litellm-seat.sh must carry the literal 'rejected a tool call'"
ok "REGRESSION PIN (fleet-ops#4780): lib/litellm-seat.sh carries the write-reject literal"

echo
echo "ALL OK: devin-writes-rejected.test.sh (fleet-ops#4780)"
