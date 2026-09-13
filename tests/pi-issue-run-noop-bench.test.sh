#!/usr/bin/env bash
# tests/pi-issue-run-noop-bench.test.sh
#
# fleet-ops#390: a no-op (pi exits 0 with stdout < OUT_MIN) must bench the
# seat via mark_seat_spawn_fail BEFORE exiting 1. Otherwise pick-seat sees
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
# Default: no open PR, issue open. Tests override for PR-shipped cases.
if [[ "$*" == *"--jq"* ]]; then
    printf 'open\n'
    exit 0
fi
printf '[]\n'
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
# fleet-ops#142/#508: if pick-seat consults live unit counts, this poison stub
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

# Two subscription seats so after the no-op seat is benched, pick-seat
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
cat >"$scratch/seatlib.sh" <<EOF
# shellcheck shell=bash
source "$repo_root/lib/litellm-seat.sh"
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
export PI_PACKET_SEAT_LIB="$scratch/seatlib.sh"

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
# EMPTY_RUN_BACKOFF_S = 15 min, fleet-ops#2343) so pick-seat skips it on the
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

# P3b: empty_run cooldown lives in the proxy. Wrappers still call the stub.
shopt -s nullglob
_noop_ledgers=("$LEDGER"/*.json)
(( ${#_noop_ledgers[@]} == 0 )) \
  || fail "P3b must not write local routing ledgers, got: ${_noop_ledgers[*]}"
ok "P3b: no local empty_run ledger after provider no-op (proxy cooldown owns routing)"

ok "pi-issue-run provider no-op exits 1 and logs mark_seat_empty_run; systemd re-seats the LiteLLM group"

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

shopt -s nullglob
_er_ledgers=("$LEDGER"/*.json)
(( ${#_er_ledgers[@]} == 0 )) \
  || fail "P3b must not write local routing ledgers after empty-run, got: ${_er_ledgers[*]}"
ok "P3b: no local empty_run ledger (proxy cooldown owns routing)"

ok "empty-run (tools=0 + no final text) fails loudly and logs mark_seat_empty_run"

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

# First LiteLLM group call no-ops (0B); the in-process retry succeeds.
# P3b has one group (worker-cheap); the proxy may land on a different backend.
: >"$scratch/pi-calls"
cat >"$stub_bin/pi" <<STUB
#!/usr/bin/env bash
nfile="$scratch/pi-calls"
n=\$(cat "\$nfile" 2>/dev/null || echo 0)
n=\$((n + 1))
printf '%s\n' "\$n" >"\$nfile"
if [[ "\$n" -eq 1 ]]; then
    exit 0
fi
printf 'Real output: fixed the issue, opened PR #9999.\n'
exit 0
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

# fleet-ops#1298: the first no-op group is logged via mark_seat_empty_run.
# P3b: that group is litellm/worker-cheap, not a per-model pick-seat row.
if grep -qF 'litellm/worker-cheap' "$scratch/mark_calls" 2>/dev/null; then
    fail "first no-op group must use mark_seat_empty_run, not mark_seat_spawn_fail (calls: $(cat "$scratch/mark_calls"))"
fi
grep -qF 'litellm/worker-cheap' "$scratch/mark_empty_calls" 2>/dev/null \
  || fail "first no-op group must log mark_seat_empty_run; empty calls: $(cat "$scratch/mark_empty_calls" 2>/dev/null || true)"
ok "first no-op group logged via mark_seat_empty_run (proxy cooldown owns skip)"

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

# =============================================================================
# fleet-ops#3714 + #3810: a session that made tool calls but ended its turn ON
# a tool call (no trailing assistant text) leaves stdout at 0B while the verdict
# on stderr says tools=N class=worked. Live 2026-09-05T22:14Z fleet-ops-3268 on
# ollama/deepseek-v4-flash:0731: 14 tool calls, 44k tokens, stderr
# "PACKET-VERDICT tools=35 class=worked", stdout=0B. #3714 ruled this is NOT a
# provider no-op (the seat functioned, tools>0) so the seat is NOT benched.
# #3810: but a worked-no-text session that did NOT ship a PR is a BURNED CLAIM,
# not a success. 16 such runs in 2h on ollama/deepseek-v4-flash:0731 each
# burned a claim silently (exit 0, no re-queue). Fix: exit 1 (fail loudly,
# death_class=work) so systemd Restart re-queues on a different seat. The seat
# is NOT benched. A worked-no-text session that DID ship (PR open or issue
# closed) stays exit 0 (real success).
# =============================================================================
rm -f "$LEDGER"/*.json "$LEDGER"/*.spawn-bench.json 2>/dev/null || true
rm -f "$scratch/mark_calls" "$scratch/mark_empty_calls" 2>/dev/null || true
export EMPTY_RUN_RETRY_MAX=0

no_empty_run_ledger() {
    local f
    for f in "$LEDGER"/*.json; do
        [[ -f "$f" ]] || continue
        if [[ "$(jq -r '.failure_mode // empty' "$f" 2>/dev/null)" == "empty_run" ]]; then
            return 1
        fi
    done
    return 0
}

# (a) verdict on stderr, nothing on stdout, no PR shipped -> exit 1, seat NOT benched.
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
printf 'EXTLOAD-OK extension=packet-verdict mode=print-safe\nPACKET-VERDICT tools=35 class=worked\n' >&2
exit 0
STUB
chmod +x "$stub_bin/pi"

inst5="fleet-ops-3714-verdict"
printf 'Implement one GitHub issue: fleet-ops#3714.\nTARGET: repo Nishfleet/fleet-ops issue 3714 unit pi-issue-fleet-ops-3714\n' >"$ISSUES_DIR/${inst5}.in"
set +e
bash "$bin" "$inst5" >"$scratch/run5.out" 2>"$scratch/run5.err"
rc5=$?
set -e
[[ "$rc5" == "1" ]] \
  || fail "worked-no-text (stderr verdict tools=35, stdout 0B, no PR) must exit 1, got rc=$rc5 err=$(tail -n 5 "$scratch/run5.err")"
if [[ -s "$scratch/mark_empty_calls" ]]; then
    fail "worked-no-text must NOT bench the seat via mark_seat_empty_run; calls: $(cat "$scratch/mark_empty_calls")"
fi
no_empty_run_ledger || fail "worked-no-text must write no empty_run ledger: $(ls "$LEDGER")"
grep -qF 'worked-no-text' "$scratch/run5.err" \
  || fail "expected a worked-no-text log line, got: $(tail -n 5 "$scratch/run5.err")"
grep -qF 'failing claim loudly' "$scratch/run5.err" \
  || fail "expected a 'failing claim loudly' log line, got: $(tail -n 5 "$scratch/run5.err")"
ok "fleet-ops#3714 (a): stderr verdict tools=35 + stdout 0B + no PR -> exit 1, seat not benched"

# (b) no verdict line at all; only the session jsonl carries toolCall entries, no PR -> exit 1.
rm -f "$scratch/mark_calls" "$scratch/mark_empty_calls" 2>/dev/null || true
inst6="fleet-ops-3714-jsonl"
sess6="$HOME/.pi/agent/sessions/pi-issue-${inst6}"
cat >"$stub_bin/pi" <<STUB
#!/usr/bin/env bash
mkdir -p "$sess6"
printf '%s\n' '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"true"}}],"stopReason":"toolUse"}}' >"$sess6/2026-09-05T22-14-18-067Z_test.jsonl"
exit 0
STUB
chmod +x "$stub_bin/pi"
printf 'Implement one GitHub issue: fleet-ops#3714.\nTARGET: repo Nishfleet/fleet-ops issue 3714 unit pi-issue-fleet-ops-3714\n' >"$ISSUES_DIR/${inst6}.in"
set +e
bash "$bin" "$inst6" >"$scratch/run6.out" 2>"$scratch/run6.err"
rc6=$?
set -e
[[ "$rc6" == "1" ]] \
  || fail "worked-no-text (session jsonl toolCall, no verdict, stdout 0B, no PR) must exit 1, got rc=$rc6 err=$(tail -n 5 "$scratch/run6.err")"
if [[ -s "$scratch/mark_empty_calls" ]]; then
    fail "session-jsonl tool calls must NOT bench the seat; calls: $(cat "$scratch/mark_empty_calls")"
fi
no_empty_run_ledger || fail "session-jsonl tool calls must write no empty_run ledger: $(ls "$LEDGER")"
ok "fleet-ops#3714 (b): session jsonl toolCall + no verdict + stdout 0B + no PR -> exit 1, seat not benched"

# (c) control: 0B stdout, no verdict, no tool calls anywhere is STILL a provider no-op.
rm -f "$scratch/mark_calls" "$scratch/mark_empty_calls" 2>/dev/null || true
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/pi"
inst7="fleet-ops-3714-noop"
printf 'Implement one GitHub issue: fleet-ops#3714.\nTARGET: repo Nishfleet/fleet-ops issue 3714 unit pi-issue-fleet-ops-3714\n' >"$ISSUES_DIR/${inst7}.in"
set +e
bash "$bin" "$inst7" >"$scratch/run7.out" 2>"$scratch/run7.err"
rc7=$?
set -e
[[ "$rc7" == "1" ]] \
  || fail "true no-op (0B, no verdict, no tool calls) must still exit 1, got rc=$rc7"
[[ -s "$scratch/mark_empty_calls" ]] \
  || fail "true no-op must still bench the seat via mark_seat_empty_run"
ok "fleet-ops#3714 (c): true no-op still benched (detector not loosened)"

# (d) worked-no-text WITH a PR shipped -> exit 0 (real success, #3810).
rm -f "$scratch/mark_calls" "$scratch/mark_empty_calls" 2>/dev/null || true
cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
# PR is open for this case.
if [[ "$*" == *"--jq"* ]]; then
    printf 'open\n'
    exit 0
fi
printf '[{"number":42,"state":"open"}]\n'
exit 0
STUB
chmod +x "$stub_bin/gh"
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
printf 'EXTLOAD-OK extension=packet-verdict mode=print-safe\nPACKET-VERDICT tools=35 class=worked\n' >&2
exit 0
STUB
chmod +x "$stub_bin/pi"
inst8="fleet-ops-3810-shipped"
printf 'Implement one GitHub issue: fleet-ops#3810.\nTARGET: repo Nishfleet/fleet-ops issue 3810 unit pi-issue-fleet-ops-3810\n' >"$ISSUES_DIR/${inst8}.in"
set +e
bash "$bin" "$inst8" >"$scratch/run8.out" 2>"$scratch/run8.err"
rc8=$?
set -e
[[ "$rc8" == "0" ]]   || fail "worked-no-text WITH PR shipped must exit 0, got rc=$rc8 err=$(tail -n 5 "$scratch/run8.err")"
if [[ -s "$scratch/mark_empty_calls" ]]; then
    fail "worked-no-text with PR shipped must NOT bench the seat; calls: $(cat "$scratch/mark_empty_calls")"
fi
grep -qF 'PR shipped or issue closed' "$scratch/run8.err"   || fail "expected a 'PR shipped or issue closed' log line, got: $(tail -n 5 "$scratch/run8.err")"
ok "fleet-ops#3810 (d): worked-no-text + PR shipped -> exit 0, seat not benched"

# Restore default gh stub for any subsequent test sections.
cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"--jq"* ]]; then
    printf 'open\n'
    exit 0
fi
printf '[]\n'
exit 0
STUB
chmod +x "$stub_bin/gh"

ok "fleet-ops#3714/#3810: worked-no-text is not a provider no-op; no-PR fails loudly, PR-shipped succeeds; true no-op still benches"

# =============================================================================
# fleet-ops#3847: a SINGLE worked-no-text run (tools>0, 0B stdout) is not proof
# of a broken seat, but N consecutive ones is. Live 2026-09-06:
# ollama/deepseek-v4-flash:0731 produced 0B final text on 5/5 runs in 2h
# (fleet-ops-3714, 0509-1731, fleet-ops-3727, fleet-ops-3322, fleet-ops-3730;
# 197 tool calls, zero deliverables), each classified worked-no-text and never
# benched. Once a seat hits WORKED_NO_TEXT_THRESHOLD consecutive 0B-stdout
# worked-no-text runs, it is benched via mark_seat_empty_run and re-seated.
#
# NOTE (fleet-ops#3810, merged on main): a worked-no-text run with NO PR
# shipped now exits 1 loudly regardless of threshold. So every run below
# exits 1 (loud fail) AND must NOT bench; the bench fires only at the
# threshold. The exit code is therefore not the discriminator — the bench
# (mark_seat_empty_run) and the counter are.
# =============================================================================
export WORKED_NO_TEXT_THRESHOLD=3
rm -f "$scratch/mark_calls" "$scratch/mark_empty_calls" 2>/dev/null || true
rm -f "$LEDGER"/*.worked-no-text.json 2>/dev/null || true
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
printf 'EXTLOAD-OK extension=packet-verdict mode=print-safe\nPACKET-VERDICT tools=12 class=worked\n' >&2
exit 0
STUB
chmod +x "$stub_bin/pi"

for i in 1 2 3; do
    inst9="fleet-ops-3847-wnt-$i"
    printf 'Implement one GitHub issue: fleet-ops#3847.\nTARGET: repo Nishfleet/fleet-ops issue 3847 unit pi-issue-fleet-ops-3847\n' >"$ISSUES_DIR/${inst9}.in"
    set +e
    bash "$bin" "$inst9" >"$scratch/run9-$i.out" 2>"$scratch/run9-$i.err"
    rc=$?
    set -e
    [[ "$rc" == "1" ]] \
      || fail "worked-no-text run #$i (no PR) must exit 1 per #3810, got rc=$rc err=$(tail -n 5 "$scratch/run9-$i.err")"
    grep -qF 'failing claim loudly' "$scratch/run9-$i.err" \
      || fail "worked-no-text run #$i must loud-fail, got: $(tail -n 3 "$scratch/run9-$i.err")"
done
if [[ -s "$scratch/mark_empty_calls" ]]; then
    fail "P3b: worked-no-text must not local-bench; empty calls: $(cat "$scratch/mark_empty_calls")"
fi
shopt -s nullglob
_wnt_ledgers=("$LEDGER"/*.json "$LEDGER"/*.worked-no-text.json)
(( ${#_wnt_ledgers[@]} == 0 )) \
  || fail "P3b must not write local worked-no-text ledgers, got: ${_wnt_ledgers[*]}"
ok "fleet-ops#3847: consecutive worked-no-text loud-fails; no local counter or bench (proxy cooldown owns skip)"
