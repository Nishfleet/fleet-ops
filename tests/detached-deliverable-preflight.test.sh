#!/usr/bin/env bash
# tests/detached-deliverable-preflight.test.sh
#
# fleet-ops#5142: the DetachedJobDied repair path relaunches EVERY dead
# detached unit — including packets whose deliverable already landed (the
# promised file exists, or the PR the packet named merged / is armed +
# mergeable). Phase 2 adds a bounded, fail-open deliverable pre-flight in
# the per-alert filter loop; this phase-1 test-first harness covers:
#
#   (a) journal died: line carries deliverable=<abs-path> and the file is
#       present + non-empty -> 0 spawns, RESOLVED-DELIVERED in actions.log,
#       dead-man --clear <unit> called.
#   (b) journal deliverable=unset and the packet's named PR is OPEN but
#       unarmed (autoMergeRequest=null) -> exactly 1 spawn (today's
#       unchanged relaunch behaviour).
#   (c) the gh PR lookup times out -> exactly 1 spawn (fail-open: a flaky
#       gh must never strand a dead packet).
#
# Hermetic: HOME is redirected so the dispatcher's child PATH
# ($HOME/.local/bin:$PATH, ~L1215) resolves bare `pi-systemd-run` to a stub
# that only records argv — the phase-2 PI_SYSTEMD_RUN_BIN seam points at
# the same stub. JOURNALCTL_BIN/GH/PI_DEADMAN_BIN are env seams; no live
# gh, journalctl, systemd, or dead-man textfile. ALERT_REPAIR_NO_SPAWN is
# deliberately NOT set: real spawn attempts are what we count.
#
# Cases (b) and (c) pass on the unmodified dispatcher; case (a) MUST fail
# pre-change (the dispatcher spawns a relaunch it should have suppressed).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
dispatch_bin="$repo_root/libexec/alert-repair-dispatch"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"
python3 -m py_compile "$dispatch_bin" || fail "py_compile failed"

scratch="$(mktemp -d -t detached-deliverable-preflight.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
mkdir -p "$scratch/packets" "$scratch/seats" "$scratch/mock-bin" \
         "$scratch/home/.local/bin" "$scratch/agent-state" "$scratch/class-park"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Healthy fake seat so _pick_seat reaches the spawn path.
cat >"$scratch/pi-seat-health.json" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"$NOW"}
EOF
cat >"$scratch/seats/minimax__MiniMax-M3.json" <<EOF
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"$NOW","usable_at":null}
EOF
cat >"$scratch/seat-caps.json" <<'JSON'
{"providers":{"devin":{"cap":4,"models":{"glm-5-2":3}},"minimax":{"cap":2,"models":{"MiniMax-M3":2}}}}
JSON

# Mock deadman: records --clear invocations, does nothing else.
MOCK_DEADMAN="$scratch/mock-bin/pi-detached-deadman"
printf '#!/usr/bin/env bash\necho "deadman $*" >> "${MOCK_DEADMAN_LOG:?}"\nexit 0\n' >"$MOCK_DEADMAN"
# Mock claim helper: always proceeds so the test reaches the spawn path.
MOCK_CLAIM="$scratch/mock-bin/alert-repair-claim"
printf '#!/usr/bin/env bash\nexit 0\n' >"$MOCK_CLAIM"
# Mock journalctl (JOURNALCTL_BIN seam, lands in phase 2): prints the dead
# unit's journal — whatever fixture file the current case wrote.
MOCK_JOURNALCTL="$scratch/mock-bin/journalctl"
cat >"$MOCK_JOURNALCTL" <<'MOCK'
#!/usr/bin/env bash
echo "journalctl $*" >> "${MOCK_JOURNAL_LOG:?}"
cat "${MOCK_JOURNAL_FIXTURE:?}"
exit 0
MOCK
# Mock gh (GH seam): MOCK_GH_MODE=open prints one OPEN, UNARMED PR;
# =sleep hangs past the 5s pre-flight budget so the subprocess timeout
# fires. `pr list` gets a JSON array, `pr view` an object.
MOCK_GH="$scratch/mock-bin/gh"
cat >"$MOCK_GH" <<'MOCK'
#!/usr/bin/env bash
echo "gh $*" >> "${MOCK_GH_LOG:?}"
if [[ "${MOCK_GH_MODE:-open}" == "sleep" ]]; then
    sleep 30
    exit 0
fi
if [[ " $* " == *" list "* ]]; then
    printf '[{"number":5299,"state":"OPEN","autoMergeRequest":null,"mergeable":"MERGEABLE"}]\n'
else
    printf '{"number":5299,"state":"OPEN","autoMergeRequest":null,"mergeable":"MERGEABLE"}\n'
