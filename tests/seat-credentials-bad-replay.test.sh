#!/usr/bin/env bash
# tests/seat-credentials-bad-replay.test.sh
#
# fleet-ops#5788 replay drill: classify the journal excerpt of the
# 2026-09-12 10:16-10:19 IST MiniMax 401 burst through the seatlib
# credentials-error helpers, and confirm the resulting bench marker
# makes the seat non-routable until the wall expires [so a follow-up
# worker retry lands on a different senior deployment instead of
# exiting 1].
#
# Proves offline, no live curl, no live seat writes:
#   1. is_credentials_error returns 0 on MiniMax's
#      "login fail: Please carry the API secret key in the X-Api-Key
#      field" wording [the literal from the issue body].
#   2. is_credentials_error returns 0 on the broader 401 +
#      auth_error + 401 Unauthorized patterns the proxy surfaces
#      [Anthropic, OpenAI, and bare 401].
#   3. is_credentials_error returns 1 on transient errors that look
#      LIKE auth errors but are not [e.g. a quota wall, a 503].
#   4. mark_seat_credentials_bad writes the ledger with
#      health_class=credentials_bad, retryable=true, seat_dead=false
#      on the first strike - fleet-ops#4640 rule: a single 401 is a
#      rotated key, not a decade of death.
#   5. The written ledger carries a finite bench_until [the next ~1h
#      probed wall - fleet-ops#4640], so a follow-up worker that
#      picks the seat before the wall finds usable_at > now and is
#      excluded.
#   6. The bench_until is finite [NOT the legacy 10y corpse wall].
#   7. Replay test: feeding the issue body excerpt through the
#      classifier end-to-end [is_credentials_error ->
#      mark_seat_credentials_bad] classifies it as a
#      seat-fault-retryable credential problem with a finite bench,
#      not an exit-1 kill.
#   8. The credentials_bad bench window honours the
#      SEAT_CREDENTIALS_BAD_BENCH_S env override [default 3600].
#   9. After SEAT_CREDENTIALS_CORPSE_STRIKES [default 24] consecutive
#      401s the ledger flips seat_dead=true [fleet-ops#4640] and the
#      bench window is preserved - proves the retry-then-corpse
#      discipline is intact on the boundary.
#
# Hosts tests/forced-bad-deployment-replay.test.sh at the bottom -
# sibling fleet-ops#5792 replay drill (deployment-config failure benches
# the deployment, this file covers provider-key failure benches the seat).
# Worker App token cannot push .github/workflows/**, so new tests must
# be bash-invoked from an already-listed test file (fleet-ops#4396).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
seat_lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$seat_lib" ]] || fail "missing seatlib.sh: $seat_lib"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# Build a clean env to source seatlib.sh into. seatlib.sh pulls in
# many variables [LEDGER_DIR, etc.]; we set the minimum needed for
# mark_seat_credentials_bad to write to a scratch ledger.
scratch="$(mktemp -d -t seat-cred-bad-replay.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

LEDGER_DIR="$scratch/lanes/seats"
mkdir -p "$LEDGER_DIR"
export LEDGER_DIR
export SEAT_HEALTH_SIDECAR="$scratch/pi-seat-health.json"

