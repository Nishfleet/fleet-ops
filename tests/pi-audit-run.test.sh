#!/usr/bin/env bash
# tests/pi-audit-run.test.sh
#
# fleet-ops#776: pi-audit senior auditor panel units fail when:
#   1. the senior role's seat ladder fallback prints a literal "\t" instead
#      of a real tab, so provider and model are a malformed single string.
#   2. an auditor returns a FAIL/PASS reason missing the required duplicate
#      or north-star keywords, causing pi-audit-run to exit 1 and the
#      systemd unit to exhaust StartLimitBurst.
#
# This test exercises the full pi-audit-run binary with stubbed gh, pi, and
# seat-lib. It proves the senior ladder emits a real tab-separated
# provider/model pair (walled first entry falls through to the next), that
# an incomplete reason is padded not rejected, and that a fully-walled lane
# is a lane fault (exit 0, no vote).

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-audit-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t pi-audit-run.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME" "$scratch/state"

# --- fake gh -----------------------------------------------------------------
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"issue view"*"--json"*)
    printf '{"title":"test issue","body":"test body","labels":[]}\n'
    exit 0
    ;;
  *"pr list"*|*"issue list"*)
    printf '[]\n'
    exit 0
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$gh_fake"

# --- fake pi -----------------------------------------------------------------
pi_fake="$scratch/pi"
cat >"$pi_fake" <<'FAKE'
#!/usr/bin/env bash
prov="" mod=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print)   shift ;;
    --provider) prov="$2"; shift 2 ;;
    --model)    mod="$2"; shift 2 ;;
    *)          shift ;;
  esac
done
printf '%s\t%s\n' "$prov" "$mod" >>"${PI_CALLS:-/dev/null}"
# Discard the packet so the caller does not see a broken pipe.
if [[ -n "${PI_DUMP_PACKET:-}" ]]; then
  cat >"$PI_DUMP_PACKET"
else
  cat >/dev/null
fi
if [[ "${PI_FAIL:-0}" == "1" ]]; then
  printf 'simulated pi failure\n' >&2
  exit 1
fi
printf '%s' "${PI_RESPONSE:-}"
FAKE
chmod +x "$pi_fake"

# --- fake seat-lib -----------------------------------------------------------
# Provides only the helpers pi-audit-run uses. The default straitly seat is
# unavailable so the fallback path (the one with the "\t" bug) is exercised.
seat_lib="$scratch/seat-lib.sh"
cat >"$seat_lib" <<'LIB'
# shellcheck shell=bash
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HOME="${HOME:-/home/nish}"

load_seat_caps() { :; }

enumerate_seats() {
  printf '%s\t%s\t-\t1\n' commandcode deepseek/deepseek-v4-flash
  printf '%s\t%s\t-\t1\n' commandcode minimax/minimax-m3-free
  printf '%s\t%s\t-\t1\n' hetzner Qwen/Qwen3.6-35B-A3B-FP8
  printf '%s\t%s\t-\t1\n' straitly deepseek/deepseek-v4-pro
  printf '%s\t%s\t-\t1\n' straitly gpt-5.6-sol
  printf '%s\t%s\t-\t1\n' devin glm-5-2
}

class_of() {
  case "$1" in
    commandcode|hetzner|opencode|orcarouter|groq|inferx) printf 'free\n' ;;
    straitly|zenmux|openrouter|minimax|openrouter-anthropic) printf 'metered\n' ;;
    devin|cursor|cline|ollama) printf 'prepaid-quota\n' ;;
    *) printf '\n' ;;
  esac
}

model_cap() { printf '1\n'; }

seat_usable() {
  # fleet-ops#3121: within the senior ladder (seat-caps senior_seats_in_order)
  # the FIRST usable seat wins. Make cursor (first entry) unusable so the
  # resolver falls through to the second ladder entry xai-oauth/grok-4.6 —
  # proving "walled role resolves to its fallback" inside the ladder.
  if [[ "$1" == "cursor" ]]; then
    return 1
  fi
  return 0
}

