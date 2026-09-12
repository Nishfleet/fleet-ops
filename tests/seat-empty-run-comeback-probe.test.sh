#!/usr/bin/env bash
# tests/seat-empty-run-comeback-probe.test.sh
#
# fleet-ops#4819: an empty-run bench must not be released by a tools=0
# standing-smoke reply. The comeback-release probe is the trigger; it may
# release only on tools>0 AND non-empty stdout. The spawn-bench marker
# carries that contract inline so a judge cannot hand-release on "Reply OK".
#
# Drills (issue accept):
#   1. empty-run class + tools=0 probe reply -> seat stays benched, logged
#   2. same seat + tools>0 and non-empty stdout -> released, one actions.log line
# Also: mark_seat_empty_run writes failure_mode + citation +
# release_requires=real-work-probe; a guessed PROBE_TOKEN with tools=0
# still holds (the standing-smoke lie with a lucky "42").
#
# Offline: scratch ledger, stub pi, no network, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
BIN="$repo_root/bin/fleet-seat-comeback-release"
seat_lib="$repo_root/lib/litellm-seat.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$BIN" ]] || fail "missing $BIN"
"$BIN" --help >/dev/null || fail "--help must exit 0"

TMPD="$(mktemp -d -t empty-run-comeback-probe.XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT INT TERM

NOW_ISO="2026-08-30T12:00:00Z"
SEATDIR="$TMPD/seats"
mkdir -p "$SEATDIR" "$TMPD/home" "$TMPD/xdg"
export HOME="$TMPD/home"
export XDG_RUNTIME_DIR="$TMPD/xdg"
export PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR"
export PI_SEAT_HEALTH_SIDECAR="$TMPD/pi-seat-health.json"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export PI_SEAT_CREDENTIAL_PRECHECK=0
export FLEET_SEAT_COMEBACK_ACTIONS_LOG="$TMPD/actions.log"
export FLEET_SEAT_COMEBACK_NOW="$NOW_ISO"
export SEAT_LOG_FILE="$TMPD/watch.log"

cat > "$TMPD/seat-caps.json" <<'CAPS'
{
  "free_providers_in_order": ["ollama"],
  "providers": {
    "ollama": { "cap": 8, "class": "free", "models": { "deepseek-v4-flash:0731": 8 } }
  }
}
CAPS
export SEAT_CAPS_JSON="$TMPD/seat-caps.json"

# --- 0. marker write carries the release contract inline --------------------
# shellcheck disable=SC1091
source "$seat_lib"
mark_seat_empty_run "ollama" "deepseek-v4-flash:0731" "test:4819:empty" >/dev/null 2>&1 \
  || fail "0: mark_seat_empty_run failed"
mk=$(seat_spawn_bench_path "ollama" "deepseek-v4-flash:0731")
jq -e '.failure_mode == "empty_run"
        and .release_requires == "real-work-probe"
        and .citation == "fleet-ops#3737"' "$mk" >/dev/null \
  || fail "0: marker must carry failure_mode=empty_run, release_requires=real-work-probe, citation=fleet-ops#3737: $(cat "$mk")"
ok "0: mark_seat_empty_run writes failure_mode + release_requires + citation (fleet-ops#4819)"

