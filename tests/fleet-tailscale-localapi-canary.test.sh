#!/usr/bin/env bash
# tests/fleet-tailscale-localapi-canary.test.sh
#
# Proves the tailscaled localapi socket-reachability canary (fleet-ops#2151)
# offline:
#   1. Clean: unprivileged `tailscale status` succeeds with peers -> OK, no file.
#   2. Permission denied on socket -> exit 1, LOUD, auto-files.
#   3. Daemon not responding -> exit 1, LOUD, auto-files.
#   4. Status OK but zero peers (isolated node) -> exit 1, LOUD, auto-files.
#   5. Missing fixture -> exit 1, watcher-broken.
#   6. Dedup: open issue already carrying the marker -> no second create.
#   7. Heartbeat-tier1 wires the canary (block 42); MANIFEST installs it.
#   8. Live VPS (when unprivileged tailscale status works) must pass.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-tailscale-localapi-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"
command -v jq >/dev/null 2>&1 || fail "jq missing"
bash -n "$bin" || fail "bash syntax error in canary"
bash -n "$tier1" || fail "bash syntax error in tier1"

scratch="$(mktemp -d -t tailscale-localapi-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_TAILSCALE_LOCALAPI_REPO="Nishfleet/fleet-ops"
export FLEET_TAILSCALE_LOCALAPI_FILE=1
export FLEET_OPS_REPO="$repo_root"

gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export PATH="$scratch:$PATH"

run_canary() {
  FLEET_TAILSCALE_STATUS_FIXTURE="$scratch/status.out" \
  FLEET_TAILSCALE_STATUS_FIXTURE_RC="${STATUS_RC:-0}" \
  FLEET_TAILSCALE_STATUS_FIXTURE_ERR="${STATUS_ERR:-}" \
  "$bin" 2>&1
}

# --- 1. clean: status OK with peers ---------------------------------------
: >"$gh_log"; : >"$triage"
cat >"$scratch/status.out" <<'OUT'
100.108.184.97  netcup-rs2000         nishant345@  linux  -
100.82.230.76   hostinger-kvm4        nishant345@  linux  offline, last seen 19d ago
100.120.128.16  nishants-macbook-air  nishant345@  macOS  offline, last seen 1d ago
OUT
out=$(run_canary) || fail "scenario1: clean status must exit 0 ($out)"
grep -q 'OK: unprivileged tailscale status reached localapi' <<<"$out" \
  || fail "scenario1: must log OK ($out)"
grep -q 'TAILSCALE-LOCALAPI-OK' "$triage" \
  || fail "scenario1: must write OK marker to triage"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario1: must not file ($gh_log)"
fi
ok "scenario1: clean unprivileged status with peers is green"

# --- 2. permission denied on socket ---------------------------------------
: >"$gh_log"; : >"$triage"
STATUS_RC=1
STATUS_ERR="failed to connect to local tailscaled (which appears to be running as tailscaled, pid 903). Got error: Failed to connect to local Tailscale daemon for /localapi/v0/status; not running? Error: dial unix /var/run/tailscale/tailscaled.sock: connect: permission denied"
out=$(run_canary) && fail "scenario2: permission denied must exit non-zero"
rc=$?
[[ "$rc" -eq 1 ]] || fail "scenario2: must exit 1, got $rc"
grep -q 'TAILSCALE-LOCALAPI-UNREACHABLE' <<<"$out" \
  || fail "scenario2: must log UNREACHABLE ($out)"
grep -q 'issue create' "$gh_log" \
  || fail "scenario2: must auto-file ($gh_log)"
grep -q 'tailscale-localapi-canary: localapi-unreachable' "$gh_log" \
  || fail "scenario2: filed issue must carry the marker"
ok "scenario2: permission denied -> exit 1, LOUD, auto-files"

# --- 3. daemon not responding ---------------------------------------------
: >"$gh_log"; : >"$triage"
STATUS_RC=1
STATUS_ERR="Failed to connect to local Tailscale daemon for /localapi/v0/status; not running?"
out=$(run_canary) && fail "scenario3: daemon not responding must exit non-zero"
rc=$?
[[ "$rc" -eq 1 ]] || fail "scenario3: must exit 1, got $rc"
grep -q 'TAILSCALE-LOCALAPI-UNREACHABLE' <<<"$out" \
  || fail "scenario3: must log UNREACHABLE ($out)"
ok "scenario3: daemon not responding -> exit 1, LOUD"