seat_ledger_path() { printf '%s/%s__%s.json\n' "${PI_SEAT_HEALTH_LEDGER_DIR:-/dev/null}" "$1" "$2"; }
LIB

# --- prompt and plan ---------------------------------------------------------
prompt="$scratch/auditor.md"
cat >"$prompt" <<'EOF'
# Senior auditor

Respond with exactly two lines then stop:

PASS
<one paragraph reason>

OR

FAIL
<one paragraph reason>

Your one-paragraph reason MUST include these exact keywords:
1. duplicate/duplicates
2. north-star/customer/edge/parity/beat
EOF

plan="$scratch/plan.md"
cat >"$plan" <<'EOF'
# Decisions ledger

- north-star: beat the customer's own edge AI
EOF

calls="$scratch/pi-calls"
state_dir="$scratch/audit-state"
mkdir -p "$state_dir"

export AUDIT_GH="$gh_fake"
export PI_BIN="$pi_fake"
export PI_PACKET_SEAT_LIB="$seat_lib"
export AUDIT_PROMPT="$prompt"
export AUDIT_PLAN_FILE="$plan"
export AUDIT_STATE_DIR="$state_dir"
export PI_CALLS="$calls"

# -----------------------------------------------------------------------------
# Scenario 1: the senior role (replaces dead straitly) resolves to the first
# usable seat in senior_seats_in_order. cursor (first entry) is walled, so the
# resolver falls through to the second ladder entry xai-oauth/grok-4.6.
# -----------------------------------------------------------------------------
reset_state() { rm -rf "$state_dir"; mkdir -p "$state_dir"; rm -f "$calls"; }

reset_state
PI_RESPONSE=$'FAIL\nThe candidate is not a duplicate and advances the north star.' \
  bash "$bin" 'demo--42--senior' >"$scratch/scenario1.out" 2>"$scratch/scenario1.err" || true

[[ -f "$state_dir/demo/42/senior.vote" ]] \
  || fail "scenario1: no senior vote written ($(cat "$scratch/scenario1.err"))"
[[ $(jq -r '.verdict' "$state_dir/demo/42/senior.vote") == "FAIL" ]] \
  || fail "scenario1: verdict should be FAIL"

# The pi stub records the provider/model it was called with.
[[ -s "$calls" ]] || fail "scenario1: pi was never called"
call_line=$(head -n1 "$calls")
call_prov=$(printf '%s\n' "$call_line" | cut -f1)
call_mod=$(printf '%s\n' "$call_line" | cut -f2)
[[ "$call_prov" == "xai-oauth" ]] \
  || fail "scenario1: provider was '$call_prov' (expected 'xai-oauth'); call_line='$call_line'"
[[ "$call_mod" == "grok-4.6" ]] \
  || fail "scenario1: model was '$call_mod' (expected 'grok-4.6'); call_line='$call_line'"
ok "scenario1: senior falls through walled cursor to xai-oauth/grok-4.6, emits real tab-separated provider/model"

# -----------------------------------------------------------------------------
# Scenario 2: free-glm-5-3 auditor returns FAIL with an incomplete reason;
# the runner pads the missing keywords and writes the vote instead of failing.
# -----------------------------------------------------------------------------
reset_state
export AUDIT_FREE_GLM53_SEAT='commandcode:deepseek/deepseek-v4-flash'
PI_RESPONSE=$'FAIL\nThis is a vague idea without a concrete termination command.' \
  bash "$bin" 'demo--43--free-glm-5-3' >"$scratch/scenario2.out" 2>"$scratch/scenario2.err"

[[ -f "$state_dir/demo/43/free-glm-5-3.vote" ]] \
  || fail "scenario2: no free-glm-5-3 vote written (rc would be non-zero): $(cat "$scratch/scenario2.err")"

vote_reason=$(jq -r '.reason' "$state_dir/demo/43/free-glm-5-3.vote")
[[ $(jq -r '.verdict' "$state_dir/demo/43/free-glm-5-3.vote") == "FAIL" ]] \
  || fail "scenario2: verdict should be FAIL"

# The padded reason must contain both keyword groups.
[[ "${vote_reason,,}" == *"duplicate"* ]] \
  || fail "scenario2: padded reason missing 'duplicate': $vote_reason"
