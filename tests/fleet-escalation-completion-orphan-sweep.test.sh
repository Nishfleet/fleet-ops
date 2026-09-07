#!/usr/bin/env bash
# tests/fleet-escalation-completion-orphan-sweep.test.sh
#
# fleet-ops#2614: fleet-escalation-completion must sweep orphan chain state
# files left behind by cross-unit re-fires. Without the sweep those files
# sit "in_flight" forever (the main flow only updates the hash of the
# CURRENT STOP-REASON, so older hashes never get terminal=green|nish-wall|
# pending-closeout). Two cases:
#
#   A. in_flight past BUDGET (no terminal field, first_seen < now-BUDGET):
#      mark terminal=expired so any future scan stops considering it open.
#   B. closed past 2x BUDGET (terminal already set, age > 2x BUDGET): delete.
#
# The sweep is invoked once per tick of fleet-heartbeat (which runs the
# completion enforcer every ~30 min). With the writer-side same-unit
# re-fire dedupe (companion test) the orphan rate drops to near zero,
# but a single cross-unit race still leaks one file per race.
#
# Runs entirely offline. The completion script reads:
#   * $FLEET_STOP_REASON — STOP-REASON.json path
#   * $FLEET_ESCALATION_COMPLETION_STATE — state dir for chain JSON files
#   * $FLEET_ESCALATION_COMPLETION_BUDGET — cycle budget in seconds
#   * $FLEET_ESCALATION_COMPLETION_SYSTEMCTL — systemctl (must be a stub
#     because the flow calls `systemctl --user is-active stop-escalation`
#     and `systemctl --user show $unit --property=Result`. The active
#     call must report "inactive" so the close path is not blocked; the
#     show call must report Result=success so detector_green returns true
#     when we want a green path. We only test the sweep here, so we use
#     a stub that always returns inactive / Result=exit-code.)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
completion="$repo_root/bin/fleet-escalation-completion"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$completion" ]] || fail "$completion not executable"

scratch="$(mktemp -d -t esc-complete-sweep.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin" "$scratch/agent-state"
PATH="$scratch/bin:$PATH"
export PATH

AS="$scratch/agent-state"
STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR"
SR="$AS/STOP-REASON.json"

# Stub systemctl. The completion script calls:
#   * `systemctl --user is-active stop-escalation.service` (must be inactive
#     so escalation_pipeline_active() returns false; the sweep does NOT
#     depend on the pipeline being active).
#   * `systemctl --user show <unit> --property=Result --value` (the
#     detector_green branch, which we don't exercise in this sweep test,
#     but the script calls it for every STOP-REASON we seed).
# We seed Result=success so detector_green returns true on the current
# STOP-REASON; the script then takes the green path and emits a
# terminal=green marker for the CURRENT hash. The orphan sweep runs
# BEFORE that green path closes the dir, so we can observe the
# terminal=expired marker on the orphans. We use unit=ghost-unit.service
# so Result=success from systemctl's POV maps cleanly.
cat > "$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "--user" && "$2" == "is-active" ]]; then
    echo "inactive"
    exit 0
fi
prop=""
for a in "$@"; do
    case "$a" in
        -p) prop_next=1 ;;
        --property=*) prop="${a#--property=}" ;;
        -p*) prop="${a#-p}" ;;
        *)
            if [ "${prop_next:-0}" = "1" ]; then prop="$a"; prop_next=0; fi
            ;;
    esac
done
case "$prop" in
    Result)           echo "success" ;;
    *)                echo "" ;;
esac
STUB
chmod +x "$scratch/bin/systemctl"

# Stub sha256sum — we control the content of every STOP-REASON so a
# stable sha256 is computable from the script's input. The completion
# script calls sha256sum on the live STOP-REASON file; we just need it
# to match the hash it computes inside the test.
sha256_of() {
    python3 -c "import sys,hashlib; sys.stdout.write(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"
}

now=$(date -u +%s)

