#!/usr/bin/env bash
# tests/pi-systemd-run.test.sh
#
# Proves the session-survive wrapper:
#   1. dry-run emits systemd-run --user --collect --no-block (not nohup)
#   2. --stdin becomes StandardInput=file:<abs>
#   3. nohup in the command is refused
#   4. already-active unit is a no-op (does not call systemd-run)
#   5. routing docs name pi-systemd-run so nohup is not the path of least
#      resistance (fleet-ops#54, #255). Hermetic fixtures prove the check;
#      live AGENTS.md / CLAUDE.md / vault standing-rules / ~/.codex/AGENTS.md
#      are asserted on the VPS.
#   6. LIVE (skipped if no user systemd): a job started from a dying parent
#      is still active after that parent exits.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-systemd-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

# --- 1. dry-run shape -------------------------------------------------------
out="$("$bin" --dry-run --unit issue26-shape -- sleep 1)"
printf '%s\n' "$out" | grep -q 'systemd-run' || fail "dry-run must invoke systemd-run, got: $out"
printf '%s\n' "$out" | grep -q -- '--user' || fail "dry-run must pass --user: $out"
printf '%s\n' "$out" | grep -q -- '--collect' || fail "dry-run must pass --collect: $out"
printf '%s\n' "$out" | grep -q -- '--no-block' || fail "dry-run must pass --no-block: $out"
printf '%s\n' "$out" | grep -q -- '--unit=issue26-shape' || fail "dry-run must pass --unit: $out"
printf '%s\n' "$out" | grep -qv 'nohup' || fail "dry-run must not mention nohup: $out"
ok "dry-run is systemd-run --user --collect --no-block"
printf '%s\n' "$out" | grep -q 'ExecStopPost=' || fail "dry-run must set ExecStopPost (fleet-ops#1204): $out"
printf '%s\n' "$out" | grep -q 'TimeoutStopSec=180' || fail "dry-run must set TimeoutStopSec=180: $out"
printf '%s\n' "$out" | grep -q 'RuntimeMaxSec=90min' || fail "dry-run must set RuntimeMaxSec from default --deadline 90 (fleet-ops#3328): $out"
ok "dry-run wires ExecStopPost salvage + RuntimeMaxSec"

# --- 2. --stdin becomes StandardInput=file: --------------------------------
pkt="$(mktemp)"
echo "packet" >"$pkt"
out="$("$bin" --dry-run --unit issue26-stdin --stdin "$pkt" -- /bin/true)"
rm -f "$pkt"
printf '%s\n' "$out" | grep -q 'StandardInput=file:' || fail "stdin must set StandardInput=file: $out"
ok "stdin maps to StandardInput=file:"

# --- 3. refuse nohup --------------------------------------------------------
set +e
err="$("$bin" --dry-run --unit x -- nohup sleep 1 2>&1)"
rc=$?
set -e
[[ "$rc" == "2" ]] || fail "nohup must exit 2, got $rc ($err)"
printf '%s\n' "$err" | grep -qi 'nohup' || fail "refuse message must mention nohup: $err"
ok "nohup in command is refused"

# --- 4. already-active no-op (does not call systemd-run) --------------------
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
cat >"$fake/systemctl" <<'FAKE'
#!/usr/bin/env bash
# $1 is --user
shift
case "$1" in
  is-active) echo active; exit 0 ;;
  show) echo 0; exit 0 ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
FAKE
cat >"$fake/systemd-run" <<'FAKE'
#!/usr/bin/env bash
echo "systemd-run was invoked: $*" >&2
exit 99
FAKE
chmod +x "$fake/systemctl" "$fake/systemd-run"
out="$(SYSTEMCTL="$fake/systemctl" SYSTEMD_RUN="$fake/systemd-run" \
    "$bin" --unit already-live -- /bin/true)"
printf '%s\n' "$out" | grep -q 'no-op' || fail "active unit must no-op, got: $out"
ok "already-active unit is a no-op"

