#!/usr/bin/env bash
# tests/pi-issue-run-packet-regen.test.sh
#
# fleet-ops#1451: when the .in packet is missing (archived by reaper while
# Restart=on-failure ladder is still armed), pi-issue-run regenerates it from
# the worker prompt + TARGET line so the restart proceeds instead of failing
# with 208/STDIN.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-pkt-regen.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME" "$scratch/xdg"
unset WORKER_APP_CREDS_FILE || true

# P14: stub a working App identity so the run reaches pi.
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
state_dir="$scratch/state"
issues_dir="$scratch/issues"
ledger_dir="$scratch/ledger"
mkdir -p "$state_dir" "$issues_dir" "$ledger_dir" "$scratch/bin"

# Fake worker prompt (shorter than real one for test speed)
prompt_file="$scratch/worker.md"
cat >"$prompt_file" <<'PROMPT'
# Test worker prompt
You are a test worker.
TARGET line follows.
PROMPT

inst="fleet-ops-1451"
# NOTE: do NOT create the .in packet — the test is that it gets REGENERATED.

# A fake pi that succeeds and prints enough output to pass no-op check.
cat >"$scratch/bin/pi" <<'EOF'
#!/usr/bin/env bash
echo "PR created: https://github.com/Nishfleet/fleet-ops/pull/123"
exit 0
EOF
chmod +x "$scratch/bin/pi"

cat >"$scratch/bin/worker-token" <<'EOF'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
EOF
chmod +x "$scratch/bin/worker-token"
export WORKER_TOKEN_BIN="$scratch/bin/worker-token"

