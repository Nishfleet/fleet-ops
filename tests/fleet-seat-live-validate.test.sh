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
# fleet-ops#3661: the canary now rejects phantom seat keys (a provider/model
# pair not present in seat-caps.json providers.<p>.models.<m>) with a LOUD
# SEAT-KEY-INVALID line and writes nothing. Point it at a scratch caps
# fixture that includes the grok/xai-oauth models it paints, so the guard is
# exercised deterministically (the real seat-caps.json is absent on hosted
# CI and would otherwise fail-open).
cat > "$scratch/seat-caps.json" <<'CAPS'
{
  "providers": {
    "grok": {"models": {"grok-4.6": 0, "grok-4.5": 0}},
    "xai-oauth": {"models": {"grok-4.6": 2, "grok-4.5": 0}}
  }
}
CAPS
export FLEET_SEAT_CAPS_JSON="$scratch/seat-caps.json"
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

# xai-oauth state is independent of the grok CLI. Each scenario below sets
# FLEET_XAI_OAUTH_PROBE so the canary's validate_xai_oauth sees a known
# value without making a real api.x.ai call. The probe file's first line
# is "ok" or "dead".
write_xai_probe() {
    local val="$1"
    printf '%s\n' "$val" >"$scratch/xai_probe"
    export FLEET_XAI_OAUTH_PROBE="$scratch/xai_probe"
}

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

xai_oauth_ledger_class() {
  local model="$1"
  jq -r '.health_class' "$PI_SEAT_HEALTH_LEDGER_DIR/xai-oauth__${model}.json"
}

# --- 1. grok missing -> watcher-broken, exit 1 -----------------------------
# xai-oauth is independent. Even when the grok watch is broken, the
# xai-oauth seat can be healthy — the canary must report that, not blindly
# mark xai-oauth credentials_bad. Here xai-oauth is dead (probe=dead); the
# canary writes both ledgers as credentials_bad and files a single finding.
: >"$gh_log"; : >"$triage"
write_xai_probe dead
export FLEET_GROK_BIN="$scratch/bin/no-such-grok"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario1: expected rc=1, got $env_rc ($env_out)"
grep -q 'SEAT-LIVE-VALIDATE-WATCHER-BROKEN' "$triage" \
  || fail "scenario1: missing LOUD watcher-broken ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario1: must auto-file"
[[ "$(xai_oauth_ledger_class grok-4.6)" == "credentials_bad" ]] \
  || fail "scenario1: xai-oauth must be credentials_bad when xai probe=dead"
ok "scenario1: grok missing is fail-loud watcher-broken; xai-oauth independently reported"
export FLEET_GROK_BIN="$grok_fake"
write_xai_probe ok
unset FLEET_XAI_OAUTH_PROBE

# --- 2. not authenticated + no auth.json -> dead, observe-to-open ----------
# Both grok and xai-oauth are dead. The canary writes both bad and files
# a finding for the both-dead class.
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
write_xai_probe dead
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
[[ "$(xai_oauth_ledger_class grok-4.6)" == "credentials_bad" ]] \
  || fail "scenario2: xai-oauth/grok-4.6 ledger must be credentials_bad"
[[ "$(xai_oauth_ledger_class grok-4.5)" == "credentials_bad" ]] \
  || fail "scenario2: xai-oauth/grok-4.5 ledger must be credentials_bad"
jq -e '.seat_dead == true' "$PI_SEAT_HEALTH_LEDGER_DIR/grok__grok-4.6.json" >/dev/null \
  || fail "scenario2: seat_dead must be true"
jq -e '.seat_dead == true' "$PI_SEAT_HEALTH_LEDGER_DIR/xai-oauth__grok-4.6.json" >/dev/null \
  || fail "scenario2: xai-oauth seat_dead must be true"
ok "scenario2: unauthenticated + missing auth.json writes credentials_bad and files"

# --- 3. logged in + auth.json -> healthy, no file, no token leak -----------
# Both grok and xai-oauth are healthy. The canary must report both healthy
# and NOT file a finding.
: >"$gh_log"; : >"$triage"
mkdir -p "$GROK_HOME"
printf '%s\n' "{\"dummy\":{\"key\":\"$FAKE_TOKEN\"}}" >"$AUTH_JSON"
chmod 600 "$AUTH_JSON"
printf '%s\n' "You are logged in with grok.com." >"$scratch/models.txt"
printf '%s\n' "Default model: grok-4.6" >>"$scratch/models.txt"
export GROK_MODELS_FIXTURE="$scratch/models.txt"
export GROK_MODELS_RC=0
write_xai_probe ok
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario3: expected rc=0, got $env_rc ($env_out)"
grep -q 'SEAT-LIVE-VALIDATE-OK' "$triage" || fail "scenario3: missing OK line"
! grep -q 'issue create' "$gh_log" || fail "scenario3: must not file when healthy"
[[ "$(ledger_class grok-4.6)" == "healthy" ]] \
  || fail "scenario3: grok-4.6 must be healthy"
