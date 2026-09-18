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
#   9. the helper supports --apply and --check.
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

# The drift canary (bin/fleet-ops-drift.py) that used to invoke this helper
# with --apply was deleted 2026-09-18 with the rest of the copy-then-detect-
# drift deploy cluster: live paths are symlinks into the repo, so there is no
# drift to detect. The helper stays as a hand-run one-shot; its behaviour is
# what the scenarios below lock.
grep -q -- '--apply' "$bin" || fail "helper must support --apply"
grep -q -- '--check' "$bin" || fail "helper must support --check"
ok "helper supports --apply and --check"

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

echo "OK: fleet-ops#410 retarget helper scenarios pass"

echo "OK: fleet-ops#410 retarget helper refuses while worktrees remain, applies when they are gone"
exit 0