# Stub seat-lib that uses the real seat_log, forces a specific seat, and avoids
# systemd/ledger dependencies.
stub_lib="$scratch/seat-lib.sh"
cat >"$stub_lib" <<EOF
# shellcheck shell=bash
export HOME="$scratch/home"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_PACKET_STATE="$state_dir"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger_dir"
mkdir -p "\$PI_PACKET_STATE" "\$XDG_RUNTIME_DIR"
# shellcheck source=../lib/seat-lib.sh source-path=SCRIPTDIR
source "$repo_root/lib/seat-lib.sh"
task_weight() { echo "light"; }
pick_seat() { printf 'devin\tglm-5-2\n'; return 0; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
is_overload_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
mark_seat_overload_bench() { return 0; }
EOF

export PI_PACKET_STATE="$state_dir"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger_dir"
export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_ISSUES_DIR="$issues_dir"
export PI_BIN="$scratch/bin/pi"
export XDG_RUNTIME_DIR="$scratch/xdg"
export WORKER_PROMPT="$prompt_file"
export PATH="$scratch/bin:$PATH"

# Verify the packet does NOT exist before the run
[[ ! -f "$issues_dir/$inst.in" ]] || fail "test setup broken: $issues_dir/$inst.in already exists"

set +e
bash "$bin" "$inst" >"$scratch/run.out" 2>"$scratch/run.err"
rc=$?
set -e

[[ "$rc" == "0" ]] || fail "pi-issue-run must exit 0 when packet is regenerated and pi succeeds, got $rc (err: $(cat "$scratch/run.err"))"

# Verify the packet was regenerated
[[ -f "$issues_dir/$inst.in" ]] || fail "packet file was not regenerated: $issues_dir/$inst.in"

# Verify packet content: worker prompt + TARGET line
pkt_content=$(cat "$issues_dir/$inst.in")
echo "$pkt_content" | grep -q "Test worker prompt" || fail "regenerated packet missing worker prompt content: $pkt_content"
echo "$pkt_content" | grep -q "TARGET: repo Nishfleet/fleet-ops issue 1451 unit pi-issue-fleet-ops-1451" \
  || fail "regenerated packet missing correct TARGET line: $pkt_content"

# Verify log mentions regeneration
grep -q "REGENERATED missing packet for Nishfleet/fleet-ops#1451" "$scratch/run.err" \
  || fail "stderr must mention packet regeneration, got: $(cat "$scratch/run.err")"

ok "pi-issue-run regenerates missing .in packet from worker prompt + TARGET (fleet-ops#1451)"

# --- Test B: instance name parsing fails gracefully for malformed instance ---
scratch2="$(mktemp -d -t pi-pkt-bad.XXXXXX)"
trap 'rm -rf "$scratch2"' EXIT INT TERM

export HOME="$scratch2/home"
mkdir -p "$HOME" "$scratch2/xdg" "$scratch2/issues" "$scratch2/state" "$scratch2/ledger" "$scratch2/bin"
unset WORKER_APP_CREDS_FILE || true
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"

cat >"$scratch2/bin/pi" <<'EOF'
#!/usr/bin/env bash
echo "should not reach here"
exit 0
EOF
chmod +x "$scratch2/bin/pi"

cat >"$scratch2/bin/worker-token" <<'EOF'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
EOF
chmod +x "$scratch2/bin/worker-token"
export WORKER_TOKEN_BIN="$scratch2/bin/worker-token"

stub_lib2="$scratch2/seat-lib.sh"
cat >"$stub_lib2" <<EOF
# shellcheck shell=bash
export HOME="$scratch2/home"
export XDG_RUNTIME_DIR="$scratch2/xdg"
export PI_PACKET_STATE="$scratch2/state"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch2/ledger"
mkdir -p "\$PI_PACKET_STATE" "\$XDG_RUNTIME_DIR"
source "$repo_root/lib/seat-lib.sh"
task_weight() { echo "light"; }
pick_seat() { printf 'devin\tglm-5-2\n'; return 0; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
is_overload_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
mark_seat_overload_bench() { return 0; }
EOF

export PI_PACKET_STATE="$scratch2/state"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch2/ledger"
export PI_PACKET_SEAT_LIB="$stub_lib2"
export PI_ISSUES_DIR="$scratch2/issues"
export PI_BIN="$scratch2/bin/pi"
export XDG_RUNTIME_DIR="$scratch2/xdg"
export WORKER_PROMPT="$prompt_file"
export PATH="$scratch2/bin:$PATH"

# Instance without a dash — should fail gracefully
set +e
bash "$bin" "malformedinstance" >"$scratch2/run.out" 2>"$scratch2/run.err"
rc=$?
set -e

[[ "$rc" == "1" ]] || fail "malformed instance must exit 1, got $rc"
grep -q "cannot parse repo/issue from instance" "$scratch2/run.err" \
  || fail "must log parse failure, got: $(cat "$scratch2/run.err")"

ok "pi-issue-run fails gracefully on malformed instance name"

# --- Test C: missing worker prompt fails gracefully ---
scratch3="$(mktemp -d -t pi-pkt-noprompt.XXXXXX)"
trap 'rm -rf "$scratch3"' EXIT INT TERM

export HOME="$scratch3/home"
mkdir -p "$HOME" "$scratch3/xdg" "$scratch3/issues" "$scratch3/state" "$scratch3/ledger" "$scratch3/bin"
unset WORKER_APP_CREDS_FILE || true
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"

cat >"$scratch3/bin/pi" <<'EOF'
#!/usr/bin/env bash
echo "should not reach here"
exit 0
EOF
chmod +x "$scratch3/bin/pi"

cat >"$scratch3/bin/worker-token" <<'EOF'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
EOF
chmod +x "$scratch3/bin/worker-token"
export WORKER_TOKEN_BIN="$scratch3/bin/worker-token"

stub_lib3="$scratch3/seat-lib.sh"
cat >"$stub_lib3" <<EOF
# shellcheck shell=bash
export HOME="$scratch3/home"
export XDG_RUNTIME_DIR="$scratch3/xdg"
export PI_PACKET_STATE="$scratch3/state"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch3/ledger"
mkdir -p "\$PI_PACKET_STATE" "\$XDG_RUNTIME_DIR"
source "$repo_root/lib/seat-lib.sh"
task_weight() { echo "light"; }
pick_seat() { printf 'devin\tglm-5-2\n'; return 0; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
is_overload_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
mark_seat_overload_bench() { return 0; }
EOF

export PI_PACKET_STATE="$scratch3/state"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch3/ledger"
export PI_PACKET_SEAT_LIB="$stub_lib3"
export PI_ISSUES_DIR="$scratch3/issues"
export PI_BIN="$scratch3/bin/pi"
export XDG_RUNTIME_DIR="$scratch3/xdg"
export WORKER_PROMPT="/nonexistent/worker.md"
export PATH="$scratch3/bin:$PATH"

set +e
bash "$bin" "fleet-ops-999" >"$scratch3/run.out" 2>"$scratch3/run.err"
rc=$?
set -e

[[ "$rc" == "1" ]] || fail "missing worker prompt must exit 1, got $rc"
grep -q "worker prompt not found" "$scratch3/run.err" \
  || fail "must log missing worker prompt, got: $(cat "$scratch3/run.err")"

ok "pi-issue-run fails gracefully when worker prompt is missing"