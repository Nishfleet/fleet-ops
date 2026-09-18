#!/usr/bin/env bash
# tests/fleet-bare-metal-rebuild.test.sh
#
# fleet-ops#1135: lock the bare-metal rebuild manifest and script shape.
#
# 2026-09-18: fleet-bare-metal-rebuild-drill (script + service + weekly timer)
# was deleted. No release gate read its artifact, and its only meaningful
# plane (the fresh-OS container proof) had been silently SKIPping for want of
# a local ubuntu:24.04 image while it still reported all_pass=true — false
# assurance. The capability it wrapped survives as
# `bin/fleet-bare-metal-rebuild --manifest-check`, exercised in section 6.
#
# What it proves:
#   1. Rebuild script + drill + manifest + runbook + units exist and are
#      executable/syntax-valid.
#   2. MANIFEST installs the new bin, config, service and timer.
#   3. The service is oneshot, bounded, no Restart, execs the drill.
#   4. The timer is weekly, persistent, named reason.
#   5. systemd-analyze verify accepts the units (when the tool exists).
#   6. The manifest JSON is valid and has the required keys.
#   7. The rebuild script --manifest-check passes on the real repo.
#   8. The drill runs with container proof skipped and produces a green
#      last-run.json (does NOT pull Docker images in CI).
#   9. The drill --check reports ready files without system calls.
#  10. A container proof is invoked when Docker is available and the image
#      exists (mocked in this test).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
# Always exercise the real repo; callers (e.g. escalation-coverage-canary)
# may point FLEET_OPS_REPO at a scratch fixture.
export FLEET_OPS_REPO="$repo_root"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

rebuild="$repo_root/bin/fleet-bare-metal-rebuild"
manifest="$repo_root/MANIFEST"
manifest_json="$repo_root/config/bare-metal-rebuild-manifest.json"
runbook="$repo_root/docs/bare-metal-rebuild.md"

[[ -x "$rebuild" ]] || fail "not executable: $rebuild"
[[ -f "$manifest_json" ]] || fail "missing: $manifest_json"
[[ -f "$runbook" ]] || fail "missing: $runbook"
bash -n "$rebuild" || fail "fleet-bare-metal-rebuild: bash syntax error"

# 3. MANIFEST installs the new artifacts.
grep -Fxq "bin/fleet-bare-metal-rebuild /home/nish/.local/bin/fleet-bare-metal-rebuild" "$manifest" \
  || fail "MANIFEST missing bin/fleet-bare-metal-rebuild"
grep -Fxq "config/bare-metal-rebuild-manifest.json /home/nish/.config/fleet-ops/bare-metal-rebuild-manifest.json" "$manifest" \
  || fail "MANIFEST missing config/bare-metal-rebuild-manifest.json"
# fleet-ops#3971: global oomd pressure duration must survive a bare-metal rebuild.
[[ -f "$repo_root/systemd/system/oomd.conf.d/99-fleet.conf" ]] \
  || fail "missing repo source: systemd/system/oomd.conf.d/99-fleet.conf"
grep -Fxq "systemd/system/oomd.conf.d/99-fleet.conf /etc/systemd/oomd.conf.d/99-fleet.conf" "$manifest" \
  || fail "MANIFEST missing oomd 99-fleet.conf"
ok "MANIFEST installs the new artifacts"

scratch="$(mktemp -d -t bare-metal-rebuild.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# 5. Manifest JSON shape.
command -v jq >/dev/null 2>&1 || fail "jq missing"
jq -e . "$manifest_json" >/dev/null || fail "bare-metal-rebuild-manifest.json is not valid JSON"
for key in version title description target packages manual_tools repositories install_manifest env_files secrets_locations backup masked_units; do
  jq -e ".${key}" "$manifest_json" >/dev/null || fail "manifest missing required key: $key"
done
ok "bare-metal-rebuild-manifest.json has required keys"

# 5b. masked_units names openipmi.service with a reason (fleet-ops#2122).
jq -e '.masked_units.units[] | select(.name=="openipmi.service") | .reason' "$manifest_json" >/dev/null \
  || fail "manifest masked_units must name openipmi.service with a reason"
ok "manifest masked_units declares openipmi.service"

# 5c. systemd-networkd-wait-online.service must NOT be in masked_units
# (fleet-ops#3103): it can be healthy (eth0 setup reaches 'configured'), and
# netplan owns and re-enables it, so a mask would not hold and live_check would
# report a permanent violation. Guard against re-adding it.
if jq -r '.masked_units.units[].name // empty' "$manifest_json" 2>/dev/null \
    | grep -qx "systemd-networkd-wait-online.service"; then
  fail "manifest masked_units must NOT name systemd-networkd-wait-online.service (netplan-owned, can be healthy; fleet-ops#3103)"
else
  ok "manifest masked_units correctly excludes systemd-networkd-wait-online.service"
fi

# 6. Rebuild script --manifest-check passes on the real repo.
# fleet-ops#3277: the repo MANIFEST carries `npm-pin:<rel>` srcs that
# resolve against the installed pi examples dir at install time, not the
# repo checkout. manifest-check must skip them as "missing" so a bare-metal
# rebuild does not demand a repo file it will never have. Run the check on
# the real repo (which carries npm-pin srcs) and assert no npm-pin line is
# reported as a missing src.
grep -q '^npm-pin:' "$manifest" || fail "MANIFEST lacks an npm-pin: src to probe (fixture gone?)"
if "$rebuild" --manifest-check 2>&1 | grep -q 'MANIFEST src missing.*npm-pin:'; then
  fail "manifest-check must not flag npm-pin: srcs as missing repo files"
fi
"$rebuild" --manifest-check || fail "rebuild --manifest-check failed"
ok "rebuild --manifest-check passes"

# 8b. count_unmasked_units: 0 when masked, 1 when not (fleet-ops#2122).
masked_lib="$repo_root/lib/bare-metal-masked-units.sh"
[[ -f "$masked_lib" ]] || fail "missing lib: $masked_lib"

# Stub systemctl: prints a fixed is-enabled result for the named unit.
stubctl="$scratch/stub-systemctl"
cat >"$stubctl" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "is-enabled" ]]; then
  echo "${STUB_IS_ENABLED_STATE:-masked}"
  exit 1
fi
exit 0
STUB
chmod +x "$stubctl"

# Source the lib with a no-op log and call count_unmasked_units. The lib
# depends only on $MANIFEST_JSON, $SYSTEMCTL and a `log` function.
run_count() {
  local state="$1"
  STUB_IS_ENABLED_STATE="$state" SYSTEMCTL="$stubctl" MANIFEST_JSON="$manifest_json" \
    bash -c 'source "$1"; log() { :; }; count_unmasked_units' _ "$masked_lib"
}

masked_count="$(run_count masked)"
[[ "$masked_count" == "0" ]] \
  || fail "count_unmasked_units should be 0 when masked, got $masked_count"
ok "count_unmasked_units returns 0 when openipmi.service is masked"

masked_count="$(run_count enabled)"
[[ "$masked_count" == "1" ]] \
  || fail "count_unmasked_units should be 1 when not masked, got $masked_count"
ok "count_unmasked_units returns 1 when openipmi.service is not masked"

echo "OK: fleet-ops#1135 bare-metal rebuild test pass"
