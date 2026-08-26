#!/usr/bin/env bash
# tests/interactive-session-reap.test.sh
#
# fleet-ops#85: stale interactive sessions in session-*.scope are reaped
# with SIGTERM-then-SIGKILL; mid-work sessions are not.
#
# Invariants:
#   1. Wiring: binary, timer, service, MANIFEST, Idle N=8, SIGTERM-first.
#   2. user@1000.service (fleet heartbeat / intake / pi-issue) is ignored.
#   3. sshd, tailscaled, Codex app-server, Cursor worker start are skipped.
#   4. Recent jsonl (last tool-call) is not reaped.
#   5. --dry-run logs a stale ccd-cli and does not kill it.
#   6. Dirty worktree blocks the reap.
#   7. claim/issue-* branch blocks the reap.
#   8. Clean no-claim stale session is SIGTERM'd.
#   9. SIGTERM-ignored fixture is SIGKILL'd after the grace window.
#  10. No-resume PID is fail-closed on first sight and reaped after N hours
#      of zero IO delta.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/interactive-session-reap"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || { chmod +x "$bin"; }
[[ -x "$bin" ]] || fail "not executable: $bin"
bash -n "$bin" || fail "bash -n $bin"

# --- invariant 1: wiring ---------------------------------------------------
svc="$repo_root/systemd/interactive-session-reap.service"
timer="$repo_root/systemd/interactive-session-reap.timer"
manifest="$repo_root/MANIFEST"
[[ -f "$svc" ]] || fail "missing $svc"
[[ -f "$timer" ]] || fail "missing $timer"
grep -q "^ExecStart=/bin/bash -c 'exec /home/nish/.local/bin/interactive-session-reap'\$" "$svc" \
  || fail "service ExecStart must wrap bash -c exec (CI stubs cannot name a new binary)"
grep -q '^Restart=no$' "$svc" || fail "service must Restart=no (timer is the retry)"
grep -q '^OnCalendar=\*:41$' "$timer" || fail "timer must fire hourly at :41"
grep -q '^\[Install\]$' "$timer" || fail "timer must have [Install] so install.sh enable --now picks it up"
grep -q '^WantedBy=timers.target$' "$timer" || fail "timer WantedBy=timers.target"
grep -q 'IDLE_HOURS:-8' "$bin" || fail "default N must be 8 hours (measured idle tail 2026-08-27)"
grep -q 'kill -TERM' "$bin" || fail "must SIGTERM first"
grep -q 'kill -KILL' "$bin" || fail "must SIGKILL after grace"
grep -q 'sshd' "$bin" && grep -q 'tailscaled' "$bin" && grep -q 'fleet-heartbeat' "$bin" \
  || fail "must name sshd/tailscaled/fleet-heartbeat as out of scope"
bin_line="bin/interactive-session-reap /home/nish/.local/bin/interactive-session-reap"
svc_line="systemd/interactive-session-reap.service /home/nish/.config/systemd/user/interactive-session-reap.service"
timer_line="systemd/interactive-session-reap.timer /home/nish/.config/systemd/user/interactive-session-reap.timer"
grep -Fxq "$bin_line" "$manifest" || fail "MANIFEST missing: $bin_line"
grep -Fxq "$svc_line" "$manifest" || fail "MANIFEST missing: $svc_line"
grep -Fxq "$timer_line" "$manifest" || fail "MANIFEST missing: $timer_line"
ok "invariant 1: wiring locked"

