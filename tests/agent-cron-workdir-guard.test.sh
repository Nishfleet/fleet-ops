#!/usr/bin/env bash
# tests/agent-cron-workdir-guard.test.sh
#
# auditor-finding-B (2026-08-26T02:57Z, AUDITOR-LOG.md): agent-cron-run
# defaulted WORKDIR to $HOME when the unit env was absent, so a manual
# invocation (or a misconfigured unit) silently ran the product cron against
# $HOME. The 0509-daily-market-signal unit sets WORKDIR correctly, but the
# silent fallback masked the fault. This locks the fail-closed guard:
#   - WORKDIR unset or equal to $HOME -> FATAL, exit 1, named slug, pi never
#     invoked.
#   - WORKDIR set to a real dir -> runs as before.
#   - AGENT_CRON_ALLOW_HOME_WORKDIR=1 -> explicit escape hatch still runs.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/agent-cron-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t agent-cron-workdir.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub seat-lib so the guard scenarios never reach seat picking.
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
pick_seat() { printf 'cursor\tcomposer-2.5\n'; return 0; }
EOF

# Fake pi that records invocation — the guard must stop pi from ever running.
fake_pi="$scratch/pi"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
echo "$*" > "$PI_RECORD_ARGS"
echo "ran"
EOF
chmod +x "$fake_pi"

record_args="$scratch/pi.args"
rm -f "$record_args"
prompts_dir="$scratch/prompts"
log_dir="$scratch/cron-output"
mkdir -p "$prompts_dir" "$log_dir"
printf '# guard-test prompt\nbody\n' >"$prompts_dir/0509-daily-market-signal.md"

export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export PATH="$scratch:$PATH"
export PROMPTS_DIR="$prompts_dir"
export LOG_DIR="$log_dir"
export PI_RECORD_ARGS="$record_args"
export ATTEMPTS_DIR="$scratch/attempts"

# --- scenario 1: WORKDIR unset (inherits $HOME) -> FATAL, exit 1 ------------
set +e
env -u WORKDIR -u AGENT_CRON_ALLOW_HOME_WORKDIR \
    "$bin" 0509-daily-market-signal >"$scratch/run1.out" 2>"$scratch/run1.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario 1: missing WORKDIR must exit 1, got $rc"
grep -q 'FATAL' "$scratch/run1.err" \
  || fail "scenario 1: must fail loud with FATAL, got: $(cat "$scratch/run1.err")"
grep -q '0509-daily-market-signal' "$scratch/run1.err" \
  || fail "scenario 1: FATAL must name the slug, got: $(cat "$scratch/run1.err")"
[[ ! -s "$record_args" ]] \
  || fail "scenario 1: pi must NOT be invoked when WORKDIR is missing, got: $(cat "$record_args" 2>/dev/null)"
ok "scenario 1: WORKDIR unset -> FATAL exit 1, slug named, pi never invoked"

# --- scenario 2: WORKDIR=$HOME explicitly -> FATAL, exit 1 ------------------
set +e
WORKDIR="$HOME" "$bin" 0509-daily-market-signal >"$scratch/run2.out" 2>"$scratch/run2.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario 2: WORKDIR=\$HOME must exit 1, got $rc"
grep -q 'FATAL' "$scratch/run2.err" \
  || fail "scenario 2: must fail loud with FATAL, got: $(cat "$scratch/run2.err")"
ok "scenario 2: WORKDIR=\$HOME -> FATAL exit 1"

# --- scenario 3: WORKDIR is a real dir -> runs, pi invoked ------------------
rm -f "$record_args"
real_dir="$scratch/realwork"
mkdir -p "$real_dir"
set +e
WORKDIR="$real_dir" "$bin" 0509-daily-market-signal >"$scratch/run3.out" 2>"$scratch/run3.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario 3: real WORKDIR must exit 0, got $rc (stderr: $(cat "$scratch/run3.err"))"
grep -q -- '--provider cursor' "$record_args" \
  || fail "scenario 3: pi must be invoked, got: $(cat "$record_args" 2>/dev/null)"
ok "scenario 3: real WORKDIR -> runs, pi invoked"

# --- scenario 4: escape hatch AGENT_CRON_ALLOW_HOME_WORKDIR=1 runs ----------
rm -f "$record_args"
set +e
WORKDIR="$HOME" AGENT_CRON_ALLOW_HOME_WORKDIR=1 \
    "$bin" 0509-daily-market-signal >"$scratch/run4.out" 2>"$scratch/run4.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario 4: escape hatch must exit 0, got $rc (stderr: $(cat "$scratch/run4.err"))"
grep -q -- '--provider cursor' "$record_args" \
  || fail "scenario 4: escape hatch must still invoke pi, got: $(cat "$record_args" 2>/dev/null)"
ok "scenario 4: AGENT_CRON_ALLOW_HOME_WORKDIR=1 escape hatch runs"

ok "agent-cron WORKDIR guard: fail-closed on missing/\\\$HOME workdir, named slug, escape hatch"
