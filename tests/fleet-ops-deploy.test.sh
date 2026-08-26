#!/usr/bin/env bash
# tests/fleet-ops-deploy.test.sh
#
# fleet-ops#149: merge-to-live deploy step + drift canary.
#
# Proves, entirely offline with mocked systemctl and a local git remote:
#   1. install.sh installs+enables MANIFEST bins and units; canary is clean.
#   2. A missing symlink fails the canary (DRIFT-INSTALL).
#   3. A dirty tracked file fails the canary (DRIFT-CHECKOUT).
#   4. A stale checkout (HEAD behind origin/main) fails the canary.
#   5. An extra enabled fleet unit fails the canary (DRIFT-UNITS).
#   6. A hand-installed extra symlink fails the canary (DRIFT-EXTRAS).
#   7. origin/main ahead + clean checkout: fleet-ops-deploy fast-forwards,
#      installs the newly merged bin+unit, enables them, canary passes.
#   8. Dirty checkout: fleet-ops-deploy blocks, does not merge, does not reset.
#   9. Linked worktree (.git FILE) is accepted by fleet-ops-deploy (re-land #313).
#  10. Live dest matching the checkout working tree is not enough: origin/main
#      blob compare fails if dest bytes differ from origin/main (self-compare
#      of checkout-vs-itself is impossible).
#  11. Enable-link into a volatile path (/tmp outside the checkout) fails
#      DRIFT-VOLATILE.
#  12. install.sh refuses to overwrite a live file newer than the repo copy,
#      and removes the paper-over heartbeat drop-in.
#  12c. install.sh refuses a seat-caps cap drop even when the repo file has
#      a newer mtime (git checkout refreshes mtime; fleet-ops#371).
#  12d. origin/main blob matching the repo file is allowed to land a merged
#      cap drop (fleet-ops-deploy path).
#  13. A leftover .service whose ExecStart binary is missing fails
#      DRIFT-MISSING-EXEC and auto-files (fleet-ops#285).
#  14. The paper-over heartbeat drop-in fails DRIFT-PAPER-OVER and auto-files
#      (fleet-ops#370). A second tick with the marker open does not re-file.
#  15. FLEET_OPS_DRIFT_BIN under agent-worktrees fails DEPLOY-DRIFT-BIN-VOLATILE.
#  16. fleet-ops-deploy removes the paper-over drop-in even when merge is blocked.
#
# The real bin/fleet-ops-drift.py and bin/fleet-ops-deploy are exercised.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v jq >/dev/null 2>&1 || fail "jq missing"
[[ -x "$repo_root/bin/fleet-ops-deploy" ]] || fail "missing bin/fleet-ops-deploy"
[[ -f "$repo_root/bin/fleet-ops-drift.py" ]] || fail "missing bin/fleet-ops-drift.py"
grep -q 'fleet-ops-deploy' "$repo_root/bin/fleet-heartbeat-tier1" \
    || fail "fleet-heartbeat-tier1 must invoke fleet-ops-deploy"
grep -q 'deploy_rc' "$repo_root/bin/fleet-heartbeat-tier1" \
    || fail "fleet-heartbeat-tier1 must propagate deploy_rc"
grep -q 'rev-parse --git-dir' "$repo_root/bin/fleet-ops-deploy" \
    || fail "fleet-ops-deploy must use rev-parse --git-dir (worktree-safe), not [ -d .git ]"
if grep -Fq '[ ! -d "$DEPLOY_CHECKOUT/.git" ]' "$repo_root/bin/fleet-ops-deploy"; then
    fail "fleet-ops-deploy still uses [ ! -d .git ] which false-negatives on linked worktrees"
fi
grep -q 'FLEET_OPS_CHECKOUT=/home/nish/workspaces/tooling/fleet-ops-deploy-clone' \
    "$repo_root/systemd/fleet-heartbeat.service" \
    || fail "fleet-heartbeat.service must pin the canonical deploy-clone checkout"
grep -q 'AUDIT_REPO_ROOT=/home/nish/workspaces/tooling/fleet-ops-deploy-clone' \
    "$repo_root/systemd/fleet-blind-audit.service" \
    || fail "fleet-blind-audit.service must pin AUDIT_REPO_ROOT to the canonical deploy-clone"
grep -q 'check_live_matches_origin_main' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must compare live dests to origin/main blobs"
grep -q 'DRIFT-VOLATILE' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must flag volatile unit/enable-link paths"
grep -q 'live_newer_than_repo' "$repo_root/install.sh" \
    || fail "install.sh must refuse to overwrite a newer live config"
grep -q 'seat_caps_would_downgrade' "$repo_root/install.sh" \
    || fail "install.sh must refuse a seat-caps cap drop even when mtime is newer (fleet-ops#371)"
grep -q 'fleet-ops#371' "$repo_root/install.sh" \
    || fail "install.sh cap-drop refuse must name fleet-ops#371"
grep -q 'remove_papered_heartbeat_dropin' "$repo_root/install.sh" \
    || fail "install.sh must remove the paper-over heartbeat drop-in"
grep -q 'refuse_noncanonical_install' "$repo_root/install.sh" \
    || fail "install.sh must refuse to install from a non-canonical workspaces checkout"
grep -q 'DEPLOY-NONCANONICAL' "$repo_root/bin/fleet-ops-deploy" \
    || fail "fleet-ops-deploy must refuse a non-canonical FLEET_OPS_CHECKOUT"
