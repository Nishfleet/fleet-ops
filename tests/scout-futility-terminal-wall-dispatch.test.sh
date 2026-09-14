#!/usr/bin/env bash
# tests/scout-futility-terminal-wall-dispatch.test.sh
#
# fleet-ops#6577: a provider wall that kills BOTH scout hops used to end the
# chain with two failed units and no dispatch. Live 2026-09-14T04:15Z:
# pi-scout@0509 died on `Connection error.` (wall-crash #1 per
# scout-futility-check); OnFailure fired pi-scout-repair@0509, which died on
# the SAME wall 11s later with `PACKET-VERDICT tools=0 class=no-tools` — and
# nothing observed the chain-terminal exit (the repair template carried no
# ExecStopPost at all), so no issue was dispatched and the next scout cycle
# was ~4h away.
#
# This test proves the fix end to end on the existing rails, offline:
#   1. Unit wiring: pi-scout-repair@.service carries the dash-prefixed
#      ExecStopPost end-repair hook; systemd-analyze verify accepts it.
#   2. Repair terminal wall (exit 1 + wall-class journal, the live shape)
#      -> end-repair emits ONE LOUD SCOUT-WALL-CHAIN-DEAD triage line
#      carrying BOTH hops' unit names and journal lines, with the
#      per-repo signal key.
#   3. The real detector->queue reconciler (fleet-ops#362 — the rail that
#      filed alarms #6555-#6559) turns that line into exactly ONE
#      `alarm: SCOUT-WALL-CHAIN-DEAD` issue.
#   4. Second wall while the alarm is open -> NO duplicate issue; the
#      reconciler re-observes via heartbeat comment (deduped per
#      wall-storm, fleet-ops#6577 acceptance).
#   5. The scout hop's OWN terminal wall does NOT emit the chain-dead
#      signal — only the chain-terminal repair exit files.
#   6. Repair exit 0 (chain completed) and seat-skip 75 (never started)
#      never alarm.
#
# The reconciler is exercised through the REAL lib with read-only fakes
# (same hermetic shape as bin/chain-e2e-drill); nothing here re-implements
# a hop.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/scout-futility-check"
repair_unit="$repo_root/systemd/pi-scout-repair@.service"
reconciler="$repo_root/lib/detector-queue-reconciler.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
bash -n "$bin" || fail "scout-futility-check: bash syntax error"
[[ -f "$repair_unit" ]] || fail "missing: $repair_unit"
[[ -f "$reconciler" ]] || fail "missing: $reconciler"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# --- 1. wiring --------------------------------------------------------------
grep -q "ExecStopPost=-/bin/bash -c 'exec /home/nish/.local/bin/scout-futility-check end-repair %i'" "$repair_unit" \
  || fail "pi-scout-repair@.service must ExecStopPost=- scout-futility-check end-repair (fleet-ops#6577)"
grep -q "pi-scout-run %i scout-repair" "$repair_unit" \
  || fail "pi-scout-repair@.service ExecStart must still invoke pi-scout-run"
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify --man=no "$repair_unit" >/dev/null 2>&1 \
    || fail "systemd-analyze verify failed for pi-scout-repair@.service"
  ok "wiring: repair template hooks ExecStopPost end-repair; systemd-analyze verify passes"
else
  ok "wiring: repair template hooks ExecStopPost end-repair (systemd-analyze not on PATH, skipped)"
fi

# --- scratch environment ----------------------------------------------------
scratch="$(mktemp -d -t scout-wall-chain.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
state="$scratch/state"
mkdir -p "$state"
triage="$scratch/triage.md"
: >"$triage"

export SCOUT_FUTILITY_STATE_DIR="$state"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export SCOUT_FUTILITY_N=3
export SCOUT_FUTILITY_BUFFER=12
export SCOUT_FUTILITY_REPO="Nishfleet/fleet-ops"
export SCOUT_FUTILITY_FILE=1
export SCOUT_FUTILITY_READY_COUNT=2
export SCOUT_FUTILITY_PROM="$scratch/fleet-scout.prom"
export SCOUT_FUTILITY_GATE_OPEN=0
export WORK_SUPPLY_CLAIMED_COUNT=0