# --- 5. routing docs name pi-systemd-run (fleet-ops#54, #255) --------------
# The old "call pi directly / there is no dispatch wrapper" sentence made
# `nohup pi ... &` the obvious background path. README and heartbeat already
# point here; the home/vault/codex routing docs must too. #54 listed three
# live files and missed ~/.codex/AGENTS.md; this list is the lock.
names_pi_systemd_run() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    grep -q 'pi-systemd-run' "$f"
}

before="$repo_root/tests/fixtures/routing-docs/before-no-wrapper.md"
after="$repo_root/tests/fixtures/routing-docs/after-pi-systemd-run.md"
[[ -f "$before" && -f "$after" ]] || fail "missing routing-doc fixtures"
if names_pi_systemd_run "$before"; then
    fail "old 'no dispatch wrapper' wording must fail the check (got a match in $before)"
fi
names_pi_systemd_run "$after" || fail "required pi-systemd-run sentence must pass ($after)"
ok "fixture check rejects the old wording and accepts the required sentence"

names_pi_systemd_run "$repo_root/README.md" \
    || fail "README.md must name pi-systemd-run"
names_pi_systemd_run "$repo_root/prompts/heartbeat.md" \
    || fail "prompts/heartbeat.md must name pi-systemd-run"
grep -q 'never `nohup`' "$repo_root/prompts/heartbeat.md" \
    || fail "heartbeat.md must ban nohup in the spawn step"
ok "in-repo README and heartbeat name pi-systemd-run"

# Live copies agents actually read. GitHub runners do not have these files
# (HOME is /home/runner). On the VPS all five exist and this is the run.
# fleet-ops#256: ~/.pi/agent/AGENTS.md is the always-on context Pi loads
# before prompts; #54's home/vault/codex update missed it, leaving nohup as
# the path of least resistance there. It must name pi-systemd-run too.
live_docs=(
    /home/nish/AGENTS.md
    /home/nish/.claude/CLAUDE.md
    /home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md
    /home/nish/.codex/AGENTS.md
    /home/nish/.pi/agent/AGENTS.md
)
live_checked=0
for f in "${live_docs[@]}"; do
    if [[ -f "$f" ]]; then
        names_pi_systemd_run "$f" || fail "$f must name pi-systemd-run so nohup is not the path of least resistance"
        live_checked=$((live_checked + 1))
    fi
done
expected="${#live_docs[@]}"
if [[ "$live_checked" -eq "$expected" ]]; then
    ok "live routing docs name pi-systemd-run ($live_checked files, including ~/.pi/agent/AGENTS.md)"
elif [[ "$live_checked" -eq 0 ]]; then
    echo "SKIP: live routing docs not present (CI runner)"
else
    fail "expected 0 or ${expected} live routing docs, found $live_checked"
fi

# --- 6. live: survives a dying parent --------------------------------------
if ! systemctl --user is-system-running >/dev/null 2>&1 \
    && ! systemctl --user show -p Version >/dev/null 2>&1; then
    echo "SKIP: no user systemd (CI runner) — live survive-parent not run here"
else
    unit="issue26-survive-$$"
    # Parent starts the unit and exits. The child sleep must still be running.
    # Suppress the dispatch ledger write so the live test does not pollute the
    # real agent-state ledger with a test sleep unit (fleet-ops#1009).
    bash -c "FLEET_DISPATCH_LEDGER_NO_WRITE=1 $bin --unit $unit -- /bin/sleep 20"
    # Parent is gone. Give systemd a moment to register the unit.
    sleep 0.4
    state="$(systemctl --user is-active "${unit}.service" 2>/dev/null || true)"
    if [[ "$state" != "active" && "$state" != "activating" ]]; then
        systemctl --user status "${unit}.service" --no-pager >&2 || true
        fail "unit ${unit}.service should still be live after parent exit, state=$state"
    fi
    systemctl --user stop "${unit}.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "${unit}.service" >/dev/null 2>&1 || true
    ok "unit still live after launching parent exited (state=$state)"
fi

# fleet-ops#1204: nested so hosted CI runs salvage tests without a workflow edit
# (nishfleet-worker cannot push .github/workflows/**). Hermetic cases do not
# need user systemd; the nested file skips its own live SIGTERM drill.
bash "$here/pi-salvage-worktree.test.sh" || fail "pi-salvage-worktree tests failed"

