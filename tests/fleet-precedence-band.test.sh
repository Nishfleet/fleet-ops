#!/usr/bin/env bash
# tests/fleet-precedence-band.test.sh
#
# Proves the precedence-band canary (fleet-ops#1223) offline:
#   1. Production policy + surge phase + 0 units -> exit 0, OK.
#   2. Missing policy -> exit 1.
#   3. machinery_max_pct > 30 -> exit 1.
#   4. product_min_pct < 70 -> exit 1.
#   5. owner != weekly-fleet-review -> exit 1.
#   6. product_front missing or malformed -> exit 1.
#   7. Surge phase: non-leverage fleet-ops claim -> exit 1.
#   8. Surge phase: leverage fleet-ops claim only -> exit 0.
#   9. Band phase: machinery share over cap -> exit 1.
#  10. Band phase: machinery share at cap -> exit 0.
#  11. Ratchet: loosening without wfr_waiver_on -> exit 1.
#  12. Ratchet: loosening with fresh waiver -> exit 0.
#  13. Ratchet: re-stamped waiver rejected.
#  14. Heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it.
#  15. Matrix row is enforced with mechanism+proof.
#  19. Band floor: machinery=0, product=1..3 allows one repair lane (fleet-ops#1452).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-precedence-band-canary"
lib="$repo_root/lib/pi-packet/precedence-band-canary.py"
shlib="$repo_root/lib/precedence-band.sh"
policy="$repo_root/config/precedence-band.json"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
matrix="$repo_root/config/rule-enforcement.json"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$shlib" ]] || fail "missing $shlib"
[[ -f "$policy" ]] || fail "missing $policy"
[[ -f "$tier1" ]] || fail "missing $tier1"
[[ -f "$matrix" ]] || fail "missing $matrix"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

scratch="$(mktemp -d -t precedence-band.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"

clean_policy() {
  cat >"$scratch/policy.json"
}

base_policy_json() {
  cat <<'JSON'
{
  "description": "test",
  "cutoff_utc": "2026-08-28T02:30:00Z",
  "machinery_max_pct": 30,
  "product_min_pct": 70,
  "machinery_repo": "fleet-ops",
  "owner": "weekly-fleet-review",
  "product_front": [
    "0509#1299",
    "0509#1302",
    "fleet-ops#1198"
  ],
  "surge_leverage_issues": [1204, 1134, 1010, 1149, 1155, 1157, 1133, 1167, 1163, 1146, 1135, 1223]
}
JSON
}

# Default NOW for run_canary: a fixed pre-cutoff instant. The base policy's
# cutoff_utc is 2026-08-28T02:30:00Z, so 2026-08-28T01:00:00Z lands in the
# surge phase. Pinning the default (instead of leaving it empty = live clock)
# makes the whole drill time-invariant: a scenario that forgets to pass a
# phase-specific NOW runs in surge phase by construction, never in whatever
# phase real time happens to be in. This is the mechanical prevention for the
# fleet-ops#1444 class — #1446 pinned scenarios 7/8 reactively; this default
# pins every future scenario too. Scenario 18 below proves the default holds.
DEFAULT_NOW="2026-08-28T01:00:00Z"

run_canary() {
  FLEET_PRECEDENCE_BAND_POLICY="${1:-$scratch/policy.json}" \
  FLEET_PRECEDENCE_UNITS_FILE="${2:-$scratch/units.txt}" \
  FLEET_PRECEDENCE_BAND_PRIOR="${3:-$scratch/missing.prior.json}" \
  PRECEDENCE_BAND_NOW="${4:-$DEFAULT_NOW}" \
  FLEET_HEARTBEAT_TRIAGE="$triage" \
  "$bin" 2>&1
}

# --- 1. production: surge phase, 0 units ------------------------------------
base_policy_json | clean_policy
: >"$scratch/units.txt"
set +e
out=$(run_canary)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario1: production must be clean, got rc=$rc ($out)"
grep -q 'PRECEDENCE-BAND-OK' <<<"$out" || fail "scenario1: production must log OK ($out)"
ok "scenario1: production policy+surge+no-units is clean"

# --- 2. missing policy ------------------------------------------------------
set +e
out=$(run_canary "$scratch/missing.json")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario2: missing policy must exit 1, got $rc ($out)"
grep -q 'policy missing' <<<"$out" || fail "scenario2: must name policy missing ($out)"
ok "scenario2: missing policy is fail-loud"

# --- 3. machinery_max_pct > 30 ----------------------------------------------
base_policy_json | jq '.machinery_max_pct = 60 | .product_min_pct = 40' | clean_policy
set +e
out=$(run_canary)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario3: machinery_max_pct > 30 must exit 1, got $rc ($out)"
grep -q 'machinery_max_pct' <<<"$out" || fail "scenario3: must name machinery_max_pct ($out)"
ok "scenario3: machinery cap is locked to <= 30 (ledger ceiling)"

# --- 4. product_min_pct < 70 ------------------------------------------------
base_policy_json | jq '.product_min_pct = 50' | clean_policy
set +e
out=$(run_canary)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario4: product_min_pct < 70 must exit 1, got $rc ($out)"
grep -q 'product_min_pct' <<<"$out" || fail "scenario4: must name product_min_pct ($out)"
ok "scenario4: product floor is locked to >= 70 (ledger floor)"

# --- 5. owner != weekly-fleet-review ----------------------------------------
base_policy_json | jq '.owner = "nish"' | clean_policy
set +e
out=$(run_canary)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario5: owner != weekly-fleet-review must exit 1, got $rc ($out)"
grep -q 'weekly-fleet-review' <<<"$out" || fail "scenario5: must name weekly-fleet-review ($out)"
ok "scenario5: only the Weekly Fleet Review owns the dial"