# journalctl stub keyed on the UNIT name: pi-scout-repair@* gets the repair
# hop's journal (the live 2026-09-14T04:15:16Z lines), pi-scout@* gets the
# scout hop's (the live 04:15:02Z lines). --since/-n/-o are accepted and
# ignored; bodies come from per-unit files so the two hops never share
# evidence.
mkdir -p "$scratch/bin"
cat >"$scratch/bin/journalctl" <<'EOFSTUB'
#!/usr/bin/env bash
unit=""
for a in "$@"; do
    case "$a" in
        *@*.service) unit="$a" ;;
    esac
done
case "$unit" in
    pi-scout-repair@*) cat "${JOURNALCTL_REPAIR_BODY:?}" ;;
    pi-scout@*)        cat "${JOURNALCTL_SCOUT_BODY:?}" ;;
    *) exit 0 ;;
esac
EOFSTUB
chmod +x "$scratch/bin/journalctl"
export JOURNALCTL="$scratch/bin/journalctl"

# fleet-ops#6163: scout-futility-check's #3445 fail-closed mint header runs
# BEFORE its always-exit-0 trap is armed. With no inherited GH_TOKEN it
# execs $HOME/.local/bin/worker-token — a file the scratch HOME above can
# never hold — so every bin call exited 1 in token-less contexts (the
# 2026-09-14 orchestrator-sweep red on main: "worker-token: No such file or
# directory" -> end-repair exit 1) while worker envs (GH_TOKEN set) skipped
# the mint and passed. The header deliberately skips minting when GH names
# a stub (its own comment: tests stub gh read-only), so export the
# documented seam: every "$GH" call inside the bin is already `|| true`
# guarded and the paths this test drives need no gh data — a dead-stub gh
# keeps the sandbox fully off the network in every ambient env. Same shape
# as tests/scout-futility.test.sh's $gh_fake for the same binary. The
# reconciler calls below still pass GH=$gh_mock explicitly, overriding this
# for the hops that need real issue/view + issue/comment behaviour.
cat >"$scratch/bin/gh" <<'EOFSTUB'
#!/usr/bin/env bash
# fleet-ops#6163 hermetic gh: any call exits 0 with empty output. Every
# "$GH" call site in scout-futility-check is `|| true`-guarded and treats
# empty as unknown, so no exercised path can silently read live state.
exit 0
EOFSTUB
chmod +x "$scratch/bin/gh"
export GH="$scratch/bin/gh"

# The live incident shapes (evidence lines quoted in issue #6577).
repair_body="$scratch/repair-journal.txt"
scout_body="$scratch/scout-journal.txt"
cat >"$repair_body" <<'EOF'
[pi-seated-err] EXTLOAD-OK extension=seat-health source=after_provider_response
[pi-seated-err] EXTLOAD-OK extension=stop-judge mode=print-safe
[pi-seated-err] EXTLOAD-OK extension=subagent mode=print-safe
[pi-seated-err] Connection error.
[pi-seated-err] PACKET-VERDICT tools=0 class=no-tools
EOF
cat >"$scout_body" <<'EOF'
[pi-seated-err] EXTLOAD-OK extension=stop-judge mode=print-safe
[pi-seated-err] Connection error.
[pi-seated-err] PACKET-VERDICT class=worked
EOF
export JOURNALCTL_REPAIR_BODY="$repair_body"
export JOURNALCTL_SCOUT_BODY="$scout_body"

last_line() {
    grep '\[' "$triage" 2>/dev/null | tail -n 1 || true
}

chain_dead_lines() {
    grep -c 'SCOUT-WALL-CHAIN-DEAD' "$triage" 2>/dev/null || true
}

# Seed the per-repo state the way the live chain leaves it: the scout's
# cmd_begin wrote last_run_epoch (this cycle's begin), cmd_end cleared
# begin_at, and the repair hop runs seconds after the scout's death.
seed_state() {
    local epoch
    epoch=$(($(date -u +%s) - 60))
    cat >"$state/0509.state" <<EOF
# scout-futility state
before=2
before_hours=
begin_at=
consecutive_dry=0
consecutive_wall=0
last_run_epoch=${epoch}
EOF
}

# --- 2. repair terminal wall -> ONE LOUD line -------------------------------
seed_state
set +e
"$bin" end-repair 0509 1 >/dev/null 2>"$scratch/endrepair-a.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "end-repair must always exit 0, got $rc ($(cat "$scratch/endrepair-a.log"))"
[[ "$(chain_dead_lines)" == "1" ]] || fail "exactly one SCOUT-WALL-CHAIN-DEAD line expected, got $(chain_dead_lines)"
line="$(last_line)"
case "$line" in
  *'signal: scout-wall-chain-dead/0509'*) : ;;
  *) fail "LOUD line must carry the per-repo signal key, got: $line" ;;
