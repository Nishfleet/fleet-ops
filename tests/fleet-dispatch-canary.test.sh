#!/usr/bin/env bash
# tests/fleet-dispatch-canary.test.sh
#
# Proves the packet dispatch ledger completion invariant (fleet-ops#1009):
# every pi-systemd-run dispatch is a canary-tracked chain.
#
# Hermetic (no user systemd, no real pi, no real seat-lib). Mocks:
#   - systemctl: per-unit is-active / Result / ExecMainStatus via a store dir
#   - journalctl: per-unit journal content via a store dir
#   - pi-systemd-run: a stub that records the re-dispatch and appends a new
#     ledger entry (so the chain grows exactly like the real bin)
#   - seat-lib: stubbed via FLEET_DISPATCH_CANARY_SEAT_MODE
#
# What we prove:
#   1. No ledger / no open entries -> exit 0 (clean).
#   2. In-flight unit (active) -> exit 0, entry stays open.
#   3. Completed unit (Result=success) -> closed completed/success.
#   4. Completed unit (Result=exit-code, ExecMainStatus=1) -> closed
#      completed/failed. NOT re-dispatched (its own escalation owns it).
#   5. --collect'd successful unit (Result empty, journal "Succeeded") ->
#      closed completed/success via the journal fallback.
#   6. Orphan past deadline, retries=0, packet present -> RE-DISPATCHED on a
#      fresh seat; current entry closed redispatched; new open entry appended
#      with hop=1, retries=1, same chain_id.
#   7. Orphan past deadline, retries=2 -> ESCALATED via STOP-REASON
#      (reason=dispatch-orphan); entry closed escalated; no 3rd re-dispatch.
#   8. Orphan before deadline -> waiting, exit 0, entry stays open.
#   9. Orphan with no packet file -> re-dispatch blocked -> fail-loud (exit 1)
#      when retries < 2 (the ladder above this canary owns it).
#  10. pi-systemd-run appends a ledger entry on a real (non-dry-run, non-noop)
#      dispatch and copies the packet into agent-state; dry-run does NOT.
#  11. pi-systemd-run parses provider/model from the bare command form.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
canary="$repo_root/bin/fleet-dispatch-canary.py"
psrun="$repo_root/bin/pi-systemd-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$canary" ]] || fail "fleet-dispatch-canary.py not executable: $canary"
[[ -x "$psrun" ]]  || fail "pi-systemd-run not executable: $psrun"
command -v jq >/dev/null || fail "jq required"
command -v python3 >/dev/null || fail "python3 required"

scratch="$(mktemp -d -t dispatch-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"
mkdir -p "$HOME"

AS="$scratch/agent-state"
mkdir -p "$AS"
LEDGER="$AS/dispatch-ledger.jsonl"
PKT_DIR="$AS/dispatch-packets"
STOP_REASON="$AS/STOP-REASON.json"
mkdir -p "$PKT_DIR"

# --- mock systemctl / journalctl -------------------------------------------
# Per-unit state lives in $SYSCTL_STORE/<unit>.active, .result, .exit.
# Missing file = unit not found / no value.
sysctl_store="$scratch/sysctl"
mkdir -p "$sysctl_store"
cat >"$scratch/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${SYSCTL_STORE:?}"
cmd="$1"; shift
[[ "$cmd" == "--user" ]] || exit 1
cmd="$1"; shift
case "$cmd" in
  is-active)
    unit="$1"
    if [ -f "$store/$unit.active" ]; then cat "$store/$unit.active"; else echo "inactive"; fi
    ;;
  show)
    unit=""; prop=""
    for a in "$@"; do
      case "$a" in
        --property=*) prop="${a#--property=}" ;;
        -p) prop="NEXT" ;;
        --value) ;;
        *) [ "$prop" == "NEXT" ] && prop="$a" || { [ -z "$unit" ] && unit="$a"; } ;;
      esac
    done
    case "$prop" in
      LoadState)
        # "loaded" if the unit has a .active file (real record); else "not-found".
        [ -f "$store/$unit.active" ] && echo "loaded" || echo "not-found"
        ;;
      Result)
        # Real systemctl returns "success" by default for a not-found unit;
        # only return the stored result when the unit is loaded.
        if [ -f "$store/$unit.active" ]; then
          [ -f "$store/$unit.result" ] && cat "$store/$unit.result" || echo "success"
        else
          echo "success"
        fi
        ;;
      ExecMainStatus)
        [ -f "$store/$unit.exit" ] && cat "$store/$unit.exit" || echo "0"
        ;;
      *) echo "" ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/systemctl"