# fleet-ops#1213: nested so hosted CI runs git-mirror-update tests without
# a workflow edit (nishfleet-worker cannot push .github/workflows/**).
bash "$here/git-mirror-update.test.sh" || fail "git-mirror-update tests failed"

# ============================================================================
# Dispatch ledger (fleet-ops#1009)
# ============================================================================
# Hermetic: fake systemd-run, verify ledger append + packet copy + new flags.
scratch2="$(mktemp -d -t pi-systemd-run-dispatch.XXXXXX)"
trap2='rm -rf "$scratch2"'
trap "$trap2" EXIT

cat >"$scratch2/fake-systemd-run" <<'FAKE'
#!/usr/bin/env bash
echo "fake-systemd-run: $*" >>"${SR_LOG:?}"
exit 0
FAKE
chmod +x "$scratch2/fake-systemd-run"

# Fake systemctl: always returns inactive / MainPID=0 so the already-running
# no-op check does not fire.
cat >"$scratch2/fake-systemctl" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  --user)
    case "${2:-}" in
      is-active) echo "inactive"; exit 1 ;;
      show) echo "MainPID=0"; exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
esac
exit 0
FAKE
chmod +x "$scratch2/fake-systemctl"

pkt="$scratch2/packet.md"
echo "test packet body" > "$pkt"
: > "$scratch2/sr.log"

LEDGER="$scratch2/dispatch-ledger.jsonl"
AS="$scratch2/agent-state"

# --- 7. dry-run with --deadline/--provider/--model/--chain-id/--hop --------
set +e
SYSTEMD_RUN="$scratch2/fake-systemd-run" \
SYSTEMCTL="$scratch2/fake-systemctl" \
PI_SALVAGE_DISABLE=1 \
AGENT_STATE="$AS" \
FLEET_DISPATCH_LEDGER="$LEDGER" \
FLEET_DISPATCH_LEDGER_NO_WRITE=1 \
SR_LOG="$scratch2/sr.log" \
  "$bin" --dry-run --unit testunit --stdin "$pkt" \
    --deadline 30 --provider devin --model glm-5-2 \
    --chain-id chain-x --hop 0 \
    -- pi --print --provider devin --model glm-5-2 2>/dev/null
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "dry-run with new flags rc=$rc"
[[ ! -s "$scratch2/sr.log" ]] || fail "dry-run must not call systemd-run"
[[ ! -f "$LEDGER" ]] || fail "dry-run must not write ledger"
ok "dry-run accepts --deadline/--provider/--model/--chain-id/--hop (fleet-ops#1009)"
# fleet-ops#3328: --deadline must become RuntimeMaxSec so the unit dies at
# the budget instead of holding hop=run. Re-run the same dry-run and read
# stdout (the previous block discarded it).
out="$(SYSTEMD_RUN="$scratch2/fake-systemd-run" \
SYSTEMCTL="$scratch2/fake-systemctl" \
PI_SALVAGE_DISABLE=1 \
AGENT_STATE="$AS" \
FLEET_DISPATCH_LEDGER="$LEDGER" \
FLEET_DISPATCH_LEDGER_NO_WRITE=1 \
  "$bin" --dry-run --unit testunit --stdin "$pkt" \
    --deadline 30 --provider devin --model glm-5-2 \
    --chain-id chain-x --hop 0 \
    -- pi --print --provider devin --model glm-5-2)"
printf '%s\n' "$out" | grep -q 'RuntimeMaxSec=30min' \
  || fail "--deadline 30 must set RuntimeMaxSec=30min (fleet-ops#3328): $out"
ok "--deadline 30 wires RuntimeMaxSec=30min (fleet-ops#3328)"

