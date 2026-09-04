#!/usr/bin/env bash
# tests/pi-intake-run.test.sh
#
# Proves:
#   1. The pi-intake@.service unit uses a per-instance RuntimeDirectory and
#      writes its packet to a per-instance path (fleet-ops#141).
#   2. pi-intake-run picks the packet from its per-instance rundir.
#   3. Overlapping intake ticks no-op instead of racing.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-intake-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

# --- 1. unit shape (fleet-ops#141) -----------------------------------------
unit="$repo_root/systemd/pi-intake@.service"
[[ -f "$unit" ]] || fail "missing unit file: $unit"
grep -q '^RuntimeDirectory=pi-intake-%i$' "$unit" \
  || fail "unit must use per-instance RuntimeDirectory, got: $(grep '^RuntimeDirectory=' "$unit" || true)"
grep -q '^ExecStart=/home/nish/.local/bin/pi-intake-run %i$' "$unit" \
  || fail "unit ExecStart must stay /home/nish/.local/bin/pi-intake-run %i, got: $(grep '^ExecStart=' "$unit" || true)"
grep -q '%t/pi-intake-%i/intake-%i.pkt' "$unit" \
  || fail "unit ExecStartPre must write to per-instance %t/pi-intake-%i/intake-%i.pkt, got: $(grep '^ExecStartPre=' "$unit" || true)"
ok "unit file: per-instance RuntimeDirectory and packet path (fleet-ops#141)"

# --- scratch dirs ---------------------------------------------------------
lockdir="$(mktemp -d)"
marker="$(mktemp)"
testrundir="$(mktemp -d)"
cleanup() { rm -rf "$lockdir" "$testrundir"; rm -f "$marker"; }
trap cleanup EXIT

# --- 2. packet path uses per-instance rundir -------------------------------
mkdir -p "$testrundir/pi-intake-demo"
pkt="$testrundir/pi-intake-demo/intake-demo.pkt"
printf 'demo packet\n' > "$pkt"
cat > "$testrundir/runner" <<'FAKE'
#!/usr/bin/env bash
touch "${1}.ran"
exit 0
FAKE
chmod +x "$testrundir/runner"
XDG_RUNTIME_DIR="$testrundir" PI_PACKET_RUN="$testrundir/runner" "$bin" demo >/dev/null
[[ -f "$pkt.ran" ]] || fail "runner was not invoked with packet path $pkt"
ok "pi-intake-run uses per-instance packet path"

# --- 3. overlapping intake ticks no-op instead of racing -------------------
export XDG_RUNTIME_DIR="$lockdir"
export PI_INTAKE_LOCKDIR="$lockdir"
# First tick holds the lock for ~2s and writes a marker.
export PI_INTAKE_CMD="echo first >>'$marker'; sleep 2"

"$bin" tesrepo >/tmp/pi-intake-run-first.out 2>&1 &
first_pid=$!
sleep 0.3

# Second tick must no-op while the first holds the lock.
set +e
export PI_INTAKE_CMD="echo second >>'$marker'"
out="$("$bin" tesrepo 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "overlap must exit 0, got $rc ($out)"
printf '%s\n' "$out" | grep -q 'no-op' || fail "overlap must print no-op, got: $out"

wait "$first_pid" || fail "first tick failed"

# Marker must contain only the first tick's write.
got="$(cat "$marker")"
[[ "$got" == "first" ]] || fail "second tick must not run the body, marker='$got'"
ok "overlapping intake tick is a no-op"

# After the lock is released, a later tick must run.
export PI_INTAKE_CMD="echo third >>'$marker'"
"$bin" tesrepo >/dev/null
got="$(cat "$marker")"
[[ "$got" == $'first\nthird' ]] || fail "later tick should run after lock release, marker='$got'"
ok "later tick runs after lock release"

