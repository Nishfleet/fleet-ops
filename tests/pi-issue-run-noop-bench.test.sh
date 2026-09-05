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

# P14 (fleet-ops#549): the worker App creds file must exist and mint before
# pi runs. The no-op bench is about seat rotation, not identity — stub a
# working App identity so the run reaches pi.
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
export PI_SEAT_LIB_CHECK_SYSTEMD=0
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
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
STUB
chmod +x "$stub_bin/worker-token"
export WORKER_TOKEN_BIN="$stub_bin/worker-token"

cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
args=" $* "
# fleet-ops#142/#508: if pick_seat consults live unit counts, this poison stub
# reports the fixture seats as fully occupied and the test fails.
if [[ "$args" == *" list-units "* ]]; then
  for i in 1 2 3 4; do
    printf 'pi-issue@poison-glm-5-2-%s.service loaded active running poison\n' "$i"
    printf 'pi-issue@poison-swe-1-7-%s.service loaded active running poison\n' "$i"
  done
  exit 0
fi
if [[ "$args" == *" show "* ]] && [[ "$args" == *"ExecStart"* ]]; then
  # fleet-ops#1155: the enumerator matches the literal "pi --print" in ExecStart.
  if [[ "$args" == *"glm-5-2"* ]]; then
    printf '/home/nish/.local/bin/pi --print --provider devin --model glm-5-2\n'
  else
    printf '/home/nish/.local/bin/pi --print --provider devin --model swe-1-7\n'
  fi
  exit 0
fi
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
    "devin": { "cap": 4, "class": "subscription", "remote_agent": true, "models": { "glm-5-2": 4, "swe-1-7": 4 } }
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
eval "\$(declare -f mark_seat_empty_run | sed '1s/^mark_seat_empty_run/orig_mark_seat_empty_run/')"
mark_seat_empty_run() {
    printf '%s/%s %s\n' "\$1" "\$2" "\${3:-}" >>"$scratch/mark_empty_calls"
    orig_mark_seat_empty_run "\$@"
}
EOF
export PI_PACKET_SEAT_LIB="$scratch/seat-lib.sh"

# fleet-ops#1378: the default in-process retry loop would try the second seat
# before exiting 1. Set EMPTY_RUN_RETRY_MAX=0 to preserve the original
# single-attempt behaviour for the provider-no-op and empty-run bench tests.
export EMPTY_RUN_RETRY_MAX=0

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

# (a) fleet-ops#1298: provider no-ops (stdout < OUT_MIN, exit 0) ARE seat
# faults — same class as the verdict tools=0 empty-run (fleet-ops#902).
# The seat is benched via mark_seat_empty_run (FLAT cooldown,
# EMPTY_RUN_BACKOFF_S = 15 min, fleet-ops#2343) so pick_seat skips it on the
# next intake re-spawn and reroutes to a healthy seat. #1298 reversed the
# #1416 "lane fault, no bench" decision: without a bench, an intake re-spawn
# (fresh claim, empty tried-seats) re-picked the same no-op'ing seat and
# burned 8 runs/2h on straitly/deepseek-v4-pro. mark_seat_spawn_fail must
# NOT be called (spawn-fail is the wrong class — empty_run now shares the
# geometric #3531 ladder, capped at 6 h / 1800 s for remote agents).
if [[ -f "$scratch/mark_calls" ]]; then
    fail "mark_seat_spawn_fail was called for stdout < OUT_MIN — must use mark_seat_empty_run (empty_run class, geometric cooldown), not spawn-fail (calls: $(cat "$scratch/mark_calls"))"
fi
[[ -f "$scratch/mark_empty_calls" ]] \
  || fail "mark_seat_empty_run was NOT called for stdout < OUT_MIN — provider no-op must bench the seat (fleet-ops#1298)"
grep -qF "$np/$nm" "$scratch/mark_empty_calls" \
  || fail "mark_seat_empty_run not called for $np/$nm; calls: $(cat "$scratch/mark_empty_calls")"
