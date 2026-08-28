#!/usr/bin/env bash
# tests/rule-enforcement.test.sh
#
# Proves the rule-coverage matrix + canary (fleet-ops#383):
#   1. Committed config/rule-enforcement.json is valid.
#   2. Join against a fixture vault: complete coverage is green.
#   3. Drill: a fixture `## ` heading with no matrix entry is uncovered,
#      the canary exits 1 naming it, and an issue is auto-filed (fake gh).
#   4. Replay: an open issue carrying the signal key is deduped (no second file).
#   5. queued(#N) older than queued_stale_days is a LOUD violation.
#   6. advisory without a reason fails validate-matrix.
#   7. FLAG ledger lines are skipped (not standing rules).
#   8. Observe-to-close: an enforced row with an open fallback-signal
#      mechanism issue gets a `canary-covered:` comment; replay is a no-op.
#
# Offline. Live vault coverage is asserted when the vault files exist
# (VPS inner loop); hosted CI skips that one check rather than inventing
# a stale snapshot.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/rule-enforcement.py"
matrix="$repo_root/config/rule-enforcement.json"
canary="$repo_root/bin/fleet-escalation-canary"
vault_rules="/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md"
vault_ledger="/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/decisions-ledger.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$matrix" ]] || fail "missing $matrix"
[[ -x "$canary" ]] || fail "not executable: $canary"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

python3 "$lib" validate-matrix --matrix "$matrix" \
  || fail "committed matrix failed validate-matrix"
count=$(jq '.rules | length' "$matrix")
[[ "$count" -gt 0 ]] || fail "matrix.rules is empty"
ok "committed matrix is valid ($count rules)"

jq -e '.rules[] | select(.id == "led-worker-lane-refresh" and .status == "enforced")' \
  "$matrix" >/dev/null \
  || fail "led-worker-lane-refresh must be status=enforced (fleet-ops#545)"
ok "matrix row led-worker-lane-refresh is enforced"

jq -e '.rules[] | select(.id == "led-2026-08-27-worker-lane-order-nish-emphatic-can-t-stress-enou" and .status == "enforced")' \
  "$matrix" >/dev/null \
  || fail "led-2026-08-27-worker-lane-order must be status=enforced (fleet-ops#1178)"
ok "matrix row led-2026-08-27-worker-lane-order is enforced"

jq -e '.rules[] | select(.id == "sr-verify-harness" and .status == "enforced")' \
  "$matrix" >/dev/null \
  || fail "sr-verify-harness must be status=enforced (fleet-ops#524)"
ok "matrix row sr-verify-harness is enforced"

jq -e '.rules[] | select(.id == "sr-pstack-review" and .status == "enforced") | .proof | test("prompts/worker.md")' \
  "$matrix" >/dev/null \
  || fail "sr-pstack-review must be enforced and proof must name prompts/worker.md (fleet-ops#1260)"
ok "matrix row sr-pstack-review is enforced via worker.md"

jq -e '.rules[] | select(.id == "led-work-supply-agent-ready" and .status == "enforced")' \
  "$matrix" >/dev/null \
  || fail "led-work-supply-agent-ready must be status=enforced (fleet-ops#543)"
ok "matrix row led-work-supply-agent-ready is enforced"

# fleet-ops#552: the two 2026-08-27 ledger rules must have enforced matrix
# rows even when the live vault is absent (CI skips the live join).
for src in \
  "decisions-ledger.md: 2026-08-27 | TOP GEAR everywhere, non-negotiable" \
  "decisions-ledger.md: 2026-08-27 | escalation matrix FIXES, not just routes" \
  "decisions-ledger.md: 2026-08-27 | Vacation window corrected"
do
  status=$(jq -r --arg src "$src" '.rules[] | select(.source == $src) | .status' "$matrix")
  [[ "$status" == "enforced" ]] || fail "matrix must have $src as enforced, got ${status:-missing}"
  ok "matrix row for $src is enforced"
done
# fleet-ops#1178: apostrophe in "can't" — assert via --arg, not a double-quoted for-loop entry.
src_1178='decisions-ledger.md: 2026-08-27 | Worker lane order (Nish, emphatic: "can'"'"'t stress enough")'
status=$(jq -r --arg src "$src_1178" '.rules[] | select(.source == $src) | .status' "$matrix")
[[ "$status" == "enforced" ]] || fail "matrix must have $src_1178 as enforced, got ${status:-missing}"
ok "matrix row for worker lane order (fleet-ops#1178) is enforced"

src_1245='decisions-ledger.md: 2026-08-27 | GEO/AEO: fleet executes measurement + owned-content tactics; community/PR parked for Nish'
status=$(jq -r --arg src "$src_1245" '.rules[] | select(.source == $src) | .status' "$matrix")
[[ "$status" == "enforced" ]] || fail "matrix must have $src_1245 as enforced, got ${status:-missing}"
ok "matrix row for GEO/AEO parked tactics (fleet-ops#1245) is enforced"

# fleet-ops#1178: volume front-of-ladder canary. Hosted BEFORE the live
# vault join so a busy board of other uncovered sibling ledger lines
# cannot skip this drill (the live join still asserts our covered_rows).
bash "$here/fleet-volume-lane-order-canary.test.sh" || fail "volume-lane-order canary drill failed"
ok "rule-enforcement: volume-lane-order canary drill"

# fleet-ops#1245: GEO/AEO parked-tactics + brand-gate canary. Hosted
# BEFORE the live vault join for the same reason as #1178.
bash "$here/fleet-geo-aeo.test.sh" || fail "geo-aeo canary drill failed"
ok "rule-enforcement: geo-aeo canary drill"

# fleet-ops#1222: Weekly Fleet Review quality ratchet. Nested host so this
# token does not need a workflow edit. Before the live vault join so a busy
# board of other uncovered sibling ledger lines cannot skip this drill.
bash "$here/quality-ratchet.test.sh" || fail "quality-ratchet drill failed"
ok "rule-enforcement: quality-ratchet drill"

# fleet-ops#1223: precedence-band canary (ledger rent-paying band). Nested
# host so this token does not need a workflow edit. Before the live vault
# join so a busy board of other uncovered sibling ledger lines cannot skip
# this drill.
bash "$here/fleet-precedence-band.test.sh" || fail "precedence-band canary drill failed"
ok "rule-enforcement: precedence-band canary drill"

# fleet-ops#234: escalate-senior intake path (senior panel). Nested host so
# the worker token does not need a workflow edit (fleet-ops#566).
bash "$here/pi-escalation-audit.test.sh" || fail "pi-escalation-audit drill failed"
ok "rule-enforcement: pi-escalation-audit drill"

