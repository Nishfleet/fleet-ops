#!/usr/bin/env bash
# tests/agent-cron-failure-reason.test.sh
#
# fleet-ops#342: when agent-cron-run cannot pick a seat, the failure reason
# lands on stderr (the systemd journal / `systemctl status` surface) in
# addition to the durable watch.log audit trail.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/agent-cron-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t agent-cron-failure.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

prompts_dir="$scratch/prompts"
log_dir="$scratch/cron-output"
state_dir="$scratch/state"
mkdir -p "$prompts_dir" "$log_dir" "$state_dir" "$scratch/home" "$scratch/ledger"
printf '# 0509 daily market signal prompt\nwrite the signal.\n' >"$prompts_dir/0509-daily-market-signal.md"

# Stub seat-lib that uses the real seat_log (so it writes to stderr), but
# forces pick_seat to return empty so we exercise the no-seat failure path.
stub_lib="$scratch/seat-lib.sh"
cat >"$stub_lib" <<EOF
# shellcheck shell=bash
export HOME="${scratch}/home"
export XDG_RUNTIME_DIR="${scratch}/xdg"
export PI_PACKET_STATE="$state_dir"
export PI_SEAT_HEALTH_LEDGER_DIR="${scratch}/ledger"
mkdir -p "\$PI_PACKET_STATE" "\$XDG_RUNTIME_DIR"
# shellcheck source=../lib/seat-lib.sh source-path=SCRIPTDIR
source "$repo_root/lib/seat-lib.sh"
task_weight() { echo "light"; }
pick_seat() { :; return 1; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
EOF

export HOME="$scratch/home"
export PI_PACKET_STATE="$state_dir"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
export PI_PACKET_SEAT_LIB="$stub_lib"
export PROMPTS_DIR="$prompts_dir"
export LOG_DIR="$log_dir"
export WORKDIR="$scratch"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_BIN="$scratch/no-pi"

set +e
bash "$bin" 0509-daily-market-signal >"$scratch/run.out" 2>"$scratch/run.err"
rc=$?
set -e

[[ "$rc" == "1" ]] || fail "agent-cron-run must exit 1 when no seat is available, got $rc"
grep -q 'no healthy seat' "$scratch/run.err" \
  || fail "stderr must contain 'no healthy seat' failure reason, got: $(cat "$scratch/run.err")"
grep -q 'no healthy seat' "$PI_PACKET_STATE/watch.log" \
  || fail "watch.log must retain the durable audit line, got: $(cat "$PI_PACKET_STATE/watch.log" 2>/dev/null)"

ok "agent-cron-run no-seat failure is printed to stderr and watch.log"
