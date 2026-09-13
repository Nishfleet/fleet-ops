#!/usr/bin/env bash
# tests/seat-caps-citation-rule6-replay.test.sh
#
# Replay drill for rule 6 (fleet-ops#3864): synthesize the exact seat-caps.json
# hunk #3848 landed (ollama/deepseek-v4-flash:0731 retired to cap=0 corpse on a
# prepaid-quota provider with a reason that cites empty-runs, not the
# retirement rule's evidence) and prove tests/seat-caps-citation.test.sh now
# REFUSES it (exit 1), while still exiting 0 on the live config.
#
# The #3848 hunk merged 2026-09-06T04:57Z and deployed 05:00Z; at that moment
# ~/.local/state/pi-packet/seat-yield.json showed sessions 20 / pr_count 6 /
# yield 0.30 for the seat and the only deaths in watch.log were rc=124
# hang-watchdog (infrastructure, never seat yield). The three config-pinning
# suites all passed on #3848 because the citation rules checked for a dated
# reason, not the retirement rule's evidence. Rule 6 closes that gap; this
# drill is the proof it actually catches the regression.
#
# Runs entirely offline: copies the live config to a scratch file, applies the
# #3848 hunk via jq, and runs the citation test against the fixture. No
# network, no live state mutation.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
caps_real="$repo_root/config/seat-caps.json"
citation_test="$repo_root/tests/seat-caps-citation.test.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$caps_real" ]]    || fail "seat-caps.json not found: $caps_real"
[[ -f "$citation_test" ]] || fail "citation test not found: $citation_test"
command -v jq >/dev/null   || fail "jq required"

scratch="$(mktemp -d -t seat-caps-rule6.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- the exact #3848 reason (verbatim from PR #3848 diff) -------------------
# This reason cites empty-runs / stdout=0B / HTTP 200 / PONG, NOT the
# retirement rule's evidence (model-working error class, >=20 sessions, PR rate
# <10% / pr_count 0). It must be refused by rule 6.
reason_3848='2026-09-06 fleet-ops#3686: ollama/deepseek-v4-flash:0731 is a corpse advertising health. Live probe 2026-09-06T04:33Z: pi --print --provider ollama --model deepseek-v4-flash:0731 '"'"'Reply PONG'"'"' -> rc=0 PONG (simple packet works, HTTP 200), but the seat no-ops on real work — exit 0, stdout=0B. Heartbeat 2026-09-05T16:30Z: waste.empty_runs_last_2h=21, all samples ollama/deepseek-v4-flash:0731 exiting 0 with stdout=0B, consecutive_failure_count=13, geometric backoff climbed 7200->14400->21600s in 1h while ledger_health_class=healthy (seat-health.ts clobbered the ledger back to healthy/count=0 on a later simple-probe 200). The clobber-proof spawn-bench marker survived and seat_usable honoured it while live, but each bench wall expired and pick-seat re-offered the seat the next cycle — 21 wasted runs in 2h. The no-op is real-work-only (the model cannot drive the fleet worker task), so the seat is functionally dead and unfixable from the fleet side. Retired to cap=0 corpse: pick-seat skips it (model cap=0) and the skip classifies INTENTIONAL (never re-auditioned, fleet-ops#2435). Recovery is provider-side only — re-audition via a fresh allowlist entry if Ollama Cloud deepseek-v4-flash:0731 regains real-work capability. Provider cap/hard_ceiling/max_probe_ceiling stay so a future re-audition re-raises the model cap without a test edit (seatlib-aimd locks hard_ceiling=true).'

# --- Test 1: the live config still passes the citation test (exit 0) --------
echo "--- Test 1: live config passes seat-caps-citation.test.sh (exit 0) ---"
if bash "$citation_test" >/tmp/rule6-replay-live.out 2>&1; then
    ok "live config: seat-caps-citation.test.sh exits 0"
else
    rc=$?
    cat /tmp/rule6-replay-live.out >&2
    fail "live config: seat-caps-citation.test.sh must exit 0 on main, got rc=$rc"
fi
# Confirm rule 6 ran on the live config.
grep -q 'scenario 12' /tmp/rule6-replay-live.out \
  || fail "live config: scenario 12 (rule 6) did not run"
grep -q 'rule 6' /tmp/rule6-replay-live.out \
  || fail "live config: rule 6 verdict line missing"
ok "live config: rule 6 ran and passed (vacuous or satisfied)"

# --- Test 2: synthesize the #3848 fixture (ollama cap=0 corpse on prepaid) --
echo "--- Test 2: synthesize the #3848 fixture ---"
fixture="$scratch/seat-caps.json"
cp "$caps_real" "$fixture"
# Apply the #3848 hunk: ollama/deepseek-v4-flash:0731 -> {cap:0, intentional_cap_zero:corpse, reason}.
# ollama is class=prepaid-quota, so rule 6 must check it.
jq --arg reason "$reason_3848" \
   '.providers.ollama.models["deepseek-v4-flash:0731"] = {cap: 0, intentional_cap_zero: "corpse", reason: $reason}' \
   "$caps_real" > "$fixture"
