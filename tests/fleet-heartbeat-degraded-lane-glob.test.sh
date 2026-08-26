#!/usr/bin/env bash
# tests/fleet-heartbeat-degraded-lane-glob.test.sh
#
# fleet-ops#103: the §7 degraded-lane report used hyphen globs
# `pi-issue-*.service` / `pi-packet-*.service`, which match nothing because
# template instances are `pi-issue@<repo>-<issue>.service` (at-sign).
# This test pins the at-sign globs, the at-sign grep filter, and the case
# pattern that admits `pi-issue@*` / `pi-packet@*` / `fable-p*` units.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

bin="$repo_root/bin/fleet-heartbeat-tier1"
[[ -x "$bin" ]] || fail "not executable: $bin"

# --- Phase A: source uses at-sign globs and filter ------------------------
grep -F "list-units 'pi-issue@*.service' 'pi-packet@*.service' 'fable-p*.service'" "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 §7 must use pi-issue@*.service and pi-packet@*.service globs"
grep -F "grep -E '^(pi-issue@|pi-packet@|fable-p)'" "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 §7 filter must admit at-sign unit names"
grep -F "pi-issue@*|pi-packet@*|fable-p*)" "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 §7 case pattern must match pi-issue@*, pi-packet@*, fable-p*"
# The old hyphen globs must not be the ones used in §7.
grep -F "list-units 'pi-issue-*.service' 'pi-packet-*.service' 'fable-p*.service'" "$bin" >/dev/null \
  && fail "fleet-heartbeat-tier1 §7 must not use the old hyphen pi-issue globs" || true
ok "source uses at-sign globs, filter, and case pattern for §7"

# --- Phase B: fake systemd environment ------------------------------------
scratch="$(mktemp -d -t heartbeat-degraded.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

units_file="$scratch/units"
cat >"$units_file" <<'UNITS'
pi-issue@fleet-ops-103.service	activating	auto-restart	crash-looping pi-issue worker
pi-packet@fleet-ops-103.service	activating	auto-restart	crash-looping pi-packet worker
fable-p-foo.service	activating	auto-restart	crash-looping fable transient
pi-issue@other-1.service	activating	start	worker still launching
pi-issue-103.service	activating	auto-restart	hyphen-name unit (not a real template)
ssh.service	activating	auto-restart	unrelated unit
UNITS

loud_log="$scratch/loud.log"
: >"$loud_log"

loud() { printf '[%s] %s\n' "$1" "${*:2}" >> "$loud_log"; }
log()  { :; }

# Fake systemctl that honours --state, list-units globs, and show --property.
fake_systemctl="$scratch/systemctl"
cat >"$fake_systemctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == --user ]] && shift
cmd="${1:-}"; shift || true

case "$cmd" in
  list-units)
    state=""
    declare -a patterns=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --state) state="$2"; shift 2 ;;
        --state=*) state="${1#--state=}"; shift ;;
        --no-legend) shift ;;
        --*) shift ;;
        *) patterns+=("$1"); shift ;;
      esac
    done
    while IFS=$'\t' read -r unit active sub _desc; do
      [[ -n "$unit" ]] || continue
      [[ -n "$state" && "$active" != "$state" ]] && continue
      matched=0
      for p in "${patterns[@]}"; do
        case "$p" in
          "'pi-issue@*.service'"|pi-issue@*.service)
            [[ "$unit" == pi-issue@*.service ]] && matched=1 ;;
          "'pi-packet@*.service'"|pi-packet@*.service)
            [[ "$unit" == pi-packet@*.service ]] && matched=1 ;;
          "'fable-p*.service'"|fable-p*.service)
            [[ "$unit" == fable-p*.service ]] && matched=1 ;;
          "'pi-issue-*.service'"|pi-issue-*.service)
            [[ "$unit" == pi-issue-*.service ]] && matched=1 ;;
          "'pi-packet-*.service'"|pi-packet-*.service)
            [[ "$unit" == pi-packet-*.service ]] && matched=1 ;;
        esac
      done
      (( matched )) || continue
      printf '%s loaded %s %s\tfake description\n' "$unit" "$active" "$sub"
    done < "$FAKE_DEGRADED_UNITS"
    ;;
  show)
    prop=""
    unit=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --property=*) prop="${1#--property=}"; shift ;;
        --property|-p) prop="$2"; shift 2 ;;
        --value) shift ;;
        --*) shift ;;
        *)
          if [[ -z "$unit" ]]; then
            unit="$1"
          fi
          shift
          ;;
      esac
    done
    while IFS=$'\t' read -r u active sub _desc; do
      if [[ "$u" == "$unit" ]]; then
        case "$prop" in
          ActiveState) printf '%s\n' "$active"; exit 0 ;;
          SubState)    printf '%s\n' "$sub"; exit 0 ;;
        esac
      fi
    done < "$FAKE_DEGRADED_UNITS"
    printf 'unknown\n'
    ;;
esac
FAKE
chmod +x "$fake_systemctl"