[[ "$(xai_oauth_ledger_class grok-4.6)" == "healthy" ]] \
  || fail "scenario3: xai-oauth/grok-4.6 must be healthy"
[[ "$(xai_oauth_ledger_class grok-4.5)" == "healthy" ]] \
  || fail "scenario3: xai-oauth/grok-4.5 must be healthy"
assert_no_token_leak
ok "scenario3: logged-in grok is healthy; xai-oauth independently healthy; token never printed"

# --- 4. not authenticated + auth.json present (refresh failed) -------------
# Both dead. The canary writes both bad and files a finding.
: >"$gh_log"; : >"$triage"
printf '%s\n' "{\"dummy\":{\"key\":\"$FAKE_TOKEN\"}}" >"$AUTH_JSON"
printf '%s\n' "You are not authenticated." >"$scratch/models.txt"
export GROK_MODELS_FIXTURE="$scratch/models.txt"
export GROK_MODELS_RC=0
write_xai_probe dead
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario4: expected rc=0, got $env_rc ($env_out)"
grep -q 'SEAT-LIVE-VALIDATE-GROK-DEAD' "$triage" || fail "scenario4: missing LOUD"
grep -q 'issue create' "$gh_log" || fail "scenario4: must auto-file"
[[ "$(ledger_class grok-4.6)" == "credentials_bad" ]] \
  || fail "scenario4: refresh-failed must write credentials_bad"
[[ "$(ledger_class grok-4.5)" == "credentials_bad" ]] \
  || fail "scenario4: grok-4.5 must be credentials_bad"
[[ "$(xai_oauth_ledger_class grok-4.6)" == "credentials_bad" ]] \
  || fail "scenario4: xai-oauth/grok-4.6 must be credentials_bad"
[[ "$(xai_oauth_ledger_class grok-4.5)" == "credentials_bad" ]] \
  || fail "scenario4: xai-oauth/grok-4.5 must be credentials_bad"
assert_no_token_leak
ok "scenario4: auth.json present but still unauthenticated is dead; xai-oauth independently dead"

# --- 5. dedup on marker ----------------------------------------------------
: >"$gh_log"; : >"$triage"
rm -f "$AUTH_JSON"
printf '%s\n' "You are not authenticated." >"$scratch/models.txt"
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n '[{number:917,title:"other",body:"seat-live-validate: grok needs-interactive"}]' \
  >"$GH_OPEN_ISSUES"
write_xai_probe dead
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
write_xai_probe dead
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario6: expected rc=0, got $env_rc ($env_out)"
! grep -q 'issue create' "$gh_log" || fail "scenario6: must dedupe #917 title"
ok "scenario6: SuperGrok pi seat dead title is not re-filed"
unset GH_OPEN_ISSUES
rm -f "$scratch/open.json"

# --- 7. pi auth check ready + grok dead is the #917 class ------------------
# Both dead: pi auth reports ready (presence only) while the live grok CLI
# is dead AND xai-oauth is independently dead. The finding must name the
# presence-vs-live class.
: >"$gh_log"; : >"$triage"
rm -f "$AUTH_JSON"
printf '%s\n' "You are not authenticated." >"$scratch/models.txt"
printf '%s\n' '{"status":"ready","provider":"grok"}' >"$scratch/pi-auth.json"
export FLEET_PI_AUTH_CHECK_JSON="$scratch/pi-auth.json"
write_xai_probe dead
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario7: expected rc=0, got $env_rc ($env_out)"
grep -q 'status=ready (presence only)' "$triage" \
  || fail "scenario7: must name the presence-vs-live class ($env_out)"
grep -q 'issue create' "$gh_log" || fail "scenario7: must auto-file"
ok "scenario7: pi auth check ready while grok CLI is dead is named as the class"
unset FLEET_PI_AUTH_CHECK_JSON