jq -e '.providers.ollama.models["deepseek-v4-flash:0731"].cap == 0' "$fixture" >/dev/null \
  || fail "fixture: ollama model cap not set to 0"
jq -r '.providers.ollama.models["deepseek-v4-flash:0731"].intentional_cap_zero' "$fixture" | grep -q '^corpse$' \
  || fail "fixture: ollama model intentional_cap_zero not corpse"
jq -r '.providers.ollama.class' "$fixture" | grep -q '^prepaid-quota$' \
  || fail "fixture: ollama must be prepaid-quota (rule 6 only fires on paid providers)"
ok "fixture: ollama/deepseek-v4-flash:0731 cap=0 corpse on prepaid-quota (the #3848 hunk)"

# --- Test 3: the citation test REFUSES the #3848 fixture (exit 1) -----------
echo "--- Test 3: citation test refuses the #3848 fixture (exit 1) ---"
if SEAT_CAPS_JSON="$fixture" bash "$citation_test" >/tmp/rule6-replay-fixture.out 2>&1; then
    cat /tmp/rule6-replay-fixture.out >&2
    fail "fixture: seat-caps-citation.test.sh must exit 1 on the #3848 hunk (rule 6), got exit 0"
fi
rc_fixture=${PIPESTATUS[0]:-$?}
# Confirm rule 6 is what refused it (scenario 12 must appear in the output).
grep -q 'scenario 12' /tmp/rule6-replay-fixture.out \
  || { cat /tmp/rule6-replay-fixture.out >&2; fail "fixture: scenario 12 (rule 6) did not run"; }
grep -qiE 'scenario12: .*rule 6' /tmp/rule6-replay-fixture.out \
  || { cat /tmp/rule6-replay-fixture.out >&2; fail "fixture: rule 6 did not flag the #3848 hunk"; }
# Confirm the refusal names the missing evidence (error class is the first gap
# in the #3848 reason — it cites empty-runs, not model-working/tools>0).
grep -qiE 'must cite the retirement error class' /tmp/rule6-replay-fixture.out \
  || { cat /tmp/rule6-replay-fixture.out >&2; fail "fixture: rule 6 refusal did not name the missing error class"; }
ok "fixture: seat-caps-citation.test.sh exits 1 on the #3848 hunk — rule 6 refuses it"

# --- Test 4: a CORRECT retirement reason passes rule 6 on the same seat -----
# Proves rule 6 is not a blanket blocker: a reason that cites all three pieces
# of evidence (model-working, n=24 sessions, pr_count 0) is accepted.
echo "--- Test 4: a correct retirement reason passes rule 6 ---"
reason_correct='2026-09-06 retirement (fleet-ops#3864 rule 6): ollama/deepseek-v4-flash:0731 retired after n=24 sessions ended with the model working (model-working, tools>0, no infra error) and pr_count 0 (PR rate 0%, under 10%). Live watch 2026-09-06: every session drove the fleet worker task and produced no PR. Recovery is provider-side only.'
fixture_ok="$scratch/seat-caps-ok.json"
jq --arg reason "$reason_correct" \
   '.providers.ollama.models["deepseek-v4-flash:0731"] = {cap: 0, intentional_cap_zero: "corpse", reason: $reason}' \
   "$caps_real" > "$fixture_ok"
if SEAT_CAPS_JSON="$fixture_ok" bash "$citation_test" >/tmp/rule6-replay-ok.out 2>&1; then
    grep -q 'scenario 12' /tmp/rule6-replay-ok.out \
      || { cat /tmp/rule6-replay-ok.out >&2; fail "correct fixture: scenario 12 did not run"; }
    grep -qiE 'ollama/deepseek-v4-flash:0731: cap=0 yield retirement on prepaid-quota provider cites error class' /tmp/rule6-replay-ok.out \
      || { cat /tmp/rule6-replay-ok.out >&2; fail "correct fixture: rule 6 did not accept the evidence-cited reason"; }
    ok "correct fixture: seat-caps-citation.test.sh exits 0 — rule 6 accepts a properly-evidenced retirement"
else
    rc_ok=$?
    cat /tmp/rule6-replay-ok.out >&2
    fail "correct fixture: seat-caps-citation.test.sh must exit 0 on a properly-evidenced retirement, got rc=$rc_ok"
fi

ok "seat-caps-citation-rule6-replay: #3848 hunk refused, live config accepted, correct retirement accepted (fleet-ops#3864)"