# --- 8. real dispatch: ledger append + packet copy + provider parse --------
: > "$scratch2/sr.log"
set +e
SYSTEMD_RUN="$scratch2/fake-systemd-run" \
SYSTEMCTL="$scratch2/fake-systemctl" \
PI_SALVAGE_DISABLE=1 \
AGENT_STATE="$AS" \
FLEET_DISPATCH_LEDGER="$LEDGER" \
FLEET_DISPATCH_PACKET_DIR="$AS/dispatch-packets" \
SR_LOG="$scratch2/sr.log" \
  "$bin" --unit ledger-test --stdin "$pkt" \
    --deadline 5 --chain-id chain-abc --hop 0 \
    -- pi --print --provider devin --model glm-5-2 2>/dev/null
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "real dispatch rc=$rc"

# Ledger must have exactly one entry.
lines=$(wc -l < "$LEDGER")
[[ "$lines" == "1" ]] || fail "ledger must have 1 entry, got $lines"

# Parse and validate the ledger entry.
python3 - "$LEDGER" <<'PY' || fail "ledger entry validation failed"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["status"] == "open", d
assert d["chain_id"] == "chain-abc", d
assert d["hop"] == 0, d
assert d["unit"] == "ledger-test", d
assert d["provider"] == "devin", d       # parsed from COMMAND
assert d["model"] == "glm-5-2", d        # parsed from COMMAND
assert d["deadline_min"] == 5, d
assert d["deadline_ts"] != "", d
assert d["packet_path"] != "", d
assert d["retries"] == 0, d
print("ledger entry OK")
PY

# Packet must have been copied into dispatch-packets.
pkts=$(find "$AS/dispatch-packets" -name 'ledger-test-*.md' | wc -l)
[[ "$pkts" == "1" ]] || fail "expected 1 copied packet, got $pkts"

# systemd-run must have been called with StandardInput pointing at the copy.
grep -q 'StandardInput=file:' "$scratch2/sr.log" \
  || fail "systemd-run must receive StandardInput=file:"
grep -q "$AS/dispatch-packets" "$scratch2/sr.log" \
  || fail "StandardInput must point at the durable copy, not the original"

ok "real dispatch: ledger append + packet copy + provider parse (fleet-ops#1009)"

# --- 9. --deadline / --hop validation ---------------------------------------
set +e
SYSTEMD_RUN="$scratch2/fake-systemd-run" SYSTEMCTL="$scratch2/fake-systemctl" \
PI_SALVAGE_DISABLE=1 FLEET_DISPATCH_LEDGER_NO_WRITE=1 SR_LOG="$scratch2/sr.log" \
  "$bin" --unit bad --deadline 0 -- /bin/true 2>/dev/null
rc=$?
set -e
[[ "$rc" == "2" ]] || fail "--deadline 0 must exit 2, got $rc"

set +e
SYSTEMD_RUN="$scratch2/fake-systemd-run" SYSTEMCTL="$scratch2/fake-systemctl" \
PI_SALVAGE_DISABLE=1 FLEET_DISPATCH_LEDGER_NO_WRITE=1 SR_LOG="$scratch2/sr.log" \
  "$bin" --unit bad --hop -1 -- /bin/true 2>/dev/null
rc=$?
set -e
[[ "$rc" == "2" ]] || fail "--hop -1 must exit 2, got $rc"

ok "--deadline/--hop validation rejects junk (fleet-ops#1009)"

# --- 10. FLEET_DISPATCH_LEDGER_NO_WRITE suppresses ledger -------------------
rm -f "$LEDGER"
: > "$scratch2/sr.log"
set +e
SYSTEMD_RUN="$scratch2/fake-systemd-run" SYSTEMCTL="$scratch2/fake-systemctl" \
PI_SALVAGE_DISABLE=1 AGENT_STATE="$AS" \
FLEET_DISPATCH_LEDGER="$LEDGER" FLEET_DISPATCH_LEDGER_NO_WRITE=1 \
SR_LOG="$scratch2/sr.log" \
  "$bin" --unit noledger --stdin "$pkt" -- /bin/sleep 1 2>/dev/null
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "no-write dispatch rc=$rc"
[[ ! -f "$LEDGER" ]] || fail "FLEET_DISPATCH_LEDGER_NO_WRITE must suppress ledger"

ok "FLEET_DISPATCH_LEDGER_NO_WRITE suppresses ledger append (fleet-ops#1009)"
