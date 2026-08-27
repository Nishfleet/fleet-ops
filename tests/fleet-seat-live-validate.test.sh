#!/usr/bin/env bash
# tests/fleet-seat-live-validate.test.sh
#
# Proves the SuperGrok live-validate canary (fleet-ops#917) offline:
#   1. grok binary missing -> exit 1, LOUD watcher-broken.
#   2. grok models "not authenticated" + no auth.json -> exit 0 (observe-to-
#      open), credentials_bad ledger, auto-file, LOUD.
#   3. grok models "logged in" + auth.json present -> exit 0, healthy
#      ledger, no file. Fake token in auth.json never appears in output.
#   4. grok models "not authenticated" + auth.json present (refresh failed)
#      -> exit 0, credentials_bad, auto-file.
#   5. Dedup: open issue already carrying the marker -> no second create.
#   6. Dedup: open issue titled like fleet-ops#917 -> no second create.
#   7. pi auth check status=ready while grok CLI is dead is the #917 class
#      (presence vs live) and still files.
#   8. grok models timeout (rc 124) -> needs-interactive, exit 0.
#   9. Heartbeat-tier1 wires the canary, fail-loud on watcher-broken,
#      MANIFEST installs it.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-seat-live-validate"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"

scratch="$(mktemp -d -t seat-live-validate.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME" "$scratch/bin"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_SEAT_LIVE_VALIDATE_REPO="Nishfleet/fleet-ops"
export FLEET_SEAT_LIVE_VALIDATE_FILE=1
export GROK_HOME="$scratch/grok"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
mkdir -p "$GROK_HOME" "$PI_SEAT_HEALTH_LEDGER_DIR"
AUTH_JSON="$GROK_HOME/auth.json"

FAKE_TOKEN="TEST-TOKEN-DO-NOT-LEAK-xyz789"

gh_log="$scratch/gh.log"
gh_fake="$scratch/bin/gh"
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

grok_fake="$scratch/bin/grok"
cat >"$grok_fake" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "models" ]]; then
  if [[ -n "${GROK_MODELS_SLEEP:-}" ]]; then
    sleep "$GROK_MODELS_SLEEP"
  fi
  if [[ -f "${GROK_MODELS_FIXTURE:-/dev/null}" ]]; then
    cat "$GROK_MODELS_FIXTURE"
  fi
  exit "${GROK_MODELS_RC:-0}"
fi
exit 0
FAKE
chmod +x "$grok_fake"
export FLEET_GROK_BIN="$grok_fake"
export PATH="$scratch/bin:$PATH"

run_canary() {
  set +e
  env_out=$("$bin" 2>&1)
  env_rc=$?
  set -e
}

assert_no_token_leak() {
  if grep -F "$FAKE_TOKEN" <<<"$env_out" >/dev/null 2>&1; then
    fail "output leaked FAKE_TOKEN: $env_out"
  fi
  if grep -F "$FAKE_TOKEN" "$triage" >/dev/null 2>&1; then
    fail "triage leaked FAKE_TOKEN"
  fi
  if grep -F "$FAKE_TOKEN" "$gh_log" >/dev/null 2>&1; then
    fail "gh log leaked FAKE_TOKEN"
  fi
}

ledger_class() {
  local model="$1"
  jq -r '.health_class' "$PI_SEAT_HEALTH_LEDGER_DIR/grok__${model}.json"
}

# --- 1. grok missing -> watcher-broken, exit 1 -----------------------------
: >"$gh_log"; : >"$triage"
export FLEET_GROK_BIN="$scratch/bin/no-such-grok"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario1: expected rc=1, got $env_rc ($env_out)"
grep -q 'SEAT-LIVE-VALIDATE-WATCHER-BROKEN' "$triage" \
  || fail "scenario1: missing LOUD watcher-broken ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario1: must auto-file"
ok "scenario1: grok missing is fail-loud watcher-broken"
export FLEET_GROK_BIN="$grok_fake"

# --- 2. not authenticated + no auth.json -> dead, observe-to-open ----------
: >"$gh_log"; : >"$triage"
rm -f "$AUTH_JSON" 2>/dev/null || true
AUTH_JSON="$GROK_HOME/auth.json"
printf '%s\n' "You are not authenticated." >"$scratch/models.txt"
printf '%s\n' "" >>"$scratch/models.txt"
printf '%s\n' "Default model: grok-4.6" >>"$scratch/models.txt"
printf '%s\n' "Available models:" >>"$scratch/models.txt"
printf '%s\n' "  * grok-4.6 (default)" >>"$scratch/models.txt"
export GROK_MODELS_FIXTURE="$scratch/models.txt"
export GROK_MODELS_RC=0
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario2: expected rc=0, got $env_rc ($env_out)"
grep -q 'SEAT-LIVE-VALIDATE-GROK-DEAD' "$triage" \
  || fail "scenario2: missing LOUD grok-dead"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file"
grep -q -- '--search' "$gh_log" || fail "scenario2: gh issue list must use --search (newest-50 missed #917)"
[[ "$(ledger_class grok-4.6)" == "credentials_bad" ]] \
  || fail "scenario2: grok-4.6 ledger must be credentials_bad"
[[ "$(ledger_class grok-4.5)" == "credentials_bad" ]] \
  || fail "scenario2: grok-4.5 ledger must be credentials_bad"
jq -e '.seat_dead == true' "$PI_SEAT_HEALTH_LEDGER_DIR/grok__grok-4.6.json" >/dev/null \
  || fail "scenario2: seat_dead must be true"