# fleet-ops#907: D1 prod migration vacation grant is enforced by the worker
# prompt D1 schema rule and this CI drill.
bash "$here/fleet-d1-prod-migration-grant.test.sh" || fail "d1-prod-migration-grant drill failed"
ok "rule-enforcement: d1-prod-migration-grant drill"

# Live vault join when the files are on this box.
if [[ -f "$vault_rules" && -f "$vault_ledger" ]]; then
  set +e
  live=$(python3 "$lib" join --rules "$vault_rules" --ledger "$vault_ledger" \
    --matrix "$matrix" --now "2026-08-26T16:00:00Z")
  live_rc=$?
  set -e
  uncovered=$(jq '.uncovered | length' <<<"$live")
  malformed=$(jq '.malformed | length' <<<"$live")
  extra=$(jq '.extra_matrix | length' <<<"$live")
  [[ "$uncovered" == "0" ]] || fail "live vault has uncovered rules: $(jq -c '.uncovered' <<<"$live")"
  [[ "$malformed" == "0" ]] || fail "live matrix has malformed rows: $(jq -c '.malformed' <<<"$live")"
  [[ "$extra" == "0" ]] || fail "live matrix has extra rows: $(jq -c '.extra_matrix' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-27 | TOP GEAR everywhere, non-negotiable" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report TOP GEAR as enforced covered_rows (fleet-ops#479): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "global-standing-rules.md: Prepaid subs run at max utilization (Nish, 2026-08-20)" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report sr-prepaid-max-util as enforced covered_rows (fleet-ops#531): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-27 | escalation matrix FIXES, not just routes" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report escalation FIXES as enforced covered_rows (fleet-ops#548): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "global-standing-rules.md: Vault sync conflicts auto-resolve (Nish, 2026-08-19, amends the freeze rule)" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report vault sync conflicts as enforced covered_rows (fleet-ops#529): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "global-standing-rules.md: Find the proven thing before you build anything (Nish, 2026-08-23)" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report sr-find-proven-thing as enforced covered_rows (fleet-ops#534): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-26 | NORTH STAR: quality through and through" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report led-north-star-quality as enforced covered_rows (fleet-ops#459): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-26 | GLM 5.3 flash free on ClinePass" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report GLM 5.3 flash ClinePass as enforced covered_rows (fleet-ops#462): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-25 | repo visibility" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report repo visibility as enforced covered_rows (fleet-ops#542): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-27 | straitly ds4-pro approved for workers" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report straitly ds4-pro as enforced covered_rows (fleet-ops#546): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "global-standing-rules.md: Execution IS the review — run it, log the bugs, fix, run again (Nish, 2026-08-25 — non-negotiable)" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report sr-execution-is-review as enforced covered_rows (fleet-ops#537): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-26 | work supply (rev: 24h, same day)" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report work supply 24h as enforced covered_rows (fleet-ops#540): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-26 | worker-lane refresh (Nish)" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report worker-lane refresh as enforced covered_rows (fleet-ops#545): $(jq -c '.covered_rows' <<<"$live")"
  jq -e --arg src 'decisions-ledger.md: 2026-08-27 | Worker lane order (Nish, emphatic: "can'"'"'t stress enough")' \
    '.covered_rows[] | select(.source == $src and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report worker lane order as enforced covered_rows (fleet-ops#1178): $(jq -c '.covered_rows' <<<"$live")"
  jq -e --arg src 'decisions-ledger.md: 2026-08-27 | GEO/AEO: fleet executes measurement + owned-content tactics; community/PR parked for Nish' \
    '.covered_rows[] | select(.source == $src and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report GEO/AEO parked tactics as enforced covered_rows (fleet-ops#1245): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-27 | Quality ratchet (Nish)" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report Quality ratchet as enforced covered_rows (fleet-ops#1222): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-25 | continuous research" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report continuous research as enforced covered_rows (fleet-ops#541): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-24 | Tailscale" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report Tailscale ACL lockdown as enforced covered_rows (fleet-ops#544): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "global-standing-rules.md: Per-repo verification harness (Nish, 2026-08-20, adopted from Cursor pstack)" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report sr-verify-harness as enforced covered_rows (fleet-ops#524): $(jq -c '.covered_rows' <<<"$live")"
  jq -e '.covered_rows[] | select(.source == "decisions-ledger.md: 2026-08-25 | work supply" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report work-supply agent-ready as enforced covered_rows (fleet-ops#543): $(jq -c '.covered_rows' <<<"$live")"
  ok "live vault join is covered (vault=$(jq .vault_rule_count <<<"$live") rc=$live_rc)"
  ok "live join: TOP GEAR source is enforced (observe-to-close for #479)"
  ok "live join: prepaid max-util source is enforced (observe-to-close for #531)"
  ok "live join: escalation FIXES source is enforced (observe-to-close for #548)"
  ok "live join: vault sync conflicts source is enforced (observe-to-close for #529)"
  ok "live join: find-the-proven-thing source is enforced (observe-to-close for #534)"
  ok "live join: NORTH STAR quality source is enforced (observe-to-close for #459)"
  ok "live join: GLM 5.3 flash ClinePass source is enforced (observe-to-close for #462)"
  ok "live join: repo visibility source is enforced (observe-to-close for #542)"
  ok "live join: straitly ds4-pro source is enforced (observe-to-close for #546)"
  ok "live join: execution-is-review source is enforced (observe-to-close for #537)"
  ok "live join: work supply 24h source is enforced (observe-to-close for #540)"
  ok "live join: worker-lane refresh source is enforced (observe-to-close for #545)"
  ok "live join: worker lane order source is enforced (observe-to-close for #1178)"
  ok "live join: GEO/AEO parked tactics source is enforced (observe-to-close for #1245)"
  ok "live join: Quality ratchet source is enforced (observe-to-close for #1222)"
  ok "live join: continuous research source is enforced (observe-to-close for #541)"
  ok "live join: Tailscale ACL lockdown source is enforced (observe-to-close for #544)"
  ok "live join: per-repo verification harness source is enforced (observe-to-close for #524)"
  ok "live join: work-supply agent-ready source is enforced (observe-to-close for #543)"
else
  ok "live vault not present (hosted CI) — skip exhaustiveness join"
fi

# --- parser unit: FLAG lines skipped, ### not counted, ## counted ------------
scratch="$(mktemp -d -t rule-enf.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

cat >"$scratch/rules.md" <<'EOF'
# Title
## Real standing rule (Nish, 2026-08-26)
body
### Child heading must not count
## Second standing rule
EOF
cat >"$scratch/ledger.md" <<'EOF'
## Ledger
### Product / fleet
- 2026-08-26 | real decision | STANDING, NON-NEGOTIABLE: a rule
- 2026-08-26 | flag row | FLAG (not a Nish decision): skip me
- not a decision line
- 2026-08-28 | REVERSAL: machinery-gate builds DELETED | The two entries above are VOID - do not re-execute
- 2026-08-28 | Clarification of the reversal above | The VOID applies to the build only
EOF

python3 - "$lib" "$scratch/rules.md" "$scratch/ledger.md" <<'PY' || fail "parser unit failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("reenf", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
standing = m.parse_standing_rules(open(sys.argv[2], encoding="utf-8").read())
ledger = m.parse_ledger(open(sys.argv[3], encoding="utf-8").read())
assert len(standing) == 2, standing
assert standing[0]["key"] == "Real standing rule (Nish, 2026-08-26)", standing
assert len(ledger) == 1, ledger
assert ledger[0]["key"] == "2026-08-26 | real decision", ledger
assert ledger[0]["key"] == "2026-08-26 | real decision", ledger

src = "decisions-ledger.md: 2026-08-27 | TOP GEAR everywhere, non-negotiable"
assert m.fallback_id_from_source(src) == (
    "led-2026-08-27-top-gear-everywhere-non-negotiable"
), m.fallback_id_from_source(src)
row = {
    "id": "led-top-gear-everywhere",
    "source": src,
    "status": "enforced",
    "fallback_id": m.fallback_id_from_source(src),
}
body_fallback = (
    "The rule-coverage canary found a standing rule with no live enforcer.\n\n"
    f"- source: `{src}`\n\n"
    "signal: rule-enforcement/led-2026-08-27-top-gear-everywhere-non-negotiable\n"
)
assert m.issue_matches_covered(body_fallback, row), "fallback signal + source backtick must match"
body_matrix_id = "signal: rule-enforcement/led-top-gear-everywhere\n"
assert m.issue_matches_covered(body_matrix_id, row), "matrix id signal must match"
assert not m.issue_matches_covered("unrelated body", row)
assert not m.issue_matches_covered(
    f"- source: `{src}`\nrelated but not a mechanism signal\n", row
), "quoting the source without a signal must not match"

report = {
    "covered_rows": [row],
    "auto_file_cap_per_tick": 5,
}
issues = [
    {"number": 479, "body": body_fallback, "comments": []},
    {"number": 480, "body": "signal: rule-enforcement/other", "comments": []},
    {
        "number": 481,
        "body": body_fallback,
        "comments": [{"body": f"canary-covered: {src}\n"}],
    },
]
targets = m.observe_targets(report, issues)
assert [t["number"] for t in targets] == [479], targets
assert targets[0]["marker"] == f"canary-covered: {src}", targets

# close_targets: only issues that carry the canary-covered marker AND match an
# enforced row are closeable. #481 has the marker -> closeable. #479 has no
# marker yet (canary has not reported green) -> NOT closeable. #480 is an
# unrelated signal -> NOT closeable.
close_targets = m.close_targets(report, issues)
assert [t["number"] for t in close_targets] == [481], close_targets
assert close_targets[0]["marker"] == f"canary-covered: {src}", close_targets
assert close_targets[0]["id"] == row["id"], close_targets

# A non-enforced row must never produce a close target even with the marker.
queued_row = dict(row, status="queued", issue=362)
queued_report = {"covered_rows": [queued_row], "auto_file_cap_per_tick": 5}
queued_issues = [
    {"number": 482, "body": body_fallback, "comments": [{"body": f"canary-covered: {src}\n"}]},
]
assert m.close_targets(queued_report, queued_issues) == [], "queued row must not close"
print("parser-ok")
PY
ok "parser: ## headings counted, ### ignored, FLAG ledger lines skipped"
ok "observe-to-close: fallback id, source backtick, and already-commented issues"
ok "observe-to-close close_targets: marker+enforced closes, no-marker and queued do not"

# --- fixture join: complete coverage ----------------------------------------
cat >"$scratch/covered-rules.md" <<'EOF'
## Covered fixture rule (Nish, 2026-08-26)
EOF
cat >"$scratch/covered-ledger.md" <<'EOF'
- 2026-08-26 | covered ledger rule | a decision
EOF
cat >"$scratch/covered-matrix.json" <<'EOF'
{
  "queued_stale_days": 7,
  "auto_file_cap_per_tick": 5,
  "rules": [
    {
      "id": "sr-covered-fixture",
      "source": "global-standing-rules.md: Covered fixture rule (Nish, 2026-08-26)",
      "mechanism": "test gate",
      "proof": "tests/rule-enforcement.test.sh",
      "status": "enforced"
    },
    {
      "id": "led-covered-fixture",
      "source": "decisions-ledger.md: 2026-08-26 | covered ledger rule",
      "mechanism": "test gate",
      "proof": "tests/rule-enforcement.test.sh",
      "status": "enforced"
    }
  ]
}
EOF
python3 "$lib" join --rules "$scratch/covered-rules.md" --ledger "$scratch/covered-ledger.md" \
  --matrix "$scratch/covered-matrix.json" --now "2026-08-26T12:00:00Z" >"$scratch/covered.json"
jq -e '.violations == 0 and .uncovered == []' "$scratch/covered.json" >/dev/null \
  || fail "complete fixture must have zero violations: $(cat "$scratch/covered.json")"
ok "join: complete fixture is green"

# fleet-ops#548: CI-visible guard for the VPS-only miss. A ledger with the
# two 2026-08-27 titles must be covered by the committed rows, and omitting
# those rows must surface the fallback ids the canary auto-files.
cat >"$scratch/548-rules.md" <<'EOF'
# none
EOF
cat >"$scratch/548-ledger.md" <<'EOF'
- 2026-08-27 | TOP GEAR everywhere, non-negotiable | a decision
- 2026-08-27 | escalation matrix FIXES, not just routes | a decision
EOF
jq '{
  queued_stale_days: .queued_stale_days,
  auto_file_cap_per_tick: .auto_file_cap_per_tick,
  rules: [.rules[] | select(
    .source == "decisions-ledger.md: 2026-08-27 | TOP GEAR everywhere, non-negotiable"
    or .source == "decisions-ledger.md: 2026-08-27 | escalation matrix FIXES, not just routes"
  )]
}' "$matrix" >"$scratch/548-covered-matrix.json"
python3 "$lib" join --rules "$scratch/548-rules.md" --ledger "$scratch/548-ledger.md" \
  --matrix "$scratch/548-covered-matrix.json" --now "2026-08-27T12:00:00Z" \
  >"$scratch/548-covered.json"
