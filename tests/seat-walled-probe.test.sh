#!/usr/bin/env bash
# tests/seat-walled-probe.test.sh
#
# seat-walled-probe (fleet-ops#1348): when a walled seat's usable_at
# expires, send a polite 1-token "reply OK" probe. A confirmed-healthy
# response lets the seat re-enter the ladder (seat-health.ts clears
# usable_at on the healthy observation the probe produces). credentials_bad
# seats probe weekly and file an agent-ready issue if still bad.
#
# What we prove:
#   1. A walled seat whose usable_at is in the FUTURE is NOT probed.
#   2. A walled seat whose usable_at is in the PAST IS probed (dry-run logs it).
#   3. A healthy seat (usable_at null) is NOT probed.
#   4. min_probe_interval_s is honoured: a seat observed < 900s ago is skipped
#      even if usable_at is in the past.
#   5. credentials_bad: a weekly-expired seat triggers issue filing via the
#      configured FLEET_ISSUE_FILE_BIN mock (not real gh).
#   6. A run with no seats to probe exits 0 (not a failed unit).
#   7. --probe-all picks up a non-walled failure mode with expired usable_at.
#   8. Unit files are valid systemd (systemd-analyze verify) and the timer
#      has a timer-manifest entry.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/seat-walled-probe"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

cleanup() {
    rm -rf "$scratch" 2>/dev/null || true
    if (( cleanup_installed_bin )); then
        rm -f "$installed_bin" 2>/dev/null || true
    fi
}

cleanup_installed_bin=0
installed_bin="/home/nish/.local/bin/seat-walled-probe"

[[ -f "$bin" ]] || fail "seat-walled-probe not found: $bin"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seatwallprobe.XXXXXX)"
trap 'cleanup' EXIT INT TERM

ledger="$scratch/seats"
mkdir -p "$ledger"
state_dir="$scratch/state"
mkdir -p "$state_dir"

# seat-caps.json with a walled_comeback table (min_probe_interval_s=900).
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "walled_comeback": {
    "min_probe_interval_s": 900,
    "rate_limit_s": 900,
    "daily_quota_s": 3600,
    "monthly_quota_s": 86400,
    "free_balance_exhausted_s": 86400,
    "credentials_bad_s": 604800
  }
}
JSON

# now = 2026-08-29T12:00:00Z = 1724932800... use a fixed NOW for determinism.
# Use date arithmetic: pick a fixed "now" via FLEET_SEAT_WALLED_PROBE_NOW if
# the script supported it; it does not, so we compute timestamps relative to
# the real clock. Use offsets that are unambiguous regardless of wall time.
now_s=$(date -u +%s)
past_iso=$(date -u -d "@$((now_s - 3600))" +%Y-%m-%dT%H:%M:%SZ)   # 1h ago
future_iso=$(date -u -d "@$((now_s + 3600))" +%Y-%m-%dT%H:%M:%SZ) # 1h ahead
recent_iso=$(date -u -d "@$((now_s - 60))" +%Y-%m-%dT%H:%M:%SZ)   # 1m ago
week_ago_iso=$(date -u -d "@$((now_s - 604900))" +%Y-%m-%dT%H:%M:%SZ) # > 1 week ago

