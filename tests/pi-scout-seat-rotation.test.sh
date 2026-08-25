#!/usr/bin/env bash
# tests/pi-scout-seat-rotation.test.sh
#
# Proves the scout and scout-repair systemd units no longer hard-code a
# provider/model. The new wrapper (bin/pi-scout-run) calls pick_seat and
# runs pi with the returned provider/model, exiting cleanly when a healthy
# seat exists and failing loud when none are available.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-scout-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-scout-seat.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub seat-lib with a deterministic pick_seat and no-op seat_log.
stub_lib="$scratch/seat-lib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
seat_log() { :; }
task_weight() { echo "light"; }
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
printf 'scout output\n'
EOF
chmod +x "$fake_pi"

record_args="$scratch/pi.args"
record_stdin="$scratch/pi.stdin"

export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export SCOUT_PROMPT_DIR="$repo_root/prompts"
export PI_RECORD_ARGS="$record_args"
export PI_RECORD_STDIN="$record_stdin"

# --- scout wrapper calls pi with the returned provider/model ---------------
set +e
out=$("$bin" fleet-ops scout)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scout wrapper must exit 0, got $rc"
grep -q -- '--provider minimax' "$record_args" \
  || fail "pi must be called with --provider minimax, got: $(cat "$record_args")"
grep -q -- '--model MiniMax-M3' "$record_args" \
  || fail "pi must be called with --model MiniMax-M3, got: $(cat "$record_args")"
grep -q 'TARGET REPO: Nishfleet/fleet-ops' "$record_stdin" \
  || fail "packet must contain TARGET REPO line, got: $(head "$record_stdin")"
[[ "$out" == "scout output" ]] || fail "wrapper stdout mismatch: $out"
ok "scout wrapper runs pi with the rotated provider/model and exits cleanly"

# --- scout-repair wrapper builds the correct TARGET line -------------------
rm -f "$record_args" "$record_stdin"
set +e
out=$("$bin" 0509 scout-repair)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scout-repair wrapper must exit 0, got $rc"
grep -q -- '--provider minimax' "$record_args" \
  || fail "repair: pi must be called with --provider minimax, got: $(cat "$record_args")"
grep -q -- '--model MiniMax-M3' "$record_args" \
  || fail "repair: pi must be called with --model MiniMax-M3, got: $(cat "$record_args")"
grep -q 'TARGET: scout unit pi-scout@0509.service, repo Nishfleet/0509' "$record_stdin" \
  || fail "repair packet must contain TARGET line, got: $(head "$record_stdin")"
ok "scout-repair wrapper builds the correct target line"

# --- no healthy seat -> wrapper fails loud ---------------------------------
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
seat_log() { :; }
task_weight() { echo "light"; }
pick_seat() { :; return 1; }
EOF

set +e
out=$("$bin" fleet-ops scout 2>"$scratch/err.log")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "no seat: wrapper must exit 1, got $rc"
grep -q 'no healthy seat available' "$scratch/err.log" \
  || fail "no seat: wrapper must fail loud on stderr, got: $(cat "$scratch/err.log")"
ok "no healthy seat -> wrapper exits 1 (fail loud)"

# --- unit files no longer hard-code provider/model in ExecStart -----------
if grep -qE '^ExecStart=.*(--provider|--model)' \
   "$repo_root/systemd/pi-scout@.service" \
   "$repo_root/systemd/pi-scout-repair@.service"; then
    fail "unit files still hard-code --provider or --model in ExecStart"
fi
grep -q "pi-scout-run %i scout" "$repo_root/systemd/pi-scout@.service" \
  || fail "pi-scout@.service ExecStart must invoke pi-scout-run"
grep -q "pi-scout-run %i scout-repair" "$repo_root/systemd/pi-scout-repair@.service" \
  || fail "pi-scout-repair@.service ExecStart must invoke pi-scout-run"
ok "unit files do not hard-code provider/model"

# --- systemd-analyze verify on the unit files -----------------------------
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify --man=no \
      "$repo_root/systemd/pi-scout@.service" \
      "$repo_root/systemd/pi-scout-repair@.service" >/dev/null 2>&1 \
    || fail "systemd-analyze verify failed for pi-scout units"
  ok "systemd-analyze verify accepts pi-scout units"
else
  echo "SKIP: systemd-analyze not on PATH"
fi

ok "pi-scout seat rotation: wrapper picks seat, runs pi, and fails loud when walled"
