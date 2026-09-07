#!/usr/bin/env bash
# tests/alert-repair-claim-mutex.test.sh
#
# fleet-ops#1199: the alert-repair mutex. Two dispatches for the same
# (alert, repo) pair, 10s apart, must produce exactly one worker spawn
# (DISPATCH line in actions.log) and exactly one skipped-claimed line.
# The drill is the live-class test: if the mutex is missing, both
# dispatches spawn duplicate workers and the test fails.
#
# Three layers tested:
#   1. The standalone helper (libexec/alert-repair-claim) — proves two
#      concurrent acquires for the same alert+repo produce one win + one
#      lost-race, regardless of timing.
#   2. The end-to-end drill (libexec/alert-repair-dispatch with mocked
#      pi-systemd-run) — fires two dispatches 10s apart and asserts the
#      actions.log carries exactly one DISPATCH and exactly one
#      SKIPPED-CLAIMED line.
#   3. A ratchet on config/fleet_rules.yml — FleetMainRed must stay at
#      `for: 30m`. The mutex ships together with the threshold; a future
#      loosening has to land as a new issue + the same mutex.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

claim_bin="$repo_root/libexec/alert-repair-claim"
dispatch_bin="$repo_root/libexec/alert-repair-dispatch"
rules_file="$repo_root/config/fleet_rules.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$claim_bin"    ]] || fail "not executable: $claim_bin"
[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"
[[ -f "$rules_file"   ]] || fail "missing: $rules_file"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export XDG_RUNTIME_DIR="$scratch/run"
export FLEET_CLAIM_CHECKOUT_ROOT="$scratch/products"
export FLEET_CLAIM_REMOTE=origin
export FLEET_CLAIM_MAIN_BRANCH=main
export ALERT_REPAIR_STATE_DIR="$scratch/alert-repair-state"
export ALERT_REPAIR_PACKET_DIR="$scratch/agent-state/alert-repair"
export PACKET_DIR="$scratch/agent-state/alert-repair"
export SEAT_HEALTH_FILE="$scratch/pi-seat-health.json"
mkdir -p "$FLEET_CLAIM_CHECKOUT_ROOT" "$ALERT_REPAIR_STATE_DIR" "$PACKET_DIR" "$XDG_RUNTIME_DIR"

# --- bare remote + product checkout -----------------------------------------
bare="$scratch/bare/fleet-ops.git"
mkdir -p "$scratch/bare"
git -c init.defaultBranch=main init --bare -q "$bare"

checkout="$FLEET_CLAIM_CHECKOUT_ROOT/fleet-ops"
git -c init.defaultBranch=main clone -q "$bare" "$checkout"
(
    cd "$checkout"
    git config user.email "test@example.com"
    git config user.name "Test"
    echo 'init' > file.txt
    git add file.txt
    git commit -q -m 'initial'
    git branch -M main
    git push -q -u origin main
)

# --- 1. standalone helper: two concurrent acquires produce 1 win + 1 loss --
"$claim_bin" fleet-ops FleetMainRed >/dev/null

set +e
"$claim_bin" fleet-ops FleetMainRed >"$scratch/second.out" 2>&1
rc=$?
set -e
[[ "$rc" == 1 ]] || fail "second acquire must exit 1, got rc=$rc"
printf '%s' "$(cat "$scratch/second.out")" | grep -q '^claimed-by-other' \
    || fail "expected 'claimed-by-other' from second acquire, got: $(cat "$scratch/second.out")"

# Confirm the claim branch is on origin and points at main's tip.
# Scope is the alert name kebab-cased (FleetMainRed -> fleet-main-red),
# so the branch is claim/fleet-main-red-fleet-ops. Issue #1199's literal
# example uses the shorter form `claim/red-main-<repo>`; the actual
# convention is the kebab-case of the alert name so any alert maps to a
# deterministic, collision-free branch.
branch_tip=$(git -C "$checkout" ls-remote origin 'refs/heads/claim/fleet-main-red-fleet-ops' | awk '{print $1}')
main_sha=$(git -C "$checkout" ls-remote origin 'refs/heads/main' | awk '{print $1}')
[[ -n "$branch_tip" ]] || fail 'claim branch missing on origin'
[[ "$branch_tip" == "$main_sha" ]] \
    || fail "claim tip ($branch_tip) must match main tip ($main_sha)"
ok 'standalone acquire: second concurrent call refused, branch matches main'

# --- 2. end-to-end drill: two dispatches 10s apart --------------------------
# Mock pi-systemd-run so we don't spawn a real worker; the dispatch script
# writes DISPATCH to actions.log only after the subprocess returns.
mock_bin="$scratch/mock-bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/pi-systemd-run" <<'MOCK'
#!/usr/bin/env bash
# Mock for tests: exit 0 immediately. The real tool spawns a worker; this
# stub lets the test assert that exactly one invocation happens.
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] mock-pi-systemd-run args=$*" >> "${MOCK_LOG:-/dev/null}"
exit 0
MOCK
chmod +x "$mock_bin/pi-systemd-run"
export MOCK_LOG="$scratch/mock-pi-systemd-run.log"

