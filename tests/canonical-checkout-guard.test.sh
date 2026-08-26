#!/usr/bin/env bash
# tests/canonical-checkout-guard.test.sh
#
# fleet-ops#176: live install must come from the canonical deploy checkout,
# never a hotfix / issue worktree / worktree-parent. Proves, offline:
#   1. install.sh refuses a workspaces hotfix tree.
#   2. install.sh refuses an issue worktree.
#   3. install.sh --check from a hotfix still runs (auditors need DIFF).
#   4. install.sh from the canonical overlay path succeeds.
#   5. FLEET_OPS_ALLOW_NONCANONICAL=1 overrides the refuse.
#   6. fleet-ops-deploy refuses a non-canonical FLEET_OPS_CHECKOUT.
#   7. drift canary DRIFT-SOURCE + auto-files when checkout is a hotfix.
#   8. drift canary WRONG-SYMLINK + auto-files when a dest points at a hotfix.
#   9. Dedup: an open issue already carrying the marker -> no second create.
#
# Overlay FLEET_OPS_WORKSPACES_ROOT so this never touches the live box.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$repo_root/install.sh" ]] || fail "missing install.sh"
[[ -x "$repo_root/bin/fleet-ops-deploy" ]] || fail "missing bin/fleet-ops-deploy"
[[ -f "$repo_root/bin/fleet-ops-drift.py" ]] || fail "missing bin/fleet-ops-drift.py"
grep -q 'refuse_noncanonical_install' "$repo_root/install.sh" \
    || fail "install.sh must define refuse_noncanonical_install"
grep -q 'DEPLOY-NONCANONICAL' "$repo_root/bin/fleet-ops-deploy" \
    || fail "fleet-ops-deploy must emit DEPLOY-NONCANONICAL"
grep -q 'DRIFT-SOURCE' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must emit DRIFT-SOURCE"
grep -q 'gh issue create' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must auto-file"

scratch="$(mktemp -d -t canonical-checkout-guard.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"

ws="$scratch/workspaces"
canon="$ws/tooling/fleet-ops-deploy-clone"
hotfix="$ws/tooling/fleet-ops-deploy"
issue_wt="$ws/agent-worktrees/issue-fleet-ops-176"
mkdir -p "$canon/bin" "$hotfix/bin" "$issue_wt/bin" "$canon/systemd" "$hotfix/systemd"

cp "$repo_root/install.sh" "$canon/install.sh"
cp "$repo_root/install.sh" "$hotfix/install.sh"
cp "$repo_root/install.sh" "$issue_wt/install.sh"
cp "$repo_root/bin/fleet-ops-deploy" "$canon/bin/fleet-ops-deploy"
cp "$repo_root/bin/fleet-ops-deploy" "$hotfix/bin/fleet-ops-deploy"
chmod +x "$canon/install.sh" "$hotfix/install.sh" "$issue_wt/install.sh" \
         "$canon/bin/fleet-ops-deploy" "$hotfix/bin/fleet-ops-deploy"

printf 'canonical\n' >"$canon/bin/demo-script"
printf 'hotfix\n' >"$hotfix/bin/demo-script"
printf 'issue\n' >"$issue_wt/bin/demo-script"

demo_dest="$HOME/.local/bin/demo-script"
cat >"$canon/MANIFEST" <<MANIFEST
bin/demo-script $demo_dest
MANIFEST
cp "$canon/MANIFEST" "$hotfix/MANIFEST"
cp "$canon/MANIFEST" "$issue_wt/MANIFEST"

systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--user" ]; then
  shift
fi
case "${1:-}" in
  daemon-reload|enable|start) exit 0 ;;
  is-enabled) exit 1 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$systemctl_fake"

export FLEET_OPS_WORKSPACES_ROOT="$ws"
export FLEET_OPS_CANONICAL_CHECKOUT="$canon"
export PATH="$scratch:$PATH"

# --- 1. hotfix install refuses ----------------------------------------------
set +e
hot_out=$(SYSTEMCTL="$systemctl_fake" "$hotfix/install.sh" 2>&1)
hot_rc=$?
set -e
[[ "$hot_rc" -eq 1 ]] || fail "scenario1: hotfix install should rc=1, got $hot_rc out=$hot_out"
[[ "$hot_out" == *"REFUSE:"* ]] || fail "scenario1: expected REFUSE, got: $hot_out"
[[ "$hot_out" == *"fleet-ops#176"* ]] || fail "scenario1: refuse must cite fleet-ops#176"
[[ ! -e "$demo_dest" ]] || fail "scenario1: hotfix install retargeted live dest"
ok "scenario1: install.sh refuses a workspaces hotfix tree"

