#!/usr/bin/env bash
# tests/grok-token-refresh.test.sh
#
# fleet-ops#41 drill: headless OAuth refresh of
# ~/.pi/agent/auth.json["xai-oauth"] against the live x.ai endpoint.
# Proves offline, no network, no credential leak:
#   1. auth.json missing                            -> SKIP, exit 0.
#   2. no xai-oauth provider / no refresh           -> SKIP, exit 0.
#   3. access still has >TTL_S of life              -> SKIP, exit 0,
#                                                     auth.json unchanged,
#                                                     last_success preserved.
#   4. POST returns 200 + new tokens                -> OK, exit 0,
#                                                     auth.json rewritten,
#                                                     metric written.
#   5. POST returns 500                             -> REJECT, exit 1,
#                                                     auth.json unchanged.
#   6. POST returns 200 but no access_token         -> REJECT, exit 1,
#                                                     auth.json unchanged.
#   7. POST returns 200 but no refresh_token        -> OK, exit 0,
#                                                     previous refresh kept
#                                                     (matches pi-grok).
#   8. POST returns 200 but expires_in missing      -> REJECT, exit 1,
#                                                     auth.json unchanged.
#   9. only grant_type=refresh_token is sent.
#  10. SKIP path never logs credential contents.
#  11. SUCCESS path logs only sha256 prefix, never value.
#  12. Replay after success is a SKIP (skip-if-fresh).
#  13. Sibling providers under the same auth.json are preserved.
#  14. Lock directory is created and removed cleanly.
#  15. prom textfile is rewritten (not appended) on every run.
#  16. --help exits 0 and prints the usage.
#  17. unknown flag exits 2.
#  18. unknown argument exits 2.
#  19. jq-missing gate present in script body.
#  20. curl-missing gate present in script body.
#  21. Heartbeat wiring (tier1 picks up the absent() rule + organ entry).
#  22. MANIFEST ships the script + both units.
#  23. seat-caps reason + _comment_grok cite grok-token-refresh.
#  24. SKIP after a prior success preserves last_success (no false alarm).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/grok-token-refresh"
svc="$repo_root/systemd/grok-token-refresh.service"
timer="$repo_root/systemd/grok-token-refresh.timer"
manifest="$repo_root/MANIFEST"
rules="$repo_root/config/fleet_rules.yml"
organs="$repo_root/config/fleet-organs.json"
seat_caps="$repo_root/config/seat-caps.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$svc" ]] || fail "missing $svc"
[[ -f "$timer" ]] || fail "missing $timer"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d -t grok-token-refresh.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME/.pi/agent"
AUTH_JSON="$HOME/.pi/agent/auth.json"

TEXTFILE_DIR="$scratch/prom"
mkdir -p "$TEXTFILE_DIR"
TEXTFILE="$TEXTFILE_DIR/fleet-grok-token-refresh.prom"

curl_bin="$scratch/curl"
cat >"$curl_bin" <<'CURL'
#!/usr/bin/env bash
# Stub: only honours the args the script passes (POST + url + data +
# write-out + output). Records argv to $GROK_CURL_LOG for assertions.
printf '%s\n' "$*" >>"${GROK_CURL_LOG:-/dev/null}"
code="${GROK_CURL_STATUS:-200}"
body="${GROK_CURL_FIXTURE:-}"
out=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "--output" || "$prev" == "-o" ]]; then
        out="$a"
    fi
    prev="$a"
done
if [[ -n "$out" ]]; then
    if [[ -n "$body" && -f "$body" ]]; then
        cat "$body" >"$out"
    else
        : >"$out"
    fi
fi
printf '%s' "$code"
exit 0
CURL
chmod +x "$curl_bin"

export PI_AGENT_AUTH_JSON="$AUTH_JSON"
export GROK_TOKEN_REFRESH_TEXTFILE="$TEXTFILE"
export GROK_TOKEN_REFRESH_CURL_BIN="$curl_bin"
export GROK_TOKEN_REFRESH_TIMEOUT=5
export GROK_TOKEN_REFRESH_TOKEN_TTL_S=1800
export GROK_TOKEN_REFRESH_LOCK_TIMEOUT_S=5
export FLEET_GROK_REFRESH_TRIAGE="$scratch/triage.md"
: >"$FLEET_GROK_REFRESH_TRIAGE"
export GROK_CURL_LOG="$scratch/curl.log"
: >"$GROK_CURL_LOG"

