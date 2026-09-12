#!/usr/bin/env bash
# tests/agent-cron-empty-stdout.test.sh
#
# fleet-ops#5515: agent-cron-run's success path treated `pi exited 0` as
# "run recorded". But pi can exit 0 with EMPTY stdout (late-stream /
# empty-message class): no assistant output, no rotation-log line, no
# escalation. Live evidence 2026-09-11: quality-research-weekly produced
# header-only cron-output files on 2026-08-29 (two attempts) and 2026-09-05
# (one attempt), the visual-quality-waves rotation log gained no line since
# 2026-08-28, and the unit reported Result=success — two weekly cycles
# silently skipped.
#
# The fix (same shape as the #5189 writes-refused guard):
#   rc=0 + whitespace-only stdout ->
#     (1) evidence (header + stderr tail) appended to the dated log file,
#     (2) seat_log EMPTY-STDOUT,
#     (3) rm the temp captures, exit 1 so Restart=on-failure re-seats and
#         StartLimitBurst fails the unit loud,
#     (4) tried-seats RETAINED (not a success — no reset).
#   rc=0 + non-empty stdout -> exit 0 unchanged (control).
#
# Runs entirely offline: stub seat-lib, a fake pi, scratch dirs.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/agent-cron-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
bash -n "$bin" || fail "agent-cron-run has a syntax error"

scratch="$(mktemp -d -t agent-cron-empty-stdout.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

stub_lib="$scratch/stub-seat-lib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
mkdir -p "$ATTEMPTS_DIR"
seat_log() { printf '%s\n' "$*" >>"$SEAT_LOG"; }
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
fake_hermes="$scratch/hermes"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_hermes"
chmod +x "$fake_hermes"

prompts_dir="$scratch/prompts"
log_dir="$scratch/cron-output"
mkdir -p "$prompts_dir" "$log_dir" "$scratch/attempts" "$scratch/workdir"
printf '# quality-research-weekly\nproduce the wave report.\n' >"$prompts_dir/quality-research-weekly.md"

export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export PATH="$scratch:$PATH"
export PROMPTS_DIR="$prompts_dir"
export LOG_DIR="$log_dir"
export WORKDIR="$scratch/workdir"
export ATTEMPTS_DIR="$scratch/attempts"
export SEAT_LOG="$scratch/seat.log"
export AGENT_CRON_ALLOW_HOME_WORKDIR=1

out_file="$log_dir/quality-research-weekly-$(date -u +%Y-%m-%d).md"
tried_file="$ATTEMPTS_DIR/agent-cron-quality-research-weekly.tried-seats"

# ============================================================================
# 1. rc=0 + EMPTY stdout -> exit 1, evidence recorded, tried-seats retained
# ============================================================================
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' >"$fake_pi"
chmod +x "$fake_pi"

set +e
"$bin" quality-research-weekly >"$scratch/run1.out" 2>"$scratch/run1.err"
rc=$?
set -e
[[ "$rc" == "1" ]] \
    || fail "empty stdout on rc=0 must exit 1 (loud, systemd Restart= re-seats), got $rc (stderr: $(cat "$scratch/run1.err"))"
ok "e2e: rc=0 + empty stdout -> exit 1 (was the silent SUCCESS stall)"

# Evidence appended to the dated OUT: header + stderr tail.
[[ -f "$out_file" ]] || fail "empty-stdout run must be recorded to $out_file"
grep -q 'EMPTY-STDOUT' "$out_file" \
    || fail "recorded evidence must carry the EMPTY-STDOUT header, got: $(cat "$out_file")"
grep -q 'seat=cursor/cursor-grok-4.6-high' "$out_file" \
    || fail "recorded evidence must name the seat, got: $(cat "$out_file")"
ok "e2e: EMPTY-STDOUT evidence (seat named) recorded in the dated log"

# tried-seats must be RETAINED (not reset — the run is not a success, and the
# systemd retry must not re-offer a clean slate).
[[ -f "$tried_file" ]] && grep -q 'cursor/cursor-grok-4.6-high' "$tried_file" \
    || fail "tried-seats must still list the seat after an empty-stdout run, got: $(cat "$tried_file" 2>/dev/null || echo MISSING)"
ok "e2e: tried-seats retained (no success-path reset)"

# No EMPTY-STDOUT line pretends success in the seat log.
grep -q 'SUCCESS' "$SEAT_LOG" \
    && fail "empty-stdout run must NOT be logged as SUCCESS, seat log: $(cat "$SEAT_LOG")"
grep -q 'EMPTY-STDOUT' "$SEAT_LOG" \
    || fail "seat log must record EMPTY-STDOUT, got: $(cat "$SEAT_LOG")"
ok "e2e: seat log records EMPTY-STDOUT, never SUCCESS"

# ============================================================================
# 2. control: rc=0 + WHITESPACE-ONLY stdout -> exit 1 (same silent stall)
# ============================================================================
: >"$SEAT_LOG"; :>"$tried_file" 2>/dev/null || true
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "  \\t\\n"\nexit 0\n' >"$fake_pi"
chmod +x "$fake_pi"
set +e
"$bin" quality-research-weekly >"$scratch/run2.out" 2>"$scratch/run2.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "whitespace-only stdout must also exit 1, got $rc"
ok "e2e: whitespace-only stdout -> exit 1"

# ============================================================================
# 3. control: rc=0 + non-empty stdout -> exit 0 unchanged, dated log has the run
# ============================================================================
: >"$SEAT_LOG"; rm -f "$out_file"; :>"$tried_file" 2>/dev/null || true
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "wave 12 rotation: performed the research, verdict follows.\\n"\nexit 0\n' >"$fake_pi"
chmod +x "$fake_pi"
set +e
"$bin" quality-research-weekly >"$scratch/run3.out" 2>"$scratch/run3.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "control: non-empty stdout run must exit 0, got $rc (stderr: $(cat "$scratch/run3.err"))"
[[ -f "$out_file" ]] && grep -q 'wave 12 rotation' "$out_file" \
    || fail "control: successful run output must be recorded to $out_file"
! grep -q 'EMPTY-STDOUT' "$out_file" \
    || fail "control: success path must not write the EMPTY-STDOUT marker"
ok "control: non-empty stdout exits 0, run recorded normally (no false positive)"

: >"$SEAT_LOG"
"$bin" quality-research-weekly >/dev/null 2>&1 || true
grep -q 'SUCCESS' "$SEAT_LOG" || fail "control: success run must still log SUCCESS"
ok "control: success path still logs SUCCESS"

# ============================================================================
# 4. Detector coverage: rc!=0 empty stdout was ALREADY a failure — the guard
#    must not change that path; assert the guard sits on the rc==0 branch by
#    ordering (guard precedes the success DIGEST write).
# ============================================================================
grep -n 'EMPTY-STDOUT' "$bin" | grep -q 'agent-cron-run' \
    || fail "agent-cron-run must emit the EMPTY-STDOUT seat_log"
line_guard=$(grep -n 'EMPTY-STDOUT on' "$bin" | head -1 | cut -d: -f1)
line_digest=$(grep -n "digest=\$(grep -m1 '^DIGEST:: '" "$bin" | head -1 | cut -d: -f1)
[[ -n "$line_guard" && -n "$line_digest" && "$line_guard" -lt "$line_digest" ]] \
    || fail "the empty-stdout guard must run BEFORE the success digest write"
ok "guard ordering: EMPTY-STDOUT check precedes the success write"

echo
echo "ALL OK: agent-cron-empty-stdout.test.sh (fleet-ops#5515)"