[[ "${vote_reason,,}" == *"north star"* || "${vote_reason,,}" == *"north-star"* || "${vote_reason,,}" == *"northstar"* ]] \
  || fail "scenario2: padded reason missing north-star keyword: $vote_reason"
ok "scenario2: incomplete reason is padded, vote written, exit 0"

unset AUDIT_FREE_GLM53_SEAT

# -----------------------------------------------------------------------------
# Scenario 3: valid PASS with complete reason still writes cleanly.
# -----------------------------------------------------------------------------
reset_state
PI_RESPONSE=$'PASS\nNo duplicate; beats customer edge AI and advances the north star.' \
  bash "$bin" 'demo--44--devin' >"$scratch/scenario3.out" 2>"$scratch/scenario3.err"

[[ -f "$state_dir/demo/44/devin.vote" ]] \
  || fail "scenario3: no devin vote written"
[[ $(jq -r '.verdict' "$state_dir/demo/44/devin.vote") == "PASS" ]] \
  || fail "scenario3: verdict should be PASS"
ok "scenario3: complete PASS reason writes vote and exits 0"

# -----------------------------------------------------------------------------
# Scenario 4: missing verdict still exits 1 (systemd may retry once).
# -----------------------------------------------------------------------------
reset_state
PI_RESPONSE=$'some random text\nwith no verdict' \
  bash "$bin" 'demo--45--devin' >"$scratch/scenario4.out" 2>"$scratch/scenario4.err" || rc=$?
[[ "${rc:-0}" == "1" ]] || fail "scenario4: missing verdict must exit 1, got rc=${rc:-0}"
[[ ! -f "$state_dir/demo/45/devin.vote" ]] \
    || fail "scenario4: vote must not be written when verdict is missing"
ok "scenario4: missing verdict still exits 1"

# -----------------------------------------------------------------------------
# Scenario 5: seat-health preflight refuses a transient_fault seat
#              (fleet-ops#146 storm-tolerant panel).
# The per-seat ledger file names the provider+model; a transient_fault
# marker tells the runner to write a SKIP vote (exit 0) and not call
# pi. The preflight fires BEFORE the packet build, so the SKIP vote
# has the same shape as a real vote and the panel can tally on it.
# -----------------------------------------------------------------------------
reset_state
seat_health_dir="$scratch/seat-health"
mkdir -p "$seat_health_dir"
# devin/glm-5-2 is in transient_fault.
cat >"$seat_health_dir/devin__glm-5-2.json" <<'LEDGER'
{
  "health_class":"transient_fault",
  "seat_dead":false,
  "observed_at":"2026-08-27T05:55:00Z",
  "poison_ladder":false
}
LEDGER
# Free seat is healthy.
cat >"$seat_health_dir/commandcode__minimax-minimax-m3-free.json" <<'LEDGER'
{
  "health_class":"healthy",
  "seat_dead":false,
  "observed_at":"2026-08-27T05:55:00Z",
  "poison_ladder":false
}
LEDGER

export PI_SEAT_HEALTH_LEDGER_DIR="$seat_health_dir"
set +e
PI_RESPONSE=$'PASS\nthis should never be called' \
  bash "$bin" 'demo--46--devin' >"$scratch/scenario5.out" 2>"$scratch/scenario5.err"
rc5=$?
set -e
unset PI_SEAT_HEALTH_LEDGER_DIR

[[ "$rc5" == 0 ]] || fail "scenario5: preflight SKIP must exit 0, got $rc5 ($(cat "$scratch/scenario5.err"))"
[[ -f "$state_dir/demo/46/devin.vote" ]] \
    || fail "scenario5: SKIP vote must be written ($(cat "$scratch/scenario5.err"))"
[[ $(jq -r '.verdict' "$state_dir/demo/46/devin.vote") == "SKIP" ]] \
    || fail "scenario5: verdict must be SKIP, got $(jq -r '.verdict' "$state_dir/demo/46/devin.vote")"
