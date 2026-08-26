#!/usr/bin/env bash
# tests/seat-lib-degraded.test.sh
#
# fleet-ops#63: distinguish `active/running` (busy) from
# `activating/auto-restart` (degraded, lane held but no work) in seat
# accounting. fleet-ops#355: the enumerator must use at-sign globs
# (`pi-issue@*.service`), not hyphen (`pi-issue-*.service`), because
# template instances are `pi-issue@<inst>.service`.
#   1. unit_is_degraded() returns true only for activating/auto-restart.
#   2. count_degraded_total() counts degraded units across the
#      registry + legacy-grep paths.
#   3. count_active_total() is unchanged: it still counts auto-restart
#      units as occupying the seat (cap enforcement stays correct).
#
# Stub systemd + a scratch registry. Pure unit test — no pi, no real
# fleet, no network.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

scratch="$(mktemp -d -t seat-lib-degraded.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- stub systemd ----------------------------------------------------------
# Reads units + their active/sub states from two flat files so the test
# can drive both list-units and show by changing those files. State key
# is the unit name; values are ActiveState and SubState.
fake="$scratch/systemctl"
active_db="$scratch/active.db"
sub_db="$scratch/sub.db"
: >"$active_db"; : >"$sub_db"
cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
case "$1" in
  list-units)
    shift
    state_filter=""
    declare -a patterns=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --state=*) state_filter="${1#--state=}"; shift ;;
        --state)   state_filter="$2"; shift 2 ;;
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
      # Match against any pattern (globs).
      pat_match=0
      for pat in "${patterns[@]:-}"; do
        [[ -z "$pat" ]] && continue
        # shellcheck disable=SC2254
        case "$u" in
          $pat) pat_match=1 ;;
        esac
      done
      (( pat_match )) || continue
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
    # systemd's `show` accepts: `show -p PROP [--value] UNIT`. The UNIT is
    # the last positional; --value is a boolean flag (no arg). We need to
    # extract the prop and the unit without consuming both as args.
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
      *) echo "" ;;
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
export FAKE_EXEC_DB="$scratch/exec.db"

# Put the fake systemctl on PATH so seat-lib.sh's bare `systemctl --user ...`
# invocations hit the stub instead of the real systemd user instance.
mkdir -p "$scratch/bin"
ln -sf "$fake" "$scratch/bin/systemctl"
export PATH="$scratch/bin:$PATH"

# --- seed a minimal cap map + models.json so pick_seat is not in the way ---
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
# SYSTEMCTL is honoured by some callers but seat-lib.sh's bare `systemctl`
# invocations are intercepted via the PATH-symlinked fake above.
export SYSTEMCTL="$fake"

# Source seat-lib.sh so we exercise the real function bodies.
SEAT_LIB="$repo_root/lib/seat-lib.sh"
[[ -f "$SEAT_LIB" ]] || fail "seat-lib.sh not found: $SEAT_LIB"
# shellcheck source=../lib/seat-lib.sh
source "$SEAT_LIB"

# --- helper: seed a unit into the fake systemctl --------------------------
seed_unit() {
    local unit="$1" active="$2" sub="$3"
    printf '%s|%s\n' "$unit" "$active" >>"$active_db"
    printf '%s|%s\n' "$unit" "$sub" >>"$sub_db"
}

# --- helper: seed an active-seats registry entry -------------------------
seed_registry() {
    local instance="$1" provider="$2" model="$3" sysunit="$4"
    : "${sysunit:-$instance}"  # sysunit is consumed by the caller for clarity;
                                # seat-lib.sh re-derives the systemd unit name
                                # from the instance at lookup time.
    mkdir -p "$ACTIVE_SEATS_DIR"
    jq -nc --arg p "$provider" --arg m "$model" --arg u "$instance" \
        '{provider:$p, model:$m, unit:$u}' \
        > "$ACTIVE_SEATS_DIR/${instance}.json"
}

# --- 1: unit_is_degraded unit test ---------------------------------------
seed_unit pi-issue@fleet-ops-36.service activating auto-restart
seed_unit pi-issue@fleet-ops-31.service activating start
seed_unit pi-issue@fleet-ops-20.service active running
seed_unit pi-issue@fleet-ops-21.service failed failed
seed_unit pi-issue@fleet-ops-22.service inactive dead