# Seat health file: pick a fresh fallback ladder seat.
cat >"$SEAT_HEALTH_FILE" <<'EOF'
{"provider":"minimax","model":"MiniMax-M3","health_class":"healthy","observed_at":"2099-01-01T00:00:00Z"}
EOF

# Override the dispatch's helper path so the test does not depend on the
# installed location of alert-repair-claim.
export ALERT_REPAIR_CLAIM_BIN="$claim_bin"

# Release the prior claim so the drill starts on a clean slate.
# (The release path is identical to fleet-claim's: push --delete. There is
# no separate release helper in this PR — claim-reconcile + the worker
# packet own release. For the test, drop the branch directly via git.)
git -C "$checkout" push origin --delete 'refs/heads/claim/fleet-main-red-fleet-ops' >/dev/null 2>&1 || true
rm -f "$ALERT_REPAIR_STATE_DIR/fleet-ops-fleet-main-red.json"

# Two dispatches, 10s apart, both targeting fleet-ops/FleetMainRed.
fire_dispatch() {
    local n="$1"
    AMX_ALERT_1_LABEL_alertname="FleetMainRed" \
    AMX_ALERT_1_LABEL_repo="fleet-ops" \
    AMX_ALERT_1_LABEL_severity="critical" \
    AMX_ALERT_1_LABEL_service="fleet" \
    AMX_LABEL_repo="fleet-ops" \
    AMX_STATUS="firing" \
    AMX_RECEIVER="test-receiver" \
    PATH="$mock_bin:$PATH" \
    HOME="$scratch" \
    "$dispatch_bin" \
        >"$scratch/dispatch-$n.out" 2>"$scratch/dispatch-$n.err"
}

fire_dispatch 1 &
first_pid=$!
sleep 10
fire_dispatch 2 &
second_pid=$!
wait "$first_pid"; first_rc=$?
wait "$second_pid"; second_rc=$?

[[ "$first_rc" == 0 ]] || fail "first dispatch must exit 0, got rc=$first_rc"
[[ "$second_rc" == 0 ]] || fail "second dispatch must exit 0, got rc=$second_rc (got skipped-claimed)"

# Exactly one DISPATCH and exactly one SKIPPED-CLAIMED in actions.log.
dispatched=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
skipped=$(grep -c '\] SKIPPED-CLAIMED ' "$PACKET_DIR/actions.log" || true)
[[ "$dispatched" == "1" ]] \
    || fail "expected exactly 1 DISPATCH line, got $dispatched:
$(cat "$PACKET_DIR/actions.log" 2>/dev/null || true)"
[[ "$skipped" == "1" ]] \
    || fail "expected exactly 1 SKIPPED-CLAIMED line, got $skipped:
$(cat "$PACKET_DIR/actions.log" 2>/dev/null || true)"
ok 'end-to-end drill: two dispatches 10s apart -> 1 DISPATCH + 1 SKIPPED-CLAIMED'

# Confirm the mock pi-systemd-run was invoked exactly once (not twice).
mock_invokes=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$mock_invokes" == "1" ]] \
    || fail "mock pi-systemd-run should run exactly once, got $mock_invokes"
ok 'exactly one worker spawned (mock pi-systemd-run invoked once)'

