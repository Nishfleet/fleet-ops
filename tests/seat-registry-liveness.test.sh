#!/usr/bin/env bash
# tests/seat-registry-liveness.test.sh
#
# fleet-ops#5141: a live Type=oneshot pi worker reports
# ActiveState=activating / SubState=start for its ENTIRE run (systemd
# reports activating/start from ExecStart to exit), so the liveness bound
# for a started process is the unit's OWN TimeoutStartSec — read back as
# TimeoutStartUSec and parsed by _seat_duration_to_s — not a hardcoded
# 300s. The old bound reaped every live worker older than 5 minutes
# (63 reaps in watch.log, all "(SubState=start, threshold=300s)").
# fleet-ops#993: age is measured from ExecMainStartTimestampMonotonic
# (ActiveEnterTimestampMonotonic is 0 for every still-activating oneshot).
# fleet-ops#1361: activating with no started process
# (ExecMainStartTimestampMonotonic=0) or SubState=auto-restart fails
# closed at the short PI_SEAT_ACTIVATING_NO_PROCESS_MAX_S bound (300s).
#
# What we prove:
#   1. activating/start with a process inside the unit's own
#      TimeoutStartUSec is LIVE — 400s and 40min under a 45min bound —
#      and its registry file survives the _seat_live_registry_files sweep.
#   2. activating/start past its own TimeoutStartUSec (50min under 45min)
#      is REAPED: _seat_registry_unit_live returns 1 and the sweep
#      deletes the registry file.
#   3. activating with ExecMainStartTimestampMonotonic=0 ages from
#      ActiveEnterTimestampMonotonic and reaps at the 300s no-process
#      bound.
#   4. activating/auto-restart reaps at the 300s bound even when the
#      process timestamp exists (RestartSec=240 < 300 keeps a normal
#      restart's seat — fleet-ops#63).
#   5. A per-unit bound shorter than the fallback wins: a 10min
#      TimeoutStartUSec unit reaps at 20min of age.
#   6. TimeoutStartUSec=infinity or unparseable falls back to
#      PI_SEAT_ACTIVATING_MAX_S (3300s): 50min is live, 56min reaps.
#   7. Drift block: systemd/pi-issue@.service still declares Type=oneshot
#      and its TimeoutStartSec stays <= the fallback bound — otherwise
#      the premise of this probe needs re-review (fleet-ops#5141).
#
# Stub systemd + a scratch registry. Pure unit test — no pi, no real
# fleet, no network.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

# Hermetic when nested under tests/seat.lib.test.sh (fleet-ops#449), which
# export -f systemctl and awk. Functions beat PATH; this file ships its
# own fake systemctl.
unset -f systemctl awk 2>/dev/null || true