unit_is_degraded pi-issue@fleet-ops-36.service \
  || fail "unit_is_degraded must return true for activating/auto-restart"
unit_is_degraded pi-issue@fleet-ops-31.service \
  && fail "unit_is_degraded must return false for activating/start (busy, not degraded)"
unit_is_degraded pi-issue@fleet-ops-20.service \
  && fail "unit_is_degraded must return false for active/running (busy)"
unit_is_degraded pi-issue@fleet-ops-21.service \
  && fail "unit_is_degraded must return false for failed (released)"
unit_is_degraded pi-issue@fleet-ops-22.service \
  && fail "unit_is_degraded must return false for inactive (released)"
ok "unit_is_degraded distinguishes auto-restart from every other state"

# --- 2: count_degraded_total counts auto-restart via the registry --------
seed_registry pi-issue-fleet-ops-36 devin swe-1-7 pi-issue@fleet-ops-36.service
seed_registry pi-issue-fleet-ops-31 devin swe-1-7 pi-issue@fleet-ops-31.service

n=$(count_degraded_total)
[[ "$n" == "1" ]] || fail "count_degraded_total: expected 1 (fleet-ops-36 only), got $n"
ok "count_degraded_total = 1 (only fleet-ops-36 in auto-restart)"

# Add another auto-restart unit via the registry; count rises.
seed_unit pi-issue@fleet-ops-75.service activating auto-restart
seed_registry pi-issue-fleet-ops-75 devin swe-1-7 pi-issue@fleet-ops-75.service
n=$(count_degraded_total)
[[ "$n" == "2" ]] || fail "count_degraded_total: expected 2 after adding fleet-ops-75, got $n"
ok "count_degraded_total = 2 after adding a second auto-restart unit"

# --- 3: count_active_total is unchanged (still counts auto-restart) ------
# fleet-ops#63 wanted "degraded, not busy" — but the seat IS held, so
# count_active_total must still include auto-restart units to keep
# pick_seat's per-model caps honest.
n=$(count_active_total)
[[ "$n" -ge 2 ]] || fail "count_active_total: expected >= 2 (degraded units still occupy seats), got $n"
ok "count_active_total includes auto-restart units (seat IS held)"

# --- 4: a 'busy' worker is NOT in count_degraded_total --------------------
# (regression guard: activating/start should not be classified as degraded.)
seed_unit pi-issue@fleet-ops-31.service activating start
# already seeded; verify count_degraded_total stays at 2, not 3.
n=$(count_degraded_total)
[[ "$n" == "2" ]] || fail "count_degraded_total: activating/start must NOT count as degraded, got $n"
ok "count_degraded_total excludes activating/start (busy, not degraded)"

# --- 5: source pins at-sign list-units globs (fleet-ops#355) --------------
# Template instances are pi-issue@<inst>.service. Hyphen globs match
# nothing. The same class as #28 (heartbeat §4) and #103 (heartbeat §7),
# in seat-lib's worker enumerator.
grep -F "list-units 'pi-issue@*.service' 'pi-packet@*.service'" "$SEAT_LIB" >/dev/null \
  || fail "seat-lib.sh must list-units pi-issue@*.service and pi-packet@*.service (at-sign)"
grep -F "list-units 'pi-issue-*.service' 'pi-packet-*.service'" "$SEAT_LIB" >/dev/null \
  && fail "seat-lib.sh must not list-units pi-issue-*.service / pi-packet-*.service (hyphen)" || true
ok "source uses at-sign list-units globs, not hyphen"

# --- 6: _seat_list_unit returns at-sign template instances ----------------
# A hyphen-named unit is seeded so a leftover hyphen glob would still
# "succeed" against the wrong name. The enumerator must ignore it.
seed_unit pi-issue-355.service active running
listed=$(_seat_list_unit)
printf '%s\n' "$listed" | grep -qxF 'pi-issue@fleet-ops-36.service' \
  || fail "_seat_list_unit must emit pi-issue@fleet-ops-36.service, got: $listed"