# Seat 1: rate_limit, usable_at in the past, observed 1h ago -> SHOULD probe.
cat >"$ledger/devin__glm-5-2.json" <<JSON
{"provider":"devin","model":"glm-5-2","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"$past_iso","source":"after_provider_response","failure_mode":"rate_limit","usable_at":"$past_iso","consecutive_failure_count":1}
JSON

# Seat 2: quota_exhausted, usable_at in the future -> should NOT probe.
cat >"$ledger/cline__cline-pass_deepseek-v4-flash.json" <<JSON
{"provider":"cline","model":"cline-pass/deepseek-v4-flash","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"$past_iso","source":"after_provider_response","failure_mode":"quota_exhausted","usable_at":"$future_iso","consecutive_failure_count":1}
JSON

# Seat 3: healthy, usable_at null -> should NOT probe.
cat >"$ledger/ollama__deepseek-v4-flash-0731.json" <<JSON
{"provider":"ollama","model":"deepseek-v4-flash:0731","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"$past_iso","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
JSON

# Seat 4: rate_limit, usable_at past BUT observed only 60s ago (< 900s
# min_probe_interval) -> should NOT probe (interval not met).
cat >"$ledger/zenmux__qwen.json" <<JSON
{"provider":"zenmux","model":"qwen","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"$recent_iso","source":"after_provider_response","failure_mode":"rate_limit","usable_at":"$past_iso","consecutive_failure_count":1}
JSON

# Seat 5: credentials_bad, observed > 1 week ago, usable_at past -> SHOULD
# probe AND file an agent-ready issue (probe will "fail" via mock pi).
cat >"$ledger/grok__grok-4.json" <<JSON
{"provider":"grok","model":"grok-4","http_status":403,"retry_after":null,"health_class":"credentials_bad","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"$week_ago_iso","source":"after_provider_response","failure_mode":"credentials_bad","usable_at":"$past_iso","consecutive_failure_count":3}
JSON

# Mock pi: prints "OK" (success) for devin, exits 1 (fail) for grok.
mock_pi="$scratch/mock-pi"
cat >"$mock_pi" <<'SH'
#!/usr/bin/env bash
# mock-pi: last arg is the prompt; provider/model come via --provider/--model.
provider=""
model=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider) provider="$2"; shift 2 ;;
        --model)    model="$2";    shift 2 ;;
        --print)    shift ;;
        *)          shift ;;
    esac
done
if [[ "$provider" == "grok" ]]; then
    echo "Error: 403 Forbidden" >&2
    exit 1
fi
echo "OK"
SH
chmod +x "$mock_pi"

# Mock fleet-issue-file: records the filing and prints a fake URL.
mock_issue_file="$scratch/mock-fleet-issue-file"
mock_issue_log="$scratch/issue-file-calls.log"
: > "$mock_issue_log"
cat >"$mock_issue_file" <<SH
#!/usr/bin/env bash
echo "\$(date -u +%s) \$*" >>"$mock_issue_log"
echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
SH
chmod +x "$mock_issue_file"

export PI_SEAT_HEALTH_LEDGER_DIR="$ledger"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_BIN="$mock_pi"
export FLEET_ISSUE_FILE_BIN="$mock_issue_file"
export FLEET_ISSUE_REPO="Nishfleet/fleet-ops"
export PI_PACKET_STATE="$state_dir"

# --- Test 1: dry-run picks devin (past usable_at) and grok (weekly), skips others ---
# In dry-run, probe_seat returns 0 (would-probe) so the failure/issue-filing
# branch is NOT exercised here — issue filing is proved by the real mock run
# (Test 2). Dry-run only proves seat SELECTION.
out=$(bash "$bin" --dry-run 2>&1) || true
echo "$out" | grep -q "DRY-RUN: would probe devin/glm-5-2" \
    || fail "dry-run should probe devin/glm-5-2 (past usable_at)"
echo "$out" | grep -q "DRY-RUN: would probe grok/grok-4" \
    || fail "dry-run should probe grok/grok-4 (weekly credentials_bad)"
! echo "$out" | grep -q "would probe cline/cline-pass" \
    || fail "dry-run should NOT probe cline (future usable_at)"
! echo "$out" | grep -q "would probe ollama" \
    || fail "dry-run should NOT probe ollama (healthy)"
! echo "$out" | grep -q "would probe zenmux" \
    || fail "dry-run should NOT probe zenmux (min_probe_interval not met)"
ok "dry-run probes the right seats (devin + grok), skips future/healthy/recent"

# --- Test 2: real (mock) run — devin probe succeeds, grok fails + files issue ---
bash "$bin" 2>&1 || true
issue_calls=$(cat "$mock_issue_log")
echo "$issue_calls" | grep -q "grok-4" \
    || fail "credentials_bad grok should have triggered issue filing"
echo "$issue_calls" | grep -q -- "--label agent-ready" \
    || fail "issue filing should use --label agent-ready"
ok "credentials_bad weekly probe filed an agent-ready issue via mock"

# watch.log should record the probe results.
watch_log="$state_dir/watch.log"
[[ -f "$watch_log" ]] || fail "watch.log not written"
grep -q "probe devin/glm-5-2 SUCCEEDED" "$watch_log" \
    || fail "watch.log should record devin probe SUCCEEDED"
grep -q "probe grok/grok-4 FAILED" "$watch_log" \
    || fail "watch.log should record grok probe FAILED"
ok "probe results logged to watch.log"

# actions.log should record the sweep summary.
actions_log="$state_dir/actions.log"
[[ -f "$actions_log" ]] || fail "actions.log not written"
grep -q "seat-probe sweep complete" "$actions_log" \
    || fail "actions.log should record sweep complete"
ok "sweep summary logged to actions.log"

# --- Test 3: no seats to probe exits 0 ---
# Empty ledger dir (remove all files).
rm -f "$ledger"/*.json
rc=0; bash "$bin" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 0 ]] || fail "no seats to probe should exit 0, got $rc"
ok "no seats to probe exits 0 (not a failed unit)"

# --- Test 4: --probe-all picks up a non-walled mode with expired usable_at ---
cat >"$ledger/hetzner__qwen.json" <<JSON
{"provider":"hetzner","model":"qwen","http_status":503,"retry_after":null,"health_class":"transient_fault","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"$past_iso","source":"after_provider_response","failure_mode":"transient_http","usable_at":"$past_iso","consecutive_failure_count":1}
JSON
out=$(bash "$bin" --probe-all --dry-run 2>&1) || true
echo "$out" | grep -q "would probe hetzner/qwen" \
    || fail "--probe-all should probe hetzner (transient_http, expired)"
ok "--probe-all probes non-walled expired seats"

# Without --probe-all, transient_http is skipped.
out=$(bash "$bin" --dry-run 2>&1) || true
! echo "$out" | grep -q "would probe hetzner" \
    || fail "default mode should NOT probe hetzner (transient_http not walled)"
ok "default mode skips non-walled failure modes"

# --- Test 5: systemd unit validity + timer manifest entry ---
if command -v systemd-analyze >/dev/null 2>&1; then
    # systemd-analyze verify checks that ExecStart points at an executable.
    # The unit points at the installed path; create a temporary symlink for
    # the test, then remove it (the real install is fleet-ops#1348's job).
    if [[ ! -e "$installed_bin" ]]; then
        mkdir -p "$(dirname "$installed_bin")"
        ln -s "$bin" "$installed_bin"
        cleanup_installed_bin=1
    fi
    systemd-analyze verify "$repo_root/systemd/seat-walled-probe.service" \
        "$repo_root/systemd/seat-walled-probe.timer" 2>&1 | grep -q "seat-walled-probe" \
        && fail "systemd-analyze reported seat-walled-probe unit errors" || true
    ok "systemd-analyze accepts seat-walled-probe units"
else
    ok "systemd-analyze not available — skipping unit verify"
fi

python3 -c "
import json, sys
d = json.load(open('$repo_root/systemd/timer-manifest.json'))
t = d['timers'].get('seat-walled-probe.timer')
assert t is not None, 'seat-walled-probe.timer missing from manifest'
assert t['classification'] == 'scheduled', t
assert 'fleet-ops#1348' in t['reason'], t
print('OK: seat-walled-probe.timer has manifest entry')
"

echo "ALL seat-walled-probe tests passed"
