#!/usr/bin/env bash
# tests/fleet-heartbeat-orphan-distinguish.test.sh
#
# fleet-ops#63: crash-looping workers (activating/auto-restart) held
# their claim branch and agent-in-progress label while doing no work.
# The heartbeat's orphan sweep used `--state=running` and missed both
# `activating/start` (a worker that is just now launching pi) AND
# `activating/auto-restart` (a crash-loop waiting for its next RestartSec
# window). Either case held the lane but the heartbeat treated it as
# an orphan.
#
# This test pins the fix: the orphan sweep must use
# `--state=active,activating` so it correctly identifies the unit as
# "live" (held) in both busy (start) and degraded (auto-restart) sub-
# states. A separate `auto-restart` SubState query is used to label the
# log line as DEGRADED so operators can tell the two apart.
#
# We don't run the full heartbeat tick (it depends on gh and a live
# repo). Instead we extract the orphan-sweep logic into a small helper
# that takes a fake systemctl output and verifies the classification
# decision for each state combination.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- Phase A: tier1 calls systemctl with the new --state filter ---------
# Grep the source for the broadened live-check. Catches future
# regressions to `--state=running`.
bin="$repo_root/bin/fleet-heartbeat-tier1"
[[ -x "$bin" ]] || fail "not executable: $bin"

grep -F -- '--state=active,activating' "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 missing --state=active,activating (orphan sweep must match busy AND degraded)"
# The old --state=running should NOT be the primary live-check anymore.
# It's still acceptable as a fallback for the transient fable-p* check,
# but the primary pi-issue unit check must be --state=active,activating.
grep -F -- '--state=running' "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 has no running-state check at all (the fable-p* fallback must remain)"
ok "orphan sweep uses --state=active,activating for the live-check"

# --- Phase B: simulate the four state combinations through a fake systemctl
# We can't run the full tier1 without gh + a live repo, so we reproduce
# just the live-check predicate and prove its classification.
scratch="$(mktemp -d -t heartbeat-orphan.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

fake="$scratch/fake-systemctl"
# Each line of FAKE state file is "<state>" e.g. "activating", "active".
state_file="$scratch/state"
substate_file="$scratch/substate"
: >"$state_file"
: >"$substate_file"

cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
# fake systemctl for tier1's live-check. Honours --state= (comma-separated
# list of ActiveState values) so failed/inactive units are excluded
# from --state=active,activating the same way the real systemctl does.
shift  # --user
case "$1" in
  list-units)
    shift
    declare -a wanted_states=()
    saw_state=0
    unit_pattern=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --state)
          saw_state=1
          IFS=',' read -ra wanted_states <<<"$2"
          shift 2
          ;;
        --state=*)
          saw_state=1
          IFS=',' read -ra wanted_states <<<"${1#--state=}"
          shift
          ;;
        --no-legend) shift ;;
        --*) shift ;;  # other long flags we don't model
        *) unit_pattern="$1"; shift ;;
      esac
    done
    # Echo the unit iff it's in the allowed list AND its active state
    # matches one of the requested --state= values (when set).
    if [[ -s "$FAKE_STATE" ]] && grep -qx "$unit_pattern" "$FAKE_STATE"; then
      cur=$(cat "$FAKE_STATE_VAL")
      if (( saw_state )); then
        match=0
        for s in "${wanted_states[@]}"; do
          [[ "$s" == "$cur" ]] && match=1
        done
        (( match )) || exit 0
      fi
      printf '%s loaded %s %s\tfake description\n' "$unit_pattern" "$cur" "$(cat "$FAKE_SUB_VAL")"
    fi
    exit 0
    ;;
  show)
    prop=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -p) prop="$2"; shift 2 ;;
        --value) shift ;;
        *) shift ;;
      esac
    done
    case "$prop" in
      ActiveState) cat "$FAKE_STATE_VAL" ;;
      SubState)    cat "$FAKE_SUB_VAL" ;;
      *) echo "" ;;
    esac
    exit 0
    ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake"

