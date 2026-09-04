#!/usr/bin/env bash
# tests/seat-transport-down.test.sh
#
# fleet-ops#3238: transport-down gate for the bash seat-bench writers and the
# post-recovery sweep in bin/pi-transport-self-heal.
#
# Proves:
#   1. mark_seat_spawn_fail / empty_run / quota_bench / overload_bench /
#      hang_bench write NO per-seat bench when the transport is down; they
#      write exactly one transport-down.json marker.
#   2. _mark_transport_down preserves first_observed_at across repeated hits.
#   3. pi-transport-self-heal, on recovery, quarantines only benches whose
#      written_at / observed_at falls inside the transport-down window.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"
self_heal="$repo_root/bin/pi-transport-self-heal"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
[[ -x "$self_heal" ]] || fail "pi-transport-self-heal not found or not executable: $self_heal"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-transport-down.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# ---------------------------------------------------------------------------
# 1. Gate test: every bench writer charges the run to transport, not the seat
# ---------------------------------------------------------------------------
led="$scratch/ledger-gate"
st="$scratch/state-gate"
mkdir -p "$led" "$st" "$scratch/xdg"

fake_probe="$scratch/pi-transport-check-fail"
cat >"$fake_probe" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$fake_probe"

export PI_PACKET_STATE="$st"
export PI_SEAT_HEALTH_LEDGER_DIR="$led"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_TRANSPORT_CHECK="$fake_probe"
export PI_SEAT_LIB_CHECK_TRANSPORT=1
export HOME="$scratch/home"  # isolate from real seat-caps / quality-routing
mkdir -p "$HOME"

source "$lib"

p="devin"; m="glm-5-2"
tm="$st/transport-down.json"