# Per-unit journal content in $JRNL_STORE/<unit>.journal (empty = no journal).
jrnl_store="$scratch/jrnl"
mkdir -p "$jrnl_store"
cat >"$scratch/journalctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${JRNL_STORE:?}"
# Parse: --user -u <unit> -o cat -n 20
unit=""
while [ $# -gt 0 ]; do
  case "$1" in
    -u) unit="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -f "$store/$unit.journal" ] && cat "$store/$unit.journal" || true
FAKE
chmod +x "$scratch/journalctl"

# --- stub pi-systemd-run (records re-dispatch + appends ledger entry) -------
# Mirrors the real bin's ledger append so the chain grows identically.
PSRUN_LOG="$scratch/psrun-calls.log"
: > "$PSRUN_LOG"
export PSRUN_LOG
cat >"$scratch/pi-systemd-run" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
# Minimal flag parse mirroring the real bin's ledger-relevant flags.
unit=""; stdin_file=""; provider=""; model=""; deadline_min="90"; chain_id=""; hop="0"
while [ $# -gt 0 ]; do
  case "$1" in
    --unit) unit="$2"; shift 2 ;;
    --stdin) stdin_file="$2"; shift 2 ;;
    --provider) provider="$2"; shift 2 ;;
    --model) model="$2"; shift 2 ;;
    --deadline) deadline_min="$2"; shift 2 ;;
    --chain-id) chain_id="$2"; shift 2 ;;
    --hop) hop="$2"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
echo "call unit=$unit stdin=$stdin_file provider=$provider model=$model deadline=$deadline_min chain=$chain_id hop=$hop" >>"${PSRUN_LOG:-/dev/null}"
# Append a new ledger entry exactly like the real bin (open, hop+retries=hop).
AS="${AGENT_STATE:?}"
LEDGER="${FLEET_DISPATCH_LEDGER:-$AS/dispatch-ledger.jsonl}"
PKT_DIR="${FLEET_DISPATCH_PACKET_DIR:-$AS/dispatch-packets}"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
id="$(cat /proc/sys/kernel/random/uuid)"
[ -z "$chain_id" ] && chain_id="$id"
packet_path=""
[ -n "$stdin_file" ] && [ -f "$stdin_file" ] && packet_path="$(readlink -f "$stdin_file")"
deadline_ts="$(date -u -d "@$(( $(date -u -d "$ts" +%s) + deadline_min * 60 ))" +%Y-%m-%dT%H:%M:%SZ)"
python3 -c '
import json, sys
e={"id":sys.argv[1],"chain_id":sys.argv[2],"hop":int(sys.argv[3]),"ts":sys.argv[4],
   "unit":sys.argv[5],"packet_path":sys.argv[6],"provider":sys.argv[7],"model":sys.argv[8],
   "deadline_min":int(sys.argv[9]),"deadline_ts":sys.argv[10],"status":"open","retries":int(sys.argv[3])}
sys.stdout.write(json.dumps(e,separators=(",",":"))+"\n")
' "$id" "$chain_id" "$hop" "$ts" "$unit" "$packet_path" "$provider" "$model" "$deadline_min" "$deadline_ts" >> "$LEDGER"
exit 0
FAKE
chmod +x "$scratch/pi-systemd-run"