# --- 8. grok models timeout -> needs-interactive, exit 0 -------------------
# grok dead (timeout), xai-oauth dead.
: >"$gh_log"; : >"$triage"
rm -f "$AUTH_JSON"
: >"$scratch/models.txt"
export GROK_MODELS_FIXTURE="$scratch/models.txt"
export GROK_MODELS_SLEEP=5
export FLEET_GROK_MODELS_TIMEOUT=1
write_xai_probe dead
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario8: expected rc=0, got $env_rc ($env_out)"
grep -q 'SEAT-LIVE-VALIDATE-GROK-DEAD' "$triage" || fail "scenario8: missing LOUD"
grep -q 'timed out' "$triage" || fail "scenario8: must name the timeout"
[[ "$(xai_oauth_ledger_class grok-4.6)" == "credentials_bad" ]] \
  || fail "scenario8: xai-oauth/grok-4.6 must be credentials_bad"
[[ "$(xai_oauth_ledger_class grok-4.5)" == "credentials_bad" ]] \
  || fail "scenario8: xai-oauth/grok-4.5 must be credentials_bad"
ok "scenario8: grok models timeout is needs-interactive, tick stays green; xai-oauth independently dead"
unset GROK_MODELS_SLEEP
unset FLEET_GROK_MODELS_TIMEOUT

# --- 9. THE #1450 FIX: grok dead + xai-oauth healthy ------------------------
# The original bug: when the grok CLI was dead, the canary wrote
# credentials_bad on xai-oauth/* too, even though the xai-oauth extension
# had a fresh, valid token. This is the scenario that produced the #1450
# "all four Grok seats 401" report.
#
# The fix: validate_xai_oauth makes a live probe and writes the xai-oauth
# ledger independently. When xai-oauth is healthy, it is NOT marked dead.
: >"$gh_log"; : >"$triage"
rm -f "$AUTH_JSON"
printf '%s\n' "You are not authenticated." >"$scratch/models.txt"
export GROK_MODELS_FIXTURE="$scratch/models.txt"
export GROK_MODELS_RC=0
write_xai_probe ok
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario9: expected rc=0, got $env_rc ($env_out)"
grep -q 'SEAT-LIVE-VALIDATE-GROK-DEAD' "$triage" || fail "scenario9: must LOUD grok-dead"
grep -q 'SEAT-LIVE-VALIDATE-GROK-DEAD-XAI-OK' "$triage" \
  || fail "scenario9: must name the grok-dead/xai-ok split"
grep -q 'issue create' "$gh_log" || fail "scenario9: must auto-file (grok dead alone is still a finding)"
[[ "$(ledger_class grok-4.6)" == "credentials_bad" ]] \
  || fail "scenario9: grok/grok-4.6 must be credentials_bad"
[[ "$(xai_oauth_ledger_class grok-4.6)" == "healthy" ]] \
  || fail "scenario9: xai-oauth/grok-4.6 must be healthy (the #1450 fix)"
[[ "$(xai_oauth_ledger_class grok-4.5)" == "healthy" ]] \
  || fail "scenario9: xai-oauth/grok-4.5 must be healthy (the #1450 fix)"
jq -e '.seat_dead == false' "$PI_SEAT_HEALTH_LEDGER_DIR/xai-oauth__grok-4.6.json" >/dev/null \
  || fail "scenario9: xai-oauth seat_dead must be false"
ok "scenario9: grok dead + xai-oauth healthy does NOT mark xai-oauth dead (the #1450 fix)"

# --- 10. grok healthy + xai-oauth dead (rare but real) ---------------------
# The mirror case: grok CLI is healthy but the xai-oauth extension token
# has expired independently. The canary must report the xai-oauth seat
# dead and file a finding for it.
: >"$gh_log"; : >"$triage"
mkdir -p "$GROK_HOME"
printf '%s\n' "{\"dummy\":{\"key\":\"$FAKE_TOKEN\"}}" >"$AUTH_JSON"
chmod 600 "$AUTH_JSON"
printf '%s\n' "You are logged in with grok.com." >"$scratch/models.txt"
export GROK_MODELS_FIXTURE="$scratch/models.txt"
export GROK_MODELS_RC=0
write_xai_probe dead
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario10: expected rc=0, got $env_rc ($env_out)"
grep -q 'SEAT-LIVE-VALIDATE-OK' "$triage" \
  || fail "scenario10: grok healthy must still emit OK (grok watch is fine)"
grep -q 'issue create' "$gh_log" \
  || fail "scenario10: must auto-file for the xai-oauth-only dead class"
[[ "$(ledger_class grok-4.6)" == "healthy" ]] \
  || fail "scenario10: grok-4.6 must be healthy"
[[ "$(xai_oauth_ledger_class grok-4.6)" == "credentials_bad" ]] \
  || fail "scenario10: xai-oauth/grok-4.6 must be credentials_bad"
