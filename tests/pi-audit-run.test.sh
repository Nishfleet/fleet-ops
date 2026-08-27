#!/usr/bin/env bash
# tests/pi-audit-run.test.sh
#
# fleet-ops#776: pi-audit senior auditor panel units fail when:
#   1. straitly seat fallback prints a literal "\t" instead of a real tab,
#      so provider and model are the malformed string "straitly\tgpt-5.6-sol".
#   2. an auditor returns a FAIL/PASS reason missing the required duplicate
#      or north-star keywords, causing pi-audit-run to exit 1 and the
#      systemd unit to exhaust StartLimitBurst.
#
# This test exercises the full pi-audit-run binary with stubbed gh, pi, and
# seat-lib. It proves the straitly fallback emits a real tab-separated
# provider/model pair and that an incomplete reason is padded, not rejected.

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
  # Force the straitly default off and the fallback gpt-5.6-sol on.
  if [[ "$1" == "straitly" && "$2" == "deepseek/deepseek-v4-pro" ]]; then
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
# Scenario 1: straitly fallback emits a real tab and the right provider/model.
# -----------------------------------------------------------------------------
reset_state() { rm -rf "$state_dir"; mkdir -p "$state_dir"; rm -f "$calls"; }

reset_state
PI_RESPONSE=$'FAIL\nThe candidate is not a duplicate and advances the north star.' \
  bash "$bin" 'demo--42--straitly' >"$scratch/scenario1.out" 2>"$scratch/scenario1.err" || true

[[ -f "$state_dir/demo/42/straitly.vote" ]] \
  || fail "scenario1: no straitly vote written ($(cat "$scratch/scenario1.err"))"
[[ $(jq -r '.verdict' "$state_dir/demo/42/straitly.vote") == "FAIL" ]] \
  || fail "scenario1: verdict should be FAIL"

# The pi stub records the provider/model it was called with.
[[ -s "$calls" ]] || fail "scenario1: pi was never called"
call_line=$(head -n1 "$calls")
# With the bug, this line would be "straitly\tgpt-5.6-sol\tstraitly\tgpt-5.6-sol".
call_prov=$(printf '%s\n' "$call_line" | cut -f1)
call_mod=$(printf '%s\n' "$call_line" | cut -f2)
[[ "$call_prov" == "straitly" ]] \
  || fail "scenario1: provider was '$call_prov' (expected 'straitly'); call_line='$call_line'"
[[ "$call_mod" == "gpt-5.6-sol" ]] \
  || fail "scenario1: model was '$call_mod' (expected 'gpt-5.6-sol'); call_line='$call_line'"
ok "scenario1: straitly fallback calls pi with provider=straitly, model=gpt-5.6-sol"

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

ok "pi-audit-run: straitly tab fallback fixed, incomplete reasons padded, missing verdict still fails"