grep -q 'DRIFT-SOURCE' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must flag live dests that point outside the canonical checkout"
grep -q 'gh issue create' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must auto-file a canonical-checkout drift issue"
grep -q 'DRIFT-MISSING-EXEC' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must flag user units whose ExecStart binary is missing"
grep -q 'orphan-execstart: fleet-ops#285' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must auto-file missing-ExecStart leftovers with the #285 marker"
grep -q 'DRIFT-PAPER-OVER' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must flag the paper-over heartbeat drop-in (fleet-ops#370)"
grep -q 'paper-over-dropin: fleet-ops#370' "$repo_root/bin/fleet-ops-drift.py" \
    || fail "drift canary must auto-file the paper-over drop-in with the #370 marker"
grep -q 'DEPLOY-DRIFT-BIN-VOLATILE' "$repo_root/bin/fleet-ops-deploy" \
    || fail "fleet-ops-deploy must refuse FLEET_OPS_DRIFT_BIN under agent-worktrees"
grep -q 'fleet-heartbeat.service.d/10-deploy-checkout.conf' "$repo_root/bin/fleet-ops-deploy" \
    || fail "fleet-ops-deploy must remove the paper-over heartbeat drop-in"
if grep -q 'FLEET_OPS_DRIFT_BIN=' "$repo_root/systemd/fleet-heartbeat.service"; then
    fail "fleet-heartbeat.service must not pin FLEET_OPS_DRIFT_BIN (that was the paper-over)"
fi
[[ ! -e "$repo_root/systemd/fleet-heartbeat.service.d/10-deploy-checkout.conf" ]] \
    || fail "repo must not ship the paper-over heartbeat drop-in"

# --- scratch environment -----------------------------------------------------
scratch="$(mktemp -d -t fleet-ops-deploy.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME/.local/bin" \
         "$HOME/.config/systemd/user" \
         "$HOME/.pi/agent/prompts" \
         "$HOME/.local/state/fleet-ops"

checkout="$scratch/fleet-ops-checkout"
install="$checkout/install.sh"
canary="$HOME/.local/bin/fleet-ops-drift"
deploy="$checkout/bin/fleet-ops-deploy"

# --- build a minimal deploy checkout -----------------------------------------
mkdir -p "$checkout/bin" "$checkout/systemd" "$checkout/config"
cp "$repo_root/install.sh" "$install"
cp "$repo_root/bin/fleet-ops-drift.py" "$checkout/bin/fleet-ops-drift.py"
cp "$repo_root/bin/fleet-ops-deploy" "$deploy"
chmod +x "$install" "$checkout/bin/fleet-ops-drift.py" "$deploy"

cat >"$checkout/config/intake-repos.json" <<'JSON'
{
  "repos": [{ "name": "demo" }],
  "excluded": [],
  "deferred": []
}
JSON

cat >"$checkout/MANIFEST" <<MANIFEST
systemd/demo.timer $HOME/.config/systemd/user/demo.timer
bin/demo-script $HOME/.local/bin/demo-script
bin/fleet-ops-drift.py $HOME/.local/bin/fleet-ops-drift
bin/intake-reconcile $HOME/.local/bin/intake-reconcile
systemd/intake-reconcile.path $HOME/.config/systemd/user/intake-reconcile.path
systemd/intake-reconcile.timer $HOME/.config/systemd/user/intake-reconcile.timer
MANIFEST

cat >"$checkout/systemd/demo.timer" <<'UNIT'
[Unit]
Description=Demo timer

[Timer]
OnCalendar=*:00/30
Persistent=true

[Install]
WantedBy=timers.target
UNIT

cat >"$checkout/systemd/intake-reconcile.path" <<'UNIT'
[Unit]
Description=Reconcile path

[Path]
PathChanged=/tmp/intake-repos.json
Unit=intake-reconcile.service

[Install]
WantedBy=default.target
UNIT

cat >"$checkout/systemd/intake-reconcile.timer" <<'UNIT'
[Unit]
Description=Reconcile timer

[Timer]
OnCalendar=*:00/30

[Install]
WantedBy=timers.target
UNIT

# Templates fleet-ops actually ships — the drift canary matches rogue
# instances (pi-intake@rogue.timer) against these by template prefix, so
# they must exist in the test checkout for scenario 5 to exercise that path.
cat >"$checkout/systemd/pi-intake@.timer" <<'UNIT'
[Unit]
Description=Pi intake timer for %i

[Timer]
OnCalendar=*:00/30

[Install]
WantedBy=timers.target
UNIT
cat >"$checkout/systemd/pi-scout@.timer" <<'UNIT'
[Unit]
Description=Pi scout timer for %i

[Timer]
OnCalendar=*:00/30

[Install]
WantedBy=timers.target
UNIT

cat >"$checkout/bin/demo-script" <<'BIN'
#!/usr/bin/env bash
echo demo
BIN
chmod +x "$checkout/bin/demo-script"

cat >"$checkout/bin/intake-reconcile" <<'BIN'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
json="$here/../config/intake-repos.json"
for repo in $(jq -r '.repos[].name' "$json"); do
  systemctl --user enable --now "pi-intake@$repo.timer" >/dev/null 2>&1 || true
  systemctl --user enable --now "pi-scout@$repo.timer" >/dev/null 2>&1 || true
done
BIN
chmod +x "$checkout/bin/intake-reconcile"

# --- local git repo with a real origin ---------------------------------------
origin_bare="$scratch/origin.git"
git init --bare -q "$origin_bare"
git -C "$checkout" init -q -b main
git -C "$checkout" config user.email "test@example.com"
git -C "$checkout" config user.name "Test"
git -C "$checkout" add .
git -C "$checkout" commit -q -m "initial"
git -C "$checkout" remote add origin "$origin_bare"
git -C "$checkout" push -q origin HEAD:main
git -C "$checkout" fetch -q origin
git -C "$checkout" branch -q --set-upstream-to=origin/main main

# --- fake systemctl ----------------------------------------------------------
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
enabled_file="${FLEET_OPS_FAKE_ENABLED:-/dev/null}"
mkdir -p "$(dirname "$enabled_file")" 2>/dev/null || true

if [ "${1:-}" = "--user" ]; then
  shift
fi
cmd="${1:-}"
if [ "$#" -gt 0 ]; then
  shift
fi

case "$cmd" in
  is-enabled)
    [ -f "$enabled_file" ] && grep -qxF "$1" "$enabled_file" && exit 0
    exit 1
    ;;
  list-unit-files)
    if [ -f "$enabled_file" ]; then
      while IFS= read -r u; do
        [ -n "$u" ] && printf '%s enabled enabled\n' "$u"
      done < "$enabled_file"
    fi
    exit 0
    ;;
  daemon-reload)
    exit 0
    ;;
  enable)
    for u in "$@"; do
      [ -n "$u" ] || continue
      case "$u" in
        --now) ;;
        *) printf '%s\n' "$u" >> "$enabled_file" ;;
      esac
    done
    exit 0
    ;;
  start)
    exit 0
    ;;
  *)
    printf 'unexpected systemctl call: %s %s\n' "$cmd" "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$systemctl_fake"