# pi should NOT have been called.
[[ ! -s "$calls" ]] || fail "scenario5: preflight refused call; pi should not run (calls=$(cat "$calls"))"
ok "scenario5: seat-health preflight writes SKIP vote and skips pi for transient_fault seat"

# -----------------------------------------------------------------------------
# Scenario 6: provider wall during the call -> SKIP vote (not exit 1).
# On 2026-08-27 the live pi-audit-run exited 1 on a commandcode wall,
# which tripped Restart=on-failure and exhausted StartLimitBurst=2 in
# two ticks. The runner now writes SKIP and exits 0 so the unit does
# not auto-restart, and the heartbeat retries the next tick when the
# seat is healthy.
# -----------------------------------------------------------------------------
reset_state
export PI_FAIL=1
set +e
bash "$bin" 'demo--47--free-glm-5-3' >"$scratch/scenario6.out" 2>"$scratch/scenario6.err"
rc6=$?
set -e
unset PI_FAIL

[[ "$rc6" == 0 ]] || fail "scenario6: provider wall must exit 0 (SKIP path), got $rc6"
[[ -f "$state_dir/demo/47/free-glm-5-3.vote" ]] \
    || fail "scenario6: SKIP vote must be written ($(cat "$scratch/scenario6.err"))"
[[ $(jq -r '.verdict' "$state_dir/demo/47/free-glm-5-3.vote") == "SKIP" ]] \
    || fail "scenario6: verdict must be SKIP, got $(jq -r '.verdict' "$state_dir/demo/47/free-glm-5-3.vote")"
reason6=$(jq -r '.reason' "$state_dir/demo/47/free-glm-5-3.vote")
[[ "$reason6" == *"transient failure"* ]] \
    || fail "scenario6: reason should mention transient failure, got: $reason6"
ok "scenario6: provider wall writes SKIP vote, exit 0 (no auto-restart, no StartLimit burn)"

# -----------------------------------------------------------------------------
# Scenario 7: fleet-ops#1011. pi-audit-run sources seat-lib.sh, which
# itself sets STATE_DIR=$HOME/.local/state/pi-packet for its own
# attempts/active-seats ledger. Without the VOTE_DIR rename, the source
# silently overwrites pi-audit-run's STATE_DIR and the vote lands in
# pi-packet/ where the heartbeat-auditor never reads it. The senior
# admission panel is then permanently starved, scout-candidate issues
# never graduate to agent-ready, and the ready buffer stays below 12h
# forever — exactly the green-and-empty scout futility that #454 was
# supposed to escalate. The #1011 live instance stayed open for the
# same reason. This scenario sources a stub seat-lib that mirrors the
# real one (it sets STATE_DIR) and asserts the vote lands in the
# AUDIT_STATE_DIR override, not the seat-lib's STATE_DIR.
# -----------------------------------------------------------------------------
reset_state
audit_dir="$scratch/audit-1011"
mkdir -p "$audit_dir"
seaty="$scratch/seat-lib-buggy.sh"
cat >"$seaty" <<'LIB'
# shellcheck shell=bash
# Mirrors the real seat-lib.sh variable clobber (fleet-ops#1011).
STATE_DIR="${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}"
export STATE_DIR

load_seat_caps() { :; }

enumerate_seats() {
  printf '%s\t%s\t-\t1\n' devin glm-5-2
}

class_of()   { printf 'prepaid-quota\n'; }
model_cap()  { printf '1\n'; }
seat_usable(){ return 0; }
seat_ledger_path() { printf '%s/%s__%s.json\n' "/dev/null" "$1" "$2"; }
LIB

export PI_PACKET_SEAT_LIB="$seaty"
export AUDIT_STATE_DIR="$audit_dir"
# Sanity: the seat-lib clobbers STATE_DIR; the runner must NOT use that.
PI_RESPONSE=$'PASS\nThis is a complete reason with duplicate and north-star keywords.' \
  bash "$bin" 'demo--48--devin' >"$scratch/scenario7.out" 2>"$scratch/scenario7.err"
unset PI_PACKET_SEAT_LIB
unset AUDIT_STATE_DIR

