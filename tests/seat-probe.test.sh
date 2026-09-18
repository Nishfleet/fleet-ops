#!/usr/bin/env bash
# tests/seat-probe.test.sh — offline tests for lib/seat-probe.sh
# (fleet-ops#7776): a walled LiteLLM group must cost one probe per backoff
# window, not one dead claim/start/verdict cycle per attempt. curl and the
# key command are stubbed; no proxy, no network, no journald.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
probe="$repo_root/lib/seat-probe.sh"
[[ -f "$probe" ]] || { echo "FAIL: lib/seat-probe.sh missing"; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch=$(mktemp -d -t seat-probe.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- stubbed curl: serves canned headers/body, counts calls -------------------
cat >"$scratch/fake-curl" <<'EOF'
#!/usr/bin/env bash
echo x >>"$FAKE_CURL_COUNT"
hdr="$FAKE_CURL_HDR"; body="$FAKE_CURL_BODY"; code="$FAKE_CURL_CODE"
while [ $# -gt 0 ]; do
  case "$1" in
    -D) printf '%s' "$hdr" >"$2"; shift 2 ;;
    -o) printf '%s' "$body" >"$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "$code"
EOF
chmod +x "$scratch/fake-curl"

export FLEET_SEAT_PROBE_CURL="$scratch/fake-curl"
export FLEET_SEAT_PROBE_KEY_CMD="echo sk-test"
export FLEET_SEAT_PROBE_STATE_DIR="$scratch/state"
export FLEET_SEAT_PROBE_HEALTH_FILE="$scratch/state/pi-seat-health.json"
export FLEET_SEAT_PROBE_NOW=10000
export FAKE_CURL_COUNT="$scratch/calls"
: >"$FAKE_CURL_COUNT"

calls() { wc -l <"$FAKE_CURL_COUNT" | tr -d ' '; }
run() { set +e; out=$("$@" 2>&1); rc=$?; set -e; }

healthy() {
  export FAKE_CURL_CODE=200
  export FAKE_CURL_HDR=$'HTTP/1.1 200 OK\r\nx-litellm-model-id: synthetic-glm53flash-worker-cheap\r\n\r\n'
  export FAKE_CURL_BODY='data: {"choices":[{"delta":{"tool_calls":[{"function":{"name":"probe_ok"}}]}}]}'
}
walled() {
  export FAKE_CURL_CODE=429
  export FAKE_CURL_HDR=$'HTTP/1.1 429 Too Many Requests\r\n\r\n'
  export FAKE_CURL_BODY='{"error":{"message":"rate limited"}}'
}

# --- 1. flag off -> pass-through, zero probes ---------------------------------
export FLEET_SEAT_PROBE=0
walled
run bash "$probe" worker-cheap
[[ "$rc" == 0 ]] || fail "FLEET_SEAT_PROBE=0 must exit 0, got $rc ($out)"
[[ "$(calls)" == 0 ]] || fail "disabled probe must not call curl"
ok "FLEET_SEAT_PROBE=0 disables the gate (revert switch)"
export FLEET_SEAT_PROBE=1

# --- 2. live group: 200 + tool_calls + non-devin id -> exit 0 ------------------
healthy
run bash "$probe" worker-cheap
[[ "$rc" == 0 ]] || fail "live group must exit 0, got $rc ($out)"
[[ "$(calls)" == 1 ]] || fail "one probe expected, got $(calls)"
[[ ! -f "$scratch/state/seat-wall-worker-cheap.json" ]] || fail "live probe must not write wall state"
ok "200 + tool_calls + non-devin x-litellm-model-id exits 0"

# --- 3. walled group: 429 -> exit 1 + one SEAT-WALL line + state + health -----
walled
run bash "$probe" worker-cheap
[[ "$rc" == 1 ]] || fail "walled group must exit 1, got $rc"
printf '%s\n' "$out" | grep -qx 'SEAT-WALL group=worker-cheap retry_after=300' \
  || fail "expected 'SEAT-WALL group=worker-cheap retry_after=300', got: $out"
printf '%s\n' "$out"   # keep the SEAT-WALL line in the test's own output (VERIFY must-match)
[[ -f "$scratch/state/seat-wall-worker-cheap.json" ]] || fail "wall state file missing"
grep -q '"next_probe_at":10300' "$scratch/state/seat-wall-worker-cheap.json" \
  || fail "backoff must be 300s (min 5 min)"
grep -q '"health_class":"seat-wall"' "$scratch/state/pi-seat-health.json" \
  || fail "pi-seat-health.json must carry health_class=seat-wall"
grep -q '"model":"worker-cheap"' "$scratch/state/pi-seat-health.json" \
  || fail "seat-wall record must name the group"
ok "429 walls the group: one SEAT-WALL line, 300s backoff, seat-wall health"

# --- 4. suppressed re-check: zero API calls, still exit 1, still one line ----
run bash "$probe" worker-cheap
[[ "$rc" == 1 ]] || fail "suppressed check must exit 1, got $rc"
[[ "$(calls)" == 2 ]] || fail "backoff must suppress the probe (calls=$(calls), want 2 total)"
[[ "$(printf '%s\n' "$out" | grep -c 'SEAT-WALL')" == 0 ]] \
  || fail "suppressed check must not re-log SEAT-WALL (log once)"
ok "backoff suppresses re-probes: zero API calls inside the window"

# --- 5. second wall after the window: backoff doubles --------------------------
export FLEET_SEAT_PROBE_NOW=$((10000 + 301))
run bash "$probe" worker-cheap
[[ "$rc" == 1 ]] || fail "still walled must exit 1"
grep -q '"retry_after":600' "$scratch/state/seat-wall-worker-cheap.json" \
  || fail "backoff must double to 600"
ok "backoff doubles across wall episodes (300 -> 600)"

# --- 6. replay: 12 more refused starts inside the window = zero new probes ----
export FLEET_SEAT_PROBE_NOW=$((10000 + 400))
for _ in $(seq 12); do run bash "$probe" worker-cheap; done
[[ "$(calls)" == 3 ]] || fail "12 refused starts inside the window must not probe (calls=$(calls), want 3)"
ok "replay: a walled group costs one probe per window, not one per start"

# --- 7. devin deployment id is walled even when tool_calls appear -------------
export FLEET_SEAT_PROBE_NOW=$((10000 + 1000 + 1201))
rm -f "$scratch/state/seat-wall-worker-cheap.json"
export FAKE_CURL_CODE=200
export FAKE_CURL_HDR=$'HTTP/1.1 200 OK\r\nx-litellm-model-id: devin-swe-2-max-senior\r\n\r\n'
export FAKE_CURL_BODY='data: {"choices":[{"delta":{"tool_calls":[{}]}}]}'
run bash "$probe" worker-capable
[[ "$rc" == 1 ]] || fail "devin-served response must be treated as walled, got $rc"
printf '%s\n' "$out" | grep -q 'SEAT-WALL group=worker-capable' \
  || fail "devin wall must log SEAT-WALL for the group, got: $out"
ok "x-litellm-model-id *devin* is walled even with a tool_calls chunk"

# --- 8. 200 without tool_calls is walled ---------------------------------------
export FLEET_SEAT_PROBE_NOW=$((10000 + 3000))
export FAKE_CURL_HDR=$'HTTP/1.1 200 OK\r\nx-litellm-model-id: synthetic-glm53flash-worker-cheap\r\n\r\n'
export FAKE_CURL_BODY='data: {"choices":[{"delta":{"content":"pong"}}]}'
run bash "$probe" worker-cheap
[[ "$rc" == 1 ]] || fail "200 with no tool_calls must be walled, got $rc"
ok "a 200 with no tool_calls chunk is walled (a silent no-op is not a seat)"

# --- 9. recovery: wall state clears, health record flips to healthy -----------
export FLEET_SEAT_PROBE_NOW=$((10000 + 4000))
healthy
run bash "$probe" worker-cheap
[[ "$rc" == 0 ]] || fail "recovered group must exit 0, got $rc"
[[ ! -f "$scratch/state/seat-wall-worker-cheap.json" ]] || fail "wall state must clear on a live probe"
grep -q '"health_class":"healthy"' "$scratch/state/pi-seat-health.json" \
  || fail "seat-wall record must flip to healthy on recovery"
ok "live probe clears the wall and flips the group's health record"

# --- 10. infra fault (key unreadable) -> exit 2, no wall state -----------------
export FLEET_SEAT_PROBE_KEY_CMD=false
run bash "$probe" worker-cheap
[[ "$rc" == 2 ]] || fail "key fault must exit 2, got $rc"
[[ ! -f "$scratch/state/seat-wall-worker-cheap.json" ]] || fail "infra fault must not write wall state"
export FLEET_SEAT_PROBE_KEY_CMD="echo sk-test"
ok "probe infrastructure faults exit 2 and do not masquerade as a wall"

# --- 11. multi-group arg: any walled group fails the condition -----------------
export FLEET_SEAT_PROBE_NOW=$((10000 + 6000))
rm -f "$scratch/state"/seat-wall-*.json
healthy
run bash "$probe" worker-cheap worker-capable
[[ "$rc" == 0 ]] || fail "both live must exit 0, got $rc"
walled
run bash "$probe" worker-cheap worker-capable
[[ "$rc" == 1 ]] || fail "one walled group must fail the condition, got $rc"
printf '%s\n' "$out" | grep -q 'SEAT-WALL group=worker-cheap' \
  || fail "multi-group run must name the walled group, got: $out"
ok "intake shape: worker-cheap + worker-capable probed together, either wall skips"

# --- 12. unit wiring: both worker units gate on the probe ----------------------
grep -q 'seat-probe.sh; \[ -x "\$x" \] || exit 0; exec "\$x" worker-cheap worker-capable' \
  "$repo_root/systemd/pi-intake@.service" \
  || fail "pi-intake@ must ExecCondition the probe on both worker groups"
grep -q 'seat-probe.sh; \[ -x "\$x" \] || exit 0; exec "\$x" worker-capable' \
  "$repo_root/systemd/pi-issue@.service" \
  || fail "pi-issue@ must ExecCondition the probe on worker-capable"
grep -q 'no-tools-unit' "$repo_root/systemd/pi-issue-failed@.service" \
  || fail "pi-issue-failed@ must skip release on a no-tools verdict"
ok "units wired: ExecCondition gates intake + worker, release skips no-tools"

echo "OK: seat-probe.test.sh — all checks passed"
