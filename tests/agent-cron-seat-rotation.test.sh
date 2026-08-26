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
timer="$repo_root/systemd/agent-cron-0509-daily-market-signal.timer"
install_sh="$repo_root/install.sh"
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
grep -q '^Environment=PROMPTS_DIR=/home/nish/\.pi/agent/prompts$' "$svc" \
  || fail "service must use the MANIFEST-installed prompts dir"
ok "service unit: Restart=on-failure RestartSec=900 StartLimitBurst=3, no legacy SEAT_FILE, managed PROMPTS_DIR"

# --- MANIFEST entries -------------------------------------------------------
grep -Fxq "bin/agent-cron-run /home/nish/.local/bin/agent-cron-run" "$manifest" \
  || fail "MANIFEST missing: bin/agent-cron-run"
grep -Fxq "systemd/agent-cron-0509-daily-market-signal.service /home/nish/.config/systemd/user/agent-cron-0509-daily-market-signal.service" "$manifest" \
  || fail "MANIFEST missing: agent-cron service"
grep -Fxq "systemd/agent-cron-0509-daily-market-signal.timer /home/nish/.config/systemd/user/agent-cron-0509-daily-market-signal.timer" "$manifest" \
  || fail "MANIFEST missing: agent-cron timer"
grep -Fxq "prompts/0509-daily-market-signal.md /home/nish/.pi/agent/prompts/0509-daily-market-signal.md" "$manifest" \
  || fail "MANIFEST missing: prompts/0509-daily-market-signal.md"
git -C "$repo_root" ls-files --error-unmatch prompts/0509-daily-market-signal.md >/dev/null \
  || fail "prompt file not tracked in git: prompts/0509-daily-market-signal.md"
ok "MANIFEST entries present for runner + service + timer + prompt"

# --- install.sh enables the [Install] timer (fleet-ops#183) -----------------
# The timer was in MANIFEST with [Install] and still not-found on the live
# host because install.sh only enabled intake-reconcile. Lock both the
# unit shape and the installer call so a later unit with [Install] cannot
# be added the same way without the enable line.
[[ -f "$timer" ]] || fail "timer unit not found: $timer"
[[ -x "$install_sh" ]] || fail "not executable: $install_sh"
grep -q '^\[Install\]$' "$timer" \
  || fail "timer must carry [Install] so systemctl enable can hook it"
grep -q '^WantedBy=timers.target$' "$timer" \
  || fail "timer [Install] must WantedBy=timers.target"
grep -Fq -- '"$SYSTEMCTL" --user enable --now agent-cron-0509-daily-market-signal.timer' "$install_sh" \
  || fail "install.sh must enable --now agent-cron-0509-daily-market-signal.timer"
ok "timer has [Install] and install.sh enables it"

# Behavioral: a scratch install with stub systemctl must actually invoke
# enable --now. Destinations stay under $scratch so this cannot mutate the
# live user bus. A comment-only enable line would fail this.
#
# fleet-ops#290: GitHub's runner has no user systemd bus. A stub that
# always exits 0 makes is-enabled look already-enabled, so install.sh
# skips enable --now and P14 goes red. Same shape as
# tests/fleet-ops-deploy.test.sh: quoted fake, is-enabled -> 1, enable
# recorded. SYSTEMCTL= is how the rest of fleet-ops injects the stub.
install_scratch="$scratch/install-root"
mkdir -p "$install_scratch/systemd" "$scratch/fake-bin" "$scratch/user-units"
cp -a "$install_sh" "$install_scratch/install.sh"
cp -a "$timer" "$install_scratch/systemd/agent-cron-0509-daily-market-signal.timer"
cp -a "$svc" "$install_scratch/systemd/agent-cron-0509-daily-market-signal.service"
cat >"$install_scratch/MANIFEST" <<MANIFEST
systemd/agent-cron-0509-daily-market-signal.service $scratch/user-units/agent-cron-0509-daily-market-signal.service
systemd/agent-cron-0509-daily-market-signal.timer $scratch/user-units/agent-cron-0509-daily-market-signal.timer
MANIFEST
calls="$scratch/systemctl.calls"
: >"$calls"
cat >"$scratch/fake-bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SYSTEMCTL_CALLS:?}"
if [ "${1:-}" = "--user" ]; then
  shift
fi
cmd="${1:-}"
case "$cmd" in
  is-enabled)
    # Fresh box: nothing enabled. Always-0 here is the #290 regression.
    exit 1
    ;;
  daemon-reload|enable|start)
    exit 0
    ;;
  *)
    printf 'unexpected systemctl call: %s %s\n' "$cmd" "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$scratch/fake-bin/systemctl"
export SYSTEMCTL_CALLS="$calls"
set +e
"$scratch/fake-bin/systemctl" --user is-enabled agent-cron-0509-daily-market-signal.timer
stub_is_enabled_rc=$?
set -e
: >"$calls"
[[ "$stub_is_enabled_rc" == "1" ]] \
  || fail "stub is-enabled must exit 1 on a fresh box (always-0 stubs skip enable --now: fleet-ops#290), got $stub_is_enabled_rc"
SYSTEMCTL="$scratch/fake-bin/systemctl" PATH="$scratch/fake-bin:$PATH" \
  "$install_scratch/install.sh"
[[ -L "$scratch/user-units/agent-cron-0509-daily-market-signal.timer" ]] \
  || fail "scratch install must symlink the timer"
grep -Eqx -- '--user enable --now agent-cron-0509-daily-market-signal\.timer' "$calls" \
  || fail "scratch install did not enable --now the agent-cron timer: $(cat "$calls")"
ok "scratch install.sh enable --now invoked for the [Install] timer"

# --- systemd-analyze verify on the unit files -------------------------------
# NOTE: unit-file verification is owned by the dedicated `systemd-analyze` CI
# job (.github/workflows/ci.yml), which stubs the VPS ExecStart paths
# (/home/nish/.local/bin/agent-cron-run, etc.) before verifying every
# systemd/*.service + *.timer. Do NOT re-verify here: this test runs without
# sudo and without those stubs, and `systemd-analyze verify` on systemd 256+
# rejects units whose ExecStart binary does not exist on the host — so an
# inline verify false-positives on every CI run (the runner has no
# /home/nish/.local/bin/agent-cron-run). That red baseline kept main failing
# since #144 and made auto-revert thrash (halt issues #151/#160/#169/#172).

ok "agent-cron seat rotation: gate replaced by pick_seat, transient 429 routes to alt, fully-walled fails loud"
