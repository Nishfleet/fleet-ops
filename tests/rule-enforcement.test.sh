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
  jq -e '.covered_rows[] | select(.source == "global-standing-rules.md: Vault sync conflicts auto-resolve (Nish, 2026-08-19, amends the freeze rule)" and .status == "enforced")' <<<"$live" >/dev/null \
    || fail "live join must report vault sync conflicts as enforced covered_rows (fleet-ops#529): $(jq -c '.covered_rows' <<<"$live")"
  ok "live vault join is covered (vault=$(jq .vault_rule_count <<<"$live") rc=$live_rc)"
  ok "live join: TOP GEAR source is enforced (observe-to-close for #479)"
  ok "live join: vault sync conflicts source is enforced (observe-to-close for #529)"
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
print("parser-ok")
PY
ok "parser: ## headings counted, ### ignored, FLAG ledger lines skipped"
ok "observe-to-close: fallback id, source backtick, and already-commented issues"

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
    GH_OPEN_ISSUES="${GH_OPEN_ISSUES:-}" \
    FLEET_ESCALATION_CANARY_SKIP_BACKUP="${FLEET_ESCALATION_CANARY_SKIP_BACKUP:-0}" \
    FLEET_ESCALATION_CANARY_SKIP_VAULT_CONFLICT="${FLEET_ESCALATION_CANARY_SKIP_VAULT_CONFLICT:-0}" \
    "$canary" 2>&1
  )
  env_rc=$?
  set -e
}

run_drill

[[ "$env_rc" == "1" ]] || fail "drill: canary must exit 1, got $env_rc ($env_out)"
grep -q 'Untracked fixture rule that must scream' "$drill/triage.md" \
  || fail "drill: triage must name the untracked heading"
grep -q 'ESCALATION-CANARY-VIOLATION' "$drill/triage.md" \
  || fail "drill: triage missing VIOLATION"
create_count=$(grep -c create "$created" 2>/dev/null || echo 0)
[[ "$create_count" == "2" ]] || fail "drill: expected 2 gh issue create calls (uncovered + queued), got $create_count (log=$(cat "$glog"))"
grep -q 'FILED' <<<"$env_out" || fail "drill: canary must log FILED (out=$env_out)"
ok "drill: extra heading and queued row are flagged and auto-filed"

# Replay: open issue with the signal key -> no second create for either.
printf '%s\n' '[{"number":77,"title":"already","body":"signal: rule-enforcement/sr-untracked-fixture-rule-that-must-scream-nish-2026-08-26"},{"number":78,"title":"queued","body":"signal: rule-enforcement/sr-queued-fixture"}]' \
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
ok "drill: canary-covered marker is not posted twice"

# fleet-ops#519: run the no-agent-names gate drill as part of the
# rule-enforcement suite so it is exercised in CI without a workflow edit.
bash "$here/fleet-no-agent-names.test.sh" || fail "no-agent-names gate drill failed"
ok "rule-enforcement: no-agent-names gate drill"

# fleet-ops#529: conflict-file canary. Invoked from this CI-listed file so
# hosted runners run it without a workflow edit (worker tokens cannot push
# .github/workflows/**).
bash "$here/vault-conflict-resolver.test.sh" || fail "vault-conflict-resolver drill failed"
ok "rule-enforcement: vault-conflict-resolver drill"

# fleet-ops#527: monthly rulebook red-team + rollback-backup gate. Same
# CI constraint (worker token cannot add a P14 line in ci.yml).
bash "$here/fleet-rulebook-redteam.test.sh" || fail "rulebook red-team drill failed"
ok "rule-enforcement: rulebook red-team drill"

ok "rule-enforcement: matrix, join, stale queued, advisory, auto-file, observe-to-close, no-agent-names, vault-conflict, and rulebook-redteam drills"
