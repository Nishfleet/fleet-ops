#!/usr/bin/env bash
# tests/agent-cron-empty-stdout.test.sh
#
# fleet-ops#5515: pi can exit 0 with EMPTY stdout (late-stream/empty-message
# class: the model finalized without emitting anything). agent-cron-run's
# success path then logged SUCCESS, reset tried-seats, and exited 0 — no
# Restart, no OnFailure, no escalation. quality-research-weekly silently
# skipped TWO weekly cycles this way (2026-08-30: 286-byte log, one Restart,
# two outputless attempts; 2026-09-06: 125-byte log, one outputless attempt
# on opencode/nemotron-3-ultra-free — unit Result=success both times while
# the rotation log in visual-quality-waves.md gained nothing).
#
# Fix pinned here: on the rc=0 path, an empty (whitespace-only) stdout is a
# FAILED run — evidence (header + stderr tail) is recorded in the dated OUT
# file, tried-seats is retained, and the script exits 1 so systemd
# Restart=on-failure re-seats; after StartLimitBurst the unit fails loud
# into the existing unit-escalation rails. A non-empty rc=0 run still exits
# 0 (control).
#
# Offline: stub seat-lib + fake pi, same harness as
# tests/agent-cron-writes-refused.test.sh.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/agent-cron-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t agent-cron-empty-stdout.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

stub_lib="$scratch/stub-seat-lib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
ATTEMPTS_DIR="${ATTEMPTS_DIR:-/tmp/agent-cron-es-attempts-stub}"
mkdir -p "$ATTEMPTS_DIR"
seat_log() { :; }
task_weight() { echo "light"; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
pick_seat() { printf 'cursor\tcursor-grok-4.6-high\n'; return 0; }
EOF

fake_pi="$scratch/pi"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' >"$fake_pi"   # outputless success, edited per case
chmod +x "$fake_pi"

fake_hermes="$scratch/hermes"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_hermes"
chmod +x "$fake_hermes"

prompts_dir="$scratch/prompts"
log_dir="$scratch/cron-output"
mkdir -p "$prompts_dir" "$log_dir" "$scratch/attempts"
printf '# test rotation prompt\nrun the rotation.\n' >"$prompts_dir/quality-research-weekly.md"

export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export PATH="$scratch:$PATH"
export PROMPTS_DIR="$prompts_dir"
export LOG_DIR="$log_dir"
export WORKDIR="$scratch"
export ATTEMPTS_DIR="$scratch/attempts"

out_file="$log_dir/quality-research-weekly-$(date -u +%Y-%m-%d).md"
tried_file="$ATTEMPTS_DIR/agent-cron-quality-research-weekly.tried-seats"

# ============================================================================
# 1. THE BUG: rc=0 + EMPTY stdout must NOT be a silent success
# ============================================================================
rm -f "$out_file"
set +e
"$bin" quality-research-weekly >"$scratch/run1.out" 2>"$scratch/run1.err"
rc=$?
set -e
[[ "$rc" == "1" ]] \
    || fail "e2e: rc=0 with EMPTY stdout must exit 1 (loud), got $rc (stderr: $(cat "$scratch/run1.err"))"
ok "e2e: empty-stdout run exits 1 (was the silent rc=0 stall, fleet-ops#5515)"

# Evidence must be recorded in the dated log — the stderr tail is the only
# diagnostic the senior auditor gets from a killed-run.
[[ -f "$out_file" ]] || fail "empty-stdout run must record evidence to $out_file"
grep -q 'EMPTY-STDOUT' "$out_file" \
    || fail "recorded evidence must carry the EMPTY-STDOUT header, got: $(cat "$out_file")"
grep -q 'seat=cursor/cursor-grok-4.6-high' "$out_file" \
    || fail "recorded evidence must name the seat, got: $(cat "$out_file")"
ok "e2e: evidence (header + seat) recorded in the dated log"

# tried-seats must NOT be reset (an outputless run is not a success — the
# systemd retry must not re-offer a clean slate).
grep -q 'cursor/cursor-grok-4.6-high' "$tried_file" 2>/dev/null \
    || fail "tried-seats must still list the empty-stdout seat, got: $(cat "$tried_file" 2>/dev/null || echo MISSING)"
ok "e2e: tried-seats retains the outputless seat (no success-path reset)"

# ============================================================================
# 2. CONTROL: a run WITH stdout still exits 0 and records its output
# ============================================================================
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'rotation result: SKIP-WITH-NUDGE, dated line appended.\n'
printf 'PACKET-VERDICT tools=13 class=worked\n'
EOF
chmod +x "$fake_pi"
set +e
"$bin" quality-research-weekly >"$scratch/run2.out" 2>"$scratch/run2.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "control: a run WITH stdout must still exit 0, got $rc (stderr: $(cat "$scratch/run2.err"))"
grep -q 'PACKET-VERDICT tools=13 class=worked' "$out_file" \
    || fail "control: a successful run's output must still be recorded, got: $(cat "$out_file")"
ok "control: clean run exits 0, output recorded (no regression on the success path)"

# ============================================================================
# 3. Whitespace-only stdout counts as EMPTY (the Pi print-notify residue)
# ============================================================================
rm -f "$out_file"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '   \n'
EOF
chmod +x "$fake_pi"
set +e
"$bin" quality-research-weekly >"$scratch/run3.out" 2>"$scratch/run3.err"
rc=$?
set -e
[[ "$rc" == "1" ]] \
    || fail "whitespace-only stdout must also exit 1 (got $rc)"
ok "e2e: whitespace-only stdout counts as EMPTY (exit 1)"

# ============================================================================
# 4. Regression pin: the guard must live in the rc=0 path, AFTER #5189
# ============================================================================
grep -q 'fleet-ops#5515' "$bin" \
    || fail "agent-cron-run must carry the #5515 empty-stdout guard"
grep -q 'EMPTY-STDOUT' "$bin" \
    || fail "agent-cron-run must carry the EMPTY-STDOUT evidence header"
ok "agent-cron-run wires the #5515 EMPTY-STDOUT guard"

echo
echo "ALL OK: agent-cron-empty-stdout.test.sh (fleet-ops#5515)"