enabled_units="$scratch/enabled_units"
: >"$enabled_units"
export FLEET_OPS_FAKE_ENABLED="$enabled_units"

run_canary() {
  FLEET_OPS_CHECKOUT="$checkout" \
  FLEET_OPS_SYSTEMCTL="$systemctl_fake" \
  FLEET_OPS_AUDIT_LOG="$HOME/.local/state/fleet-ops/drift-audit.log" \
  FLEET_OPS_TRIAGE="$scratch/triage.md" \
  FLEET_OPS_SKIP_FETCH=1 \
    "$canary" 2>&1
}

run_deploy() {
  PATH="$scratch:$PATH" \
  FLEET_OPS_CHECKOUT="$checkout" \
  FLEET_OPS_DRIFT_BIN="$canary" \
  FLEET_OPS_SYSTEMCTL="$systemctl_fake" \
  FLEET_OPS_DEPLOY_AUDIT_LOG="$scratch/deploy-audit.log" \
  FLEET_OPS_TRIAGE="$scratch/triage.md" \
    "$deploy" 2>&1
}

# --- scenario 1: install+enable, canary is clean -----------------------------
PATH="$scratch:$PATH" "$install" >/tmp/install.out 2>&1 || {
    cat /tmp/install.out
    fail "scenario1: install.sh failed"
}
PATH="$scratch:$PATH" "$checkout/bin/intake-reconcile" >/dev/null 2>&1 || true
for u in demo.timer intake-reconcile.path intake-reconcile.timer; do
  grep -qxF "$u" "$enabled_units" \
      || fail "scenario1: $u was not enabled (enabled=$(cat "$enabled_units"))"
done
for u in pi-intake@demo.timer pi-scout@demo.timer; do
  grep -qxF "$u" "$enabled_units" \
      || fail "scenario1: $u was not enabled by intake-reconcile (enabled=$(cat "$enabled_units"))"
done
[ -L "$HOME/.config/systemd/user/demo.timer" ] \
    || fail "scenario1: demo.timer not installed as a symlink"
[ -L "$HOME/.local/bin/demo-script" ] \
    || fail "scenario1: demo-script not installed as a symlink"
[ -L "$canary" ] || fail "scenario1: drift canary not installed as a symlink"

if ! out=$(run_canary); then
    fail "scenario1: canary should be clean after install, got: $out"
fi
ok "scenario1: install+enable and canary pass"

# --- scenario 2: missing symlink is caught -----------------------------------
rm -f "$HOME/.config/systemd/user/demo.timer"
if out=$(run_canary); then
    fail "scenario2: canary should fail after deleting demo.timer, got: $out"
fi
[[ "$out" == *"DRIFT-INSTALL"* ]] || fail "scenario2: missing symlink did not produce DRIFT-INSTALL (got: $out)"
PATH="$scratch:$PATH" "$install" >/dev/null 2>&1 || true

# --- scenario 3: dirty tracked file ------------------------------------------
echo '# dirty' >> "$checkout/MANIFEST"
if out=$(run_canary); then
    fail "scenario3: canary should fail on dirty checkout, got: $out"
fi
[[ "$out" == *"DRIFT-CHECKOUT"* ]] || fail "scenario3: dirty checkout did not produce DRIFT-CHECKOUT (got: $out)"
git -C "$checkout" checkout -- MANIFEST

# --- scenario 4: stale checkout (HEAD behind origin/main) --------------------
old_head=$(git -C "$checkout" rev-parse HEAD)
git -C "$checkout" checkout -q -b next-main
printf '\n# comment\n' >> "$checkout/systemd/demo.timer"
git -C "$checkout" add -A
git -C "$checkout" commit -q -m "new main"
git -C "$checkout" push -q origin HEAD:main
new_head=$(git -C "$checkout" rev-parse HEAD)
git -C "$checkout" checkout -q "$old_head"
if out=$(run_canary); then
    fail "scenario4: canary should fail on stale checkout, got: $out"
fi
[[ "$out" == *"DRIFT-CHECKOUT"* ]] || fail "scenario4: stale checkout did not produce DRIFT-CHECKOUT (got: $out)"
git -C "$checkout" checkout -q "$new_head"
git -C "$checkout" merge --ff-only -q origin/main