# --- 6. product_front malformed --------------------------------------------
base_policy_json | jq '.product_front = ["bad-row", "0509#x"]' | clean_policy
set +e
out=$(run_canary)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario6: malformed product_front must exit 1, got $rc ($out)"
grep -q 'product_front' <<<"$out" || fail "scenario6: must name product_front ($out)"
ok "scenario6: product_front entries must be REPO#NUMBER"

# --- 7. surge phase, non-leverage fleet-ops claim ---------------------------
base_policy_json | clean_policy
cat >"$scratch/units.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@fleet-ops-1234.service
UNITS
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/missing.prior.json" "2026-08-28T01:00:00Z")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario7: surge non-leverage must exit 1, got $rc ($out)"
grep -q 'surge-phase non-leverage' <<<"$out" || fail "scenario7: must name surge-phase non-leverage ($out)"
ok "scenario7: surge refuses a non-leverage fleet-ops claim"

# --- 8. surge phase, leverage fleet-ops claim only --------------------------
cat >"$scratch/units.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@fleet-ops-1223.service
UNITS
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/missing.prior.json" "2026-08-28T01:00:00Z")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario8: surge leverage-only must exit 0, got $rc ($out)"
grep -q 'PRECEDENCE-BAND-OK' <<<"$out" || fail "scenario8: must log OK ($out)"
ok "scenario8: surge accepts leverage-only fleet-ops claims"

# --- 9. band phase, machinery share over cap --------------------------------
cat >"$scratch/units.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@0509-1302.service
pi-issue@0509-9999.service
pi-issue@fleet-ops-1223.service
pi-issue@fleet-ops-101.service
pi-issue@fleet-ops-102.service
pi-issue@fleet-ops-103.service
UNITS
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/missing.prior.json" "2026-08-28T03:30:00Z")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario9: band over-cap must exit 1, got $rc ($out)"
grep -q 'over the cap' <<<"$out" || fail "scenario9: must name over the cap ($out)"
ok "scenario9: band rejects live machinery share > cap"

# --- 10. band phase, machinery share at cap ---------------------------------
cat >"$scratch/units.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@0509-1302.service
pi-issue@0509-9999.service
pi-issue@0509-8888.service
pi-issue@0509-7777.service
pi-issue@0509-6666.service
pi-issue@0509-5555.service
pi-issue@fleet-ops-1223.service
pi-issue@fleet-ops-101.service
pi-issue@fleet-ops-102.service
UNITS
# 3 machinery / 10 total = 30% = cap (allowed)
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/missing.prior.json" "2026-08-28T03:30:00Z")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario10: band at-cap must exit 0, got $rc ($out)"
grep -q 'PRECEDENCE-BAND-OK' <<<"$out" || fail "scenario10: must log OK ($out)"
ok "scenario10: band accepts machinery share == cap"

# --- 10b. band phase, one repair lane at low-n is the floor, not drift ------
# fleet-ops#1452: 1 machinery + 1 product is 50% > 30%, but that is the
# machinery floor (one repair lane always allowed), not over-cap drift.
# Without this, allowing the floor in allow_claim would immediately trip
# the canary the moment live units are wired in.
cat >"$scratch/units.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@fleet-ops-1452.service
UNITS
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/missing.prior.json" "2026-08-28T03:30:00Z")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario10b: one repair lane at low-n must exit 0, got $rc ($out)"
grep -q 'PRECEDENCE-BAND-OK' <<<"$out" || fail "scenario10b: must log OK ($out)"
ok "scenario10b: canary accepts the one-repair-lane floor (1 machinery + 1 product)"

cat >"$scratch/units.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@0509-1302.service
pi-issue@fleet-ops-1452.service
UNITS
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/missing.prior.json" "2026-08-28T03:30:00Z")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario10c: 1 machinery + 2 product must exit 0, got $rc ($out)"
ok "scenario10c: canary accepts the one-repair-lane floor (1 machinery + 2 product)"

# Two repair lanes at low-n is still over-cap. The floor is one lane.
cat >"$scratch/units.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@fleet-ops-1452.service
pi-issue@fleet-ops-101.service
UNITS
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/missing.prior.json" "2026-08-28T03:30:00Z")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario10d: 2 machinery + 1 product must exit 1, got $rc ($out)"
grep -q 'over the cap' <<<"$out" || fail "scenario10d: must name over the cap ($out)"
ok "scenario10d: canary still rejects a second repair lane at low-n"

# --- 10e. band phase, all-machinery with ZERO live product is NOT drift ------
# fleet-ops#1421: the rent-paying band is a RATIO among live units. When zero
# product units are live (all product work blocked-on / between intake ticks)
# there is no product share to protect, so 100% machinery is the only possible
# value and the ratio is undefined. Flagging "100% > 30%" here is the same
# disease as the surge-leverage-exhaustion false positive (#1431): a watcher
# misreading a legitimate intake state as drift. The live trip on 2026-08-29
# (10 machinery / 0 product, all 7 0509 agent-ready issues blocked-on) cried
# wolf for ~1h and would have auto-filed a false starvation cluster. Product
# intake health is the undersaturation watchdog's job, not this canary's.
cat >"$scratch/units.txt" <<'UNITS'
pi-issue@fleet-ops-1421.service
pi-issue@fleet-ops-1431.service
pi-issue@fleet-ops-1448.service
pi-issue@fleet-ops-1452.service
pi-issue@fleet-ops-101.service
pi-issue@fleet-ops-102.service
pi-issue@fleet-ops-103.service
pi-issue@fleet-ops-104.service
pi-issue@fleet-ops-105.service
pi-issue@fleet-ops-106.service
UNITS
# 10 machinery / 0 product = 100% machinery > 30% cap, but product_count == 0
# so the ratio is undefined -> legitimate, must exit 0.
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/missing.prior.json" "2026-08-28T03:30:00Z")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario10e: all-machinery + 0 live product must exit 0, got $rc ($out)"
grep -q 'PRECEDENCE-BAND-OK' <<<"$out" || fail "scenario10e: must log OK ($out)"
ok "scenario10e: canary accepts 100% machinery when zero product is live (ratio undefined, fleet-ops#1421)"