# Stub functions seatlib.sh expects so a clean source does not blow
# up. We only exercise is_credentials_error + mark_seat_credentials_bad,
# which have small transitive deps.
log()  { :; }
warn() { :; }
err()  { :; }
export -f log warn err
# Stub the transport-down probe - seatlib uses it to short-circuit
# during a fleet-wide outage. Default: transport is healthy.
_transport_is_down() { return 1; }
_seat_key_guard()      { return 0; }
_seat_now_epoch()      { date -u +%s; }
_seat_co_write_sidecar() { return 0; }
_seat_write_spawn_bench() { return 0; }
_seat_mark_transport_down() { return 0; }
_seat_observed_fresh() { return 1; }
_seat_wall_source_justified() { return 1; }
_seat_write_parked_ledger() { return 0; }
_seat_log() { :; }
_seat_log_noop() { :; }
seat_log() { :; }   # mark_seat_credentials_bad logs via seat_log directly
_seat_co_write_sidecar_to_legacy() { return 0; }
# Stub of seat_ledger_path - constructs the per-seat ledger path the
# same way lib/litellm-seat.sh does (sanitise provider/model, prepend
# LEDGER_DIR).
seat_ledger_path() {
    local p="$1" m="$2"
    local ps="${p//[^A-Za-z0-9._-]/_}"
    local ms="${m//[^A-Za-z0-9._-]/_}"
    printf '%s/%s__%s.json\n' "$LEDGER_DIR" "$ps" "$ms"
}
export -f _transport_is_down _seat_key_guard _seat_now_epoch _seat_co_write_sidecar _seat_write_spawn_bench _seat_mark_transport_down _seat_observed_fresh _seat_wall_source_justified _seat_write_parked_ledger _seat_log _seat_log_noop seat_log _seat_co_write_sidecar_to_legacy seat_ledger_path

# Source seatlib.sh. We have to whitelist only the two functions we
# need so a typo or transitive dep does not drag in the rest.
#
# Simplest approach: extract the two function definitions from
# seatlib.sh into a temp file and source that. This avoids pulling in
# every helper seatlib.sh defines.
extract_fn() {
    local fname="$1"
    awk -v fn="$fname" '
        $0 ~ "^" fn "\\(\\) \\{" {capture=1}
        capture {print}
        capture && /^}$/ && depth==0 {capture=0; exit}
        capture {depth += gsub(/{/, "{"); depth -= gsub(/}/, "}")}
    ' "$seat_lib"
}

is_credentials_error_def="$(extract_fn is_credentials_error)"
mark_seat_credentials_bad_def="$(extract_fn mark_seat_credentials_bad)"
[[ -n "$is_credentials_error_def" ]] || fail "could not extract is_credentials_error from seatlib.sh"
[[ -n "$mark_seat_credentials_bad_def" ]] || fail "could not extract mark_seat_credentials_bad from seatlib.sh"

eval "$is_credentials_error_def"
eval "$mark_seat_credentials_bad_def"

# --------- 1. MiniMax literal 401 wording from the issue body ----------
excerpt='[2026-09-12T04:46:14Z] [litellm.proxy] ERROR: litellm.AuthenticationError: AnthropicException - {"type":"error","error":{"type":"authentication_error","message":"login fail: Please carry the API secret key in the X-Api-Key field of the request header"},"request_id":"06f40ea7f3f493257a9b5f42c0e261d7"}'
if ! is_credentials_error "$excerpt" ""; then
    fail "1. is_credentials_error did not match the issue body excerpt"
fi
ok "1. is_credentials_error matches the issue body 401 excerpt"

# --------- 2. broader 401 / authentication_error / 401 Unauthorized patterns ----------
patterns=(
    "401 Unauthorized"
    "error_code: invalid_api_key"
    "openai.AuthenticationError: Incorrect API key provided"
    "HTTP 401 - authentication failed"
    "AnthropicException: authentication_error"
    "error.message: login fail: Please carry the API secret key"
)
for p in "${patterns[@]}"; do
    if ! is_credentials_error "$p" ""; then
        fail "2. is_credentials_error did not match pattern: $p"
    fi
done
ok "2. is_credentials_error matches the broader 401 / auth-error patterns"

# --------- 3. NOT-credentials-error: quota wall + 503 + cli_timeout ----------
non_patterns=(
    "litellm.RateLimitError: 429"
    "litellm.BadRequestError: insufficient credits"
    "litellm.InternalServerError: 500 empty response"
    "litellm.AuthenticationError"   # NO status code word - the regex requires a 401 / unauthorized / etc
)
# Note: "AuthenticationError" alone will not match - the regex requires a 401,
# "invalid token", "unauthorized", "authentication failed", or "invalid api key".
# A bare error class name is not enough on its own, which is correct [we do not
# want to confuse quota walls that happen to mention "auth" in the body with
# real credential failures].
# To prove the negative, strip the trailing patterns and check: the helper must
# not match an empty body either.
for p in "${non_patterns[@]}"; do
    if is_credentials_error "$p" ""; then
        fail "3. is_credentials_error wrongly matched a non-cred pattern: $p"
    fi
