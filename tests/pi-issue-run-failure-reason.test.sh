#!/usr/bin/env bash
# tests/pi-issue-run-failure-reason.test.sh
#
# fleet-ops#342: when pi fails inside pi-issue-run, the wrapper emits the
# failure reason to stderr (the systemd journal / `systemctl status` surface)
# in addition to the durable watch.log audit trail.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-issue-failure.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME" "$scratch/xdg"

# P14 (fleet-ops#549): the worker App creds file must exist and mint before
# pi runs. This test is about the failure-reason log, not identity — stub a
# working App identity so the run reaches pi.
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
state_dir="$scratch/state"
issues_dir="$scratch/issues"
ledger_dir="$scratch/ledger"
mkdir -p "$state_dir" "$issues_dir" "$ledger_dir" "$scratch/bin"

inst="test-issue"
printf 'packet body for test issue\n' >"$issues_dir/$inst.in"

# A fake pi that fails with a clear reason. Keep the text free of quota /
# ETIMEDOUT keywords so this test hits the generic `pi exited` path.
cat >"$scratch/bin/pi" <<'EOF'
#!/usr/bin/env bash
echo 'simulated pi failure: boom' >&2
exit 1
EOF
chmod +x "$scratch/bin/pi"

cat >"$scratch/bin/worker-token" <<'EOF'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
EOF
chmod +x "$scratch/bin/worker-token"
export WORKER_TOKEN_BIN="$scratch/bin/worker-token"

# Stub seat-lib that uses the real seat_log (so it writes to stderr), forces
# a specific seat, and avoids systemd/ledger dependencies.
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
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
EOF

export PI_PACKET_STATE="$state_dir"
export PI_SEAT_HEALTH_LEDGER_DIR="$ledger_dir"
export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_ISSUES_DIR="$issues_dir"
export PI_BIN="$scratch/bin/pi"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PATH="$scratch/bin:$PATH"

set +e
bash "$bin" "$inst" >"$scratch/run.out" 2>"$scratch/run.err"
rc=$?
set -e

[[ "$rc" == "1" ]] || fail "pi-issue-run must exit 1 when pi fails, got $rc"
grep -q 'pi exited 1' "$scratch/run.err" \
  || fail "stderr must contain the pi failure reason, got: $(cat "$scratch/run.err")"
grep -q 'pi exited 1' "$PI_PACKET_STATE/watch.log" \
  || fail "watch.log must retain the durable audit line, got: $(cat "$PI_PACKET_STATE/watch.log" 2>/dev/null)"

ok "pi-issue-run pi failure is printed to stderr and watch.log"