# --- helpers ---------------------------------------------------------------
# Append an open ledger entry. Args: unit provider model deadline_min retries hop chain_id packet_path
add_entry() {
  local unit="$1" prov="$2" mdl="$3" dmin="$4" retries="$5" hop="$6" chain="$7" packet="$8"
  local id_ ts_ dl_
  id_="$(cat /proc/sys/kernel/random/uuid)"
  ts_="2026-08-27T00:00:00Z"
  dl_="$(date -u -d "@$(( $(date -u -d "$ts_" +%s) + dmin * 60 ))" +%Y-%m-%dT%H:%M:%SZ)"
  python3 -c '
import json, sys
e={"id":sys.argv[1],"chain_id":sys.argv[2],"hop":int(sys.argv[3]),"ts":sys.argv[4],
   "unit":sys.argv[5],"packet_path":sys.argv[6],"provider":sys.argv[7],"model":sys.argv[8],
   "deadline_min":int(sys.argv[9]),"deadline_ts":sys.argv[10],"status":"open","retries":int(sys.argv[11])}
sys.stdout.write(json.dumps(e,separators=(",",":"))+"\n")
' "$id_" "$chain" "$hop" "$ts_" "$unit" "$packet" "$prov" "$mdl" "$dmin" "$dl_" "$retries" >> "$LEDGER"
  echo "$id_"
}

# Last record for an id (last line wins).
last_rec() { jq -c --arg id "$1" 'select(.id==$id)' "$LEDGER" | tail -1; }

run_canary() {
  local now="$1"
  set +e
  FLEET_DISPATCH_LEDGER="$LEDGER" \
  FLEET_DISPATCH_PACKET_DIR="$PKT_DIR" \
  FLEET_STOP_REASON="$STOP_REASON" \
  FLEET_DISPATCH_CANARY_SYSTEMCTL="$scratch/systemctl" \
  FLEET_DISPATCH_CANARY_JOURNALCTL="$scratch/journalctl" \
  FLEET_DISPATCH_CANARY_PI_SYSTEMD_RUN="$scratch/pi-systemd-run" \
  FLEET_DISPATCH_CANARY_SEAT_MODE="healthy" \
  FLEET_DISPATCH_CANARY_NOW="$now" \
  SYSCTL_STORE="$sysctl_store" JRNL_STORE="$jrnl_store" \
  AGENT_STATE="$AS" \
    "$canary" >/dev/null 2>"$scratch/canary.err"
  local rc=$?
  set -e
  echo "$rc"
}

# A real packet file for re-dispatch tests.
pkt="$scratch/packet.md"
echo "DO THE WORK" > "$pkt"
pkt_abs="$(readlink -f "$pkt")"

# ============================================================================
echo "=== 1. no ledger -> clean ==="
rm -f "$LEDGER"
rc=$(run_canary "2026-08-27T02:00:00Z")
[[ "$rc" == "0" ]] || fail "no ledger should exit 0 (got $rc)"
ok "no ledger exits 0"

# ============================================================================
echo "=== 2. in-flight unit (active) -> stays open ==="
rm -f "$LEDGER"; : > "$PSRUN_LOG"
id1=$(add_entry "unit-live" "devin" "glm-5-2" "90" "0" "0" "chain-1" "$pkt_abs")
echo "active" > "$sysctl_store/unit-live.service.active"
rc=$(run_canary "2026-08-27T02:00:00Z")
[[ "$rc" == "0" ]] || fail "in-flight should exit 0 (got $rc)"
status=$(last_rec "$id1" | jq -r .status)
[[ "$status" == "open" ]] || fail "in-flight entry should stay open (got $status)"
[[ ! -s "$PSRUN_LOG" ]] || fail "in-flight must not re-dispatch"
ok "in-flight unit stays open, no re-dispatch"

