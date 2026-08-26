#!/usr/bin/env bash
# tests/pi-intake-repair-run.test.sh
#
# Proves the pi-intake-repair unit no longer hard-codes a provider/model.
# The new wrapper (bin/pi-intake-repair-run) calls pick_seat and runs pi with
# the returned provider/model, exiting cleanly when a healthy seat exists and
# failing loud when none are available.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-intake-repair-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-intake-repair.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub seat-lib with a deterministic pick_seat and no-op seat_log.
stub_lib="$scratch/seat-lib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
seat_log() { :; }
task_weight() { echo "heavy"; }
pick_seat() {
    printf 'minimax\tMiniMax-M3\n'
    return 0
}
EOF

# Fake pi that records args and stdin, then prints output.
fake_pi="$scratch/pi"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PI_RECORD_ARGS"
cat > "$PI_RECORD_STDIN"
printf 'intake repair output\n'
EOF
chmod +x "$fake_pi"

record_args="$scratch/pi.args"
record_stdin="$scratch/pi.stdin"

export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export INTAKE_REPAIR_PROMPT_DIR="$repo_root/prompts"
export PI_RECORD_ARGS="$record_args"
export PI_RECORD_STDIN="$record_stdin"

# --- wrapper calls pi with the returned provider/model -----------------------
set +e
out=$("$bin" fleet-ops)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "intake-repair wrapper must exit 0, got $rc"
grep -q -- '--provider minimax' "$record_args" \
  || fail "pi must be called with --provider minimax, got: $(cat "$record_args")"
grep -q -- '--model MiniMax-M3' "$record_args" \
  || fail "pi must be called with --model MiniMax-M3, got: $(cat "$record_args")"
grep -q 'TARGET: intake unit pi-intake@fleet-ops.service, repo Nishfleet/fleet-ops' "$record_stdin" \
  || fail "packet must contain TARGET line, got: $(head "$record_stdin")"
[[ "$out" == "intake repair output" ]] || fail "wrapper stdout mismatch: $out"
ok "intake-repair wrapper runs pi with the rotated provider/model and exits cleanly"

# --- no healthy seat -> wrapper fails loud ---------------------------------
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
seat_log() { :; }
task_weight() { echo "heavy"; }
pick_seat() { :; return 1; }
EOF

set +e
out=$("$bin" fleet-ops 2>"$scratch/err.log")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "no seat: wrapper must exit 1, got $rc"
grep -q 'no healthy seat available' "$scratch/err.log" \
  || fail "no seat: wrapper must fail loud on stderr, got: $(cat "$scratch/err.log")"
ok "no healthy seat -> intake-repair wrapper exits 1 (fail loud)"

# --- unit file no longer hard-codes provider/model in ExecStart ------------
unit="$repo_root/systemd/pi-intake-repair@.service"
[[ -f "$unit" ]] || fail "unit file missing: $unit"
if grep -qE '^ExecStart=.*(--provider|--model)' "$unit"; then
    fail "pi-intake-repair@.service ExecStart still hard-codes --provider or --model"
fi
grep -q "pi-intake-repair-run %i" "$unit" \
  || fail "pi-intake-repair@.service ExecStart must invoke pi-intake-repair-run"
ok "pi-intake-repair@.service does not hard-code provider/model"

# --- MANIFEST installs the wrapper ----------------------------------------
grep -Fxq 'bin/pi-intake-repair-run /home/nish/.local/bin/pi-intake-repair-run' \
    "$repo_root/MANIFEST" \
  || fail "MANIFEST missing: bin/pi-intake-repair-run"
ok "MANIFEST installs pi-intake-repair-run"

# --- canary allowlist includes this wrapper (fleet-ops#351 omission) ------
grep -qE '^[[:space:]]+pi-intake-repair-run$' \
    "$repo_root/bin/fleet-escalation-canary" \
  || fail "pi-intake-repair-run missing from SANCTIONED_PI_RUNNERS in fleet-escalation-canary"
ok "escalation canary sanctions pi-intake-repair-run"

# --- systemd-analyze verify on the unit file -------------------------------
# The unit uses `/bin/bash -c exec ...` so verify does not need the wrapper
# binary to exist (same shape as pi-scout-repair@.service).
if command -v systemd-analyze >/dev/null 2>&1; then
  if ! systemd-analyze verify --man=no "$unit" >/dev/null 2>&1; then
    fail "systemd-analyze verify failed for pi-intake-repair@.service"
  fi
  ok "systemd-analyze verify accepts pi-intake-repair@.service"
else
  echo "SKIP: systemd-analyze not on PATH"
fi

ok "pi-intake-repair seat rotation: wrapper picks seat, runs pi, and fails loud when walled"