# --- 10f. band phase, machinery crowding out LIVE product is still drift -----
# Negative control for 10e: the moment even ONE product unit is live, the
# ratio is defined and 100%-ish machinery over the cap is real drift again.
cat >"$scratch/units.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@fleet-ops-1421.service
pi-issue@fleet-ops-1431.service
pi-issue@fleet-ops-1448.service
pi-issue@fleet-ops-1452.service
pi-issue@fleet-ops-101.service
pi-issue@fleet-ops-102.service
pi-issue@fleet-ops-103.service
pi-issue@fleet-ops-104.service
pi-issue@fleet-ops-105.service
UNITS
# 9 machinery / 10 total = 90% > 30% cap, product_count == 1 -> real drift.
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/missing.prior.json" "2026-08-28T03:30:00Z")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario10f: 9 machinery + 1 live product must exit 1, got $rc ($out)"
grep -q 'over the cap' <<<"$out" || fail "scenario10f: must name over the cap ($out)"
ok "scenario10f: canary still rejects machinery crowding out LIVE product (10e does not weaken ratio enforcement)"

# --- 11. ratchet: loosening without wfr_waiver_on ---------------------------
base_policy_json | jq '.machinery_max_pct = 30' | clean_policy
cat >"$scratch/prior.json" <<'JSON'
{
  "machinery_max_pct": 20,
  "product_min_pct": 80,
  "wfr_waiver_on": "2026-08-26T18:00:00Z"
}
JSON
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/prior.json" "")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario11: loosening without waiver must exit 1, got $rc ($out)"
grep -q 'wfr_waiver_on is missing' <<<"$out" || fail "scenario11: must name wfr_waiver_on is missing ($out)"
ok "scenario11: ratchet rejects loosening without a WFR waiver"

# --- 12. ratchet: loosening with fresh waiver -------------------------------
base_policy_json | jq '. + {"wfr_waiver_on": "2026-08-27T18:00:00Z"}' | clean_policy
: >"$scratch/units.txt"
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/prior.json" "")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario12: waiver with fresh date must exit 0, got $rc ($out)"
grep -q 'PRECEDENCE-BAND-OK' <<<"$out" || fail "scenario12: must log OK ($out)"
ok "scenario12: ratchet accepts a fresh, monotonically-later WFR waiver"

# --- 13. ratchet: re-stamped waiver rejected --------------------------------
cat >"$scratch/prior2.json" <<'JSON'
{
  "machinery_max_pct": 25,
  "product_min_pct": 75,
  "wfr_waiver_on": "2026-08-27T18:00:00Z"
}
JSON
base_policy_json | jq '. + {"wfr_waiver_on": "2026-08-27T18:00:00Z"}' | clean_policy
set +e
out=$(run_canary "$scratch/policy.json" "$scratch/units.txt" "$scratch/prior2.json" "")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario13: re-stamped waiver must exit 1, got $rc ($out)"
grep -q 're-stamp forbidden' <<<"$out" || fail "scenario13: must name re-stamp forbidden ($out)"
ok "scenario13: ratchet rejects a re-stamped WFR waiver"

# --- 14. heartbeat + MANIFEST -----------------------------------------------
grep -F 'fleet-precedence-band-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-precedence-band-canary"
grep -F 'precedence_band_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture precedence_band_canary_rc"
grep -F 'if [ "${precedence_band_canary_rc:-0}" -ne 0 ]; then' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the precedence-band gate fails loud"
grep -F 'exit "$precedence_band_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit with precedence_band_canary_rc when the gate fails loud"
grep -F 'require_manifest_helper "$PRECEDENCE_BAND_CANARY_BIN"' "$tier1" >/dev/null \
  || fail "tier1 precedence-band block must call require_manifest_helper"
grep -F 'HELPER-MISSING' "$tier1" >/dev/null \
  || fail "tier1 must emit HELPER-MISSING"
grep -Fxq 'bin/fleet-precedence-band-canary /home/nish/.local/bin/fleet-precedence-band-canary' "$manifest" \
  || fail "MANIFEST must install bin/fleet-precedence-band-canary"
grep -Fxq 'lib/pi-packet/precedence-band-canary.py /home/nish/.local/lib/pi-packet/precedence-band-canary.py' "$manifest" \
  || fail "MANIFEST must install lib/pi-packet/precedence-band-canary.py"
grep -Fxq 'config/precedence-band.json /home/nish/.local/state/pi-packet/precedence-band.json' "$manifest" \
  || fail "MANIFEST must install config/precedence-band.json"
grep -Fxq 'lib/precedence-band.sh /home/nish/.local/lib/pi-packet/precedence-band.sh' "$manifest" \
  || fail "MANIFEST must install lib/precedence-band.sh"
ok "scenario14: heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it"

# --- 15. matrix row ---------------------------------------------------------
jq -e '.rules[] | select(.id == "led-2026-08-27-precedence-band-overnight-machinery-surge-nish" and .status == "enforced")' \
  "$matrix" >/dev/null \
  || fail "matrix row must be status=enforced"
mech=$(jq -r '.rules[] | select(.id == "led-2026-08-27-precedence-band-overnight-machinery-surge-nish") | .mechanism' "$matrix")
printf '%s\n' "$mech" | grep -q 'fleet-precedence-band-canary' \
  || fail "mechanism must name fleet-precedence-band-canary (got: $mech)"
