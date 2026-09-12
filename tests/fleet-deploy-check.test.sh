#!/usr/bin/env bash
# tests/fleet-deploy-check.test.sh
#
# Merge-to-live gate (fleet-ops#468, decisions-ledger 2026-08-27 TOP GEAR):
# merged-but-not-live latency must be <= 5 minutes. fleet-deploy-check runs
# on a 2-min timer, fetches, compares origin/main vs HEAD, and invokes the
# sanctioned deploy step when origin/main moved OR the clone is on a named
# non-main branch (fleet-ops#5222).
#
# What we prove:
#   1. Checkout missing -> loud DEPLOY-CHECK-CHECKOUT-MISSING, exit 0.
#   2. origin/main unchanged -> "nothing to do", deploy NOT invoked, exit 0.
#   2b. origin/main SHA unchanged but checkout is off-main -> deploy IS
#       invoked (fleet-ops#5222).
#   3. origin/main moved + NO_DEPLOY=1 -> "compare-only", deploy NOT invoked.
#   4. origin/main moved, deploy invoked once, deploy bin logs rc=0 -> exit 0.
#   5. origin/main moved, deploy invoked, deploy bin exits 1 -> LOUD
#      DEPLOY-CHECK-FAILED, exit 1.
#   6. Deploy already in flight (argv[0] match) -> yields, deploy NOT invoked.
#   6b. A later argument that merely carries bin/fleet-ops-deploy is NOT
#       in-flight (fleet-ops#533: never pgrep -f).
#   7. Already deployed between fetch and lock -> no second deploy.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-deploy-check"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "fleet-deploy-check not found: $bin"
grep -q 'fleet-ops#5222' "$bin" \
    || fail "fleet-deploy-check must invoke deploy on off-main (fleet-ops#5222)"
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
# fleet-ops#598: pin defaultBranch AND retarget HEAD after the first push.
# GitHub-hosted git 2.55 still has init.defaultBranch=master, so an unpinned
# `git init --bare` leaves HEAD at refs/heads/master. After pushing main,
# `git clone` warns "remote HEAD refers to nonexistent ref" and has no local
# main, so `git push origin main` dies (P14 run 33015880096).
origin="$scratch/origin"
git -c init.defaultBranch=main init -q --bare "$origin"
git -C "$checkout" remote add origin "$origin"
git -C "$checkout" push -q origin main
git -C "$origin" symbolic-ref HEAD refs/heads/main

# fleet-ops#5016: this fixture's origin is a local bare path, so point the
# origin-fetch-URL guard's expectation at it. Production sets no seam and so
# demands the fleet-ops GitHub URL. Exported: the inline invocations below
# inherit it.
export FLEET_OPS_EXPECTED_ORIGIN_URL="$origin"

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

# --- 2b. origin/main SHA unchanged but checkout is off-main (fleet-ops#5222)
git -C "$checkout" checkout -q -b throwaway-guard-test
: > "$DEPLOY_SPY_LOG"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "off-main same-SHA should exit 0 (got $rc)"
grep -q "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" \
    || fail "off-main must invoke deploy even when HEAD SHA == origin/main"
grep -q "not main" "$scratch/err.log" \
    || fail "off-main must log the not-main reason: $(cat "$scratch/err.log")"
git -C "$checkout" checkout -q main
: > "$DEPLOY_SPY_LOG"
ok "off-main same SHA -> invoke deploy (fleet-ops#5222)"

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

# --- 5. deploy rc=1 -> LOUD FAILED, exit 0 (soft) ---------------------------
# fleet-ops#768 (auditor trip 2026-08-27T01:54Z): the prior behavior exited
# 1 on deploy failure, which tripped the systemd unit, fired OnFailure=,
# and summoned the auditor every tick a worker transiently dirtied the
# deploy-clone (the inner fleet-ops-deploy already auto-files the only
# actionable signal via auto_file_off_main). The check now treats
# deploy-blocked as soft: it logs the LOUD line for visibility and
# returns 0 so the next tick can retry. A hard internal error in the
# deploy binary is still surfaced via the LOUD line.
advance_origin "remote-four"
rc=$(run_bin 0 1)
[[ "$rc" == "0" ]] || fail "deploy rc=1 should be soft (exit 0), got $rc"
grep -q "DEPLOY-CHECK-FAILED" "$scratch/err.log" || fail "missing DEPLOY-CHECK-FAILED loud line"
ok "deploy failure louds DEPLOY-CHECK-FAILED, exit 0 (soft, was: hard-fail-tripped auditor)"