# Helper: write a chain state file with the given first_seen, terminal
# value ("" = in_flight, or "green"/"expired"/etc), and a synthetic hash.
write_chain() {
    local fake_hash="$1" first_seen="$2" terminal="$3"
    local body
    if [ -z "$terminal" ]; then
        body=$(printf '{"hash":"%s","first_seen":%s,"stall_count":0}' "$fake_hash" "$first_seen")
    else
        body=$(printf '{"hash":"%s","first_seen":%s,"stall_count":0,"terminal":"%s"}' "$fake_hash" "$first_seen" "$terminal")
    fi
    printf '%s\n' "$body" > "$STATE_DIR/$fake_hash.json"
}

# Seed the state dir with a mix of orphans:
#   * alpha (old in_flight, first_seen=now-90000 = past BUDGET 86400)
#   * bravo (very old in_flight, first_seen=now-200000 = past 2x BUDGET)
#   * charlie (closed past 2x BUDGET, first_seen=now-200000, terminal=green)
#   * delta (recent in_flight, first_seen=now-30 = within budget; MUST stay)
write_chain "alpha0000000000000000000000000000000000000000000000000000" $((now - 90000)) ""
write_chain "bravo0000000000000000000000000000000000000000000000000000" $((now - 200000)) ""
write_chain "charlie000000000000000000000000000000000000000000000000000" $((now - 200000)) "green"
write_chain "delta0000000000000000000000000000000000000000000000000000" $((now - 30)) ""

# Seed the CURRENT STOP-REASON.json so the sweep runs with a known hash.
cat > "$SR" <<EOF
{"reason":"unit-failure","detail":{"unit":"ghost-unit.service","result":"exit-code","exit_status":"1","memory_peak":"","oom_signal":"no"},"timestamp":"1970-01-01T00:00:00.000Z","extension":"unit-escalation","source":"unit-escalation"}
EOF
current_hash=$(sha256_of "$SR")
echo "current_hash=$current_hash"

# Run the completion enforcer with the seeded state dir.
rc=0
FLEET_STOP_REASON="$SR" \
FLEET_ESCALATION_COMPLETION_STATE="$STATE_DIR" \
FLEET_ESCALATION_COMPLETION_BUDGET=86400 \
FLEET_ESCALATION_COMPLETION_SYSTEMCTL="$scratch/bin/systemctl" \
FLEET_ESCALATION_COMPLETION_DRY_RUN=1 \
    bash "$completion" 2>"$scratch/run.stderr" || rc=$?
rc=${rc:-0}

# Expectations:
#   * alpha (in_flight past BUDGET) -> terminal=expired
#   * bravo (in_flight past 2x BUDGET) -> terminal=expired (mark first,
#     the deletion path runs at 2x BUDGET for FILES WITH TERMINAL — after
#     marking, bravo still has age > 2x BUDGET, so the next sweep iteration
#     would delete it. In a single sweep pass bravo is marked expired.)
#   * charlie (closed past 2x BUDGET) -> deleted
#   * delta (recent in_flight within BUDGET) -> unchanged
#   * current_hash (writes terminal=green or pending-closeout) -> created
alpha_terminal=$(jq -r '.terminal // ""' "$STATE_DIR/alpha0000000000000000000000000000000000000000000000000000.json" 2>/dev/null || echo "")
[[ "$alpha_terminal" = "expired" ]] \
    || fail "alpha (in_flight past BUDGET) must be marked terminal=expired, got: '$alpha_terminal'"
ok "alpha (in_flight past BUDGET) -> terminal=expired (mark stops further 'open' reads)"

bravo_terminal=$(jq -r '.terminal // ""' "$STATE_DIR/bravo0000000000000000000000000000000000000000000000000000.json" 2>/dev/null || echo "")
[[ "$bravo_terminal" = "expired" ]] \
    || fail "bravo (in_flight past 2x BUDGET) must be marked terminal=expired in this pass, got: '$bravo_terminal'"
ok "bravo (in_flight past 2x BUDGET) -> terminal=expired (mark; would be deleted next sweep)"

if [ -e "$STATE_DIR/charlie000000000000000000000000000000000000000000000000000.json" ]; then
    fail "charlie (closed past 2x BUDGET) must be DELETED by the sweep, but the file still exists"
fi
ok "charlie (closed past 2x BUDGET) -> DELETED (terminal set + aged out, garbage collected)"