# Each writer should return 1 and only write/refresh the transport-down marker.
writer_should_charge_transport() {
    local name="$1"; shift
    rm -f "$led"/*.json

    if "mark_seat_$name" "$p" "$m" "$@" >/dev/null 2>&1; then
        fail "$name: must return 1 when transport is down"
    fi

    [[ -f "$tm" ]] || fail "$name: transport-down marker not written at $tm"
    [[ "$(jq -r '.transport' "$tm")" == "down" ]] || fail "$name: transport-down marker missing transport=down"
    [[ -n "$(jq -r '.first_observed_at // ""' "$tm")" ]] || fail "$name: transport-down marker missing first_observed_at"
    [[ "$(jq -r '.last_charged_provider' "$tm")" == "$p" ]] || fail "$name: transport-down marker wrong provider"
    [[ "$(jq -r '.last_charged_model' "$tm")" == "$m" ]] || fail "$name: transport-down marker wrong model"

    local lf
    lf="$led/devin__glm-5-2.json"
    [[ ! -f "$lf" ]] || fail "$name: per-seat ledger written despite transport-down ($lf)"
    [[ ! -f "$led/devin__glm-5-2.spawn-bench.json" ]] || fail "$name: spawn-bench marker written despite transport-down"
}

writer_should_charge_transport spawn_fail "test:spawn:no-block"
first_observed="$(jq -r '.first_observed_at' "$tm")"
writer_should_charge_transport empty_run "test:empty:tools=0"
[[ "$(jq -r '.first_observed_at' "$tm")" == "$first_observed" ]] || fail "_mark_transport_down did not preserve first_observed_at"
writer_should_charge_transport quota_bench "resets in 5m"
writer_should_charge_transport overload_bench "503 Upstream model provider is temporarily unavailable retry after 120"
writer_should_charge_transport hang_bench

ok "3238-gate: all bench writers charge transport-down and write no per-seat marker"

# Fail-open test: if the transport-check is disabled, a per-seat bench is written.
rm -f "$led"/*.json "$tm"
export PI_SEAT_LIB_CHECK_TRANSPORT=0
if ! mark_seat_empty_run "$p" "$m" "test:transport-check-disabled" >/dev/null 2>&1; then
    fail "empty_run with PI_SEAT_LIB_CHECK_TRANSPORT=0 must still write per-seat bench"
fi
[[ -f "$led/devin__glm-5-2.json" ]] || fail "empty_run with transport check disabled did not write ledger"
ok "3238-gate: PI_SEAT_LIB_CHECK_TRANSPORT=0 fail-open writes per-seat bench"

# ---------------------------------------------------------------------------
# 2. Self-heal sweep test: only benches inside the down window are quarantined
# ---------------------------------------------------------------------------
led2="$scratch/ledger-sweep"
st2="$scratch/state-sweep"
mkdir -p "$led2" "$st2" "$scratch/bin"

probe_fail_sentinel="$st2/probe-fail"
touch "$probe_fail_sentinel"

probe="$st2/pi-transport-check"
cat >"$probe" <<'SH'
#!/usr/bin/env bash
if [[ -f "$PI_TRANSPORT_PROBE_FAIL_SENTINEL" ]]; then
  exit 1
fi
exit 0
SH
chmod +x "$probe"

npm="$scratch/bin/npm"
cat >"$npm" <<'SH'
#!/usr/bin/env bash
# Stub npm for self-heal sweep testing. On rebuild, clear the probe sentinel
# so the post-heal probe succeeds.
if [[ "$1" == "rebuild" ]]; then
  rm -f "${PI_TRANSPORT_PROBE_FAIL_SENTINEL:?no sentinel}" 2>/dev/null || true
  exit 0
fi
exit 0
SH
chmod +x "$npm"

pi_bin="$st2/pi"
: >"$pi_bin"

# Build a down window that starts 3 minutes ago and ends at recovery time.
now_s=$(date -u +%s)
first_s=$(( now_s - 180 ))
observed_s=$(( now_s - 60 ))
first_iso=$(date -u -d "@$first_s" +%Y-%m-%dT%H:%M:%SZ)
observed_iso=$(date -u -d "@$observed_s" +%Y-%m-%dT%H:%M:%SZ)

jq -n \
  --arg first "$first_iso" \
  --arg observed "$observed_iso" \
  --arg p "$p" --arg m "$m" \
  '{transport:"down", first_observed_at:$first, observed_at:$observed, last_charged_provider:$p, last_charged_model:$m}' \
  >"$st2/transport-down.json"

# Inside window: bench observed_at 90s ago (between first and now).
inside_obs_s=$(( now_s - 90 ))
inside_obs=$(date -u -d "@$inside_obs_s" +%Y-%m-%dT%H:%M:%SZ)
jq -n \
  --arg observed "$inside_obs" \
  '{provider:"devin", model:"glm-5-2", health_class:"transient_fault", observed_at:$observed, consecutive_failure_count:1}' \
  >"$led2/devin__glm-5-2.json"

# Outside window: bench observed_at 5 minutes ago (before first_observed_at).
outside_obs_s=$(( now_s - 300 ))
outside_obs=$(date -u -d "@$outside_obs_s" +%Y-%m-%dT%H:%M:%SZ)
jq -n \
  --arg observed "$outside_obs" \
  '{provider:"opencode", model:"mimo-v2.5-free", health_class:"transient_fault", observed_at:$observed, consecutive_failure_count:2}' \
  >"$led2/opencode__mimo-v2.5-free.json"

# Healthy ledger must never be swept.
jq -n \
  --arg observed "$inside_obs" \
  '{provider:"cursor", model:"composer-2.5", health_class:"healthy", observed_at:$observed, consecutive_failure_count:0}' \
  >"$led2/cursor__composer-2.5.json"

export PI_TRANSPORT_CHECK="$probe"
export PI_TRANSPORT_PROBE_FAIL_SENTINEL="$probe_fail_sentinel"
export PI_TRANSPORT_HEAL_STATE="$st2"
export SEAT_LEDGER_DIR="$led2"
export SEAT_TRANSPORT_DOWN_MARKER="$st2/transport-down.json"
export PI_BIN="$pi_bin"
export PATH="$scratch/bin:$PATH"

if ! bash "$self_heal" >/dev/null 2>&1; then
    fail "pi-transport-self-heal should exit 0 after fake rebuild/probe"
fi

q_dir=$(find "$scratch" -maxdepth 1 -type d -name 'ledger-sweep-bench-poisoned-pi-transport-*' | head -n1)
[[ -n "$q_dir" ]] || fail "self-heal did not create a quarantine dir"

[[ -f "$q_dir/devin__glm-5-2.json" ]] || fail "inside-window bench not quarantined"
[[ ! -f "$q_dir/opencode__mimo-v2.5-free.json" ]] || fail "outside-window bench was wrongly quarantined"
[[ ! -f "$q_dir/cursor__composer-2.5.json" ]] || fail "healthy ledger was wrongly quarantined"
[[ -f "$led2/opencode__mimo-v2.5-free.json" ]] || fail "outside-window bench was removed from ledger"
[[ -f "$led2/cursor__composer-2.5.json" ]] || fail "healthy ledger was removed from ledger"

[[ -f "$st2/transport-down.json" ]] || fail "transport-down marker missing after self-heal"
[[ "$(jq -r '.transport' "$st2/transport-down.json")" == "recovered" ]] || fail "transport-down marker not set to recovered"
[[ -n "$(jq -r '.recovered_at // ""' "$st2/transport-down.json")" ]] || fail "recovered_at not set on marker"
[[ -n "$(jq -r '.quarantine_dir // ""' "$st2/transport-down.json")" ]] || fail "quarantine_dir not set on marker"

ok "3238-sweep: self-heal quarantines only benches inside the transport-down window"