printf '%s\n' "$mech" | grep -qE 'machinery_max_pct(<=|<)30' \
  || fail "mechanism must lock machinery to <=30% (got: $mech)"
printf '%s\n' "$mech" | grep -qE 'product_min_pct(>=|>)70' \
  || fail "mechanism must lock product to >=70% (got: $mech)"
printf '%s\n' "$mech" | grep -qE 'priority|emergency' \
  || fail "mechanism must lock priority or emergency label escape (got: $mech)"
printf '%s\n' "$mech" | grep -q 'weekly-fleet-review' \
  || fail "mechanism must name weekly-fleet-review as the dial owner (got: $mech)"
printf '%s\n' "$mech" | grep -q 'tighten' \
  || fail "mechanism must lock the tighten-only ratchet (got: $mech)"
proof=$(jq -r '.rules[] | select(.id == "led-2026-08-27-precedence-band-overnight-machinery-surge-nish") | .proof' "$matrix")
printf '%s\n' "$proof" | grep -q 'bin/fleet-precedence-band-canary' \
  || fail "proof must name the canary (got: $proof)"
printf '%s\n' "$proof" | grep -q 'tests/fleet-precedence-band.test.sh' \
  || fail "proof must name this test (got: $proof)"
printf '%s\n' "$proof" | grep -q 'lib/precedence-band.sh' \
  || fail "proof must name the bash library (got: $proof)"
printf '%s\n' "$proof" | grep -q 'lib/pi-intake-tick.sh' \
  || fail "proof must name the intake-tick hookup (got: $proof)"
printf '%s\n' "$mech" | grep -q 'pi-intake-tick' \
  || fail "mechanism must name pi-intake-tick (got: $mech)"
printf '%s\n' "$mech" | grep -q 'machinery floor' \
  || fail "mechanism must name the machinery floor (fleet-ops#1452) (got: $mech)"
printf '%s\n' "$proof" | grep -q 'fleet-ops#1452' \
  || fail "proof must cite fleet-ops#1452 (got: $proof)"
ok "scenario15: matrix row is enforced with mechanism+proof"

