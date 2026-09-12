#!/usr/bin/env bash
# tests/fleet-review-arm-check.test.sh
#
# fleet-ops#3709 (part 2/2 of #3264): reviewer-round fallback — when no
# entry of senior_seats_in_order is usable, the product worker opens the
# PR WITHOUT `gh pr merge --auto` and marks the body with the literal
# line `review: skipped, no capable seat` so the loose-ends surface it.
# Never skipped silently, never armed unreviewed.
#
# Replay drill. Offline. Proves:
#
#   1. senior_seat_available() returns 1 when every senior seat is
#      benched (quota_bench with a future bench_until), 0 when one is
#      usable.
#   2. bin/fleet-review-arm-check exits 1 when no senior seat is usable
#      (the "open without the arm + body line" gate) and 0 when one is.
#   3. prompts/worker.md carries the fallback instruction (the worker
#      knows to open without the arm and add the body line).
#
# Hosted by tests/ci-standards-audit.test.sh so P14 runs it without a
# workflow-file edit (workers cannot push .github/workflows/**).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/litellm-seat.sh"
arm_check="$repo_root/bin/fleet-review-arm-check"
worker="$repo_root/prompts/worker.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -x "$arm_check" ]] || fail "not executable: $arm_check"
[[ -f "$worker" ]] || fail "missing $worker"
command -v jq >/dev/null 2>&1 || fail "jq required"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d -t review-arm-check.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Offline: no live systemd / seat-health writes.
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_NOUSABLE_COOLDOWN_S=0

# A scratch cap map independent of the live fleet config. Two senior seats
# in senior_seats_in_order (cursor first, xai-oauth second).
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["ollama"],
  "senior_seats_in_order": ["cursor/cursor-grok-4.6-high", "xai-oauth/grok-4.6"],
  "providers": {
    "cursor":   { "cap": 1, "class": "subscription", "models": { "cursor-grok-4.6-high": 1 } },
    "xai-oauth": { "cap": 2, "class": "subscription", "models": { "grok-4.6": 2 } },
    "ollama":   { "cap": 2, "class": "free", "models": { "deepseek-v4-flash:0731": 2 } }
  }
}
JSON

ledger="$scratch/seats"
mkdir -p "$ledger"

# A future bench_until (quota_bench) benches a seat. The bench must be in
# the future relative to the REAL clock (seat_usable compares against now),
# so use a far-future wall.
BENCH_UNTIL="2099-01-01T00:00:00Z"

bench_seat() {
    local p="$1" m="$2"
    local ps ms
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    cat >"$ledger/${ps}__${ms}.json" <<JSON
{"health_class":"quota_bench","seat_dead":false,"observed_at":"${BENCH_UNTIL}","usable_at":"${BENCH_UNTIL}","bench_until":"${BENCH_UNTIL}","consecutive_failure_count":0}
JSON
}

unbench_seat() {
    local p="$1" m="$2"
    local ps ms
    ps="${p//[^A-Za-z0-9._-]/_}"
    ms="${m//[^A-Za-z0-9._-]/_}"
    rm -f "$ledger/${ps}__${ms}.json"
}

export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export PI_PACKET_STATE="$scratch/state"
mkdir -p "$PI_PACKET_STATE"

# --- 1. senior_seat_available(): all benched -> 1, one usable -> 0 --------
bench_seat cursor cursor-grok-4.6-high
bench_seat xai-oauth grok-4.6
set +e
out=$(bash -c 'source "$0"; load_seat_caps; senior_seat_available' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "1: all senior seats benched must be unavailable, got rc=$rc"
ok "1a: senior_seat_available returns 1 when every senior seat is benched"

unbench_seat xai-oauth grok-4.6
set +e
out=$(bash -c 'source "$0"; load_seat_caps; senior_seat_available' "$lib" 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "1b: one usable senior seat must be available, got rc=$rc"
ok "1b: senior_seat_available returns 0 when one senior seat is usable"

# --- 2. bin/fleet-review-arm-check: exit 1 when no senior seat ------------
bench_seat xai-oauth grok-4.6
set +e
"$arm_check" >"$scratch/arm.out" 2>"$scratch/arm.err"
arm_rc=$?
set -e
[[ "$arm_rc" == "1" ]] || fail "2a: arm-check must exit 1 when no senior seat usable, got $arm_rc ($(cat "$scratch/arm.err"))"
ok "2a: fleet-review-arm-check exits 1 when no senior seat usable (open without the arm)"

unbench_seat xai-oauth grok-4.6
set +e
"$arm_check" >"$scratch/arm2.out" 2>"$scratch/arm2.err"
arm_rc=$?
set -e
[[ "$arm_rc" == "0" ]] || fail "2b: arm-check must exit 0 when a senior seat is usable, got $arm_rc ($(cat "$scratch/arm2.err"))"
ok "2b: fleet-review-arm-check exits 0 when a senior seat is usable (arm allowed)"

# --help must print usage and exit 2 (not run a live check).
set +e
"$arm_check" --help >"$scratch/help.out" 2>&1
help_rc=$?
set -e
[[ "$help_rc" == "2" ]] || fail "2c: --help must exit 2, got $help_rc"
grep -q 'no capable' "$scratch/help.out" \
    || fail "2c: --help must document the fallback body line"
ok "2c: fleet-review-arm-check --help documents the fallback"

# --- 3. worker.md carries the fallback instruction -------------------------
grep -q 'review: skipped, no capable seat' "$worker" \
    || fail "4: worker.md must carry the fallback body line"
grep -q 'fleet-review-arm-check' "$worker" \
    || fail "4: worker.md must reference fleet-review-arm-check"
ok "3: worker.md carries the no-capable-seat fallback instruction"

echo "fleet-review-arm-check: PASS"