# --- scenario 5: extra enabled fleet unit ------------------------------------
expected_units=(
  demo.timer
  intake-reconcile.path
  intake-reconcile.timer
  pi-intake@demo.timer
  pi-scout@demo.timer
)
: >"$enabled_units"
printf '%s\n' "${expected_units[@]}" > "$enabled_units"
printf 'pi-intake@rogue.timer\n' >> "$enabled_units"
if out=$(run_canary); then
    fail "scenario5: canary should fail on extra enabled unit, got: $out"
fi
[[ "$out" == *"DRIFT-UNITS"* ]] || fail "scenario5: extra enabled unit did not produce DRIFT-UNITS (got: $out)"

# --- scenario 5b: externally-managed unit (fleet-prefixed, no source) ignored
# A unit with a fleet-y name prefix but NO source file in this checkout is
# owned by another system (codex-remote-control.service, pi-transport-check.*)
# and must NOT be flagged as drift — the old prefix-only check false-positived
# on these and turned every heartbeat tick red.
: >"$enabled_units"
printf '%s\n' "${expected_units[@]}" > "$enabled_units"
printf 'codex-remote-control.service\n' >> "$enabled_units"
printf 'pi-transport-check.timer\n' >> "$enabled_units"
if ! out=$(run_canary); then
    fail "scenario5b: canary should pass (externally-managed units ignored), got: $out"
fi
[[ "$out" == *"DRIFT-UNITS"* ]] \
    && fail "scenario5b: externally-managed units were flagged as DRIFT-UNITS (got: $out)"
ok "scenario5b: externally-managed (no-source) units ignored, not flagged as drift"

# --- scenario 5c: masked unit + template-instance symlinks ignored -----------
# intake-reconcile masks disabled units via a /dev/null symlink, and enabled
# template instances (pi-intake@<repo>.timer) symlink to the shipped template.
# Both are legit fleet state, not drift — the old check_extra_symlinks flagged
# them because it didn't understand template instances or the /dev/null mask.
: >"$enabled_units"
printf '%s\n' "${expected_units[@]}" > "$enabled_units"
# masked (disabled) unit: symlink to /dev/null
ln -sf /dev/null "$HOME/.config/systemd/user/pi-intake@rogue.timer"
# enabled template instance: symlink to the shipped template in the checkout
ln -sf "$checkout/systemd/pi-intake@.timer" "$HOME/.config/systemd/user/pi-intake@extra.timer"
if ! out=$(run_canary); then
    fail "scenario5c: canary should pass (masked + template-instance symlinks are legit), got: $out"
fi
[[ "$out" == *"DRIFT-EXTRAS"* ]] \
    && fail "scenario5c: masked/template-instance symlinks were flagged as DRIFT-EXTRAS (got: $out)"
ok "scenario5c: masked (/dev/null) and template-instance symlinks ignored, not flagged as drift"
rm -f "$HOME/.config/systemd/user/pi-intake@rogue.timer" "$HOME/.config/systemd/user/pi-intake@extra.timer"

# --- scenario 6: hand-installed extra symlink --------------------------------
: >"$enabled_units"
printf '%s\n' "${expected_units[@]}" > "$enabled_units"
mkdir -p "$scratch/fleet-ops-stale/bin"
echo '# stale' > "$scratch/fleet-ops-stale/bin/extra"
ln -sf "$scratch/fleet-ops-stale/bin/extra" "$HOME/.local/bin/extra"
if out=$(run_canary); then
    fail "scenario6: canary should fail on extra symlink, got: $out"
fi
[[ "$out" == *"DRIFT-EXTRAS"* ]] || fail "scenario6: extra symlink did not produce DRIFT-EXTRAS (got: $out)"
rm -f "$HOME/.local/bin/extra"

# --- scenario 7: origin/main ahead — deploy merges and installs the new unit -
: >"$enabled_units"
behind_head=$(git -C "$checkout" rev-parse HEAD)
git -C "$checkout" checkout -q -b add-merged
cat >"$checkout/bin/merged-script" <<'BIN'
#!/usr/bin/env bash
echo merged
BIN
chmod +x "$checkout/bin/merged-script"
cat >"$checkout/systemd/merged.timer" <<'UNIT'
[Unit]
Description=Merged timer

[Timer]
OnCalendar=*:00/30

[Install]
WantedBy=timers.target
UNIT
cat >>"$checkout/MANIFEST" <<MANIFEST
bin/merged-script $HOME/.local/bin/merged-script
systemd/merged.timer $HOME/.config/systemd/user/merged.timer
MANIFEST
git -C "$checkout" add -A
git -C "$checkout" commit -q -m "add merged bin+unit"
git -C "$checkout" push -q origin HEAD:main
merged_head=$(git -C "$checkout" rev-parse HEAD)
git -C "$checkout" checkout -q "$behind_head"
[ "$(git -C "$checkout" rev-parse HEAD)" != "$merged_head" ] \
    || fail "scenario7: setup did not leave checkout behind origin/main"

if ! out=$(run_deploy); then
    fail "scenario7: deploy should merge a clean behind checkout, got: $out"
fi
[ "$(git -C "$checkout" rev-parse HEAD)" = "$merged_head" ] \
    || fail "scenario7: checkout was not fast-forwarded to origin/main"
[ -L "$HOME/.local/bin/merged-script" ] \
    || fail "scenario7: merged-script was not installed"
[ -L "$HOME/.config/systemd/user/merged.timer" ] \
    || fail "scenario7: merged.timer was not installed"
grep -qxF "merged.timer" "$enabled_units" \
    || fail "scenario7: merged.timer was not enabled (enabled=$(cat "$enabled_units"))"
ok "scenario7: origin/main ahead merges, installs, and enables the new unit"