run_script() {
    set +e
    out="$("$bin" 2>&1)"
    rc=$?
    set -e
}

# Write a clean auth.json with the live xai-oauth shape.
# expires is milliseconds epoch (pi-grok / OAuthCredentials).
write_auth() {
    local rt="${1:-RT-FIXTURE-NOT-A-REAL-TOKEN-001}"
    local exp_ms="${2:-$(( ($(date -u +%s) + 86400) * 1000 ))}"
    local extra_provider="${3:-}"
    if [[ -n "$extra_provider" ]]; then
        jq -n \
            --arg rt "$rt" \
            --argjson exp "$exp_ms" \
            --argjson extra "$extra_provider" \
            '{
              "xai-oauth": {
                type: "oauth",
                access: "AT-OLD",
                refresh: $rt,
                expires: $exp,
                tokenType: "Bearer",
                tokenEndpoint: "https://auth.x.ai/oauth2/token",
                baseUrl: "https://api.x.ai/v1",
                idToken: "IDT-KEEP"
              },
              sibling: $extra
            }' >"$AUTH_JSON"
    else
        jq -n \
            --arg rt "$rt" \
            --argjson exp "$exp_ms" \
            '{
              "xai-oauth": {
                type: "oauth",
                access: "AT-OLD",
                refresh: $rt,
                expires: $exp,
                tokenType: "Bearer",
                tokenEndpoint: "https://auth.x.ai/oauth2/token",
                baseUrl: "https://api.x.ai/v1",
                idToken: "IDT-KEEP"
              }
            }' >"$AUTH_JSON"
    fi
    chmod 600 "$AUTH_JSON"
}

assert_no_token_leak() {
    local label="$1" blob="$2"
    if grep -F 'RT-FIXTURE' <<<"$blob" >/dev/null 2>&1; then
        fail "$label: leaked RT-FIXTURE: $blob"
    fi
    if grep -F 'AT-OLD' <<<"$blob" >/dev/null 2>&1; then
        fail "$label: leaked AT-OLD: $blob"
    fi
    if grep -F 'AT-NEW' <<<"$blob" >/dev/null 2>&1; then
        fail "$label: leaked AT-NEW: $blob"
    fi
    if grep -F 'RT-NEW-ROTATED' <<<"$blob" >/dev/null 2>&1; then
        fail "$label: leaked RT-NEW-ROTATED: $blob"
    fi
    if [[ -f "$TEXTFILE" ]] && grep -F 'RT-FIXTURE' "$TEXTFILE" >/dev/null 2>&1; then
        fail "$label: textfile leaked RT-FIXTURE: $(cat "$TEXTFILE")"
    fi
    if [[ -f "$TEXTFILE" ]] && grep -F 'RT-NEW-ROTATED' "$TEXTFILE" >/dev/null 2>&1; then
        fail "$label: textfile leaked RT-NEW-ROTATED: $(cat "$TEXTFILE")"
    fi
}

assert_metric_outcome() {
    local want="$1"
    local got
    got="$(grep -E '^fleet_grok_token_refresh_outcome\{outcome="' "$TEXTFILE" | grep -F "outcome=\"$want\"" | awk '{print $NF}')"
    [[ "$got" == "1" ]] || fail "metric outcome=$want expected 1, got '$got' (textfile: $(cat "$TEXTFILE" 2>/dev/null || echo MISSING))"
}

# --- 1. auth.json missing -> SKIP, exit 0 ----------------------------------
rm -f "$AUTH_JSON"
: >"$GROK_CURL_LOG"
run_script
[[ "$rc" -eq 0 ]] || fail "scenario1: expected rc=0, got $rc ($out)"
! grep -F 'POST' "$GROK_CURL_LOG" >/dev/null 2>&1 || fail "scenario1: must not call curl"
grep -q 'SKIP' <<<"$out" || fail "scenario1: must log SKIP: $out"
ok "scenario1: missing auth.json -> SKIP, no curl"

