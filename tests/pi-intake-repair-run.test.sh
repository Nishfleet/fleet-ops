#!/usr/bin/env bash
# tests/pi-intake-repair-run.test.sh
#
# Proves the pi-intake-repair unit no longer hard-codes a provider/model.
# The new wrapper (bin/pi-intake-repair-run) calls pick-seat and runs pi with
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

# Stub seatlib with a deterministic pick-seat and no-op seat_log.
stub_lib="$scratch/seatlib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
seat_log() { :; }
task_weight() { echo "heavy"; }
# fleet-ops#520: stub the privacy helpers the wrapper now calls. The stub
# returns "public" so the test's deterministic pick-seat path is unchanged;
# the privacy guard itself is drilled in tests/repo-privacy-guard.test.sh.
repo_privacy() { echo "public"; }
packet_repo() { echo ""; }
litellm_seat() {
    printf 'minimax\tMiniMax-M3\n'
    return 0
}
packet_difficulty() { echo "heavy"; }
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
# fleet-ops#520: stub the privacy helpers the wrapper now calls. The stub
# returns "public" so the test's deterministic pick-seat path is unchanged;
# the privacy guard itself is drilled in tests/repo-privacy-guard.test.sh.
repo_privacy() { echo "public"; }
packet_repo() { echo ""; }
litellm_seat() { :; return 1; }
litellm_seat() { :; return 1; }
packet_difficulty() { echo "heavy"; }
EOF

set +e
out=$("$bin" fleet-ops 2>"$scratch/err.log")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "no seat: wrapper must exit 1, got $rc"
grep -q 'no healthy seat available' "$scratch/err.log" \
  || fail "no seat: wrapper must fail loud on stderr, got: $(cat "$scratch/err.log")"
ok "no healthy seat -> intake-repair wrapper exits 1 (fail loud)"

# --- PACKET-VERDICT gains elapsed=<secs>s + budget=<secs>s (fleet-ops#6034) -
# A second fake pi prints a real verdict; a fake SYSTEMCTL (the same override
# install.sh precedent-sets, fleet-ops#290) reports the unit's start budget
# as "45min" -> 2700s. The wrapper must still pass the raw verdict through
# (tee) and add exactly one augmented line, elapsed first, budget second.
verdict_pi="$scratch/pi-verdict"
cat >"$verdict_pi" <<'EOF'
#!/usr/bin/env bash
printf 'repair done\n'
printf 'PACKET-VERDICT tools=53 class=worked\n'
EOF
chmod +x "$verdict_pi"

fake_systemctl="$scratch/systemctl"
cat >"$fake_systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$SYSTEMCTL_RECORD_ARGS"
echo '45min'
EOF
chmod +x "$fake_systemctl"
systemctl_args="$scratch/systemctl.args"

export SYSTEMCTL="$fake_systemctl"
export SYSTEMCTL_RECORD_ARGS="$systemctl_args"
export PI_BIN="$verdict_pi"

verdict_out="$scratch/verdict.stdout"
set +e
"$bin" fleet-ops >"$verdict_out"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "verdict run must exit 0, got $rc"
[[ "$(wc -l <"$verdict_out")" == "3" ]] \
  || fail "expected exactly 3 stdout lines (pi output, raw verdict, augmented); got: $(cat "$verdict_out")"
grep -Fxq 'repair done' "$verdict_out" \
  || fail "non-verdict pi stdout must still pass through: $(cat "$verdict_out")"
grep -Fxq 'PACKET-VERDICT tools=53 class=worked' "$verdict_out" \
  || fail "raw PACKET-VERDICT line must still reach the journal: $(cat "$verdict_out")"
tail -n 1 "$verdict_out" | grep -Eq '^PACKET-VERDICT tools=53 class=worked elapsed=[0-9]+s budget=2700s$' \
  || fail "augmented verdict line must be last, with elapsed + budget=2700s: $(tail -n 1 "$verdict_out")"
grep -q 'pi-intake-repair@fleet-ops.service' "$systemctl_args" \
  || fail "budget must come from unit pi-intake-repair@fleet-ops.service, got: $(cat "$systemctl_args")"
grep -q 'TimeoutStartUSec' "$systemctl_args" \
  || fail "budget must come from the TimeoutStartUSec property, got: $(cat "$systemctl_args")"