# ============================================================================
echo "=== 3. completed success (Result=success) -> closed ==="
rm -f "$LEDGER"; : > "$PSRUN_LOG"
id2=$(add_entry "unit-ok" "devin" "glm-5-2" "90" "0" "0" "chain-2" "$pkt_abs")
echo "inactive" > "$sysctl_store/unit-ok.service.active"
echo "success"  > "$sysctl_store/unit-ok.service.result"
echo "0"        > "$sysctl_store/unit-ok.service.exit"
rc=$(run_canary "2026-08-27T02:00:00Z")
[[ "$rc" == "0" ]] || fail "completed-success should exit 0 (got $rc)"
status=$(last_rec "$id2" | jq -r .status)
verdict=$(last_rec "$id2" | jq -r .verdict)
[[ "$status" == "completed" && "$verdict" == "success" ]] || fail "expected completed/success (got $status/$verdict)"
[[ ! -s "$PSRUN_LOG" ]] || fail "completed must not re-dispatch"
ok "completed success closed, no re-dispatch"

# ============================================================================
echo "=== 4. completed failed (Result=exit-code) -> closed failed, NOT re-dispatched ==="
rm -f "$LEDGER"; : > "$PSRUN_LOG"
id3=$(add_entry "unit-fail" "devin" "glm-5-2" "90" "0" "0" "chain-3" "$pkt_abs")
echo "failed"    > "$sysctl_store/unit-fail.service.active"
echo "exit-code" > "$sysctl_store/unit-fail.service.result"
echo "1"         > "$sysctl_store/unit-fail.service.exit"
rc=$(run_canary "2026-08-27T02:00:00Z")
[[ "$rc" == "0" ]] || fail "completed-failed should exit 0 (got $rc)"
status=$(last_rec "$id3" | jq -r .status)
verdict=$(last_rec "$id3" | jq -r .verdict)
[[ "$status" == "completed" && "$verdict" == "failed" ]] || fail "expected completed/failed (got $status/$verdict)"
[[ ! -s "$PSRUN_LOG" ]] || fail "completed-failed must NOT re-dispatch (own escalation owns it)"
ok "completed failed closed, not re-dispatched"

# ============================================================================
echo "=== 5. --collect'd success (Result empty, journal Succeeded) -> closed via journal ==="
rm -f "$LEDGER"; : > "$PSRUN_LOG"
id4=$(add_entry "unit-collect" "devin" "glm-5-2" "90" "0" "0" "chain-4" "$pkt_abs")
# --collect unloads the unit: no .active file (LoadState=not-found), Result=success
# (default), no exit file. The journal still holds the terminal verdict.
echo "Succeeded." > "$jrnl_store/unit-collect.service.journal"
rc=$(run_canary "2026-08-27T02:00:00Z")
[[ "$rc" == "0" ]] || fail "collect-success should exit 0 (got $rc)"
status=$(last_rec "$id4" | jq -r .status)
verdict=$(last_rec "$id4" | jq -r .verdict)
[[ "$status" == "completed" && "$verdict" == "success" ]] || fail "expected completed/success via journal (got $status/$verdict)"
ok "--collect'd success closed via journal fallback"

# ============================================================================
echo "=== 5b. not-found unit (Result=success default, no journal) past deadline -> ORPHAN, not closed ==="
# Regression guard (fleet-ops#1009): real systemctl returns Result="success"
# for a non-existent unit (the property default). Without a LoadState=loaded
# check the canary would falsely close every orphan as completed/success and
# never re-dispatch. This entry has no .active file (LoadState=not-found) and
# no journal, so it MUST be re-dispatched, not closed.
rm -f "$LEDGER"; : > "$PSRUN_LOG"; rm -f "$STOP_REASON"
id4b=$(add_entry "unit-gone" "devin" "glm-5-2" "90" "0" "0" "chain-4b" "$pkt_abs")
# No .active file -> LoadState=not-found, Result=success (default), no journal.
rc=$(run_canary "2026-08-27T02:00:00Z")
[[ "$rc" == "0" ]] || fail "not-found orphan should re-dispatch and exit 0 (got $rc)"
status=$(last_rec "$id4b" | jq -r .status)
[[ "$status" == "redispatched" ]] || fail "not-found orphan should be redispatched, not closed (got $status)"
calls=$(wc -l < "$PSRUN_LOG" | tr -d ' ')
[[ "$calls" == "1" ]] || fail "not-found orphan should trigger 1 re-dispatch (got $calls)"
ok "not-found unit (Result=success default) past deadline -> re-dispatched, NOT falsely closed"

