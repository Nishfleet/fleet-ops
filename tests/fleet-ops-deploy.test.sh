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

ok "fleet-ops deploy step: install, drift detection, merge, and canary pass offline"