# Fresh-runner floor (fleet-ops#94/#98 shape, same idiom as
# seat.lib.test.sh): the liveness cases need monotonic ages up to 3360s,
# so every /proc/uptime read sees >= 3700s. The lib's clock and mono_ago
# share this one shimmed clock.
awk() {
  if [[ "$*" == *'/proc/uptime'* ]] && [[ "$*" == *'print int($1)'* ]]; then
    local real_s
    real_s=$(command awk '{print int($1)}' /proc/uptime)
    if (( real_s < 3700 )); then real_s=3700; fi
    echo "$real_s"
  else
    command awk "$@"
  fi
}

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-registry-liveness.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- stub systemd ----------------------------------------------------------
# Reads units + their active/sub states from flat files so the test can
# drive list-units/show/is-active by changing those files. props.db is a
# generic per-unit property table (unit|property|value) for the monotonic
# timestamps and TimeoutStartUSec that _seat_registry_unit_live consults.
fake="$scratch/systemctl"
active_db="$scratch/active.db"
sub_db="$scratch/sub.db"
exec_db="$scratch/exec.db"
props_db="$scratch/props.db"
: >"$active_db"; : >"$sub_db"; : >"$exec_db"; : >"$props_db"
cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
case "$1" in
  list-units)
    shift
    state_filter=""
    type_filter=""
    declare -a patterns=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --state=*) state_filter="${1#--state=}"; shift ;;
        --state)   state_filter="$2"; shift 2 ;;
        --type=*)  type_filter="${1#--type=}"; shift ;;
        --type)    type_filter="$2"; shift 2 ;;
        --no-legend) shift ;;
        --plain) shift ;;
        *) patterns+=("$1"); shift ;;
      esac
    done
    while IFS= read -r u; do
      [[ -n "$u" ]] || continue
      active=$(grep -F "$u|" "$FAKE_ACTIVE_DB" | head -n1 | cut -d'|' -f2)
      sub=$(grep -F "$u|" "$FAKE_SUB_DB" | head -n1 | cut -d'|' -f2)
      [[ -z "$active" ]] && continue
      # Match against any pattern (globs). No patterns = match all.
      if ((${#patterns[@]})); then
        pat_match=0
        for pat in "${patterns[@]}"; do
          [[ -z "$pat" ]] && continue
          # shellcheck disable=SC2254
          case "$u" in
            $pat) pat_match=1 ;;
          esac
        done
        (( pat_match )) || continue
      fi
      if [[ -n "$state_filter" ]]; then
        match=0
        IFS=',' read -ra wants <<<"$state_filter"
        for w in "${wants[@]}"; do [[ "$w" == "$active" ]] && match=1; done
        (( match )) || continue
      fi
      printf '%s loaded %s %s\tfake description\n' "$u" "$active" "$sub"
    done < <(awk -F'|' 'NR>0 {print $1}' "$FAKE_ACTIVE_DB" | sort -u)
    exit 0
    ;;
  show)
    # systemd's `show` accepts: `show -p PROP [--value] UNIT` and
    # `show UNIT --property=PROP --value` in any order. The UNIT is the
    # last positional; --value is a boolean flag (no arg). Extract the
    # prop and the unit without consuming both as args.
    prop=""
    unit=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -p) prop="$2"; shift 2 ;;
        --value) shift ;;
        --property=*) prop="${1#--property=}"; shift ;;
        *) unit="$1"; shift ;;
      esac
    done
    case "$prop" in
      ActiveState)
        grep -F "${unit}|" "$FAKE_ACTIVE_DB" | head -n1 | cut -d'|' -f2
        ;;
      SubState)
        grep -F "${unit}|" "$FAKE_SUB_DB" | head -n1 | cut -d'|' -f2
        ;;
      ExecStart)
        grep -F "${unit}|" "$FAKE_EXEC_DB" 2>/dev/null | head -n1 | cut -d'|' -f2-
        ;;
      *)
        # Generic property table (unit|property|value):
        # ExecMainStartTimestampMonotonic, ActiveEnterTimestampMonotonic,
        # TimeoutStartUSec, ... A missing row prints nothing, matching
        # `systemctl show --value` for an unset property.
        grep -F "${unit}|${prop}|" "$FAKE_PROPS_DB" 2>/dev/null | head -n1 | cut -d'|' -f3-
        ;;
    esac
    exit 0
    ;;
  is-active)
    unit="${2:-}"
    grep -F "${unit}|" "$FAKE_ACTIVE_DB" | head -n1 | cut -d'|' -f2
    exit 0
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake"
export FAKE_ACTIVE_DB="$active_db"
export FAKE_SUB_DB="$sub_db"
export FAKE_EXEC_DB="$exec_db"
export FAKE_PROPS_DB="$props_db"

# Put the fake systemctl on PATH so seatlib.sh's bare `systemctl --user ...`
# invocations hit the stub instead of the real systemd user instance.
mkdir -p "$scratch/bin"
ln -sf "$fake" "$scratch/bin/systemctl"
export PATH="$scratch/bin:$PATH"