fi
exit 0
MOCK
# Spawn stub: argv[0] `pi-systemd-run` resolves against the CHILD env PATH
# ($HOME/.local/bin first). Both the PATH lookup and the phase-2
# PI_SYSTEMD_RUN_BIN seam land here — no real unit can ever be created.
MOCK_SPAWN="$scratch/home/.local/bin/pi-systemd-run"
printf '#!/usr/bin/env bash\necho "$*" >> "${MOCK_SPAWN_LOG:?}"\nexit 0\n' >"$MOCK_SPAWN"
chmod +x "$MOCK_DEADMAN" "$MOCK_CLAIM" "$MOCK_JOURNALCTL" "$MOCK_GH" "$MOCK_SPAWN"
PATH="$scratch/home/.local/bin:$PATH" command -v pi-systemd-run | grep -qx "$MOCK_SPAWN" \
    || fail "spawn stub must shadow pi-systemd-run on the child PATH"

# Packet for (b)/(c): names a branch + a Nishfleet/<repo>#N ref so the
# pre-flight has a PR candidate to check. Packet for (a) names no PR —
# the journal's deliverable path alone decides.
cat >"$scratch/packet-pr-candidate.md" <<'EOF'
# Detached job packet

- unit: gate-c-billing-failed
- repo: Nishfleet/fleet-ops

## accept