esac
case "$line" in
  *'pi-scout@0509.service'*) : ;;
  *) fail "LOUD line must name the scout hop unit, got: $line" ;;
esac
case "$line" in
  *'pi-scout-repair@0509.service'*) : ;;
  *) fail "LOUD line must name the repair hop unit, got: $line" ;;
esac
case "$line" in
  *'Connection error'*) : ;;
  *) fail "LOUD line must carry both hops' journal lines (Connection error), got: $line" ;;
esac
case "$line" in
  *'PACKET-VERDICT tools=0 class=no-tools'*) : ;;
  *) fail "LOUD line must carry the repair hop's no-tools verdict, got: $line" ;;
esac
ok "repair terminal wall: one LOUD SCOUT-WALL-CHAIN-DEAD line with signal key, both units, both hops' journal lines"

# --- 3. the reconciler files exactly ONE alarm issue ------------------------
issue_store="$scratch/issues"
mkdir -p "$issue_store"
issue_file_mock="$scratch/fleet-issue-file"
cat >"$issue_file_mock" <<EOFMOCK
#!/usr/bin/env bash
set -euo pipefail
title=""; body=""
prev=""
for a in "\$@"; do
    case "\$prev" in
        --title) title="\$a" ;;
        --body)  body="\$a" ;;
    esac
    prev="\$a"
done
n=\$(find "$issue_store" -name 'issue-*.title' 2>/dev/null | wc -l)
n=\$((n + 1))
printf '%s\n' "\$title" > "$issue_store/issue-\${n}.title"
printf '%s\n' "\$body" > "$issue_store/issue-\${n}.body"
printf 'agent-ready\n' > "$issue_store/issue-\${n}.labels"
echo "https://github.com/Nishfleet/fleet-ops/issues/700\${n}"
EOFMOCK
chmod +x "$issue_file_mock"

gh_mock="$scratch/gh"
cat >"$gh_mock" <<'EOFGH'
#!/usr/bin/env bash
set -euo pipefail
store="${ISSUE_STORE:?}"
cmd="$1"; shift
sub="${1:-}"; shift || true
case "$cmd/$sub" in
  issue/view)
    num="$1"; shift
    args="$*"
    if [[ "$args" == *"--json title"* ]]; then
        cat "$store/issue-${num}.title"
        exit 0
    fi
    if [[ "$args" == *"--json comments"* ]]; then
        if [[ -f "$store/issue-${num}.comments" ]]; then
            python3 -c 'import json,sys;print(json.dumps([{"body": sys.stdin.read(), "createdAt": ""}]))' <"$store/issue-${num}.comments"
        else
            printf '{"comments": []}\n'
        fi
        exit 0
    fi
    exit 0
    ;;
  issue/comment)
    num="$1"; shift
    body=""; prev=""
    for a in "$@"; do
        case "$prev" in --body) body="$a" ;; esac
        prev="$a"
    done
    printf '%s\n' "$body" >>"$store/issue-${num}.comments"
    echo "https://github.com/Nishfleet/fleet-ops/issues/${num}#issuecomment-1"
    ;;
  *) exit 0 ;;
esac
EOFGH
chmod +x "$gh_mock"

run_reconciler() {
    local open_json="$1" now="$2"
    FLEET_HEARTBEAT_TRIAGE="$triage" \
    FLEET_SIGNAL_RECONCILE_OPEN_ISSUES_JSON="$open_json" \
    FLEET_SIGNAL_RECONCILE_FILE_ISSUES=1 \
    FLEET_SIGNAL_RECONCILE_OK_TO_CLOSE=0 \
    FLEET_SIGNAL_RECONCILE_ISSUE_REPO="Nishfleet/fleet-ops" \
    FLEET_SIGNAL_RECONCILE_NOW="$now" \
    FLEET_ISSUE_FILE="$issue_file_mock" \
    GH="$gh_mock" \
    ISSUE_STORE="$issue_store" \
        python3 "$reconciler" >>"$scratch/reconciler.log" 2>&1
}

printf '[]\n' >"$scratch/open-empty.json"
run_reconciler "$scratch/open-empty.json" "2026-09-14T04:20:00Z" \
  || fail "reconciler tick 1 crashed ($(cat "$scratch/reconciler.log"))"