grep -qF "provider-no-op" "$scratch/mark_empty_calls" \
  || fail "mark_seat_empty_run reason must mention provider-no-op; calls: $(cat "$scratch/mark_empty_calls")"
ok "provider no-op (stdout < OUT_MIN) -> mark_seat_empty_run called for $np/$nm (seat fault, geometric cooldown)"

# (b) per-seat ledger: failure_mode=empty_run, usable_at ~900s (15 min) ahead.
ledger1="$LEDGER/${np//[^A-Za-z0-9._-]/_}__${nm//[^A-Za-z0-9._-]/_}.json"
[[ -f "$ledger1" ]] || fail "per-seat ledger missing at $ledger1"
mode1=$(jq -r '.failure_mode // empty' "$ledger1")
[[ "$mode1" == "empty_run" ]] \
  || fail "ledger failure_mode must be empty_run, got '$mode1': $(cat "$ledger1")"
usable1=$(jq -r '.usable_at // empty' "$ledger1")
[[ -n "$usable1" ]] || fail "ledger has no usable_at: $(cat "$ledger1")"
usable1_epoch=$(date -u -d "$usable1" +%s)
now1_epoch=$(date -u +%s)
delta1=$((usable1_epoch - now1_epoch))
(( delta1 >= 840 && delta1 <= 960 )) \
  || fail "provider no-op usable_at should be ~900s (15 min) ahead, got ${delta1}s: $(cat "$ledger1")"
ok "ledger failure_mode=empty_run usable_at=+${delta1}s (~15 min geometric cooldown, fleet-ops#2343)"

# (c) seat_usable rejects the benched seat; pick_seat with empty tried-seats
# (the intake re-spawn case) re-routes to a DIFFERENT seat — the #1298 fix.
# shellcheck disable=SC1091
source "$repo_root/lib/seat-lib.sh"
if seat_usable "$np" "$nm"; then
    fail "seat_usable $np/$nm returned usable after provider no-op bench — should be benched"
fi
ok "seat_usable $np/$nm UNUSABLE after provider no-op (reroutes on next pick)"
: >"$tried"
next=$(pick_seat "" "" 0 "" || true)
[[ -n "$next" ]] || fail "pick_seat returned empty after provider no-op bench"
next_np=$(printf '%s' "$next" | cut -f1)
next_nm=$(printf '%s' "$next" | cut -f2)
[[ "$next_np/$next_nm" != "$np/$nm" ]] \
  || fail "pick_seat re-selected the no-op seat $np/$nm on intake re-spawn (empty tried-seats) — must reroute to a healthy seat (fleet-ops#1298)"
ok "pick_seat reroutes intake re-spawn to $next_np/$next_nm (skips benched $np/$nm)"

ok "pi-issue-run provider no-op exits 1, benches seat (empty_run, geometric cooldown), reroutes to a healthy seat"

# =============================================================================
# fleet-ops#902: verdict-based EMPTY RUN — pi exits 0 and the ONLY stdout is
# the PACKET-VERDICT tools=0 line (no final text). At ~90B this exceeds
# OUT_MIN (20B), so the byte-count check alone would count it as success (the
# #902 gap: devin lane exit 0, zero output, silently counted as success). The
# empty-run check must exit 1 AND bench the seat via mark_seat_empty_run with
# a ~15 min (900s) cooldown, so the packet is re-routed and the seat is
# auto-re-eligible after the cooldown.
# =============================================================================
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
printf 'EXTLOAD-OK extension=packet-verdict mode=print-safe\nPACKET-VERDICT tools=0 class=no-tools\n'
exit 0
STUB
chmod +x "$stub_bin/pi"

inst2="fleet-ops-902"
printf 'Implement one GitHub issue: fleet-ops#902.\n' >"$ISSUES_DIR/${inst2}.in"

set +e
bash "$bin" "$inst2" >"$scratch/run2.out" 2>"$scratch/run2.err"
rc2=$?
set -e

