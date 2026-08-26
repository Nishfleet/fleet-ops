#!/usr/bin/env bash
# tests/intake-reconcile-deploy-checkout.test.sh
#
# Codifies the 2026-08-26 intake-reconcile split-brain hotfix: the systemd
# unit must read intake-repos.json from the live deploy checkout, not the
# stale products/fleet-ops worktree (which lagged origin/main and re-enabled
# deferred siterep-public timers every tick).
#
# What it proves:
#   1. Drop-in exists with Environment=INTAKE_RECONCILE_INTAKE_JSON pointing
#      at fleet-ops-deploy-clone/config/intake-repos.json.
#   2. MANIFEST lists that drop-in at the live user systemd dest.
#   3. install.sh, given that MANIFEST line, installs the drop-in under a
#      scratch HOME; the installed file carries the env var.
#
# Entirely offline. Fake systemctl so this never touches the live user
# manager (same rule as tests/intake-reconcile.test.sh).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

dropin="$repo_root/systemd/intake-reconcile.service.d/10-deploy-checkout.conf"
manifest="$repo_root/MANIFEST"
install="$repo_root/install.sh"
want_json="/home/nish/workspaces/tooling/fleet-ops-deploy-clone/config/intake-repos.json"
want_env="Environment=INTAKE_RECONCILE_INTAKE_JSON=$want_json"
want_manifest="systemd/intake-reconcile.service.d/10-deploy-checkout.conf /home/nish/.config/systemd/user/intake-reconcile.service.d/10-deploy-checkout.conf"

# --- 1. drop-in shape -------------------------------------------------------
[[ -f "$dropin" ]] || fail "missing drop-in: $dropin"
grep -q '^\[Service\]$' "$dropin" \
  || fail "drop-in missing [Service] section: $dropin"
grep -Fxq "$want_env" "$dropin" \
  || fail "drop-in must set $want_env"
ok "drop-in points INTAKE_RECONCILE_INTAKE_JSON at deploy-clone"

# --- 2. MANIFEST dest -------------------------------------------------------
grep -Fxq "$want_manifest" "$manifest" \
  || fail "MANIFEST missing entry: $want_manifest"
ok "MANIFEST installs drop-in to live user systemd dest"

# --- 3. install.sh lands the drop-in (hermetic) -----------------------------
[[ -x "$install" ]] || fail "install.sh not executable: $install"
bash -n "$install" || fail "install.sh: bash syntax error"

scratch="$(mktemp -d -t intake-reconcile-deploy-checkout.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

checkout="$scratch/checkout"
mkdir -p "$checkout/systemd/intake-reconcile.service.d"
cp "$install" "$checkout/install.sh"
chmod +x "$checkout/install.sh"
cp "$dropin" "$checkout/systemd/intake-reconcile.service.d/10-deploy-checkout.conf"
cat >"$checkout/MANIFEST" <<MANIFEST
systemd/intake-reconcile.service.d/10-deploy-checkout.conf $HOME/.config/systemd/user/intake-reconcile.service.d/10-deploy-checkout.conf
MANIFEST

systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "--user" ]; then
  shift
fi
case "${1:-}" in
  daemon-reload|start) exit 0 ;;
  is-enabled) exit 1 ;;
  enable|reenable) exit 0 ;;
  *) printf 'unexpected systemctl call: %s\n' "$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$systemctl_fake"

FLEET_OPS_ALLOW_NONCANONICAL=1 PATH="$scratch:$PATH" "$checkout/install.sh" >"$scratch/install.out" 2>&1 || {
  cat "$scratch/install.out" >&2
  fail "install.sh failed in scratch HOME"
}

dest="$HOME/.config/systemd/user/intake-reconcile.service.d/10-deploy-checkout.conf"
[[ -L "$dest" ]] || fail "install.sh did not symlink drop-in to $dest"
[[ "$(readlink -f "$dest")" = "$(readlink -f "$checkout/systemd/intake-reconcile.service.d/10-deploy-checkout.conf")" ]] \
  || fail "drop-in symlink target is $(readlink -f "$dest"), want checkout file"
grep -Fxq "$want_env" "$dest" \
  || fail "installed drop-in missing $want_env"
ok "install.sh installs deploy-clone INTAKE_RECONCILE_INTAKE_JSON drop-in"

echo "OK: intake-reconcile reads deploy-clone intake-repos.json after install.sh"
exit 0