scratch="$(mktemp -d -t isr.XXXXXX)"
cleanup() {
    [[ -n "${keep_pid:-}" ]] && kill -KILL "$keep_pid" 2>/dev/null || true
    [[ -n "${term_pid:-}" ]] && kill -KILL "$term_pid" 2>/dev/null || true
    [[ -n "${ign_pid:-}" ]] && kill -KILL "$ign_pid" 2>/dev/null || true
    [[ -n "${io_pid:-}" ]] && kill -KILL "$io_pid" 2>/dev/null || true
    rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

proc="$scratch/proc"
projects="$scratch/claude/projects/-home-nish"
state_dir="$scratch/state"
triage="$scratch/triage.md"
mkdir -p "$proc" "$projects" "$state_dir"
: >"$triage"

NOW=2000000000
IDLE=8
UUID="11111111-1111-1111-1111-111111111111"
SESSION_CG="0::/user.slice/user-1000.slice/session-33934.scope"
FLEET_CG="0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-pi\\x2dissue.slice/pi-issue@fleet-ops-1.service"

write_cmdline() {
    local dest="$1"; shift
    python3 -c 'import sys,pathlib; pathlib.Path(sys.argv[1]).write_bytes(b"\0".join(a.encode() for a in sys.argv[2:])+b"\0")' "$dest" "$@"
}

write_stat() {
    local dest="$1" pid="$2" comm="$3"
    printf '%s (%s) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 99 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n' \
        "$pid" "$comm" >"$dest"
}

make_agent_proc() {
    local pid="$1" cg="$2" comm="$3" cwd="$4"
    shift 4
    local d="$proc/$pid"
    mkdir -p "$d"
    printf '%s\n' "$cg" >"$d/cgroup"
    printf '%s\n' "$comm" >"$d/comm"
    write_cmdline "$d/cmdline" "$@"
    write_stat "$d/stat" "$pid" "$comm"
    printf 'PPid:\t1\n' >"$d/status"
    printf 'rchar: 10\nwchar: 10\n' >"$d/io"
    ln -sfn "$cwd" "$d/cwd"
}

init_git() {
    local dir="$1" branch="${2:-main}"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "test"
    printf 'x\n' >"$dir/file"
    git -C "$dir" add file
    git -C "$dir" commit -q -m init
    if [[ "$branch" != "main" && "$branch" != "master" ]]; then
        git -C "$dir" checkout -q -b "$branch"
    fi
}

touch_jsonl() {
    local uuid="$1" epoch="$2"
    local f="$projects/${uuid}.jsonl"
    printf '{"type":"x"}\n' >"$f"
    touch -d "@$epoch" "$f"
}

run_bin() {
    PROC_ROOT="$proc" \
    CLAUDE_PROJECTS="$scratch/claude/projects" \
    INTERACTIVE_SESSION_REAP_STATE="$state_dir" \
    TRIAGE_FILE="$triage" \
    NOW_EPOCH="$NOW" \
    IDLE_HOURS="$IDLE" \
    GRACE_SEC="${GRACE_SEC:-1}" \
    "$bin" "$@"
}

clean_git="$scratch/clean"
init_git "$clean_git"

# --- invariant 2: fleet cgroup ignored -------------------------------------
: >"$triage"
printf '{}' >"$state_dir/io-state.json"
make_agent_proc 9001 "$FLEET_CG" ccd-cli "$clean_git" \
    /home/nish/.claude/remote/ccd-cli/2.1.246 --resume="$UUID"
touch_jsonl "$UUID" $((NOW - 12 * 3600))
out="$(run_bin --dry-run 2>&1 || true)"
grep -q 'SESSION-REAP' "$triage" && fail "fleet cgroup must not reap: $(cat "$triage")"
grep -q 'would reap pid=9001' <<<"$out" && fail "fleet cgroup dry-run must not name pid 9001"
ok "invariant 2: user@1000.service cgroup ignored"

# --- invariant 3: protected cmdlines skipped -------------------------------
: >"$triage"
rm -rf "$proc"; mkdir -p "$proc"
for spec in \
    "9002 sshd /usr/sbin/sshd -D" \
    "9003 tailscaled /usr/sbin/tailscaled" \
    "9004 codex /home/nish/.codex/bin/codex app-server --listen unix://" \
    "9005 node /home/nish/.local/bin/cursor-agent worker start --name box"
do
    set -- $spec
    pid="$1"; comm="$2"; shift 2
    make_agent_proc "$pid" "$SESSION_CG" "$comm" "$clean_git" "$@"
done
out="$(run_bin --dry-run 2>&1 || true)"
if grep -qE 'would reap pid=900[2-5]' <<<"$out"; then
    fail "protected cmdlines were listed: $out"
fi
ok "invariant 3: sshd/tailscaled/app-server/worker-start skipped"

# --- invariant 4: recent jsonl is kept -------------------------------------
: >"$triage"
rm -rf "$proc"; mkdir -p "$proc"
printf '{}' >"$state_dir/io-state.json"
keep_pid=""
sleep 120 &
keep_pid=$!
make_agent_proc "$keep_pid" "$SESSION_CG" ccd-cli "$clean_git" \
    /home/nish/.claude/remote/ccd-cli/2.1.246 --resume="$UUID"
touch_jsonl "$UUID" $((NOW - 60))
run_bin 2>/dev/null || true
kill -0 "$keep_pid" 2>/dev/null || fail "recent jsonl session was killed"
grep -q 'SESSION-REAP' "$triage" && fail "recent jsonl must not triage a reap: $(cat "$triage")"
ok "invariant 4: recent jsonl is not reaped"
kill -KILL "$keep_pid" 2>/dev/null || true
keep_pid=""

# --- invariant 5: dry-run does not kill ------------------------------------
: >"$triage"
rm -rf "$proc"; mkdir -p "$proc"
printf '{}' >"$state_dir/io-state.json"
term_pid=""
sleep 120 &
term_pid=$!
make_agent_proc "$term_pid" "$SESSION_CG" ccd-cli "$clean_git" \
    /home/nish/.claude/remote/ccd-cli/2.1.246 --resume="$UUID"
touch_jsonl "$UUID" $((NOW - 12 * 3600))
out="$(run_bin --dry-run 2>&1)"
kill -0 "$term_pid" 2>/dev/null || fail "dry-run killed the fixture"
grep -q "would reap pid=$term_pid" <<<"$out" || fail "dry-run must name the stale pid: $out"
grep -q 'SESSION-REAP-DRY' "$triage" || fail "dry-run must log SESSION-REAP-DRY: $(cat "$triage")"
grep -q "session=33934" "$triage" || fail "triage must name session id: $(cat "$triage")"
ok "invariant 5: dry-run logs and does not kill"

# --- invariant 6: dirty worktree blocks ------------------------------------
: >"$triage"
dirty="$scratch/dirty"
init_git "$dirty"
printf 'dirty\n' >"$dirty/file"
rm -rf "$proc"; mkdir -p "$proc"
printf '{}' >"$state_dir/io-state.json"
make_agent_proc "$term_pid" "$SESSION_CG" ccd-cli "$dirty" \
    /home/nish/.claude/remote/ccd-cli/2.1.246 --resume="$UUID"
touch_jsonl "$UUID" $((NOW - 12 * 3600))
run_bin 2>/dev/null || true
kill -0 "$term_pid" 2>/dev/null || fail "dirty worktree session was killed"
grep -q 'SESSION-REAP-SKIP' "$triage" || fail "dirty worktree must skip: $(cat "$triage")"
grep -q 'dirty-worktree' "$triage" || fail "skip reason must name dirty-worktree: $(cat "$triage")"
ok "invariant 6: dirty worktree blocks reap"

# --- invariant 7: claim branch blocks --------------------------------------
: >"$triage"
claimed="$scratch/claimed"
init_git "$claimed" "claim/issue-99"
rm -rf "$proc"; mkdir -p "$proc"
printf '{}' >"$state_dir/io-state.json"
make_agent_proc "$term_pid" "$SESSION_CG" ccd-cli "$claimed" \
    /home/nish/.claude/remote/ccd-cli/2.1.246 --resume="$UUID"
touch_jsonl "$UUID" $((NOW - 12 * 3600))
run_bin 2>/dev/null || true
kill -0 "$term_pid" 2>/dev/null || fail "claim-branch session was killed"
grep -q 'claim-ref:claim/issue-99' "$triage" || fail "skip must name claim ref: $(cat "$triage")"
ok "invariant 7: claim/issue-* branch blocks reap"
kill -KILL "$term_pid" 2>/dev/null || true
term_pid=""

# --- invariant 8: clean stale session is SIGTERM'd -------------------------
: >"$triage"
rm -rf "$proc"; mkdir -p "$proc"
printf '{}' >"$state_dir/io-state.json"
term_pid=""
sleep 120 &
term_pid=$!
make_agent_proc "$term_pid" "$SESSION_CG" ccd-cli "$clean_git" \
    /home/nish/.claude/remote/ccd-cli/2.1.246 --resume="$UUID"
touch_jsonl "$UUID" $((NOW - 12 * 3600))
run_bin 2>/dev/null || true
if kill -0 "$term_pid" 2>/dev/null; then
    fail "stale clean session survived SIGTERM"
fi
grep -q 'SESSION-REAP' "$triage" || fail "reap must be triaged: $(cat "$triage")"
grep -q "pid=$term_pid" "$triage" || fail "triage must name pid: $(cat "$triage")"
grep -q 'idle_h=' "$triage" || fail "triage must name idle age: $(cat "$triage")"
ok "invariant 8: clean stale session SIGTERM'd"
term_pid=""

# --- invariant 9: SIGKILL after ignored SIGTERM ----------------------------
: >"$triage"
rm -rf "$proc"; mkdir -p "$proc"
printf '{}' >"$state_dir/io-state.json"
ign_pid=""
python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)' &
ign_pid=$!
# Let the ignorer install its handler.
sleep 0.2
make_agent_proc "$ign_pid" "$SESSION_CG" ccd-cli "$clean_git" \
    /home/nish/.claude/remote/ccd-cli/2.1.246 --resume="$UUID"
