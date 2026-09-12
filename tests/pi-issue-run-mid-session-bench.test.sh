#!/usr/bin/env bash
# tests/pi-issue-run-mid-session-bench.test.sh
#
# fleet-ops#516 (auditor 2026-08-27): a provider process killed mid-session
# (SIGTERM/143 — cursor-grok-4.6-high exits 143 on heavy ~14-minute packets)
# must bench the seat via mark_seat_spawn_fail, exactly like the no-op path.
# Otherwise the tried-seats exclusion is the ONLY thing keeping the next
# restart off the killing seat, and the reaper wipes tried-seats on every
# reap — so the intake re-claim starts from an empty list and pick_seat
# re-selects the same killing seat (0509-974: cursor 143 x3, summoned the
# auditor 2026-08-26T20:40Z).
#
# fleet-ops#4903: a mid-session death is an infra death, not a work failure.
# pi-issue-run must exit 0 so systemd Restart= does NOT re-spawn the same
# unit (the re-spawn storm: 174/322 <60s deaths in 12h). ExecStopPost
# starts pi-intake@ which re-queues through intake. The seat is still
# benched (asserted below).
#
# A mid-session death is NOT a spawn ETIMEDOUT (elapsed > SPAWN_FAIL_MAX_S)
# and NOT a quota wall (no 429 in the output), so it previously fell through
# UNBENCHED. This test pins the bench.
#
# Runs entirely offline: stubbed models.json, seat-caps.json, ledger dir,
# a fake pi, and PI_ISSUES_DIR redirected into scratch. No live state
# dir, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-issue-midsession.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# P14 (fleet-ops#549): the worker App creds file must exist and mint before
# pi runs. The mid-session bench is about seat rotation, not identity — stub
# a working App identity so the run reaches pi.
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
export PI_SEAT_HEALTH_SIDECAR="$scratch/pi-seat-health.json"
export PI_ISSUES_DIR="$ISSUES_DIR"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export XDG_RUNTIME_DIR="$scratch/xdg"
mkdir -p "$XDG_RUNTIME_DIR"

stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"

# Fake pi: exit 1 with the real cursor mid-session-death marker in stderr
# (vendor CLIs self-terminate; pi-issue-run re-reports rc=1 + this line).
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
printf '' >&2
echo "Cursor exited with code 143: " >&2
sleep 0.2
exit 1
STUB
chmod +x "$stub_bin/pi"
export PI_BIN="$stub_bin/pi"

cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/gh"

cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
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

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "cursor": {
      "models": [
        { "id": "cursor-grok-4.6-high", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 },
        { "id": "composer-2.5", "cost": { "input": 0 }, "reasoning": false, "contextWindow": 100000 }
      ]
    },
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
    "cursor": { "cap": 1, "class": "subscription", "models": { "cursor-grok-4.6-high": 1, "composer-2.5": 1 } },
    "devin": { "cap": 4, "class": "subscription", "models": { "swe-1-7": 4 } }
  }
}
JSON

# Overlay: record mark_seat_spawn_fail calls, then run the real function
# so the per-seat ledger is actually written.
cat >"$scratch/seat-lib.sh" <<EOF
# shellcheck shell=bash
source "$repo_root/lib/seat-lib.sh"
eval "\$(declare -f mark_seat_spawn_fail | sed '1s/^mark_seat_spawn_fail/orig_mark_seat_spawn_fail/')"
mark_seat_spawn_fail() {
    printf '%s/%s %s\n' "\$1" "\$2" "\${3:-}" >>"$scratch/mark_calls"
    orig_mark_seat_spawn_fail "\$@"
}
EOF
export PI_PACKET_SEAT_LIB="$scratch/seat-lib.sh"

inst="0509-974"
# fleet-ops#1167: cursor is keystone/senior-review only, so the packet must be
# keystone-class for this test to exercise a cursor mid-session death.
{
  printf 'difficulty: keystone\n'
  printf 'Implement one GitHub issue: Nishfleet/0509#974 (BET 3 Offer Timeline).\n'
} >"$ISSUES_DIR/${inst}.in"

set +e
bash "$bin" "$inst" >"$scratch/run.out" 2>"$scratch/run.err"
rc=$?
set -e

# fleet-ops#4903: a mid-session provider death is an infra death, not a work
# failure. pi-issue-run must exit 0 so systemd Restart= does NOT re-spawn
# the same unit (the re-spawn storm). ExecStopPost starts pi-intake@ which
# re-queues through intake. The seat is still benched (asserted below).
[[ "$rc" == "0" ]] \
  || fail "mid-session death must exit 0 (infra-death re-queue via intake, not Restart=), got rc=$rc err=$(cat "$scratch/run.err")"

tried="$STATE_DIR/attempts/pi-issue-${inst}.tried-seats"
[[ -s "$tried" ]] || fail "tried-seats file missing after run"
seat_line=$(head -n1 "$tried")
[[ "$seat_line" == */* ]] || fail "tried-seats first line is not provider/model: $seat_line"
np="${seat_line%%/*}"
nm="${seat_line#*/}"

# (a) mark_seat_spawn_fail was called for that seat, with a mid-session reason.
[[ -f "$scratch/mark_calls" ]] \
  || fail "mark_seat_spawn_fail was never called (mid-session death path did not bench the seat)"
grep -qF "$np/$nm" "$scratch/mark_calls" \
  || fail "mark_seat_spawn_fail was not called for $np/$nm; calls: $(cat "$scratch/mark_calls")"
grep -qE "mid-session" "$scratch/mark_calls" \
  || fail "mark_seat_spawn_fail reason must mention mid-session; calls: $(cat "$scratch/mark_calls")"
ok "mid-session death -> mark_seat_spawn_fail called for $np/$nm"

# P3b: mark_* is a log stub. Proxy cooldown owns skip, not a local ledger.
shopt -s nullglob
_mid_ledgers=("$LEDGER"/*.json)
(( ${#_mid_ledgers[@]} == 0 )) \
  || fail "P3b must not write local routing ledgers, got: ${_mid_ledgers[*]}"
ok "P3b: no local per-seat ledger after mid-session death (proxy cooldown owns routing)"

ok "pi-issue-run logs a mid-session provider death; systemd re-seats the LiteLLM group"