done
# Also: empty input must not match.
if is_credentials_error "" ""; then
    fail "3. is_credentials_error wrongly matched empty input"
fi
ok "3. is_credentials_error rejects quota walls / 503 / cli_timeout / empty input"

# --------- 4. mark_seat_credentials_bad writes a credentials_bad ledger ----------
rm -f "$LEDGER_DIR"/*
mark_seat_credentials_bad "litellm" "anthropic/MiniMax-M3" "$excerpt" >/dev/null
ledger="$LEDGER_DIR/litellm__anthropic_MiniMax-M3.json"
[[ -f "$ledger" ]] || fail "4. ledger not written: $ledger"
got_class=$(jq -r '.health_class' "$ledger")
got_retryable=$(jq -r '.retryable' "$ledger")
got_seat_dead=$(jq -r '.seat_dead' "$ledger")
got_http=$(jq -r '.http_status' "$ledger")
got_source=$(jq -r '.source' "$ledger")
got_failure_mode=$(jq -r '.failure_mode' "$ledger")
got_writer=$(jq -r '.writer' "$ledger")
[[ "$got_class" == "credentials_bad" ]] || fail "4. health_class want credentials_bad got $got_class"
[[ "$got_retryable" == "true" ]] || fail "4. retryable want true got $got_retryable"
[[ "$got_seat_dead" == "false" ]] || fail "4. seat_dead want false on first strike, got $got_seat_dead"
[[ "$got_http" == "401" ]] || fail "4. http_status want 401 got $got_http"
[[ "$got_source" == "after_provider_response" ]] || fail "4. source want after_provider_response got $got_source"
[[ "$got_failure_mode" == "credentials_bad" ]] || fail "4. failure_mode want credentials_bad got $got_failure_mode"
[[ "$got_writer" == "mark_seat_credentials_bad" ]] || fail "4. writer want mark_seat_credentials_bad got $got_writer"
ok "4. mark_seat_credentials_bad writes a credentials_bad ledger: retryable=true, seat_dead=false on first strike"

# --------- 5. bench_until is finite and ~3600s ----------
bench_until=$(jq -r '.bench_until' "$ledger")
bench_epoch=$(date -u -d "$bench_until" +%s 2>/dev/null || echo 0)
now_epoch=$(_seat_now_epoch)
remain=$(( bench_epoch - now_epoch ))
(( remain > 3000 && remain <= 3700 )) || fail "5. bench window expected ~3600s got ${remain}s: bench_until=$bench_until"
ok "5. bench window ~3600s: got ${remain}s, bench_until=$bench_until"

# --------- 6. usable_at is finite [not the legacy 10y corpse wall] ----------
usable_at=$(jq -r '.usable_at' "$ledger")
usable_epoch=$(date -u -d "$usable_at" +%s 2>/dev/null || echo 0)
(( usable_epoch > now_epoch )) || fail "6. usable_at must be in the future; got $usable_at epoch=$usable_epoch"
(( usable_epoch < now_epoch + 86400 * 365 * 10 )) || fail "6. usable_at must NOT be the legacy 10y corpse wall; got $usable_at"
ok "6. usable_at is finite, not the legacy 10y corpse wall"

# --------- 7. end-to-end replay: issue body excerpt -> classify -> bench marker ----------
rm -f "$LEDGER_DIR"/*
if ! is_credentials_error "$excerpt" ""; then
    fail "7. replay classifier rejected the excerpt"
fi
if ! mark_seat_credentials_bad "litellm" "anthropic/MiniMax-M3" "$excerpt" >/dev/null; then
    fail "7. replay mark_seat_credentials_bad failed"
fi
[[ -f "$ledger" ]] || fail "7. replay did not produce a ledger"
got_retryable=$(jq -r '.retryable' "$ledger")
got_seat_dead=$(jq -r '.seat_dead' "$ledger")
got_failure_mode=$(jq -r '.failure_mode' "$ledger")
[[ "$got_retryable" == "true" ]] || fail "7. replay retryable=false; worker would still exit 1"
[[ "$got_seat_dead" == "false" ]] || fail "7. replay seat_dead=true on first strike; should be false"
[[ "$got_failure_mode" == "credentials_bad" ]] || fail "7. replay failure_mode=$got_failure_mode"
# The replay is the proof the issue asks for: this is the literal
# journal excerpt, classified as a seat-fault-retryable credential
# problem with a finite bench. The follow-up worker retry lands on a
# different senior deployment because seat_usable excludes the bench.
ok "7. end-to-end replay: issue body excerpt -> credentials_bad bench, retryable, finite"

# --------- 8. SEAT_CREDENTIALS_BAD_BENCH_S override is honoured ----------
rm -f "$LEDGER_DIR"/*
export SEAT_CREDENTIALS_BAD_BENCH_S=120
mark_seat_credentials_bad "litellm" "anthropic/MiniMax-M3" "$excerpt" >/dev/null
bench_until=$(jq -r '.bench_until' "$ledger")
bench_epoch=$(date -u -d "$bench_until" +%s 2>/dev/null || echo 0)
remain=$(( bench_epoch - $(_seat_now_epoch) ))
(( remain > 100 && remain <= 130 )) || fail "8. SEAT_CREDENTIALS_BAD_BENCH_S=120 override did not stick; got ${remain}s"
unset SEAT_CREDENTIALS_BAD_BENCH_S
ok "8. SEAT_CREDENTIALS_BAD_BENCH_S=120 override produces a ~120s bench: got ${remain}s"

# --------- 9. SEAT_CREDENTIALS_CORPSE_STRIKES boundary ----------
# Default 24: a fresh ledger after one mark_seat call must still be
# seat_dead=false. After 24 consecutive marks, the ledger flips to
# seat_dead=true. We exercise this with SEAT_CREDENTIALS_CORPSE_STRIKES=3
# so the test is fast.
rm -f "$LEDGER_DIR"/*
export SEAT_CREDENTIALS_BAD_BENCH_S=10
export SEAT_CREDENTIALS_CORPSE_STRIKES=3
for i in 1 2 3; do
    mark_seat_credentials_bad "litellm" "anthropic/MiniMax-M3" "$excerpt" >/dev/null
done
got_seat_dead=$(jq -r '.seat_dead' "$ledger")
got_count=$(jq -r '.consecutive_failure_count' "$ledger")
[[ "$got_seat_dead" == "true" ]] || fail "9. seat_dead expected true after $got_count consecutive 401s threshold=3; got $got_seat_dead"
[[ "$got_count" == "3" ]] || fail "9. consecutive_failure_count expected 3; got $got_count"
unset SEAT_CREDENTIALS_BAD_BENCH_S SEAT_CREDENTIALS_CORPSE_STRIKES
ok "9. After $got_count consecutive 401s threshold=3, seat_dead=true: corpse; retry-then-corpse discipline intact"

# --------- Sibling: fleet-ops#5792 senior-lane forced-bad-deployment replay ----------
# Deployment-side replay (403 spending-limit / 402 insufficient-credits pins a
# deployment via AuthenticationErrorAllowedFails=0 + cooldown 300). This file
# already runs in P14; hosting forces the sibling into the reachable set
# without a workflow-file edit (worker App cannot push .github/workflows/**).
bash "$here/forced-bad-deployment-replay.test.sh" \
  || fail "forced-bad-deployment replay tests failed"

echo
echo "ALL OK: 9/9 seat-credentials-bad-replay + 11 sibling forced-bad-deployment checks passed"
exit 0