delta_terminal=$(jq -r '.terminal // ""' "$STATE_DIR/delta0000000000000000000000000000000000000000000000000000.json" 2>/dev/null || echo "")
[[ -z "$delta_terminal" ]] \
    || fail "delta (recent in_flight within BUDGET) must stay in_flight, got terminal='$delta_terminal'"
delta_first_seen=$(jq -r '.first_seen // 0' "$STATE_DIR/delta0000000000000000000000000000000000000000000000000000.json" 2>/dev/null || echo 0)
[[ "$delta_first_seen" = "$((now - 30))" ]] \
    || fail "delta first_seen must be preserved (no overwrite), got $delta_first_seen (expected $((now - 30)))"
ok "delta (recent in_flight within BUDGET) -> unchanged (current trip, not an orphan)"

# Verify the sweep logged a summary line.
grep -q "orphan-chain sweep: marked=" "$scratch/run.stderr" \
    || fail "completion must log an orphan-chain sweep summary line; got stderr: $(cat "$scratch/run.stderr")"
ok "completion logs orphan-chain sweep summary (visibility for the canary)"

# ---- Case F: small state dir (no orphans past BUDGET) -> sweep is a no-op ----
# Stub Result=exit-code this time so detector_green returns false and the
# main flow stays in the "in-flight, not stale" branch (rc=0). The sweep
# must still run safely, find nothing to mark/delete, and emit the
# summary line only if it actually changed something.
cat > "$scratch/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "--user" && "$2" == "is-active" ]]; then
    echo "inactive"
    exit 0
fi
prop=""
for a in "$@"; do
    case "$a" in
        -p) prop_next=1 ;;
        --property=*) prop="${a#--property=}" ;;
        -p*) prop="${a#-p}" ;;
        *)
            if [ "${prop_next:-0}" = "1" ]; then prop="$a"; prop_next=0; fi
            ;;
    esac
done
case "$prop" in
    Result)           echo "exit-code" ;;
    *)                echo "" ;;
esac
STUB
chmod +x "$scratch/bin/systemctl"

fresh_state="$scratch/fresh"
mkdir -p "$fresh_state"
# Seed a recent closed-but-not-aged-out file: terminal=green, age 90000
# (past 1x BUDGET 86400 but not past 2x BUDGET 172800). Sweep must keep it.
fake_other=$(printf '{"hash":"other0000000000000000000000000000000000000000000000000000","first_seen":%s,"terminal":"green"}' $((now - 90000)))
printf '%s\n' "$fake_other" > "$fresh_state/other0000000000000000000000000000000000000000000000000000.json"

rc=0
FLEET_STOP_REASON="$SR" \
FLEET_ESCALATION_COMPLETION_STATE="$fresh_state" \
FLEET_ESCALATION_COMPLETION_BUDGET=86400 \
FLEET_ESCALATION_COMPLETION_SYSTEMCTL="$scratch/bin/systemctl" \
FLEET_ESCALATION_COMPLETION_DRY_RUN=1 \
    bash "$completion" 2>"$scratch/fresh.stderr" || rc=$?
rc=${rc:-0}
[[ "$rc" -eq 0 ]] \
    || fail "sweep on a small state dir must exit 0 (in-flight chain within budget), got rc=$rc. stderr=$(cat "$scratch/fresh.stderr")"
[ -e "$fresh_state/other0000000000000000000000000000000000000000000000000000.json" ] \
    || fail "closed-but-not-aged-out file must be preserved (age 90000 < 2x BUDGET 172800)"
ok "closed-but-not-aged-out file preserved (sweep only deletes at 2x BUDGET, not 1x)"

# Sweep with no work to do should NOT emit the "marked=... deleted=..." summary line
# (it's gated on at least one of marked/deleted being > 0).
if grep -q "orphan-chain sweep: marked=" "$scratch/fresh.stderr"; then
    fail "sweep with no orphans must not emit the 'marked=' summary line; got: $(cat "$scratch/fresh.stderr")"
fi
ok "sweep with no orphans is silent (visibility only when there is work to do)"

echo
echo "fleet-escalation-completion: orphan-chain sweep proven (fleet-ops#2614)"
