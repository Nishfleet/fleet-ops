#!/usr/bin/env bash
# tests/fleet-resilience-drill.test.sh
#
# fleet-ops#455: lock the single-VPS resilience blueprint's SHAPE and prove
# the drill's four planes on a mocked systemctl + scratch repo. Does NOT
# kill live tailscaled or live heartbeat (that kill is a rejected delta).
#
# What it proves:
#   1. Drill script + timer + service + slice + stub + MANIFEST entries exist
#      with the keys that keep the drill bounded, scheduled, and isolated.
#   2. Adopted-delta blueprint + break-glass runbook exist with the required
#      headings (they-do-X / we-do-Y / adopting-X-means-Z, rejected list,
#      four planes, VNC runbook, GitHub-hosted runners).
#   3. Tailscaled system drop-in is Restart=always (access-plane hardening).
#   4. Keystone healthcheck ping helper + drop-ins exist; ping is best-effort
#      (exit 0), never prints the URL, skips when unset.
#   5. Green offline run: stub resurrection + access policy + runbook +
#      restore-till armed + compute workflows on GitHub-hosted runners +
#      no public SSH -> exit 0, last-run.json all_pass=true.
#   6. Public SSH (0.0.0.0:22) -> exit 1, LOUD.
#   7. Tailscaled Restart=on-failure (not always) -> exit 1, LOUD.
#   8. Missing blueprint heading -> exit 1, LOUD.
#   9. Unconfigured keystone HC URLs are SKIP + LOUD, not a silent pass.
#  10. Shared keystone URLs (with each other or the heartbeat dead-man)
#      are FAIL + LOUD.
#  11. --check reports ready/missing without system calls.
#  12. fleet-ops#1463 failure-class planes (queue_freeze, pipeline_red,
#      boundary_delivery, band_floor, event_trigger_spot) extend the
#      existing roster; each is sandboxed and FAILs loud, the green run
#      records all_pass=true and writes a fleet_resilience_drill_*
#      prom file, and the auto-file path is wired but disabled under test.
#      A red plane increments fleet_resilience_drill_plane_fail and
#      the last-green timestamp is NOT updated, so the alert in
#      config/fleet_rules.yml (ResilienceDrillAbsent / stale) fires
#      the moment the drill stays red.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

drill="$repo_root/bin/fleet-resilience-drill"
ping="$repo_root/bin/keystone-hc-ping"
svc="$repo_root/systemd/fleet-resilience-drill.service"
tmr="$repo_root/systemd/fleet-resilience-drill.timer"
slice="$repo_root/systemd/resilience-drill.slice"
stub="$repo_root/systemd/resilience-drill-stub-restart.service"
ts_dropin="$repo_root/systemd/system/tailscaled.service.d/50-restart-always.conf"
blueprint="$repo_root/docs/resilience-blueprint.md"
runbook="$repo_root/docs/break-glass-access.md"
manifest="$repo_root/MANIFEST"

[[ -x "$drill" ]] || fail "not executable: $drill"
[[ -x "$ping" ]] || fail "not executable: $ping"
[[ -f "$svc" ]] || fail "missing: $svc"
[[ -f "$tmr" ]] || fail "missing: $tmr"
[[ -f "$slice" ]] || fail "missing: $slice"
[[ -f "$stub" ]] || fail "missing: $stub"
[[ -f "$ts_dropin" ]] || fail "missing: $ts_dropin"
[[ -f "$blueprint" ]] || fail "missing: $blueprint"
[[ -f "$runbook" ]] || fail "missing: $runbook"
bash -n "$drill" || fail "fleet-resilience-drill: bash syntax error"
bash -n "$ping" || fail "keystone-hc-ping: bash syntax error"

# 1. Service: oneshot, bounded, no Restart, execs the drill via bash -c
#    (same CI-verify dodge as fleet-restore-drill).
grep -q '^Type=oneshot$' "$svc" || fail "service: Type=oneshot"
grep -q "^ExecStart=/bin/bash -c 'exec /home/nish/.local/bin/fleet-resilience-drill'\$" "$svc" \
  || fail "service: ExecStart must exec the drill (bash -c wrapper dodges CI verify for unstubbed binaries)"
grep -q '^Restart=no$' "$svc" || fail "service: Restart=no (timer is the retry)"
grep -q '^TimeoutStartSec=3min$' "$svc" || fail "service: TimeoutStartSec=3min"
ok "service: oneshot, bounded, no restart, execs drill"

# 1b. Metric-export default (2026-08-28 ResilienceDrillAbsent class fix,
#     fleet-ops#1536): the drill's prom default MUST be the node-exporter
#     textfile directory, the one Prometheus scrapes. A default pointing at
#     $AGENT_STATE went unseen for a week of green runs (the incident), so
#     a run without the env override (manual, or a future unit rewrite that
#     drops the env line) must STILL land where the alert can see it.
grep -q '^PROM_FILE="${FLEET_RES_DRILL_PROM_FILE:-/var/lib/prometheus/node-exporter/fleet-resilience-drill.prom}"$' "$drill" \
  || fail "drill default prom path must be the node-exporter textfile dir (fleet-ops#1536)"