jq -e '.violations == 0 and (.uncovered | length) == 0 and (.covered == 2)' \
  "$scratch/548-covered.json" >/dev/null \
  || fail "committed 2026-08-27 rows must cover the two ledger titles: $(cat "$scratch/548-covered.json")"
ok "join: committed 2026-08-27 rows cover the two ledger titles (fleet-ops#548)"

cat >"$scratch/548-missing-matrix.json" <<'EOF'
{
  "queued_stale_days": 7,
  "auto_file_cap_per_tick": 5,
  "rules": [
    {
      "id": "led-unrelated-548",
      "source": "decisions-ledger.md: 2026-08-26 | unrelated covered",
      "mechanism": "test gate",
      "proof": "tests/rule-enforcement.test.sh",
      "status": "enforced"
    }
  ]
}
EOF
set +e
python3 "$lib" join --rules "$scratch/548-rules.md" --ledger "$scratch/548-ledger.md" \
  --matrix "$scratch/548-missing-matrix.json" --now "2026-08-27T12:00:00Z" \
  >"$scratch/548-missing.json"
missing_rc=$?
set -e
[[ "$missing_rc" == "1" ]] || fail "omitting the 2026-08-27 rows must make join exit 1, got $missing_rc"
jq -e '[.uncovered[].id] | sort == [
  "led-2026-08-27-escalation-matrix-fixes-not-just-routes",
  "led-2026-08-27-top-gear-everywhere-non-negotiable"
]' "$scratch/548-missing.json" >/dev/null \
  || fail "omitting the 2026-08-27 rows must uncover the canary fallback ids: $(cat "$scratch/548-missing.json")"