# --- scenario 8: dirty checkout blocks, no merge, no reset -------------------
: >"$enabled_units"
block_head=$(git -C "$checkout" rev-parse HEAD)
git -C "$checkout" checkout -q -b ahead-dirty
echo '# next' >> "$checkout/bin/demo-script"
git -C "$checkout" add -A
git -C "$checkout" commit -q -m "ahead"
git -C "$checkout" push -q origin HEAD:main
git -C "$checkout" checkout -q "$block_head"
echo '# hot patch' >> "$checkout/bin/demo-script"
if out=$(run_deploy); then
    fail "scenario8: deploy should block on dirty tracked files, got: $out"
fi
[[ "$out" == *"DEPLOY-BLOCKED"* ]] || fail "scenario8: dirty checkout did not produce DEPLOY-BLOCKED (got: $out)"
[ "$(git -C "$checkout" rev-parse HEAD)" = "$block_head" ] \
    || fail "scenario8: dirty checkout was mutated (HEAD moved)"
git -C "$checkout" diff --quiet -- bin/demo-script \
    && fail "scenario8: dirty tracked file was reset or discarded"
[[ "$out" != *"stash"* ]] || fail "scenario8: deploy mentioned stash"
ok "scenario8: dirty checkout blocks with no merge and no reset"

# --- scenario 9: linked worktree (.git is a FILE) is a valid checkout --------
: >"$enabled_units"
git -C "$checkout" reset --hard -q origin/main
git -C "$checkout" worktree add --detach -q "$scratch/linked-wt"
[[ -f "$scratch/linked-wt/.git" ]] \
    || fail "scenario9: setup expected .git to be a file on the linked worktree"
[[ ! -d "$scratch/linked-wt/.git" ]] \
    || fail "scenario9: setup expected .git NOT to be a directory on the linked worktree"
if ! out=$(
  PATH="$scratch:$PATH" \
  FLEET_OPS_CHECKOUT="$scratch/linked-wt" \
  FLEET_OPS_DRIFT_BIN="$canary" \
  FLEET_OPS_SYSTEMCTL="$systemctl_fake" \
  FLEET_OPS_DEPLOY_AUDIT_LOG="$scratch/deploy-audit.log" \
  FLEET_OPS_TRIAGE="$scratch/triage.md" \
    "$deploy" 2>&1
); then
    [[ "$out" != *"DEPLOY-CHECKOUT-MISSING"* ]] \
        || fail "scenario9: linked worktree was rejected as missing checkout: $out"
    fail "scenario9: deploy on a linked worktree failed: $out"
fi
[[ "$out" != *"DEPLOY-CHECKOUT-MISSING"* ]] \
    || fail "scenario9: linked worktree was rejected as missing checkout: $out"
ok "scenario9: linked worktree (.git file) is accepted"
git -C "$checkout" worktree remove "$scratch/linked-wt"
PATH="$scratch:$PATH" "$install" >/dev/null 2>&1 || true

# --- scenario 10: origin/main blob compare cannot self-compare ----------------
# dest is a symlink into the checkout (the production self-compare shape).
# Mutate the working tree (dest follows). origin/main blobs are unchanged.
# Calling check_live_matches_origin_main alone must FAIL with DRIFT-ORIGIN.
# A self-comparison of dest vs working tree would PASS.
: >"$enabled_units"
printf '%s\n' "${expected_units[@]}" > "$enabled_units"
git -C "$checkout" checkout -q -- systemd/demo.timer
if ! pyout=$(
  FLEET_OPS_AUDIT_LOG="$HOME/.local/state/fleet-ops/drift-audit.log" \
  FLEET_OPS_TRIAGE="$scratch/triage.md" \
  HOME="$HOME" \
  python3 - "$checkout" <<'PY' 2>&1
import importlib.util
import sys
from pathlib import Path

checkout = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "fleet_ops_drift", checkout / "bin" / "fleet-ops-drift.py"
)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)
(checkout / "systemd" / "demo.timer").write_text("# mutated working tree\n", encoding="utf-8")
try:
    mod.check_live_matches_origin_main(checkout)
except SystemExit as e:
    sys.exit(e.code if e.code is not None else 1)
sys.exit(0)
PY
); then
    [[ "$pyout" == *"DRIFT-ORIGIN"* ]] \
        || fail "scenario10: expected DRIFT-ORIGIN when dest matches dirty worktree but not origin/main, got: $pyout"
    ok "scenario10: origin/main blob compare fails when dest matches the working tree only"
else
    fail "scenario10: origin/main blob compare passed (self-comparison is possible): $pyout"
fi
git -C "$checkout" checkout -q -- systemd/demo.timer

# --- scenario 11: enable-link into a volatile path outside the checkout ------
: >"$enabled_units"
printf '%s\n' "${expected_units[@]}" merged.timer > "$enabled_units"
mkdir -p "$HOME/.config/systemd/user/timers.target.wants" "$scratch/volatile-outside"
printf '[Timer]\nOnCalendar=*:00/30\n' > "$scratch/volatile-outside/rogue.timer"
ln -sfn "$scratch/volatile-outside/rogue.timer" \
    "$HOME/.config/systemd/user/timers.target.wants/rogue.timer"
if out=$(run_canary); then
    fail "scenario11: canary should fail on a wants-link into a volatile path, got: $out"
fi
[[ "$out" == *"DRIFT-VOLATILE"* ]] \
    || fail "scenario11: volatile enable-link did not produce DRIFT-VOLATILE (got: $out)"
ok "scenario11: enable-link into a volatile path fails DRIFT-VOLATILE"
rm -f "$HOME/.config/systemd/user/timers.target.wants/rogue.timer"