ok "PACKET-VERDICT restamped with elapsed=<secs>s budget=2700s (45min from the live unit)"

# --- wrapper preserves pi's exit code (fleet-ops#6034) -----------------------
# pipefail + captured rc: a failing pi (exit 3) must still exit 3, with the
# augmented verdict line still printed.
failing_pi="$scratch/pi-failing"
cat >"$failing_pi" <<'EOF'
#!/usr/bin/env bash
printf 'repair done\n'
printf 'PACKET-VERDICT tools=53 class=worked\n'
exit 3
EOF
chmod +x "$failing_pi"

export PI_BIN="$failing_pi"
failing_out="$scratch/failing.stdout"
set +e
"$bin" fleet-ops >"$failing_out"
rc=$?
set -e
[[ "$rc" == "3" ]] || fail "wrapper must preserve pi's exit 3, got $rc"
grep -Eq '^PACKET-VERDICT tools=53 class=worked elapsed=[0-9]+s budget=2700s$' "$failing_out" \
  || fail "augmented verdict line must still print when pi exits 3: $(cat "$failing_out")"
ok "wrapper exits with pi's rc (3) and still stamps elapsed/budget"

# --- unparseable budget -> augmented line omits budget= (fleet-ops#6034) ----
# The SYSTEMCTL stub now prints "banana": the augmented line must end at
# elapsed=<secs>s with no budget= field (never a fabricated number).
garbage_systemctl="$scratch/systemctl-garbage"
cat >"$garbage_systemctl" <<'EOF'
#!/usr/bin/env bash
echo 'banana'
EOF
chmod +x "$garbage_systemctl"

export SYSTEMCTL="$garbage_systemctl"
export PI_BIN="$verdict_pi"
garbage_out="$scratch/garbage.stdout"
set +e
"$bin" fleet-ops >"$garbage_out"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "garbage-budget run must exit 0, got $rc"
tail -n 1 "$garbage_out" | grep -Eq '^PACKET-VERDICT tools=53 class=worked elapsed=[0-9]+s$' \
  || fail "garbage budget: augmented line must end at elapsed=<secs>s: $(tail -n 1 "$garbage_out")"
grep -q 'budget' "$garbage_out" && fail "garbage budget must not fabricate budget=: $(cat "$garbage_out")"
ok "unparseable budget -> augmented line omits budget= silently"

# --- unit file no longer hard-codes provider/model in ExecStart ------------
unit="$repo_root/systemd/pi-intake-repair@.service"
[[ -f "$unit" ]] || fail "unit file missing: $unit"
if grep -qE '^ExecStart=.*(--provider|--model)' "$unit"; then
    fail "pi-intake-repair@.service ExecStart still hard-codes --provider or --model"
fi
grep -q "pi-intake-repair-run %i" "$unit" \
  || fail "pi-intake-repair@.service ExecStart must invoke pi-intake-repair-run"
ok "pi-intake-repair@.service does not hard-code provider/model"

# --- unit start budget 1800s -> 2700s, StartLimit latch untouched (fleet-ops#6034) ---
# Exactly one unit change; StartLimitIntervalSec/StartLimitBurst must stay
# byte-identical (fleet-ops#5036: raising the burst re-wedges).
grep -Fxq 'TimeoutStartSec=2700' "$unit" \
  || fail "pi-intake-repair@.service must carry the exact line 'TimeoutStartSec=2700' (fleet-ops#6034)"
! grep -Fxq 'TimeoutStartSec=1800' "$unit" \
  || fail "pi-intake-repair@.service still carries the old 'TimeoutStartSec=1800'"
grep -Fxq 'StartLimitIntervalSec=21600' "$unit" \
  || fail "pi-intake-repair@.service must still carry 'StartLimitIntervalSec=21600' byte-identical (fleet-ops#5036)"
grep -Fxq 'StartLimitBurst=2' "$unit" \
  || fail "pi-intake-repair@.service must still carry 'StartLimitBurst=2' byte-identical (fleet-ops#5036)"
ok "pi-intake-repair@.service: TimeoutStartSec=2700 with StartLimitIntervalSec=21600 + StartLimitBurst=2 untouched"

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
