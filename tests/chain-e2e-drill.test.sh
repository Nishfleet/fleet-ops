#!/usr/bin/env bash
# tests/chain-e2e-drill.test.sh
#
# fleet-ops#375: the chain-e2e drill proves the whole failure chain end to
# end by injecting one synthetic fixture fault and asserting each hop
# mechanically. This test runs the drill in DRY_RUN (wiring proofs only, no
# live systemd / no GitHub writes) and asserts every hop passes, then locks
# the wiring: SLO snapshot folds it in, blind-audit runs it on the cadence,
# and the escalation canary treats the fixture as a drill.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
drill="$repo_root/bin/chain-e2e-drill"
slo="$repo_root/bin/fleet-gap-closure-slo"
canary="$repo_root/bin/fleet-escalation-canary"
audit="$repo_root/bin/fleet-blind-audit"
fixture_unit="$repo_root/systemd/chain-e2e-drill-fixture.service"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$drill" ]] || fail "not executable: $drill"
bash -n "$drill" || fail "$drill fails bash -n"

# --help is the help-first contract for new bin/ files.
set +e
"$drill" --help >"$tmp/help.txt" 2>&1; help_rc=$?
set -e
[[ "$help_rc" -eq 0 ]] || fail "--help must exit 0, got $help_rc"
grep -q "usage: chain-e2e-drill" "$tmp/help.txt" || fail "--help must print usage"

# --- run the drill in DRY_RUN and assert all hops pass ---------------------
DRY="$tmp/dry"
set +e
CHAIN_E2E_STATE_DIR="$DRY" CHAIN_E2E_DRY_RUN=1 \
    CHAIN_E2E_FAKE_NOW="2026-09-08T21:00:00Z" \
    "$drill" >"$tmp/dry.out" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "DRY_RUN drill must exit 0, got $rc: $(tail -3 "$tmp/dry.out")"
res="$DRY/chain-e2e-drill-results.json"
[[ -f "$res" ]] || fail "no results file $res"
jq -e '.all_pass == true' "$res" >/dev/null || fail "all_pass must be true: $(cat "$res")"

jq -e '.signal == "chain-e2e-drill/fixture"' "$res" >/dev/null \
  || fail "results must carry the fixture signal key"
jq -e '.label == "drill:chain-e2e"' "$res" >/dev/null \
  || fail "results must carry the drill label"
jq -e '.marker == "[drill:chain-e2e]"' "$res" >/dev/null \
  || fail "results must carry the LOUD drill marker"

jq -e '.results[] | select(.name == "fixture-isolated" and .pass)' "$res" >/dev/null \
  || fail "hop 1 (fixture isolated/non-installable) must pass"
jq -e '.results[] | select(.name == "ticket-auto-filed" and .pass)' "$res" >/dev/null \
  || fail "hop 2 (#362 auto-files ticket on signal key) must pass"
jq -e '.results[] | select(.name == "escalate-senior-routed" and .pass)' "$res" >/dev/null \
  || fail "hop 3 (escalate-senior routing) must pass"
jq -e '.results[] | select(.name == "mechanism-gate" and .pass)' "$res" >/dev/null \
  || fail "hop 4 (#366 gate rejects no-mechanism, passes with drill) must pass"
jq -e '.results[] | select(.name == "observe-to-close-refused-while-red" and .pass)' "$res" >/dev/null \
  || fail "hop 5a (ticket refuses close while red) must pass"
jq -e '.results[] | select(.name == "observe-to-close-flips-on-green" and .pass)' "$res" >/dev/null \
  || fail "hop 5b (ticket flips closed on green) must pass"
jq -e '.results[] | select(.name == "slo-snapshot" and .pass)' "$res" >/dev/null \
  || fail "hop 6 (SLO snapshot) must pass"
jq -e '.results[] | select(.name == "resume-wiring" and .pass)' "$res" >/dev/null \
  || fail "hop 7 (resume-or-dispatch wiring, fleet-ops#5456) must pass"

# --- the fixture stub unit must be unmistakably synthetic -------------------
[[ -f "$fixture_unit" ]] || fail "fixture stub unit missing"
grep -qE '^\[Install\]$' "$fixture_unit" \
  && fail "fixture stub must NOT be installable ([Install] banned)"
grep -q '^RuntimeMaxSec=' "$fixture_unit" \
  || fail "fixture stub must be bounded by RuntimeMaxSec"
grep -q 'Slice=chain-e2e-drill.slice' "$fixture_unit" \
  || fail "fixture stub must be isolated to chain-e2e-drill.slice"
grep -qF '[drill:chain-e2e]' "$fixture_unit" \
  || fail "fixture stub LOUD line must carry the [drill:chain-e2e] marker"
grep -qF 'signal: chain-e2e-drill/fixture' "$fixture_unit" \
  || fail "fixture stub LOUD line must carry signal: chain-e2e-drill/fixture"
ok "fixture stub is non-installable, bounded, isolated, and synthetic"

# --- hop 6 wiring: SLO snapshot folds the drill result ---------------------
grep -qF 'chain-e2e-drill-results' "$slo" \
  || fail "fleet-gap-closure-slo must read chain-e2e-drill-results"
grep -qF 'chain_e2e_drill_pass_rate' "$slo" \
  || fail "SLO snapshot must emit chain_e2e_drill_pass_rate"
ok "fleet-gap-closure-slo folds the chain-e2e drill into the SLO snapshot"

# --- cadence wiring: blind-audit runs the drill once per audit cycle -------
grep -qF 'chain-e2e-drill' "$audit" \
  || fail "fleet-blind-audit must run the chain-e2e drill on its cadence"
ok "fleet-blind-audit runs the chain-e2e drill once per audit cycle"

# --- hop 7 wiring: the hourly heartbeat runs the kill-three-ways drill ------
# fleet-ops#5456 H: the drill runs from the EXISTING hourly fleet-heartbeat
# verify step (block 5b), not a new timer, and a drill failure propagates so
# the heartbeat unit lands in --state=failed.
grep -qF 'chain-e2e-drill' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "fleet-heartbeat-tier1 must run the kill-three-ways drill (block 5b)"
grep -qF 'drill_rc' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "block 5b must propagate a drill failure (drill_rc exit)"
ok "fleet-heartbeat-tier1 runs the kill-three-ways drill hourly (block 5b, fail-loud)"

# --- hop 1 wiring: the escalation canary treats the fixture as a drill ------
grep -qF 'chain-e2e-drill-fixture' "$canary" \
  || fail "fleet-escalation-canary must exclude chain-e2e-drill-fixture from escalation"
ok "escalation canary excludes the fixture (no real senior page)"

echo "OK: chain-e2e drill — all hops pass in DRY_RUN, wiring locked"