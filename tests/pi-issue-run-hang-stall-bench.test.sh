#!/usr/bin/env bash
# tests/pi-issue-run-hang-stall-bench.test.sh
#
# fleet-ops#2133: two detectors that previously existed only as a hot-patch on
# the LIVE /home/nish/.local/bin/pi-issue-run (never landed on a PR) must fire
# so the run fails loud and the seat is avoided on the next restart. Both gate
# on spawn_elapsed_s > PI_HANG_BENCH_MIN_S (default 300s).
#
#   (A) devin long-hang-then-ETIMEDOUT: rc=1, elapsed > 300s, stderr contains
#       "spawnSync ... ETIMEDOUT". NOT a spawn-phase failure (elapsed >
#       SPAWN_FAIL_MAX_S), NOT the hang watchdog (exits before
#       PI_HANG_TIMEOUT_S), NOT a mid-session signal death. Without this
#       detector the seat stays pickable and burns every retry.
#   (B) Ready-for-input stall: rc=1 (not 124), elapsed > 300s, stderr has
#       >5 "Ready for input" lines. The provider loops prompting but never
#       advances.
#
# Cleanup #4263/#6100: the per-seat bench ledger and its mark_seat_* stubs are
# DELETED — the LiteLLM proxy cooldown owns cross-unit seat health. The
# detectors' remaining job is classification + loud exit 1; the record-only
# spies below pin that NO bench stub fires (a non-empty record fails the run).
#
# Runs entirely offline: stubbed models.json, seat-caps.json, ledger dir, a
# fake pi, and PI_ISSUES_DIR redirected into scratch. PI_HANG_BENCH_MIN_S=1
# and SPAWN_FAIL_MAX_S=1 collapse the 5-minute wall-clock gate to ~1s so the
# test is fast without changing production defaults (the env vars default to
# 300 and 120 respectively in lib/litellm-seat.sh / bin/pi-issue-run).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-issue-hangstall.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# P14 (fleet-ops#549): worker App creds file must exist and mint before pi
# runs. Stub a working App identity so the run reaches pi.
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"

STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
ISSUES_DIR="$scratch/issues"
mkdir -p "$ISSUES_DIR"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"

export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_ISSUES_DIR="$ISSUES_DIR"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export XDG_RUNTIME_DIR="$scratch/xdg"
mkdir -p "$XDG_RUNTIME_DIR"

# Collapse the elapsed gates: #2133 detectors need elapsed > PI_HANG_BENCH_MIN_S
# AND (to avoid the spawn-fail block setting spawn_fail_triggered) elapsed >
# SPAWN_FAIL_MAX_S. A ~1.2s sleep clears both when each threshold is 1.
export PI_HANG_BENCH_MIN_S=1
export SPAWN_FAIL_MAX_S=1
# Keep the hang watchdog well above the test sleep so it never fires.
export PI_HANG_TIMEOUT_S=2520

stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/gh"

cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-hangstall\n'
exit 0
STUB
chmod +x "$stub_bin/worker-token"
export WORKER_TOKEN_BIN="$stub_bin/worker-token"

cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/systemctl"

export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"

# devin is the seat we exercise (the #2133 ETIMEDOUT mode is devin-observed;
# the RFI stall is provider-agnostic). devin is not keystone-restricted, so a
# normal-difficulty packet picks it.
cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "providers": {
    "devin": { "cap": 4, "class": "subscription", "models": { "swe-1-7": 4 } }
  }
}
JSON

# Overlay: record-only spies for the deleted bench stubs. Cleanup #4263/#6100
# removed them from lib/litellm-seat.sh; a non-empty record fails the run.
cat >"$scratch/seatlib.sh" <<EOF
# shellcheck shell=bash
source "$repo_root/lib/litellm-seat.sh"
mark_seat_hang_bench() {
    printf '%s/%s %s\n' "\$1" "\$2" "\${3:-}" >>"$scratch/hang_calls"
}
mark_seat_spawn_fail() {
    printf '%s/%s %s\n' "\$1" "\$2" "\${3:-}" >>"$scratch/spawnfail_calls"
}
EOF
export PI_PACKET_SEAT_LIB="$scratch/seatlib.sh"

