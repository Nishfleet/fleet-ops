#!/usr/bin/env bash
# tests/pi-seat-source-litellm.test.sh
#
# Proves the fleet-ops#4130 P3a PI_SEAT_SOURCE=litellm env switch routes the
# worker seat-selection callers to their LiteLLM proxy group instead of
# pick_seat, while the default seat-lib path is unchanged.
#
#   pi-issue-run        -> litellm-worker/worker-cheap (light) | worker-capable (heavy)
#                          litellm-private/worker-private for a private-repo target
#   pi-packet-run       -> litellm-worker/worker-cheap (light) | worker-capable (heavy)
#                          litellm-private/worker-private for a private-repo target
#   pi-scout-run        -> litellm-worker/worker-cheap
#   pi-audit-run        -> litellm-worker/worker-cheap
#   fleet-researcher-run-> litellm-worker/worker-cheap
#
# Runs offline: seat-lib, systemctl, worker-token and pi are all stubbed. No
# Claude, no systemd user session, no network, no live state dir.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t pi-seat-source.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"
mkdir -p "$HOME"

# --- stub App identity (P14) so pi-issue-run reaches the seat pick ----------
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
STUB
chmod +x "$stub_bin/worker-token"
export WORKER_TOKEN_BIN="$stub_bin/worker-token"
export PATH="$stub_bin:$PATH"

