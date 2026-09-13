#!/usr/bin/env bash
# tests/agent-cron-prompt-e2big-guard.test.sh
#
# fleet-ops#5309: pi's cursor provider passes the whole composed prompt to
# cursor-agent as a spawn ARGUMENT. The kernel's per-arg limit on this box is
# ~82KB (measured 2026-09-11: 80KB prompt rc=0, 90KB prompt `spawnSync
# /home/nish/.local/bin/cursor-agent E2BIG` rc=1 in ~1s). fable-check.md grew
# past it on 2026-09-11 and fable-fleet-check.service crash-looped: each
# Restart re-picked cursor, pi exited 1 in 1s, no bench marker was written
# (E2BIG was not in is_spawn_etimeout's signature list, spawn_fail=0), so
# tried-seats was the only guard and the same seat was re-picked until
# StartLimitBurst=3 tripped the unit.
#
# Locks the fix:
#   - prompt file > PROMPT_E2BIG_CAP_BYTES (default 75000) -> exit 1 with the
#     distinct line `PROMPT TOO LARGE <bytes> for cursor spawn-arg limit`,
#     pi NEVER spawned, pick-seat NEVER called, no seat bench written (the
#     seat is healthy; the prompt is the fault).
#   - prompt under the cap -> runs as before.
#   - PROMPT_E2BIG_CAP_BYTES is an env-tunable cap.
#   - backstop: the REAL lib/litellm-seat.sh is_spawn_etimeout now classifies
#     `spawnSync <bin> E2BIG` so a missed case benches with a spawn-bench
#     marker instead of crash-looping.
#
# NOTE (issue item 3): long-prompt judges (fable-check) must keep their
# prompt under the cap. The pre-flight is the real gate for live prompts
# (operator-managed files outside the repo); the class lock below also
# pins every repo-tracked cron prompt under the cap so a repo edit cannot
# re-bloat one past the spawn-arg limit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/agent-cron-run"
real_lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$real_lib" ]] || fail "seatlib.sh not found: $real_lib"