- deliverable lands on branch fable/gate-c-billing-failed (PR for Nishfleet/fleet-ops#5142)
EOF
cat >"$scratch/packet-a.md" <<'EOF'
# Detached job packet

- unit: pi-fleetops-gate-c-billing

## accept

- write the billing export to the promised deliverable path
EOF

write_ledger() {  # $1=dispatch uuid (alert `dispatch` label), $2=unit, $3=packet_path
    cat >"$scratch/agent-state/dispatch-ledger.jsonl" <<EOF
{"id":"$1","chain_id":"$1","hop":0,"ts":"$NOW","unit":"$2","packet_path":"$3","provider":"devin","model":"glm-5-2","deadline_min":90,"deadline_ts":"$NOW","cmdline":"pi --print --provider devin --model glm-5-2","status":"open","retries":0}
EOF
}

reset_logs() {
    : >"$scratch/packets/actions.log"; : >"$scratch/mock-deadman.log"
    : >"$scratch/mock-spawn.log";  : >"$scratch/mock-gh.log"
    : >"$scratch/mock-journal.log"
}

run_dispatch() {
    (
        export HOME="$scratch/home"
        export PACKET_DIR="$scratch/packets"
        export ALERT_REPAIR_PACKET_DIR="$scratch/packets"
        export SEAT_HEALTH_FILE="$scratch/pi-seat-health.json"
        export SEAT_LEDGER_DIR="$scratch/seats"
        export SEAT_CAPS_JSON="$scratch/seat-caps.json"
        export CLASS_PARK_DIR="$scratch/class-park"
        export ALERT_REPAIR_CLAIM_BIN="$MOCK_CLAIM"
        export PI_DEADMAN_BIN="$MOCK_DEADMAN"
        export PI_DEADMAN_TEXTFILE="$scratch/fleet-detached.prom"
        export PI_SYSTEMD_RUN_BIN="$MOCK_SPAWN"
        export JOURNALCTL_BIN="$MOCK_JOURNALCTL"
        export GH="$MOCK_GH"
        export FLEET_DISPATCH_LEDGER="$scratch/agent-state/dispatch-ledger.jsonl"
        export AGENT_STATE="$scratch/agent-state"
        export MOCK_DEADMAN_LOG="$scratch/mock-deadman.log"
        export MOCK_SPAWN_LOG="$scratch/mock-spawn.log"
        export MOCK_GH_LOG="$scratch/mock-gh.log"
        export MOCK_JOURNAL_LOG="$scratch/mock-journal.log"
        export AMX_STATUS=firing AMX_RECEIVER=repair-dispatch AMX_LABEL_service=fleet
        for e in "$@"; do export "$e"; done
        "$dispatch_bin" >"$scratch/out" 2>"$scratch/err"
    )
    rc=$?
    return $rc
}

alert_env() {  # $1=unit $2=dispatch-uuid $3=deliverable-flag $4=journal-fixture $5=gh-mode
    run_dispatch \
        'AMX_ALERT_1_LABEL_alertname=DetachedJobDied' \
        "AMX_ALERT_1_LABEL_unit=$1" \
        'AMX_ALERT_1_LABEL_cmdline=pi --print --provider devin --model glm-5-2' \
        "AMX_ALERT_1_LABEL_dispatch=$2" \
        "AMX_ALERT_1_LABEL_deliverable=$3" \
        'AMX_ALERT_1_LABEL_deadline=90' \
        'AMX_ALERT_1_STATUS=firing' \
        "MOCK_JOURNAL_FIXTURE=$4" \
        "MOCK_GH_MODE=$5"
}

UUID_A="11111111-5142-4514-8514-211111111111"
UUID_B="22222222-5142-4514-8514-222222222222"
UUID_C="33333333-5142-4514-8514-333333333333"
journal_died() {  # $1=unit $2=deliverable-path-or-unset $3=out-file
    printf '[2026-09-11T01:00:00Z] [pi-detached-deadman] died: unit=%s result=exit-code deliverable=%s — dead-man tripped\n' \
        "$1" "$2" >"$3"
}

# --- (a) deliverable file present + non-empty -> suppressed relaunch -----
UNIT_A="pi-fleetops-gate-c-billing"
echo "gate-c billing export: 4021 rows" >"$scratch/deliverable-a.out"
journal_died "$UNIT_A" "$scratch/deliverable-a.out" "$scratch/journal-a.txt"
write_ledger "$UUID_A" "$UNIT_A" "$scratch/packet-a.md"
reset_logs
alert_env "$UNIT_A" "$UUID_A" 1 "$scratch/journal-a.txt" open
rc=$?
[[ "$rc" == 0 ]] || fail "(a) dispatch must exit 0, got rc=$rc; err=$(cat "$scratch/err")"
! grep -q . "$scratch/mock-spawn.log" \
    || fail "(a) delivered packet must NOT spawn a relaunch; spawn argv: $(cat "$scratch/mock-spawn.log")"
grep -q "RESOLVED-DELIVERED unit=$UNIT_A" "$scratch/packets/actions.log" \
    || fail "(a) must log RESOLVED-DELIVERED; actions.log=$(cat "$scratch/packets/actions.log" 2>/dev/null)"
grep -q "deadman --clear $UNIT_A" "$scratch/mock-deadman.log" \
    || fail "(a) deadman --clear must be called; log=$(cat "$scratch/mock-deadman.log" 2>/dev/null)"
ok '(a) deliverable file present: 0 spawns, RESOLVED-DELIVERED, dead-man cleared'

# --- (b) deliverable unset + OPEN unarmed PR -> exactly 1 spawn ----------
UNIT_B="gate-c-billing-failed"
journal_died "$UNIT_B" unset "$scratch/journal-b.txt"
write_ledger "$UUID_B" "$UNIT_B" "$scratch/packet-pr-candidate.md"
reset_logs
alert_env "$UNIT_B" "$UUID_B" 0 "$scratch/journal-b.txt" open
rc=$?
[[ "$rc" == 0 ]] || fail "(b) dispatch must exit 0, got rc=$rc; err=$(cat "$scratch/err")"
[[ "$(grep -c . "$scratch/mock-spawn.log")" == 1 ]] \
    || fail "(b) undelivered packet must spawn exactly one relaunch; spawn log=$(cat "$scratch/mock-spawn.log")"
! grep -q 'RESOLVED-DELIVERED' "$scratch/packets/actions.log" \
    || fail "(b) OPEN unarmed PR is not delivered; actions.log=$(cat "$scratch/packets/actions.log")"
! grep -q "deadman --clear $UNIT_B" "$scratch/mock-deadman.log" \
    || fail "(b) relaunched packet must not clear the dead-man; log=$(cat "$scratch/mock-deadman.log")"
[[ "$(grep -c . "$scratch/mock-gh.log")" -le 1 ]] \
    || fail "(b) pre-flight must spend at most one gh call; log=$(cat "$scratch/mock-gh.log")"
ok '(b) deliverable unset + OPEN unarmed PR: exactly 1 spawn'

# --- (c) gh times out -> fail-open, exactly 1 spawn ----------------------
UNIT_C="pi-fleetops-pr5301-verify"
journal_died "$UNIT_C" unset "$scratch/journal-c.txt"
write_ledger "$UUID_C" "$UNIT_C" "$scratch/packet-pr-candidate.md"
reset_logs
alert_env "$UNIT_C" "$UUID_C" 0 "$scratch/journal-c.txt" sleep
rc=$?
[[ "$rc" == 0 ]] || fail "(c) dispatch must exit 0, got rc=$rc; err=$(cat "$scratch/err")"
[[ "$(grep -c . "$scratch/mock-spawn.log")" == 1 ]] \
    || fail "(c) gh timeout must fail open and spawn exactly one relaunch; spawn log=$(cat "$scratch/mock-spawn.log")"
! grep -q 'RESOLVED-DELIVERED' "$scratch/packets/actions.log" \
    || fail "(c) a timed-out gh proves nothing; actions.log=$(cat "$scratch/packets/actions.log")"
! grep -q "deadman --clear $UNIT_C" "$scratch/mock-deadman.log" \
    || fail "(c) relaunched packet must not clear the dead-man; log=$(cat "$scratch/mock-deadman.log")"
ok '(c) gh timeout: fail-open, exactly 1 spawn'

ok 'fleet-ops#5142 deliverable pre-flight passes'