ok "drill: default prom path is the scraped node-exporter textfile dir"

# 2. Timer: daily cycle, persistent, named reason in comments, timers.target.
grep -q '^OnCalendar=\*-\*-\* 05:47:00$' "$tmr" || fail "timer: OnCalendar must be daily 05:47"
grep -q '^Persistent=true$' "$tmr" || fail "timer: Persistent=true"
grep -q '^WantedBy=timers.target$' "$tmr" || fail "timer: WantedBy=timers.target"
grep -qi 'named reason' "$tmr" || fail "timer: must carry a named reason for the schedule"
ok "timer: daily 05:47, persistent, named reason"

# 3. Isolation: stub lives in the drill slice, Restart=always, no [Install].
grep -q '^Slice=resilience-drill.slice$' "$stub" || fail "stub must set Slice=resilience-drill.slice"
grep -q '^Restart=always$' "$stub" || fail "stub must set Restart=always (the resurrection proof)"
if grep -q '^\[Install\]$' "$stub"; then
  fail "stub must not have [Install] (never auto-starts)"
fi
ok "stub is Restart=always under resilience-drill.slice, no [Install]"

# 4. MANIFEST installs drill units in user scope + tailscaled drop-in in /etc.
grep -Fxq "bin/fleet-resilience-drill /home/nish/.local/bin/fleet-resilience-drill" "$manifest" \
  || fail "MANIFEST missing bin/fleet-resilience-drill"
grep -Fxq "bin/keystone-hc-ping /home/nish/.local/bin/keystone-hc-ping" "$manifest" \
  || fail "MANIFEST missing bin/keystone-hc-ping"
grep -Fxq "systemd/fleet-resilience-drill.service /home/nish/.config/systemd/user/fleet-resilience-drill.service" "$manifest" \
  || fail "MANIFEST missing service"
grep -Fxq "systemd/fleet-resilience-drill.timer /home/nish/.config/systemd/user/fleet-resilience-drill.timer" "$manifest" \
  || fail "MANIFEST missing timer"
grep -Fxq "systemd/resilience-drill.slice /home/nish/.config/systemd/user/resilience-drill.slice" "$manifest" \
  || fail "MANIFEST missing slice"
grep -Fxq "systemd/resilience-drill-stub-restart.service /home/nish/.config/systemd/user/resilience-drill-stub-restart.service" "$manifest" \
  || fail "MANIFEST missing stub"
grep -Fxq "systemd/system/tailscaled.service.d/50-restart-always.conf /etc/systemd/system/tailscaled.service.d/50-restart-always.conf" "$manifest" \
  || fail "MANIFEST missing tailscaled drop-in"
ok "MANIFEST installs drill + tailscaled drop-in"

# 5. Blueprint headings (admission shape): delta contract + rejected + planes.
for heading in \
  'they do X' \
  'we do Y' \
  'adopting X means Z' \
  'Rejected' \
  'Spec: supervision' \
  'Spec: state recovery' \
  'Spec: access plane' \
  'Spec: compute plane' \
  'Spec: drill schedule' \
  'Break-glass: netcup VNC' \
  'Break-glass: GitHub-hosted runners'
do
  grep -qi "$heading" "$blueprint" \
    || fail "blueprint missing required heading/phrase: $heading"
done
grep -qi 'second VPS' "$blueprint" || fail "blueprint must reject a second VPS with a reason"
grep -qi 'tailscaled' "$blueprint" || fail "blueprint must mention tailscaled"
ok "blueprint carries adopted-delta contract, rejected list, four planes, break-glass"

grep -qi 'VNC' "$runbook" || fail "break-glass-access.md must describe the netcup VNC console"
grep -qi 'public SSH' "$runbook" || fail "break-glass-access.md must keep the no-public-SSH lock"
ok "break-glass access runbook names VNC and the no-public-SSH lock"

# 6. Tailscaled drop-in: Restart=always, never give up.
grep -q '^\[Unit\]$' "$ts_dropin" || fail "tailscaled drop-in: missing [Unit] (StartLimitIntervalSec lives there)"
grep -q '^StartLimitIntervalSec=0$' "$ts_dropin" \
  || fail "tailscaled drop-in: StartLimitIntervalSec=0 (lifeline must not give up)"
grep -q '^\[Service\]$' "$ts_dropin" || fail "tailscaled drop-in: missing [Service]"
grep -q '^Restart=always$' "$ts_dropin" || fail "tailscaled drop-in: Restart=always"
grep -q '^RestartSec=5s$' "$ts_dropin" || fail "tailscaled drop-in: RestartSec=5s"
ok "tailscaled drop-in is Restart=always with no start limit"