ok "join: omitting the 2026-08-27 rows uncovers the canary fallback ids (fleet-ops#548)"

# --- queued row in report ---------------------------------------------------
cat >"$scratch/queued-rules.md" <<'EOF'
# fixture
## Covered fixture rule (Nish, 2026-08-26)
## Queued fixture rule waiting for a mechanism (Nish, 2026-08-26)
EOF
cat >"$scratch/queued-matrix.json" <<'EOF'
{
  "queued_stale_days": 7,
  "auto_file_cap_per_tick": 5,
  "rules": [
    {
      "id": "sr-covered-fixture",
      "source": "global-standing-rules.md: Covered fixture rule (Nish, 2026-08-26)",
      "mechanism": "test gate",
      "proof": "tests/rule-enforcement.test.sh",
      "status": "enforced"
    },
    {
      "id": "led-covered-fixture",
      "source": "decisions-ledger.md: 2026-08-26 | covered ledger rule",
      "mechanism": "test gate",
      "proof": "tests/rule-enforcement.test.sh",
      "status": "enforced"
    },
    {
      "id": "sr-queued-fixture",
      "source": "global-standing-rules.md: Queued fixture rule waiting for a mechanism (Nish, 2026-08-26)",
      "mechanism": "not yet",
      "proof": "fleet-ops#1",
      "status": "queued(#1)",
      "queued_since": "2026-08-26"
    }
  ]
}
EOF
python3 "$lib" join --rules "$scratch/queued-rules.md" --ledger "$scratch/covered-ledger.md" \
  --matrix "$scratch/queued-matrix.json" --now "2026-08-26T12:00:00Z" >"$scratch/queued.json"
jq -e '.queued | length == 1' "$scratch/queued.json" >/dev/null \
  || fail "queued fixture must report one queued row: $(cat "$scratch/queued.json")"
jq -e '.queued[0].mechanism == "not yet" and .queued[0].proof == "fleet-ops#1"' "$scratch/queued.json" >/dev/null \
  || fail "queued row must carry mechanism and proof: $(jq -c '.queued[0]' "$scratch/queued.json")"
ok "join: queued rows include mechanism and proof"

# --- stale queued -----------------------------------------------------------
cat >"$scratch/stale-matrix.json" <<'EOF'
{
  "queued_stale_days": 7,
  "auto_file_cap_per_tick": 5,
  "rules": [
    {
      "id": "sr-covered-fixture",
      "source": "global-standing-rules.md: Covered fixture rule (Nish, 2026-08-26)",
      "mechanism": "not yet",
      "proof": "fleet-ops#1",
      "status": "queued(#1)",
      "queued_since": "2026-08-01"
    },
    {
      "id": "led-covered-fixture",
      "source": "decisions-ledger.md: 2026-08-26 | covered ledger rule",
      "mechanism": "test gate",
      "proof": "tests/rule-enforcement.test.sh",
      "status": "enforced"
    }
  ]
}
EOF
set +e
python3 "$lib" join --rules "$scratch/covered-rules.md" --ledger "$scratch/covered-ledger.md" \
  --matrix "$scratch/stale-matrix.json" --now "2026-08-26T12:00:00Z" >"$scratch/stale.json"
stale_rc=$?
set -e
[[ "$stale_rc" == "1" ]] || fail "stale queued must make join exit 1, got $stale_rc"
jq -e '.stale_queued | length == 1' "$scratch/stale.json" >/dev/null \
  || fail "stale queued not reported: $(cat "$scratch/stale.json")"
ok "join: queued older than 7 days is a violation"

# --- duplicate source fails validate ----------------------------------------
cat >"$scratch/bad-duplicate.json" <<'EOF'
{
  "queued_stale_days": 7,
  "auto_file_cap_per_tick": 5,
  "rules": [
    {
      "id": "led-2026-08-27-top-gear-everywhere-non-negotiable",
      "source": "decisions-ledger.md: 2026-08-27 | TOP GEAR everywhere, non-negotiable",
      "mechanism": "Mechanism issue auto-filed by fleet-escalation-canary; implement the enforcer and flip to enforced",
      "proof": "Nishfleet/fleet-ops#479",
      "status": "queued(#479)",
      "queued_since": "2026-08-27"
    },
    {
      "id": "led-top-gear-everywhere",
      "source": "decisions-ledger.md: 2026-08-27 | TOP GEAR everywhere, non-negotiable",
      "mechanism": "TOP GEAR invariant: deferral requires a named clock; merge-to-live <=5min event-driven; seat-recovery fires intake instantly",
      "proof": "fleet-ops #468",
      "status": "enforced"
    }
  ]
}
EOF
set +e
python3 "$lib" validate-matrix --matrix "$scratch/bad-duplicate.json" >/dev/null 2>"$scratch/bad-dup.err"
dup_rc=$?
set -e
[[ "$dup_rc" == "1" ]] || fail "duplicate source must fail validate, got rc=$dup_rc"
grep -q 'duplicate source' "$scratch/bad-dup.err" \
  || fail "duplicate source error must name the source: $(cat "$scratch/bad-dup.err")"