# --- scenario 12: install.sh refuses newer live config; removes paper-over ---
stale="$scratch/stale-repo"
mkdir -p "$stale/config"
cp "$repo_root/install.sh" "$stale/install.sh"
chmod +x "$stale/install.sh"
printf 'stale-caps\n' > "$stale/config/seat-caps.json"
printf 'live-caps\n' > "$scratch/live-caps.json"
touch -d '2020-01-01T00:00:00' "$stale/config/seat-caps.json"
touch -d '2026-08-26T00:00:00' "$scratch/live-caps.json"
caps_dest="$scratch/caps-dest"
ln -sfn "$scratch/live-caps.json" "$caps_dest"
cat >"$stale/MANIFEST" <<MANIFEST
config/seat-caps.json $caps_dest
MANIFEST
set +e
refuse_out=$("$stale/install.sh" 2>&1)
refuse_rc=$?
set -e
[[ "$refuse_rc" -eq 1 ]] || fail "scenario12: install.sh from a stale repo should refuse (rc=1), got rc=$refuse_rc out=$refuse_out"
[[ "$refuse_out" == *"REFUSE:"* ]] \
    || fail "scenario12: expected REFUSE line, got: $refuse_out"
[[ "$(readlink -f "$caps_dest")" = "$(readlink -f "$scratch/live-caps.json")" ]] \
    || fail "scenario12: live dest was overwritten by the stale repo"
[[ "$(cat "$caps_dest")" = "live-caps" ]] \
    || fail "scenario12: live caps content was changed"
ok "scenario12: install.sh refuses to overwrite a newer live config"

dropin="$HOME/.config/systemd/user/fleet-heartbeat.service.d/10-deploy-checkout.conf"
mkdir -p "$(dirname "$dropin")"
printf 'Environment=FLEET_OPS_DRIFT_BIN=/tmp/gc-able-worktree/fleet-ops-drift.py\n' > "$dropin"
PATH="$scratch:$PATH" "$install" >/dev/null 2>&1 || true
[[ ! -e "$dropin" ]] || fail "scenario12: paper-over heartbeat drop-in was not removed"
ok "scenario12b: install.sh removes the paper-over heartbeat drop-in"

# --- scenario 12c: cap drop with NEWER repo mtime (fleet-ops#371) ------------
# git checkout of a stale commit stamps the working tree now, so the #372
# mtime guard would allow the overwrite. Live is the post-#331 snapshot
# (devin 4 / ollama 4); repo is the pre-#331 snapshot (devin 0 / ollama 2).
stale371="$scratch/stale-caps-mtime-hole"
mkdir -p "$stale371/config"
cp "$repo_root/install.sh" "$stale371/install.sh"
chmod +x "$stale371/install.sh"
cat >"$stale371/config/seat-caps.json" <<'JSON'
{"providers":{"devin":{"cap":0},"ollama":{"cap":2,"models":{"deepseek-v4-flash:0731":2}}}}
JSON
cat >"$scratch/live-caps-371.json" <<'JSON'
{"providers":{"devin":{"cap":4,"quota_bench_default_s":900},"ollama":{"cap":4,"models":{"deepseek-v4-flash:0731":4}}}}
JSON
touch -d '2020-01-01T00:00:00' "$scratch/live-caps-371.json"
touch -d '2026-08-26T20:35:00' "$stale371/config/seat-caps.json"
caps_dest371="$scratch/caps-dest-371"
ln -sfn "$scratch/live-caps-371.json" "$caps_dest371"
cat >"$stale371/MANIFEST" <<MANIFEST
config/seat-caps.json $caps_dest371
MANIFEST
set +e
refuse371_out=$("$stale371/install.sh" 2>&1)
refuse371_rc=$?
set -e
[[ "$refuse371_rc" -eq 1 ]] || fail "scenario12c: cap drop with newer repo mtime should refuse (rc=1), got rc=$refuse371_rc out=$refuse371_out"
[[ "$refuse371_out" == *"fleet-ops#371"* ]] \
    || fail "scenario12c: expected fleet-ops#371 REFUSE, got: $refuse371_out"
[[ "$refuse371_out" == *"devin:4->0"* ]] \
    || fail "scenario12c: REFUSE must name the devin 4->0 drop, got: $refuse371_out"
[[ "$(readlink -f "$caps_dest371")" = "$(readlink -f "$scratch/live-caps-371.json")" ]] \
    || fail "scenario12c: live dest was overwritten by the stale repo"
[[ "$(jq -r '.providers.devin.cap' "$caps_dest371")" = "4" ]] \
    || fail "scenario12c: live devin cap was changed"
ok "scenario12c: install.sh refuses a seat-caps cap drop even when repo mtime is newer"

# --- scenario 12d: origin/main blob may land a merged cap drop --------------
canon371="$scratch/canon-seat-caps"
mkdir -p "$canon371/config"
cp "$repo_root/install.sh" "$canon371/install.sh"
chmod +x "$canon371/install.sh"
cat >"$canon371/config/seat-caps.json" <<'JSON'
{"providers":{"devin":{"cap":3}}}
JSON
cat >"$scratch/live-caps-ff.json" <<'JSON'
{"providers":{"devin":{"cap":4}}}
JSON
touch -d '2026-08-26T20:35:00' "$scratch/live-caps-ff.json"
touch -d '2020-01-01T00:00:00' "$canon371/config/seat-caps.json"
caps_dest_ff="$scratch/caps-dest-ff"
ln -sfn "$scratch/live-caps-ff.json" "$caps_dest_ff"
cat >"$canon371/MANIFEST" <<MANIFEST
config/seat-caps.json $caps_dest_ff
MANIFEST
git -C "$canon371" init -q -b main
git -C "$canon371" config user.email "test@example.com"
git -C "$canon371" config user.name "Test"
git -C "$canon371" add config/seat-caps.json MANIFEST install.sh
git -C "$canon371" commit -q -m "merged cap drop"
git -C "$canon371" update-ref refs/remotes/origin/main HEAD
set +e
ff_out=$("$canon371/install.sh" 2>&1)
ff_rc=$?
set -e
[[ "$ff_rc" -eq 0 ]] || fail "scenario12d: origin/main blob should be allowed to land, got rc=$ff_rc out=$ff_out"
[[ "$(readlink -f "$caps_dest_ff")" = "$(readlink -f "$canon371/config/seat-caps.json")" ]] \
    || fail "scenario12d: dest was not retargeted at origin/main seat-caps"