# --- 2a. auth.json has no xai-oauth provider -> SKIP -----------------------
: >"$GROK_CURL_LOG"
jq -n '{other: {access: "AT-OLD"}}' >"$AUTH_JSON"
chmod 600 "$AUTH_JSON"
run_script
[[ "$rc" -eq 0 ]] || fail "scenario2a: expected rc=0, got $rc ($out)"
! grep -F 'POST' "$GROK_CURL_LOG" >/dev/null 2>&1 || fail "scenario2a: must not call curl"
grep -q 'SKIP' <<<"$out" || fail "scenario2a: must log SKIP: $out"
ok "scenario2a: no xai-oauth provider -> SKIP, no curl"

# --- 2b. xai-oauth present but no refresh -> SKIP --------------------------
: >"$GROK_CURL_LOG"
jq -n '{"xai-oauth": {access: "AT-OLD", type: "oauth"}}' >"$AUTH_JSON"
chmod 600 "$AUTH_JSON"
run_script
[[ "$rc" -eq 0 ]] || fail "scenario2b: expected rc=0, got $rc ($out)"
! grep -F 'POST' "$GROK_CURL_LOG" >/dev/null 2>&1 || fail "scenario2b: must not call curl"
grep -q 'SKIP' <<<"$out" || fail "scenario2b: must log SKIP: $out"
ok "scenario2b: no refresh under xai-oauth -> SKIP, no curl"

# --- 3. access still fresh -> SKIP, exit 0 ---------------------------------
: >"$GROK_CURL_LOG"
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) + 86400) * 1000 ))
before_hash="$(sha256sum "$AUTH_JSON" | awk '{print $1}')"
run_script
[[ "$rc" -eq 0 ]] || fail "scenario3: expected rc=0, got $rc ($out)"
! grep -F 'POST' "$GROK_CURL_LOG" >/dev/null 2>&1 || fail "scenario3: must not call curl"
after_hash="$(sha256sum "$AUTH_JSON" | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || fail "scenario3: auth.json was modified on SKIP"
ok "scenario3: fresh access -> SKIP, auth.json untouched"

# --- 4. POST 200 with new tokens -> OK -------------------------------------
: >"$GROK_CURL_LOG"
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) - 60) * 1000 ))
fixture_ok="$scratch/token-ok.json"
cat >"$fixture_ok" <<'JSON'
{
  "access_token": "AT-NEW",
  "refresh_token": "RT-NEW-ROTATED",
  "token_type": "Bearer",
  "expires_in": 21600
}
JSON
export GROK_CURL_FIXTURE="$fixture_ok"
export GROK_CURL_STATUS=200
run_script
[[ "$rc" -eq 0 ]] || fail "scenario4: expected rc=0, got $rc ($out)"
grep -F 'POST' "$GROK_CURL_LOG" >/dev/null 2>&1 || fail "scenario4: must call POST"
grep -F "https://auth.x.ai/oauth2/token" "$GROK_CURL_LOG" >/dev/null 2>&1 || fail "scenario4: must POST to x.ai OAuth endpoint"
grep -F 'grant_type=refresh_token' "$GROK_CURL_LOG" >/dev/null 2>&1 || fail "scenario4: must send grant_type=refresh_token"
grep -F 'client_id=b1a00492-073a-47ea-816f-4c329264a828' "$GROK_CURL_LOG" >/dev/null 2>&1 || fail "scenario4: must send the proven client_id"
got_access="$(jq -r '.["xai-oauth"].access' "$AUTH_JSON")"
got_refresh="$(jq -r '.["xai-oauth"].refresh' "$AUTH_JSON")"
[[ "$got_access" == "AT-NEW" ]] || fail "scenario4: expected access=AT-NEW, got $got_access"
[[ "$got_refresh" == "RT-NEW-ROTATED" ]] || fail "scenario4: expected refresh=RT-NEW-ROTATED, got $got_refresh"
# expires is ms; expect ~ now_ms + 21600*1000 - 300*1000
got_expires="$(jq -r '.["xai-oauth"].expires' "$AUTH_JSON")"
now_ms=$(( $(date -u +%s) * 1000 ))
expected=$(( now_ms + 21600 * 1000 - 300 * 1000 ))
diff=$(( got_expires - expected ))
# Allow ±5s of clock drift in the test itself.
if (( diff < -5000 || diff > 5000 )); then
    fail "scenario4: expires off by ${diff}ms (got=$got_expires expected≈$expected)"
