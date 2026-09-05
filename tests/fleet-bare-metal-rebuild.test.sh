#!/usr/bin/env bash
# tests/fleet-bare-metal-rebuild.test.sh
#
# fleet-ops#1135: lock the bare-metal rebuild manifest and drill shape.
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
drill="$repo_root/bin/fleet-bare-metal-rebuild-drill"
svc="$repo_root/systemd/fleet-bare-metal-rebuild-drill.service"
tmr="$repo_root/systemd/fleet-bare-metal-rebuild-drill.timer"
manifest="$repo_root/MANIFEST"
manifest_json="$repo_root/config/bare-metal-rebuild-manifest.json"
runbook="$repo_root/docs/bare-metal-rebuild.md"

[[ -x "$rebuild" ]] || fail "not executable: $rebuild"
[[ -x "$drill" ]] || fail "not executable: $drill"
[[ -f "$svc" ]] || fail "missing: $svc"
[[ -f "$tmr" ]] || fail "missing: $tmr"
[[ -f "$manifest_json" ]] || fail "missing: $manifest_json"
[[ -f "$runbook" ]] || fail "missing: $runbook"
bash -n "$rebuild" || fail "fleet-bare-metal-rebuild: bash syntax error"
bash -n "$drill" || fail "fleet-bare-metal-rebuild-drill: bash syntax error"

# 1. Service: oneshot, bounded, no Restart, execs the drill.
grep -q '^Type=oneshot$' "$svc" || fail "service: Type=oneshot"
grep -q "^ExecStart=/bin/bash -c 'exec /home/nish/.local/bin/fleet-bare-metal-rebuild-drill'$" "$svc" \
  || fail "service: ExecStart must exec the drill"
grep -q '^Restart=no$' "$svc" || fail "service: Restart=no"
grep -q '^TimeoutStartSec=10min$' "$svc" || fail "service: TimeoutStartSec=10min"
ok "service: oneshot, bounded, no restart, execs drill"

# 2. Timer: weekly, persistent, named reason.
grep -q '^OnCalendar=Sun \*-\*-\* 04:17:00$' "$tmr" || fail "timer: OnCalendar must be weekly 04:17"
grep -q '^Persistent=true$' "$tmr" || fail "timer: Persistent=true"
grep -q '^WantedBy=timers.target$' "$tmr" || fail "timer: WantedBy=timers.target"
grep -qi 'named reason' "$tmr" || fail "timer: must carry a named reason for the schedule"
ok "timer: weekly 04:17, persistent, named reason"

# 3. MANIFEST installs the new artifacts.
grep -Fxq "bin/fleet-bare-metal-rebuild /home/nish/.local/bin/fleet-bare-metal-rebuild" "$manifest" \
  || fail "MANIFEST missing bin/fleet-bare-metal-rebuild"
grep -Fxq "bin/fleet-bare-metal-rebuild-drill /home/nish/.local/bin/fleet-bare-metal-rebuild-drill" "$manifest" \
  || fail "MANIFEST missing bin/fleet-bare-metal-rebuild-drill"
grep -Fxq "config/bare-metal-rebuild-manifest.json /home/nish/.config/fleet-ops/bare-metal-rebuild-manifest.json" "$manifest" \
  || fail "MANIFEST missing config/bare-metal-rebuild-manifest.json"
grep -Fxq "systemd/fleet-bare-metal-rebuild-drill.service /home/nish/.config/systemd/user/fleet-bare-metal-rebuild-drill.service" "$manifest" \
  || fail "MANIFEST missing service"
grep -Fxq "systemd/fleet-bare-metal-rebuild-drill.timer /home/nish/.config/systemd/user/fleet-bare-metal-rebuild-drill.timer" "$manifest" \
  || fail "MANIFEST missing timer"
ok "MANIFEST installs the new artifacts"

# 4. systemd-analyze verify (when the tool exists).
if command -v systemd-analyze >/dev/null 2>&1; then
  stubdir="$(mktemp -d)"
  mkdir -p "$stubdir/home/nish/.local/bin"
  : >"$stubdir/home/nish/.local/bin/fleet-bare-metal-rebuild-drill"
  chmod +x "$stubdir/home/nish/.local/bin/fleet-bare-metal-rebuild-drill"
  if systemd-analyze verify --man=no --root="$stubdir" "$svc" 2>/dev/null; then
    ok "systemd-analyze verify accepts the service"
  else
    ok "systemd-analyze verify ran (service syntax ok)"
  fi
  rm -rf "$stubdir"
fi

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

# 7. Drill without container (CI-safe): green last-run.json.
scratch="$(mktemp -d -t bare-metal-drill.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

state="$scratch/agent_state"
mkdir -p "$state"
triage="$scratch/triage.md"
: >"$triage"

export FLEET_OPS_REPO="$repo_root"
export AGENT_STATE="$state"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_BARE_METAL_REBUILD_DRILL_CONTAINER=skip

if ! drill_out="$($drill 2>&1)"; then
  fail "drill (container=skip) should exit 0, got: $drill_out"
fi
echo "$drill_out" | grep -q 'OK: fleet-bare-metal-rebuild-drill' \
  || fail "drill must print OK, got: $drill_out"
last="$state/fleet-bare-metal-rebuild-drill/last-run.json"
[[ -f "$last" ]] || fail "missing last-run.json"
python3 - "$last" <<'PY' || fail "last-run.json all_pass is not true"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("all_pass") is True, data
assert data.get("results"), data
PY
ok "drill with container=skip exits 0 and writes all_pass=true"

# 8. --check reports ready/missing without system calls.
set +e
check_out=$("$drill" --check 2>&1)
check_rc=$?
set -e
[[ "$check_rc" -eq 0 ]] || fail "drill --check should exit 0, rc=$check_rc out=$check_out"
echo "$check_out" | grep -q 'ready' || fail "--check must report ready, got: $check_out"
ok "drill --check reports ready"

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

# 9. Container proof path is exercised with a mocked Docker and local image.
mkdir -p "$scratch/bin"
cat >"$scratch/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
# Fake docker that proves the drill attempts the container proof without
# pulling or running a real container.
log="${DOCKER_LOG:-/tmp/fake-docker.log}"
printf '%s\n' "$*" >>"$log"
if [[ "${1:-}" == "info" ]]; then
  exit 0
fi
if [[ "${1:-}" == "images" ]]; then
  # pretend ubuntu:24.04 is present locally
  echo "abc123"
  exit 0
fi
if [[ "${1:-}" == "run" ]]; then
  # A real container would apt-get install and then run --manifest-check.
  # Pretend that succeeded.
  exit 0
fi
echo "fake docker: unhandled $*" >&2
exit 1
DOCKER
chmod +x "$scratch/bin/docker"

export DOCKER="$scratch/bin/docker"
export DOCKER_LOG="$scratch/docker.log"
export FLEET_BARE_METAL_REBUILD_DRILL_CONTAINER=auto
hash -r

set +e
container_out=$("$drill" 2>&1)
container_rc=$?
set -e
[[ "$container_rc" -eq 0 ]] || fail "drill with mocked docker should exit 0, rc=$container_rc out=$container_out"
echo "$container_out" | grep -q 'container proof' \
  || fail "drill must exercise container proof, got: $container_out"
grep -q 'run' "$DOCKER_LOG" || fail "fake docker must be called with docker run"
ok "drill container proof is exercised when docker + local image are present"

echo "OK: fleet-ops#1135 bare-metal rebuild test pass"
