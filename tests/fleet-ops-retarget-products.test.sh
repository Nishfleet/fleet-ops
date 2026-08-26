#!/usr/bin/env bash
# tests/fleet-ops-retarget-products.test.sh
#
# fleet-ops#410: retarget products/fleet-ops at the deploy-clone only after
# linked worktrees leave the pre-rewrite parent. Proves, offline:
#   1. --apply refuses while a worktree is attached (symlink unchanged).
#   2. --apply retargets when no worktrees remain; parent dir is kept.
#   3. already-canonical is a no-op.
#   4. a real directory at products/fleet-ops is refused (not ln -sfn'd into).
#   5. absent link is not a failure.
#   6. --check never mutates, even when retarget is safe.
#   7. the script never deletes the worktree parent.
#   8. worker.md uses the deploy-clone as the fleet-ops git parent.
#   9. drift canary calls --apply and auto-files the #410 marker on error.
#  10. MANIFEST installs the helper.
#
# Overlay FLEET_OPS_WORKSPACES_ROOT so this never touches the live box.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-ops-retarget-products"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
grep -q 'fleet-ops#410' "$bin" || fail "helper must cite fleet-ops#410"
if grep -E -q '\brm[[:space:]]+(-[a-zA-Z]*f|--force)' "$bin"; then
  fail "helper must not rm -f the worktree parent"
fi
ok "helper exists, cites #410, and does not rm -f"

grep -q 'check_products_symlink' "$repo_root/bin/fleet-ops-drift.py" \
  || fail "drift canary must call check_products_symlink"
grep -q 'products-symlink-stale: fleet-ops#410' "$repo_root/bin/fleet-ops-drift.py" \
  || fail "drift canary must auto-file with the #410 marker"
grep -q -- '--apply' "$repo_root/bin/fleet-ops-drift.py" \
  || fail "drift canary must invoke the helper with --apply"
ok "drift canary wires --apply + #410 auto-file"

grep -Fxq "bin/fleet-ops-retarget-products /home/nish/.local/bin/fleet-ops-retarget-products" \
  "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-ops-retarget-products"
ok "MANIFEST installs the helper"

grep -q 'tooling/fleet-ops-deploy-clone' "$repo_root/prompts/worker.md" \
  || fail "worker.md must name the deploy-clone as the fleet-ops git parent"
grep -q 'fleet-ops#410' "$repo_root/prompts/worker.md" \
  || fail "worker.md must cite fleet-ops#410 for the fleet-ops checkout"
ok "worker.md uses deploy-clone for fleet-ops worktrees"

scratch="$(mktemp -d -t fleet-ops-retarget.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

ws="$scratch/workspaces"
parent="$ws/tooling/fleet-ops"
canon="$ws/tooling/fleet-ops-deploy-clone"
products="$ws/products/fleet-ops"
wt="$ws/agent-worktrees/issue-fleet-ops-410-test"
mkdir -p "$parent" "$canon" "$ws/products" "$ws/agent-worktrees"
printf 'canon\n' >"$canon/README"
printf 'parent\n' >"$parent/README"

git -C "$parent" init -q
git -C "$parent" config user.email "test@example.com"
git -C "$parent" config user.name "test"
git -C "$parent" add README
git -C "$parent" commit -q -m "parent"
git -C "$parent" worktree add -q "$wt"

ln -sfn "$parent" "$products"

export FLEET_OPS_WORKSPACES_ROOT="$ws"
export FLEET_OPS_CANONICAL_CHECKOUT="$canon"
export FLEET_OPS_PRODUCTS_LINK="$products"
export FLEET_OPS_WORKTREE_PARENT="$parent"

# --- 1. attached worktree: refuse ------------------------------------------
set +e
out=$("$bin" --apply 2>&1)
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "scenario1: expected rc=2, got $rc out=$out"
[[ "$out" == *"PRODUCTS-STALE-WAITING"* ]] || fail "scenario1: expected WAITING, got: $out"
[[ "$(readlink -f "$products")" = "$(readlink -f "$parent")" ]] \
  || fail "scenario1: --apply retargeted while a worktree was attached"
[[ -d "$parent" ]] || fail "scenario1: parent directory was removed"
ok "scenario1: --apply refuses while a worktree is attached"