# --- 2. issue worktree install refuses --------------------------------------
set +e
iss_out=$(SYSTEMCTL="$systemctl_fake" "$issue_wt/install.sh" 2>&1)
iss_rc=$?
set -e
[[ "$iss_rc" -eq 1 ]] || fail "scenario2: issue-worktree install should rc=1, got $iss_rc out=$iss_out"
[[ "$iss_out" == *"REFUSE:"* ]] || fail "scenario2: expected REFUSE, got: $iss_out"
[[ ! -e "$demo_dest" ]] || fail "scenario2: issue-worktree install retargeted live dest"
ok "scenario2: install.sh refuses an issue worktree"

# --- 3. --check from hotfix still runs --------------------------------------
set +e
chk_out=$(SYSTEMCTL="$systemctl_fake" "$hotfix/install.sh" --check 2>&1)
chk_rc=$?
set -e
[[ "$chk_out" != *"REFUSE:"* ]] || fail "scenario3: --check must not refuse, got: $chk_out"
[[ "$chk_rc" -eq 1 ]] || fail "scenario3: --check should report missing dest (rc=1), got $chk_rc out=$chk_out"
[[ "$chk_out" == *"DIFF:"* ]] || fail "scenario3: --check should emit DIFF, got: $chk_out"
ok "scenario3: install.sh --check from a hotfix still reports DIFF"

# --- 4. canonical overlay install succeeds ----------------------------------
SYSTEMCTL="$systemctl_fake" "$canon/install.sh" >/dev/null 2>&1 \
    || fail "scenario4: canonical install.sh failed"
[[ -L "$demo_dest" ]] || fail "scenario4: dest is not a symlink"
[[ "$(readlink -f "$demo_dest")" = "$(readlink -f "$canon/bin/demo-script")" ]] \
    || fail "scenario4: dest points at $(readlink -f "$demo_dest"), want canonical"
ok "scenario4: install.sh from the canonical overlay path succeeds"

# --- 5. ALLOW override lets a hotfix install --------------------------------
rm -f "$demo_dest"
SYSTEMCTL="$systemctl_fake" FLEET_OPS_ALLOW_NONCANONICAL=1 "$hotfix/install.sh" >/dev/null 2>&1 \
    || fail "scenario5: ALLOW=1 hotfix install failed"
[[ "$(readlink -f "$demo_dest")" = "$(readlink -f "$hotfix/bin/demo-script")" ]] \
    || fail "scenario5: ALLOW=1 did not install from hotfix"
ok "scenario5: FLEET_OPS_ALLOW_NONCANONICAL=1 overrides the refuse"
rm -f "$demo_dest"
SYSTEMCTL="$systemctl_fake" "$canon/install.sh" >/dev/null 2>&1 || true

# --- 6. fleet-ops-deploy refuses hotfix checkout ----------------------------
git -C "$hotfix" init -q
git -C "$hotfix" config user.email "test@example.com"
git -C "$hotfix" config user.name "test"
git -C "$hotfix" add -A
git -C "$hotfix" commit -q -m "hotfix" --allow-empty
set +e
dep_out=$(
  FLEET_OPS_CHECKOUT="$hotfix" \
  FLEET_OPS_TRIAGE="$scratch/triage.md" \
  FLEET_OPS_DEPLOY_AUDIT_LOG="$scratch/deploy-audit.log" \
  "$hotfix/bin/fleet-ops-deploy" 2>&1
)
dep_rc=$?
set -e
[[ "$dep_rc" -eq 1 ]] || fail "scenario6: deploy should rc=1, got $dep_rc out=$dep_out"
[[ "$dep_out" == *"DEPLOY-NONCANONICAL"* ]] \
    || fail "scenario6: expected DEPLOY-NONCANONICAL, got: $dep_out"
ok "scenario6: fleet-ops-deploy refuses a non-canonical checkout"

# --- 7-9. drift canary auto-file / WRONG-SYMLINK / dedup --------------------
gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
: >"$scratch/open.json"
echo '[]' >"$scratch/open.json"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    cat "${GH_OPEN_ISSUES:-/dev/null}"
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/1760"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"