fi
# Sibling fields preserved.
got_id="$(jq -r '.["xai-oauth"].idToken' "$AUTH_JSON")"
[[ "$got_id" == "IDT-KEEP" ]] || fail "scenario4: idToken was lost"
got_type="$(jq -r '.["xai-oauth"].type' "$AUTH_JSON")"
[[ "$got_type" == "oauth" ]] || fail "scenario4: type was lost"
[[ -s "$TEXTFILE" ]] || fail "scenario4: textfile metric not written"
assert_metric_outcome "success"
assert_no_token_leak "scenario4" "$out"
ok "scenario4: 200 + new tokens -> OK, auth.json rewritten, sibling fields preserved, metric written"

# Capture last_success for scenario 24.
SUCCESS_EPOCH="$(awk '/^fleet_grok_token_refresh_last_success_seconds / {print $2}' "$TEXTFILE")"
[[ -n "$SUCCESS_EPOCH" && "$SUCCESS_EPOCH" != "0" ]] || fail "scenario4: last_success must be non-zero after success"

# --- 5. POST 500 -> REJECT -------------------------------------------------
: >"$GROK_CURL_LOG"
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) - 60) * 1000 ))
before_hash="$(sha256sum "$AUTH_JSON" | awk '{print $1}')"
unset GROK_CURL_FIXTURE
export GROK_CURL_STATUS=500
run_script
[[ "$rc" -eq 1 ]] || fail "scenario5: expected rc=1, got $rc ($out)"
after_hash="$(sha256sum "$AUTH_JSON" | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || fail "scenario5: auth.json was modified on REJECT"
grep -q 'GROK-TOKEN-REFRESH-REJECT' "$FLEET_GROK_REFRESH_TRIAGE" || fail "scenario5: must append REJECT to triage"
assert_metric_outcome "reject"
ok "scenario5: HTTP 500 -> REJECT, auth.json untouched"

# --- 6. POST 200 but no access_token -> REJECT -----------------------------
: >"$GROK_CURL_LOG"
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) - 60) * 1000 ))
before_hash="$(sha256sum "$AUTH_JSON" | awk '{print $1}')"
fixture_no_access="$scratch/token-no-access.json"
cat >"$fixture_no_access" <<'JSON'
{ "refresh_token": "RT-NEW-ROTATED", "expires_in": 21600, "token_type": "Bearer" }
JSON
export GROK_CURL_FIXTURE="$fixture_no_access"
export GROK_CURL_STATUS=200
run_script
[[ "$rc" -eq 1 ]] || fail "scenario6: expected rc=1, got $rc ($out)"
after_hash="$(sha256sum "$AUTH_JSON" | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || fail "scenario6: auth.json was modified on REJECT"
grep -q 'no access_token' <<<"$out" || fail "scenario6: must name the missing field"
ok "scenario6: no access_token in body -> REJECT, auth.json untouched"

# --- 7. POST 200 but no refresh_token -> OK, keep previous -----------------
: >"$GROK_CURL_LOG"
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) - 60) * 1000 ))
fixture_no_refresh="$scratch/token-no-refresh.json"
cat >"$fixture_no_refresh" <<'JSON'
{ "access_token": "AT-NEW", "expires_in": 21600, "token_type": "Bearer" }
JSON
export GROK_CURL_FIXTURE="$fixture_no_refresh"
export GROK_CURL_STATUS=200
run_script
[[ "$rc" -eq 0 ]] || fail "scenario7: expected rc=0, got $rc ($out)"
got_access="$(jq -r '.["xai-oauth"].access' "$AUTH_JSON")"
got_refresh="$(jq -r '.["xai-oauth"].refresh' "$AUTH_JSON")"
[[ "$got_access" == "AT-NEW" ]] || fail "scenario7: expected access=AT-NEW, got $got_access"
[[ "$got_refresh" == "RT-FIXTURE-NOT-A-REAL-TOKEN-001" ]] || fail "scenario7: expected previous refresh kept, got $got_refresh"
grep -q 'refresh unchanged' <<<"$out" || fail "scenario7: must note refresh unchanged"
ok "scenario7: no refresh_token in body -> OK, previous refresh kept (pi-grok parity)"