# ============================================================================
echo "=== 6. orphan past deadline, retries=0 -> RE-DISPATCHED, chain grows ==="
rm -f "$LEDGER"; : > "$PSRUN_LOG"; rm -f "$STOP_REASON"
id5=$(add_entry "unit-orphan" "devin" "glm-5-2" "90" "0" "0" "chain-5" "$pkt_abs")
# Unit gone: no .active file (LoadState=not-found), no .result, no journal.
# This is the true orphan shape: unit never existed or was --collect'd.
# 2h after dispatch ts (2026-08-27T00:00:00Z) -> past 90min deadline.
rc=$(run_canary "2026-08-27T02:00:00Z")
[[ "$rc" == "0" ]] || fail "orphan re-dispatch should exit 0 (got $rc)"
status=$(last_rec "$id5" | jq -r .status)
[[ "$status" == "redispatched" ]] || fail "orphan should be closed redispatched (got $status)"
# The stub pi-systemd-run was called once and appended a new open entry.
calls=$(wc -l < "$PSRUN_LOG" | tr -d ' ')
[[ "$calls" == "1" ]] || fail "expected 1 re-dispatch call (got $calls)"
# New entry: hop=1, retries=1, same chain_id, status=open.
new_open=$(jq -c 'select(.status=="open" and .chain_id=="chain-5")' "$LEDGER" | tail -1)
[[ -n "$new_open" ]] || fail "new open entry for chain-5 must exist"
new_hop=$(echo "$new_open" | jq -r .hop)
new_retries=$(echo "$new_open" | jq -r .retries)
[[ "$new_hop" == "1" && "$new_retries" == "1" ]] || fail "new entry hop/retries should be 1 (got $new_hop/$new_retries)"
new_unit=$(echo "$new_open" | jq -r .unit)
[[ "$new_unit" == "unit-orphan-r1" ]] || fail "new unit should be unit-orphan-r1 (got $new_unit)"
# STOP-REASON must NOT have been written (re-dispatch succeeded).
[[ ! -f "$STOP_REASON" ]] || fail "STOP-REASON must not be written on a successful re-dispatch"
ok "orphan re-dispatched on fresh seat, chain grows (hop=1), no escalation"

# ============================================================================
echo "=== 7. orphan past deadline, retries=2 -> ESCALATED via STOP-REASON ==="
rm -f "$LEDGER"; : > "$PSRUN_LOG"; rm -f "$STOP_REASON"
id6=$(add_entry "unit-orphan2" "devin" "glm-5-2" "90" "2" "2" "chain-6" "$pkt_abs")
# Unit gone: no .active file (LoadState=not-found), no journal (orphan).
rc=$(run_canary "2026-08-27T02:00:00Z")
[[ "$rc" == "0" ]] || fail "escalate should exit 0 (got $rc)"
status=$(last_rec "$id6" | jq -r .status)
[[ "$status" == "escalated" ]] || fail "orphan retries=2 should be closed escalated (got $status)"
# No 3rd re-dispatch.
[[ ! -s "$PSRUN_LOG" ]] || fail "retries=2 must NOT re-dispatch a 3rd time"
# STOP-REASON written with reason=dispatch-orphan.
[[ -f "$STOP_REASON" ]] || fail "STOP-REASON must be written on escalation"
reason=$(jq -r .reason "$STOP_REASON")
detail_chain=$(jq -r .detail.chain_id "$STOP_REASON")
detail_retries=$(jq -r .detail.retries "$STOP_REASON")
[[ "$reason" == "dispatch-orphan" ]] || fail "STOP-REASON reason should be dispatch-orphan (got $reason)"
[[ "$detail_chain" == "chain-6" ]] || fail "STOP-REASON detail.chain_id should be chain-6 (got $detail_chain)"
[[ "$detail_retries" == "2" ]] || fail "STOP-REASON detail.retries should be 2 (got $detail_retries)"
ok "orphan retries=2 escalated via STOP-REASON (senior conference), no 3rd re-dispatch"