ok "validate-matrix: duplicate source is rejected"

# --- advisory without reason fails validate ---------------------------------
cat >"$scratch/bad-advisory.json" <<'EOF'
{
  "queued_stale_days": 7,
  "auto_file_cap_per_tick": 5,
  "rules": [
    {
      "id": "sr-x",
      "source": "global-standing-rules.md: X",
      "mechanism": "none",
      "proof": "n/a",
      "status": "advisory()"
    }
  ]
}
EOF
set +e
python3 "$lib" validate-matrix --matrix "$scratch/bad-advisory.json" >/dev/null 2>"$scratch/bad-adv.err"
adv_rc=$?
set -e
[[ "$adv_rc" == "1" ]] || fail "empty advisory reason must fail validate"
ok "validate-matrix: advisory() without a reason is rejected"

# ============================================================================
# Drill: extra ## heading -> canary flags it AND auto-files an issue
# ============================================================================
drill="$scratch/drill"
mkdir -p "$drill/home" "$drill/repo/bin" "$drill/repo/config" \
         "$drill/repo/.github/workflows" "$drill/state" "$drill/onf" "$drill/fakebin"
cp "$canary" "$drill/repo/bin/fleet-escalation-canary"
chmod +x "$drill/repo/bin/fleet-escalation-canary"

cat >"$drill/repo/.github/workflows/auto-revert.yml" <<'WF'
on:
  workflow_run:
    workflows: ["CI"]
WF
cat >"$drill/repo/.github/workflows/red-on-main-detector.yml" <<'WF'
on:
  workflow_call:
WF

cat >"$drill/standing.md" <<'EOF'
# fixture
## Covered fixture rule (Nish, 2026-08-26)
## Untracked fixture rule that must scream (Nish, 2026-08-26)
## Queued fixture rule waiting for a mechanism (Nish, 2026-08-26)
EOF
cat >"$drill/ledger.md" <<'EOF'
- 2026-08-26 | covered ledger rule | a decision
- 2026-08-26 | untracked ledger rule that must scream | a decision
EOF
cat >"$drill/repo/config/rule-enforcement.json" <<'EOF'
{
  "queued_stale_days": 7,
  "auto_file_cap_per_tick": 5,
  "rules": [
    {
      "id": "sr-covered-fixture",
      "source": "global-standing-rules.md: Covered fixture rule (Nish, 2026-08-26)",
      "mechanism": "test gate",
      "proof": "tests/rule-enforcement.test.sh",
      "status": "enforced"
    },
    {
      "id": "led-covered-fixture",
      "source": "decisions-ledger.md: 2026-08-26 | covered ledger rule",
      "mechanism": "test gate",
      "proof": "tests/rule-enforcement.test.sh",
      "status": "enforced"
    },
    {
      "id": "sr-queued-fixture",
      "source": "global-standing-rules.md: Queued fixture rule waiting for a mechanism (Nish, 2026-08-26)",
      "mechanism": "not yet",
      "proof": "fleet-ops#1",
      "status": "queued(#1)",
      "queued_since": "2026-08-26"
    }
  ]
}
EOF

printf '%s\n' "good-worker.service" >"$drill/loaded"
printf 'unit-escalation@good-worker.service.service\n' >"$drill/onf/good-worker.service"
printf '{"repos":[{"name":"0509"}],"excluded":[]}' >"$drill/repo/config/intake-repos.json"
printf '{"claim_repos":["Nishfleet/0509"]}' >"$drill/state/fleet-repos.json"
: >"$drill/state/.escalation-delivery"
: >"$drill/state/.red-ci-ownerless-guard"
: >"$drill/state/.red-check-senior-auditor-bridge"
: >"$drill/triage.md"

cat >"$drill/systemctl" <<'FAKE'
#!/usr/bin/env bash
shift
cmd="$1"; shift
case "$cmd" in
  list-units)
    printf 'good-worker.service loaded active running -\n'
    exit 0
    ;;
  show)
    printf 'unit-escalation@good-worker.service.service\n'
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
FAKE
chmod +x "$drill/systemctl"

cat >"$drill/fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
log="${GH_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$log"
subcmd="${1:-}"
shift || true
case "$subcmd" in
  issue)
    case "${1:-}" in
      list)
        if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
          cat "${GH_OPEN_ISSUES}"
        else
          printf '[]\n'
        fi
        ;;
      create)
        echo "https://github.com/Nishfleet/fleet-ops/issues/4242"
        echo create >>"${GH_CREATED:-/dev/null}"
        ;;
      view)
        # Replay comments from GH_OPEN_ISSUES for the requested number.
        num=""
        for arg in "$@"; do
          case "$arg" in
            [0-9]*) num="$arg"; break ;;
          esac
        done
        if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" && -n "$num" ]]; then
          jq -c --argjson n "$num" '.[] | select(.number == $n)' "${GH_OPEN_ISSUES}" \
            | jq -c '{comments: (.comments // [])}' \
            || printf '{"comments":[]}\n'
        else
          printf '{"comments":[]}\n'
        fi
        ;;
      comment)
        num=""
        for arg in "$@"; do
          case "$arg" in
            [0-9]*) num="$arg"; break ;;
          esac
        done
        if [[ -n "${GH_COMMENTED:-}" && "${GH_COMMENTED}" != "/dev/null" ]]; then
          printf '%s\n' "$num" >>"$GH_COMMENTED"
        fi
        echo "https://github.com/Nishfleet/fleet-ops/issues/${num}#comment"
        ;;
      close)
        num=""
        for arg in "$@"; do
          case "$arg" in
            [0-9]*) num="$arg"; break ;;
          esac
        done
        if [[ -n "${GH_CLOSED:-}" && "${GH_CLOSED}" != "/dev/null" ]]; then
          printf '%s\n' "$num" >>"$GH_CLOSED"
        fi
        ;;
    esac
    ;;
esac
exit 0
FAKE_GH
chmod +x "$drill/fakebin/gh"

created="$drill/created.txt"
: >"$created"
glog="$drill/gh.log"
: >"$glog"