[[ "$(jq -r '.providers.devin.cap' "$caps_dest_ff")" = "3" ]] \
    || fail "scenario12d: dest did not pick up the merged cap"
ok "scenario12d: origin/main seat-caps blob is allowed to land a merged cap drop"

# --- scenario 13: leftover unit whose ExecStart binary is missing (fleet-ops#285)
# The GitHub-hosted replacement left .service/.timer files on disk after the
# VPS binary was renamed to .bak. Extra-symlink and extra-enabled checks miss
# this class: the files are regular (not symlinks) and the timer is disabled.
: >"$enabled_units"
printf '%s\n' "${expected_units[@]}" merged.timer > "$enabled_units"
gh_log="$scratch/gh-orphan.log"
gh_fake="$scratch/gh-orphan"
: >"$gh_log"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    cat "${GH_OPEN_ISSUES:-/dev/null}"
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/2850"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
: >"$scratch/open-orphan.json"
echo '[]' >"$scratch/open-orphan.json"
cat >"$HOME/.config/systemd/user/repo-standards-reconcile.service" <<UNIT
[Unit]
Description=Leftover reconcile

[Service]
Type=oneshot
ExecStart=$HOME/.local/bin/repo-standards-reconcile
UNIT
cat >"$HOME/.config/systemd/user/repo-standards-reconcile.timer" <<'UNIT'
[Unit]
Description=Leftover reconcile timer

[Timer]
OnCalendar=*-*-* 03:30:00

[Install]
WantedBy=timers.target
UNIT
[[ ! -e "$HOME/.local/bin/repo-standards-reconcile" ]] \
    || fail "scenario13: setup expected the ExecStart binary to be missing"
run_orphan_canary() {
  GH="$gh_fake" \
  GH_LOG="$gh_log" \
  GH_OPEN_ISSUES="$scratch/open-orphan.json" \
  FLEET_OPS_DRIFT_FILE=1 \
  FLEET_OPS_DRIFT_REPO="Nishfleet/fleet-ops" \
    run_canary
}
if out=$(run_orphan_canary); then
    fail "scenario13: canary should fail on a leftover unit with a missing ExecStart, got: $out"
fi
[[ "$out" == *"DRIFT-MISSING-EXEC"* ]] \
    || fail "scenario13: expected DRIFT-MISSING-EXEC (got: $out)"
[[ "$out" == *"repo-standards-reconcile.service"* ]] \
    || fail "scenario13: must name the leftover service (got: $out)"
[[ "$out" == *"repo-standards-reconcile.timer"* ]] \
    || fail "scenario13: must name the sibling leftover timer (got: $out)"
grep -q 'issue create' "$gh_log" \
    || fail "scenario13: must auto-file (log=$(cat "$gh_log"))"
ok "scenario13: leftover unit with missing ExecStart fails DRIFT-MISSING-EXEC and auto-files"

: >"$gh_log"
jq -n --arg b $'body\norphan-execstart: fleet-ops#285\n' \
  '[{number: 285, body: $b}]' >"$scratch/open-orphan.json"
if out=$(
  GH="$gh_fake" \
  GH_LOG="$gh_log" \
  GH_OPEN_ISSUES="$scratch/open-orphan.json" \
  FLEET_OPS_DRIFT_FILE=1 \
  FLEET_OPS_DRIFT_REPO="Nishfleet/fleet-ops" \
    run_canary
); then
    fail "scenario13b: canary should still fail on leftover after dedup, got: $out"
fi
grep -q 'issue create' "$gh_log" \
    && fail "scenario13b: must not file a duplicate (log=$(cat "$gh_log"))"
[[ "$out" == *"dedup:"* ]] || fail "scenario13b: expected dedup log, got: $out"
ok "scenario13b: open issue with the marker is not filed twice"

rm -f "$HOME/.config/systemd/user/repo-standards-reconcile.service" \
      "$HOME/.config/systemd/user/repo-standards-reconcile.timer"
if ! out=$(run_canary); then
    fail "scenario13c: canary should be clean after leftover units are removed, got: $out"
fi
ok "scenario13c: removing the leftover units clears DRIFT-MISSING-EXEC"

# --- scenario 14: paper-over heartbeat drop-in fails and auto-files (#370) ---
: >"$enabled_units"
printf '%s\n' "${expected_units[@]}" merged.timer > "$enabled_units"
git -C "$checkout" checkout -q -- systemd/demo.timer bin/demo-script MANIFEST 2>/dev/null || true
paper_gh_log="$scratch/gh-paper.log"
paper_gh="$scratch/gh-paper"
: >"$paper_gh_log"
echo '[]' >"$scratch/open-paper.json"
cat >"$paper_gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    cat "${GH_OPEN_ISSUES:-/dev/null}"
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/3700"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$paper_gh"
dropin="$HOME/.config/systemd/user/fleet-heartbeat.service.d/10-deploy-checkout.conf"
mkdir -p "$(dirname "$dropin")"
printf 'Environment=FLEET_OPS_DRIFT_BIN=/tmp/agent-worktrees/fix-drift-canary/bin/fleet-ops-drift.py\n' > "$dropin"
run_paper_canary() {
  GH="$paper_gh" \
  GH_LOG="$paper_gh_log" \
  GH_OPEN_ISSUES="$scratch/open-paper.json" \
  FLEET_OPS_DRIFT_FILE=1 \
  FLEET_OPS_DRIFT_REPO="Nishfleet/fleet-ops" \
    run_canary
}
if out=$(run_paper_canary); then
    fail "scenario14: canary should fail on the paper-over drop-in, got: $out"