# --- 16. intake-tick sources the band and skips BEFORE the claim push -------
tick="$repo_root/lib/pi-intake-tick.sh"
[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
grep -F '. "$PRECEDENCE_BAND_LIB"' "$tick" >/dev/null \
  || fail "intake-tick must source PRECEDENCE_BAND_LIB"
grep -F 'precedence_band_allow_claim' "$tick" >/dev/null \
  || fail "intake-tick must call precedence_band_allow_claim"
grep -F 'skipped-precedence-band' "$tick" >/dev/null \
  || fail "intake-tick must log skipped-precedence-band"
grep -F 'precedence_band_pending_clear' "$tick" >/dev/null \
  || fail "intake-tick must clear the floor latch at start (fleet-ops#1452)"
allow_line=$(grep -n 'precedence_band_allow_claim' "$tick" | head -1 | cut -d: -f1)
push_line=$(grep -n 'push --force-with-lease' "$tick" | head -1 | cut -d: -f1)
[[ -n "$allow_line" && -n "$push_line" ]] || fail "intake-tick must contain allow_claim and claim push"
[[ "$allow_line" -lt "$push_line" ]] \
  || fail "allow_claim (line $allow_line) must run before claim push (line $push_line)"
ok "scenario16: intake-tick sources the band and skips before the claim push"

grep -F '_surge_has_leverage' "$tick" >/dev/null \
  || fail "intake-tick must carry the surge-exhaustion probe (fleet-ops#1431)"
grep -F 'surge floor can admit' "$tick" >/dev/null \
  || fail "intake-tick must relax the skip to reach the surge floor (fleet-ops#1431)"
ok "scenario16b: intake-tick relaxes the surge skip when surge work is exhausted (fleet-ops#1431)"

# --- 17. allow_claim: surge / product / band / multiplier -------------------
# shellcheck source=/dev/null
. "$shlib"
base_policy_json | clean_policy
export PRECEDENCE_BAND_JSON="$scratch/policy.json"
export PRECEDENCE_BAND_NOW="2026-08-27T12:00:00Z"
export BAND_PENDING_FILE="$scratch/pending.latch"
rm -f "$BAND_PENDING_FILE"
: >"$scratch/units.txt"
export FLEET_PRECEDENCE_UNITS_FILE="$scratch/units.txt"

set +e
# 17a: non-leverage WITH a live machinery worker running is still surge-skipped
# (the fleet-ops queue is not hard-stalled — a machinery lane is in flight).
: >"$scratch/units.txt"; printf 'pi-issue@fleet-ops-101.service\n' >>"$scratch/units.txt"
reason=$(precedence_band_allow_claim fleet-ops 9999 '[]' "" "")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario17a: surge non-leverage with live machinery must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-surge-leverage" ]] \
  || fail "scenario17a: expected skip-surge-leverage, got $reason"
ok "scenario17a: surge skips a non-leverage fleet-ops claim when a machinery lane is already live"

# 17a2 (fleet-ops#1431): surge non-leverage with ZERO live machinery gets exactly
# one floor lane (the surge floor) so the queue can never hard-stall through a
# surge window when no surge_leverage_issue is claimable.
set +e
export BAND_PENDING_FILE="$scratch/pending.latch"
rm -f "$BAND_PENDING_FILE"
: >"$scratch/units.txt"
reason=$(precedence_band_allow_claim fleet-ops 9998 '[]' "" "")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17a2: surge floor must rc=0, got $rc ($reason)"
[[ "$reason" == "allow-surge-floor" ]] \
  || fail "scenario17a2: expected allow-surge-floor, got $reason"
ok "scenario17a2: surge admits one repair lane when no machinery is live (floor)"

# 17a3: the surge floor is latched — a SECOND non-leverage claim in the same
# tick is refused (exactly one lane, not a drain of the overnight queue).
set +e
reason=$(precedence_band_allow_claim fleet-ops 9997 '[]' "" "")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario17a3: surge floor latch must refuse the second claim, got $rc ($reason)"
[[ "$reason" == "skip-surge-leverage" ]] \
  || fail "scenario17a3: expected skip-surge-leverage after the floor, got $reason"
ok "scenario17a3: surge floor is latched — one lane per tick, then skip"

set +e
reason=$(precedence_band_allow_claim fleet-ops 1223 '[]' "" "")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17b: surge leverage must rc=0, got $rc ($reason)"
[[ "$reason" == "allow-surge-leverage" ]] \
  || fail "scenario17b: expected allow-surge-leverage, got $reason"
ok "scenario17b: surge allows a leverage fleet-ops claim"

set +e
reason=$(precedence_band_allow_claim 0509 1299 "")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17c: product must rc=0, got $rc ($reason)"
[[ "$reason" == "allow-product" ]] \
  || fail "scenario17c: expected allow-product, got $reason"
ok "scenario17c: product claims are never gated"

# Missing policy must not stall a product tick.
export PRECEDENCE_BAND_JSON="$scratch/missing.json"
set +e
reason=$(precedence_band_allow_claim 0509 1299 "")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17d: product with missing policy must rc=0, got $rc ($reason)"
[[ "$reason" == "allow-product" ]] \
  || fail "scenario17d: expected allow-product on missing policy, got $reason"
ok "scenario17d: missing policy does not stall product intake"

export PRECEDENCE_BAND_JSON="$scratch/policy.json"
export PRECEDENCE_BAND_NOW="2026-08-28T03:30:00Z"
cat >"$scratch/units.txt" <<'UNITS'
pi-issue@fleet-ops-101.service
pi-issue@fleet-ops-102.service
pi-issue@fleet-ops-103.service
UNITS
# 3 machinery / 3 total; a fourth machinery claim is 4/4 = 100% > 30%.
set +e
reason=$(precedence_band_allow_claim fleet-ops 104 '[]' "" "")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario17e: band over-cap must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-band" ]] \
  || fail "scenario17e: expected skip-band, got $reason"
ok "scenario17e: band skips a machinery claim that would breach the cap"

set +e
reason=$(precedence_band_allow_claim fleet-ops 104 '[{"name": "priority"}]' "" "")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17f: multiplier must rc=0, got $rc ($reason)"
[[ "$reason" == "allow-multiplier" ]] \
  || fail "scenario17f: expected allow-multiplier, got $reason"
ok "scenario17f: priority label lets machinery jump the cap"

# --- 17g. legit-work quality classification function -----------------------
# shellcheck source=/dev/null
. "$shlib"
export PRECEDENCE_BAND_JSON="$scratch/policy.json"
export PRECEDENCE_BAND_NOW="2026-08-28T03:30:00Z"
export BAND_PENDING_FILE="$scratch/pending.latch"
rm -f "$BAND_PENDING_FILE"
: >"$scratch/units.txt"
export FLEET_PRECEDENCE_UNITS_FILE="$scratch/units.txt"

# Test classify_quality directly
set +e
quality=$(precedence_band_classify_quality "feat: add new feature")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17g: classify_quality feat must rc=0, got $rc ($quality)"
[[ "$quality" == "upgrade" ]] || fail "scenario17g: feat -> upgrade, got $quality"
ok "scenario17g: classify_quality feat -> upgrade"

set +e
quality=$(precedence_band_classify_quality "fix: resolve bug")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17h: classify_quality fix must rc=0, got $rc ($quality)"
[[ "$quality" == "repair" ]] || fail "scenario17h: fix -> repair, got $quality"
ok "scenario17h: classify_quality fix -> repair"

set +e
quality=$(precedence_band_classify_quality "test: add unit test")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17i: classify_quality test must rc=0, got $rc ($quality)"
[[ "$quality" == "repair" ]] || fail "scenario17i: test -> repair, got $quality"
ok "scenario17i: classify_quality test -> repair"

set +e
quality=$(precedence_band_classify_quality "chore: update deps")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17j: classify_quality chore must rc=0, got $rc ($quality)"
[[ "$quality" == "churn" ]] || fail "scenario17j: chore -> churn, got $quality"
ok "scenario17j: classify_quality chore -> churn"

set +e
quality=$(precedence_band_classify_quality "refactor: clean up code")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17k: classify_quality refactor must rc=0, got $rc ($quality)"
[[ "$quality" == "churn" ]] || fail "scenario17k: refactor -> churn, got $quality"
ok "scenario17k: classify_quality refactor -> churn"

set +e
quality=$(precedence_band_classify_quality "docs: update readme")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17l: classify_quality docs must rc=0, got $rc ($quality)"
[[ "$quality" == "churn" ]] || fail "scenario17l: docs -> churn, got $quality"
ok "scenario17l: classify_quality docs -> churn"

set +e
quality=$(precedence_band_classify_quality "random title no prefix")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17m: classify_quality no-prefix must rc=0, got $rc ($quality)"
[[ "$quality" == "churn" ]] || fail "scenario17m: no-prefix -> churn, got $quality"
ok "scenario17m: classify_quality no-prefix -> churn (safe catch-all)"

# --- 17ab..17ah. content-based classification for unprefixed titles ---------
# fleet-ops#1516 starvation root cause: every alert-filed issue has a
# plain-English title with no conventional-commit prefix, so the old
# classifier defaulted the whole title to churn and the legit-work surge
# valve never opened for them. An unprefixed title carrying an unambiguous
# outage/defect signal (in title OR body) must be repair; a prefixed title
# keeps its prefix mapping regardless of body (chore: stays churn even when
# the body says "broken").
expect_quality() {  # title body expected
  local title="$1" body="$2" expected="$3" got
  set +e
  got="$(precedence_band_classify_quality "$title" "$body")"
  rc=$?
  set -e
  [[ "$rc" == "0" ]] || fail "classify_quality rc=$rc for '$title' (got $got)"
  [[ "$got" == "$expected" ]] \
    || fail "classify_quality '$title' -> '$got', want '$expected'"
}

# Unprefixed outage titles -> repair (the starved alert-filed issues).
expect_quality "fleet-ops main CI red (FleetMainRed pending checks)" "" repair
ok "scenario17ab: unprefixed 'red' signal -> repair"
expect_quality "FleetGhWebhookReceiverAbsent firing 6h — receiver down" "" repair
ok "scenario17ac: unprefixed 'down'/'absent' signal -> repair"
expect_quality "alert-repair chain stalled at verify hop since 02:00" "" repair
ok "scenario17ad: unprefixed 'stalled' signal -> repair"
# Title alone carries no signal word; the outage lives in the body.
expect_quality "Dispatcher burns 2851 at-capacity skips per 2h" \
  "capacity exhausted; every ready issue skipped" repair
ok "scenario17ae: unprefixed body 'exhausted' signal -> repair"
expect_quality "at-capacity skip churn: 1006 events in 2h against cap=1" \
  "lane starved; no worker dispatches" repair
ok "scenario17af: unprefixed body 'starved' signal -> repair"

# Prefixed title keeps its mapping even with a 'broken' body (content-blind).
expect_quality "chore: tidy up logs" "broken everything, red alert" churn
ok "scenario17ag: chore: stays churn despite repair-signal body"
# Unprefixed churn signal (rename) with no outage signal -> churn.
expect_quality "Rename helper" "" churn
ok "scenario17ah: unprefixed 'rename' (no outage signal) -> churn"

# Test is_legit_work directly
set +e
precedence_band_is_legit_work "feat: add new feature"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17n: is_legit_work feat must rc=0, got $rc"
ok "scenario17n: is_legit_work feat -> true (legit)"

set +e
precedence_band_is_legit_work "fix: resolve bug"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17o: is_legit_work fix must rc=0, got $rc"
ok "scenario17o: is_legit_work fix -> true (legit)"

set +e
precedence_band_is_legit_work "test: add unit test"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17p: is_legit_work test must rc=0, got $rc"
ok "scenario17p: is_legit_work test -> true (legit)"

set +e
precedence_band_is_legit_work "chore: update deps"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario17q: is_legit_work chore must rc=1, got $rc"
ok "scenario17q: is_legit_work chore -> false (churn)"

set +e
precedence_band_is_legit_work "refactor: clean up code"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario17r: is_legit_work refactor must rc=1, got $rc"
ok "scenario17r: is_legit_work refactor -> false (churn)"

# --- 17s. empty-product surge expansion with legit-work guard (fleet-ops#1516) ---
# When product-ready is empty (BAND_PRODUCT == 0) and we're over the machinery
# cap, legit work (upgrade/repair) should be allowed, churn should be skipped.
export PRECEDENCE_BAND_NOW="2026-08-28T03:30:00Z"
cat >"$scratch/units-empty-product.txt" <<'UNITS'
pi-issue@fleet-ops-101.service
pi-issue@fleet-ops-102.service
pi-issue@fleet-ops-103.service
UNITS
# 3 machinery / 3 total = 100% > 30% cap. Next machinery claim would be 4/4.
export FLEET_PRECEDENCE_UNITS_FILE="$scratch/units-empty-product.txt"
rm -f "$BAND_PENDING_FILE"

# Empty product, legit work (feat) -> allow-band-surge-legit
set +e
reason=$(precedence_band_allow_claim fleet-ops 104 '[]' "" "feat: add new feature")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17s: empty-product + feat must rc=0, got $rc ($reason)"
[[ "$reason" == "allow-band-surge-legit" ]] || fail "scenario17s: expected allow-band-surge-legit, got $reason"
ok "scenario17s: empty-product surge allows legit work (feat/upgrade)"

# Empty product, legit work (fix) -> allow-band-surge-legit
rm -f "$BAND_PENDING_FILE"
set +e
reason=$(precedence_band_allow_claim fleet-ops 105 '[]' "" "fix: resolve bug")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17t: empty-product + fix must rc=0, got $rc ($reason)"
[[ "$reason" == "allow-band-surge-legit" ]] || fail "scenario17t: expected allow-band-surge-legit, got $reason"
ok "scenario17t: empty-product surge allows legit work (fix/repair)"

# Empty product, legit work (test) -> allow-band-surge-legit
rm -f "$BAND_PENDING_FILE"
set +e
reason=$(precedence_band_allow_claim fleet-ops 106 '[]' "" "test: add unit test")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17u: empty-product + test must rc=0, got $rc ($reason)"
[[ "$reason" == "allow-band-surge-legit" ]] || fail "scenario17u: expected allow-band-surge-legit, got $reason"
ok "scenario17u: empty-product surge allows legit work (test/repair)"

# Empty product, churn work (chore) -> skip-band
rm -f "$BAND_PENDING_FILE"
set +e
reason=$(precedence_band_allow_claim fleet-ops 107 '[]' "" "chore: update deps")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario17v: empty-product + chore must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-band" ]] || fail "scenario17v: expected skip-band, got $reason"
ok "scenario17v: empty-product surge rejects churn work (chore)"

# Empty product, churn work (refactor) -> skip-band
rm -f "$BAND_PENDING_FILE"
set +e
reason=$(precedence_band_allow_claim fleet-ops 108 '[]' "" "refactor: clean up code")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario17w: empty-product + refactor must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-band" ]] || fail "scenario17w: expected skip-band, got $reason"
ok "scenario17w: empty-product surge rejects churn work (refactor)"

# Empty product, churn work (no prefix) -> skip-band (safe catch-all)
rm -f "$BAND_PENDING_FILE"
set +e
reason=$(precedence_band_allow_claim fleet-ops 109 '[]' "" "random title no prefix")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario17x: empty-product + no-prefix must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-band" ]] || fail "scenario17x: expected skip-band, got $reason"
ok "scenario17x: empty-product surge rejects churn work (no-prefix catch-all)"

# Empty product, empty title -> skip-band (safe catch-all)
rm -f "$BAND_PENDING_FILE"
set +e
reason=$(precedence_band_allow_claim fleet-ops 110 '[]' "" "")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario17y: empty-product + empty-title must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-band" ]] || fail "scenario17y: expected skip-band, got $reason"
ok "scenario17y: empty-product surge rejects churn work (empty title)"

# Product NOT empty, over cap, legit work -> still skip-band (only empty product)
cat >"$scratch/units-with-product.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@fleet-ops-101.service
pi-issue@fleet-ops-102.service
pi-issue@fleet-ops-103.service
UNITS
# 3 machinery + 1 product = 4 total, 75% machinery > 30%
export FLEET_PRECEDENCE_UNITS_FILE="$scratch/units-with-product.txt"
rm -f "$BAND_PENDING_FILE"
set +e
reason=$(precedence_band_allow_claim fleet-ops 104 '[]' "" "feat: add new feature")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario17z: product-not-empty + feat must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-band" ]] || fail "scenario17z: expected skip-band, got $reason"
ok "scenario17z: product-not-empty does NOT trigger empty-product surge expansion"

# scenario17aa: band bootstrap — when nothing is live (0 machinery, 0 product),
# the first machinery claim MUST be allowed. Without the bootstrap exception,
# the first claim makes it 100% > 30% → skip-band, deadlocking the fleet
# when product is all blocked-on (auditor 2026-08-28, summon unit-failure
# fleet-heartbeat).
cat >"$scratch/units-empty.txt" <<'UNITS'
UNITS
export FLEET_PRECEDENCE_UNITS_FILE="$scratch/units-empty.txt"
rm -f "$BAND_PENDING_FILE"
set +e
reason=$(precedence_band_allow_claim fleet-ops 9999 '[]' "" "")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario17aa: bootstrap must rc=0, got $rc ($reason)"
[[ "$reason" == "allow-band-bootstrap" ]] \
  || fail "scenario17aa: expected allow-band-bootstrap, got $reason"
ok "scenario17aa: band bootstrap allows first claim when nothing is live"

# scenario19: machinery floor (fleet-ops#1452). The 0-live bootstrap in
# 17g does not cover the low-n case: overnight 2026-08-27→28, 1-2 product
# units were live and every machinery claim computed as 1/(1+N) > 30%
# (N=1 → 50%, N=2 → 33%). Result: 224 ready items, ~0 dispatches, the
# starvation reports themselves skipped-precedence-band. One repair lane
# must always be allowed when live machinery == 0; ratio enforcement
# resumes from the second machinery unit.
export PRECEDENCE_BAND_NOW="2026-08-28T03:30:00Z"
for product_n in 1 2 3; do
  rm -f "$BAND_PENDING_FILE"
  : >"$scratch/units-floor.txt"
  i=0
  while (( i < product_n )); do
    echo "pi-issue@0509-$((1299 + i)).service" >>"$scratch/units-floor.txt"
    i=$((i + 1))
  done
  export FLEET_PRECEDENCE_UNITS_FILE="$scratch/units-floor.txt"
  set +e
  reason=$(precedence_band_allow_claim fleet-ops 1452 '[]' "" "")
  rc=$?
  set -e
  [[ "$rc" == "0" ]] \
    || fail "scenario19: machinery=0 product=$product_n must rc=0, got $rc ($reason)"
  [[ "$reason" == "allow-band-floor" ]] \
    || fail "scenario19: machinery=0 product=$product_n expected allow-band-floor, got $reason"
  ok "scenario19: machinery=0 product=$product_n allows one repair lane ($reason)"
done
# The floor is one lane, not a free-for-all: once a machinery unit is
# live, a second machinery claim at low-n is still skip-band (2/4 = 50%
# > 30% with product=2).
cat >"$scratch/units-floor.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@0509-1302.service
pi-issue@fleet-ops-101.service
UNITS
export FLEET_PRECEDENCE_UNITS_FILE="$scratch/units-floor.txt"
set +e
reason=$(precedence_band_allow_claim fleet-ops 1452 '[]' "" "")
rc=$?
set -e
[[ "$rc" == "1" ]] \
  || fail "scenario19d: second machinery unit at low-n must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-band" ]] \
  || fail "scenario19d: expected skip-band, got $reason"