# --- seed a minimal cap map + models.json so pick-seat is not in the way ---
export HOME="$scratch/home"
mkdir -p "$HOME/.local/state/pi-packet"
cat >"$HOME/.local/state/pi-packet/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "providers": {
    "devin": {
      "cap": 4,
      "class": "subscription",
      "models": { "swe-1-7": 4 }
    }
  }
}
JSON
export PI_PACKET_STATE="$HOME/.local/state/pi-packet"
export SEAT_CAPS_JSON="$HOME/.local/state/pi-packet/seat-caps.json"
export PI_MODELS_JSON="$repo_root/tests/fixtures/minimal-models.json"
export PI_SEAT_LIB_CHECK_SYSTEMD=1
# SYSTEMCTL is honoured by some callers but seatlib.sh's bare `systemctl`
# invocations are intercepted via the PATH-symlinked fake above.
export SYSTEMCTL="$fake"

# Source seatlib.sh so we exercise the real function bodies.
SEAT_LIB="$repo_root/lib/litellm-seat.sh"
[[ -f "$SEAT_LIB" ]] || fail "seatlib.sh not found: $SEAT_LIB"
# shellcheck source=../lib/litellm-seat.sh
source "$SEAT_LIB"

# --- helpers --------------------------------------------------------------
now_s() { awk '{print int($1)}' /proc/uptime; }

# Monotonic-microseconds value for "N seconds ago" (the same clock
# _seat_registry_unit_live ages against).
mono_ago() {
    local n="$1"
    echo $(( ( $(now_s) - n ) * 1000000 ))
}

seed_unit() {
    local unit="$1" active="$2" sub="$3"
    printf '%s|%s\n' "$unit" "$active" >>"$active_db"
    printf '%s|%s\n' "$unit" "$sub" >>"$sub_db"
}

seed_prop() {
    local unit="$1" prop="$2" value="$3"
    printf '%s|%s|%s\n' "$unit" "$prop" "$value" >>"$props_db"
}

# Seed an active-seats registry entry. `unit` is the BARE instance name
# (e.g. pi-issue-5141-a1); seatlib.sh re-derives the systemd unit
# (pi-issue@5141-a1.service) from it at lookup time.
seed_registry() {
    local instance="$1"
    mkdir -p "$ACTIVE_SEATS_DIR"
    jq -nc --arg p devin --arg m swe-2-max --arg u "$instance" \
        '{provider:$p, model:$m, unit:$u}' \
        > "$ACTIVE_SEATS_DIR/${instance}.json"
}

# Clear the registry + fake-unit DBs between cases: a reaped file is gone
# for good and grep head -n1 means a re-seeded prop for the same unit
# would keep returning the first row, so each sub-case gets a fresh unit.
reset_case() {
    rm -f "$ACTIVE_SEATS_DIR"/pi-*.json 2>/dev/null || true
    : >"$active_db"; : >"$sub_db"; : >"$exec_db"; : >"$props_db"
}

# Assert the registry file's unit is LIVE: _seat_registry_unit_live
# returns 0 and the sweep keeps the file.
expect_live() {
    local f="$1" label="$2" rc=0
    _seat_registry_unit_live "$f" || rc=$?
    [[ "$rc" == "0" ]] \
        || fail "$label: _seat_registry_unit_live rc=$rc, expected 0 (live)"
    _seat_live_registry_files >/dev/null
    [[ -f "$f" ]] \
        || fail "$label: live registry file was reaped by the sweep"
}

# Assert the registry file's unit is STALE: _seat_registry_unit_live
# returns 1 and the sweep deletes the file.
expect_reaped() {
    local f="$1" label="$2" rc=0
    _seat_registry_unit_live "$f" || rc=$?
    [[ "$rc" == "1" ]] \
        || fail "$label: _seat_registry_unit_live rc=$rc, expected 1 (stale)"
    _seat_live_registry_files >/dev/null
    [[ ! -f "$f" ]] \
        || fail "$label: stale registry file still present after the sweep"
}