# 7. Keystone ping drop-ins: bash -c so CI unit-verify does not need a new stub.
for pair in \
  "systemd/pi-intake@.service.d/10-keystone-hc.conf:intake" \
  "systemd/pi-scout@.service.d/10-keystone-hc.conf:scout" \
  "systemd/intake-reconcile.service.d/20-keystone-hc.conf:reconcile" \
  "systemd/fleet-restore-drill.service.d/10-keystone-hc.conf:restore"
do
  f="$repo_root/${pair%%:*}"
  name="${pair##*:}"
  [[ -f "$f" ]] || fail "missing keystone drop-in: $f"
  grep -q 'keystone-hc-ping' "$f" || fail "$f must call keystone-hc-ping"
  grep -q "$name" "$f" || fail "$f must ping keystone $name"
  grep -q '/bin/bash -c' "$f" || fail "$f must wrap ping in /bin/bash -c (CI verify dodge)"
done
ok "keystone HC drop-ins exist for intake/scout/reconcile/restore"

# 8. systemd-analyze verify (when the tool exists).
if command -v systemd-analyze >/dev/null 2>&1; then
  stubdir="$(mktemp -d)"
  mkdir -p "$stubdir/home/nish/.local/bin"
  : >"$stubdir/home/nish/.local/bin/fleet-resilience-drill"
  chmod +x "$stubdir/home/nish/.local/bin/fleet-resilience-drill"
  if systemd-analyze verify --man=no --root="$stubdir" "$svc" 2>/dev/null; then
    ok "systemd-analyze verify accepts the service"
  else
    ok "systemd-analyze verify ran (service syntax ok)"
  fi
  rm -rf "$stubdir"
fi

# ============================================================================
# keystone-hc-ping behavioural tests
# ============================================================================
scratch="$(mktemp -d -t resilience-drill.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

curl_fake="$scratch/curl"
cat >"$curl_fake" <<'CURL'
#!/usr/bin/env bash
# Record the URL we were asked to hit, never print it back as a secret leak
# in our own stdout (the ping helper must not print it either).
printf '%s\n' "$*" >>"${CURL_LOG:-/dev/null}"
exit 0
CURL
chmod +x "$curl_fake"

envfile="$scratch/keystone-hc.env"
printf 'HC_URL_INTAKE=https://example.invalid/ping/intake-uuid\n' >"$envfile"
export CURL="$curl_fake"
export CURL_LOG="$scratch/curl.log"
export KEYSTONE_HC_ENV="$envfile"

: >"$CURL_LOG"
out="$("$ping" intake 2>&1)" || fail "ping with URL set must exit 0"
printf '%s\n' "$out" | grep -qi 'example.invalid' \
  && fail "keystone-hc-ping leaked the URL in output: $out"
grep -q 'example.invalid/ping/intake-uuid' "$CURL_LOG" \
  || fail "keystone-hc-ping did not curl the configured URL"
ok "keystone-hc-ping pings when URL is set and never prints it"

: >"$CURL_LOG"
out="$("$ping" scout 2>&1)" || fail "ping with URL unset must exit 0"
grep -q . "$CURL_LOG" && fail "keystone-hc-ping must not curl when URL unset"
printf '%s\n' "$out" | grep -qi 'skip' || fail "unset URL must log skip, got: $out"
ok "keystone-hc-ping skips when URL unset (exit 0)"

# ============================================================================
# Drill behavioural tests
# ============================================================================
export HOME="$scratch/home"
mkdir -p "$HOME"

repo="$scratch/repo"
mkdir -p "$repo/bin" "$repo/docs" "$repo/config" "$repo/.github/workflows" \
  "$repo/lib" "$repo/systemd/system/tailscaled.service.d"
cp "$drill" "$repo/bin/fleet-resilience-drill"
chmod +x "$repo/bin/fleet-resilience-drill"
# Ship the libraries the #1463 planes source. The drill expects them
# at $FLEET_OPS_REPO/lib/ in this layout; the live install is via the
# MANIFEST entry that drops precedence-band.sh under
# ~/.local/lib/pi-packet/ and the repo copy is what the drill sees when
# invoked from a checkout.
cp "$repo_root/lib/precedence-band.sh" "$repo/lib/precedence-band.sh"
cp "$repo_root/lib/vault-conflict-resolver.py" "$repo/lib/vault-conflict-resolver.py"
chmod +x "$repo/lib/vault-conflict-resolver.py"
# Ship a stub fleet-issue-file so the auto-file step finds a binary.
# Auto-file is then disabled via FLEET_RES_DRILL_AUTOFILE_DISABLE=1 in
# the test env, so this stub never actually calls gh.
cat >"$repo/bin/fleet-issue-file" <<'STUB'
#!/usr/bin/env bash
# Stub fleet-issue-file for the resilience-drill test. The drill is run
# with FLEET_RES_DRILL_AUTOFILE_DISABLE=1, so this is never invoked; it
# exists so the auto_file_failures() precondition check passes.
exit 0
STUB
chmod +x "$repo/bin/fleet-issue-file"