ok "scenario19d: ratio resumes from the second machinery unit (skip-band)"

# Intra-tick latch (fleet-ops#1452 blast radius): the floor reads live
# systemd units, but pi-intake-tick starts workers --no-block and then
# immediately considers the next ready issue. Until the first unit shows
# as activating, BAND_MACHINERY stays 0 and an unlatched floor would dump
# the whole overnight queue (224 ready items). One process may spend the
# floor once; the next call falls through to the ratio. The latch is a
# file keyed on $$ because allow_claim is captured in $() (subshell).
rm -f "$BAND_PENDING_FILE"
cat >"$scratch/units-floor.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@0509-1302.service
UNITS
export FLEET_PRECEDENCE_UNITS_FILE="$scratch/units-floor.txt"
set +e
reason=$(precedence_band_allow_claim fleet-ops 1452 '[]' "" "")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario19e: first floor claim must rc=0, got $rc ($reason)"
[[ "$reason" == "allow-band-floor" ]] \
  || fail "scenario19e: expected allow-band-floor, got $reason"
set +e
reason=$(precedence_band_allow_claim fleet-ops 1453 '[]' "" "")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario19e: second claim same process must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-band" ]] \
  || fail "scenario19e: expected skip-band (floor already spent), got $reason"
ok "scenario19e: floor is one claim per process (intra-tick latch)"

