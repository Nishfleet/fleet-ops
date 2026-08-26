#!/usr/bin/env bash
# tests/fleet-ops-deploy.test.sh
#
# fleet-ops#149: merge-to-live deploy step + drift canary.
#
# Proves, entirely offline with mocked git/systemctl:
#   1. A fresh merge adding a bin script + systemd unit is installed and
#      enabled by install.sh on the next heartbeat tick.
#   2. install.sh --check (the canary's fast path) catches a missing/wrong
#      symlink.
#   3. The canary fails loud on a dirty tracked file.
#   4. The canary fails loud on a stale/diverged checkout.
#   5. The canary fails loud on an extra enabled fleet unit.
#   6. The canary fails loud on a hand-installed extra symlink.
#
# The real bin/fleet-ops-drift.py is exercised; systemctl calls are stubbed
# and git is a real local repo so origin/main exists without network.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v jq >/dev/null 2>&1 || fail "jq missing"

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
canary="$checkout/bin/fleet-ops-drift"

# --- build a minimal deploy checkout -----------------------------------------
mkdir -p "$checkout/bin" "$checkout/systemd" "$checkout/config"
cp "$repo_root/install.sh" "$install"
cp "$repo_root/bin/fleet-ops-drift.py" "$checkout/bin/fleet-ops-drift.py"
ln -s "$(basename "$checkout/bin/fleet-ops-drift.py")" "$canary"
chmod +x "$install" "$canary"

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
PathChanged=$checkout/config/intake-repos.json
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

# Minimal declared-set reconciler for the test: enables the two per-repo timers.
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

# --- local git repo with origin/main -----------------------------------------
git -C "$checkout" init -q
git -C "$checkout" config user.email "test@example.com"
git -C "$checkout" config user.name "Test"
git -C "$checkout" add .
git -C "$checkout" commit -q -m "initial"
git -C "$checkout" update-ref refs/remotes/origin/main HEAD

# --- fake systemctl ----------------------------------------------------------
systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
enabled_file="${FLEET_OPS_FAKE_ENABLED:-/dev/null}"
mkdir -p "$(dirname "$enabled_file")" 2>/dev/null || true

shift  # consume --user
cmd="$1"; shift

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
  daemon-reload|enable|enable\ --now|start)
    # install.sh enable --now for .timer, and enable for .service both call
    # enable. Record the unit name so the canary sees it as enabled.
    if [ "$cmd" = "enable" ] || [ "$cmd" = "enable --now" ]; then
      for u in "$@"; do
        [ -n "$u" ] || continue
        case "$u" in
          --now) ;;
          *) printf '%s\n' "$u" >> "$enabled_file" ;;
        esac
      done
    fi
    exit 0
    ;;
  *)
    printf 'unexpected systemctl call: %s %s\n' "$cmd" "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$systemctl_fake"

# Shared state for the fake.
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

# --- scenario 1: fresh merge installs+enables, canary is clean -------------
# Install from the checkout, run the reconciler, then run the canary.
PATH="$scratch:$PATH" "$install" >/tmp/install.out 2>&1 || {
    cat /tmp/install.out; fail "scenario1: install.sh failed"
}
PATH="$scratch:$PATH" "$checkout/bin/intake-reconcile" >/dev/null 2>&1 || true
# install.sh should have enabled the MANIFEST timers.
for u in demo.timer intake-reconcile.path intake-reconcile.timer; do
  grep -qxF "$u" "$enabled_units" \
      || fail "scenario1: $u was not enabled (enabled=[$enabled_units])"
done
# intake-reconcile should have enabled the per-repo timers.
for u in pi-intake@demo.timer pi-scout@demo.timer; do
  grep -qxF "$u" "$enabled_units" \
      || fail "scenario1: $u was not enabled by intake-reconcile (enabled=[$enabled_units])"
done
# symlinks should point at the checkout.
[ -L "$HOME/.config/systemd/user/demo.timer" ] \
    || fail "scenario1: demo.timer not installed as a symlink"
[ -L "$HOME/.local/bin/demo-script" ] \
    || fail "scenario1: demo-script not installed as a symlink"

if ! out=$(run_canary); then
    fail "scenario1: canary should be clean after install, got: $out"
fi
ok "scenario1: fresh merge installs+enables and canary passes"

# --- scenario 2: missing symlink is caught by install.sh --check -----------
rm -f "$HOME/.config/systemd/user/demo.timer"
if out=$(run_canary); then
    fail "scenario2: canary should fail after deleting demo.timer, got: $out"
fi
[[ "$out" == *"DRIFT-INSTALL"* ]] || fail "scenario2: missing symlink did not produce DRIFT-INSTALL (got: $out)"
# restore for following scenarios
PATH="$scratch:$PATH" "$install" >/dev/null 2>&1 || true

# --- scenario 3: dirty tracked file blocks update ----------------------------
echo '# dirty' >> "$checkout/MANIFEST"
if out=$(run_canary); then
    fail "scenario3: canary should fail on dirty checkout, got: $out"
fi
[[ "$out" == *"DRIFT-CHECKOUT"* ]] || fail "scenario3: dirty checkout did not produce DRIFT-CHECKOUT (got: $out)"
git -C "$checkout" checkout -- MANIFEST

# --- scenario 4: stale checkout (HEAD behind origin/main) -------------------
old_head=$(git -C "$checkout" rev-parse HEAD)
# Create a new commit on a detached branch and advance origin/main there.
git -C "$checkout" checkout -q -b next-main
printf '\n[Timer]\nRandomizedDelaySec=10\n' >> "$checkout/systemd/demo.timer"
git -C "$checkout" add -A
git -C "$checkout" commit -q -m "new main"
new_head=$(git -C "$checkout" rev-parse HEAD)
git -C "$checkout" update-ref refs/remotes/origin/main "$new_head"
# Go back to the old HEAD (simulating the deploy checkout not yet merged).
git -C "$checkout" checkout -q "$old_head"
if out=$(run_canary); then
    fail "scenario4: canary should fail on stale checkout, got: $out"
fi
[[ "$out" == *"DRIFT-CHECKOUT"* ]] || fail "scenario4: stale checkout did not produce DRIFT-CHECKOUT (got: $out)"
# restore
git -C "$checkout" checkout -q next-main

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
printf 'pi-intake@ rogue.timer\n' >> "$enabled_units"
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

ok "fleet-ops deploy step: install, drift detection, and canary pass offline"