run_drill() {
  set +e
  env_out=$(
    HOME="$drill/home" \
    SYSTEMCTL="$drill/systemctl" \
    GH="$drill/fakebin/gh" \
    PATH="$drill/fakebin:$PATH" \
    FLEET_OPS_REPO="$drill/repo" \
    FLEET_HEARTBEAT_TRIAGE="$drill/triage.md" \
    AGENT_STATE="$drill/state" \
    FLEET_ESCALATION_CANARY_DELIVERY="$drill/state/.escalation-delivery" \
    FLEET_ESCALATION_CANARY_REDCI="$drill/state/.red-ci-ownerless-guard" \
    FLEET_ESCALATION_CANARY_BRIDGE="$drill/state/.red-check-senior-auditor-bridge" \
    FLEET_INTAKE_REPOS_JSON="$drill/repo/config/intake-repos.json" \
    FLEET_REDPR_REPOS_JSON="$drill/state/fleet-repos.json" \
    FLEET_STANDING_RULES="$drill/standing.md" \
    FLEET_DECISIONS_LEDGER="$drill/ledger.md" \
    FLEET_RULE_ENFORCEMENT_JSON="$drill/repo/config/rule-enforcement.json" \
    FLEET_RULE_ENFORCEMENT_LIB="$lib" \
    FLEET_RULE_ENFORCEMENT_FILE_ISSUES=1 \
    FLEET_RULE_ENFORCEMENT_ISSUE_REPO="Nishfleet/fleet-ops" \
    FLEET_RULE_ENFORCEMENT_UMBRELLA_ISSUES=1 \
    FLEET_RULE_ENFORCEMENT_NOW="2026-08-26T12:00:00Z" \
    GH_LOG="$glog" \
    GH_CREATED="$created" \
    GH_COMMENTED="${GH_COMMENTED:-/dev/null}" \
    GH_CLOSED="${GH_CLOSED:-/dev/null}" \
    GH_OPEN_ISSUES="${GH_OPEN_ISSUES:-}" \
    FLEET_ESCALATION_CANARY_SKIP_BACKUP="${FLEET_ESCALATION_CANARY_SKIP_BACKUP:-0}" \
    FLEET_ESCALATION_CANARY_SKIP_VAULT_CONFLICT="${FLEET_ESCALATION_CANARY_SKIP_VAULT_CONFLICT:-0}" \
    FLEET_ESCALATION_CANARY_SKIP_PRIVACY_GUARD=1 \
    "$canary" 2>&1
  )
  env_rc=$?
  set -e
}

run_drill

[[ "$env_rc" == "1" ]] || fail "drill: canary must exit 1, got $env_rc ($env_out)"
grep -q 'Untracked fixture rule that must scream' "$drill/triage.md" \
  || fail "drill: triage must name the untracked heading"
grep -q 'untracked ledger rule that must scream' "$drill/triage.md" \
  || fail "drill: triage must name the untracked ledger entry (fleet-ops#474)"
grep -q 'ESCALATION-CANARY-VIOLATION' "$drill/triage.md" \
  || fail "drill: triage missing VIOLATION"
create_count=$(grep -c create "$created" 2>/dev/null || echo 0)
[[ "$create_count" == "3" ]] || fail "drill: expected 3 gh issue create calls (uncovered standing + uncovered ledger + queued), got $create_count (log=$(cat "$glog"))"
grep -q 'FILED' <<<"$env_out" || fail "drill: canary must log FILED (out=$env_out)"
ok "drill: extra heading, uncovered ledger entry, and queued row are flagged and auto-filed"

# Replay: open issue with the signal key -> no second create for either.
printf '%s\n' '[{"number":77,"title":"already","body":"signal: rule-enforcement/sr-untracked-fixture-rule-that-must-scream-nish-2026-08-26"},{"number":79,"title":"ledger","body":"signal: rule-enforcement/led-2026-08-26-untracked-ledger-rule-that-must-scream"},{"number":78,"title":"queued","body":"signal: rule-enforcement/sr-queued-fixture"}]' \
  >"$drill/open.json"
: >"$created"
: >"$drill/triage.md"
export GH_OPEN_ISSUES="$drill/open.json"
run_drill
[[ "$env_rc" == "1" ]] || fail "dedupe replay: still a coverage violation, must exit 1"
if grep -q create "$created"; then
  fail "dedupe replay: must not file a second issue"
fi
grep -q 'already has an open mechanism issue' <<<"$env_out" \
  || fail "dedupe replay: must log deduped (out=$env_out)"
ok "drill: open issue with signal key is deduped"

# Observe-to-close (fleet-ops#479): a fully covered vault + an open
# mechanism issue filed under the fallback signal must get a canary comment,
# even when the matrix id differs from the auto-file id. Replay with the
# marker already in comments must not comment twice.
cat >"$drill/standing.md" <<'EOF'
# fixture
## Covered fixture rule (Nish, 2026-08-26)
## Queued fixture rule waiting for a mechanism (Nish, 2026-08-26)
EOF
cat >"$drill/ledger.md" <<'EOF'
- 2026-08-26 | covered ledger rule | a decision
EOF
: >"$created"
: >"$drill/triage.md"
commented="$drill/commented.txt"
: >"$commented"
printf '%s\n' '[{"number":479,"title":"mechanism for TOP GEAR","body":"- source: `decisions-ledger.md: 2026-08-26 | covered ledger rule`\n\nsignal: rule-enforcement/led-2026-08-26-covered-ledger-rule","comments":[]},{"number":78,"title":"queued","body":"signal: rule-enforcement/sr-queued-fixture"}]' \
  >"$drill/open.json"
export GH_OPEN_ISSUES="$drill/open.json"
export GH_COMMENTED="$commented"
export FLEET_ESCALATION_CANARY_SKIP_BACKUP=1
export FLEET_ESCALATION_CANARY_SKIP_VAULT_CONFLICT=1
run_drill
[[ "$env_rc" == "0" ]] || fail "observe-to-close: canary must exit 0 when covered (rc=$env_rc out=$env_out)"
if grep -q create "$created"; then
  fail "observe-to-close: must not file a new issue when the source is covered"
fi
grep -q '^479$' "$commented" || fail "observe-to-close: must comment on #479 (commented=$(cat "$commented") out=$env_out)"
grep -q 'OBSERVED-COVERED' <<<"$env_out" || fail "observe-to-close: must log OBSERVED-COVERED (out=$env_out)"
ok "drill: enforced coverage comments on the fallback-signal mechanism issue"

: >"$commented"
: >"$drill/triage.md"
closed="$drill/closed.txt"
: >"$closed"
export GH_CLOSED="$closed"
printf '%s\n' '[{"number":479,"title":"mechanism for TOP GEAR","body":"- source: `decisions-ledger.md: 2026-08-26 | covered ledger rule`\n\nsignal: rule-enforcement/led-2026-08-26-covered-ledger-rule","comments":[{"body":"canary-covered: decisions-ledger.md: 2026-08-26 | covered ledger rule\n"}]},{"number":78,"title":"queued","body":"signal: rule-enforcement/sr-queued-fixture"}]' \
  >"$drill/open.json"