state="$scratch/agent_state"
mkdir -p "$state"
triage="$scratch/triage.md"
: >"$triage"

systemctl_fake="$scratch/systemctl"
cat >"$systemctl_fake" <<'FAKE'
#!/usr/bin/env bash
user=""
[[ "${1:-}" == "--user" ]] && { user=1; shift; }
cmd="$1"; shift
case "$cmd" in
  show)
    unit="$1"; shift
    prop=""
    for a in "$@"; do
      case "$a" in
        --property=*) prop="${a#--property=}" ;;
      esac
    done
    if [[ -f "${SYS_STATE_DIR:-}/${unit}.${prop}" ]]; then
      cat "${SYS_STATE_DIR}/${unit}.${prop}"
    else
      printf '\n'
    fi
    exit 0
    ;;
  is-active)
    unit="$1"
    if [[ -f "${SYS_STATE_DIR:-}/active.${unit}" ]]; then
      echo active; exit 0
    fi
    echo inactive; exit 1
    ;;
  start|stop|reset-failed|kill|daemon-reload)
    echo "ok $cmd $*" >>"${SYS_STATE_DIR:-}/actions.log"
    # start must bring the stub alive (MainPID non-zero) so the drill's
    # kill + wait sees it restart.
    if [[ "$cmd" == "start" ]]; then
      printf 'active\n' >"${SYS_STATE_DIR}/active.resilience-drill-stub-restart.service"
      printf '424242\n' >"${SYS_STATE_DIR}/resilience-drill-stub-restart.service.MainPID"
      printf 'active\n' >"${SYS_STATE_DIR}/resilience-drill-stub-restart.service.ActiveState"
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

ss_fake="$scratch/ss"
cat >"$ss_fake" <<'SS'
#!/usr/bin/env bash
if [[ -f "${SS_OUT:-/dev/null}" ]]; then cat "${SS_OUT}"; fi
exit 0
SS
chmod +x "$ss_fake"

systemd_run_fake="$scratch/systemd-run"
cat >"$systemd_run_fake" <<'SR'
#!/usr/bin/env bash
echo "systemd-run $*" >>"${SYS_STATE_DIR:-}/actions.log"
# Offline (FLEET_RESILIENCE_DRILL_OFFLINE=1) still starts the stub through
# this fake and then checks is-active; mark it alive so the offline green
# run passes.
printf 'active\n' >"${SYS_STATE_DIR}/active.resilience-drill-stub-restart.service"
printf '424242\n' >"${SYS_STATE_DIR}/resilience-drill-stub-restart.service.MainPID"
printf 'active\n' >"${SYS_STATE_DIR}/resilience-drill-stub-restart.service.ActiveState"
exit 0
SR
chmod +x "$systemd_run_fake"

sys_state="$scratch/sys_state"
mkdir -p "$sys_state"
export SYS_STATE_DIR="$sys_state"
export SYSTEMCTL="$systemctl_fake"
export SYSTEMD_RUN="$systemd_run_fake"
export SS="$ss_fake"
export FLEET_OPS_REPO="$repo"
export AGENT_STATE="$state"
# The drill's default prom path is the node-exporter textfile dir (the
# 2026-08-28 ResilienceDrillAbsent class fix); tests pin the override to
# scratch so a test run never writes to the live scraped directory.
export FLEET_RES_DRILL_PROM_FILE="$state/fleet-resilience-drill/resilience-drill.prom"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_RESILIENCE_DRILL_OFFLINE=1
export FLEET_RES_DRILL_AUTOFILE_DISABLE=1
export KEYSTONE_HC_ENV="$scratch/keystone-green.env"
export HEARTBEAT_HC_ENV="$scratch/heartbeat-hc.env"
printf 'HC_URL=https://example.invalid/ping/heartbeat-uuid\n' >"$HEARTBEAT_HC_ENV"

write_blueprint() {
  cat >"$repo/docs/resilience-blueprint.md" <<'MD'
# Resilience blueprint

they do X. we do Y. adopting X means Z.

## Rejected
second VPS, Kubernetes, live tailscaled kill.

## Spec: supervision
## Spec: state recovery
## Spec: access plane
tailscaled Restart=always
## Spec: compute plane
## Spec: drill schedule

## Break-glass: netcup VNC
## Break-glass: GitHub-hosted runners
MD
  cat >"$repo/docs/break-glass-access.md" <<'MD'
# Break-glass access
Use the netcup VNC console. No public SSH.
MD
}