# --- 6. deploy already in flight -> yields -----------------------------------
advance_origin "remote-five"
n_before=$(grep -c "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || true)
# Simulate an in-flight deploy: argv[0] basename fleet-ops-deploy
# (fleet-ops#533: match argv[0]/argv[1], never pgrep -f).
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

# --- 6b. a later argument that merely carries the path must NOT yield ------
advance_origin "remote-five-b"
n_before=$(grep -c "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || true)
python3 -c 'import time,sys; time.sleep(20)' bin/fleet-ops-deploy &
arg_pid=$!
sleep 0.3
rc=$(run_bin 0)
kill "$arg_pid" 2>/dev/null || true
wait "$arg_pid" 2>/dev/null || true
[[ "$rc" == "0" ]] || fail "argument-only match should exit 0 (got $rc)"
if grep -q "yielding this tick" "$scratch/err.log"; then
  fail "argument-only bin/fleet-ops-deploy must not look in-flight"
fi
n_after=$(grep -c "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || true)
[[ "$n_after" -gt "$n_before" ]] || fail "argument-only match must still invoke deploy"
ok "argument-only cmdline match is not in-flight"

# --- 7. already deployed between fetch and lock -------------------------------
advance_origin "remote-six"
n_before=$(grep -c "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || true)
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

# --- 9. dirty deploy clone (tracked edit) -> LOUD DIRTY-CLONE every tick ----
# fleet-ops#3758: a worker editing a tracked file directly in the deploy clone
# must be flagged on EVERY tick for visibility, even when origin/main is
# unchanged (no merge has arrived to trip the deploy-side rejection). The
# dirty state is not fatal here (fleet-ops-deploy rejects/auto-files/rescues),
# so the gate must NOT skip the deploy path - it only adds the LOUD line.
# Sync the fixture to a clean HEAD==origin/main first (the deploy spy never
# actually merges, so HEAD has stayed at the original commit through §4-7).
git -C "$checkout" fetch -q origin
git -C "$checkout" reset -q --hard origin/main
printf 'worker-wip\n' >> "$checkout/f"
n_before=$(grep -c "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || true)
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "dirty clone should still exit 0 (got $rc)"
grep -q "DEPLOY-CHECK-DIRTY-CLONE" "$scratch/err.log" \
  || fail "dirty tracked edit must loud DEPLOY-CHECK-DIRTY-CLONE"
grep -q "nothing to do" "$scratch/err.log" \
  || fail "dirty + unchanged must still log nothing to do"
# The offending path (porcelain short format) is named in the LOUD line.
grep -qE "DEPLOY-CHECK-DIRTY-CLONE.*\bf\b" "$scratch/err.log" \
  || fail "DIRTY-CLONE loud should name the offending path"
n_after=$(grep -c "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || true)
[[ "$n_after" == "$n_before" ]] \
  || fail "dirty + unchanged must not invoke deploy (visibility only)"
git -C "$checkout" checkout -q -- f
ok "dirty tracked edit louds DIRTY-CLONE on an unchanged tick, no deploy"

# --- 10. untracked file in deploy clone -> LOUD DIRTY-CLONE ----------------
# A stray untracked file (e.g. a worker's scratch artifact) also dirties the
# clone; plain `git status --porcelain` catches it so "clean" = truly
# porcelain-empty.
: > "$scratch/err.log"
echo stray > "$checkout/worker-untracked.txt"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "untracked clone should exit 0 (got $rc)"
grep -q "DEPLOY-CHECK-DIRTY-CLONE" "$scratch/err.log" \
  || fail "untracked file must loud DEPLOY-CHECK-DIRTY-CLONE"
grep -q "worker-untracked.txt" "$scratch/err.log" \
  || fail "DIRTY-CLONE loud should name the untracked path"
rm -f "$checkout/worker-untracked.txt"
ok "untracked file louds DIRTY-CLONE and names the path"

# --- 11. clean clone -> no DIRTY-CLONE loud ---------------------------------
# A clean origin/main deploy clone must not trip the gate (no noise on the
# healthy path).
: > "$scratch/err.log"
rc=$(run_bin 0)
[[ "$rc" == "0" ]] || fail "clean clone should exit 0 (got $rc)"
if grep -q "DEPLOY-CHECK-DIRTY-CLONE" "$scratch/err.log"; then
  fail "clean clone must not loud DIRTY-CLONE"
fi
ok "clean clone produces no DIRTY-CLONE loud"

# --- 11b. DIRTY-CLONE auto-file default OFF (fleet-ops#5687) ----------------
# Without FLEET_DEPLOY_CHECK_DIRTY_AUTOFILE=1 the check must behave exactly
# as before: LOUD only, no episode state, no issue-file invocation.
issue_file_spy="$scratch/issue-file-spy.sh"
cat >"$issue_file_spy" <<'FAKE'
#!/usr/bin/env bash
echo "ISSUE-FILE-INVOKED args=$*" >> "$ISSUE_FILE_SPY_LOG"
exit "${ISSUE_FILE_SPY_RC:-0}"
FAKE
chmod +x "$issue_file_spy"
ISSUE_FILE_SPY_LOG="$scratch/issue-file-spy.log"
: > "$ISSUE_FILE_SPY_LOG"

dirty_autofile_run() {
  set +e
  FLEET_OPS_CHECKOUT="$checkout" \
  FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
  FLEET_DEPLOY_CHECK_LOCK="$lock" \
  FLEET_DEPLOY_CHECK_NO_DEPLOY=1 \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
  AGENT_STATE="$scratch/as" \
  FLEET_DEPLOY_CHECK_DIRTY_STATE_DIR="$scratch/as-dirty" \
  FLEET_DEPLOY_CHECK_DIRTY_AUTOFILE="${DIRTY_AUTOFILE_VAL:-0}" \
  FLEET_ISSUE_FILE="$issue_file_spy" \
  ISSUE_FILE_SPY_LOG="$ISSUE_FILE_SPY_LOG" \
  ISSUE_FILE_SPY_RC="${ISSUE_FILE_SPY_RC_VAL:-0}" \
    "$bin" >/dev/null 2>"$scratch/err-dirty.log"
  local rc=$?
  set -e
  echo "$rc"
}

printf 'autofile-wip\n' >> "$checkout/f"   # dirty the clone
: > "$ISSUE_FILE_SPY_LOG"
rc=$(dirty_autofile_run)                    # flag defaults OFF
[[ "$rc" == "0" ]] || fail "default-off dirty tick should exit 0 (got $rc)"
grep -q "DEPLOY-CHECK-DIRTY-CLONE" "$scratch/err-dirty.log" \
  || fail "default-off must still loud DIRTY-CLONE"
[[ ! -s "$ISSUE_FILE_SPY_LOG" ]] || fail "default-off must never invoke issue-file"
[[ ! -d "$scratch/as-dirty" ]] || fail "default-off must not write episode state"
ok "DIRTY-CLONE auto-file default OFF: LOUD only, no state, no filing"

# --- 11c. auto-file ON: 3rd consecutive dirty tick files exactly once -------
: > "$ISSUE_FILE_SPY_LOG"
DIRTY_AUTOFILE_VAL=1
rc=$(dirty_autofile_run); [[ "$rc" == "0" ]] || fail "dirty tick 1 should exit 0 (got $rc)"
rc=$(dirty_autofile_run); [[ "$rc" == "0" ]] || fail "dirty tick 2 should exit 0 (got $rc)"
[[ ! -s "$ISSUE_FILE_SPY_LOG" ]] \
  || fail "must not file before the 3rd consecutive dirty tick"
rc=$(dirty_autofile_run); [[ "$rc" == "0" ]] || fail "dirty tick 3 should exit 0 (got $rc)"
[[ -s "$ISSUE_FILE_SPY_LOG" ]] || fail "3rd consecutive dirty tick must auto-file"
grep -q "ISSUE-FILE-INVOKED args=file -R Nishfleet/fleet-ops --title DEPLOY-CHECK-DIRTY-CLONE" "$ISSUE_FILE_SPY_LOG" \
  || fail "must file via fleet-issue-file against Nishfleet/fleet-ops with a DIRTY-CLONE title"
grep -q "signal: deploy-check/dirty-clone" "$ISSUE_FILE_SPY_LOG" \
  || fail "filed body must carry the signal: deploy-check/dirty-clone marker"
grep -q -- "--label agent-ready" "$ISSUE_FILE_SPY_LOG" \
  || fail "auto-filed issue must carry --label agent-ready — the intake only lists -l agent-ready, an unlabeled filing is never claimed (fleet-ops#5687)"
: > "$ISSUE_FILE_SPY_LOG"
rc=$(dirty_autofile_run)                    # 4th consecutive tick
[[ "$rc" == "0" ]] || fail "dirty tick 4 should exit 0 (got $rc)"
[[ ! -s "$ISSUE_FILE_SPY_LOG" ]] || fail "one filing per dirty episode, not one per tick"
ok "auto-file ON: 3rd consecutive dirty tick files once per episode"

# --- 11d. clean tick resets the episode -------------------------------------
git -C "$checkout" checkout -q -- f         # clean the clone
: > "$ISSUE_FILE_SPY_LOG"
rc=$(dirty_autofile_run)
[[ "$rc" == "0" ]] || fail "clean tick should exit 0 (got $rc)"
[[ ! -f "$scratch/as-dirty/dirty-clone-streak" ]] \
  || fail "clean tick must reset the episode streak"
[[ ! -f "$scratch/as-dirty/dirty-clone-filed" ]] \
  || fail "clean tick must clear the filed marker"
printf 'autofile-wip-2\n' >> "$checkout/f"  # new dirty episode
dirty_autofile_run >/dev/null
dirty_autofile_run >/dev/null
[[ ! -s "$ISSUE_FILE_SPY_LOG" ]] \
  || fail "a fresh episode must restart counting (no filing on ticks 1-2)"
rc=$(dirty_autofile_run)
[[ "$rc" == "0" ]] || fail "new episode tick 3 should exit 0 (got $rc)"
[[ -s "$ISSUE_FILE_SPY_LOG" ]] || fail "a fresh episode must file again on its 3rd tick"
git -C "$checkout" checkout -q -- f
ok "clean tick resets the episode; a new episode files again on its 3rd tick"

# --- 11e. failed filing is non-fatal and retried next tick ------------------
rm -rf "$scratch/as-dirty"
printf 'autofile-retry\n' >> "$checkout/f"   # dirty the clone again
: > "$ISSUE_FILE_SPY_LOG"
ISSUE_FILE_SPY_RC_VAL=1                     # issue-file spy fails
dirty_autofile_run >/dev/null
dirty_autofile_run >/dev/null
[[ ! -s "$ISSUE_FILE_SPY_LOG" ]] || fail "failing spy ticks 1-2 must not invoke (below threshold)"
rc=$(dirty_autofile_run)                    # tick 3: filing attempted + fails
[[ "$rc" == "0" ]] || fail "a failed filing must not fail the check (got $rc)"
grep -q "WARN: DIRTY-CLONE auto-file failed" "$scratch/err-dirty.log" \
  || fail "a failed filing must log a WARN retry line"
[[ ! -f "$scratch/as-dirty/dirty-clone-filed" ]] \
  || fail "a failed filing must not write the filed marker"
: > "$ISSUE_FILE_SPY_LOG"
ISSUE_FILE_SPY_RC_VAL=0
rc=$(dirty_autofile_run)                    # tick 4: retry succeeds
[[ "$rc" == "0" ]] || fail "retry tick should exit 0 (got $rc)"
[[ -s "$ISSUE_FILE_SPY_LOG" ]] || fail "a failed filing must be retried on the next tick"
git -C "$checkout" checkout -q -- f
ok "failed filing logs WARN, stays non-fatal, retries next tick"

# --- 12. non-canonical unit symlink -> LOUD + repair (fleet-ops#4166) --------
# A worker's non-canonical install.sh retargets every live fleet unit symlink
# at a GC-able worktree; removing it blinds the fleet (Unit to trigger
# vanished -> canary stops -> chain gauge absent). The per-tick gate must
# detect a unit symlink whose target is non-canonical (under the workspaces
# root but not the canonical checkout) or dangling, LOUD, and repair via the
# sanctioned install.sh. Prove: detect, LOUD, repair invoked, exit 0.
unit_dir="$scratch/units"
canon_dir="$scratch/canon"
ws_root="$scratch/ws"
worktree_dir="$scratch/ws/issue-fleet-ops-4141"
mkdir -p "$unit_dir" "$canon_dir/systemd" "$worktree_dir/systemd"
# Canonical unit file (the repair target).
cat >"$canon_dir/systemd/fleet-completion-canary.service" <<'UNIT'
[Unit]
Description=canary
[Service]
ExecStart=/bin/true
UNIT
# A fake install.sh that retargets a unit symlink at the canonical checkout.
cat >"$canon_dir/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -euo pipefail
unit_dir="${FLEET_DEPLOY_CHECK_UNIT_DIR:?}"
canon="$(readlink -f "${FLEET_OPS_CANONICAL_CHECKOUT:-$1}")"
ln -sfn "$canon/systemd/fleet-completion-canary.service" \
  "$unit_dir/fleet-completion-canary.service"
INSTALL
chmod +x "$canon_dir/install.sh"
# A worktree unit file (the non-canonical source a worker installed from).
cat >"$worktree_dir/systemd/fleet-completion-canary.service" <<'UNIT'
[Unit]
Description=canary
[Service]
ExecStart=/bin/true
UNIT
# Live symlink points at the GC-able worktree (the hijack).
ln -sfn "$worktree_dir/systemd/fleet-completion-canary.service" \
  "$unit_dir/fleet-completion-canary.service"

: > "$scratch/err.log"
rc=$(FLEET_OPS_CHECKOUT="$canon_dir" \
     FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
     FLEET_DEPLOY_CHECK_LOCK="$lock" \
     FLEET_DEPLOY_CHECK_NO_DEPLOY=0 \
     FLEET_DEPLOY_CHECK_UNIT_DIR="$unit_dir" \
     FLEET_DEPLOY_CHECK_INSTALL_BIN="$canon_dir/install.sh" \
     FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir" \
     FLEET_OPS_WORKSPACES_ROOT="$ws_root" \
     FLEET_HEARTBEAT_TRIAGE="$triage" \
     DEPLOY_SPY_LOG="$DEPLOY_SPY_LOG" \
       "$bin" >/dev/null 2>"$scratch/err.log"; echo $?)
[[ "$rc" == "0" ]] || fail "non-canonical unit symlink should exit 0 (got $rc)"
grep -q "DEPLOY-CHECK-NONCANONICAL-UNITS" "$scratch/err.log" \
  || fail "non-canonical unit symlink must loud DEPLOY-CHECK-NONCANONICAL-UNITS"
grep -q "fleet-completion-canary.service" "$scratch/err.log" \
  || fail "LOUD line must name the offending unit symlink"
# Repair: the symlink must now point at the canonical checkout.
target=$(readlink -f "$unit_dir/fleet-completion-canary.service")
case "$target" in
  "$canon_dir"*) ;;
  *) fail "repair must retarget at canonical; got $target" ;;
esac
ok "non-canonical unit symlink louds + repairs to canonical (fleet-ops#4166)"

# --- 12b. dangling unit symlink (target vanished) -> LOUD + repair ---------
# The exact 07:33Z condition: the worktree was removed, so the symlink target
# vanished. install.sh retargets it back to canonical. Re-hijack the symlink
# at the worktree first (test 12's repair retargeted it to canonical), then
# remove the worktree to make the symlink dangle.
ln -sfn "$worktree_dir/systemd/fleet-completion-canary.service" \
  "$unit_dir/fleet-completion-canary.service"
rm -rf "$worktree_dir"
: > "$scratch/err.log"
rc=$(FLEET_OPS_CHECKOUT="$canon_dir" \
     FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
     FLEET_DEPLOY_CHECK_LOCK="$lock" \
     FLEET_DEPLOY_CHECK_NO_DEPLOY=0 \
     FLEET_DEPLOY_CHECK_UNIT_DIR="$unit_dir" \
     FLEET_DEPLOY_CHECK_INSTALL_BIN="$canon_dir/install.sh" \
     FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir" \
     FLEET_OPS_WORKSPACES_ROOT="$ws_root" \
     FLEET_HEARTBEAT_TRIAGE="$triage" \
     DEPLOY_SPY_LOG="$DEPLOY_SPY_LOG" \
       "$bin" >/dev/null 2>"$scratch/err.log"; echo $?)
[[ "$rc" == "0" ]] || fail "dangling unit symlink should exit 0 (got $rc)"
grep -q "DEPLOY-CHECK-NONCANONICAL-UNITS" "$scratch/err.log" \
  || fail "dangling unit symlink must loud DEPLOY-CHECK-NONCANONICAL-UNITS"
target=$(readlink -f "$unit_dir/fleet-completion-canary.service")
case "$target" in
  "$canon_dir"*) ;;
  *) fail "repair must retarget dangling symlink at canonical; got $target" ;;
esac
ok "dangling unit symlink (vanished target) louds + repairs (fleet-ops#4166)"

# --- 12c. compare-only mode -> LOUD only, no repair -----------------------
# FLEET_DEPLOY_CHECK_NO_DEPLOY=1 must LOUD but NOT repair (auditors need to
# see the drift without mutation). Re-hijack the symlink first.
mkdir -p "$worktree_dir/systemd"
cat >"$worktree_dir/systemd/fleet-completion-canary.service" <<'UNIT'
[Unit]
Description=canary
[Service]
ExecStart=/bin/true
UNIT
ln -sfn "$worktree_dir/systemd/fleet-completion-canary.service" \
  "$unit_dir/fleet-completion-canary.service"
: > "$scratch/err.log"
rc=$(FLEET_OPS_CHECKOUT="$canon_dir" \
     FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
     FLEET_DEPLOY_CHECK_LOCK="$lock" \
     FLEET_DEPLOY_CHECK_NO_DEPLOY=1 \
     FLEET_DEPLOY_CHECK_UNIT_DIR="$unit_dir" \
     FLEET_DEPLOY_CHECK_INSTALL_BIN="$canon_dir/install.sh" \
     FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir" \
     FLEET_OPS_WORKSPACES_ROOT="$ws_root" \
     FLEET_HEARTBEAT_TRIAGE="$triage" \
     DEPLOY_SPY_LOG="$DEPLOY_SPY_LOG" \
       "$bin" >/dev/null 2>"$scratch/err.log"; echo $?)
[[ "$rc" == "0" ]] || fail "compare-only non-canonical should exit 0 (got $rc)"
grep -q "DEPLOY-CHECK-NONCANONICAL-UNITS" "$scratch/err.log" \
  || fail "compare-only must still LOUD DEPLOY-CHECK-NONCANONICAL-UNITS"
# Symlink must still point at the worktree (no repair in compare-only).
target=$(readlink "$unit_dir/fleet-completion-canary.service")
case "$target" in
  "$worktree_dir"*) ;;
  *) fail "compare-only must NOT repair; symlink should still point at worktree, got $target" ;;
esac
ok "compare-only mode louds but does not repair (fleet-ops#4166)"

# --- 12d. canonical unit symlink -> no LOUD --------------------------------
# A unit symlink already pointing at the canonical checkout must not trip the
# gate (no noise on the healthy path).
ln -sfn "$canon_dir/systemd/fleet-completion-canary.service" \
  "$unit_dir/fleet-completion-canary.service"
: > "$scratch/err.log"
rc=$(FLEET_OPS_CHECKOUT="$canon_dir" \
     FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
     FLEET_DEPLOY_CHECK_LOCK="$lock" \
     FLEET_DEPLOY_CHECK_NO_DEPLOY=0 \
     FLEET_DEPLOY_CHECK_UNIT_DIR="$unit_dir" \
     FLEET_DEPLOY_CHECK_INSTALL_BIN="$canon_dir/install.sh" \
     FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir" \
     FLEET_OPS_WORKSPACES_ROOT="$ws_root" \
     FLEET_HEARTBEAT_TRIAGE="$triage" \
     DEPLOY_SPY_LOG="$DEPLOY_SPY_LOG" \
       "$bin" >/dev/null 2>"$scratch/err.log"; echo $?)
[[ "$rc" == "0" ]] || fail "canonical unit symlink should exit 0 (got $rc)"
if grep -q "DEPLOY-CHECK-NONCANONICAL-UNITS" "$scratch/err.log"; then
  fail "canonical unit symlink must not loud DEPLOY-CHECK-NONCANONICAL-UNITS"
fi
ok "canonical unit symlink produces no NONCANONICAL-UNITS loud"

# --- 12e. non-fleet unit symlink is skipped --------------------------------
# A foreign/distro unit symlink that does NOT point at a systemd/ path must
# not trip the gate (only fleet-managed unit symlinks point at systemd/).
ln -sfn /usr/lib/systemd/user/dbus.service "$unit_dir/dbus.service"
: > "$scratch/err.log"
rc=$(FLEET_OPS_CHECKOUT="$canon_dir" \
     FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
     FLEET_DEPLOY_CHECK_LOCK="$lock" \
     FLEET_DEPLOY_CHECK_NO_DEPLOY=0 \
     FLEET_DEPLOY_CHECK_UNIT_DIR="$unit_dir" \
     FLEET_DEPLOY_CHECK_INSTALL_BIN="$canon_dir/install.sh" \
     FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir" \
     FLEET_OPS_WORKSPACES_ROOT="$ws_root" \
     FLEET_HEARTBEAT_TRIAGE="$triage" \
     DEPLOY_SPY_LOG="$DEPLOY_SPY_LOG" \
       "$bin" >/dev/null 2>"$scratch/err.log"; echo $?)
[[ "$rc" == "0" ]] || fail "foreign unit symlink should exit 0 (got $rc)"
if grep -q "DEPLOY-CHECK-NONCANONICAL-UNITS" "$scratch/err.log"; then
  fail "foreign (non-systemd/) unit symlink must not loud DEPLOY-CHECK-NONCANONICAL-UNITS"
fi
ok "foreign (non-systemd/) unit symlink is skipped"

# --- 12f. in-flight worktree unit (fleet-ops#5998) -> stand down the LOUD --
# The live 2026-09-12 case: a worker's unit (gh-runner@) existed ONLY in its
# worktree. The canonical checkout had no MANIFEST row for it, so the repair
# ran install.sh, rc=0'd, changed nothing, and the 2-min detect->LOUD->
# retarget(no-op) loop repeated while the worktree was alive. A LIVE
# workspaces target whose unit is not in $canon/systemd/ is the worker's
# in-flight unit (its PR is open): it must NOT trip the gate, and it
# self-heals once the unit lands in the canonical checkout.
worktree_dir_inflight="$scratch/ws/issue-fleet-ops-5935"
mkdir -p "$worktree_dir_inflight/systemd"
cat >"$worktree_dir_inflight/systemd/gh-runner@.service" <<'UNIT'
[Unit]
Description=ephemeral GitHub Actions runner (fleet-ops#5935)
UNIT
ln -sfn "$worktree_dir_inflight/systemd/gh-runner@.service" \
  "$unit_dir/gh-runner@.service"
: > "$scratch/err.log"
rc=$(FLEET_OPS_CHECKOUT="$canon_dir" \
     FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
     FLEET_DEPLOY_CHECK_LOCK="$lock" \
     FLEET_DEPLOY_CHECK_NO_DEPLOY=0 \
     FLEET_DEPLOY_CHECK_UNIT_DIR="$unit_dir" \
     FLEET_DEPLOY_CHECK_INSTALL_BIN="$canon_dir/install.sh" \
     FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir" \
     FLEET_OPS_WORKSPACES_ROOT="$ws_root" \
     FLEET_HEARTBEAT_TRIAGE="$triage" \
     DEPLOY_SPY_LOG="$DEPLOY_SPY_LOG" \
       "$bin" >/dev/null 2>"$scratch/err.log"; echo $?)
[[ "$rc" == "0" ]] || fail "in-flight worktree unit should exit 0 (got $rc)"
if grep -q "DEPLOY-CHECK-NONCANONICAL-UNITS" "$scratch/err.log"; then
  fail "in-flight worktree unit (live target, not in canonical checkout) must not loud; got: $(cat "$scratch/err.log")"
fi
target=$(readlink "$unit_dir/gh-runner@.service")
case "$target" in
  "$worktree_dir_inflight"*) ;;
  *) fail "stand-down must not touch the link; got $target" ;;
esac
ok "in-flight worktree unit stands down the NONCANONICAL-UNITS loud (fleet-ops#5998)"

# --- 12g. dangling in-flight unit link (fleet-ops#5998) -> LOUD + removal --
# Worktree died before its unit ever landed in the canonical checkout
# (the #5935 reap while #6012 was open). install.sh cannot help: no
# MANIFEST row, rc=0, link stayed, LOUD looped. The closer must remove the
# dead link, say what it did, and the flap must end on the next tick.
rm -rf "$worktree_dir_inflight"
: > "$scratch/err.log"
rc=$(FLEET_OPS_CHECKOUT="$canon_dir" \
     FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
     FLEET_DEPLOY_CHECK_LOCK="$lock" \
     FLEET_DEPLOY_CHECK_NO_DEPLOY=0 \
     FLEET_DEPLOY_CHECK_UNIT_DIR="$unit_dir" \
     FLEET_DEPLOY_CHECK_INSTALL_BIN="$canon_dir/install.sh" \
     FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir" \
     FLEET_OPS_WORKSPACES_ROOT="$ws_root" \
     FLEET_HEARTBEAT_TRIAGE="$triage" \
     DEPLOY_SPY_LOG="$DEPLOY_SPY_LOG" \
       "$bin" >/dev/null 2>"$scratch/err.log"; echo $?)
[[ "$rc" == "0" ]] || fail "dangling in-flight unit link should exit 0 (got $rc)"
grep -q "DEPLOY-CHECK-NONCANONICAL-UNITS" "$scratch/err.log" \
  || fail "dangling in-flight unit link must still loud"
grep -q "gh-runner@.service" "$scratch/err.log" \
  || fail "LOUD must name the dead unit symlink"
grep -q "1 dangling removed" "$scratch/err.log" \
  || fail "repair log must report the dangling removal, got: $(cat "$scratch/err.log")"
if [[ -L "$unit_dir/gh-runner@.service" ]] || [[ -e "$unit_dir/gh-runner@.service" ]]; then
  fail "closer must remove a dangling link whose unit is not in the canonical checkout"
fi
: > "$scratch/err.log"
rc=$(FLEET_OPS_CHECKOUT="$canon_dir" \
     FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
     FLEET_DEPLOY_CHECK_LOCK="$lock" \
     FLEET_DEPLOY_CHECK_NO_DEPLOY=0 \
     FLEET_DEPLOY_CHECK_UNIT_DIR="$unit_dir" \
     FLEET_DEPLOY_CHECK_INSTALL_BIN="$canon_dir/install.sh" \
     FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir" \
     FLEET_OPS_WORKSPACES_ROOT="$ws_root" \
     FLEET_HEARTBEAT_TRIAGE="$triage" \
     DEPLOY_SPY_LOG="$DEPLOY_SPY_LOG" \
       "$bin" >/dev/null 2>"$scratch/err.log"; echo $?)
[[ "$rc" == "0" ]] || fail "post-removal tick should exit 0 (got $rc)"
if grep -q "DEPLOY-CHECK-NONCANONICAL-UNITS" "$scratch/err.log"; then
  fail "after the closer removes the dead link the flap must end (no repeat LOUD)"
fi
ok "dangling in-flight link louds once, closer removes it, flap ends (fleet-ops#5998)"

# --- 13. install.sh repair exits non-zero but names the failing step (fleet-ops#4223)
# When install.sh refuses a live config (non-fatal), it still retargets the
# non-canonical unit symlinks. fleet-deploy-check must report which install
# step failed, not just "install.sh repair exited rc=1".
unit_dir2="$scratch/units2"
canon_dir2="$scratch/canon2"
ws_root2="$scratch/ws2"
worktree_dir2="$scratch/ws2/issue-fleet-ops-4223"
mkdir -p "$unit_dir2" "$canon_dir2/systemd" "$worktree_dir2/systemd"
cat >"$canon_dir2/systemd/fleet-completion-canary.service" <<'UNIT'
[Unit]
Description=canary
[Service]
ExecStart=/bin/true
UNIT
cat >"$worktree_dir2/systemd/fleet-completion-canary.service" <<'UNIT'
[Unit]
Description=canary
[Service]
ExecStart=/bin/true
UNIT
ln -sfn "$worktree_dir2/systemd/fleet-completion-canary.service" \
  "$unit_dir2/fleet-completion-canary.service"

cat >"$canon_dir2/install-refuse.sh" <<INSTALL
#!/usr/bin/env bash
ln -sfn "$canon_dir2/systemd/fleet-completion-canary.service" \
  "$unit_dir2/fleet-completion-canary.service"
echo "NONFATAL REFUSE: /home/nish/.pi/agent/models.json is newer than repo copy config/pi-models.json and the content differs (will not overwrite live config)"
exit 1
INSTALL
chmod +x "$canon_dir2/install-refuse.sh"

: > "$scratch/err.log"
rc=$(FLEET_OPS_CHECKOUT="$canon_dir2" \
     FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
     FLEET_DEPLOY_CHECK_LOCK="$lock" \
     FLEET_DEPLOY_CHECK_NO_DEPLOY=0 \
     FLEET_DEPLOY_CHECK_UNIT_DIR="$unit_dir2" \
     FLEET_DEPLOY_CHECK_INSTALL_BIN="$canon_dir2/install-refuse.sh" \
     FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir2" \
     FLEET_OPS_WORKSPACES_ROOT="$ws_root2" \
     FLEET_HEARTBEAT_TRIAGE="$triage" \
     DEPLOY_SPY_LOG="$DEPLOY_SPY_LOG" \
       "$bin" >/dev/null 2>"$scratch/err.log"; echo $?)
# The repair step is reported; the checker itself continues and is not fatal.
grep -q "DEPLOY-CHECK-NONCANONICAL-UNITS" "$scratch/err.log" \
  || fail "non-canonical unit symlink must loud DEPLOY-CHECK-NONCANONICAL-UNITS"
grep -q "NONFATAL REFUSE: /home/nish/.pi/agent/models.json" "$scratch/err.log" \
  || fail "LOUD line must include the install.sh refusal reason, got: $(cat "$scratch/err.log")"
target=$(readlink -f "$unit_dir2/fleet-completion-canary.service")
case "$target" in
  "$canon_dir2"*) ;;
  *) fail "repair must retarget at canonical; got $target" ;;
esac
ok "fleet-deploy-check reports the install.sh step that failed (fleet-ops#4223)"

# --- 8. fleet-ops#598: unpinned defaultBranch=master is the CI failure ------
# Drill: a bare origin whose HEAD stays on master after a main push makes
# clone + `git push origin main` fail with `src refspec main does not match
# any`. Retargeting HEAD to refs/heads/main is the guard.
repro_origin="$scratch/repro-origin"
git -c init.defaultBranch=master init -q --bare "$repro_origin"
[[ "$(git -C "$repro_origin" symbolic-ref HEAD)" == "refs/heads/master" ]] \
  || fail "repro origin HEAD should be master"
repro_co="$scratch/repro-co"
git init -q -b main "$repro_co"
git -C "$repro_co" config user.email t@t
git -C "$repro_co" config user.name t
echo one >"$repro_co/f"
git -C "$repro_co" add f
git -C "$repro_co" commit -qm one
git -C "$repro_co" remote add origin "$repro_origin"
git -C "$repro_co" push -q origin main
[[ "$(git -C "$repro_origin" symbolic-ref HEAD)" == "refs/heads/master" ]] \
  || fail "pushing main must not retarget unpinned origin HEAD"
repro_tmp="$scratch/repro-tmp"
git clone -q "$repro_origin" "$repro_tmp" 2>/dev/null || true
git -C "$repro_tmp" config user.email t@t
git -C "$repro_tmp" config user.name t
echo two >"$repro_tmp/x"
git -C "$repro_tmp" add x
git -C "$repro_tmp" commit -qm two
set +e
git -C "$repro_tmp" push -q origin main 2>"$scratch/repro-push.err"
repro_push_rc=$?
set -e
[[ "$repro_push_rc" != "0" ]] || fail "unpinned origin HEAD=master must make push origin main fail"
grep -q "src refspec main does not match any" "$scratch/repro-push.err" \
  || fail "unpinned clone must fail with src refspec main (got $(cat "$scratch/repro-push.err"))"
ok "unpinned defaultBranch=master + clone + push origin main fails as on CI"

git -C "$repro_origin" symbolic-ref HEAD refs/heads/main
repro_tmp2="$scratch/repro-tmp2"
git clone -q "$repro_origin" "$repro_tmp2"
[[ "$(git -C "$repro_tmp2" branch --show-current)" == "main" ]] \
  || fail "after symbolic-ref, clone must check out main"
git -C "$repro_tmp2" config user.email t@t
git -C "$repro_tmp2" config user.name t
echo three >"$repro_tmp2/y"
git -C "$repro_tmp2" add y
git -C "$repro_tmp2" commit -qm three
git -C "$repro_tmp2" push -q origin main
ok "symbolic-ref HEAD refs/heads/main makes clone + push origin main work"

# Live fixture this file uses must stay pinned.
[[ "$(git -C "$origin" symbolic-ref HEAD)" == "refs/heads/main" ]] \
  || fail "fixture origin HEAD must be refs/heads/main (got $(git -C "$origin" symbolic-ref HEAD))"

# Class gate: every tests/*.test.sh `git init --bare` pins init.defaultBranch
# on the same line (`=main` in fixtures, `=master` only in this CI repro).
unpinned=""
for f in "$here"/*.test.sh; do
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    stripped="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$stripped" || "$stripped" == \#* ]] && continue
    [[ "$stripped" == git* && "$stripped" == *--bare* ]] || continue
    [[ "$stripped" =~ [[:space:]]init[[:space:]] ]] || continue
    if [[ "$stripped" != *init.defaultBranch=* ]]; then
      unpinned+="$(basename "$f"):${lineno}:${stripped}"$'\n'
    fi
  done <"$f"
done
[[ -z "$unpinned" ]] || fail "git init --bare must pin init.defaultBranch on the same line (fleet-ops#598):"$'\n'"$unpinned"
ok "every tests/ git init --bare pins init.defaultBranch"

# Prove the class gate REJECTS an unpinned line (empty allowlist).
gate_hit=0
gate_line='git init -q --bare "$origin"'
if [[ "$gate_line" == git* && "$gate_line" == *--bare* && "$gate_line" =~ [[:space:]]init[[:space:]] && "$gate_line" != *init.defaultBranch=* ]]; then
  gate_hit=1
fi
[[ "$gate_hit" -eq 1 ]] || fail "class gate must reject unpinned git init --bare"
ok "class gate rejects unpinned git init --bare"

# --- 11. foreign origin fetch URL refuses before fetch/deploy ----------------
# fleet-ops#5016, live 2026-09-10T16:16Z: this clone's origin FETCH URL was
# https://github.com/Nishfleet/0509.git (pushurl correctly fleet-ops), so
# `origin/main` tracked 0509's main, this check saw a "move" and invoked the
# sanctioned deploy, and the deploy reset the live install source to 0509's
# tree. A foreign fetch URL must refuse before the fetch, with the checkout
# untouched and the deploy NOT invoked.
advance_origin "remote-foreign"
ref_before=$(git -C "$checkout" rev-parse refs/remotes/origin/main)
head_before_foreign=$(git -C "$checkout" rev-parse HEAD)
remote_before=$(git -C "$checkout" remote get-url origin)
git -C "$checkout" remote set-url origin "https://github.com/Nishfleet/0509.git"
git -C "$checkout" remote add real "$origin"
n_before=$(grep -c "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || true)
repair_prom="$scratch/repair.prom"
repair_hist="$scratch/repair.hist"
: >"$repair_hist"
set +e
rc=$(FLEET_OPS_CHECKOUT="$checkout" \
  FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
  FLEET_DEPLOY_CHECK_LOCK="$lock" \
  FLEET_DEPLOY_CHECK_NO_DEPLOY=0 \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
  AGENT_STATE="$scratch/as" \
  FLEET_DEPLOY_ORIGIN_REPAIR_PROM="$repair_prom" \
  FLEET_DEPLOY_ORIGIN_REPAIR_LOG="$repair_hist" \
    "$bin" >/dev/null 2>"$scratch/err-foreign.log"; echo $?)
set -e
[[ "$rc" == "0" ]] || fail "foreign origin must be repaired and the tick must proceed (got $rc)"
grep -q "DEPLOY-CHECK-ORIGIN-REMOTE" "$scratch/err-foreign.log" \
  || fail "missing DEPLOY-CHECK-ORIGIN-REMOTE loud line"
grep -q "repaired" "$scratch/err-foreign.log" \
  || fail "the loud line must say repaired, not refusing"
grep -q "https://github.com/Nishfleet/0509.git" "$scratch/err-foreign.log" \
  || fail "repair must name the offending origin URL (was ...)"
grep -q "fleet-ops#5301" "$scratch/err-foreign.log" \
  || fail "repair must name fleet-ops#5301"
[[ "$(git -C "$checkout" remote get-url origin)" == "$origin" ]] \
  || fail "origin fetch URL must be set back to the expected URL"
[[ -z "$(git -C "$checkout" remote | grep -x real)" ]] \
  || fail "the extra remote carrying the expected URL under another name must be removed"
grep -q 'fleet_deploy_origin_remote_repaired_total 1' "$repair_prom" \
  || fail "repair counter must be written to the .prom"
n_after=$(grep -c "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" || true)
[[ "$n_after" -ge "$n_before" ]] || fail "tick must proceed after the repair"
ok "foreign origin fetch URL -> repaired in the same tick, extra remote dropped, counter incremented, tick proceeds (fleet-ops#5301)"

# A third repair within 24h trips the alert (fleet-ops#5301).
now_s=$(date -u +%s)
printf '%s\n%s\n%s\n' "$((now_s - 3600))" "$((now_s - 7200))" "$((now_s - 10800))" >"$repair_hist"
repairs_in_24h=$(awk -v cutoff=$((now_s - 86400)) '$1 >= cutoff' "$repair_hist" | wc -l)
[[ "$repairs_in_24h" -eq 3 ]] || fail "test fixture should hold 3 repairs in 24h (got $repairs_in_24h)"
git -C "$checkout" remote set-url origin "https://github.com/Nishfleet/0509.git"
rc=$(FLEET_OPS_CHECKOUT="$checkout" \
  FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
  FLEET_DEPLOY_CHECK_LOCK="$lock" \
  FLEET_DEPLOY_CHECK_NO_DEPLOY=1 \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
  AGENT_STATE="$scratch/as" \
  FLEET_DEPLOY_ORIGIN_REPAIR_PROM="$repair_prom" \
  FLEET_DEPLOY_ORIGIN_REPAIR_LOG="$repair_hist" \
    "$bin" >/dev/null 2>"$scratch/err-alert.log"; echo $?)
[[ "$rc" == "0" ]] || fail "alert tick must still proceed (got $rc)"
grep -q "repaired 4x in 24h" "$scratch/err-alert.log" \
  || fail "a >2-repairs-in-24h rate must trip the alert (got: $(cat "$scratch/err-alert.log"))"
ok ">2 origin repairs in 24h trips the alert while the tick still proceeds (fleet-ops#5301)"

# The tripwire snapshots remote config and diffs on change (fleet-ops#5301).
tripwire_snap="$scratch/as/deploy-clone-remotes.txt"
[[ -s "$tripwire_snap" ]] || fail "tripwire must snapshot the clone's remote config"
git -C "$checkout" remote add sneaky "$origin"
rc=$(FLEET_OPS_CHECKOUT="$checkout" \
  FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
  FLEET_DEPLOY_CHECK_LOCK="$lock" \
  FLEET_DEPLOY_CHECK_NO_DEPLOY=1 \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
  AGENT_STATE="$scratch/as" \
  FLEET_DEPLOY_ORIGIN_REPAIR_PROM="$repair_prom" \
  FLEET_DEPLOY_ORIGIN_REPAIR_LOG="$repair_hist" \
    "$bin" >/dev/null 2>"$scratch/err-tripwire.log"; echo $?)
[[ "$rc" == "0" ]] || fail "tripwire tick must exit 0 (got $rc)"
grep -q "DEPLOY-CHECK-ORIGIN-TRIPWIRE" "$scratch/err-tripwire.log" \
  || fail "a remote-config diff must trip the tripwire loud line"
[[ -z "$(git -C "$checkout" remote | grep -x sneaky)" ]] \
  || fail "an extra remote carrying the expected URL must be removed even on a non-foreign origin tick"
[[ "$(git -C "$checkout" remote get-url origin)" == "$origin" ]] \
  || fail "a same-URL extra remote must not rewrite origin"
ok "tripwire diffs remote config across ticks and the repair drops the duplicate remote (fleet-ops#5301)"
git -C "$checkout" remote set-url origin "$remote_before"

# Correct fetch URL: unchanged behaviour resumes (covered by the tripwire
# tick above: correct URL -> no ORIGIN-REMOTE line at all).
[[ -z "$(grep 'ORIGIN-REMOTE' "$scratch/err-tripwire.log" | grep -v TRIPWIRE)" ]] \
  || fail "correct origin URL must not trip the repair"
rc=$(run_bin 1)
[[ "$rc" == "0" ]] || fail "correct origin URL must behave as before (got $rc)"
grep -q "compare-only" "$scratch/err.log" || fail "correct origin URL must reach the compare-only path"
ok "correct origin fetch URL -> unchanged behaviour"

# --- 14. deploy-clone drift gauge + LOUD line (fleet-ops#5786) ---------------
# The 2026-09-12 false-LIVE incident: an alert-repair worker left the deploy
# clone on its fix branch and reported the change "Live on this host" while
# the PR was still open with auto-merge off. Every tick must now write the
# fleet_deploy_clone_off_main{repo} gauge (1 = off main or dirty, 0 = clean
# main) and LOUD DEPLOY-CHECK-OFF-MAIN whenever the clone is off main — and
# DeployCloneOffMain pages the repair lane after 15 min of drift.
clone_prom="$scratch/fleet-deploy-clone.prom"
run_bin_prom() {
  local no_deploy="${1:-0}"
  set +e
  FLEET_OPS_CHECKOUT="$checkout" \
  FLEET_OPS_DEPLOY_BIN="$deploy_spy" \
  FLEET_DEPLOY_CHECK_LOCK="$lock" \
  FLEET_DEPLOY_CHECK_NO_DEPLOY="$no_deploy" \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
  FLEET_DEPLOY_CLONE_PROM="$clone_prom" \
  FLEET_DEPLOY_CLONE_REPO="fleet-ops" \
  DEPLOY_SPY_LOG="$DEPLOY_SPY_LOG" \
  DEPLOY_SPY_RC="${2:-0}" \
    "$bin" >/dev/null 2>"$scratch/err-prom.log"
  local rc=$?
  set -e
  echo "$rc"
}

# Drill: check the clone out on a branch -> gauge 1 + loud + deploy invoked.
git -C "$checkout" checkout -q -b drift-drill
: > "$DEPLOY_SPY_LOG"
rc=$(run_bin_prom 0)
[[ "$rc" == "0" ]] || fail "off-main drift tick must exit 0 (got $rc)"
grep -q 'fleet_deploy_clone_off_main{repo="fleet-ops"} 1' "$clone_prom" \
  || fail "off-main clone must write gauge 1: $(cat "$clone_prom")"
grep -q "DEPLOY-CHECK-OFF-MAIN" "$scratch/err-prom.log" \
  || fail "off-main clone must loud DEPLOY-CHECK-OFF-MAIN: $(cat "$scratch/err-prom.log")"
grep -q "drift-drill" "$scratch/err-prom.log" \
  || fail "OFF-MAIN loud must name the offending branch"
grep -q "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" \
  || fail "off-main drift must invoke the sanctioned deploy to converge"
ok "drift drill: clone on a branch -> gauge 1 + DEPLOY-CHECK-OFF-MAIN + deploy invoked"

# Detached HEAD is the same drift class — a clone parked detached cannot
# converge cleanly either.
git -C "$checkout" checkout -q --detach HEAD
: > "$DEPLOY_SPY_LOG"
rc=$(run_bin_prom 0)
[[ "$rc" == "0" ]] || fail "detached drift tick must exit 0 (got $rc)"
grep -q 'fleet_deploy_clone_off_main{repo="fleet-ops"} 1' "$clone_prom" \
  || fail "detached clone must write gauge 1"
grep -q "DEPLOY-CHECK-OFF-MAIN" "$scratch/err-prom.log" \
  || fail "detached clone must loud DEPLOY-CHECK-OFF-MAIN"
grep -q "branch=detached" "$scratch/err-prom.log" \
  || fail "detached drift must say branch=detached"
grep -q "DEPLOY-INVOKED" "$DEPLOY_SPY_LOG" \
  || fail "detached drift must invoke the sanctioned deploy to converge"
ok "detached HEAD counts as off-main drift (gauge 1 + loud + deploy)"

# Back on clean main -> gauge clears to 0 on the next tick.
git -C "$checkout" checkout -q main
git -C "$checkout" reset -q --hard origin/main
rc=$(run_bin_prom 0)
[[ "$rc" == "0" ]] || fail "converged tick must exit 0 (got $rc)"
grep -q 'fleet_deploy_clone_off_main{repo="fleet-ops"} 0' "$clone_prom" \
  || fail "clean main must clear the gauge to 0: $(cat "$clone_prom")"
if grep -q "DEPLOY-CHECK-OFF-MAIN" "$scratch/err-prom.log"; then
  fail "converged clone must not loud DEPLOY-CHECK-OFF-MAIN"
fi
ok "back on clean main -> gauge clears to 0, no OFF-MAIN loud"

# Dirty alone is drift too.
printf 'drift-wip\n' >> "$checkout/f"
rc=$(run_bin_prom 1)
[[ "$rc" == "0" ]] || fail "dirty drift tick must exit 0 (got $rc)"
grep -q 'fleet_deploy_clone_off_main{repo="fleet-ops"} 1' "$clone_prom" \
  || fail "dirty clone must write gauge 1"
git -C "$checkout" checkout -q -- f
rc=$(run_bin_prom 1)
grep -q 'fleet_deploy_clone_off_main{repo="fleet-ops"} 0' "$clone_prom" \
  || fail "cleaned clone must clear the gauge to 0"
ok "dirty clone -> gauge 1; cleaned -> gauge 0"

# A missing checkout is the extreme drift — gauge 1 so the alert still fires.
rm -f "$clone_prom"
rc=$(FLEET_OPS_CHECKOUT="$scratch/nonexistent" \
     FLEET_HEARTBEAT_TRIAGE="$triage" \
     FLEET_DEPLOY_CLONE_PROM="$clone_prom" \
     FLEET_DEPLOY_CLONE_REPO="fleet-ops" \
     "$bin" >/dev/null 2>"$scratch/err-missing.log"; echo $?)
[[ "$rc" == "0" ]] || fail "missing checkout must exit 0 (got $rc)"
grep -q 'fleet_deploy_clone_off_main{repo="fleet-ops"} 1' "$clone_prom" \
  || fail "missing checkout must write gauge 1"
ok "missing checkout -> gauge 1 (extreme drift still pages)"

# --- 14b. DeployCloneOffMain alert rule (fleet-ops#5786) ----------------------
# promtool drill: the gauge at 1 fires after 15 min and clears at 0; the
# repair lane must see severity=critical + service=fleet.
if command -v promtool >/dev/null 2>&1; then
  python3 - "$repo_root/config/fleet_rules.yml" <<'PY'
import sys, yaml
rules = yaml.safe_load(open(sys.argv[1]))
alerts = {r["alert"]: r for g in rules["groups"] for r in g["rules"]
          if "alert" in r}
a = alerts.get("DeployCloneOffMain") or sys.exit(
    "FAIL: DeployCloneOffMain missing from fleet_rules.yml")
assert a["labels"]["severity"] == "critical", a["labels"]
assert a["labels"]["service"] == "fleet", a["labels"]
assert a.get("for") == "15m", a.get("for")
assert "fleet_deploy_clone_off_main" in a["expr"], a["expr"]
assert "fleet-ops#5786" in a["annotations"]["description"], a["annotations"]
print("OK: DeployCloneOffMain rule shape — critical/fleet, 15m, cites #5786")
PY
  # QUOTED heredoc on purpose: this body embeds the rule text with backticked
  # converger commands. Under an unquoted <<YQ those backticks are bash command
  # substitution — the first live run executed `git -C <deploy-clone> checkout
  # main && git reset --hard origin/main`, and the un-prefixed `git reset` ran
  # in the INVOKING worktree and reset its branch to origin/main. Quoted heredoc
  # + placeholder keeps the drill inert; sed injects the repo root after.
  cat >"$scratch/offmain.test.yml" <<'YQ'
rule_files:
  - __REPO_ROOT__/config/fleet_rules.yml
evaluation_interval: 1m
tests:
  - interval: 1m
    name: deploy clone on a worker branch — alert silent before 15m, fires after
    input_series:
      - series: 'fleet_deploy_clone_off_main{repo="fleet-ops"}'
        values: '1x40'
    alert_rule_test:
      - eval_time: 10m
        alertname: DeployCloneOffMain
        exp_alerts: []
      - eval_time: 20m
        alertname: DeployCloneOffMain
        exp_alerts:
          - exp_labels:
              severity: critical
              service: fleet
              repo: "fleet-ops"
            exp_annotations:
              summary: 'fleet-ops deploy clone off main or dirty for 15+ minutes (fleet-ops#5786)'
              description: 'fleet_deploy_clone_off_main{repo="fleet-ops"} has been 1 for 15+ minutes: the deploy clone is on a non-main branch, detached, or dirty — the live install source is not clean origin/main, so ''LIVE on this host'' may be riding unmerged code. Repair: name the writer first (journalctl --user -u fleet-deploy-check.service for DEPLOY-CHECK-OFF-MAIN / DEPLOY-CHECK-DIRTY-CLONE; ls of /home/nish/workspaces/agent-worktrees for the branch owner). Salvage the branch''s diff into the writer''s claim worktree if it is not already in a PR, then converge the clone to clean origin/main (bin/fleet-ops-deploy, or `git -C /home/nish/workspaces/tooling/fleet-ops-deploy-clone checkout main && git reset --hard origin/main`). Done means the gauge reads 0 next tick. Never claim LIVE for a change still on a branch — the packet-verdict checker rejects the deliverable (fleet-ops#5786).'

  - interval: 1m
    name: clone back on clean main — alert stays silent
    input_series:
      - series: 'fleet_deploy_clone_off_main{repo="fleet-ops"}'
        values: '0x40'
    alert_rule_test:
      - eval_time: 20m
        alertname: DeployCloneOffMain
        exp_alerts: []
YQ
  sed -i "s|__REPO_ROOT__|$repo_root|g" "$scratch/offmain.test.yml"
  promtool test rules "$scratch/offmain.test.yml" >/dev/null \
    || fail "promtool DeployCloneOffMain drill failed"
  ok "promtool: DeployCloneOffMain fires on 15m drift, silent on clean main"
else
  echo "SKIP: promtool not installed — DeployCloneOffMain rule drill runs where promtool exists (VPS P14)"
fi

echo "OK: fleet-deploy-check: unchanged/moved/compare-only/deploy-fail/yield/lock/defaultBranch/drift-gauge"

# PR #4856: host deploy-audit-log-outside-clone so P14 listing-gate
# counts it (ci.yml edit needs workflow scope; host from this listed suite).
bash "$here/deploy-audit-log-outside-clone.test.sh" || fail "deploy-audit-log-outside-clone tests failed"