fi
[[ "$out" == *"DRIFT-PAPER-OVER"* ]] \
    || fail "scenario14: expected DRIFT-PAPER-OVER (got: $out)"
grep -q 'issue create' "$paper_gh_log" \
    || fail "scenario14: must auto-file (log=$(cat "$paper_gh_log"))"
ok "scenario14: paper-over drop-in fails DRIFT-PAPER-OVER and auto-files"

: >"$paper_gh_log"
jq -n --arg b $'body\npaper-over-dropin: fleet-ops#370\n' \
  '[{number: 370, body: $b}]' >"$scratch/open-paper.json"
if out=$(
  GH="$paper_gh" \
  GH_LOG="$paper_gh_log" \
  GH_OPEN_ISSUES="$scratch/open-paper.json" \
  FLEET_OPS_DRIFT_FILE=1 \
  FLEET_OPS_DRIFT_REPO="Nishfleet/fleet-ops" \
    run_canary
); then
    fail "scenario14b: canary should still fail on drop-in after dedup, got: $out"
fi
grep -q 'issue create' "$paper_gh_log" \
    && fail "scenario14b: must not file a duplicate (log=$(cat "$paper_gh_log"))"
[[ "$out" == *"dedup:"* ]] || fail "scenario14b: expected dedup log, got: $out"
ok "scenario14b: open issue with the #370 marker is not filed twice"
rm -f "$dropin"

# --- scenario 15: FLEET_OPS_DRIFT_BIN under agent-worktrees is refused ------
wt_canary="$scratch/agent-worktrees/fix-drift-canary-external-units/bin/fleet-ops-drift.py"
mkdir -p "$(dirname "$wt_canary")"
printf '#!/usr/bin/env python3\nraise SystemExit("volatile canary must not run")\n' > "$wt_canary"
chmod +x "$wt_canary"
if out=$(
  PATH="$scratch:$PATH" \
  FLEET_OPS_CHECKOUT="$checkout" \
  FLEET_OPS_DRIFT_BIN="$wt_canary" \
  FLEET_OPS_SYSTEMCTL="$systemctl_fake" \
  FLEET_OPS_DEPLOY_AUDIT_LOG="$scratch/deploy-audit.log" \
  FLEET_OPS_TRIAGE="$scratch/triage.md" \
    "$deploy" 2>&1
); then
    fail "scenario15: deploy should refuse a worktree FLEET_OPS_DRIFT_BIN, got: $out"
fi
[[ "$out" == *"DEPLOY-DRIFT-BIN-VOLATILE"* ]] \
    || fail "scenario15: expected DEPLOY-DRIFT-BIN-VOLATILE (got: $out)"
ok "scenario15: FLEET_OPS_DRIFT_BIN under agent-worktrees is refused"

if out=$(
  FLEET_OPS_DRIFT_BIN="$wt_canary" \
  GH="$paper_gh" \
  GH_LOG="$paper_gh_log" \
  GH_OPEN_ISSUES="$scratch/open-paper.json" \
  FLEET_OPS_DRIFT_FILE=1 \
  FLEET_OPS_DRIFT_REPO="Nishfleet/fleet-ops" \
    run_canary
); then
    fail "scenario15b: canary should fail when FLEET_OPS_DRIFT_BIN is a worktree, got: $out"
fi
[[ "$out" == *"DRIFT-PAPER-OVER"* ]] \
    || fail "scenario15b: expected DRIFT-PAPER-OVER for worktree FLEET_OPS_DRIFT_BIN (got: $out)"
ok "scenario15b: canary flags FLEET_OPS_DRIFT_BIN under agent-worktrees"

# --- scenario 16: deploy removes the drop-in even when merge is blocked ------
: >"$enabled_units"
block_head=$(git -C "$checkout" rev-parse HEAD)
echo '# paper-over-block' >> "$checkout/bin/demo-script"
mkdir -p "$(dirname "$dropin")"
printf 'Environment=FLEET_OPS_DRIFT_BIN=/tmp/agent-worktrees/x.py\n' > "$dropin"
if out=$(run_deploy); then
    fail "scenario16: deploy should block on dirty tracked files, got: $out"
fi
[[ "$out" == *"DEPLOY-BLOCKED"* ]] || fail "scenario16: expected DEPLOY-BLOCKED (got: $out)"
[[ ! -e "$dropin" ]] || fail "scenario16: paper-over drop-in survived a blocked deploy"
ok "scenario16: blocked deploy still removes the paper-over drop-in"
git -C "$checkout" checkout -q -- bin/demo-script
[ "$(git -C "$checkout" rev-parse HEAD)" = "$block_head" ] \
    || fail "scenario16: blocked deploy mutated HEAD"

ok "fleet-ops deploy step: install, drift detection, merge, and canary pass offline"

# fleet-ops#176: CI lists THIS file explicitly; the worker GitHub App cannot
# add a workflow step, so the canonical-checkout drill rides along.
bash "$here/canonical-checkout-guard.test.sh"

# fleet-ops#175: same CI-list constraint; required-bins drill rides along.
bash "$here/manifest-required-bins.test.sh"