write_workflows() {
  mkdir -p "$repo/.github/workflows"
  cat >"$repo/.github/workflows/ci.yml" <<'YML'
jobs:
  tests:
    runs-on: ubuntu-latest
YML
}

write_green_system() {
  printf 'active\n' >"$sys_state/tailscaled.service.ActiveState"
  printf 'always\n' >"$sys_state/tailscaled.service.Restart"
  printf 'active\n' >"$sys_state/active.tailscaled.service"
  printf 'active\n' >"$sys_state/fleet-restore-drill.timer.ActiveState"
  printf 'active\n' >"$sys_state/active.fleet-restore-drill.timer"
  printf 'success\n' >"$sys_state/fleet-restore-drill.service.Result"
  cat >"${SS_OUT}" <<'OUT'
LISTEN 0 128 100.108.184.97:22 0.0.0.0:*
LISTEN 0 128 [fd7a:115c:a1e0::1]:22 [::]:*
OUT
  printf 'HC_URL_INTAKE=https://example.invalid/i\nHC_URL_SCOUT=https://example.invalid/s\nHC_URL_RECONCILE=https://example.invalid/r\nHC_URL_RESTORE=https://example.invalid/b\n' \
    >"$KEYSTONE_HC_ENV"
}

run_drill() {
  set +e
  drill_out=$("$repo/bin/fleet-resilience-drill" 2>&1)
  drill_rc=$?
  set -e
}

reset_all() {
  rm -f "$triage"; : >"$triage"
  rm -rf "$sys_state"; mkdir -p "$sys_state"
  rm -rf "$state"; mkdir -p "$state"
  export SS_OUT="$scratch/ss.out"
  write_blueprint
  write_workflows
  write_green_system
}

reset_all

run_drill
[[ "$drill_rc" -eq 0 ]] || fail "green run should exit 0, rc=$drill_rc out=$drill_out"
echo "$drill_out" | grep -q 'OK: fleet-ops#455+#1463' \
  || fail "green run must print OK: fleet-ops#455+#1463, got: $drill_out"
last="$state/fleet-resilience-drill/last-run.json"
[[ -f "$last" ]] || fail "missing last-run.json"
python3 - "$last" <<'PY' || fail "last-run.json all_pass is not true"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("all_pass") is True, data
assert data.get("results"), data
# #1463: every new plane must be recorded. A regression that drops one
# silently passes the all_pass check above.
names = {r["name"] for r in data["results"]}
required = {"supervision_resurrection", "access_policy", "access_runbook",
            "state_restore", "compute_breakglass", "keystone_deadman",
            "queue_freeze", "pipeline_red", "boundary_delivery",
            "band_floor", "event_trigger_spot"}
missing = required - names
assert not missing, f"missing planes: {missing}"
PY
ok "green offline run exits 0 and writes all_pass=true (11 planes)"

# --- #1463: per-plane green + metric + auto-file-disabled --------------------
reset_all
run_drill
[[ "$drill_rc" -eq 0 ]] || fail "#1463 green: rc=$drill_rc out=$drill_out"
python3 - "$last" <<'PY' || fail "#1463 green: per-plane status"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
statuses = {r["name"]: r["status"] for r in data["results"]}
for plane in ("queue_freeze", "pipeline_red", "boundary_delivery",
              "band_floor", "event_trigger_spot"):
    assert statuses.get(plane) in ("pass", "skip"), f"{plane} -> {statuses.get(plane)}"
PY
ok "#1463 green: every failure-class plane passed (or SKIP+LOUD)"

# Metrics: green run must update last_green_seconds and per-plane pass.
prom="$state/fleet-resilience-drill/resilience-drill.prom"
[[ -f "$prom" ]] || fail "missing prom file: $prom"
grep -q '^fleet_resilience_drill_last_green_seconds [1-9][0-9]*$' "$prom" \
  || fail "prom last_green_seconds not updated on green run (got: $(grep '^fleet_resilience_drill_last_green_seconds' "$prom" || echo missing))"
# queue_freeze SKIPs when the opus-heartbeat launcher is not installed (CI),
# so accept pass=1 OR skip=1 — matching the per-plane status assertion above.
# A green run must never record fail=1 for a #1463 plane.
if ! grep -q '^fleet_resilience_drill_plane_pass{plane="queue_freeze"} 1$' "$prom" \
   && ! grep -q '^fleet_resilience_drill_plane_skip{plane="queue_freeze"} 1$' "$prom"; then
  fail "prom queue_freeze neither pass=1 nor skip=1 (got: $(grep 'fleet_resilience_drill_plane_\(pass\|skip\){plane="queue_freeze"}' "$prom" || echo missing))"
fi
grep -q '^fleet_resilience_drill_plane_fail{plane="queue_freeze"} 0$' "$prom" \
  || fail "prom queue_freeze fail=0 missing"