[[ "$rc2" == "1" ]] \
  || fail "empty-run (verdict tools=0, no text) must make pi-issue-run exit 1 (systemd re-seat), got rc=$rc2 err=$(cat "$scratch/run2.err")"

# The seat pi-issue-run actually ran on (scenario 1 benched glm-5-2 for 5 min,
# so this run picks the other seat unless that bench expired). Read it from
# THIS run's tried-seats file, never assume.
tried2="$STATE_DIR/attempts/pi-issue-${inst2}.tried-seats"
[[ -s "$tried2" ]] || fail "tried-seats file missing after empty-run"
seat2_line=$(head -n1 "$tried2")
np2="${seat2_line%%/*}"
nm2="${seat2_line#*/}"
[[ "$np2" && "$nm2" ]] || fail "could not parse seat from $tried2: $seat2_line"

# (a) mark_seat_empty_run was called for that seat, with an empty-run reason.
[[ -f "$scratch/mark_empty_calls" ]] \
  || fail "mark_seat_empty_run was never called for the empty run; spawn-fail calls: $(cat "$scratch/mark_calls" 2>/dev/null || true)"
grep -qF "$np2/$nm2" "$scratch/mark_empty_calls" \
  || fail "mark_seat_empty_run not called for $np2/$nm2; calls: $(cat "$scratch/mark_empty_calls")"
grep -qF "empty-run" "$scratch/mark_empty_calls" \
  || fail "mark_seat_empty_run reason must mention the empty run; calls: $(cat "$scratch/mark_empty_calls")"
ok "empty-run -> mark_seat_empty_run called for $np2/$nm2"

# (b) per-seat ledger: failure_mode=empty_run, usable_at ~15 min ahead.
ledger2="$LEDGER/${np2//[^A-Za-z0-9._-]/_}__${nm2//[^A-Za-z0-9._-]/_}.json"
[[ -f "$ledger2" ]] || fail "per-seat ledger missing at $ledger2"
mode2=$(jq -r '.failure_mode // empty' "$ledger2")
[[ "$mode2" == "empty_run" ]] \
  || fail "ledger failure_mode must be empty_run, got '$mode2': $(cat "$ledger2")"
usable2=$(jq -r '.usable_at // empty' "$ledger2")
[[ -n "$usable2" ]] || fail "ledger has no usable_at: $(cat "$ledger2")"
usable2_epoch=$(date -u -d "$usable2" +%s)
now2_epoch=$(date -u +%s)
delta2=$((usable2_epoch - now2_epoch))
(( delta2 >= 840 && delta2 <= 960 )) \
  || fail "empty-run usable_at should be ~900s (15 min) ahead, got ${delta2}s: $(cat "$ledger2")"
ok "ledger failure_mode=empty_run usable_at=+${delta2}s (~15 min cooldown)"

# (c) seat_usable rejects the benched seat; pick_seat skips it and re-routes.
# The OTHER seat is still benched from scenario 1 (5 min) — expire its ledger
# so pick_seat has somewhere to re-route to. This proves the empty-run seat is
# skipped (not that the whole fleet is starved).
# shellcheck disable=SC1091
source "$repo_root/lib/seat-lib.sh"
for other in "devin/glm-5-2" "devin/swe-1-7"; do
    [[ "$other" == "$np2/$nm2" ]] && continue
    o_p="${other%%/*}"; o_m="${other#*/}"
    o_ledger="$LEDGER/${o_p//[^A-Za-z0-9._-]/_}__${o_m//[^A-Za-z0-9._-]/_}.json"
    rm -f "$o_ledger" 2>/dev/null || true
    # fleet-ops#1512: also clear the clobber-proof spawn-bench marker so the
    # other seat is fully usable (seat_usable checks it before the ledger).
    o_sbench="$LEDGER/${o_p//[^A-Za-z0-9._-]/_}__${o_m//[^A-Za-z0-9._-]/_}.spawn-bench.json"
    rm -f "$o_sbench" 2>/dev/null || true