# classify <unit> <active_state> <sub_state>
# Returns one of: busy / degraded / orphan.
classify() {
    local unit="$1" active="$2" sub="$3"
    printf '%s\n' "$unit" >"$state_file"
    printf '%s\n' "$active" >"$FAKE_STATE_VAL"
    printf '%s\n' "$sub" >"$FAKE_SUB_VAL"
    if SYSTEMCTL="$fake" FAKE_STATE="$state_file" FAKE_STATE_VAL="$FAKE_STATE_VAL" FAKE_SUB_VAL="$FAKE_SUB_VAL" \
        "$fake" --user list-units "$unit" --state=active,activating --no-legend 2>/dev/null \
        | awk '{print $1}' | grep -qx "$unit"; then
        if [[ "$active" == "activating" && "$sub" == "auto-restart" ]]; then
            echo degraded
        else
            echo busy
        fi
    else
        echo orphan
    fi
}

export FAKE_STATE_VAL="$scratch/state_val"
export FAKE_SUB_VAL="$scratch/sub_val"
: >"$FAKE_STATE_VAL"; : >"$FAKE_SUB_VAL"

[[ "$(classify pi-issue@fleet-ops-1.service active running)" == "busy" ]] \
    || fail "active/running must classify as busy"
[[ "$(classify pi-issue@fleet-ops-2.service activating start)" == "busy" ]] \
    || fail "activating/start must classify as busy (worker is launching pi)"
[[ "$(classify pi-issue@fleet-ops-3.service activating auto-restart)" == "degraded" ]] \
    || fail "activating/auto-restart must classify as degraded (worker is between crashes, holds the lane)"
[[ "$(classify pi-issue@fleet-ops-4.service failed failed)" == "orphan" ]] \
    || fail "failed/failed must classify as orphan (StartLimitBurst tripped, OnFailure should have fired)"
[[ "$(classify pi-issue@fleet-ops-5.service inactive dead)" == "orphan" ]] \
    || fail "inactive/dead must classify as orphan"
ok "live-check classification: busy | busy | degraded | orphan | orphan"

# --- Phase C: degraded-lane reporter --------------------------------------
# Pin the auto-restart publish path. The §7 degraded-lane report iterates
# `systemctl list-units ... --state=activating` and only publishes
# SubState=auto-restart. Prove the source contains the same predicate.
grep -F "SubState" "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 must query SubState for the degraded-lane classification"
grep -F "DEGRADED-LANES" "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 must publish DEGRADED-LANES loud triage lines for auto-restart units"
grep -F "loud \"DEGRADED-LANES\"" "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 must wire DEGRADED-LANES through loud() (visible to operators)"
ok "degraded-lane reporter: SubState query + DEGRADED-LANES loud line wired"

# --- Phase D: default config covers fleet-ops -----------------------------
# The heartbeat fleet-repos.json default MUST include Nishfleet/fleet-ops
# in claim_repos so the orphan sweep actually runs against this repo
# (issue #61 surfaced the gap). The default is the source of truth —
# if the live config gets regenerated (e.g. on a fresh install), it
# must include fleet-ops.
grep -F '"Nishfleet/fleet-ops"' "$bin" >/dev/null \
  || fail "fleet-heartbeat-tier1 default claim_repos must include Nishfleet/fleet-ops (fleet-ops#61)"
# And it must be in the claim_repos list, not just somewhere in the file.
default_block=$(awk '/cat > "\$REPOS_JSON"/,/^JSON$/' "$bin")
printf '%s\n' "$default_block" | grep -F '"Nishfleet/fleet-ops"' >/dev/null \
  || fail "Nishfleet/fleet-ops must appear in the default fleet-repos.json heredoc"
printf '%s\n' "$default_block" | grep -F '"claim_repos": ["Nishfleet/fleet-ops"' >/dev/null \
  || fail 'Nishfleet/fleet-ops must lead the "claim_repos" array in the default fleet-repos.json'
ok "default claim_repos includes Nishfleet/fleet-ops (orphan sweep covers this repo)"