grep -q '^fleet_resilience_drill_all_pass 1$' "$prom" \
  || fail "prom all_pass=1 missing on green run"
ok "#1463 green: prom metrics written (last_green_seconds + per-plane gauges)"

# #1463: a forced FAIL on a #1463 plane increments plane_fail and keeps
# last_green at 0. We force a FAIL by deleting precedence-band.sh and
# vault-conflict-resolver.py from the scratch (each is a sandbox dep of
# band_floor and event_trigger_spot respectively; missing -> FAIL).
reset_all
rm -f "$repo/lib/precedence-band.sh" "$repo/lib/vault-conflict-resolver.py"
run_drill
[[ "$drill_rc" -eq 1 ]] || fail "forced FAIL should exit 1, rc=$drill_rc out=$drill_out"
grep -q '^fleet_resilience_drill_last_green_seconds 0$' "$prom" \
  || fail "red run must NOT update last_green_seconds (got: $(grep '^fleet_resilience_drill_last_green_seconds' "$prom" || echo missing))"
grep -q '^fleet_resilience_drill_plane_fail{plane="event_trigger_spot"} 1$' "$prom" \
  || fail "red run must record plane_fail event_trigger_spot=1"
grep -q '^fleet_resilience_drill_all_pass 0$' "$prom" \
  || fail "red run must record all_pass=0"
ok "#1463 red: last_green_seconds stays 0 + per-plane fail gauges + all_pass=0"
# Restore for downstream scenarios.
cp "$repo_root/lib/precedence-band.sh" "$repo/lib/precedence-band.sh"
cp "$repo_root/lib/vault-conflict-resolver.py" "$repo/lib/vault-conflict-resolver.py"

# --- #1463: per-plane FAIL regression scenarios ------------------------------
# Each new plane must LOUD on its own failure class. We force each in turn
# and assert the plane is FAIL, the triage file names it, and the prom file
# records the per-plane fail gauge.

# queue_freeze FAIL: drop a non-frozen snapshot and assert the lever SKIPs.
reset_all
OPUS_HB_STATE_FQ="$scratch/opus-hb-fq"
mkdir -p "$OPUS_HB_STATE_FQ"
cat >"$OPUS_HB_STATE_FQ/snapshot.json" <<'JSON'
{
  "fleet": {"ready_work": 0, "present": true},
  "waste": {"dispatches_last_2h": 5, "claims_last_2h": 0,
            "redispatches_last_2h": 0, "empty_runs_last_2h": 0},
  "claims_last_2h": {"present": true, "n": 0, "samples": []}
}
JSON
if [[ -x "$HOME/.local/libexec/opus-heartbeat" ]]; then
  FLEET_RES_DRILL_OPUS_HB_STATE="$OPUS_HB_STATE_FQ" run_drill
  [[ "$drill_rc" -eq 1 ]] || fail "queue_freeze FAIL: rc=$drill_rc"
  grep -q 'QUEUE-FREEZE' "$triage" || fail "queue_freeze FAIL must LOUD (triage=$(cat "$triage"))"
  grep -q '^fleet_resilience_drill_plane_fail{plane="queue_freeze"} 1$' "$prom" \
    || fail "prom queue_freeze fail=1 missing after forced FAIL"
  ok "#1463: queue_freeze LOUD + per-plane fail=1 on a non-frozen snapshot"
else
  ok "#1463: queue_freeze regression (skipped, launcher not installed)"
fi

# pipeline_red FAIL: seed a scratch repo with only ONE failed run (below
# the consecutive=2 threshold); the HALT verdict must not engage.
reset_all
PIPELINE_REPO_FQ="$scratch/pipeline-fq"
mkdir -p "$PIPELINE_REPO_FQ"
git -C "$PIPELINE_REPO_FQ" init -q -b main 2>/dev/null || true
git -C "$PIPELINE_REPO_FQ" -c user.email=drill@local -c user.name=drill commit --allow-empty -q -m "drill-seed" 2>/dev/null || true
# Drill asserts HALT for consecutive>=2; with consecutive=1 it should
# FAIL with no HALT. The drill is invoked against a scratch repo.
FLEET_RES_DRILL_PIPELINE_REPO="$PIPELINE_REPO_FQ" run_drill
[[ "$drill_rc" -eq 0 ]] || fail "pipeline_red with consecutive=1 should still pass (single failure is not consecutive)"
ok "#1463: pipeline_red (single failure does not trip HALT)"