run_drill
[[ "$env_rc" == "0" ]] || fail "observe replay: canary must stay exit 0 (rc=$env_rc out=$env_out)"
if grep -q create "$created"; then
  fail "observe replay: must not file"
fi
if grep -q . "$commented"; then
  fail "observe replay: must not comment again (commented=$(cat "$commented") out=$env_out)"
fi
# Observe-to-close close step (fleet-ops#521): #479 carries the canary-covered
# marker AND its rule is enforced -> the canary closes it as completed. #78 is
# a queued row (no enforced coverage) -> must NOT be closed.
grep -q '^479$' "$closed" || fail "observe-to-close close: must close #479 (closed=$(cat "$closed") out=$env_out)"
! grep -q '^78$' "$closed" || fail "observe-to-close close: must NOT close queued #78 (closed=$(cat "$closed"))"
grep -q 'OBSERVE-CLOSED' <<<"$env_out" || fail "observe-to-close close: must log OBSERVE-CLOSED (out=$env_out)"
ok "drill: canary-covered marker is not posted twice"
ok "drill: observe-to-close closes #479 (marker + enforced); queued #78 stays open"

# fleet-ops#519: run the no-agent-names gate drill as part of the
# rule-enforcement suite so it is exercised in CI without a workflow edit.
bash "$here/fleet-no-agent-names.test.sh" || fail "no-agent-names gate drill failed"
ok "rule-enforcement: no-agent-names gate drill"

# fleet-ops#926: hosted-runner rev-range class gate. Nested host so the
# worker token does not need a workflow edit.
bash "$here/ci-hosted-paths.test.sh" || fail "ci-hosted-paths class gate failed"
ok "rule-enforcement: ci-hosted-paths class gate"

# fleet-ops#529: conflict-file canary. Invoked from this CI-listed file so
# hosted runners run it without a workflow edit (worker tokens cannot push
# .github/workflows/**).
bash "$here/vault-conflict-resolver.test.sh" || fail "vault-conflict-resolver drill failed"
ok "rule-enforcement: vault-conflict-resolver drill"

# fleet-ops#1264: vault snapshot lint. Nested host so P14 covers it
# without a workflow edit (worker tokens cannot push .github/workflows/**).
bash "$here/vault-lint.test.sh" || fail "vault-lint drill failed"
ok "rule-enforcement: vault-lint drill"

# fleet-ops#1265: paved-road vault capture. Nested host so P14 covers it
# without a workflow edit (worker tokens cannot push .github/workflows/**).
bash "$here/vault-capture.test.sh" || fail "vault-capture drill failed"
ok "rule-enforcement: vault-capture drill"

# fleet-ops#533: argv[0] + push-before-delete + FLEET-PAUSED. Same
# nested-CI host so this token does not need a workflow edit.
bash "$here/fleet-wipe-lessons.test.sh" || fail "fleet-wipe-lessons gate drill failed"
ok "rule-enforcement: fleet-wipe-lessons gate drill"

# fleet-ops#787: dirty-worktree-audit shares the "is HEAD on origin"
# classification with fleet-wipe-lessons (see its docstring). Host it from
# the same nested-CI file so P14 covers it without a workflow edit.
bash "$here/dirty-worktree-audit.test.sh" || fail "dirty-worktree-audit drill failed"
ok "rule-enforcement: dirty-worktree-audit drill"

# fleet-ops#459: NORTH STAR quality guard. Nested host so the worker token
# does not need to edit .github/workflows/**.
bash "$here/north-star-quality.test.sh" || fail "north-star-quality gate drill failed"
ok "rule-enforcement: north-star-quality gate drill"

# fleet-ops#462: ClinePass GLM 5.3 flash canary. Same nested-CI host so
# this token does not need a workflow edit.
bash "$here/fleet-cline-glm53-canary.test.sh" || fail "cline glm53 canary drill failed"
ok "rule-enforcement: ClinePass GLM 5.3 flash canary drill"

# fleet-ops#542: repo-visibility canary. Nested host so the worker token
# does not need to edit .github/workflows/**.
bash "$here/fleet-repo-visibility-canary.test.sh" || fail "repo-visibility canary drill failed"
ok "rule-enforcement: repo-visibility canary drill"

# fleet-ops#546: straitly ds4-pro worker-rotation canary. Same nested-CI host.
bash "$here/fleet-straitly-ds4-pro-canary.test.sh" || fail "straitly ds4-pro canary drill failed"
ok "rule-enforcement: straitly ds4-pro canary drill"

# fleet-ops#537: execution-is-review receipt canary. Same nested-CI host.
bash "$here/fleet-exec-review-canary.test.sh" || fail "exec-review receipt canary drill failed"
ok "rule-enforcement: exec-review receipt canary drill"

# fleet-ops#525: vault knowledge-format lint timer. Nested host so the worker
# token does not need to edit .github/workflows/**.
bash "$here/fleet-vault-knowledge-format.test.sh" || fail "vault knowledge-format drill failed"
ok "rule-enforcement: vault knowledge-format drill"

# fleet-ops#539: shared-file collision PreToolUse guard. Nested host so the
# worker token does not need to edit .github/workflows/**.
bash "$here/guard-shared-file-collision.test.sh" || fail "shared-file collision guard drill failed"
ok "rule-enforcement: shared-file collision guard drill"

# fleet-ops#540: 24h/12h work-supply drain trigger. Nested host so the worker
# token does not need to edit .github/workflows/**.
bash "$here/fleet-work-supply-canary.test.sh" || fail "work-supply canary drill failed"
ok "rule-enforcement: work-supply 24h/12h drain canary drill"

# fleet-ops#545: CommandCode MiniMax M3 fail-closed catalog canary. Nested
# host so the worker token does not need to edit .github/workflows/**.
bash "$here/opencode-m3-catalog-canary.test.sh" || fail "opencode-m3 catalog canary drill failed"
ok "rule-enforcement: opencode/commandcode MiniMax M3 catalog canary drill"

# fleet-ops#541: weekly continuous-research sweep. Nested host so the
# worker token does not need to edit .github/workflows/**.
bash "$here/quality-research-weekly.test.sh" || fail "quality-research-weekly drill failed"
ok "rule-enforcement: quality-research-weekly drill"

# fleet-ops#1146: Weekly Fleet Review (WFR) — blind 6-lens senior research
# + conference, output capped at 5 specced actions. Nested host so this
# token does not need a workflow edit.
bash "$here/weekly-fleet-review.test.sh" || fail "weekly-fleet-review drill failed"
ok "rule-enforcement: weekly-fleet-review drill"

