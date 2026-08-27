#!/usr/bin/env bash
# tests/seat-lib-org-reserve.test.sh
#
# Org/repair packets must not starve issue intake. count_active_total
# charges pi-issue-* at full value and charges org units
# (pi-packet-*, alert-repair-*, pi-job-*, ad-hoc pi-systemd-run) against
# a reserve of 2, so four long-running org packets cannot fill a 4-slot
# RAM cap and skip every ready issue.
#
# Offline: scratch registry + optional stub systemd. No live units.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
SEAT_LIB="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$SEAT_LIB" ]] || fail "seat-lib.sh not found: $SEAT_LIB"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t seat-lib-org-reserve.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export PI_PACKET_STATE="$scratch/state"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_MODELS_JSON="$scratch/models.json"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export HOME="$scratch/home"
mkdir -p "$PI_PACKET_STATE/active-seats" "$PI_SEAT_HEALTH_LEDGER_DIR" "$HOME"
ACTIVE_SEATS_DIR="$PI_PACKET_STATE/active-seats"

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "org_reserve": 2,
  "providers": {
    "devin": { "cap": 4, "class": "prepaid-quota", "models": { "glm-5-2": 3, "swe-1-7": 4 } }
  },
  "free_providers_in_order": [],
  "prepaid_providers_in_order": ["devin"]
}
JSON
echo '{"providers":{}}' >"$PI_MODELS_JSON"

# --- source after env is set so STATE_DIR / SEAT_CAPS_JSON bind -----------
# shellcheck disable=SC1090
. "$SEAT_LIB"

seed_registry() {
    local instance="$1" provider="${2:-devin}" model="${3:-glm-5-2}"
    mkdir -p "$ACTIVE_SEATS_DIR"
    jq -nc --arg p "$provider" --arg m "$model" --arg u "$instance" \
        '{provider:$p, model:$m, unit:$u}' \
        > "$ACTIVE_SEATS_DIR/${instance}.json"
}

