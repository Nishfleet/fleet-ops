#!/usr/bin/env bash
# tests/install-litellm-proxy-seed-once.test.sh
#
# fleet-ops#4379: config/litellm-proxy.yaml is seed-once (operator-owned
# live). When the live file exists, install.sh must log INFO (not LOUD /
# NONFATAL REFUSE) and exit rc=0 for that entry. When the live file is
# absent (fresh checkout), install.sh must install the seed as a copy.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
install_src="$repo_root/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$install_src" ]] || fail "not executable: $install_src"

scratch="$(mktemp -d -t install-litellm-seed.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

install="$scratch/install.sh"
cp -a "$install_src" "$install"
chmod +x "$install"

# Fake a canonical deploy clone.
ws_root="$scratch/workspaces"
canon_dir="$ws_root/tooling/fleet-ops-deploy-clone"
mkdir -p "$canon_dir" "$scratch/config" \
         "$scratch/home/nish/.config/fleet-ops"

# Repo-side seed (the placeholder shape reference).
cat >"$scratch/config/litellm-proxy.yaml" <<'YAML'
# seed / shape reference
model_list:
  - model_name: worker-cheap
    litellm_params:
      model: openai/deepseek-v4-flash
      api_base: https://opencode.example/v1
      api_key: command:/home/nish/.local/bin/opencode-key
YAML

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

# ---------------------------------------------------------------------------
# Test 1: live file PRESENT -> seed-once skip, INFO log, rc=0
# ---------------------------------------------------------------------------

# Create a live file that is operator-owned (deliberately different).
cat >"$scratch/home/nish/.config/fleet-ops/litellm-proxy.yaml" <<'YAML'
# operator-owned LIVE config — real keys, real baseUrls
model_list:
  - model_name: worker-cheap
    litellm_params:
      model: openai/deepseek-v4-flash
      api_base: https://real-api.example/v1
      api_key: command:/home/nish/.local/bin/real-key-resolver
YAML

# Make the live file older than repo so the test does not accidentally
# pass via the mtime guard — seed-once must protect regardless of mtime.
touch -t 202601010000 "$scratch/home/nish/.config/fleet-ops/litellm-proxy.yaml"

cat >"$scratch/MANIFEST" <<MANIFEST
config/litellm-proxy.yaml $scratch/home/nish/.config/fleet-ops/litellm-proxy.yaml
MANIFEST

live_before="$(cat "$scratch/home/nish/.config/fleet-ops/litellm-proxy.yaml")"

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

# (a) rc=0 — seed-once skip is not a failure.
[[ "$rc" -eq 0 ]] || fail "install.sh must exit 0 when litellm-proxy.yaml seed-once skips, got rc=$rc\n$out"

# (b) INFO line present, no LOUD / NONFATAL REFUSE.
[[ "$out" == *"INFO:"*"seed-once"* ]] || fail "expected INFO seed-once line, got:\n$out"
[[ "$out" != *"NONFATAL REFUSE"* ]] || fail "seed-once must not produce NONFATAL REFUSE, got:\n$out"
[[ "$out" != *"LOUD"* ]] || fail "seed-once must not produce LOUD line, got:\n$out"

# (c) Live file was NOT overwritten.
live_after="$(cat "$scratch/home/nish/.config/fleet-ops/litellm-proxy.yaml")"
[[ "$live_before" = "$live_after" ]] || fail "live litellm-proxy.yaml was overwritten despite seed-once"

ok "test 1: seed-once skip when live file present (fleet-ops#4379)"

# ---------------------------------------------------------------------------
# Test 2: live file ABSENT -> seed installed as a copy
# ---------------------------------------------------------------------------

rm -f "$scratch/home/nish/.config/fleet-ops/litellm-proxy.yaml"

set +e
out2=$(
  HOME="$scratch/home" \
  FLEET_OPS_WORKSPACES_ROOT="$ws_root" \
  FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir" \
  SYSTEMCTL="$stub_systemctl" \
    "$install" 2>&1
)
rc2=$?
set -e

# (a) rc=0 — seed install succeeds.
[[ "$rc2" -eq 0 ]] || fail "install.sh must exit 0 when seed installs, got rc=$rc2\n$out2"

# (b) The live file now exists and matches the repo seed.
[[ -f "$scratch/home/nish/.config/fleet-ops/litellm-proxy.yaml" ]] \
  || fail "seed was not installed to live path"

cmp -s "$scratch/config/litellm-proxy.yaml" "$scratch/home/nish/.config/fleet-ops/litellm-proxy.yaml" \
  || fail "installed seed differs from repo copy"

# (c) The installed file is a regular file (copy), not a symlink.
[[ ! -L "$scratch/home/nish/.config/fleet-ops/litellm-proxy.yaml" ]] \
  || fail "seed must be a copy, not a symlink"

ok "test 2: seed installed when live file absent (fleet-ops#4379)"

# ---------------------------------------------------------------------------
# Test 3: drift mode (--check) with live file present -> no DIFF, rc=0
# ---------------------------------------------------------------------------

# Restore the operator-owned live file.
cat >"$scratch/home/nish/.config/fleet-ops/litellm-proxy.yaml" <<'YAML'
# operator-owned LIVE config — real keys, real baseUrls
model_list:
  - model_name: worker-cheap
    litellm_params:
      model: openai/deepseek-v4-flash
      api_base: https://real-api.example/v1
      api_key: command:/home/nish/.local/bin/real-key-resolver
YAML

set +e
out3=$(
  HOME="$scratch/home" \
  FLEET_OPS_WORKSPACES_ROOT="$ws_root" \
  FLEET_OPS_CANONICAL_CHECKOUT="$canon_dir" \
  SYSTEMCTL="$stub_systemctl" \
    "$install" --check 2>&1
)
rc3=$?
set -e

[[ "$rc3" -eq 0 ]] || fail "drift --check must exit 0 for seed-once file, got rc=$rc3\n$out3"
[[ "$out3" != *"DIFF:"* ]] || fail "drift --check must not flag seed-once file as DIFF, got:\n$out3"

ok "test 3: drift --check skips seed-once file (fleet-ops#4379)"

echo ""
echo "All tests passed (fleet-ops#4379)."