# fleet-ops#1236: weekly AEO visibility probe. Nested host so this token
# does not need a workflow edit.
bash "$here/aeo-probe.test.sh" || fail "aeo-probe drill failed"
ok "rule-enforcement: aeo-probe drill"

# fleet-ops#544: VPS→Mac Tailscale lockdown canary. Same nested-CI host so
# this token does not need a workflow edit.
bash "$here/fleet-tailscale-acl-canary.test.sh" || fail "tailscale ACL lockdown canary drill failed"
ok "rule-enforcement: Tailscale ACL lockdown canary drill"

# fleet-ops#524: per-repo verification harness canary. Nested host so the
# worker token does not need to edit .github/workflows/**.
bash "$here/fleet-verify-harness-canary.test.sh" || fail "verify-harness canary drill failed"
ok "rule-enforcement: verify-harness canary drill"

# fleet-ops#545: paid-flash watcher. Named in led-worker-lane-refresh
# proof fields, hosted here so the worker token does not need a workflow
# edit (fleet-ops#660 — fleet-free-roster-canary was already wired by
# #800 under fleet-ops#634).
bash "$here/paid-flash-canary.test.sh" || fail "paid-flash-canary drill failed"
ok "rule-enforcement: paid-flash canary drill"

# fleet-ops#1176: token economy rebalance seat-cap drill. Nested host so
# the worker token does not need to edit .github/workflows/**.
bash "$here/fleet-token-economy.test.sh" || fail "token economy canary drill failed"
ok "rule-enforcement: token economy canary drill"

# fleet-ops#1152: standing-rules drift gate. The generator that renders the
# canonical standing rules into CLAUDE.md/AGENTS.md is only a gate if its
# drift test actually runs; nested host so the worker token does not need
# to edit .github/workflows/**.
bash "$here/standing-rules-drift.test.sh" || fail "standing-rules drift drill failed"
ok "rule-enforcement: standing-rules drift drill"

# fleet-ops#1010: organ-heartbeat invariant. Every fleet organ ships an
# absent() rule in the same PR; the registry enumerates the known organs and
# the gate rejects a PR that touches an organ without its absent() rule.
# Nested host so the worker token does not need to edit .github/workflows/**.
bash "$here/fleet-organ-heartbeat.test.sh" || fail "organ-heartbeat drill failed"
ok "rule-enforcement: organ-heartbeat drill"

# fleet-ops#1149: asset census and guard-mapping canary. Nested host so
# the worker token does not need to edit .github/workflows/**.
bash "$here/fleet-asset-census.test.sh" || fail "asset census drill failed"
ok "rule-enforcement: asset census and guard-mapping drill"

# fleet-ops#1460: timer manifest shape lock (every user timer has a
# named-reason manifest entry). Nested host so the worker token does
# not need to edit .github/workflows/**.
bash "$here/timer-manifest.test.sh" || fail "timer-manifest drill failed"
ok "rule-enforcement: timer-manifest shape lock drill"

# fleet-ops#543: agent-ready spec-gate. Nested host so the worker token
# does not need to edit .github/workflows/**.
bash "$here/agent-ready-spec-gate.test.sh" || fail "agent-ready spec-gate drill failed"
ok "rule-enforcement: agent-ready spec-gate drill"

# fleet-ops#1464: gh-webhook receiver prom-quote regression. Nested host
# so the worker token does not need a workflow edit.
bash "$here/gh-webhook-receiver-prom-quotes.test.sh" || fail "gh-webhook receiver prom-quotes drill failed"
ok "rule-enforcement: gh-webhook receiver prom-quotes drill"

# fleet-ops#1558: per-repo worker memory drop-ins. Nested host so the worker
# token does not need a workflow edit.
bash "$here/worker-memory-dropin.test.sh" || fail "worker-memory drop-in drill failed"
ok "rule-enforcement: worker-memory drop-in drill"

# fleet-ops#????: siterep live canary pin wrapper. Nested host so the worker
# token does not need a workflow edit.
bash "$here/siterep-live-canary-pin.test.sh" || fail "siterep live canary pin drill failed"
ok "rule-enforcement: siterep live canary pin drill"

ok "rule-enforcement: matrix, join, stale queued, advisory, auto-file, observe-to-close, no-agent-names, vault-conflict, vault-lint, wipe-lessons, dirty-worktree-audit, north-star-quality, cline-glm53, repo-visibility, straitly-ds4-pro, exec-review, vault-knowledge-format, shared-file-collision, work-supply-24h, opencode-m3 catalog, quality-research-weekly, tailscale-acl, verify-harness, paid-flash, token-economy, volume-lane-order, geo-aeo, quality-ratchet, standing-rules-drift, aeo-probe, organ-heartbeat, asset-census, timer-manifest, agent-ready-spec-gate, gh-webhook-prom-quotes, worker-memory-dropin, and siterep-live-canary-pin drills"

# fleet-ops#516: sr-max-speed hunter. CI lists this file, not
# fleet-max-speed.test.sh (workers cannot edit .github/workflows).
bash "$here/fleet-max-speed.test.sh" || fail "fleet-max-speed tests failed"

# fleet-ops#523: token-efficiency PR gate for prompt assemblers. Nested
# host so the worker token does not need to edit .github/workflows/**.
bash "$here/fleet-token-efficiency.test.sh" || fail "token-efficiency gate drill failed"
ok "rule-enforcement: token-efficiency gate drill"
# fleet-ops#527: monthly rulebook red-team + rollback-backup gate. Same
# CI constraint (worker token cannot add a P14 line in ci.yml).
bash "$here/fleet-rulebook-redteam.test.sh" || fail "rulebook red-team drill failed"
ok "rule-enforcement: rulebook red-team drill"

# fleet-ops#538: "never decide by vibes — always measure" canary. Same
# nested-CI host so the worker token does not need a workflow edit.
bash "$here/fleet-vibes-canary.test.sh" || fail "vibes canary drill failed"
ok "rule-enforcement: vibes canary drill"

# fleet-ops#532: skills-native canary (sr-skills-native). Same nested-CI
# host so the worker token does not need a workflow edit.
bash "$here/skills-symlink-canary.test.sh" || fail "skills-symlink canary drill failed"
ok "rule-enforcement: skills-symlink canary drill"

ok "rule-enforcement: matrix, join, stale queued, advisory, auto-file, observe-to-close, no-agent-names, vault-conflict, rulebook-redteam, vibes, and skills-symlink drills"
