#!/usr/bin/env bash
# tests/rules-parity.test.sh — fleet-ops#6476
#
# Pins the committed branch-rulesets snapshots under config/rules/ — the
# durable verification receipt for #6476's stage-1 adoption (non_fast_forward
# + deletion, landed by the authorized admin during the 2026-09-19 #7844
# rules sweep) and the fail-closed pin on the stage-2 residual
# (required_status_checks contexts = the #3652/#3653 consolidation outcome;
# settings are Nish-reserved via fleet-ops#7464 item 2/11, 2026-09-17 sweep).
#
# Offline by design: CI's default token cannot read branch rules (the
# Administration-scoped read), so the snapshots are refreshed by a read-only
# call under the worker token; the JSON payload is verified live against
# SHA-256 at refresh time and this test re-verifies the committed copy. The
# GitHub-side live procedure lives in config/rules/README.md. The test pins
# STRUCTURE and ROUTING: removing or adding a rule type in a snapshot can
# only pass by consciously clearing the documented residual line.
#
# Drills:
#   1. Both snapshots exist, parse, and carry receipt metadata
#      (endpoint, http_status, verified_at_utc, payload_sha256 that matches
#      the canonicalized rules array carried inside the file).
#   2. fleet-ops main carries the stage-1 pair (non_fast_forward + deletion)
#      plus the sweep's merge_queue and pull_request rules; merge_queue
#      parameters match the adopted shape (SQUASH, HEADGREEN, min 1, max 5
#      build entries).
#   3. 0509 main — the parity target — carries the four rules including
#      required_status_checks with the live context set (Gitleaks,
#      codex-node-checks, semgrep, preview-assert).
#   4. Stage-2 residual is pinned: the fleet-ops snapshot carries NO
#      required_status_checks rule, and README.md still marks the residual —
#      a snapshot update that lands the context rule must also clear the
#      line (fail-closed), else this test fails.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
rules_dir="$repo_root/config/rules"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v jq >/dev/null 2>&1 || fail "jq is required (jq-1.7 on the reference host)"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

fo="$rules_dir/fleet-ops-main.json"
ni="$rules_dir/0509-main.json"

[[ -f "$fo" ]] || fail "missing $fo (verification receipt for fleet-ops main)"
[[ -f "$ni" ]] || fail "missing $ni (0509 parity target snapshot)"
[[ -f "$rules_dir/README.md" ]] || fail "missing $rules_dir/README.md (refresh procedure + residual)"

# --- Drill 1: receipt metadata + internal payload hash ----------------------
for f in "$fo" "$ni"; do
  base="$(basename "$f")"
  jq -e '.endpoint | type == "string" and length > 0' "$f" >/dev/null \
    || fail "$base: .endpoint missing"
  jq -e '.http_status == 200' "$f" >/dev/null \
    || fail "$base: .http_status is not the recorded 200"
  # verified_at_utc must be an RFC3339 UTC timestamp
  jq -r '.verified_at_utc' "$f" | grep -Eq \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || fail "$base: .verified_at_utc is not an RFC3339 UTC timestamp"
  # the payload is self-verified: sha256 over the canonicalized rules array
  actual="$(jq -cS '.rules' "$f" | sha256sum | cut -d' ' -f1)"
  recorded="$(jq -r '.payload_sha256' "$f")"
  [[ "$actual" == "$recorded" ]] \
    || fail "$base: payload_sha256 mismatch (recorded $recorded, canonical $actual)"
  jq -e '.rules | type == "array" and length == 4' "$f" >/dev/null \
    || fail "$base: .rules must be the 4-rule array GitHub returned"
done
ok "drill 1: both snapshots parse and receipts verify (endpoint, 200, timestamp, payload sha256)"

# --- Drill 2: fleet-ops main shape ------------------------------------------
got="$(jq -cS '[.rules[].type] | unique' "$fo")"
want='["deletion","merge_queue","non_fast_forward","pull_request"]'
[[ "$got" == "$want" ]] \
  || fail "fleet-ops-main: rule types $got != adopted $want"
jq -e '.rules[] | select(.type=="non_fast_forward") and select(.ruleset_source=="Nishfleet/fleet-ops")' \
  "$fo" >/dev/null || fail "fleet-ops-main: stage-1 non_fast_forward rule missing/wrong source"
jq -e '.rules[] | select(.type=="deletion") and select(.ruleset_source=="Nishfleet/fleet-ops")' \
  "$fo" >/dev/null || fail "fleet-ops-main: stage-1 deletion rule missing/wrong source"
mq="$(jq -r '.rules[] | select(.type=="merge_queue") | .parameters' "$fo" 2>/dev/null)" \
  || fail "fleet-ops-main: exactly one merge_queue rule expected"
jq -e '.merge_method == "SQUASH" and .grouping_strategy == "HEADGREEN" and .max_entries_to_build == 5 and .min_entries_to_merge == 1' \
  <<<"$mq" >/dev/null \
  || fail "fleet-ops-main: merge_queue parameters drifted from the adopted shape (SQUASH/HEADGREEN/5/1)"
pr="$(jq -r '.rules[] | select(.type=="pull_request") | .parameters' "$fo" 2>/dev/null)" \
  || fail "fleet-ops-main: exactly one pull_request rule expected"
jq -e '.required_approving_review_count == 0' <<<"$pr" >/dev/null \
  || fail "fleet-ops-main: pull_request parameters drifted (worker auto-merge needs 0 approvals)"
ok "drill 2: fleet-ops main = stage-1 pair + merge_queue(SQUASH/HEADGREEN/5/1) + pull_request(0 approvals)"

# --- Drill 3: 0509 parity target --------------------------------------------
got="$(jq -cS '[.rules[].type] | unique' "$ni")"
want='["deletion","merge_queue","non_fast_forward","required_status_checks"]'
[[ "$got" == "$want" ]] \
  || fail "0509-main: rule types $got != parity target $want"
ctxs="$(jq -r '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context' "$ni" \
  | LC_ALL=C sort | tr '\n' ' ')"
[[ "${ctxs%% }" == "Gitleaks codex-node-checks preview-assert semgrep" ]] \
  || fail "0509-main: required contexts drifted from the live set ($ctxs)"
jq -e '.merge_method == "MERGE" and .grouping_strategy == "HEADGREEN"' \
  < <(jq -r '.rules[] | select(.type=="merge_queue") | .parameters' "$ni") >/dev/null \
  || fail "0509-main: merge_queue parameters drifted (MERGE/HEADGREEN)"
ok "drill 3: 0509 main carries the four-rule parity target with the live required contexts"

# --- Drill 4: stage-2 residual is pinned ------------------------------------
jq -e '[.rules[].type] | index("required_status_checks") | not' "$fo" >/dev/null \
  || fail "fleet-ops-main: required_status_checks landed in the snapshot — stage-2 done? \
Clear the residual line in config/rules/README.md in the SAME PR that refreshes the snapshot."
grep -q '# stage-2 residual:' "$rules_dir/README.md" \
  || fail "config/rules/README.md: the '# stage-2 residual:' marker line is gone; restore or record the stage-2 decision"
ok "drill 4: stage-2 residual pinned (no required_status_checks on fleet-ops; README marker present)"

ok "ALL PASS"