assert_no_token_leak
ok "scenario10: grok healthy + xai-oauth dead marks only xai-oauth dead and files"
unset FLEET_XAI_OAUTH_PROBE

# --- 11. heartbeat wiring --------------------------------------------------
grep -F 'fleet-seat-live-validate' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-seat-live-validate"
grep -F 'seat_live_validate_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture seat_live_validate_rc"
grep -F -- 'exit "$seat_live_validate_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the live-validate watcher is broken"
grep -q 'bin/fleet-seat-live-validate' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-seat-live-validate"
ok "scenario11: heartbeat-tier1 wires the canary, fail-loud on watcher-broken, MANIFEST installs it"

# --- 12. THE #1441 FIX: probe the subscription proxy, not api.x.ai --------
# The original bug: validate_xai_oauth probed api.x.ai/v1/models, the
# API-credit endpoint. The xai-oauth token is a SuperGrok SUBSCRIPTION
# credential that the extension routes through cli-chat-proxy.grok.com,
# so api.x.ai returns 403 spending-limit even when the seat is alive.
# The canary falsely marked all four Grok seats credentials_bad while the
# proxy returned 200 (fleet-ops#1441).
#
# The fix: probe cli-chat-proxy.grok.com/v1/models with the proxy identity
# headers (buildProxyHeaders in models.ts). This scenario uses a fake curl
# that records the URL + headers it was called with and returns 200, then
# asserts the canary hit the proxy (never api.x.ai) and marked xai-oauth
# healthy. unset FLEET_XAI_OAUTH_PROBE so the real probe path runs.
: >"$gh_log"; : >"$triage"
mkdir -p "$GROK_HOME"
printf '%s\n' "{\"dummy\":{\"key\":\"$FAKE_TOKEN\"}}" >"$AUTH_JSON"
chmod 600 "$AUTH_JSON"
printf '%s\n' "You are logged in with grok.com." >"$scratch/models.txt"
export GROK_MODELS_FIXTURE="$scratch/models.txt"
export GROK_MODELS_RC=0
unset FLEET_XAI_OAUTH_PROBE
# validate_xai_oauth reads the xai-oauth token from PI_AGENT_AUTH_JSON
# (default ~/.pi/agent/auth.json), NOT the grok CLI's $GROK_HOME/auth.json.
# Point it at a file carrying an xai-oauth access token so the probe
# reaches the curl call the fake intercepts.
pi_auth_json="$scratch/pi-auth.json"
printf '%s\n' "{\"xai-oauth\":{\"access\":\"$FAKE_TOKEN\",\"refresh\":\"r\",\"type\":\"oauth\"}}" >"$pi_auth_json"
chmod 600 "$pi_auth_json"
export PI_AGENT_AUTH_JSON="$pi_auth_json"

curl_log="$scratch/curl.log"
curl_fake="$scratch/bin/curl"
cat >"$curl_fake" <<'FAKE'
#!/usr/bin/env bash
# Record every arg so the test can assert the probe URL + headers.
printf '%s\n' "$*" >>"${CURL_LOG:-/dev/null}"
# Return 200 for the subscription proxy, 403 for api.x.ai (the spending-
# limit false-negative the fix removes). Inspect the last argv for the URL.
for a in "$@"; do :; done
case "$a" in
  *cli-chat-proxy.grok.com*) printf '200'; exit 0 ;;
  *api.x.ai*) printf '403'; exit 0 ;;
  *) printf '200'; exit 0 ;;
esac
FAKE
chmod +x "$curl_fake"
export CURL_LOG="$curl_log"
# The canary hardcodes PATH and resolves curl via FLEET_CURL_BIN (mirrors
# FLEET_GROK_BIN / FLEET_PI_BIN), so override the binary directly rather
# than relying on PATH.
export FLEET_CURL_BIN="$curl_fake"

run_canary
[[ "$env_rc" == "0" ]] || fail "scenario12: expected rc=0, got $env_rc ($env_out)"
# The probe MUST hit the subscription proxy, never api.x.ai.
grep -q 'cli-chat-proxy.grok.com/v1/models' "$curl_log" \
  || fail "scenario12: probe must call cli-chat-proxy.grok.com ($curl_log)"
! grep -q 'api.x.ai/v1/models' "$curl_log" \
  || fail "scenario12: probe must NOT call api.x.ai (the #1441 false negative)"
# The proxy identity headers the extension sends must be present.
grep -q 'x-grok-client-identifier: grok-shell' "$curl_log" \
  || fail "scenario12: probe must send x-grok-client-identifier"