# Vote must land in AUDIT_STATE_DIR ($audit_dir), NOT in seat-lib's
# $HOME/.local/state/pi-packet. The real fleet_ops/a/a votes are
# invisible to the heartbeat-auditor when this fix is missing.
[[ -f "$audit_dir/demo/48/devin.vote" ]] \
  || fail "scenario7: vote missing from AUDIT_STATE_DIR ($audit_dir) — seat-lib STATE_DIR clobber not contained ($(cat "$scratch/scenario7.err"))"
verdict7=$(jq -r '.verdict' "$audit_dir/demo/48/devin.vote")
[[ "$verdict7" == "PASS" ]] || fail "scenario7: vote verdict was '$verdict7' (expected PASS)"

# Defensive: a stray vote in seat-lib's STATE_DIR proves the bug. It
# must NOT exist; the fix must keep pi-audit-run out of pi-packet.
[[ ! -f "/home/nish/.local/state/pi-packet/demo/48/devin.vote" ]] \
  || fail "scenario7: vote leaked to seat-lib STATE_DIR (/home/nish/.local/state/pi-packet/demo/48/devin.vote) — VOTE_DIR rename did not contain the clobber"
ok "scenario7: seat-lib STATE_DIR clobber contained — vote lands in AUDIT_STATE_DIR, not in pi-packet"

# -----------------------------------------------------------------------------
# Scenario 8: fully-walled auditor lane -> exit 0, NO vote written, no pi call.
# fleet-ops#146 addendum: an auditor seat wall is a LANE FAULT (bounded retry
# through the ladder, never charged to the candidate; candidate stays PENDING).
# Before the fix, resolve_seat failure exited 1, which failed the unit, burned
# StartLimitBurst, and the heartbeat's re-start of the failed unit tripped a
# NEW STOP-REASON + auditor summon EVERY tick while the seat stayed walled
# (2026-08-29: 73 straitly-audit unit failures in a day, 228 journal lines on
# 0509#1440-straitly alone). The vote must stay MISSING so the heartbeat
# re-starts this unit when the wall clears and a real PASS/FAIL lands.
# -----------------------------------------------------------------------------
reset_state
wall_lib="$scratch/seat-lib-wall.sh"
cat >"$wall_lib" <<'LIB'
# shellcheck shell=bash
# Total wall: every seat unusable.
load_seat_caps() { :; }
enumerate_seats() {
  printf '%s\t%s\t-\t1\n' straitly deepseek/deepseek-v4-pro
  printf '%s\t%s\t-\t1\n' straitly gpt-5.6-sol
  printf '%s\t%s\t-\t1\n' devin glm-5-2
}
class_of() { printf 'metered\n'; }
model_cap() { printf '1\n'; }
seat_usable() { return 1; }
seat_ledger_path() { printf '%s/%s__%s.json\n' "/dev/null" "$1" "$2"; }
LIB

unset PI_SEAT_HEALTH_LEDGER_DIR
set +e
PI_PACKET_SEAT_LIB="$wall_lib" \
  bash "$bin" 'demo--49--straitly' >"$scratch/scenario8.out" 2>"$scratch/scenario8.err"
rc8=$?
set -e
unset PI_PACKET_SEAT_LIB

[[ "$rc8" == 0 ]] || fail "scenario8: walled lane must exit 0 (lane fault), got $rc8 ($(cat "$scratch/scenario8.err"))"
[[ ! -f "$state_dir/demo/49/straitly.vote" ]] \
  || fail "scenario8: no vote must be written on a walled lane (vote file exists at $state_dir/demo/49/straitly.vote)"
grep -q 'no usable seat' "$scratch/scenario8.err" \
  || fail "scenario8: log must say 'no usable seat' ($(cat "$scratch/scenario8.err"))"
[[ ! -s "$calls" ]] || fail "scenario8: pi must NOT be called on a walled lane (calls=$(cat "$calls"))"
ok "scenario8: fully-walled lane exits 0, writes NO vote, calls no pi (candidate stays PENDING, no escalation storm)"

ok "pi-audit-run: straitly tab fallback fixed, incomplete reasons padded, missing verdict still fails, #1011 clobber contained, walled lane is a lane fault"