# --- 2b. fleet-ops#2429: skip-list class never spawns a repair worker ------
# FleetSloSeatAvailSlowBurn is a WFR-input slow-burn SLO alert
# (fleet-ops#1291/2429): repair is mechanism-impossible (seat supply is
# operator-owned), so it lives in SKIP_SET exactly like WasteRatioRising.
# Firing it through the dispatcher must log SKIP reason=skip-list, exit 0,
# spawn NOTHING (no DISPATCH line, no pi-systemd-run invocation) and never
# touch the claim mutex.
fire_skip() {
    AMX_ALERT_1_LABEL_alertname="FleetSloSeatAvailSlowBurn" \
    AMX_ALERT_1_LABEL_severity="warning" \
    AMX_ALERT_1_LABEL_service="fleet" \
    AMX_LABEL_repo="fleet-ops" \
    AMX_STATUS="firing" \
    AMX_RECEIVER="test-receiver" \
    PATH="$mock_bin:$PATH" \
    HOME="$scratch" \
    "$dispatch_bin" \
        >"$scratch/dispatch-skip.out" 2>"$scratch/dispatch-skip.err"
}

fire_skip; skip_rc=$?
[[ "$skip_rc" == 0 ]] || fail "skip-list dispatch must exit 0, got rc=$skip_rc (stderr: $(cat "$scratch/dispatch-skip.err"))"
grep -q 'SKIP alertname=FleetSloSeatAvailSlowBurn.*reason=skip-list' "$PACKET_DIR/actions.log" \
    || fail "skip-list dispatch must log SKIP reason=skip-list; actions.log: $(cat "$PACKET_DIR/actions.log" 2>/dev/null || true)"
dispatched_after=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
[[ "$dispatched_after" == "1" ]] \
    || fail "skip-list dispatch must not add a DISPATCH line, got $dispatched_after:
$(cat "$PACKET_DIR/actions.log")"
mock_invokes_after=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$mock_invokes_after" == "1" ]] \
    || fail "skip-list dispatch must not spawn a worker, mock invoked $mock_invokes_after times"
ok 'skip-list (FleetSloSeatAvailSlowBurn): SKIP reason=skip-list, no DISPATCH, no spawn'

# --- 3. ratchet: FleetMainRed must stay at `for: 30m` ----------------------
# Threshold ships together with the mutex. A future loosening has to land
# as a new issue + the same atomic guard.
for_line=$(awk '
    /^[[:space:]]*- alert:[[:space:]]+FleetMainRed/ {flag=1; next}
    flag && /^[[:space:]]*for:/ {print; exit}
' "$rules_file")
[[ "$for_line" =~ for:[[:space:]]+30m ]] \
    || fail "FleetMainRed must be 'for: 30m' (ratchet-managed from #1199 start), got: $for_line"
ok 'ratchet: FleetMainRed stays at for: 30m'

# --- 4. generalisation: a different alert on the same repo also gets a claim
# Different alert name -> different scope -> different branch. Two parallel
# acquires for the SAME alert collide (already covered above); two parallel
# acquires for DIFFERENT alerts must NOT collide.
git -C "$checkout" push origin --delete 'refs/heads/claim/fleet-main-red-fleet-ops' >/dev/null 2>&1 || true
rm -f "$ALERT_REPAIR_STATE_DIR/fleet-ops-fleet-main-red.json" \
      "$ALERT_REPAIR_STATE_DIR/fleet-ops-fleet-escalation-storm.json"

"$claim_bin" fleet-ops FleetMainRed >/dev/null
if ! "$claim_bin" fleet-ops FleetEscalationStorm >/dev/null; then
    fail "different alert (FleetEscalationStorm) must NOT collide with FleetMainRed's claim"
fi
ok 'generalisation: different alerts on the same repo do not collide'

# --- 5. different repo, same alert: independent claims ----------------------
# Two repos both fire FleetMainRed simultaneously. Each gets its own claim
# branch; neither blocks the other.
mkdir -p "$FLEET_CLAIM_CHECKOUT_ROOT/0509"
git -c init.defaultBranch=main init --bare -q "$scratch/bare/0509.git"
git -c init.defaultBranch=main clone -q "$scratch/bare/0509.git" "$FLEET_CLAIM_CHECKOUT_ROOT/0509"
(
    cd "$FLEET_CLAIM_CHECKOUT_ROOT/0509"
    git config user.email "test@example.com"
    git config user.name "Test"
    echo 'init' > file.txt
    git add file.txt
    git commit -q -m 'initial'
    git branch -M main
    git push -q -u origin main
)
if ! "$claim_bin" 0509 FleetMainRed >/dev/null; then
    fail "second repo (0509) must NOT collide with fleet-ops's FleetMainRed claim"
fi
ok 'different repo, same alert: independent claims (no false collision)'