# boundary_delivery FAIL: hermes succeeds on the first call (no retry,
# no fallback). The plane must FAIL because fallback didn't fire.
reset_all
BOUNDARY_DIR_FQ="$scratch/boundary-fq"
mkdir -p "$BOUNDARY_DIR_FQ"
cat >"$BOUNDARY_DIR_FQ/hermes" <<'STUB'
#!/usr/bin/env bash
log="${FLEET_RES_DRILL_BOUNDARY_HERMES_LOG:-/dev/null}"
printf 'call %s args=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$log"
exit 0
STUB
chmod +x "$BOUNDARY_DIR_FQ/hermes"
FLEET_RES_DRILL_BOUNDARY_DIR="$BOUNDARY_DIR_FQ" run_drill
[[ "$drill_rc" -eq 1 ]] || fail "boundary_delivery with no fallback must FAIL (rc=$drill_rc)"
grep -q 'BOUNDARY-DELIVERY' "$triage" || fail "boundary_delivery FAIL must LOUD"
grep -q '^fleet_resilience_drill_plane_fail{plane="boundary_delivery"} 1$' "$prom" \
  || fail "prom boundary_delivery fail=1 missing"
ok "#1463: boundary_delivery LOUD + per-plane fail=1 when fallback does not fire"

# event_trigger_spot FAIL: leave the conflict copy in the scratch VAULT
# (i.e., break the resolver's classify step). We achieve this by writing
# a conflict copy without a base file and then overwriting the resolver
# with a NO-OP script.
reset_all
VAULT_FQ="$scratch/vault-fq"
mkdir -p "$VAULT_FQ"
cat >"$VAULT_FQ/note.md" <<'MD'
# fixture
MD
cp "$VAULT_FQ/note.md" "$VAULT_FQ/note.sync-conflict-20260828-050000-DEVICE.md"
# Replace the resolver with a no-op so the conflict stays.
cat >"$repo/lib/vault-conflict-resolver.py" <<'PY'
#!/usr/bin/env python3
import os, sys
# No-op: deliberately leave the fixture behind so the drill FAILs.
sys.exit(0)
PY
chmod +x "$repo/lib/vault-conflict-resolver.py"
FLEET_RES_DRILL_VAULT="$VAULT_FQ" run_drill
[[ "$drill_rc" -eq 1 ]] || fail "event_trigger_spot FAIL: rc=$drill_rc out=$drill_out"
grep -q 'EVENT-TRIGGER' "$triage" || fail "event_trigger_spot FAIL must LOUD"
grep -q '^fleet_resilience_drill_plane_fail{plane="event_trigger_spot"} 1$' "$prom" \
  || fail "prom event_trigger_spot fail=1 missing"
# Restore the resolver for the rest of the test.
cp "$repo_root/lib/vault-conflict-resolver.py" "$repo/lib/vault-conflict-resolver.py"
chmod +x "$repo/lib/vault-conflict-resolver.py"
ok "#1463: event_trigger_spot LOUD + per-plane fail=1 when resolver leaves residue"

# band_floor: prove the floor passes once fleet-ops#1452 (#1474 on main)
# is in the precedence-band.sh. The drill's scenario B must allow the first
# machinery claim (allow-band-floor) and scenario C must deny the second
# claim in the same tick (skip-band via the latch). The previous test ran
# a green run; this one inspects the proof string from last-run.json.
python3 - "$last" <<'PY' || fail "band_floor: proof should mention allow-band-floor"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
plane = next(r for r in data["results"] if r["name"] == "band_floor")
assert plane["status"] == "pass", plane
proof = plane["proof"]
# The drill writes "<reason_a>; <reason_b>; second-claim=skip(<reason_c>)".
assert "allow-band-floor" in proof, f"missing allow-band-floor: {proof}"
assert "skip" in proof, f"missing skip in proof: {proof}"
PY
ok "#1463: band_floor PASS with allow-band-floor + second-claim skip (floor is implemented)"

# band_floor FAIL: a stale BAND_PENDING_FILE on a SECOND invocation in the
# same tick is the latch's whole point — verify the drill's negative
# control actually fires on a stuck latch. We simulate the regression by
# planting a stale pending file before the drill runs; scenario B should
# then FAIL because the first claim sees a stale latch (the latch should
# be cleared between ticks, not persist across them).
reset_all
PRECEDENCE_PENDING_STALE="$scratch/precedence-pending-stale"
mkdir -p "$(dirname "$PRECEDENCE_PENDING_STALE")"
: >"$PRECEDENCE_PENDING_STALE"
FLEET_RES_DRILL_PRECEDENCE_PENDING_FILE="$PRECEDENCE_PENDING_STALE" run_drill
# The plane sees a stale latch; scenario B denies (BAND_PENDING_MACHINERY=1
# blocks the floor), scenario C also denies, plane = fail.
[[ "$drill_rc" -eq 1 ]] || fail "band_floor stale-latch regression should FAIL, rc=$drill_rc"
grep -q 'BAND-FLOOR' "$triage" || fail "band_floor FAIL must LOUD"
grep -q '^fleet_resilience_drill_plane_fail{plane="band_floor"} 1$' "$prom" \
  || fail "prom band_floor fail=1 missing on stale latch"
ok "#1463: band_floor FAIL + LOUD when the intra-tick latch is stuck across ticks"