[[ "$(find "$issue_store" -name 'issue-*.title' | wc -l)" == "1" ]] \
  || fail "reconciler must file exactly ONE alarm issue (got $(find "$issue_store" -name 'issue-*.title' | wc -l))"
title="$(cat "$issue_store/issue-1.title")"
case "$title" in
  "alarm: SCOUT-WALL-CHAIN-DEAD"*) : ;;
  *) fail "filed title must be prefixed 'alarm: SCOUT-WALL-CHAIN-DEAD', got: $title" ;;
esac
case "$title" in
  *'scout-wall-chain-dead/0509'*) : ;;
  *) fail "filed title must embed the signal key (fleet-ops#4622), got: $title" ;;
esac
body="$(cat "$issue_store/issue-1.body")"
for needle in \
  'pi-scout@0509.service' \
  'pi-scout-repair@0509.service' \
  'Connection error' \
  'PACKET-VERDICT tools=0 class=no-tools' \
  'signal: scout-wall-chain-dead/0509'; do
  grep -Fq "$needle" <<<"$body" || fail "filed body missing $needle; got: $body"
done
ok "reconciler filed exactly one 'alarm: SCOUT-WALL-CHAIN-DEAD' issue with both hops' journal evidence"

# --- 4. second wall while the alarm is open -> re-observe, no duplicate -----
: >"$triage"
seed_state
"$bin" end-repair 0509 1 >/dev/null 2>>"$scratch/endrepair-b.log"
[[ "$(chain_dead_lines)" == "1" ]] || fail "second wall must emit its LOUD line (got $(chain_dead_lines))"

# The filed alarm from tick 1 is still open (no quiet tick in between).
python3 - "$issue_store" >"$scratch/open-one.json" <<'EOP'
import json, sys, pathlib
store = pathlib.Path(sys.argv[1])
body = (store / "issue-1.body").read_text()
print(json.dumps([{
    "number": 7001,
    "title": (store / "issue-1.title").read_text().strip(),
    "body": body,
    "labels": [{"name": "agent-ready"}],
    "createdAt": "2026-09-14T04:20:00Z",
}]))
EOP
run_reconciler "$scratch/open-one.json" "2026-09-14T05:00:00Z" \
  || fail "reconciler tick 2 crashed ($(tail -5 "$scratch/reconciler.log"))"
[[ "$(find "$issue_store" -name 'issue-*.title' | wc -l)" == "1" ]] \
  || fail "second wall while alarm open must NOT file a duplicate (got $(find "$issue_store" -name 'issue-*.title' | wc -l))"
[[ -f "$issue_store/issue-7001.comments" ]] \
  || fail "second wall while alarm open must re-observe via heartbeat comment"
grep -q "still alarmed" "$issue_store/issue-7001.comments" \
  || fail "re-observe comment must be the reconciler's still-alarmed heartbeat: $(cat "$issue_store/issue-7001.comments")"
ok "second wall while alarm open: deduped per wall-storm — heartbeat comment, no duplicate issue"

# --- 5. the scout hop's own wall does NOT file the chain alarm --------------
: >"$triage"
: >"$state/0509.state"
set +e
"$bin" begin 0509 >/dev/null 2>&1
"$bin" end 0509 1 >/dev/null 2>&1
set -e
[[ "$(chain_dead_lines)" == "0" ]] \
  || fail "scout hop's own terminal wall must NOT emit SCOUT-WALL-CHAIN-DEAD (only the chain-terminal repair exit files)"
wall=$(awk -F= '$1=="consecutive_wall"{print $2}' "$state/0509.state")
[[ "$wall" == "1" ]] || fail "scout hop wall crash must still count consecutive_wall=1 (existing semantics), got $wall"
ok "scout hop's own wall: no chain-dead signal; consecutive_wall counter semantics unchanged"

# --- 6. repair exit 0 / seat-skip 75 never alarm ----------------------------
: >"$triage"
seed_state
"$bin" end-repair 0509 0 >/dev/null 2>&1
[[ "$(chain_dead_lines)" == "0" ]] || fail "repair exit 0 (chain completed) must not alarm"
"$bin" end-repair 0509 75 >/dev/null 2>&1
[[ "$(chain_dead_lines)" == "0" ]] || fail "repair seat-skip 75 (never started) must not alarm"
ok "repair exit 0 / seat-skip 75: no chain-terminal alarm"

echo "OK: scout-futility-terminal-wall-dispatch: chain-terminal wall files one deduped alarm on the existing reconciler rail"