# --- 8. POST 200 but expires_in missing -> REJECT --------------------------
: >"$GROK_CURL_LOG"
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) - 60) * 1000 ))
before_hash="$(sha256sum "$AUTH_JSON" | awk '{print $1}')"
fixture_no_exp="$scratch/token-no-exp.json"
cat >"$fixture_no_exp" <<'JSON'
{ "access_token": "AT-NEW", "refresh_token": "RT-NEW-ROTATED", "token_type": "Bearer" }
JSON
export GROK_CURL_FIXTURE="$fixture_no_exp"
export GROK_CURL_STATUS=200
run_script
[[ "$rc" -eq 1 ]] || fail "scenario8: expected rc=1, got $rc ($out)"
after_hash="$(sha256sum "$AUTH_JSON" | awk '{print $1}')"
[[ "$before_hash" == "$after_hash" ]] || fail "scenario8: auth.json was modified on REJECT"
grep -q 'expires_in' <<<"$out" || fail "scenario8: must name the missing field"
ok "scenario8: no expires_in -> REJECT, auth.json untouched"

# --- 9. only grant_type=refresh_token is sent ------------------------------
: >"$GROK_CURL_LOG"
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) - 60) * 1000 ))
export GROK_CURL_FIXTURE="$fixture_ok"
export GROK_CURL_STATUS=200
run_script
[[ "$rc" -eq 0 ]] || fail "scenario9: expected rc=0, got $rc ($out)"
! grep -F 'grant_type=id_token' "$GROK_CURL_LOG" >/dev/null 2>&1 || fail "scenario9: must not send id_token grant"
! grep -F 'grant_type=bearer' "$GROK_CURL_LOG" >/dev/null 2>&1 || fail "scenario9: must not send bearer grant"
ok "scenario9: only grant_type=refresh_token is sent"

# --- 10. SKIP path never logs credential contents --------------------------
: >"$GROK_CURL_LOG"
rm -f "$AUTH_JSON"
run_script
[[ "$rc" -eq 0 ]] || fail "scenario10: expected rc=0, got $rc"
assert_no_token_leak "scenario10" "$out"
ok "scenario10: SKIP path emits no token literal"

# --- 11. SUCCESS path logs only sha256 prefix ------------------------------
: >"$GROK_CURL_LOG"
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) - 60) * 1000 ))
export GROK_CURL_FIXTURE="$fixture_ok"
export GROK_CURL_STATUS=200
run_script
[[ "$rc" -eq 0 ]] || fail "scenario11: expected rc=0, got $rc"
assert_no_token_leak "scenario11" "$out"
grep -E 'access_sha256_prefix=[0-9a-f]{16}' <<<"$out" >/dev/null \
    || fail "scenario11: must log a 16-char sha256 prefix"
ok "scenario11: SUCCESS path logs sha256 prefix, never value"

# --- 12. Replay after success is a SKIP ------------------------------------
: >"$GROK_CURL_LOG"
run_script
[[ "$rc" -eq 0 ]] || fail "scenario12: expected rc=0, got $rc ($out)"
! grep -F 'POST' "$GROK_CURL_LOG" >/dev/null 2>&1 || fail "scenario12: replay must SKIP, not POST"
grep -q 'still has .*s of life' <<<"$out" || fail "scenario12: must name the skip reason"
ok "scenario12: replay after success is a SKIP, no second grant"