done
if seat_usable "$np2" "$nm2"; then
    fail "seat_usable $np2/$nm2 returned usable after empty-run bench"
fi
next2=$(pick_seat "" "" 0 "" || true)
[[ -n "$next2" ]] || fail "pick_seat returned empty after benching $np2/$nm2"
next2_np=$(printf '%s' "$next2" | cut -f1)
next2_nm=$(printf '%s' "$next2" | cut -f2)
[[ "$next2_np/$next2_nm" != "$np2/$nm2" ]] \
  || fail "pick_seat re-selected the empty-run seat $np2/$nm2"
ok "pick_seat skips the empty-run seat and re-routes to $next2_np/$next2_nm"

ok "empty-run (tools=0 + no final text) fails loudly, benches 15 min, re-routes to the next seat"

# =============================================================================
# fleet-ops#1378: in-process no-op retry — when a seat produces a provider
# no-op (0B stdout), the script must re-run on a different seat INSIDE the
# same invocation instead of exiting 1 and consuming a systemd
# StartLimitBurst slot. The script exits 0 when the second seat succeeds, so
# no StartLimitBurst slot is consumed. Per fleet-ops#1298 the first no-op
# seat IS now benched (empty_run, geometric cooldown) so an intake re-spawn skips
# it — but the in-process retry still fires immediately on a different
# seat, so the item is never charged a StartLimitBurst slot for the flake.
# =============================================================================
# Set EMPTY_RUN_RETRY_MAX=1 so the script retries once before giving up.
export EMPTY_RUN_RETRY_MAX=1