# --- 4. status OK but zero peers (isolated) -------------------------------
: >"$gh_log"; : >"$triage"
STATUS_RC=0
STATUS_ERR=""
# A status with no peer lines (e.g. just the self line without a 100.x prefix,
# or empty). Use a header-only / empty body.
printf '' >"$scratch/status.out"
out=$(run_canary) && fail "scenario4: isolated node must exit non-zero"
rc=$?
[[ "$rc" -eq 1 ]] || fail "scenario4: must exit 1, got $rc"
grep -q 'TAILSCALE-LOCALAPI-NO-PEERS' <<<"$out" \
  || fail "scenario4: must log NO-PEERS ($out)"
grep -q 'issue create' "$gh_log" \
  || fail "scenario4: must auto-file ($gh_log)"
ok "scenario4: isolated node (no peers) -> exit 1, LOUD, auto-files"

# --- 5. missing fixture -> watcher-broken ---------------------------------
: >"$gh_log"; : >"$triage"
out=$(FLEET_TAILSCALE_STATUS_FIXTURE="$scratch/does-not-exist.out" \
      FLEET_TAILSCALE_STATUS_FIXTURE_RC=0 \
      "$bin" 2>&1) && fail "scenario5: missing fixture must exit non-zero"
rc=$?
[[ "$rc" -eq 1 ]] || fail "scenario5: must exit 1, got $rc"
grep -q 'TAILSCALE-LOCALAPI-WATCHER-BROKEN' <<<"$out" \
  || fail "scenario5: must log WATCHER-BROKEN ($out)"
ok "scenario5: missing fixture -> watcher-broken"

# --- 6. dedup: open issue already carrying the marker ---------------------
: >"$gh_log"; : >"$triage"
STATUS_RC=1
STATUS_ERR="permission denied"
cat >"$scratch/open.json" <<'JSON'
[{"number": 2151, "body": "some text\ntailscale-localapi-canary: localapi-unreachable\nmore text"}]
JSON
out=$(GH_OPEN_ISSUES="$scratch/open.json" run_canary) && fail "scenario6: dedup case must exit non-zero (canary still fails)"
rc=$?
[[ "$rc" -eq 1 ]] || fail "scenario6: canary must still exit 1 on the fault, got $rc"
if grep -q 'issue create' "$gh_log"; then
  fail "scenario6: must not create a duplicate ($gh_log)"
fi
ok "scenario6: dedup suppresses second create, canary still fails loud"

# --- 7. heartbeat-tier1 wires block 42 + MANIFEST installs the canary -----
grep -q '42. Tailscale localapi socket reachability canary' "$tier1" \
  || fail "tier1 missing block 42 header"
grep -q 'FLEET_TAILSCALE_LOCALAPI_CANARY' "$tier1" \
  || fail "tier1 missing FLEET_TAILSCALE_LOCALAPI_CANARY var"
grep -q 'tailscale_localapi_canary_rc' "$tier1" \
  || fail "tier1 missing tailscale_localapi_canary_rc propagation"
grep -q 'tailscale_localapi_canary_rc=${tailscale_localapi_canary_rc:-0}' "$tier1" \
  || fail "tier1 complete-log missing tailscale_localapi_canary_rc"
grep -Fxq "bin/fleet-tailscale-localapi-canary /home/nish/.local/bin/fleet-tailscale-localapi-canary" "$manifest" \
  || fail "MANIFEST missing fleet-tailscale-localapi-canary entry"
ok "scenario7: tier1 block 42 + MANIFEST entry wired"

# --- 8. live VPS (when unprivileged tailscale status works) ---------------
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status >/dev/null 2>&1; then
    : >"$gh_log"; : >"$triage"
    export FLEET_TAILSCALE_LOCALAPI_FILE=0
    out=$(unset FLEET_TAILSCALE_STATUS_FIXTURE FLEET_TAILSCALE_STATUS_FIXTURE_RC FLEET_TAILSCALE_STATUS_FIXTURE_ERR; "$bin" 2>&1) \
      || fail "scenario8: live VPS run must exit 0 ($out)"
    grep -q 'OK: unprivileged tailscale status reached localapi' <<<"$out" \
      || fail "scenario8: live run must log OK ($out)"
    ok "scenario8: live VPS unprivileged tailscale status passes"
  else
    ok "scenario8: skipped (unprivileged tailscale status not green on this host)"
  fi
else
  ok "scenario8: skipped (no tailscale binary on this host)"
fi

echo "OK: tailscale localapi socket-reachability canary locked (fleet-ops#2151)"