touch_jsonl "$UUID" $((NOW - 12 * 3600))
GRACE_SEC=1 run_bin 2>/dev/null || true
if kill -0 "$ign_pid" 2>/dev/null; then
    fail "SIGTERM-ignorer survived SIGKILL"
fi
ok "invariant 9: SIGKILL after grace"
ign_pid=""

# --- invariant 10: no-resume fail-closed, then IO-idle reap ----------------
: >"$triage"
rm -rf "$proc"; mkdir -p "$proc"
printf '{}' >"$state_dir/io-state.json"
io_pid=""
sleep 120 &
io_pid=$!
make_agent_proc "$io_pid" "$SESSION_CG" ccd-cli "$clean_git" \
    /home/nish/.claude/remote/ccd-cli/2.1.246 --output-format stream-json
run_bin --dry-run 2>/dev/null || true
kill -0 "$io_pid" 2>/dev/null || fail "first-sight no-resume was killed"
grep -q "would reap pid=$io_pid" <<<"$(cat "$triage"; true)" && fail "first sight must not reap"
# Same IO, 9 hours later.
NOW=$((NOW + 9 * 3600))
: >"$triage"
out="$(run_bin --dry-run 2>&1)"
grep -q "would reap pid=$io_pid" <<<"$out" || fail "IO-idle no-resume must reap on second tick: $out"
ok "invariant 10: no-resume fail-closed then IO-idle reap"
kill -KILL "$io_pid" 2>/dev/null || true
io_pid=""

echo "OK: interactive-session-reap invariants 1-10 locked (fleet-ops#85)"