# Fresh ledger/marker fixtures for the probe drills. usable_at is PAST
# (NOW_ISO=12:00Z) so the #3737 expired-marker path owes a probe.
write_expired_empty_run_fixture() {
    cat > "$SEATDIR/ollama__deepseek-v4-flash_0731.json" << 'EOF'
{"provider":"ollama","model":"deepseek-v4-flash:0731","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF
    cat > "$SEATDIR/ollama__deepseek-v4-flash_0731.spawn-bench.json" << 'EOF'
{"provider":"ollama","model":"deepseek-v4-flash:0731","usable_at":"2026-08-30T11:15:00Z","reason":"pi-issue:fleet-ops-3737:provider-no-op:stdout=0B","written_at":"2026-08-30T11:00:00Z","backoff_s":900,"failure_mode":"empty_run","consecutive_failure_count":3,"writer":"mark_seat_empty_run"}
EOF
}

# --- stubs ----------------------------------------------------------------
cat > "$TMPD/pi-tools0-ok" <<'EOF'
#!/usr/bin/env bash
# Standing smoke: rc=0, prints OK, PACKET-VERDICT tools=0 class=no-tools.
# Must NEVER release an empty-run bench (fleet-ops#4819).
printf 'PACKET-VERDICT tools=0 class=no-tools\n' >&2
printf 'OK\n'
exit 0
EOF
cat > "$TMPD/pi-tools0-guess42" <<'EOF'
#!/usr/bin/env bash
# Inline guess of the computed token with tools=0. Without the tools>0
# gate this would release (PROBE_TOKEN matches). Must HOLD.
printf 'PACKET-VERDICT tools=0 class=no-tools\n' >&2
printf '42\n'
exit 0
EOF
cat > "$TMPD/pi-tool-ok-stdout" <<'EOF'
#!/usr/bin/env bash
# Real-work probe: token on stdout, PACKET-VERDICT on stdout (print-safe).
printf '42\nPACKET-VERDICT tools=1 class=worked\n'
exit 0
EOF
chmod +x "$TMPD/pi-tools0-ok" "$TMPD/pi-tools0-guess42" "$TMPD/pi-tool-ok-stdout"

run_sweep() {
    local stub="$1" errf="$2"
    : > "$FLEET_SEAT_COMEBACK_ACTIONS_LOG"
    set +e
    PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
        SEAT_CAPS_JSON="$TMPD/seat-caps.json" \
        FLEET_SEAT_COMEBACK_STATE="$TMPD/state.json" \
        FLEET_SEAT_COMEBACK_PROM="$TMPD/release.prom" \
        FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
        FLEET_SEAT_COMEBACK_ACTIONS_LOG="$FLEET_SEAT_COMEBACK_ACTIONS_LOG" \
        PI_BIN="$stub" \
        bash "$BIN" >/dev/null 2>"$errf"
    echo $?
    set -e
}

# --- 1. tools=0 standing smoke -> HOLD, logged ---------------------------
write_expired_empty_run_fixture
rm -f "$TMPD/state.json"
rc=$(run_sweep "$TMPD/pi-tools0-ok" "$TMPD/hold.err")
[[ "$rc" == "0" ]] || fail "1: sweep must exit 0 (re-benched, not loud), got $rc ($(cat "$TMPD/hold.err"))"
hc=$(jq -r '.health_class' "$SEATDIR/ollama__deepseek-v4-flash_0731.json")
[[ "$hc" == "healthy" ]] || fail "1: ledger must stay healthy (marker is the hold), got $hc"
mk_usable=$(jq -r '.usable_at' "$SEATDIR/ollama__deepseek-v4-flash_0731.spawn-bench.json")
mk_epoch=$(date -u -d "$mk_usable" +%s 2>/dev/null || echo 0)
now_e=$(date -u -d "$NOW_ISO" +%s)
(( mk_epoch > now_e )) || fail "1: marker usable_at must be re-benched into the future, got $mk_usable"
grep -q 'HOLD (tools=0' "$TMPD/hold.err" \
  || fail "1: must log tools=0 HOLD: $(cat "$TMPD/hold.err")"
grep -qi 'COMEBACK-RELEASE .*unwalled by real-work probe' "$FLEET_SEAT_COMEBACK_ACTIONS_LOG" \
  && fail "1: tools=0 must not write a release line: $(cat "$FLEET_SEAT_COMEBACK_ACTIONS_LOG")"
jq -e '.failure_mode == "empty_run" and .release_requires == "real-work-probe" and .citation == "fleet-ops#3737"' \
  "$SEATDIR/ollama__deepseek-v4-flash_0731.spawn-bench.json" >/dev/null \
  || fail "1: re-bench must inject release_requires+citation: $(cat "$SEATDIR/ollama__deepseek-v4-flash_0731.spawn-bench.json")"
ok "1: empty-run + tools=0 standing smoke -> stays benched, logged (fleet-ops#4819)"

# --- 1b. guessed token + tools=0 still HOLDs ----------------------------
write_expired_empty_run_fixture
rm -f "$TMPD/state.json"
rc=$(run_sweep "$TMPD/pi-tools0-guess42" "$TMPD/guess.err")
[[ "$rc" == "0" ]] || fail "1b: sweep must exit 0, got $rc ($(cat "$TMPD/guess.err"))"
hc=$(jq -r '.health_class' "$SEATDIR/ollama__deepseek-v4-flash_0731.json")
[[ "$hc" == "healthy" ]] || fail "1b: guessed-42 tools=0 must not unwall ledger, got $hc"
grep -q 'HOLD (tools=0' "$TMPD/guess.err" \
  || fail "1b: must log tools=0 HOLD: $(cat "$TMPD/guess.err")"
grep -qi 'unwalled by real-work probe' "$FLEET_SEAT_COMEBACK_ACTIONS_LOG" \
  && fail "1b: guessed token with tools=0 must not release: $(cat "$FLEET_SEAT_COMEBACK_ACTIONS_LOG")"
ok "1b: guessed PROBE_TOKEN with tools=0 does not release (fleet-ops#4819)"

# --- 2. tools>0 + non-empty stdout -> released, one actions.log line ------
write_expired_empty_run_fixture
rm -f "$TMPD/state.json"
rc=$(run_sweep "$TMPD/pi-tool-ok-stdout" "$TMPD/release.err")
[[ "$rc" == "0" ]] || fail "2: sweep must exit 0, got $rc ($(cat "$TMPD/release.err"))"
hc=$(jq -r '.health_class' "$SEATDIR/ollama__deepseek-v4-flash_0731.json")
[[ "$hc" == "healthy" ]] || fail "2: successful real-work probe must leave ledger healthy, got $hc"
obs=$(jq -r '.observed_at' "$SEATDIR/ollama__deepseek-v4-flash_0731.json")
[[ "$obs" == "$NOW_ISO" ]] \
  || fail "2: unwall must refresh observed_at to sweep now, got $obs"
grep -q 'SUCCEEDED (tool-using tools=1' "$TMPD/release.err" \
  || fail "2: must log tool-using success: $(cat "$TMPD/release.err")"
rel_lines=$(grep -c 'COMEBACK-RELEASE seat=ollama/deepseek-v4-flash:0731 unwalled by real-work probe (tools>0, non-empty stdout)' "$FLEET_SEAT_COMEBACK_ACTIONS_LOG" || true)
[[ "$rel_lines" == "1" ]] \
  || fail "2: exactly one actions.log release line, got $rel_lines: $(cat "$FLEET_SEAT_COMEBACK_ACTIONS_LOG")"
ok "2: empty-run + tools>0 + non-empty stdout -> released, one actions.log line (fleet-ops#4819)"

echo "ALL OK: empty-run comeback probe (fleet-ops#4819)"
