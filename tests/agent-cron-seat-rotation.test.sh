#!/usr/bin/env bash
# tests/agent-cron-seat-rotation.test.sh
#
# fleet-ops#143: proves agent-cron-run no longer gates on the single-snapshot
# lanes/pi-seat-health.json. It now rotates seats via pick_seat, so a
# transient 429 on one seat (which would have stamped the snapshot unhealthy
# for minutes) routes to a healthy alt instead of killing the daily cron.
# When every allowlisted seat is walled, it fails loud as before.
#
# Acceptance (from the issue):
#   - stub seat-health as unhealthy + one healthy alt seat in the cap map
#     -> run succeeds on the alt.
#   - all seats walled -> FATAL as today.
#
# Also locks the Restart= policy on the cron service unit so a transient wall
# delays the daily job (systemd re-seats) instead of killing it for the day.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/agent-cron-run"
svc="$repo_root/systemd/agent-cron-0509-daily-market-signal.service"
tmr="$repo_root/systemd/agent-cron-0509-daily-market-signal.timer"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t agent-cron-seat.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub seat-lib with a deterministic pick_seat and the helpers agent-cron-run
# calls. The first scenario: pick_seat returns a healthy ALT seat even though
# the (now-irrelevant) snapshot would have been unhealthy — proving the gate
# is gone and rotation works.
stub_lib="$scratch/seat-lib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
ATTEMPTS_DIR="${ATTEMPTS_DIR:-/tmp/agent-cron-attempts-stub}"
mkdir -p "$ATTEMPTS_DIR"
seat_log() { :; }
task_weight() { echo "light"; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
pick_seat() {
    printf 'cursor\tcomposer-2.5\n'
    return 0
}
EOF

# Fake pi that records argv + stdin and prints output carrying a DIGEST line.
fake_pi="$scratch/pi"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PI_RECORD_ARGS"
cat > "$PI_RECORD_STDIN"
printf 'market signal body\nDIGEST:: daily signal digest line\n'
EOF
chmod +x "$fake_pi"

# Fake hermes so the success path's delivery does not hit the network.
fake_hermes="$scratch/hermes"
cat >"$fake_hermes" <<'EOF'
#!/usr/bin/env bash
echo "hermes stub: $*" >> "$HERMES_RECORD"
exit 0
EOF
chmod +x "$fake_hermes"

record_args="$scratch/pi.args"
record_stdin="$scratch/pi.stdin"
hermes_record="$scratch/hermes.log"
prompts_dir="$scratch/prompts"
log_dir="$scratch/cron-output"
mkdir -p "$prompts_dir" "$log_dir"
printf '# 0509 daily market signal prompt\nwrite the signal.\n' >"$prompts_dir/0509-daily-market-signal.md"

export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export PATH="$scratch:$PATH"
export PROMPTS_DIR="$prompts_dir"
export LOG_DIR="$log_dir"
export WORKDIR="$scratch"
export PI_RECORD_ARGS="$record_args"
export PI_RECORD_STDIN="$record_stdin"
export HERMES_RECORD="$hermes_record"
export ATTEMPTS_DIR="$scratch/attempts"

# --- scenario 1: unhealthy snapshot + healthy alt -> succeeds on the alt ----
set +e
"$bin" 0509-daily-market-signal >"$scratch/run1.out" 2>"$scratch/run1.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario 1: must exit 0, got $rc (stderr: $(cat "$scratch/run1.err"))"
grep -q -- '--provider cursor' "$record_args" \
  || fail "scenario 1: pi must run on the alt provider cursor, got: $(cat "$record_args")"
grep -q -- '--model composer-2.5' "$record_args" \
  || fail "scenario 1: pi must run on the alt model composer-2.5, got: $(cat "$record_args")"
# The prompt must be piped into pi (stdin carries the env header + prompt body).
grep -q 'AGENT_CRON_SLUG=0509-daily-market-signal' "$record_stdin" \
  || fail "scenario 1: pi stdin must carry the AGENT_CRON_SLUG header, got: $(head "$record_stdin")"
grep -q 'write the signal.' "$record_stdin" \
  || fail "scenario 1: pi stdin must carry the prompt body, got: $(cat "$record_stdin")"
# The run must be recorded to the dated output file with the seat line.
out_file="$log_dir/0509-daily-market-signal-$(date -u +%Y-%m-%d).md"
[[ -f "$out_file" ]] || fail "scenario 1: output file not written: $out_file"
grep -q 'seat=cursor/composer-2.5' "$out_file" \
  || fail "scenario 1: output file must record the seat, got: $(cat "$out_file")"
grep -q 'market signal body' "$out_file" \
  || fail "scenario 1: output file must contain pi stdout, got: $(cat "$out_file")"
# The DIGEST line must have been sent via hermes.
grep -q 'daily signal digest line' "$hermes_record" \
  || fail "scenario 1: digest must be sent via hermes, got: $(cat "$hermes_record" 2>/dev/null)"
ok "scenario 1: unhealthy snapshot + healthy alt -> run succeeds on the alt (cursor/composer-2.5), recorded + delivered"

# --- scenario 2: every seat walled -> FATAL as today ------------------------
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
ATTEMPTS_DIR="${ATTEMPTS_DIR:-/tmp/agent-cron-attempts-stub}"
mkdir -p "$ATTEMPTS_DIR"
seat_log() { :; }
task_weight() { echo "light"; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
pick_seat() { :; return 1; }
EOF
rm -f "$record_args" "$record_stdin"

set +e
"$bin" 0509-daily-market-signal >"$scratch/run2.out" 2>"$scratch/run2.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario 2: fully-walled ladder must exit 1, got $rc"
grep -q 'FATAL' "$scratch/run2.err" \
  || fail "scenario 2: must fail loud with FATAL on stderr, got: $(cat "$scratch/run2.err")"
grep -q 'no healthy seat available' "$scratch/run2.err" \
  || fail "scenario 2: FATAL must name the walled ladder, got: $(cat "$scratch/run2.err")"
# pi must NOT have been invoked when no seat was available.
[[ ! -s "$record_args" ]] \
  || fail "scenario 2: pi must not be invoked when no seat is available, got: $(cat "$record_args" 2>/dev/null)"
ok "scenario 2: every seat walled -> FATAL, exit 1, pi never invoked"

# --- scenario 3: pi failure -> exit 1 so systemd Restart re-seats -----------
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
ATTEMPTS_DIR="${ATTEMPTS_DIR:-/tmp/agent-cron-attempts-stub}"
mkdir -p "$ATTEMPTS_DIR"
seat_log() { :; }
task_weight() { echo "light"; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
pick_seat() { printf 'devin\tglm-5-2\n'; return 0; }
EOF
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
echo 'pi: simulated 429' >&2
exit 1
EOF
chmod +x "$fake_pi"

set +e
"$bin" 0509-daily-market-signal >"$scratch/run3.out" 2>"$scratch/run3.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario 3: pi failure must exit 1 so systemd re-seats, got $rc"
ok "scenario 3: pi failure -> exit 1 (systemd Restart= re-seats on next try)"

# --- service unit: Restart policy + ExecStart contract ----------------------
[[ -f "$svc" ]] || fail "service unit not found: $svc"
grep -q '^ExecStart=/home/nish/.local/bin/agent-cron-run 0509-daily-market-signal$' "$svc" \
  || fail "service ExecStart must invoke agent-cron-run with the slug"
grep -q '^Restart=on-failure$' "$svc" \
  || fail "service must set Restart=on-failure (transient wall delays, not kills)"
grep -q '^RestartSec=900$' "$svc" \
  || fail "service must set RestartSec=900 (15min)"
grep -q '^StartLimitBurst=3$' "$svc" \
  || fail "service must set a small StartLimitBurst=3"
grep -q '^StartLimitIntervalSec=1h$' "$svc" \
  || fail "service must set StartLimitIntervalSec=1h"
# The unit must NOT gate on the seat-health snapshot itself — the wrapper does
# the gate via pick_seat. The SEAT_FILE env from the old unit must be gone.
if grep -q 'SEAT_FILE=' "$svc"; then
    fail "service must not carry the legacy SEAT_FILE env (the snapshot gate is gone)"
fi
ok "service unit: Restart=on-failure RestartSec=900 StartLimitBurst=3, no legacy SEAT_FILE"

# --- MANIFEST entries -------------------------------------------------------
grep -Fxq "bin/agent-cron-run /home/nish/.local/bin/agent-cron-run" "$manifest" \
  || fail "MANIFEST missing: bin/agent-cron-run"
grep -Fxq "systemd/agent-cron-0509-daily-market-signal.service /home/nish/.config/systemd/user/agent-cron-0509-daily-market-signal.service" "$manifest" \
  || fail "MANIFEST missing: agent-cron service"
grep -Fxq "systemd/agent-cron-0509-daily-market-signal.timer /home/nish/.config/systemd/user/agent-cron-0509-daily-market-signal.timer" "$manifest" \
  || fail "MANIFEST missing: agent-cron timer"
ok "MANIFEST entries present for runner + service + timer"

# --- systemd-analyze verify on the unit files -------------------------------
if command -v systemd-analyze >/dev/null 2>&1; then
  # Capture stderr (where systemd-analyze writes diagnostics) so a CI-only
  # verify failure is diagnosable instead of a bare "failed" with stderr
  # discarded. stdout is empty for verify; redirect both into the capture.
  if ! verify_out=$(systemd-analyze verify --man=no "$svc" "$tmr" 2>&1); then
    fail "systemd-analyze verify failed for agent-cron units:
$verify_out"
  fi
  ok "systemd-analyze verify accepts agent-cron units"
else
  echo "SKIP: systemd-analyze not on PATH"
fi

ok "agent-cron seat rotation: gate replaced by pick_seat, transient 429 routes to alt, fully-walled fails loud"