# ============================================================================
echo "=== 8. orphan BEFORE deadline -> waiting, stays open ==="
rm -f "$LEDGER"; : > "$PSRUN_LOG"
id7=$(add_entry "unit-early" "devin" "glm-5-2" "90" "0" "0" "chain-7" "$pkt_abs")
# Unit gone: no .active file (LoadState=not-found), no journal (orphan).
# 30min after dispatch -> before 90min deadline.
rc=$(run_canary "2026-08-27T00:30:00Z")
[[ "$rc" == "0" ]] || fail "before-deadline should exit 0 (got $rc)"
status=$(last_rec "$id7" | jq -r .status)
[[ "$status" == "open" ]] || fail "before-deadline should stay open (got $status)"
[[ ! -s "$PSRUN_LOG" ]] || fail "before-deadline must not re-dispatch"
ok "orphan before deadline stays open (waiting)"

# ============================================================================
echo "=== 9. orphan no packet file, retries<2 -> fail-loud (exit 1) ==="
rm -f "$LEDGER"; : > "$PSRUN_LOG"; rm -f "$STOP_REASON"
add_entry "unit-nopkt" "devin" "glm-5-2" "90" "0" "0" "chain-8" "" >/dev/null
# Unit gone: no .active file (LoadState=not-found), no journal (orphan).
rc=$(run_canary "2026-08-27T02:00:00Z")
[[ "$rc" == "1" ]] || fail "orphan no-packet retries<2 should fail-loud exit 1 (got $rc)"
ok "orphan no-packet fail-loud (ladder above owns it)"

# ============================================================================
echo "=== 10. pi-systemd-run appends ledger entry + copies packet on real dispatch ==="
rm -f "$LEDGER"
# Use the stubbed systemctl/systemd-run so the real bin's dispatch path runs
# without touching real systemd.
fake_bin="$scratch/fake-systemd-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$2" in
  is-active) echo "inactive" ;;
  show) echo "0" ;;
  *) exit 0 ;;
esac
FAKE
cat >"$fake_bin/systemd-run" <<'FAKE'
#!/usr/bin/env bash
echo "systemd-run invoked" >&2
exit 0
FAKE
chmod +x "$fake_bin/systemctl" "$fake_bin/systemd-run"
src_pkt="$scratch/src-packet.md"
echo "WORK PACKET BODY" > "$src_pkt"
SYSTEMCTL="$fake_bin/systemctl" SYSTEMD_RUN="$fake_bin/systemd-run" \
  AGENT_STATE="$AS" FLEET_DISPATCH_LEDGER="$LEDGER" FLEET_DISPATCH_PACKET_DIR="$PKT_DIR" \
  "$psrun" --unit test-dispatch --stdin "$src_pkt" --deadline 30 \
  --provider devin --model glm-5-2 -- pi --print --provider devin --model glm-5-2 \
    >"$scratch/psrun.out" 2>"$scratch/psrun.err"
# Ledger has exactly one open entry.
lines=$(wc -l < "$LEDGER" | tr -d ' ')
[[ "$lines" == "1" ]] || fail "real dispatch should append 1 ledger entry (got $lines)"
rec=$(cat "$LEDGER")
[[ "$(echo "$rec" | jq -r .status)" == "open" ]] || fail "entry status should be open"
[[ "$(echo "$rec" | jq -r .unit)" == "test-dispatch" ]] || fail "entry unit should be test-dispatch"
[[ "$(echo "$rec" | jq -r .provider)" == "devin" ]] || fail "entry provider should be devin"
[[ "$(echo "$rec" | jq -r .model)" == "glm-5-2" ]] || fail "entry model should be glm-5-2"
[[ "$(echo "$rec" | jq -r .deadline_min)" == "30" ]] || fail "entry deadline_min should be 30"
copied=$(echo "$rec" | jq -r .packet_path)
[[ -n "$copied" && -f "$copied" ]] || fail "packet should be copied into agent-state (path=$copied)"
[[ "$(cat "$copied")" == "WORK PACKET BODY" ]] || fail "copied packet content should match source"
ok "real dispatch appends ledger entry + copies packet into agent-state"

