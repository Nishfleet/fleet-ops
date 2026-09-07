#!/usr/bin/env bash
# tests/install-refuse-continues.test.sh
#
# fleet-ops#4223: a non-fatal config REFUSE (e.g. a live models.json that is
# newer and differs from the repo copy) must not abort the rest of install.sh.
# The live config must stay protected, the installer must record the failure
# and exit non-zero, and later MANIFEST entries (like a non-canonical unit
# symlink) must still be repaired.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
install_src="$repo_root/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$install_src" ]] || fail "not executable: $install_src"

scratch="$(mktemp -d -t install-refuse-continues.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

install="$scratch/install.sh"
cp -a "$install_src" "$install"
chmod +x "$install"

# Fake a canonical deploy clone and a non-canonical worktree under it.
ws_root="$scratch/workspaces"
canon_dir="$ws_root/tooling/fleet-ops-deploy-clone"
other_wt="$ws_root/other"
mkdir -p "$canon_dir" "$other_wt" "$scratch/config" "$scratch/systemd" \
         "$scratch/home/nish/.pi/agent" \
         "$scratch/home/nish/.config/systemd/user"

# A repo-side unit that a later MANIFEST line should retarget to.
cat >"$scratch/systemd/example.service" <<'UNIT'
[Unit]
Description=Example

[Service]
ExecStart=/bin/true

[Install]
WantedBy=default.target
UNIT

# The non-canonical target a previous (worktree) install left behind.
cat >"$other_wt/example.service" <<'UNIT'
[Unit]
Description=Non-canonical stale copy

[Service]
ExecStart=/bin/false

[Install]
WantedBy=default.target
UNIT

# Live models.json: newer and different from repo copy -> protected hot-patch.
printf '{"providers":{"devin":{"cap":7}}}\n' >"$scratch/config/pi-models.json"
sleep 1
printf '{"providers":{"devin":{"cap":5}}}\n' >"$scratch/home/nish/.pi/agent/models.json"

# A live unit symlink pointing at the non-canonical worktree.
ln -sfn "$other_wt/example.service" \
    "$scratch/home/nish/.config/systemd/user/example.service"

cat >"$scratch/MANIFEST" <<MANIFEST
config/pi-models.json $scratch/home/nish/.pi/agent/models.json
systemd/example.service $scratch/home/nish/.config/systemd/user/example.service
MANIFEST

# Stub systemctl so the test is hermetic.
stub_systemctl="$scratch/stub-systemctl.sh"
cat >"$stub_systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"is-enabled"*) echo "disabled"; exit 0 ;;
  *"is-active --quiet"*) exit 1 ;;
  *"enable"*) exit 0 ;;
  *"enable --now"*) exit 0 ;;
  *"daemon-reload"*) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$stub_systemctl"

set +e
out=$(
  HOME="$scratch/home" \
  FLEET_OPS_WORKSPACES_ROOT="$ws_root" \
  FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir" \
  SYSTEMCTL="$stub_systemctl" \
    "$install" 2>&1
)
rc=$?
set -e

# (a) the installer refused the live config and exited non-zero
[[ "$rc" -ne 0 ]] || fail "install.sh must exit non-zero after a non-fatal REFUSE, got rc=$rc\n$out"

# The refusal is loud and explicitly marked non-fatal.
[[ "$out" == *"NONFATAL REFUSE:"* ]] || fail "expected NONFATAL REFUSE marker, got:\n$out"
[[ "$out" == *"models.json"* ]] || fail "REFUSE line must name models.json, got:\n$out"

# The protected live file was not overwritten.
[[ "$(cat "$scratch/home/nish/.pi/agent/models.json")" == '{"providers":{"devin":{"cap":5}}}' ]] \
  || fail "live models.json was overwritten despite REFUSE"

# (b) the later MANIFEST entry still ran: the symlink was retargeted to canonical.
target=$(readlink -f "$scratch/home/nish/.config/systemd/user/example.service")
[[ "$target" == "$(readlink -f "$scratch/systemd/example.service")" ]] \
  || fail "non-canonical unit symlink not retargeted; got $target"

# (c) the REFUSE line is still printed (with the new non-fatal prefix).
[[ "$out" == *"REFUSE:"* ]] || fail "expected a REFUSE line, got:\n$out"

ok "install.sh continues after non-fatal config REFUSE and a later unit is retargeted (fleet-ops#4223)"