printf '%s\n' "$listed" | grep -qxF 'pi-issue-355.service' \
  && fail "_seat_list_unit must not emit hyphen-named pi-issue-355.service, got: $listed" || true
ok "_seat_list_unit emits at-sign template instances, not hyphen names"

# --- 7: count_degraded_total legacy path sees at-sign crash-loopers -------
# A crash-looping worker that never wrote a registry file (legacy ExecStart
# path, or a wipe of active-seats) must still count. Hyphen globs miss it.
seed_unit pi-issue@fleet-ops-355.service activating auto-restart
n=$(count_degraded_total)
[[ "$n" == "3" ]] || fail "count_degraded_total: expected 3 after unregistered pi-issue@fleet-ops-355, got $n"
ok "count_degraded_total counts an unregistered at-sign auto-restart unit"

# --- 8: class gate: no hyphen list-units in production code ---------------
# Prevents a fourth copy of this bug. Tests may mention the old glob to
# prove it does not match; lib/ and bin/ must not call it.
hyphen_hits=$(grep -R -n -E "list-units[^[:cntrl:]]*'pi-issue-\*\.service'|list-units[^[:cntrl:]]*'pi-packet-\*\.service'" \
  "$repo_root/lib" "$repo_root/bin" || true)
[[ -z "$hyphen_hits" ]] || fail "hyphen list-units glob still in production code: $hyphen_hits"
ok "lib/ and bin/ have no hyphen pi-issue/pi-packet list-units globs"

# --- 9: PI_SEAT_LIB_CHECK_SYSTEMD=0 skips live unit listing (fleet-ops#142) ---
# Offline tests must not bleed live caps. When the gate is off, _seat_list_unit
# emits nothing even if the fake systemctl would report occupying units.
PI_SEAT_LIB_CHECK_SYSTEMD=0
listed=$(_seat_list_unit)
[[ -z "$listed" ]] || fail "_seat_list_unit must emit nothing when PI_SEAT_LIB_CHECK_SYSTEMD=0, got: $listed"
ok "_seat_list_unit is silent when PI_SEAT_LIB_CHECK_SYSTEMD=0"

# --- 10: CI host lock (fleet-ops#500) -------------------------------------
# P14 has listed this file since #36/#100. The hyphen glob still survived
# #28 and #103 because nothing failed if a later workflow rewrite dropped
# the invoke line. Require the bash invoke, not a filename mention
# (fleet-ops#490). Put the same grep in seat-lib.test.sh so dropping this
# file from P14 still fails a sibling that stays listed independently.
ci_yml="$repo_root/.github/workflows/ci.yml"
grep -Fq 'bash tests/seat-lib-degraded.test.sh' "$ci_yml" \
  || fail "ci.yml verify-command must run tests/seat-lib-degraded.test.sh (fleet-ops#500)"
ok "ci.yml still invokes this file"

# Empty-host + comment-only drill (fleet-ops#366 / #490). A filename in a
# comment must not satisfy the lock. Fixture lives under $scratch so the
# existing EXIT trap cleans it up.
empty="$scratch/empty-ci.yml"
: >"$empty"
empty_hit=0
grep -Fq 'bash tests/seat-lib-degraded.test.sh' "$empty" && empty_hit=1
[[ "$empty_hit" -eq 0 ]] || fail "empty-host drill must miss (hit=$empty_hit)"
printf '# tests/seat-lib-degraded.test.sh\n' >"$empty"
comment_hit=0
grep -Fq 'bash tests/seat-lib-degraded.test.sh' "$empty" && comment_hit=1
[[ "$comment_hit" -eq 0 ]] \
  || fail "comment-only filename must not satisfy the #500 lock (hit=$comment_hit)"
weak_hit=0
grep -Fq 'tests/seat-lib-degraded.test.sh' "$empty" && weak_hit=1
[[ "$weak_hit" -eq 1 ]] \
  || fail "comment-only drill fixture is broken (weak grep should match filename)"
ok "CI lock requires bash invoke line; comment-only filename is not enough"