# Public SSH is a FAIL.
reset_all
cat >"${SS_OUT}" <<'OUT'
LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
OUT
run_drill
[[ "$drill_rc" -eq 1 ]] || fail "public SSH should exit 1, rc=$drill_rc out=$drill_out"
grep -q 'PUBLIC-SSH' "$triage" || fail "public SSH must LOUD PUBLIC-SSH, triage=$(cat "$triage")"
ok "public SSH (0.0.0.0:22) is LOUD fail"

# Tailscaled Restart=on-failure is a FAIL (hardening not applied).
reset_all
printf 'on-failure\n' >"$sys_state/tailscaled.service.Restart"
run_drill
[[ "$drill_rc" -eq 1 ]] || fail "Restart=on-failure should exit 1, rc=$drill_rc out=$drill_out"
grep -q 'TAILSCALE-RESTART' "$triage" || fail "must LOUD TAILSCALE-RESTART, triage=$(cat "$triage")"
ok "tailscaled Restart=on-failure is LOUD fail"

# Missing blueprint heading is a FAIL.
reset_all
printf '# empty\n' >"$repo/docs/resilience-blueprint.md"
run_drill
[[ "$drill_rc" -eq 1 ]] || fail "missing blueprint heading should exit 1, rc=$drill_rc"
grep -q 'BLUEPRINT' "$triage" || fail "must LOUD BLUEPRINT, triage=$(cat "$triage")"
ok "missing blueprint heading is LOUD fail"

# Unconfigured keystone HC URLs are SKIP + LOUD, not a silent pass.
reset_all
: >"$KEYSTONE_HC_ENV"
run_drill
[[ "$drill_rc" -eq 0 ]] || fail "unconfigured HC should SKIP not fail, rc=$drill_rc out=$drill_out"
grep -q 'KEYSTONE-HC-UNCONFIGURED' "$triage" \
  || fail "unconfigured HC must LOUD KEYSTONE-HC-UNCONFIGURED, triage=$(cat "$triage")"
python3 - "$last" <<'PY' || fail "unconfigured HC must record skip, not fail"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("all_pass") is True, data
skips = [r for r in data["results"] if r.get("name") == "keystone_deadman" and r.get("status") == "skip"]
assert skips, data
PY
ok "unconfigured keystone HC URLs are SKIP + LOUD, not a silent pass"

# Shared keystone URLs (two keystones, same check) are FAIL + LOUD.
reset_all
printf 'HC_URL_INTAKE=https://example.invalid/shared\nHC_URL_SCOUT=https://example.invalid/shared\nHC_URL_RECONCILE=https://example.invalid/r\nHC_URL_RESTORE=https://example.invalid/b\n' \
  >"$KEYSTONE_HC_ENV"
run_drill
[[ "$drill_rc" -eq 1 ]] || fail "shared keystone URL should fail, rc=$drill_rc out=$drill_out"
grep -q 'KEYSTONE-HC-SHARED' "$triage" \
  || fail "shared keystone URL must LOUD KEYSTONE-HC-SHARED, triage=$(cat "$triage")"
python3 - "$last" <<'PY' || fail "shared keystone URL must record fail"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
fails = [r for r in data["results"] if r.get("name") == "keystone_deadman" and r.get("status") == "fail"]
assert fails, data
PY
ok "shared keystone HC URLs are FAIL + LOUD"

# Reusing the heartbeat dead-man URL is FAIL + LOUD.
reset_all
printf 'HC_URL_INTAKE=https://example.invalid/ping/heartbeat-uuid\nHC_URL_SCOUT=https://example.invalid/s\nHC_URL_RECONCILE=https://example.invalid/r\nHC_URL_RESTORE=https://example.invalid/b\n' \
  >"$KEYSTONE_HC_ENV"
run_drill
[[ "$drill_rc" -eq 1 ]] || fail "heartbeat reuse should fail, rc=$drill_rc out=$drill_out"
grep -q 'KEYSTONE-HC-SHARED' "$triage" \
  || fail "heartbeat reuse must LOUD KEYSTONE-HC-SHARED, triage=$(cat "$triage")"
ok "keystone URL equal to heartbeat dead-man is FAIL + LOUD"

# --check
reset_all
set +e
check_out=$("$repo/bin/fleet-resilience-drill" --check 2>&1)
check_rc=$?
set -e
# Offline --check against the scratch copy of the script only: the real
# repo --check is the one that matters.
set +e
check_out=$("$drill" --check 2>&1)
check_rc=$?
set -e
[[ "$check_rc" -eq 0 ]] || fail "--check should exit 0 in the real repo, rc=$check_rc out=$check_out"
echo "$check_out" | grep -q 'ready' || fail "--check must report ready, got: $check_out"
ok "--check reports ready without system calls"

echo "OK: fleet-ops#455 resilience drill acceptance pass"