# --- 19f..19h. starvation floor (fleet-ops#1448) -----------------------
# The 08-28 morning deadlock: the machinery cap was already consumed by
# emergency dispatches AND product lanes were saturated, so the starvation
# reports themselves (#1448, #1455) and the seat-pool fix (#1456) were
# skip-listed. With live machinery == 0 false, the machinery floor (#1452)
# could not fire; with the doubled cap already consumed, band-multiplier:2
# was also insufficient. Starvation-class issues diagnose the throttle
# itself and must get exactly ONE lane per tick even when the band would
# otherwise skip them.
# shellcheck source=/dev/null
. "$shlib"
export PRECEDENCE_BAND_JSON="$scratch/policy.json"
export PRECEDENCE_BAND_NOW="2026-08-28T03:30:00Z"
export BAND_PENDING_FILE="$scratch/pending.latch"
rm -f "$BAND_PENDING_FILE"
export BAND_PENDING_STARVATION_FILE="$scratch/pending-starvation.latch"
rm -f "$BAND_PENDING_STARVATION_FILE"
# 3 machinery + 1 product = 75% machinery > 30% cap (over cap) and product
# NOT empty — neither the machinery floor nor empty-product surge applies.
cat >"$scratch/units-starvation.txt" <<'UNITS'
pi-issue@0509-1299.service
pi-issue@fleet-ops-101.service
pi-issue@fleet-ops-102.service
pi-issue@fleet-ops-103.service
UNITS
export FLEET_PRECEDENCE_UNITS_FILE="$scratch/units-starvation.txt"
# Starvation-class issue (dispatch pipeline not consuming the queue) must get
# the reserved lane despite over-cap and saturated product.
set +e
reason=$(precedence_band_allow_claim fleet-ops 1449 '[]' "" "Intake starvation: 224 ready items, 2 dispatches in 2h with 13 healthy seats")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario19f: starvation must rc=0, got $rc ($reason)"
[[ "$reason" == "allow-starvation-floor" ]] \
  || fail "scenario19f: expected allow-starvation-floor, got $reason"