grep -q 'X-XAI-Token-Auth: xai-grok-cli' "$curl_log" \
  || fail "scenario12: probe must send X-XAI-Token-Auth"
# A 200 from the proxy marks xai-oauth healthy — the seat is alive.
[[ "$(xai_oauth_ledger_class grok-4.6)" == "healthy" ]] \
  || fail "scenario12: xai-oauth/grok-4.6 must be healthy when proxy returns 200 (the #1441 fix)"
[[ "$(xai_oauth_ledger_class grok-4.5)" == "healthy" ]] \
  || fail "scenario12: xai-oauth/grok-4.5 must be healthy when proxy returns 200"
jq -e '.seat_dead == false' "$PI_SEAT_HEALTH_LEDGER_DIR/xai-oauth__grok-4.6.json" >/dev/null \
  || fail "scenario12: xai-oauth seat_dead must be false"
assert_no_token_leak
ok "scenario12: probe hits cli-chat-proxy.grok.com (not api.x.ai), 200 marks xai-oauth healthy (the #1441 fix)"
unset CURL_LOG
unset FLEET_CURL_BIN
unset PI_AGENT_AUTH_JSON

echo "OK: fleet-seat-live-validate: watcher-broken, unauthenticated, healthy, refresh-failed, dedup, class, timeout, grok-dead+xai-ok, grok-ok+xai-dead, heartbeat wiring, proxy-probe (#1441)"

# --- 13. THE #1380 PRUNE: grok decoy pruned from models.json -> no phantom ---
# fleet-ops#1380 deletes the grok dead-decoy from the seat list: grok is
# superseded by xai-oauth (which carries grok-4.5/4.6 on the healthy
# subscription proxy path), so keeping a `grok__grok-*` ledger entry each
# tick only reports phantom walled capacity. When models.json has grok
# pruned but xai-oauth present, the canary must NOT write the grok__grok-*
# decoy ledger (no phantom), while the xai-oauth ledger is still written.
# This is the regression guard for the phantom-capacity class.
: >"$gh_log"; : >"$triage"
rm -f "$AUTH_JSON"
printf '%s\n' "You are not authenticated." >"$scratch/models.txt"
printf '%s\n' "Default model: xai-oauth/grok-4.6" >>"$scratch/models.txt"
printf '%s\n' "Available models:" >>"$scratch/models.txt"
printf '%s\n' "  * xai-oauth/grok-4.6 (default)" >>"$scratch/models.txt"
export GROK_MODELS_FIXTURE="$scratch/models.txt"
export GROK_MODELS_RC=0
# Fixture: live models.json with the grok provider pruned (xai-oauth only).
export FLEET_MODELS_JSON="$scratch/models.json"
jq -n '{"providers":{"xai-oauth":{"models":[{"id":"grok-4.6"},{"id":"grok-4.5"}]}}}' \
  >"$FLEET_MODELS_JSON"
write_xai_probe ok
# The grok__grok-* decoy ledger may still hold stale entries from earlier
# scenarios in this same ledger dir. Remove them, then assert the pruned
# canary run does NOT re-create them (the phantom would otherwise return).
rm -f "$PI_SEAT_HEALTH_LEDGER_DIR/grok__grok-4.6.json" \
      "$PI_SEAT_HEALTH_LEDGER_DIR/grok__grok-4.5.json"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario13: expected rc=0, got $env_rc ($env_out)"
grep -q 'grok decoy pruned from models.json' <<<"$env_out" \
  || fail "scenario13: must log the grok-decoy-pruned skip ($env_out)"
# The grok__grok-* decoy ledger must NOT exist (phantom gone).
if [[ -f "$PI_SEAT_HEALTH_LEDGER_DIR/grok__grok-4.6.json" ]] \
   || [[ -f "$PI_SEAT_HEALTH_LEDGER_DIR/grok__grok-4.5.json" ]]; then
    fail "scenario13: pruned grok decoy must NOT be re-painted to the ledger"
fi
# xai-oauth is still painted (the live seat): here the grok CLI is dead so
# the canary writes healthy on xai-oauth only when the independent probe ok.
[[ "$(xai_oauth_ledger_class grok-4.6)" == "healthy" ]] \
  || fail "scenario13: xai-oauth/grok-4.6 must still be written (healthy via independent probe)"
[[ "$(xai_oauth_ledger_class grok-4.5)" == "healthy" ]] \
  || fail "scenario13: xai-oauth/grok-4.5 must still be written"
ok "scenario13: grok decoy pruned from models.json => no grok__grok-* phantom ledger; xai-oauth still written (the #1380 prune)"
unset FLEET_MODELS_JSON