# Reset ledgers and mark logs so both seats are usable and scenario 3 is clean.
rm -f "$LEDGER"/*.json 2>/dev/null || true
rm -f "$LEDGER"/*.spawn-bench.json 2>/dev/null || true
rm -f "$scratch/mark_calls" "$scratch/mark_empty_calls" 2>/dev/null || true
# Clear tried-seats from prior scenarios.
: >"$STATE_DIR/attempts/pi-issue-fleet-ops-378.tried-seats" 2>/dev/null || true
: >"$STATE_DIR/attempts/pi-issue-fleet-ops-902.tried-seats" 2>/dev/null || true

# Model-aware pi stub: glm-5-2 produces no output (provider no-op), swe-1-7 succeeds.
# This is deterministic and doesn't rely on temp-file state.
# pick_seat returns glm-5-2 first (scenario 1 confirmed this order).
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *glm-5-2*)
        # Provider no-op — 0 bytes stdout
        exit 0
        ;;
    *)
        printf 'Real output: fixed the issue, opened PR #9999.\n'
        exit 0
        ;;
esac
STUB
chmod +x "$stub_bin/pi"

inst3="fleet-ops-1378"
printf 'Implement one GitHub issue: fleet-ops#1378.\n' >"$ISSUES_DIR/${inst3}.in"

set +e
bash "$bin" "$inst3" >"$scratch/run3.out" 2>"$scratch/run3.err"
rc3=$?
set -e

[[ "$rc3" == "0" ]] \
  || fail "in-process retry must exit 0 (second seat succeeded), got rc=$rc3 err=$(cat "$scratch/run3.err")"

# Verify the output file contains real output from the second seat.
out3=$(cat "$PI_ISSUES_DIR/${inst3}.out" 2>/dev/null || true)
echo "$out3" | grep -qF 'Real output' \
  || fail "output file should contain 'Real output' from second seat, got: $out3"
ok "in-process retry: first seat no-op (0B), script re-seated in-process, second seat succeeded, exited 0"

# The tried-seats file for the successful run should be reset.
tried3="$STATE_DIR/attempts/pi-issue-${inst3}.tried-seats"
[[ -s "$tried3" ]] && fail "successful run must reset tried-seats, got: $(cat "$tried3")"
ok "tried-seats reset after successful in-process retry"

# fleet-ops#1298: the first no-op seat (devin/glm-5-2) IS now benched via
# mark_seat_empty_run (empty_run, geometric cooldown) so an intake re-spawn skips
# it. The spawn-fail marker (mark_seat_spawn_fail) must NOT be used — the
# empty_run class is the correct one (flat 900s; the #1408 wall ladder is
# for real spawn-fail walls only, fleet-ops#2343).
if grep -qF 'devin/glm-5-2' "$scratch/mark_calls" 2>/dev/null; then
    fail "first no-op seat (devin/glm-5-2) must use mark_seat_empty_run, not mark_seat_spawn_fail (calls: $(cat "$scratch/mark_calls"))"
fi
grep -qF 'devin/glm-5-2' "$scratch/mark_empty_calls" 2>/dev/null \
  || fail "first no-op seat (devin/glm-5-2) must be benched via mark_seat_empty_run (fleet-ops#1298); empty calls: $(cat "$scratch/mark_empty_calls" 2>/dev/null || true)"
ok "first no-op seat (devin/glm-5-2) benched via mark_seat_empty_run (empty_run, geometric cooldown) — intake re-spawn will skip it"

# =============================================================================
# fleet-ops#3531: a remote devin session that exits 0 with tools=0 but a
# pull/<n> URL in the output is NOT an empty run. It must be treated as a
# successful session (exit 0, output copied to PI_ISSUES_DIR) and must NOT
# call mark_seat_empty_run.
# =============================================================================
rm -f "$LEDGER"/*.json 2>/dev/null || true
rm -f "$LEDGER"/*.spawn-bench.json 2>/dev/null || true
rm -f "$scratch/mark_calls" "$scratch/mark_empty_calls" 2>/dev/null || true
: >"$STATE_DIR/attempts/pi-issue-${inst}.tried-seats" 2>/dev/null || true
: >"$STATE_DIR/attempts/pi-issue-${inst2}.tried-seats" 2>/dev/null || true
: >"$STATE_DIR/attempts/pi-issue-${inst3}.tried-seats" 2>/dev/null || true
export EMPTY_RUN_RETRY_MAX=0

# Remote devin: tools=0 verdict plus a real PR URL. The PR URL proves the
# session produced an outcome even though no local tools were used.
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
printf 'PACKET-VERDICT tools=0 class=worked\nhttps://github.com/Nishfleet/fleet-ops/pull/9999\n'
exit 0
STUB
chmod +x "$stub_bin/pi"

inst4="fleet-ops-3531-remote"
printf 'Implement one GitHub issue: fleet-ops-3531.\n' >"$ISSUES_DIR/${inst4}.in"

set +e
bash "$bin" "$inst4" >"$scratch/run4.out" 2>"$scratch/run4.err"
rc4=$?
set -e

[[ "$rc4" == "0" ]] \
  || fail "remote devin with PR URL must exit 0 (success), got rc=$rc4 err=$(cat "$scratch/run4.err")"

# The output file must contain the PR URL.
out4=$(cat "$PI_ISSUES_DIR/${inst4}.out" 2>/dev/null || true)
echo "$out4" | grep -qF 'https://github.com/Nishfleet/fleet-ops/pull/9999' \
  || fail "output file should contain the PR URL, got: $out4"
ok "remote devin (tools=0 + PR URL) treated as success, output contains PR URL"

# mark_seat_empty_run must NOT be called for this remote PR success.
if [[ -f "$scratch/mark_empty_calls" ]] && grep -qF 'devin' "$scratch/mark_empty_calls"; then
    fail "remote devin PR success must NOT call mark_seat_empty_run; empty calls: $(cat "$scratch/mark_empty_calls")"
fi
ok "remote devin PR success did NOT bench the seat (no mark_seat_empty_run call)"

# The tried-seats file for a successful run should be reset.
tried4="$STATE_DIR/attempts/pi-issue-${inst4}.tried-seats"
[[ -s "$tried4" ]] && fail "successful remote run must reset tried-seats, got: $(cat "$tried4")"
ok "tried-seats reset after successful remote devin PR run"

ok "fleet-ops#1378/#3531: in-process no-op retry and remote PR success both work"