# --- stub seat-lib: pick_seat would return devin/glm-5-2; the litellm path
# must NOT call it. seat_log is a no-op.
stub_lib="$scratch/seat-lib.sh"
cat >"$stub_lib" <<'LIB'
# shellcheck shell=bash
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HOME="${HOME:-/home/nish}"
STATE_DIR="${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}"
ATTEMPTS_DIR="$STATE_DIR/attempts"
ACTIVE_SEATS_DIR="$STATE_DIR/active-seats"
LEDGER_DIR="${PI_SEAT_HEALTH_LEDGER_DIR:-$HOME/.local/state/lanes/seats}"
SPAWN_FAIL_MAX_S="${SPAWN_FAIL_MAX_S:-120}"
EMPTY_RUN_BACKOFF_S="${EMPTY_RUN_BACKOFF_S:-900}"
mkdir -p "$ATTEMPTS_DIR" "$ACTIVE_SEATS_DIR"
seat_log() { :; }
task_weight() { echo "light"; }
packet_difficulty() {
  local f="${1:-}"
  if [[ -n "$f" && -f "$f" ]] && grep -q '^difficulty: heavy' "$f" 2>/dev/null; then
    echo "heavy"
  else
    echo "light"
  fi
}
packet_repo() { echo ""; }
repo_privacy() { echo "public"; }
packet_id_from_path() { echo "testpkt"; }
pick_seat() { printf 'devin\tglm-5-2\n'; }
register_active_seat() { :; }
clear_active_seat() { :; }
mark_seat_spawn_fail() { return 1; }
mark_seat_empty_run() { return 1; }
mark_seat_quota_bench() { return 1; }
mark_seat_hang_bench() { return 1; }
mark_seat_overload_bench() { return 1; }
mark_seat_worked_no_text() { return 1; }
reset_seat_worked_no_text() { :; }
seat_usable() { return 0; }
provider_remote_agent() { return 1; }
is_empty_run() { return 1; }
session_tool_calls() { echo 0; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
is_overload_error() { return 1; }
is_mid_session_death() { return 1; }
seat_hang_timeout_s() { echo 2520; }
has_session_pr_url() { return 1; }
LIB

# --- stub pi: record args, emit >= OUT_MIN bytes ---------------------------
fake_pi="$scratch/pi"
cat >"$fake_pi" <<'PI'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PI_RECORD_ARGS"
cat > "$PI_RECORD_STDIN"
printf 'real output that is comfortably above the OUT_MIN threshold\n'
PI
chmod +x "$fake_pi"

STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
ISSUES_DIR="$scratch/issues"
mkdir -p "$ISSUES_DIR"

export PI_PACKET_STATE="$STATE_DIR"
export PI_ISSUES_DIR="$ISSUES_DIR"
export PI_BIN="$fake_pi"
export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_PACKET_ASSEMBLY_LIB="$repo_root/lib/packet-assembly.sh"
export SCOUT_PROMPT_DIR="$repo_root/prompts"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_LIB_CHECK_TRANSPORT=0
export PI_SUBAGENT_EXTLOAD_CHECK=0

record_args="$scratch/pi.args"
record_stdin="$scratch/pi.stdin"
export PI_RECORD_ARGS="$record_args"
export PI_RECORD_STDIN="$record_stdin"

# --- pi-issue-run: light -> litellm/worker-cheap ----------------------------
pkt="$ISSUES_DIR/test.in"
cat >"$pkt" <<'PKT'
TARGET: repo Nishfleet/fleet-ops issue 1 unit test
PKT
export PI_SEAT_SOURCE=litellm
rm -f "$record_args" "$record_stdin"
set +e
"$repo_root/bin/pi-issue-run" test >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pi-issue-run litellm light must exit 0, got $rc"
grep -q -- '--provider litellm-worker' "$record_args" \
  || fail "pi-issue-run litellm must use --provider litellm-worker, got: $(cat "$record_args")"
grep -q -- '--model worker-cheap' "$record_args" \
  || fail "pi-issue-run litellm light must use --model worker-cheap, got: $(cat "$record_args")"
ok "pi-issue-run PI_SEAT_SOURCE=litellm light -> litellm-worker/worker-cheap"

# --- pi-issue-run: heavy -> litellm-worker/worker-capable -------------------
cat >"$pkt" <<'PKT'
difficulty: heavy
TARGET: repo Nishfleet/fleet-ops issue 1 unit test
PKT
rm -f "$record_args" "$record_stdin"
set +e
"$repo_root/bin/pi-issue-run" test >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pi-issue-run litellm heavy must exit 0, got $rc"
grep -q -- '--provider litellm-worker' "$record_args" \
  || fail "pi-issue-run litellm heavy must use --provider litellm-worker, got: $(cat "$record_args")"
grep -q -- '--model worker-capable' "$record_args" \
  || fail "pi-issue-run litellm heavy must use --model worker-capable, got: $(cat "$record_args")"
ok "pi-issue-run PI_SEAT_SOURCE=litellm heavy -> litellm-worker/worker-capable"

# --- pi-issue-run: private repo -> litellm-private/worker-private -----------
cat >"$pkt" <<'PKT'
TARGET: repo Nishfleet/siterep-public issue 1 unit test
PKT
# stub repo_privacy to return private for this repo
cat >"$stub_lib" <<'LIB'
# shellcheck shell=bash
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HOME="${HOME:-/home/nish}"
STATE_DIR="${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}"
ATTEMPTS_DIR="$STATE_DIR/attempts"
ACTIVE_SEATS_DIR="$STATE_DIR/active-seats"
LEDGER_DIR="${PI_SEAT_HEALTH_LEDGER_DIR:-$HOME/.local/state/lanes/seats}"
SPAWN_FAIL_MAX_S="${SPAWN_FAIL_MAX_S:-120}"
EMPTY_RUN_BACKOFF_S="${EMPTY_RUN_BACKOFF_S:-900}"
mkdir -p "$ATTEMPTS_DIR" "$ACTIVE_SEATS_DIR"
seat_log() { :; }
task_weight() { echo "light"; }
packet_difficulty() {
  local f="${1:-}"
  if [[ -n "$f" && -f "$f" ]] && grep -q '^difficulty: heavy' "$f" 2>/dev/null; then
    echo "heavy"
  else
    echo "light"
  fi
}
packet_repo() { echo "siterep-public"; }
repo_privacy() { echo "private"; }
packet_id_from_path() { echo "testpkt"; }
pick_seat() { printf 'devin\tglm-5-2\n'; }
register_active_seat() { :; }
clear_active_seat() { :; }
mark_seat_spawn_fail() { return 1; }
mark_seat_empty_run() { return 1; }
mark_seat_quota_bench() { return 1; }
mark_seat_hang_bench() { return 1; }
mark_seat_overload_bench() { return 1; }
mark_seat_worked_no_text() { return 1; }
reset_seat_worked_no_text() { :; }
seat_usable() { return 0; }
provider_remote_agent() { return 1; }
is_empty_run() { return 1; }
session_tool_calls() { echo 0; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
is_overload_error() { return 1; }
is_mid_session_death() { return 1; }
seat_hang_timeout_s() { echo 2520; }
has_session_pr_url() { return 1; }
LIB
rm -f "$record_args" "$record_stdin"
set +e
"$repo_root/bin/pi-issue-run" test >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pi-issue-run litellm private must exit 0, got $rc"
grep -q -- '--provider litellm-private' "$record_args" \
  || fail "pi-issue-run litellm private must use --provider litellm-private, got: $(cat "$record_args")"
grep -q -- '--model worker-private' "$record_args" \
  || fail "pi-issue-run litellm private must use --model worker-private, got: $(cat "$record_args")"
ok "pi-issue-run PI_SEAT_SOURCE=litellm private repo -> litellm-private/worker-private"

# restore the public stub for the remaining cases
cat >"$stub_lib" <<'LIB'
# shellcheck shell=bash
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export HOME="${HOME:-/home/nish}"
STATE_DIR="${PI_PACKET_STATE:-$HOME/.local/state/pi-packet}"
ATTEMPTS_DIR="$STATE_DIR/attempts"
ACTIVE_SEATS_DIR="$STATE_DIR/active-seats"
LEDGER_DIR="${PI_SEAT_HEALTH_LEDGER_DIR:-$HOME/.local/state/lanes/seats}"
SPAWN_FAIL_MAX_S="${SPAWN_FAIL_MAX_S:-120}"
EMPTY_RUN_BACKOFF_S="${EMPTY_RUN_BACKOFF_S:-900}"
mkdir -p "$ATTEMPTS_DIR" "$ACTIVE_SEATS_DIR"
seat_log() { :; }
task_weight() { echo "light"; }
packet_difficulty() {
  local f="${1:-}"
  if [[ -n "$f" && -f "$f" ]] && grep -q '^difficulty: heavy' "$f" 2>/dev/null; then
    echo "heavy"
  else
    echo "light"
  fi
}
packet_repo() { echo ""; }
repo_privacy() { echo "public"; }
packet_id_from_path() { echo "testpkt"; }
pick_seat() { printf 'devin\tglm-5-2\n'; }
register_active_seat() { :; }
clear_active_seat() { :; }
mark_seat_spawn_fail() { return 1; }
mark_seat_empty_run() { return 1; }
mark_seat_quota_bench() { return 1; }
mark_seat_hang_bench() { return 1; }
mark_seat_overload_bench() { return 1; }
mark_seat_worked_no_text() { return 1; }
reset_seat_worked_no_text() { :; }
seat_usable() { return 0; }
provider_remote_agent() { return 1; }
is_empty_run() { return 1; }
session_tool_calls() { echo 0; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
is_overload_error() { return 1; }
is_mid_session_death() { return 1; }
seat_hang_timeout_s() { echo 2520; }
has_session_pr_url() { return 1; }
LIB

# --- pi-issue-run: default seat-lib unchanged ------------------------------
unset PI_SEAT_SOURCE
cat >"$pkt" <<'PKT'
TARGET: repo Nishfleet/fleet-ops issue 1 unit test
PKT
rm -f "$record_args" "$record_stdin"
set +e
"$repo_root/bin/pi-issue-run" test >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pi-issue-run default seat-lib must exit 0, got $rc"
grep -q -- '--provider devin' "$record_args" \
  || fail "pi-issue-run default must use pick_seat provider devin, got: $(cat "$record_args")"
grep -q -- '--model glm-5-2' "$record_args" \
  || fail "pi-issue-run default must use pick_seat model glm-5-2, got: $(cat "$record_args")"
ok "pi-issue-run default seat-lib unchanged (devin/glm-5-2)"

# --- pi-packet-run: light -> litellm-worker/worker-cheap --------------------
export PI_SEAT_SOURCE=litellm
export PI_PACKET_RUN_OUT_MIN=1
pkt2="$scratch/pkt2.md"
cat >"$pkt2" <<'PKT'
TARGET: repo Nishfleet/fleet-ops issue 1 unit test
PKT
rm -f "$record_args" "$record_stdin"
set +e
"$repo_root/bin/pi-packet-run" "$pkt2" "$scratch" "" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pi-packet-run litellm light must exit 0, got $rc"
grep -q -- '--provider litellm-worker' "$record_args" \
  || fail "pi-packet-run litellm must use --provider litellm-worker, got: $(cat "$record_args")"
grep -q -- '--model worker-cheap' "$record_args" \
  || fail "pi-packet-run litellm light must use --model worker-cheap, got: $(cat "$record_args")"
ok "pi-packet-run PI_SEAT_SOURCE=litellm light -> litellm-worker/worker-cheap"

# --- pi-packet-run: heavy -> litellm-worker/worker-capable -----------------
cat >"$pkt2" <<'PKT'
difficulty: heavy
TARGET: repo Nishfleet/fleet-ops issue 1 unit test
PKT
rm -f "$record_args" "$record_stdin"
set +e
"$repo_root/bin/pi-packet-run" "$pkt2" "$scratch" "" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pi-packet-run litellm heavy must exit 0, got $rc"
grep -q -- '--provider litellm-worker' "$record_args" \
  || fail "pi-packet-run litellm heavy must use --provider litellm-worker, got: $(cat "$record_args")"
grep -q -- '--model worker-capable' "$record_args" \
  || fail "pi-packet-run litellm heavy must use --model worker-capable, got: $(cat "$record_args")"
ok "pi-packet-run PI_SEAT_SOURCE=litellm heavy -> litellm-worker/worker-capable"

# --- pi-scout-run: -> litellm-worker/worker-cheap ---------------------------
rm -f "$record_args" "$record_stdin"
set +e
"$repo_root/bin/pi-scout-run" fleet-ops scout >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pi-scout-run litellm must exit 0, got $rc"
grep -q -- '--provider litellm-worker' "$record_args" \
  || fail "pi-scout-run litellm must use --provider litellm-worker, got: $(cat "$record_args")"
grep -q -- '--model worker-cheap' "$record_args" \
  || fail "pi-scout-run litellm must use --model worker-cheap, got: $(cat "$record_args")"
ok "pi-scout-run PI_SEAT_SOURCE=litellm -> litellm-worker/worker-cheap"

# --- fleet-researcher-run: -> litellm-worker/worker-cheap -------------------
export RESEARCHER_STATE_DIR="$scratch/researcher-state"
export RESEARCHER_DRY_RUN=0
export RESEARCHER_PROMPT="$repo_root/prompts/researcher.md"
export RESEARCHER_LIB="$repo_root/lib/researcher-delta.py"
rm -f "$record_args" "$record_stdin"
set +e
"$repo_root/bin/fleet-researcher-run" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "fleet-researcher-run litellm must exit 0, got $rc"
grep -q -- '--provider litellm-worker' "$record_args" \
  || fail "fleet-researcher-run litellm must use --provider litellm-worker, got: $(cat "$record_args")"
grep -q -- '--model worker-cheap' "$record_args" \
  || fail "fleet-researcher-run litellm must use --model worker-cheap, got: $(cat "$record_args")"
ok "fleet-researcher-run PI_SEAT_SOURCE=litellm -> litellm-worker/worker-cheap"

# --- pi-audit-run: -> litellm-worker/worker-cheap ---------------------------
export AUDIT_STATE_DIR="$scratch/audit-state"
export AUDIT_PROMPT="$repo_root/prompts/auditor.md"
export AUDIT_DRY_RUN=1
rm -f "$record_args" "$record_stdin"
set +e
out=$("$repo_root/bin/pi-audit-run" fleet-ops--1--devin 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pi-audit-run litellm must exit 0, got $rc"
printf '%s\n' "$out" | grep -q 'litellm-worker/worker-cheap' \
  || fail "pi-audit-run litellm must resolve to litellm-worker/worker-cheap, got: $out"
ok "pi-audit-run PI_SEAT_SOURCE=litellm -> litellm-worker/worker-cheap"

# --- agent-cron-run: -> litellm/judge ---------------------------------------
# agent-cron-run needs a WORKDIR (not $HOME) and a prompt file.
cron_prompts="$scratch/cron-prompts"
cron_log="$scratch/cron-log"
mkdir -p "$cron_prompts" "$cron_log"
printf '# cron prompt\n' >"$cron_prompts/test.md"
export PROMPTS_DIR="$cron_prompts"
export LOG_DIR="$cron_log"
export WORKDIR="$scratch/work"
mkdir -p "$WORKDIR"
export AGENT_CRON_ALLOW_HOME_WORKDIR=1
rm -f "$record_args" "$record_stdin"
set +e
"$repo_root/bin/agent-cron-run" test >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "agent-cron-run litellm must exit 0, got $rc"
grep -q -- '--provider litellm' "$record_args" \
  || fail "agent-cron-run litellm must use --provider litellm, got: $(cat "$record_args")"
grep -q -- '--model judge' "$record_args" \
  || fail "agent-cron-run litellm must use --model judge, got: $(cat "$record_args")"
ok "agent-cron-run PI_SEAT_SOURCE=litellm -> litellm/judge"
unset AGENT_CRON_ALLOW_HOME_WORKDIR

echo "ALL OK: PI_SEAT_SOURCE=litellm routes the six worker callers to their LiteLLM group; default seat-lib unchanged"