# --- 13. Sibling providers under the same auth.json are preserved ----------
: >"$GROK_CURL_LOG"
sibling_json='{"access":"AT-SIBLING-MUST-NOT-CHANGE","refresh":"RT-SIBLING-MUST-NOT-CHANGE","expires":9999999999999}'
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) - 60) * 1000 )) "$sibling_json"
export GROK_CURL_FIXTURE="$fixture_ok"
export GROK_CURL_STATUS=200
run_script
[[ "$rc" -eq 0 ]] || fail "scenario13: expected rc=0, got $rc ($out)"
sibling_rt="$(jq -r '.sibling.refresh' "$AUTH_JSON")"
sibling_at="$(jq -r '.sibling.access' "$AUTH_JSON")"
[[ "$sibling_rt" == "RT-SIBLING-MUST-NOT-CHANGE" ]] || fail "scenario13: sibling refresh changed to $sibling_rt"
[[ "$sibling_at" == "AT-SIBLING-MUST-NOT-CHANGE" ]] || fail "scenario13: sibling access changed to $sibling_at"
primary_at="$(jq -r '.["xai-oauth"].access' "$AUTH_JSON")"
[[ "$primary_at" == "AT-NEW" ]] || fail "scenario13: xai-oauth access not refreshed: $primary_at"
ok "scenario13: sibling provider preserved, xai-oauth rotated"

# --- 14. Lock directory is created and removed cleanly ---------------------
: >"$GROK_CURL_LOG"
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) - 60) * 1000 ))
export GROK_CURL_FIXTURE="$fixture_ok"
export GROK_CURL_STATUS=200
run_script
[[ "$rc" -eq 0 ]] || fail "scenario14: expected rc=0, got $rc ($out)"
[[ ! -e "$AUTH_JSON.fleet-refresh.lock.d" ]] || fail "scenario14: lock dir lingered at $AUTH_JSON.fleet-refresh.lock.d"
[[ ! -e "$AUTH_JSON.lock" ]] || fail "scenario14: must not use pi's proper-lockfile path $AUTH_JSON.lock"
ok "scenario14: lock directory is created and removed cleanly (fleet-owned path)"

# --- 15. textfile is rewritten (not appended) ------------------------------
: >"$GROK_CURL_LOG"
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) - 60) * 1000 ))
export GROK_CURL_FIXTURE="$fixture_ok"
export GROK_CURL_STATUS=200
for _ in 1 2 3 4 5; do
    expires_ms=$(( ($(date -u +%s) - 60) * 1000 ))
    jq --argjson e "$expires_ms" '.["xai-oauth"].expires = $e' "$AUTH_JSON" >"$AUTH_JSON.tmp"
    mv "$AUTH_JSON.tmp" "$AUTH_JSON"
    run_script
    [[ "$rc" -eq 0 ]] || fail "scenario15 pass: expected rc=0, got $rc"
done
help_count="$(grep -c '^# HELP ' "$TEXTFILE" || true)"
type_count="$(grep -c '^# TYPE ' "$TEXTFILE" || true)"
metric_count="$(grep -cE '^fleet_grok_token_refresh_' "$TEXTFILE" || true)"
[[ "$help_count" -le 2 ]] || fail "scenario15: HELP lines duplicated ($help_count)"
[[ "$type_count" -le 2 ]] || fail "scenario15: TYPE lines duplicated ($type_count)"
[[ "$metric_count" -eq 4 ]] || fail "scenario15: expected 4 metric lines, got $metric_count"
ok "scenario15: textfile rewritten, not appended (5 runs => 4 metric lines)"

# --- 16. --help exits 0 and prints the usage --------------------------------
set +e
out="$("$bin" --help 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "scenario16: --help must exit 0, got $rc"
grep -q 'Usage: grok-token-refresh' <<<"$out" || fail "scenario16: must print usage"
ok "scenario16: --help exits 0 with usage"

# --- 17/18. unknown flag / argument exits 2 --------------------------------
set +e
"$bin" --bogus >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "scenario17: unknown flag must exit 2, got $rc"
set +e
"$bin" bogus-arg >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "scenario18: unknown argument must exit 2, got $rc"
ok "scenario17/18: unknown flag/argument exits 2"