ok "scenario2: unauthenticated + missing auth.json writes credentials_bad and files"

# --- 3. logged in + auth.json -> healthy, no file, no token leak -----------
: >"$gh_log"; : >"$triage"
mkdir -p "$GROK_HOME"
printf '%s\n' "{\"dummy\":{\"key\":\"$FAKE_TOKEN\"}}" >"$AUTH_JSON"
chmod 600 "$AUTH_JSON"
printf '%s\n' "You are logged in with grok.com." >"$scratch/models.txt"
printf '%s\n' "Default model: grok-4.6" >>"$scratch/models.txt"
export GROK_MODELS_FIXTURE="$scratch/models.txt"
export GROK_MODELS_RC=0
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario3: expected rc=0, got $env_rc ($env_out)"
grep -q 'SEAT-LIVE-VALIDATE-OK' "$triage" || fail "scenario3: missing OK line"
! grep -q 'issue create' "$gh_log" || fail "scenario3: must not file when healthy"
[[ "$(ledger_class grok-4.6)" == "healthy" ]] \
  || fail "scenario3: grok-4.6 must be healthy"
assert_no_token_leak
ok "scenario3: logged-in grok is healthy; token never printed"

# --- 4. not authenticated + auth.json present (refresh failed) -------------
: >"$gh_log"; : >"$triage"
printf '%s\n' "{\"dummy\":{\"key\":\"$FAKE_TOKEN\"}}" >"$AUTH_JSON"
printf '%s\n' "You are not authenticated." >"$scratch/models.txt"
export GROK_MODELS_FIXTURE="$scratch/models.txt"
export GROK_MODELS_RC=0
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario4: expected rc=0, got $env_rc ($env_out)"
grep -q 'SEAT-LIVE-VALIDATE-GROK-DEAD' "$triage" || fail "scenario4: missing LOUD"
grep -q 'issue create' "$gh_log" || fail "scenario4: must auto-file"
[[ "$(ledger_class grok-4.6)" == "credentials_bad" ]] \
  || fail "scenario4: refresh-failed must write credentials_bad"
assert_no_token_leak
ok "scenario4: auth.json present but still unauthenticated is dead"

# --- 5. dedup on marker ----------------------------------------------------
: >"$gh_log"; : >"$triage"
rm -f "$AUTH_JSON"
printf '%s\n' "You are not authenticated." >"$scratch/models.txt"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n '[{number:917,title:"other",body:"seat-live-validate: grok needs-interactive"}]' \
  >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario5: expected rc=0, got $env_rc ($env_out)"
! grep -q 'issue create' "$gh_log" || fail "scenario5: must dedupe marker"
ok "scenario5: open issue with marker is not re-filed"
unset GH_OPEN_ISSUES

# --- 6. dedup on live #917 title -------------------------------------------
: >"$gh_log"; : >"$triage"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n '[{number:917,title:"SuperGrok pi seat dead: x.ai returns 403 OAuth-invalid; pi auth reports ready",body:"no marker yet"}]' \
  >"$GH_OPEN_ISSUES"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario6: expected rc=0, got $env_rc ($env_out)"
! grep -q 'issue create' "$gh_log" || fail "scenario6: must dedupe #917 title"
ok "scenario6: SuperGrok pi seat dead title is not re-filed"
unset GH_OPEN_ISSUES
rm -f "$scratch/open.json"

# --- 7. pi auth check ready + grok dead is the #917 class ------------------
: >"$gh_log"; : >"$triage"
rm -f "$AUTH_JSON"
printf '%s\n' "You are not authenticated." >"$scratch/models.txt"
printf '%s\n' '{"status":"ready","provider":"grok"}' >"$scratch/pi-auth.json"
export FLEET_PI_AUTH_CHECK_JSON="$scratch/pi-auth.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario7: expected rc=0, got $env_rc ($env_out)"
grep -q 'status=ready (presence only)' "$triage" \
  || fail "scenario7: must name the presence-vs-live class ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario7: must auto-file"
ok "scenario7: pi auth check ready while grok CLI is dead is named as the class"
unset FLEET_PI_AUTH_CHECK_JSON

# --- 8. grok models timeout -> needs-interactive, exit 0 -------------------
: >"$gh_log"; : >"$triage"
rm -f "$AUTH_JSON"
: >"$scratch/models.txt"
export GROK_MODELS_FIXTURE="$scratch/models.txt"
export GROK_MODELS_SLEEP=5
export FLEET_GROK_MODELS_TIMEOUT=1
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario8: expected rc=0, got $env_rc ($env_out)"
grep -q 'SEAT-LIVE-VALIDATE-GROK-DEAD' "$triage" || fail "scenario8: missing LOUD"
grep -q 'timed out' "$triage" || fail "scenario8: must name the timeout"
ok "scenario8: grok models timeout is needs-interactive, tick stays green"
unset GROK_MODELS_SLEEP
unset FLEET_GROK_MODELS_TIMEOUT

# --- 9. heartbeat wiring ---------------------------------------------------
grep -F 'fleet-seat-live-validate' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-seat-live-validate"
grep -F 'seat_live_validate_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture seat_live_validate_rc"
grep -F -- '_propagate_crash seat_live_validate_rc' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the live-validate watcher is broken"
grep -q 'bin/fleet-seat-live-validate' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-seat-live-validate"
ok "scenario9: heartbeat-tier1 wires the canary, fail-loud on watcher-broken, MANIFEST installs it"

echo "OK: fleet-seat-live-validate: watcher-broken, unauthenticated, healthy, refresh-failed, dedup, class, timeout, heartbeat wiring"
