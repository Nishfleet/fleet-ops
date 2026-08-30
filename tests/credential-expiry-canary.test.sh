#!/usr/bin/env bash
# tests/credential-expiry-canary.test.sh
#
# fleet-ops#938 (led-2026-08-27-vacation-window-corrected).
#
# Proves the credential-expiry canary enforces the 2026-09-08 window against
# official GitHub surfaces (GET /app + GitHub-Authentication-Token-Expiration),
# not a fictional GET /app/keys:
#   1. GET /app 200 → PASS (App keys do not expire).
#   2. GET /app 401 → REJECT.
#   3. PAT expiring after the window → PASS.
#   4. PAT expiring on the window end → REJECT (inclusive).
#   5. PAT expiring before the window → REJECT.
#   6. PAT with no expiry header → PASS (classic PAT, no expiry).
#   7. Unparseable PAT expiry header → REJECT.
#   8. No App and no PAT → SKIP.
#   9. now past window end → SKIP.
#  10. Source never calls GET /app/keys.
#  11. Heartbeat-tier1 block 31 wiring + require_manifest_helper.
#  12. Matrix row is enforced with mechanism + proof.
#  13. MANIFEST ships the binary + lib.
#  14. Nested from escalation-coverage-canary.test.sh (CI host).
#
# Offline. No GitHub API calls.

set -euo pipefail
# Offline: disable the wrapper's auto-file / observe-to-close gh block so
# the existing GitHub-plane tests never touch the network. The pre-expiry
# probe tests below re-enable it with a stubbed GH.
export FLEET_CRED_EXPIRY_FILE_ISSUES=0
export FLEET_CRED_EXPIRY_CLOSE_ISSUES=0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/credential-expiry-canary.py"
bin="$repo_root/bin/fleet-credential-expiry-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
matrix="$repo_root/config/rule-enforcement.json"
manifest="$repo_root/MANIFEST"
host="$here/escalation-coverage-canary.test.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -x "$bin" ]] || fail "not executable: $bin"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

app_ok='{"id":4728578,"name":"nishfleet-worker","created_at":"2026-08-26T16:30:31Z"}'

# --- 1. GET /app 200 → PASS ------------------------------------------------
set +e
out="$("$bin" --app-returns "$app_ok" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "GET /app 200 must exit 0, got $rc: $out"
grep -q 'PASS' <<<"$out" || fail "must print PASS: $out"
ok "GET /app 200 → PASS (keys do not expire)"

# --- 2. GET /app 401 → REJECT ----------------------------------------------
set +e
out="$("$bin" --app-returns '{}' --app-status 401 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "GET /app 401 must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
ok "GET /app 401 → REJECT (dead App)"

# --- 3. PAT expiring after window → PASS -----------------------------------
pat_after=$'HTTP/2 200\ngithub-authentication-token-expiration: 2026-09-09 00:00:00 +0000\n'
set +e
out="$("$bin" --app-returns "$app_ok" --pat-headers "$pat_after" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "PAT after window must exit 0, got $rc: $out"
grep -q 'PASS' <<<"$out" || fail "must print PASS: $out"
ok "PAT expiring 2026-09-09 → PASS"

# --- 4. PAT expiring at window end → REJECT (inclusive) --------------------
pat_boundary=$'HTTP/2 200\ngithub-authentication-token-expiration: 2026-09-08 23:59:59 +0000\n'
set +e
out="$("$bin" --app-returns "$app_ok" --pat-headers "$pat_boundary" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "boundary PAT must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
ok "PAT expiring at window end → REJECT"

# --- 5. PAT expiring before window → REJECT --------------------------------
pat_pre=$'HTTP/2 200\ngithub-authentication-token-expiration: 2026-08-30 12:00:00 +0000\n'
set +e
out="$("$bin" --app-returns "$app_ok" --pat-headers "$pat_pre" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "pre-window PAT must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
ok "PAT expiring before window → REJECT"

# --- 6. PAT with no expiry header → PASS -----------------------------------
pat_none=$'HTTP/2 200\ncontent-type: application/json\n'
set +e
out="$("$bin" --app-returns "$app_ok" --pat-headers "$pat_none" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "no-expiry PAT must exit 0, got $rc: $out"
grep -q 'PASS' <<<"$out" || fail "must print PASS: $out"
ok "PAT with no expiry header → PASS"

