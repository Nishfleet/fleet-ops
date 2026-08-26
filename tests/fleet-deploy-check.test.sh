#!/usr/bin/env bash
# tests/fleet-deploy-check.test.sh
#
# Merge-to-live gate (fleet-ops#468, decisions-ledger 2026-08-27 TOP GEAR):
# merged-but-not-live latency must be <= 5 minutes. fleet-deploy-check runs
# on a 2-min timer, fetches, compares origin/main vs HEAD, and ONLY invokes
# the sanctioned deploy step when origin/main moved.
#
# What we prove:
#   1. Checkout missing -> loud DEPLOY-CHECK-CHECKOUT-MISSING, exit 0.
#   2. origin/main unchanged -> "nothing to do", deploy NOT invoked, exit 0.
#   3. origin/main moved + NO_DEPLOY=1 -> "compare-only", deploy NOT invoked.
#   4. origin/main moved, deploy invoked once, deploy bin logs rc=0 -> exit 0.
#   5. origin/main moved, deploy invoked, deploy bin exits 1 -> LOUD
#      DEPLOY-CHECK-FAILED, exit 1.
#   6. Deploy already in flight (pgrep match) -> yields, deploy NOT invoked.
#   7. Already deployed between fetch and lock -> no second deploy.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-deploy-check"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "fleet-deploy-check not found: $bin"
command -v git >/dev/null || fail "git required"

scratch="$(mktemp -d -t deploycheck.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Fake checkout: a git repo whose HEAD we control.
checkout="$scratch/checkout"
git init -q -b main "$checkout"
git -C "$checkout" config user.email t@t
git -C "$checkout" config user.name t
echo one >"$checkout/f"
git -C "$checkout" add f
git -C "$checkout" commit -qm one
head_before=$(git -C "$checkout" rev-parse HEAD)

# A fake origin that we can advance.
origin="$scratch/origin"
git init -q --bare "$origin"
git -C "$checkout" remote add origin "$origin"
git -C "$checkout" push -q origin main

# Deploy spy: logs invocations, returns configurable rc.
deploy_spy="$scratch/deploy-spy.sh"
cat >"$deploy_spy" <<'FAKE'
#!/usr/bin/env bash
echo "DEPLOY-INVOKED $(date +%s) args=$*" >> "$DEPLOY_SPY_LOG"
echo "FLEET_OPS_CHECKOUT=${FLEET_OPS_CHECKOUT:-unset}" >> "$DEPLOY_SPY_LOG"
exit "${DEPLOY_SPY_RC:-0}"
FAKE
chmod +x "$deploy_spy"
DEPLOY_SPY_LOG="$scratch/deploy-spy.log"
: > "$DEPLOY_SPY_LOG"

lock="$scratch/lock"
triage="$scratch/triage.md"