# --- 4. fleet-ops#379 mechanical priority (CI hook; keep this call) --------
# ci.yml lists this file explicitly and is a gate-owned path, so the
# priority drill runs from here instead of a new workflow line.
bash "$here/intake-priority.test.sh"
# --- 5. fleet-ops#176 intake-tick heavy-seat gate (CI hook; keep this call) --
# tests/pi-intake-tick-seat-gate.test.sh (added by PR #1114) locks the
# no-heavy-seat hold on lib/pi-intake-tick.sh. ci.yml lists this file, so
# the seat-gate drill runs from here instead of a new workflow line
# (workers cannot edit .github/workflows/ci.yml). Same bash "$here/..."
# host pattern as the priority drill above.
bash "$here/pi-intake-tick-seat-gate.test.sh"
# fleet-ops#1250: claim-step prior-art bounce (CI hook; keep this call).
# ci.yml lists this file; workers cannot add a new verify-command line.
bash "$here/prior-art-claim-check.test.sh"
# --- 6. fleet-ops#1546 spawn post-condition + start-limit healer (CI hook) --
# tests/pi-intake-tick-spawn-postcondition.test.sh locks the healer
# (reset-failed on a start-limit-locked unit) and the post-condition
# verification (branch + packet + unit exist before claimed+spawned). ci.yml
# lists this file, so the drill runs from here instead of a new workflow line.
bash "$here/pi-intake-tick-spawn-postcondition.test.sh"
# --- 7. fleet-ops#1350 gh rate-limit throttle gate (CI hook) ---------------
# tests/pi-intake-gh-rate-limit.test.sh locks the side-car throttle in
# lib/pi-intake-tick.sh. ci.yml lists this file, so the drill runs here.
bash "$here/pi-intake-gh-rate-limit.test.sh"
# --- 8. fleet-ops#1455 claims-index write (CI hook) -----------------------
# tests/pi-intake-tick-claims-log.test.sh locks the append to
# ready-work-claims.log on each successful claim+spawn. Without it the
# heartbeat reports claims_last_2h=0 while claims are happening, and
# watchers auto-file false "Intake starvation" issues. ci.yml lists this
# file, so the drill runs here instead of a new workflow line.
bash "$here/pi-intake-tick-claims-log.test.sh"
# --- 9. fleet-ops#234/#2007 escalate-senior exclusion (CI hook) -----------
# tests/pi-intake-tick-escalate-senior-exclusion.test.sh (added by PR
# #2044) locks the exclude-escalate-senior filter in
# lib/pi-intake-tick.sh: a regular worker must never be dispatched on a
# senior-auditor-owned escalation (the #2007 live class). ci.yml lists
# this file, so the drill runs here instead of a new workflow line.
bash "$here/pi-intake-tick-escalate-senior-exclusion.test.sh"
# --- 10. fleet-ops#2040 set -e claim-set-e guard (CI hook) ---------------
# tests/pi-intake-tick-claim-set-e-guard.test.sh (added by PR #2040) locks
# the retry guards in lib/pi-intake-tick.sh so a GitHub secondary rate
# limit on gh issue edit/comment cannot abort the tick before the worker
# spawns (fleet-ops#2040 live class). ci.yml lists this file, so the drill
# runs here instead of a new workflow line.
bash "$here/pi-intake-tick-claim-set-e-guard.test.sh"
# --- 11. fleet-ops#1165 protected-verifier vacation park (CI hook) -------
# tests/pi-intake-tick-protected-verifier-vacation.test.sh locks the
# 0509-only, date-bounded skip in lib/pi-intake-tick.sh that parks
# agent-ready issues whose body names a protected verifier/deploy file
# during Nish's vacation, so workers do not open attest-stuck PRs that
# sit red on the required-verifier-integrity gate until Nish returns.
# ci.yml lists this file, so the drill runs here instead of a new
# workflow line (workers cannot edit .github/workflows/ci.yml).
bash "$here/pi-intake-tick-protected-verifier-vacation.test.sh"
# --- 12. fleet-ops#3247 repo-conditional worker prompt blocks (CI hook) ---
# tests/pi-intake-tick-repo-conditional-blocks.test.sh locks the conditional
# assembly in lib/pi-intake-tick.sh: the D1 schema + gate-integrity block
# ships ONLY when TARGET repo is 0509, and the GEO/AEO block ships ONLY
# when the issue carries a geo/aeo label. Keeps non-0509 and non-geo packets
# lean. ci.yml lists this file, so the drill runs here instead of a new
# workflow line (workers cannot edit .github/workflows/ci.yml).
bash "$here/pi-intake-tick-repo-conditional-blocks.test.sh"