# --- (a) activating/start inside the unit's own bound is LIVE -------------
# fleet-ops#5141 core regression: activating/start IS the running state of
# a Type=oneshot worker; a worker younger than its own TimeoutStartUSec
# must keep its seat. 400s and 40min under a 45min bound.
reset_case
inst=pi-issue-5141-a1; sysunit=pi-issue@5141-a1.service
seed_unit "$sysunit" activating start
seed_prop "$sysunit" ExecMainStartTimestampMonotonic "$(mono_ago 400)"
seed_prop "$sysunit" TimeoutStartUSec "45min"
seed_registry "$inst"
expect_live "$ACTIVE_SEATS_DIR/$inst.json" \
    "(a) activating/start 400s into a 45min TimeoutStartUSec"
ok "activating/start 400s into unit bound 45min stays live"

reset_case
inst=pi-issue-5141-a2; sysunit=pi-issue@5141-a2.service
seed_unit "$sysunit" activating start
seed_prop "$sysunit" ExecMainStartTimestampMonotonic "$(mono_ago 2400)"
seed_prop "$sysunit" TimeoutStartUSec "45min"
seed_registry "$inst"
expect_live "$ACTIVE_SEATS_DIR/$inst.json" \
    "(a) activating/start 40min into a 45min TimeoutStartUSec"
ok "activating/start 40min into unit bound 45min stays live (old 300s bound would have reaped it)"

# --- (b) activating/start past its own bound is REAPED --------------------
reset_case
inst=pi-issue-5141-b; sysunit=pi-issue@5141-b.service
seed_unit "$sysunit" activating start
seed_prop "$sysunit" ExecMainStartTimestampMonotonic "$(mono_ago 3000)"
seed_prop "$sysunit" TimeoutStartUSec "45min"
seed_registry "$inst"
expect_reaped "$ACTIVE_SEATS_DIR/$inst.json" \
    "(b) activating/start 50min into a 45min TimeoutStartUSec"
ok "activating/start past its own 45min bound (50min) is reaped"

# --- (c) ExecMain=0 ages from ActiveEnter at the 300s bound ----------------
# fleet-ops#1361: the process never started, so there is no worker runtime
# to bound — only how long the unit has sat in activating.
reset_case
inst=pi-issue-5141-c; sysunit=pi-issue@5141-c.service
seed_unit "$sysunit" activating start
seed_prop "$sysunit" ExecMainStartTimestampMonotonic "0"
seed_prop "$sysunit" ActiveEnterTimestampMonotonic "$(mono_ago 360)"
seed_registry "$inst"
expect_reaped "$ACTIVE_SEATS_DIR/$inst.json" \
    "(c) activating 6min with ExecMainStartTimestampMonotonic=0"
ok "activating with no started process reaps at the 300s no-process bound"

# --- (d) activating/auto-restart fails closed at 300s ----------------------
reset_case
inst=pi-issue-5141-d; sysunit=pi-issue@5141-d.service
seed_unit "$sysunit" activating auto-restart
seed_prop "$sysunit" ExecMainStartTimestampMonotonic "$(mono_ago 360)"
seed_registry "$inst"
expect_reaped "$ACTIVE_SEATS_DIR/$inst.json" \
    "(d) activating/auto-restart 6min"
ok "activating/auto-restart reaps at the 300s bound (not the unit's TimeoutStartUSec)"

# --- (e) a shorter per-unit bound beats the fallback ----------------------
reset_case
inst=pi-issue-5141-e; sysunit=pi-issue@5141-e.service
seed_unit "$sysunit" activating start
seed_prop "$sysunit" ExecMainStartTimestampMonotonic "$(mono_ago 1200)"
seed_prop "$sysunit" TimeoutStartUSec "10min"
seed_registry "$inst"
expect_reaped "$ACTIVE_SEATS_DIR/$inst.json" \
    "(e) activating/start 20min into a 10min TimeoutStartUSec"
ok "per-unit 10min bound reaps at 20min even though 20min < 55min fallback"

# --- (f) infinity / unparseable TimeoutStartUSec -> 3300s fallback --------
reset_case
inst=pi-issue-5141-f1; sysunit=pi-issue@5141-f1.service
seed_unit "$sysunit" activating start
seed_prop "$sysunit" ExecMainStartTimestampMonotonic "$(mono_ago 3000)"
seed_prop "$sysunit" TimeoutStartUSec "infinity"
seed_registry "$inst"
expect_live "$ACTIVE_SEATS_DIR/$inst.json" \
    "(f) activating/start 50min with TimeoutStartUSec=infinity"