# --- 2. no worktrees: retarget, keep parent --------------------------------
git -C "$parent" worktree remove --force "$wt"
set +e
out=$("$bin" --apply 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario2: expected rc=0, got $rc out=$out"
[[ "$out" == *"PRODUCTS-RETARGETED"* ]] || fail "scenario2: expected RETARGETED, got: $out"
[[ "$(readlink -f "$products")" = "$(readlink -f "$canon")" ]] \
  || fail "scenario2: products now points at $(readlink -f "$products"), want canon"
[[ -d "$parent" ]] || fail "scenario2: parent directory was removed"
[[ -f "$parent/README" ]] || fail "scenario2: parent contents were deleted"
ok "scenario2: --apply retargets when no worktrees remain and keeps the parent"

# --- 3. already canonical --------------------------------------------------
set +e
out=$("$bin" --apply 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario3: expected rc=0, got $rc out=$out"
[[ "$out" == *"PRODUCTS-CANONICAL"* ]] || fail "scenario3: expected CANONICAL, got: $out"
ok "scenario3: already-canonical is a no-op"

# --- 4. real directory refused ---------------------------------------------
rm -f "$products"
mkdir -p "$products"
printf 'not-a-link\n' >"$products/KEEP"
set +e
out=$("$bin" --apply 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "scenario4: expected rc=1, got $rc out=$out"
[[ "$out" == *"PRODUCTS-REFUSE"* ]] || fail "scenario4: expected REFUSE, got: $out"
[[ -f "$products/KEEP" ]] || fail "scenario4: directory contents were destroyed"
ok "scenario4: a real directory at products/fleet-ops is refused"

# --- 5. absent link --------------------------------------------------------
rm -rf "$products"
set +e
out=$("$bin" --apply 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario5: expected rc=0, got $rc out=$out"
[[ "$out" == *"PRODUCTS-LINK-ABSENT"* ]] || fail "scenario5: expected ABSENT, got: $out"
ok "scenario5: absent link is not a failure"

# --- 6. --check never mutates when retarget is safe ------------------------
ln -sfn "$parent" "$products"
# parent has no attached worktrees (removed in scenario 2)
set +e
out=$("$bin" --check 2>&1)
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "scenario6: --check would-retarget should rc=1, got $rc out=$out"
[[ "$out" == *"WOULD-RETARGET"* ]] || fail "scenario6: expected WOULD-RETARGET, got: $out"
[[ "$(readlink -f "$products")" = "$(readlink -f "$parent")" ]] \
  || fail "scenario6: --check mutated the symlink"
ok "scenario6: --check never mutates"

# --- 9b. drift canary: waiting is not DRIFT-PRODUCTS-SYMLINK ---------------
# Rebuild an attached worktree so the helper exits 2. Drift must not fail
# on that class (it is the expected drain state).
git -C "$parent" worktree add -q "$wt"
ln -sfn "$parent" "$products"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*) echo '[]'; exit 0 ;;
  *"issue create"*) echo "https://github.com/Nishfleet/fleet-ops/issues/4100"; exit 0 ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
: >"$scratch/gh.log"

# Minimal git checkout so find_checkout succeeds; other checks may fail
# after the products gate. We only assert the products gate's own tag.
dummy="$scratch/dummy-checkout"
mkdir -p "$dummy"
git -C "$dummy" init -q
git -C "$dummy" config user.email "test@example.com"
git -C "$dummy" config user.name "test"
git -C "$dummy" commit -q --allow-empty -m "dummy"
printf 'bin/x /tmp/x\n' >"$dummy/MANIFEST"

set +e
drift_out=$(
  HOME="$scratch/home" \
  FLEET_OPS_CHECKOUT="$dummy" \
  FLEET_OPS_WORKSPACES_ROOT="$ws" \
  FLEET_OPS_CANONICAL_CHECKOUT="$canon" \
  FLEET_OPS_PRODUCTS_LINK="$products" \
  FLEET_OPS_WORKTREE_PARENT="$parent" \
  FLEET_OPS_RETARGET_BIN="$bin" \
  FLEET_OPS_SKIP_FETCH=1 \
  FLEET_OPS_DRIFT_FILE=1 \
  FLEET_OPS_DRIFT_REPO="Nishfleet/fleet-ops" \
  FLEET_OPS_TRIAGE="$scratch/triage.md" \
  FLEET_OPS_AUDIT_LOG="$scratch/audit.log" \
  GH="$gh_fake" \
  GH_LOG="$scratch/gh.log" \
  python3 "$repo_root/bin/fleet-ops-drift.py" 2>&1
)
drift_rc=$?
set -e
[[ "$drift_out" == *"PRODUCTS-STALE-WAITING"* ]] \
  || fail "scenario9b: drift must log WAITING, got: $drift_out"
[[ "$drift_out" != *"DRIFT-PRODUCTS-SYMLINK"* ]] \
  || fail "scenario9b: waiting must not be DRIFT-PRODUCTS-SYMLINK: $drift_out"
grep -q 'issue create' "$scratch/gh.log" \
  && fail "scenario9b: waiting must not auto-file (log=$(cat "$scratch/gh.log"))"
ok "scenario9b: drift waiting is not a canary failure and does not auto-file"

# Directory refuse must fail loud + auto-file.
git -C "$parent" worktree remove --force "$wt" || true
rm -f "$products"
mkdir -p "$products"
: >"$scratch/gh.log"
: >"$scratch/triage.md"
set +e
drift_out=$(
  HOME="$scratch/home" \
  FLEET_OPS_CHECKOUT="$dummy" \
  FLEET_OPS_WORKSPACES_ROOT="$ws" \
  FLEET_OPS_CANONICAL_CHECKOUT="$canon" \
  FLEET_OPS_PRODUCTS_LINK="$products" \
  FLEET_OPS_WORKTREE_PARENT="$parent" \
  FLEET_OPS_RETARGET_BIN="$bin" \
  FLEET_OPS_SKIP_FETCH=1 \
  FLEET_OPS_DRIFT_FILE=1 \
  FLEET_OPS_DRIFT_REPO="Nishfleet/fleet-ops" \
  FLEET_OPS_TRIAGE="$scratch/triage.md" \
  FLEET_OPS_AUDIT_LOG="$scratch/audit.log" \
  GH="$gh_fake" \
  GH_LOG="$scratch/gh.log" \
  python3 "$repo_root/bin/fleet-ops-drift.py" 2>&1
)
drift_rc=$?
set -e
[[ "$drift_rc" -eq 1 ]] || fail "scenario9c: refuse should fail canary rc=1, got $drift_rc out=$drift_out"
[[ "$drift_out" == *"DRIFT-PRODUCTS-SYMLINK"* ]] \
  || fail "scenario9c: expected DRIFT-PRODUCTS-SYMLINK, got: $drift_out"
grep -q 'issue create' "$scratch/gh.log" \
  || fail "scenario9c: must auto-file (log=$(cat "$scratch/gh.log"))"
ok "scenario9c: drift auto-files when products/fleet-ops is not a symlink"

echo "OK: fleet-ops#410 retarget helper refuses while worktrees remain, applies when they are gone, and the canary auto-files the class"
exit 0