# Fake journalctl: no journal for the test units.
fake_journalctl="$scratch/journalctl"
cat >"$fake_journalctl" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$fake_journalctl"

export FAKE_DEGRADED_UNITS="$units_file"
export PATH="$scratch:$PATH"

# --- Phase C: new at-sign globs match the crash-looping workers -----------
degraded=0
degraded_units=""
while IFS= read -r u; do
    [ -z "$u" ] && continue
    case "$u" in
        pi-issue@*|pi-packet@*|fable-p*) : ;;  # match
        *) continue ;;
    esac
    sub=$(systemctl --user show "$u" --property=SubState --value 2>/dev/null || echo unknown)
    if [ "$sub" = "auto-restart" ]; then
        degraded=$((degraded+1))
        excerpt=$(journalctl --user -u "$u" -n 1 --no-pager -q 2>/dev/null \
                    | tr '\n' ' ' | head -c 200 || true)
        if [ -z "$degraded_units" ]; then
            degraded_units="$u sub=auto-restart :: ${excerpt:-<no-journal>}"
        else
            degraded_units="${degraded_units} | $u sub=auto-restart :: ${excerpt:-<no-journal>}"
        fi
        log "7.  - $u :: auto-restart (held, no work — wait for StartLimitBurst / OnFailure)"
    fi
done < <(systemctl --user list-units 'pi-issue@*.service' 'pi-packet@*.service' 'fable-p*.service' --state=activating --no-legend 2>/dev/null \
            | awk '{print $1}' \
            | grep -E '^(pi-issue@|pi-packet@|fable-p)' || true)

[[ "$degraded" == "3" ]] \
  || fail "expected 3 degraded units, got $degraded (units: $degraded_units)"
for expected in pi-issue@fleet-ops-103.service pi-packet@fleet-ops-103.service fable-p-foo.service; do
  printf '%s' "$degraded_units" | grep -qF "$expected" \
    || fail "degraded_units missing $expected"
done
# The activating/start worker is listed but not counted as degraded.
printf '%s' "$degraded_units" | grep -qF "pi-issue@other-1.service" \
  && fail "activating/start worker should not be counted as degraded" || true
ok "new at-sign globs match pi-issue@*, pi-packet@*, and fable-p* auto-restart units"

# --- Phase D: DEGRADED-LANES loud line is published -----------------------
if [ "$degraded" -gt 0 ]; then
    loud "DEGRADED-LANES" "degraded=$degraded :: ${degraded_units}"
fi
[[ -s "$loud_log" ]] || fail "DEGRADED-LANES loud line was not written"
grep -qF "DEGRADED-LANES" "$loud_log" \
  || fail "loud log must contain DEGRADED-LANES tag"
for expected in pi-issue@fleet-ops-103.service pi-packet@fleet-ops-103.service fable-p-foo.service; do
  grep -qF "$expected" "$loud_log" \
    || fail "DEGRADED-LANES message missing $expected"
done
ok "DEGRADED-LANES loud line contains all three degraded units"

# --- Phase E: old hyphen globs miss the at-sign template instance ---------
# The same fake unit set, queried with the old hyphen globs, returns no
# pi-issue@* or pi-packet@* units. (It could still return a hyphen-named
# unit, but the fleet does not use those names for template instances.)
old_output=$(systemctl --user list-units 'pi-issue-*.service' 'pi-packet-*.service' 'fable-p*.service' --state=activating --no-legend 2>/dev/null \
               | awk '{print $1}' \
               | grep -E '^(pi-issue-|pi-packet-|fable-p)' || true)
printf '%s' "$old_output" | grep -qE '^(pi-issue@|pi-packet@)' \
  && fail "old hyphen globs must not match pi-issue@* or pi-packet@* units"
ok "old hyphen globs do not match at-sign template instances"

# --- Phase F: unrelated units are excluded by the filter ------------------
new_output=$(systemctl --user list-units 'pi-issue@*.service' 'pi-packet@*.service' 'fable-p*.service' --state=activating --no-legend 2>/dev/null \
               | awk '{print $1}' \
               | grep -E '^(pi-issue@|pi-packet@|fable-p)' || true)
printf '%s' "$new_output" | grep -qF "ssh.service" \
  && fail "unrelated units like ssh.service must not pass the degraded-lane filter" || true
ok "unrelated units are excluded from the degraded-lane report"

# --- Phase G: the case pattern rejects unrelated and hyphen-named units ---
for u in pi-issue@fleet-ops-103.service pi-packet@fleet-ops-103.service fable-p-foo.service; do
  case "$u" in
    pi-issue@*|pi-packet@*|fable-p*) : ;;
    *) fail "case pattern should admit $u" ;;
  esac
done
for u in ssh.service pi-issue-103.service pi-packet-103.service; do
  case "$u" in
    pi-issue@*|pi-packet@*|fable-p*) fail "case pattern should reject $u" ;;
    *) : ;;
  esac
done
ok "case pattern admits at-sign fleet workers and fable transients, rejects others"
