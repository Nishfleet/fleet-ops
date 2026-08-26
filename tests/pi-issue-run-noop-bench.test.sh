#!/usr/bin/env bash
# tests/pi-issue-run-noop-bench.test.sh
#
# fleet-ops#390: a no-op (pi exits 0 with stdout < OUT_MIN) must bench the
# seat via mark_seat_spawn_fail BEFORE exiting 1. Otherwise pick_seat sees
# a still-healthy seat and an intake re-spawn with an empty tried-seats
# file re-selects the same no-op'ing seat — the 2026-08-26 fleet-ops-378
# stuck loop (devin/swe-1-7, 1 byte stdout, unit dead, tried-seats empty).
#
# A no-op is a transient flake, not a dead seat: bench is short
# (SPAWN_FAIL_BACKOFF_S, default 300s), matching the existing spawn-fail
# path.
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

scratch="$(mktemp -d -t pi-issue-noop-bench.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

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

stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"

# Fake pi: exit 0 with 1 byte of stdout — the fleet-ops-378 signature.
# OUT_MIN defaults to 20; 1 B is a no-op.
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
printf 'x'
exit 0
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
exit 1
STUB
chmod +x "$stub_bin/worker-token"

cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/systemctl"

export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"

# Two subscription seats so after the no-op seat is benched, pick_seat
# still has somewhere else to go (the intake re-spawn case).
cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "glm-5-2", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 },
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
    "devin": { "cap": 4, "class": "subscription", "models": { "glm-5-2": 4, "swe-1-7": 4 } }
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

inst="fleet-ops-378"
printf 'Implement one GitHub issue: fleet-ops#378.\n' >"$ISSUES_DIR/${inst}.in"

set +e
bash "$bin" "$inst" >"$scratch/run.out" 2>"$scratch/run.err"
rc=$?
set -e

[[ "$rc" == "1" ]] \
  || fail "no-op pi must make pi-issue-run exit 1 (systemd re-seat), got rc=$rc err=$(cat "$scratch/run.err")"

tried="$STATE_DIR/attempts/pi-issue-${inst}.tried-seats"
[[ -s "$tried" ]] || fail "tried-seats file missing after no-op run"
seat_line=$(head -n1 "$tried")
[[ "$seat_line" == */* ]] || fail "tried-seats first line is not provider/model: $seat_line"
np="${seat_line%%/*}"
nm="${seat_line#*/}"

# (a) mark_seat_spawn_fail was called for that seat, with a no-op reason.
[[ -f "$scratch/mark_calls" ]] \
  || fail "mark_seat_spawn_fail was never called (no-op path did not bench the seat)"
grep -qF "$np/$nm" "$scratch/mark_calls" \
  || fail "mark_seat_spawn_fail was not called for $np/$nm; calls: $(cat "$scratch/mark_calls")"
grep -qF "no-op" "$scratch/mark_calls" \
  || fail "mark_seat_spawn_fail reason must mention no-op; calls: $(cat "$scratch/mark_calls")"
ok "no-op -> mark_seat_spawn_fail called for $np/$nm"

# (b) per-seat ledger has usable_at in the future so pick_seat excludes it.
ledger_file="$LEDGER/${np//[^A-Za-z0-9._-]/_}__${nm//[^A-Za-z0-9._-]/_}.json"
[[ -f "$ledger_file" ]] || fail "per-seat ledger missing at $ledger_file"
usable=$(jq -r '.usable_at // empty' "$ledger_file")
[[ -n "$usable" ]] || fail "ledger has no usable_at: $(cat "$ledger_file")"
usable_epoch=$(date -u -d "$usable" +%s)
now_epoch=$(date -u +%s)
(( usable_epoch > now_epoch )) \
  || fail "usable_at $usable is not in the future (now epoch=$now_epoch usable epoch=$usable_epoch)"
ok "ledger usable_at=$usable is in the future"

# Simulate the intake re-spawn: empty tried-seats, same ledger. pick_seat
# must skip the no-op seat and return the other one.
: >"$tried"
# shellcheck disable=SC1091
source "$repo_root/lib/seat-lib.sh"
if seat_usable "$np" "$nm"; then
    fail "seat_usable $np/$nm returned usable after no-op bench — pick_seat would re-select it"
fi
next=$(pick_seat "" "" 0 "" || true)
[[ -n "$next" ]] || fail "pick_seat returned empty after benching $np/$nm (the other seat should still be free)"
next_np=$(printf '%s' "$next" | cut -f1)
next_nm=$(printf '%s' "$next" | cut -f2)
[[ "$next_np/$next_nm" != "$np/$nm" ]] \
  || fail "pick_seat re-selected the no-op seat $np/$nm — the stuck loop is not fixed"
ok "intake re-spawn pick_seat skips $np/$nm and picks $next_np/$next_nm"

ok "pi-issue-run no-op benches the seat so re-seat picks a different seat"