# --- 7. unparseable PAT expiry → REJECT ------------------------------------
pat_bad=$'HTTP/2 200\ngithub-authentication-token-expiration: not-a-date\n'
set +e
out="$("$bin" --app-returns "$app_ok" --pat-headers "$pat_bad" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "unparseable PAT expiry must exit 1, got $rc: $out"
grep -q 'REJECT' <<<"$out" || fail "must print REJECT: $out"
ok "unparseable PAT expiry header → REJECT"

# --- 8. no App and no PAT → SKIP -------------------------------------------
set +e
out="$("$bin" --from-fixtures /tmp/credential-expiry-empty-fixtures-does-not-exist 2>&1)"
rc=$?
set -e
# missing dir still runs evaluate with app_status=0, pat_raw=None → SKIP
[[ "$rc" -eq 0 ]] || fail "no credentials must exit 0 (SKIP), got $rc: $out"
grep -qi 'SKIP' <<<"$out" || fail "must print SKIP: $out"
ok "no App and no PAT → SKIP"

# --- 9. now past window end → SKIP -----------------------------------------
set +e
out="$("$bin" --app-returns "$app_ok" --now 2026-09-10T00:00:00Z 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "past-window must exit 0 (SKIP), got $rc: $out"
grep -qi 'SKIP' <<<"$out" || fail "must print SKIP: $out"
ok "now past window end → SKIP"

# --- 10. source never calls a private-key list endpoint --------------------
grep -F '"/app/keys"' "$lib" >/dev/null \
    && fail "lib must not call a fictional App private-key list endpoint"
ok "source does not call a fictional App private-key list endpoint"

# --- 11. tier1 block 31 wiring ---------------------------------------------
grep -q 'CRED_EXPIRY_CANARY_BIN' "$tier1" \
    || fail "tier1 must reference CRED_EXPIRY_CANARY_BIN"
grep -q 'cred_expiry_canary_rc' "$tier1" \
    || fail "tier1 must propagate cred_expiry_canary_rc"
grep -q '31. credential expiry canary' "$tier1" \
    || fail "tier1 must name block 31 as credential expiry canary"
grep -q 'require_manifest_helper.*CRED_EXPIRY_CANARY' "$tier1" \
    || fail "tier1 block 31 must call require_manifest_helper"
grep -q 'HELPER-MISSING.*credential expiry' "$tier1" \
    || fail "tier1 block 31 must loud HELPER-MISSING"
ok "tier1 block 31 wires credential-expiry-canary with require_manifest_helper"

# --- 12. matrix row is enforced with mechanism + proof ---------------------
jq -e '.rules[] | select(.id == "led-2026-08-27-vacation-window-corrected" and .status == "enforced")' \
    "$matrix" >/dev/null \
    || fail "matrix must mark led-2026-08-27-vacation-window-corrected as enforced"
jq -e '.rules[] | select(.id == "led-2026-08-27-vacation-window-corrected") | .mechanism | test("fleet-credential-expiry-canary")' \
    "$matrix" >/dev/null \
    || fail "matrix mechanism must reference fleet-credential-expiry-canary"
jq -e '.rules[] | select(.id == "led-2026-08-27-vacation-window-corrected") | .proof | test("credential-expiry-canary\\.test\\.sh")' \
    "$matrix" >/dev/null \
    || fail "matrix proof must reference credential-expiry-canary.test.sh"
ok "matrix row led-2026-08-27-vacation-window-corrected is enforced with mechanism + proof"

# --- 13. MANIFEST installs the canary + lib --------------------------------
grep -q 'bin/fleet-credential-expiry-canary' "$manifest" \
    || fail "MANIFEST must install bin/fleet-credential-expiry-canary"
grep -q 'lib/credential-expiry-canary.py' "$manifest" \
    || fail "MANIFEST must install lib/credential-expiry-canary.py"
ok "MANIFEST ships the canary binary + lib"

# --- 14. CI host lock ------------------------------------------------------
grep -Fq 'bash "$here/credential-expiry-canary.test.sh"' "$host" \
    || fail "escalation-coverage-canary.test.sh must invoke this file (CI host, no workflow edit)"
ok "nested from escalation-coverage-canary.test.sh"

# --- 15. ledger-line smoke -------------------------------------------------
set +e
out="$("$bin" --ledger-line 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "--ledger-line must exit 0, got $rc: $out"
grep -q 'Vacation window corrected' <<<"$out" || fail "ledger-line must name the decision: $out"
grep -q '2026-09-08' <<<"$out" || fail "ledger-line must name the 2026-09-08 deadline: $out"
ok "ledger-line prints the vacation-window-corrected standing rule with 2026-09-08"