run_canary() {
  set +e
  canary_out=$(
    HOME="$HOME" \
    FLEET_OPS_CHECKOUT="$1" \
    FLEET_OPS_WORKSPACES_ROOT="$ws" \
    FLEET_OPS_CANONICAL_CHECKOUT="$canon" \
    FLEET_OPS_SKIP_FETCH=1 \
    FLEET_OPS_TRIAGE="$scratch/triage.md" \
    FLEET_OPS_AUDIT_LOG="$scratch/audit.log" \
    FLEET_OPS_DRIFT_FILE=1 \
    FLEET_OPS_DRIFT_REPO="Nishfleet/fleet-ops" \
    GH="$gh_fake" \
    GH_LOG="$gh_log" \
    GH_OPEN_ISSUES="$scratch/open.json" \
    python3 "$repo_root/bin/fleet-ops-drift.py" 2>&1
  )
  canary_rc=$?
  set -e
}

: >"$gh_log"
: >"$scratch/triage.md"
run_canary "$hotfix"
[[ "$canary_rc" -eq 1 ]] || fail "scenario7: canary should rc=1, got $canary_rc out=$canary_out"
[[ "$canary_out" == *"DRIFT-SOURCE"* ]] || fail "scenario7: expected DRIFT-SOURCE, got: $canary_out"
[[ "$canary_out" == *"not the canonical checkout"* ]] \
    || fail "scenario7: must name the non-canonical checkout, got: $canary_out"
grep -q 'issue create' "$gh_log" || fail "scenario7: must auto-file (log=$(cat "$gh_log"))"
ok "scenario7: canary DRIFT-SOURCE auto-files when checkout is a hotfix"

: >"$gh_log"
: >"$scratch/triage.md"
ln -sfn "$hotfix/bin/demo-script" "$demo_dest"
run_canary "$canon"
[[ "$canary_rc" -eq 1 ]] || fail "scenario8: canary should rc=1, got $canary_rc out=$canary_out"
[[ "$canary_out" == *"WRONG-SYMLINK"* ]] || fail "scenario8: expected WRONG-SYMLINK, got: $canary_out"
grep -q 'issue create' "$gh_log" || fail "scenario8: must auto-file WRONG-SYMLINK"
ok "scenario8: canary WRONG-SYMLINK auto-files when a dest points at a hotfix"

: >"$gh_log"
: >"$scratch/triage.md"
jq -n --arg b $'body\ncanonical-checkout-drift: fleet-ops#176\n' \
  '[{number: 176, body: $b}]' >"$scratch/open.json"
run_canary "$hotfix"
[[ "$canary_rc" -eq 1 ]] || fail "scenario9: canary should still rc=1 on dedup, got $canary_rc"
grep -q 'issue create' "$gh_log" && fail "scenario9: must not file a duplicate (log=$(cat "$gh_log"))"
[[ "$canary_out" == *"dedup:"* ]] || fail "scenario9: expected dedup log, got: $canary_out"
ok "scenario9: open issue with the marker is not filed twice"

# --- scenario 10: fleet-ops-deploy refuses a non-canonical drift canary -------
# A stale FLEET_OPS_DRIFT_BIN drop-in pointing at a hotfix worktree must not
# run against the new deploy, or the rc can be misread (fleet-ops#463).
cat > "$hotfix/bin/fleet-ops-drift.py" <<'PY'
#!/usr/bin/env python3
import sys
print("noncanonical canary must not run")
sys.exit(0)
PY
chmod +x "$hotfix/bin/fleet-ops-drift.py"
set +e
deploy_canary_out=$(
  FLEET_OPS_CHECKOUT="$canon" \
  FLEET_OPS_CANONICAL_CHECKOUT="$canon" \
  FLEET_OPS_WORKSPACES_ROOT="$ws" \
  FLEET_OPS_DRIFT_BIN="$hotfix/bin/fleet-ops-drift.py" \
  FLEET_OPS_TRIAGE="$scratch/triage.md" \
  FLEET_OPS_DEPLOY_AUDIT_LOG="$scratch/deploy-audit.log" \
    "$canon/bin/fleet-ops-deploy" 2>&1
)
deploy_canary_rc=$?
set -e
[[ "$deploy_canary_rc" -eq 1 ]] || fail "scenario10: deploy should rc=1 for noncanonical canary, got rc=$deploy_canary_rc out=$deploy_canary_out"
[[ "$deploy_canary_out" == *"DEPLOY-DRIFT-BIN-NONCANONICAL"* ]] \
    || fail "scenario10: expected DEPLOY-DRIFT-BIN-NONCANONICAL, got: $deploy_canary_out"
ok "scenario10: fleet-ops-deploy refuses a drift canary from a non-canonical checkout"

echo "OK: canonical checkout guard refuses hotfix/issue worktrees and auto-files DRIFT-SOURCE"
exit 0
