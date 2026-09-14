#!/usr/bin/env bash
# tests/pi-issue-run-mid-session-bench.test.sh
#
# fleet-ops#516/#4903: a provider process killed mid-session (SIGTERM/143 —
# cursor-grok-4.6-high exits 143 on heavy ~14-minute packets) is an INFRA
# death, not a work failure. pi-issue-run must exit 0 so systemd Restart= does
# NOT re-spawn the same unit (the re-spawn storm: 174/322 <60s deaths in 12h);
# ExecStopPost starts pi-intake@ which re-queues through intake.
#
# Cleanup #4263/#6100: the per-seat bench ledger and its mark_seat_* stubs are
# DELETED — the LiteLLM proxy cooldown owns cross-unit seat health. The
# runner's mid-session duty is: classify (tried-seats, death class, exit 0),
# never bench. The record-only spy below pins that: a non-empty record fails
# the run.
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

# Overlay: record-only spy for the deleted bench stub. Cleanup #4263/#6100
# removed mark_seat_spawn_fail from lib/litellm-seat.sh; if pi-issue-run ever
# calls it again the record file becomes non-empty and the assertion fails.
cat >"$scratch/seatlib.sh" <<EOF
# shellcheck shell=bash
source "$repo_root/lib/litellm-seat.sh"
mark_seat_spawn_fail() {
    printf '%s/%s %s\n' "\$1" "\$2" "\${3:-}" >>"$scratch/mark_calls"
}
EOF
export PI_PACKET_SEAT_LIB="$scratch/seatlib.sh"

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

# (a) Cleanup #4263/#6100: the mid-session death path must NOT bench — the
# spy record must stay empty (the LiteLLM proxy cooldown owns seat health).
[[ -f "$scratch/mark_calls" ]] \
  && fail "mark_seat_spawn_fail was called on mid-session death — bench stubs are deleted (cleanup #4263/#6100); calls: $(cat "$scratch/mark_calls")"
ok "mid-session death calls NO bench stub for $np/$nm (proxy cooldown owns routing)"

# P3b: mark_* is a log stub. Proxy cooldown owns skip, not a local ledger.
shopt -s nullglob
_mid_ledgers=("$LEDGER"/*.json)
(( ${#_mid_ledgers[@]} == 0 )) \
  || fail "P3b must not write local routing ledgers, got: ${_mid_ledgers[*]}"
ok "P3b: no local per-seat ledger after mid-session death (proxy cooldown owns routing)"

ok "pi-issue-run logs a mid-session provider death; systemd re-seats the LiteLLM group"