# --- 16. fixture dir mode --------------------------------------------------
scratch="$(mktemp -d -t cred-expiry-fixture.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
printf 'HTTP/2 200\n' >"$scratch/app.headers"
printf '%s\n' "$app_ok" >"$scratch/app.body"
set +e
out="$("$bin" --from-fixtures "$scratch" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "fixture mode must exit 0, got $rc: $out"
grep -q 'PASS' <<<"$out" || fail "fixture PASS: $out"
ok "fixture dir mode → PASS"

# ============================================================================
# PRE-EXPIRY PROBE (fleet-ops#2134, WFR 2026-08-29 lens-6-security)
# ============================================================================
# The reactive seat-health ledger only records credentials_bad AFTER a
# worker burns a slot. The pre-expiry probe fires N hours BEFORE a
# credential's known expiry so the renewal issue is auto-filed before the
# production 403. These tests prove the probe-fires-before-403 invariant.

# Fixed clock for deterministic remaining_s math.
PROBE_NOW="2026-08-30T05:00:00Z"
# expires_ms chosen so remaining_s is a clean number under --now.
# 2026-08-30T05:00:00Z = 1788070800 s = 1788070800000 ms.
# 3h before expiry -> expires 2026-08-30T08:00:00Z = 1788081600000 ms.
NEAR_EXPIRY_MS=1788081600000
# 30d after now -> well outside any threshold.
FAR_EXPIRY_MS=1790662800000