ok "TimeoutStartUSec=infinity falls back to 3300s: 50min stays live"

reset_case
inst=pi-issue-5141-f2; sysunit=pi-issue@5141-f2.service
seed_unit "$sysunit" activating start
seed_prop "$sysunit" ExecMainStartTimestampMonotonic "$(mono_ago 3360)"
seed_prop "$sysunit" TimeoutStartUSec "infinity"
seed_registry "$inst"
expect_reaped "$ACTIVE_SEATS_DIR/$inst.json" \
    "(f) activating/start 56min with TimeoutStartUSec=infinity"
ok "TimeoutStartUSec=infinity falls back to 3300s: 56min is reaped"

reset_case
inst=pi-issue-5141-f3; sysunit=pi-issue@5141-f3.service
seed_unit "$sysunit" activating start
seed_prop "$sysunit" ExecMainStartTimestampMonotonic "$(mono_ago 3000)"
seed_prop "$sysunit" TimeoutStartUSec "garbage"
seed_registry "$inst"
expect_live "$ACTIVE_SEATS_DIR/$inst.json" \
    "(f) activating/start 50min with unparseable TimeoutStartUSec"
ok "unparseable TimeoutStartUSec falls back to 3300s: 50min stays live"

reset_case
inst=pi-issue-5141-f4; sysunit=pi-issue@5141-f4.service
seed_unit "$sysunit" activating start
seed_prop "$sysunit" ExecMainStartTimestampMonotonic "$(mono_ago 3360)"
seed_prop "$sysunit" TimeoutStartUSec "garbage"
seed_registry "$inst"
expect_reaped "$ACTIVE_SEATS_DIR/$inst.json" \
    "(f) activating/start 56min with unparseable TimeoutStartUSec"
ok "unparseable TimeoutStartUSec falls back to 3300s: 56min is reaped"

# --- (g) drift block: the shipped unit still matches the premise ---------
# fleet-ops#5141 issue accept #3: the fallback must cover the unit's real
# TimeoutStartSec, and the whole activating/start premise only holds while
# pi-issue@ stays Type=oneshot.
unit_file="$repo_root/systemd/pi-issue@.service"
[[ -f "$unit_file" ]] || fail "missing $unit_file"
grep -qE '^Type=oneshot' "$unit_file" \
  || fail "fleet-ops#5141: systemd/pi-issue@.service no longer declares Type=oneshot — the activating/start premise of _seat_registry_unit_live needs re-review"
unit_timeout_raw="$(grep -E '^TimeoutStartSec=' "$unit_file" | tail -n1 | cut -d= -f2-)"
unit_timeout_s="$(_seat_duration_to_s "$unit_timeout_raw" || echo "")"
[[ "$unit_timeout_s" =~ ^[0-9]+$ ]] \
  || fail "fleet-ops#5141: cannot parse TimeoutStartSec=$unit_timeout_raw from pi-issue@.service"
fallback_s="$(grep -oE 'PI_SEAT_ACTIVATING_MAX_S:-[0-9]+' "$SEAT_LIB" | head -n1 | sed 's/.*:-//')"
[[ "$fallback_s" =~ ^[0-9]+$ ]] \
  || fail "fleet-ops#5141: cannot extract the PI_SEAT_ACTIVATING_MAX_S default from seatlib.sh"
(( fallback_s >= unit_timeout_s )) \
  || fail "fleet-ops#5141: PI_SEAT_ACTIVATING_MAX_S fallback ${fallback_s}s < unit TimeoutStartSec ${unit_timeout_s}s — a healthy worker would be reaped before its own start timeout"
ok "drift block: Type=oneshot and fallback ${fallback_s}s >= unit TimeoutStartSec ${unit_timeout_s}s"

echo "ALL OK: seat-registry liveness bound — per-unit TimeoutStartUSec, no-process/auto-restart 300s, infinity/unparseable 3300s fallback"