# --- 19. jq-missing gate present -------------------------------------------
grep -q 'command -v jq' "$bin" || fail "scenario19: script must gate on command -v jq"
ok "scenario19: script gates on command -v jq"

# --- 20. curl-missing gate present -----------------------------------------
grep -F 'command -v "$CURL_BIN"' "$bin" >/dev/null \
    || fail "scenario20: script must gate on command -v \$CURL_BIN"
ok "scenario20: script gates on command -v \$CURL_BIN"

# --- 21. Heartbeat wiring (rules + organs) --------------------------------
grep -F 'FleetGrokTokenRefreshStale' "$rules" >/dev/null \
    || fail "scenario21: fleet_rules.yml must carry FleetGrokTokenRefreshStale"
grep -F 'fleet_grok_token_refresh_last_success_seconds' "$rules" >/dev/null \
    || fail "scenario21: fleet_rules.yml must reference the heartbeat metric"
jq -e '.organs[] | select(.name=="grok-token-refresh")' "$organs" >/dev/null \
    || fail "scenario21: fleet-organs.json must register grok-token-refresh"
jq -e '.organs[] | select(.name=="grok-token-refresh") | .absent_alert == "FleetGrokTokenRefreshStale"' "$organs" >/dev/null \
    || fail "scenario21: organ absent_alert must match rules"
ok "scenario21: rules + organs wired (FleetGrokTokenRefreshStale + grok-token-refresh organ)"

# --- 22. MANIFEST ships the script + both units ---------------------------
grep -F 'bin/grok-token-refresh' "$manifest" >/dev/null \
    || fail "scenario22: MANIFEST must install bin/grok-token-refresh"
grep -F 'systemd/grok-token-refresh.service' "$manifest" >/dev/null \
    || fail "scenario22: MANIFEST must install grok-token-refresh.service"
grep -F 'systemd/grok-token-refresh.timer' "$manifest" >/dev/null \
    || fail "scenario22: MANIFEST must install grok-token-refresh.timer"
ok "scenario22: MANIFEST ships the script + service + timer"

# --- 23. seat-caps cites grok-token-refresh -------------------------------
jq -e '.providers.grok.reason | contains("grok-token-refresh")' "$seat_caps" >/dev/null \
    || fail "scenario23: seat-caps providers.grok.reason must cite grok-token-refresh"
jq -e '."_comment_grok" | contains("grok-token-refresh")' "$seat_caps" >/dev/null \
    || fail "scenario23: seat-caps _comment_grok must cite grok-token-refresh"
ok "scenario23: seat-caps reason + _comment_grok cite grok-token-refresh"

# --- 24. SKIP preserves last_success (no false alarm) ---------------------
# Seed a prior success metric, then force a fresh-token SKIP. last_success
# must stay at the seeded value — zeroing it would trip the absent() rule.
printf 'fleet_grok_token_refresh_last_success_seconds 1700000000\n' >"$TEXTFILE"
printf 'fleet_grok_token_refresh_outcome{outcome="success"} 1\n' >>"$TEXTFILE"
printf 'fleet_grok_token_refresh_outcome{outcome="skipped"} 0\n' >>"$TEXTFILE"
printf 'fleet_grok_token_refresh_outcome{outcome="reject"} 0\n' >>"$TEXTFILE"
write_auth "RT-FIXTURE-NOT-A-REAL-TOKEN-001" $(( ($(date -u +%s) + 86400) * 1000 ))
: >"$GROK_CURL_LOG"
run_script
[[ "$rc" -eq 0 ]] || fail "scenario24: expected rc=0, got $rc ($out)"
got_ls="$(awk '/^fleet_grok_token_refresh_last_success_seconds / {print $2}' "$TEXTFILE")"
[[ "$got_ls" == "1700000000" ]] || fail "scenario24: last_success must stay 1700000000 on SKIP, got $got_ls"
assert_metric_outcome "skipped"
ok "scenario24: SKIP preserves last_success (no absent() false alarm)"

echo "OK: grok-token-refresh: skip paths, success path, reject paths, refresh-omitted keep, no token leak, idempotent, lock, prom rewrite, organ + rules + manifest wired, last_success preserved on skip"