# dry-run must NOT append a ledger entry.
before=$(wc -l < "$LEDGER" | tr -d ' ')
SYSTEMCTL="$fake_bin/systemctl" SYSTEMD_RUN="$fake_bin/systemd-run" \
  AGENT_STATE="$AS" FLEET_DISPATCH_LEDGER="$LEDGER" FLEET_DISPATCH_PACKET_DIR="$PKT_DIR" \
  "$psrun" --dry-run --unit test-dry --stdin "$src_pkt" -- pi --print --provider devin --model glm-5-2 \
    >/dev/null 2>&1
after=$(wc -l < "$LEDGER" | tr -d ' ')
[[ "$before" == "$after" ]] || fail "dry-run must NOT append a ledger entry (before=$before after=$after)"
ok "dry-run does NOT append a ledger entry"

# ============================================================================
echo "=== 11. pi-systemd-run parses provider/model from the bare command form ==="
rm -f "$LEDGER"
SYSTEMCTL="$fake_bin/systemctl" SYSTEMD_RUN="$fake_bin/systemd-run" \
  AGENT_STATE="$AS" FLEET_DISPATCH_LEDGER="$LEDGER" FLEET_DISPATCH_PACKET_DIR="$PKT_DIR" \
  "$psrun" --unit test-parse --stdin "$src_pkt" --deadline 90 \
  -- pi --print --provider minimax --model MiniMax-M3 \
    >"$scratch/psrun2.out" 2>"$scratch/psrun2.err"
rec=$(cat "$LEDGER")
[[ "$(echo "$rec" | jq -r .provider)" == "minimax" ]] || fail "parsed provider should be minimax (got $(echo "$rec" | jq -r .provider))"
[[ "$(echo "$rec" | jq -r .model)" == "MiniMax-M3" ]] || fail "parsed model should be MiniMax-M3 (got $(echo "$rec" | jq -r .model))"
ok "bare command form parses provider/model into the ledger"

# ============================================================================
echo "=== 12. wiring pins (fleet-ops#1009) ==="
# The canary is only "enforced" if heartbeat actually runs it, MANIFEST
# installs it once, and the CI-listed canary runner keeps invoking this
# suite (worker tokens cannot push workflows).
tier1="$repo_root/bin/fleet-heartbeat-tier1"
grep -F 'fleet-dispatch-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-dispatch-canary"
grep -F 'dispatch_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture dispatch_canary_rc"
grep -F -- 'exit "${dispatch_canary_rc}"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the dispatch canary fails loud"
n=$(grep -cF 'bin/fleet-dispatch-canary.py ' "$repo_root/MANIFEST" || true)
[[ "$n" == "1" ]] || fail "MANIFEST must list fleet-dispatch-canary.py exactly once (got $n)"
grep -F 'fleet-dispatch-canary.test.sh' "$here/escalation-coverage-canary.test.sh" >/dev/null \
  || fail "escalation-coverage-canary.test.sh must invoke this suite (fleet-ops#1009)"
grep -F 'fleet-dispatch-canary' "$repo_root/bin/fleet-escalation-canary" >/dev/null \
  || fail "fleet-escalation-canary SANCTIONED_PI_RUNNERS must include fleet-dispatch-canary"
ok "wiring: heartbeat fail-loud, MANIFEST once, nested canary runner, sanctioned pi runner"

echo
echo "ALL fleet-dispatch-canary.py tests passed"