run_scenario() {
    local label="$1" stderr_body="$2" expected_rc="$3"
    local inst="$label"
    rm -f "$scratch/hang_calls"
    rm -rf "$LEDGER"; mkdir -p "$LEDGER"
    rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"

    cat >"$stub_bin/pi" <<STUB
#!/usr/bin/env bash
printf '%s' '$stderr_body' >&2
sleep 2.2
exit $expected_rc
STUB
    chmod +x "$stub_bin/pi"
    export PI_BIN="$stub_bin/pi"

    printf 'Implement one GitHub issue: Nishfleet/fleet-ops#2133 (%s).\n' "$label" >"$ISSUES_DIR/${inst}.in"

    set +e
    bash "$bin" "$inst" >"$scratch/run.out" 2>"$scratch/run.err"
    rc=$?
    set -e

    [[ "$rc" == "1" ]] \
      || fail "$label: pi-issue-run must exit 1 (systemd re-seat), got rc=$rc err=$(cat "$scratch/run.err")"

    tried="$STATE_DIR/attempts/pi-issue-${inst}.tried-seats"
    [[ -s "$tried" ]] || fail "$label: tried-seats file missing after run"
    seat_line=$(head -n1 "$tried")
    [[ "$seat_line" == */* ]] || fail "$label: tried-seats first line is not provider/model: $seat_line"
    np="${seat_line%%/*}"
    nm="${seat_line#*/}"

    [[ -f "$scratch/hang_calls" ]] \
      && fail "$label: mark_seat_hang_bench was called — bench stubs are deleted (cleanup #4263/#6100); calls: $(cat "$scratch/hang_calls")"
    [[ -f "$scratch/spawnfail_calls" ]] \
      && fail "$label: mark_seat_spawn_fail was called — bench stubs are deleted (cleanup #4263/#6100); calls: $(cat "$scratch/spawnfail_calls")"
    ok "$label: hang detector fires, exits 1, calls NO bench stub for $np/$nm"

    shopt -s nullglob
    _hang_ledgers=("$LEDGER"/*.json)
    (( ${#_hang_ledgers[@]} == 0 )) \
      || fail "$label: P3b must not write local routing ledgers, got: ${_hang_ledgers[*]}"
    ok "$label: no local hang_bench ledger (proxy cooldown owns routing)"
}

# (A) devin long-hang-then-ETIMEDOUT. The real signature from the field is a
# spawnSync ETIMEDOUT after a ~30 min hang. stderr carries the signature; rc=1.
etimedout_body='Error: spawnSync /home/nish/.local/bin/pi ETIMEDOUT
    at Object.spawnSync (node:internal/child_process:1111:20)
spawnSync ETIMEDOUT'
run_scenario "etimedout-2133" "$etimedout_body" 1

# (B) Ready-for-input stall. >5 "Ready for input" lines, rc=1 (not 124, which
# is the hang-watchdog kill handled by mid-session-death).
rfi_body=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
    rfi_body+='Ready for input
'
done
run_scenario "rfi-stall-2133" "$rfi_body" 1


# (C)/(D) fleet-ops#3883: the hang watchdog (rc=124, a real `timeout` kill of
# pi) appends "killed" to stderr, which is_mid_session_death matches — so every
# watchdog kill used to reach mark_seat_spawn_fail and bench the seat with an
# escalating backoff. A session that made tool calls is slow, not a seat fault
# (the retirement rule classes rc=124 as infrastructure): no bench. A session
# with 0 tool calls is a true hang: bench as before. The fake pi writes the
# session jsonl exactly where pi-issue-run pins it (--session-dir/--session-id)
# and then blocks until PI_HANG_TIMEOUT_S kills it.
run_watchdog_scenario() {
    local label="$1" ntools="$2" expect_bench="$3"
    local inst="$label"
    rm -f "$scratch/hang_calls" "$scratch/spawnfail_calls"
    rm -rf "$LEDGER"; mkdir -p "$LEDGER"
    rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"

    cat >"$stub_bin/pi" <<STUB
#!/usr/bin/env bash
sdir=""; sid=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --session-dir) sdir="\$2"; shift 2 ;;
        --session-id) sid="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
mkdir -p "\$sdir"
: >"\$sdir/\$sid.jsonl"
for ((i = 0; i < $ntools; i++)); do
    printf '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"t%s","name":"bash","arguments":{"command":"true"}}]}}\\n' "\$i" >>"\$sdir/\$sid.jsonl"
    printf '{"type":"message","message":{"role":"toolResult","toolCallId":"t%s","content":[{"type":"text","text":"ok"}]}}\\n' "\$i" >>"\$sdir/\$sid.jsonl"
done
printf 'working\\n'
exec sleep 60
STUB
    chmod +x "$stub_bin/pi"
    export PI_BIN="$stub_bin/pi"

    printf 'Implement one GitHub issue: Nishfleet/fleet-ops#3883 (%s).\n' "$label" >"$ISSUES_DIR/${inst}.in"

    set +e
    PI_HANG_TIMEOUT_S=3 bash "$bin" "$inst" >"$scratch/run.out" 2>"$scratch/run.err"
    rc=$?
    set -e
    # fleet-ops#4903: rc=124 is an infra death (hang watchdog kill). pi-issue-run
    # must exit 0 so Restart= does NOT re-spawn the same unit. ExecStopPost
    # starts pi-intake@ which re-queues through intake.
    [[ "$rc" == "0" ]] \
      || fail "$label: hang-watchdog infra death must exit 0 (re-queue via intake), got rc=$rc err=$(tail -n 5 "$scratch/run.err")"

    tried="$STATE_DIR/attempts/pi-issue-${inst}.tried-seats"
    [[ -s "$tried" ]] || fail "$label: tried-seats file missing after run"
    seat_line=$(head -n1 "$tried")
    np="${seat_line%%/*}"
    nm="${seat_line#*/}"

    grep -q 'PI HANG WATCHDOG' "$STATE_DIR/watch.log" "$scratch/run.err" 2>/dev/null \
      || fail "$label: the hang watchdog did not fire (rc=124 path not exercised): $(tail -n 5 "$scratch/run.err")"
    cls=$(cat "$STATE_DIR/attempts/pi-issue-${inst}.last-death-class" 2>/dev/null || true)
    [[ "$cls" == "infra" ]] || fail "$label: last-death-class want infra got '$cls'"

    # shellcheck disable=SC1091
    source "$repo_root/lib/litellm-seat.sh"
    if [[ "$expect_bench" == "no" ]]; then
        [[ ! -f "$scratch/spawnfail_calls" ]] \
          || fail "$label: mark_seat_spawn_fail was called for a session with $ntools tool calls: $(cat "$scratch/spawnfail_calls")"
        if (( ntools > 0 )); then
            grep -q "HANG WATCHDOG kill after $ntools tool calls" "$STATE_DIR/watch.log" "$scratch/run.err" 2>/dev/null \
              || fail "$label: slow-session log line missing: $(grep -h 'pi-issue-run' "$STATE_DIR/watch.log" 2>/dev/null | tail -n 5)"
        fi
        ok "$label: rc=124 with $ntools tool calls -> no bench stub call, death class infra (proxy cooldown owns health)"
    else
        [[ -f "$scratch/spawnfail_calls" ]] \
          && fail "$label: mark_seat_spawn_fail was called for a 0-tool-call hang — bench stubs are deleted (cleanup #4263/#6100); calls: $(cat "$scratch/spawnfail_calls")"
        ok "$label: rc=124 with 0 tool calls -> exits loud via intake re-queue, no bench stub call"
    fi
}

run_watchdog_scenario "wd-slow-3883" 7 no
run_watchdog_scenario "wd-hang-3883" 0 no

ok "pi-issue-run #2133 hang/stall detectors fire and exit loud; no bench stub fires (cleanup #4263/#6100)"