# --- 17. near-expiry credential triggers the probe (not a production 403) ---
set +e
out="$("$bin" --app-returns "$app_ok" \
    --auth-entries "[{\"provider\":\"xai-oauth\",\"expires_ms\":$NEAR_EXPIRY_MS}]" \
    --now "$PROBE_NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "near-expiry must exit 1 (PRE-EXPIRY-DETECTED), got $rc: $out"
grep -q 'PRE-EXPIRY-DETECTED' <<<"$out" || fail "must print PRE-EXPIRY-DETECTED: $out"
grep -q 'probe_triggered=true' <<<"$out" || fail "must mark probe_triggered=true: $out"
grep -q 'signal: cred-expiry/xai-oauth' <<<"$out" || fail "must emit the cred-expiry signal: $out"
# The invariant: the probe fired (PRE-EXPIRY-DETECTED), NOT a production 403.
grep -qi 'production 403\|PRODUCTION-403' <<<"$out" && \
    fail "must not report a production 403 (probe fires before it): $out"
ok "near-expiry credential triggers the probe (PRE-EXPIRY-DETECTED, not a production 403)"

# --- 18. far-expiry credential does not trigger the probe -------------------
set +e
out="$("$bin" --app-returns "$app_ok" \
    --auth-entries "[{\"provider\":\"xai-oauth\",\"expires_ms\":$FAR_EXPIRY_MS}]" \
    --now "$PROBE_NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "far-expiry must exit 0, got $rc: $out"
grep -q 'PRE-EXPIRY-DETECTED' <<<"$out" && \
    fail "far-expiry must NOT print PRE-EXPIRY-DETECTED: $out"
ok "far-expiry credential does not trigger the probe"

# --- 19. static key (no expires) is not probeable ---------------------------
set +e
out="$("$bin" --app-returns "$app_ok" \
    --auth-entries '[{"provider":"devin","expires_ms":null}]' \
    --now "$PROBE_NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "static key (no expires) must exit 0, got $rc: $out"
grep -q 'PRE-EXPIRY-DETECTED' <<<"$out" && \
    fail "static key must NOT trigger PRE-EXPIRY-DETECTED: $out"
ok "static key (no known expiry) is not probeable"

# --- 20. threshold boundary: just over N hours -> no finding ----------------
# expires 7h after now; default threshold 6h -> not detected.
set +e
boundary_ms=$(( 1788070800000 + 7 * 3600 * 1000 ))
out="$("$bin" --app-returns "$app_ok" \
    --auth-entries "[{\"provider\":\"xai-oauth\",\"expires_ms\":$boundary_ms}]" \
    --now "$PROBE_NOW" --pre-expiry-hours 6 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "7h (>6h threshold) must exit 0, got $rc: $out"
grep -q 'PRE-EXPIRY-DETECTED' <<<"$out" && \
    fail "7h must NOT trigger PRE-EXPIRY-DETECTED at 6h threshold: $out"
ok "threshold boundary: 7h expiry at 6h threshold -> no finding"

# --- 21. --no-pre-expiry-probe disables the probe --------------------------
set +e
out="$("$bin" --app-returns "$app_ok" \
    --auth-entries "[{\"provider\":\"xai-oauth\",\"expires_ms\":$NEAR_EXPIRY_MS}]" \
    --now "$PROBE_NOW" --no-pre-expiry-probe 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "--no-pre-expiry-probe must exit 0 (PASS), got $rc: $out"
grep -q 'PRE-EXPIRY-DETECTED' <<<"$out" && \
    fail "--no-pre-expiry-probe must NOT print PRE-EXPIRY-DETECTED: $out"
ok "--no-pre-expiry-probe disables the probe"

# --- 22. already-expired credential is also PRE-EXPIRY-DETECTED ------------
# remaining_s negative: the credential is past expiry — the probe still
# fires (louder than near-expiry) so the renewal issue is filed.
past_ms=$(( 1788070800000 - 3600 * 1000 ))   # 1h before now
set +e
out="$("$bin" --app-returns "$app_ok" \
    --auth-entries "[{\"provider\":\"xai-oauth\",\"expires_ms\":$past_ms}]" \
    --now "$PROBE_NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "already-expired must exit 1, got $rc: $out"
grep -q 'PRE-EXPIRY-DETECTED' <<<"$out" || fail "already-expired must print PRE-EXPIRY-DETECTED: $out"
ok "already-expired credential is PRE-EXPIRY-DETECTED (louder than near-expiry)"

# --- 23. lib exposes pre_expiry_probe + load_auth_expiries -----------------
python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cec", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert hasattr(m, "pre_expiry_probe"), "missing pre_expiry_probe"
assert hasattr(m, "load_auth_expiries"), "missing load_auth_expiries"
from datetime import datetime, timezone
now = datetime(2026,8,30,5,0,0,tzinfo=timezone.utc)
# near-expiry (3h) at 6h threshold -> 1 finding
f = m.pre_expiry_probe([{"provider":"x","expires_ms":1788081600000}], now=now, threshold_hours=6)
assert len(f)==1 and f[0]["verdict"]=="PRE-EXPIRY-DETECTED" and f[0]["probe_triggered"] is True, f
# far-expiry (30d) -> 0 findings
f2 = m.pre_expiry_probe([{"provider":"x","expires_ms":1790662800000}], now=now, threshold_hours=6)
assert len(f2)==0, f2
print("lib pre_expiry_probe OK")
' "$lib" || fail "lib pre_expiry_probe/load_auth_expiries missing or wrong"
ok "lib exposes pre_expiry_probe + load_auth_expiries with correct detection"

# --- 24. auto-file: PRE-EXPIRY-DETECTED files a renewal issue (stubbed gh) --
# Build a stub gh + fleet-issue-file in a temp bin dir.
stub_dir="$(mktemp -d -t cred-expiry-stub.XXXXXX)"
trap 'rm -rf "$scratch" "$stub_dir"' EXIT INT TERM

cat >"$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
# Record every call; dispatch on subcommand.
cmd_log="${FLEET_CRED_EXPIRY_STUB_LOG:-/tmp/cred-expiry-gh-calls.log}"
case "$1" in
    issue)
        case "$2" in
            list)
                echo "${FLEET_CRED_EXPIRY_STUB_LIST:-[]}"
                ;;
            comment)
                printf 'gh issue comment %s\n' "$3" >>"$cmd_log"
                ;;
            close)
                printf 'gh issue close %s\n' "$3" >>"$cmd_log"
                ;;
        esac
        ;;
esac
exit 0
STUB
chmod +x "$stub_dir/gh"

cat >"$stub_dir/fleet-issue-file" <<'STUB'
#!/usr/bin/env bash
# Record the file call; print a fake issue URL.
cmd_log="${FLEET_CRED_EXPIRY_STUB_LOG:-/tmp/cred-expiry-gh-calls.log}"
printf 'fleet-issue-file file %s\n' "$*" >>"$cmd_log"
echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
exit 0
STUB
chmod +x "$stub_dir/fleet-issue-file"

calls_log="$(mktemp -t cred-expiry-calls.XXXXXX)"
export FLEET_CRED_EXPIRY_STUB_LOG="$calls_log"

# 24a. no existing issue -> files a new renewal issue.
export FLEET_CRED_EXPIRY_STUB_LIST='[]'
export FLEET_CRED_EXPIRY_FILE_ISSUES=1
export FLEET_CRED_EXPIRY_CLOSE_ISSUES=1
export GH="$stub_dir/gh"
export FLEET_ISSUE_FILE="$stub_dir/fleet-issue-file"
: >"$calls_log"
set +e
out="$("$bin" --app-returns "$app_ok" \
    --auth-entries "[{\"provider\":\"xai-oauth\",\"expires_ms\":$NEAR_EXPIRY_MS}]" \
    --now "$PROBE_NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "auto-file run must exit 1 (PRE-EXPIRY-DETECTED), got $rc: $out"
grep -q 'fleet-issue-file file' "$calls_log" || \
    fail "wrapper must call fleet-issue-file to file a renewal issue: $(cat "$calls_log")"
ok "auto-file: PRE-EXPIRY-DETECTED files a renewal issue via fleet-issue-file"

# 24b. existing issue with the signal -> deduped (no new file).
export FLEET_CRED_EXPIRY_STUB_LIST='[{"number":42,"body":"...signal: cred-expiry/xai-oauth...","title":"renew"}]'
: >"$calls_log"
set +e
out="$("$bin" --app-returns "$app_ok" \
    --auth-entries "[{\"provider\":\"xai-oauth\",\"expires_ms\":$NEAR_EXPIRY_MS}]" \
    --now "$PROBE_NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "dedupe run must exit 1, got $rc: $out"
grep -q 'fleet-issue-file file' "$calls_log" && \
    fail "wrapper must NOT re-file when an open issue already carries the signal: $(cat "$calls_log")"
ok "auto-file: existing renewal issue is deduped (no re-file)"

# 24c. observe-to-close: signal cleared this tick -> comment + close.
export FLEET_CRED_EXPIRY_STUB_LIST='[{"number":42,"body":"renew xai-oauth signal: cred-expiry/xai-oauth","title":"renew"}]'
: >"$calls_log"
set +e
# far-expiry -> no PRE-EXPIRY-DETECTED this tick -> the open issue clears.
out="$("$bin" --app-returns "$app_ok" \
    --auth-entries "[{\"provider\":\"xai-oauth\",\"expires_ms\":$FAR_EXPIRY_MS}]" \
    --now "$PROBE_NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "observe-to-close run must exit 0 (no finding), got $rc: $out"
grep -q 'gh issue comment 42' "$calls_log" || \
    fail "observe-to-close must comment on the cleared issue: $(cat "$calls_log")"
grep -q 'gh issue close 42' "$calls_log" || \
    fail "observe-to-close must close the cleared issue: $(cat "$calls_log")"
ok "observe-to-close: cleared signal comments + closes the renewal issue"

# 24d. observe-to-close does NOT close a still-detected provider.
export FLEET_CRED_EXPIRY_STUB_LIST='[{"number":42,"body":"renew xai-oauth signal: cred-expiry/xai-oauth","title":"renew"}]'
: >"$calls_log"
set +e
out="$("$bin" --app-returns "$app_ok" \
    --auth-entries "[{\"provider\":\"xai-oauth\",\"expires_ms\":$NEAR_EXPIRY_MS}]" \
    --now "$PROBE_NOW" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "still-detected run must exit 1, got $rc: $out"
grep -q 'gh issue close 42' "$calls_log" && \
    fail "observe-to-close must NOT close an issue whose provider is still detected: $(cat "$calls_log")"
ok "observe-to-close: still-detected provider is not closed"

# Restore the offline defaults for any later checks.
export FLEET_CRED_EXPIRY_FILE_ISSUES=0
export FLEET_CRED_EXPIRY_CLOSE_ISSUES=0
unset GH FLEET_ISSUE_FILE FLEET_CRED_EXPIRY_STUB_LIST FLEET_CRED_EXPIRY_STUB_LOG

# --- 25. tier1 block 31 still wires the canary (unchanged) -----------------
# Re-assert the tier1 wiring is intact after the wrapper change (the
# existing block-31 checks at #11 already cover this; this is a belt-and-
# braces re-confirm that the pre-expiry extension did not break the wiring).
grep -q 'CRED_EXPIRY_CANARY_BIN' "$tier1" || fail "tier1 still references CRED_EXPIRY_CANARY_BIN"
ok "tier1 block 31 wiring intact after pre-expiry extension"

echo "OK: credential-expiry-canary (fleet-ops#938 + #2134 pre-expiry probe)"