run_bin() {
  local no_deploy="${1:-0}"
  set +e
  FLEET_OPS_CHECKOUT="$checkout" \
  FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
  FLEET_DEPLOY_CHECK_LOCK="$lock" \
  FLEET_DEPLOY_CHECK_NO_DEPLOY="$no_deploy" \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
  DEPLOY_SPY_LOG="$DEPLOY_SPY_LOG" \
  DEPLOY_SPY_RC="${2:-0}" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

# --- 1. checkout missing ----------------------------------------------------
rc=$(FLEET_OPS_CHECKOUT="$scratch/nonexistent" \
     FLEET_HEARTBEAT_TRIAGE="$triage" \
     "$bin" >/dev/null 2>"$scratch/err1.log"; echo $?)
[[ "$rc" == "0" ]] || fail "missing checkout should exit 0 (got $rc)"
grep -q "DEPLOY-CHECK-CHECKOUT-MISSING" "$scratch/err1.log" || fail "missing checkout loud line"
ok "missing checkout louds and exits 0"

# --- 2. origin/main unchanged ------------------------------------------------
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "unchanged should exit 0 (got $rc)"
grep -q "nothing to do" "$scratch/err.log" || fail "missing nothing-to-do log"
[[ ! -s "$DEPLOY_SPY_LOG" ]] || fail "deploy must not be invoked when unchanged"
ok "unchanged origin/main -> nothing to do, no deploy"

# --- 3. origin/main moved + compare-only -------------------------------------
# Advance origin/main WITHOUT moving local HEAD (a remote merge).
advance_origin() {
  local msg="$1"
  local tmp="$scratch/tmp"
  rm -rf "$tmp"
  git clone -q "$origin" "$tmp" 2>/dev/null
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name t
  echo "$msg" >"$tmp/x"
  git -C "$tmp" add x
  git -C "$tmp" commit -qm "$msg"
  git -C "$tmp" push -q origin main
}
advance_origin "remote-two"
rc=$(run_bin 1)
[[ "$rc" == "0" ]] || fail "compare-only should exit 0 (got $rc)"
grep -q "compare-only" "$scratch/err.log" || fail "missing compare-only log"
[[ ! -s "$DEPLOY_SPY_LOG" ]] || fail "deploy must not be invoked in compare-only mode"
ok "moved origin/main + compare-only -> no deploy, exit 0"

# --- 4. moved, deploy invoked, rc=0 ------------------------------------------
advance_origin "remote-three"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "deploy rc=0 should exit 0 (got $rc)"
grep -q "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || fail "deploy spy not invoked"
grep -q "deploy completed rc=0" "$scratch/err.log" || fail "missing deploy-completed log"
ok "moved origin/main -> deploy invoked, exit 0"

# --- 5. deploy rc=1 -> LOUD FAILED, exit 1 -----------------------------------
advance_origin "remote-four"
rc=$(run_bin 0 1)
[[ "$rc" == "1" ]] || fail "deploy rc=1 should exit 1 (got $rc)"
grep -q "DEPLOY-CHECK-FAILED" "$scratch/err.log" || fail "missing DEPLOY-CHECK-FAILED loud line"
ok "deploy failure louds DEPLOY-CHECK-FAILED, exit 1"

# --- 6. deploy already in flight -> yields -----------------------------------
advance_origin "remote-five"
n_before=$(grep -c "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || true)
# Simulate an in-flight deploy: a process whose cmdline contains
# bin/fleet-ops-deploy (matches the pgrep pre-filter).
mkdir -p "$scratch/inflight/bin"
cp /bin/sleep "$scratch/inflight/bin/fleet-ops-deploy"
"$scratch/inflight/bin/fleet-ops-deploy" 30 &
inflight_pid=$!
sleep 0.3
rc=$(run_bin 0)
kill "$inflight_pid" 2>/dev/null || true
wait "$inflight_pid" 2>/dev/null || true
[[ "$rc" == "0" ]] || fail "yield on in-flight deploy should exit 0 (got $rc)"
grep -q "yielding this tick" "$scratch/err.log" || fail "missing yield log"
n_after=$(grep -c "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || true)
[[ "$n_after" == "$n_before" ]] || fail "deploy must not be invoked when in-flight"
ok "in-flight deploy -> yields, no deploy"

# --- 7. already deployed between fetch and lock -------------------------------
advance_origin "remote-six"
# Hold the lock so the bin cannot take it.
exec 9>"$lock"
flock 9
rc=$(run_bin 0)
flock -u 9
[[ "$rc" == "0" ]] || fail "lock-held should exit 0 (got $rc)"
grep -q "lock held" "$scratch/err.log" || fail "missing lock-held log"
n_after=$(grep -c "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || true)
[[ "$n_after" == "$n_before" ]] || fail "deploy must not be invoked when lock held"
ok "lock held -> yields, no deploy"

echo "OK: fleet-deploy-check: unchanged/moved/compare-only/deploy-fail/yield/lock"