clear_registry() {
    rm -f "$ACTIVE_SEATS_DIR"/*.json
}

# --- helpers exist --------------------------------------------------------
type -t count_active_issue >/dev/null || fail "count_active_issue missing"
type -t count_active_org >/dev/null || fail "count_active_org missing"
type -t org_reserve >/dev/null || fail "org_reserve missing"
ok "helpers exist: count_active_issue, count_active_org, org_reserve"

# --- org_reserve reads seat-caps.json (default 2) -------------------------
r=$(org_reserve)
[[ "$r" == "2" ]] || fail "org_reserve: expected 2 from fixture, got $r"
ok "org_reserve = 2 from seat-caps.json"

# --- 0 org + 2 issues → total 2 ------------------------------------------
clear_registry
seed_registry pi-issue-fleet-ops-1
seed_registry pi-issue-fleet-ops-2
[[ "$(count_active_issue)" == "2" ]] || fail "issue count: expected 2, got $(count_active_issue)"
[[ "$(count_active_org)" == "0" ]] || fail "org count: expected 0, got $(count_active_org)"
[[ "$(count_active_total)" == "2" ]] || fail "total: expected 2 (issues only), got $(count_active_total)"
ok "2 issues + 0 org → total 2"

# --- 4 org + 0 issues → total 2 (reserve cap) ----------------------------
clear_registry
seed_registry pi-packet-repair-1
seed_registry pi-packet-repair-2
seed_registry pi-packet-repair-3
seed_registry pi-packet-repair-4
[[ "$(count_active_issue)" == "0" ]] || fail "issue count: expected 0, got $(count_active_issue)"
[[ "$(count_active_org)" == "4" ]] || fail "org count: expected 4, got $(count_active_org)"
[[ "$(count_active_total)" == "2" ]] || fail "total: expected 2 (org reserve), got $(count_active_total)"
ok "0 issues + 4 org → total 2 (reserve), so intake still has slots"

# --- 4 org + 2 issues → total 4 (2 issues + 2 org charge) ----------------
seed_registry pi-issue-fleet-ops-1
seed_registry pi-issue-fleet-ops-2
[[ "$(count_active_issue)" == "2" ]] || fail "issue count: expected 2, got $(count_active_issue)"
[[ "$(count_active_org)" == "4" ]] || fail "org count: expected 4, got $(count_active_org)"
[[ "$(count_active_total)" == "4" ]] || fail "total: expected 4 (2+2), got $(count_active_total)"
ok "2 issues + 4 org → total 4 (issues + reserve), not 6"

# --- 1 org + 2 issues → total 3 (org under reserve) ----------------------
clear_registry
seed_registry pi-issue-fleet-ops-1
seed_registry pi-issue-fleet-ops-2
seed_registry pi-packet-repair-1
[[ "$(count_active_total)" == "3" ]] || fail "total: expected 3 (2+1), got $(count_active_total)"
ok "2 issues + 1 org → total 3"

# --- pick_seat accounting is unchanged: org still occupies its seat -----
# count_active_on_seat must still see the packet worker on the provider,
# or a second org packet could pile onto the same seat.
n=$(count_active_on_seat devin glm-5-2)
[[ "$n" -ge 1 ]] || fail "count_active_on_seat must still count org packets, got $n"
ok "count_active_on_seat still counts org packets (per-seat cap stays honest)"

# --- org_reserve=0 from config charges no org against intake -------------
jq '.org_reserve = 0' "$SEAT_CAPS_JSON" >"$scratch/caps0.json"
mv "$scratch/caps0.json" "$SEAT_CAPS_JSON"
_seat_caps_loaded=0
load_seat_caps || fail "load_seat_caps after org_reserve=0"
[[ "$(org_reserve)" == "0" ]] || fail "org_reserve: expected 0, got $(org_reserve)"
[[ "$(count_active_org)" == "1" ]] || fail "org still 1, got $(count_active_org)"
[[ "$(count_active_total)" == "2" ]] || fail "reserve 0: total should be issues only (2), got $(count_active_total)"
ok "org_reserve=0 charges no org against intake"

# restore default
jq '.org_reserve = 2' "$SEAT_CAPS_JSON" >"$scratch/caps2.json"
mv "$scratch/caps2.json" "$SEAT_CAPS_JSON"
_seat_caps_loaded=0
load_seat_caps || fail "load_seat_caps restore"

# --- systemd path: alert-repair + pi-job + description-stamped ad-hoc ----
# Stub systemctl so we can count org units that never write a registry file
# (alert-repair-*, pi-job-*, pi-systemd-run --unit).
fake="$scratch/systemctl"
active_db="$scratch/active.db"
desc_db="$scratch/desc.db"
exec_db="$scratch/exec.db"
: >"$active_db"; : >"$desc_db"; : >"$exec_db"
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
        --no-legend|--plain) shift ;;
        *) patterns+=("$1"); shift ;;
      esac
    done
    while IFS= read -r u; do
      [[ -n "$u" ]] || continue
      active=$(grep -F "$u|" "$FAKE_ACTIVE_DB" | head -n1 | cut -d'|' -f2)
      [[ -z "$active" ]] && continue
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
      printf '%s loaded %s running\tfake description\n' "$u" "$active"
    done < <(awk -F'|' 'NR>0 {print $1}' "$FAKE_ACTIVE_DB" | sort -u)
    exit 0
    ;;
  show)
    unit=""
    prop=""
    value_only=0
    shift || true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --property=*) prop="${1#--property=}"; shift ;;
        -p|--property) prop="$2"; shift 2 ;;
        --value) value_only=1; shift ;;
        *.service) unit="$1"; shift ;;
        *) shift ;;
      esac
    done
    [[ -n "$unit" ]] || exit 0
    case "$prop" in
      Description)
        desc=$(grep -F "$unit|" "$FAKE_DESC_DB" | head -n1 | cut -d'|' -f2)
        if (( value_only )); then printf '%s\n' "${desc:-}"; else printf 'Description=%s\n' "${desc:-}"; fi
        ;;
      ExecStart)
        exec=$(grep -F "$unit|" "$FAKE_EXEC_DB" 2>/dev/null | head -n1 | cut -d'|' -f2-)
        if (( value_only )); then printf '%s\n' "${exec:-}"; else printf 'ExecStart=%s\n' "${exec:-}"; fi
        ;;
      ActiveState)
        active=$(grep -F "$unit|" "$FAKE_ACTIVE_DB" | head -n1 | cut -d'|' -f2)
        if (( value_only )); then printf '%s\n' "${active:-inactive}"; else printf 'ActiveState=%s\n' "${active:-inactive}"; fi
        ;;
      *)
        if (( value_only )); then printf '0\n'; else printf '%s=0\n' "$prop"; fi
        ;;
    esac
    exit 0
    ;;
  is-active)
    u="${2:-$1}"
    active=$(grep -F "$u|" "$FAKE_ACTIVE_DB" | head -n1 | cut -d'|' -f2)
    [[ "$active" == "active" || "$active" == "activating" ]] && { echo "$active"; exit 0; }
    echo inactive
    exit 3
    ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$fake"
export PATH="$scratch:$PATH"
hash -r
export FAKE_ACTIVE_DB="$active_db"
export FAKE_DESC_DB="$desc_db"
export FAKE_EXEC_DB="$exec_db"

seed_unit() {
    local u="$1" active="${2:-activating}" desc="${3:-}"
    echo "${u}|${active}" >>"$active_db"
    if [[ -n "$desc" ]]; then
        echo "${u}|${desc}" >>"$desc_db"
    fi
    return 0
}

seed_exec() {
    local u="$1" exec="$2"
    echo "${u}|${exec}" >>"$exec_db"
    return 0
}

export PI_SEAT_LIB_CHECK_SYSTEMD=1
clear_registry
: >"$active_db"; : >"$desc_db"; : >"$exec_db"
seed_unit alert-repair-load-storm.service activating
seed_unit pi-job-20260827T120000Z-1.service activating
seed_unit seat-cap-fix-20260827.service activating "Pi packet seat-cap-fix-20260827 (session-independent)"
seed_unit pi-issue@fleet-ops-99.service activating

# fleet-ops#1155: units are counted by ExecStart "pi --print" content.
seed_exec alert-repair-load-storm.service 'pi --print --provider devin --model glm-5-2'
seed_exec pi-job-20260827T120000Z-1.service 'pi --print --provider devin --model swe-1-7'
seed_exec seat-cap-fix-20260827.service 'pi --print --provider devin --model glm-5-2'
seed_exec pi-issue@fleet-ops-99.service ''

seed_registry pi-issue-fleet-ops-99

org=$(count_active_org)
[[ "$org" == "3" ]] || fail "systemd org units: expected 3 (alert-repair + pi-job + description ad-hoc), got $org"
issue=$(count_active_issue)
[[ "$issue" == "1" ]] || fail "issue still 1 via registry, got $issue"
total=$(count_active_total)
[[ "$total" == "3" ]] || fail "total: expected 1 issue + min(3,2) org = 3, got $total"
ok "systemd org units (alert-repair, pi-job, description-stamped) charge reserve, not full"

# a 4th org unit still charges only 2
seed_unit alert-repair-other.service activating
seed_exec alert-repair-other.service 'pi --print --provider devin --model glm-5-2'
org=$(count_active_org)
[[ "$org" == "4" ]] || fail "expected 4 org units, got $org"
total=$(count_active_total)
[[ "$total" == "3" ]] || fail "4 org still charge 2: expected total 3, got $total"
ok "4 systemd org units still charge only the reserve of 2"

# --- intake tick documents the split -------------------------------------
tick="$repo_root/lib/pi-intake-tick.sh"
grep -q 'count_active_total' "$tick" || fail "pi-intake-tick.sh must still call count_active_total"
grep -q 'count_active_issue\|org_reserve\|count_active_org' "$tick" \
  || fail "pi-intake-tick.sh must name the issue/org split in the capacity line"
ok "pi-intake-tick.sh reports the issue/org split"

# --- intake.md prompt matches --------------------------------------------
prompt="$repo_root/prompts/intake.md"
grep -q 'org_reserve\|org/repair\|reserve of 2' "$prompt" \
  || fail "prompts/intake.md must document that org packets charge a reserve of 2"
ok "prompts/intake.md documents the org reserve"

echo "ALL OK: org reserve of 2 cannot starve issue intake"