scratch="$(mktemp -d -t agent-cron-e2big.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub seatlib: deterministic pick-seat + call recorders so the test can
# prove the guard exits BEFORE any seat work happens.
stub_lib="$scratch/seatlib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
ATTEMPTS_DIR="${ATTEMPTS_DIR:-/tmp/agent-cron-attempts-stub}"
mkdir -p "$ATTEMPTS_DIR"
seat_log() { printf '%s\n' "$*" >>"${SEAT_CALLS:-/dev/null}"; }
task_weight() { echo "light"; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_spawn_fail() { echo "spawn_fail $*" >>"${SEAT_CALLS:?}"; return 0; }
mark_seat_quota_bench() { echo "quota_bench $*" >>"${SEAT_CALLS:?}"; return 0; }
litellm_seat() { echo "pick-seat $*" >>"${SEAT_CALLS:?}"; printf 'cursor\tcomposer-2.5\n'; return 0; }
EOF

fake_pi="$scratch/pi"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PI_RECORD_ARGS"
cat >/dev/null
printf 'body\nDIGEST:: d\n'
EOF
chmod +x "$fake_pi"

record_args="$scratch/pi.args"
seat_calls="$scratch/seat.calls"
prompts_dir="$scratch/prompts"
log_dir="$scratch/cron-output"
mkdir -p "$prompts_dir" "$log_dir"
printf '# small prompt\nbody\n' >"$prompts_dir/small.md"
# 80000 bytes > the 75000 default cap, under the ~82KB kernel limit so the
# guard is what stops it (not a real E2BIG from a fake pi).
head -c 80000 /dev/zero | tr '\0' 'a' >"$prompts_dir/huge.md"

export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export PATH="$scratch:$PATH"
export PROMPTS_DIR="$prompts_dir"
export LOG_DIR="$log_dir"
export WORKDIR="$scratch"
export PI_RECORD_ARGS="$record_args"
export SEAT_CALLS="$seat_calls"
export ATTEMPTS_DIR="$scratch/attempts"

# --- scenario 1: oversized prompt -> exit 1, marker line, no spawn, no seat -
: >"$seat_calls"; rm -f "$record_args"
set +e
"$bin" huge >"$scratch/run1.out" 2>"$scratch/run1.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario 1: oversized prompt must exit 1, got $rc"
grep -q 'PROMPT TOO LARGE 80000 for cursor spawn-arg limit' "$scratch/run1.err" \
  || fail "scenario 1: stderr must carry the PROMPT TOO LARGE marker, got: $(cat "$scratch/run1.err")"
grep -q 'fleet-ops#5307' "$scratch/run1.err" \
  || fail "scenario 1: marker must carry the issue ref, got: $(cat "$scratch/run1.err")"
[[ ! -s "$record_args" ]] \
  || fail "scenario 1: pi must NOT be spawned on an oversized prompt, got: $(cat "$record_args" 2>/dev/null)"
if grep -q 'pick-seat' "$seat_calls"; then
    fail "scenario 1: pick-seat must NOT run when the prompt is oversized: $(cat "$seat_calls")"
fi
if grep -qE 'spawn_fail|quota_bench' "$seat_calls"; then
    fail "scenario 1: no seat bench may be written — the seat is healthy: $(cat "$seat_calls")"
fi
[[ ! -s "$ATTEMPTS_DIR/agent-cron-huge.tried-seats" ]] \
  || fail "scenario 1: tried-seats must stay empty (no seat was consumed): $(cat "$ATTEMPTS_DIR/agent-cron-huge.tried-seats" 2>/dev/null)"
ok "scenario 1: 80KB prompt -> PROMPT TOO LARGE exit 1, pi never spawned, no seat picked or benched"

# --- scenario 2: prompt under the cap -> runs as before ---------------------
: >"$seat_calls"; rm -f "$record_args"
set +e
"$bin" small >"$scratch/run2.out" 2>"$scratch/run2.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario 2: small prompt must exit 0, got $rc (stderr: $(cat "$scratch/run2.err"))"
grep -q -- '--provider cursor' "$record_args" \
  || fail "scenario 2: pi must be invoked on the picked seat, got: $(cat "$record_args" 2>/dev/null)"
ok "scenario 2: prompt under cap -> runs, pi invoked on picked seat"

# --- scenario 3: PROMPT_E2BIG_CAP_BYTES env override tunes the cap ----------
: >"$seat_calls"; rm -f "$record_args"
set +e
PROMPT_E2BIG_CAP_BYTES=10 "$bin" small >"$scratch/run3.out" 2>"$scratch/run3.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario 3: cap=10 on a 20-byte prompt must exit 1, got $rc"
grep -q 'PROMPT TOO LARGE' "$scratch/run3.err" \
  || fail "scenario 3: env-lowered cap must trip the same marker, got: $(cat "$scratch/run3.err")"
[[ ! -s "$record_args" ]] \
  || fail "scenario 3: pi must NOT be spawned when the env cap trips"
ok "scenario 3: PROMPT_E2BIG_CAP_BYTES override trips the guard"

# --- scenario 4: real seatlib is_spawn_etimeout classifies spawnSync E2BIG -
# Backstop (issue item: optionally add E2BIG to the signature scan). Sources
# the REAL lib in a subshell with scratch state so no production dirs/files
# are touched.
(
    export PI_PACKET_STATE="$scratch/state"
    export PI_SEAT_LIB_CHECK_TRANSPORT=0
    export PI_SEAT_LIB_CHECK_SYSTEMD=0
    export SEAT_LOG_FILE="$scratch/seat-watch.log"
    # shellcheck source=../lib/litellm-seat.sh source-path=SCRIPTDIR
    source "$real_lib"
    # The observed live signature: `spawnSync /home/nish/.local/bin/cursor-agent E2BIG`.
    if ! is_spawn_etimeout "" "Error: spawnSync /home/nish/.local/bin/cursor-agent E2BIG"; then
        echo "FAIL: is_spawn_etimeout must classify spawnSync ... E2BIG" >&2
        exit 1
    fi
    # Negative controls: bare E2BIG with no spawn-signal word must NOT match
    # (a mid-session read/write E2BIG is not a spawn-phase fault), and a
    # plain provider error must still not match.
    if is_spawn_etimeout "" "read failed: E2BIG"; then
        echo "FAIL: is_spawn_etimeout must NOT match a spawn-word-free E2BIG" >&2
        exit 1
    fi
    if is_spawn_etimeout "" "pi: simulated 429"; then
        echo "FAIL: is_spawn_etimeout must NOT match a plain 429" >&2
        exit 1
    fi
    exit 0
) || fail "scenario 4: real seatlib is_spawn_etimeout E2BIG classification failed"
ok "scenario 4: is_spawn_etimeout benches spawnSync E2BIG, ignores spawn-free E2BIG and plain errors"

# --- class lock: every repo-tracked cron prompt stays under the cap --------
# Live cron prompts are operator-managed files outside the repo (the
# pre-flight is their gate); the repo copies in prompts/ are the MANIFEST
# source, so pin them under the default cap here.
while IFS= read -r p; do
    bytes=$(wc -c <"$p")
    (( bytes <= 75000 )) \
        || fail "class lock: $p is ${bytes}B > 75000B cap — a cron prompt this size E2BIGs on cursor seats (fleet-ops#5309)"
done < <(find "$repo_root/prompts" -name '*.md' -type f)
ok "class lock: all repo prompts/*.md under the 75000B spawn-arg cap"

ok "agent-cron prompt-E2BIG guard: oversized prompt fails loud pre-spawn, no seat consumed, env-tunable, E2BIG classified"