ok "scenario19f: starvation-class issue gets one floor lane despite over-cap+saturated-product"
# The starvation floor is latched: a SECOND starvation claim in the same
# tick is refused so it cannot drain the overnight queue.
set +e
reason=$(precedence_band_allow_claim fleet-ops 1450 '[]' "" "Intake starvation: 229 ready items, 0 claims in 2h")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario19g: starvation latch must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-band" ]] \
  || fail "scenario19g: expected skip-band after starvation floor spent, got $reason"
ok "scenario19g: starvation floor is latched — one lane per tick, then skip"
# A non-starvation repair issue in the same over-cap+saturated-product
# position is still skip-band (only starvation-class is floor-eligible).
rm -f "$BAND_PENDING_STARVATION_FILE"
set +e
reason=$(precedence_band_allow_claim fleet-ops 1451 '[]' "" "fix: resolve a specific booking bug")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario19h: non-starvation over-cap must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-band" ]] \
  || fail "scenario19h: expected skip-band for non-starvation over-cap, got $reason"
ok "scenario19h: non-starvation repair stays skip-band (only starvation is floor-eligible)"
# Starvation detection must NOT fire on an empty title/body (safe catch-all).
rm -f "$BAND_PENDING_STARVATION_FILE"
set +e
reason=$(precedence_band_allow_claim fleet-ops 1452 '[]' "" "")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario19i: empty starvation title must rc=1, got $rc ($reason)"
[[ "$reason" == "skip-band" ]] \
  || fail "scenario19i: expected skip-band for empty title, got $reason"
ok "scenario19i: empty title is not starvation-class (safe catch-all)"

# --- 18. run_canary default NOW is pinned (mechanical prevention #1444) -----
# The #1444 FleetMainRed root cause: run_canary defaulted PRECEDENCE_BAND_NOW
# to empty (live clock), so a phase-specific scenario that forgot to pin NOW
# ran in whatever phase real time happened to be in. #1446 pinned scenarios 7/8
# reactively; the DEFAULT_NOW pin above prevents the class for every future
# scenario. This static guard catches a revert: if someone restores the empty
# default, the drill goes time-dependent again and CI breaks once real time
# crosses cutoff_utc.
self="$here/fleet-precedence-band.test.sh"
grep -F 'DEFAULT_NOW="2026-08-28T01:00:00Z"' "$self" >/dev/null \
  || fail "scenario18: DEFAULT_NOW must be pinned to a pre-cutoff instant (fleet-ops#1444)"
grep -F 'PRECEDENCE_BAND_NOW="${4:-$DEFAULT_NOW}"' "$self" >/dev/null \
  || fail "scenario18: run_canary must default PRECEDENCE_BAND_NOW to \$DEFAULT_NOW (fleet-ops#1444)"
# Dynamic proof: a no-arg run_canary call lands in surge phase (the pinned
# default), not in whatever phase the live clock is in. Real time at CI run
# is post-cutoff (band phase), so a reverted empty default would yield
# phase=band here and fail this assertion.
base_policy_json | clean_policy
: >"$scratch/units.txt"
set +e
out=$(run_canary)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario18: pinned-default surge must exit 0, got $rc ($out)"
grep -q 'phase=surge' <<<"$out" \
  || fail "scenario18: pinned default must yield phase=surge, got ($out)"
ok "scenario18: run_canary default NOW is pinned (time-invariant drill)"

ok "precedence-band: production clean, policy locks, surge, band cap, ratchet, heartbeat, matrix, intake-tick"
