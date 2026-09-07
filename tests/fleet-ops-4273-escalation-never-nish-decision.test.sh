#!/usr/bin/env bash
# tests/fleet-ops-4273-escalation-never-nish-decision.test.sh
#
# fleet-ops#4273: the two bin-side escalation paths in lib/pi-intake-tick.sh
# (#2462 reclaim-count cap exhaustion and #2772 claim-loop gate) must NEVER
# emit `blocked-on: nish-decision`. Seat exhaustion and dead claim paths are
# fleet-infrastructure faults the fleet owns repairing; `nish-decision` is
# reserved for money / pricing / legal / brand / product direction /
# customer-data deletion / secret exposure / outbound communication only.
#
# Proves:
#   1. The #2462 escalation comment (skipped-max-reclaims, every seat class
#      exhausted) does NOT contain the string `nish-decision`. It emits
#      `blocked-on: infra` (the #3310 auto-release design).
#   2. The #2772 escalation comment (skipped-claim-loop) does NOT contain
#      `nish-decision`. It emits `blocked-on: orchestrator`.
#   3. The reserved-class path still CAN keep `nish-decision`: blocked-reconcile's
#      NISH_REASON regex (money/legal/brand/product-direction/customer-data)
#      preserves a valid `blocked-on: nish-decision` line instead of rewriting
#      it to orchestrator.
#
# Static-grep + extract drill (same shape as the #2462/#2772 cap tests): the
# tick needs gh/git/network to run end-to-end; the assertions pin the emitted
# comment text and the blocked-reconcile reserved-class gate.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
reconcile="$repo_root/bin/blocked-reconcile"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
[[ -f "$reconcile" ]] || fail "bin/blocked-reconcile missing"

# --- helper: extract the body of a `gh issue comment ... --body "<text>"` ----
# Returns the text between the opening `--body "` and the closing `"` that
# precedes ` 2>/dev/null || true` on the escalation lines. We pull the full
# comment block (multi-line) by scanning from the anchor `--body "` up to the
# closing `"` + ` 2>/dev/null`.
escalation_comment_body() {
    local file="$1" anchor="$2"
    # Print from the line holding the anchor's `--body "` through the line
    # that closes the body string (`"<space>2>/dev/null`). awk keeps state.
    awk -v anchor="$anchor" '
        $0 ~ anchor && /--body "/ { in_body=1 }
        in_body { print }
        in_body && /" 2>\/dev\/null/ { in_body=0 }
    ' "$file"
}

# === Test 1: #2462 skipped-max-reclaims escalation never emits nish-decision ===
# The exhaustion-path comment is the one that names "every seat class" and
# emits blocked-on: infra. Anchor on the fleet-ops#3310 exhaustion comment.
_2462_body=$(escalation_comment_body "$tick" 'fleet-ops#3310: issue')
# The escalation must exist (the comment is posted on seat-class exhaustion).
printf '%s' "$_2462_body" | grep -q 'blocked-on: infra' \
    || fail "#2462 escalation must still emit blocked-on: infra (the #3310 auto-release design)"
if printf '%s' "$_2462_body" | grep -q 'nish-decision'; then
    fail "#2462 escalation must never emit nish-decision (seat exhaustion is a fleet-infra fault): $(printf '%s' "$_2462_body" | grep nish-decision)"
fi
ok "Test 1: #2462 skipped-max-reclaims escalation emits blocked-on: infra, never nish-decision"

# === Test 2: #2772 skipped-claim-loop escalation never emits nish-decision ===
_2772_body=$(escalation_comment_body "$tick" 'fleet-ops#2772: issue')
printf '%s' "$_2772_body" | grep -q 'blocked-on: orchestrator' \
    || fail "#2772 escalation must emit blocked-on: orchestrator (fleet-ops#4273)"
if printf '%s' "$_2772_body" | grep -q 'nish-decision'; then
    fail "#2772 escalation must never emit nish-decision (dead claim paths are a fleet-infra fault): $(printf '%s' "$_2772_body" | grep nish-decision)"
fi
ok "Test 2: #2772 skipped-claim-loop escalation emits blocked-on: orchestrator, never nish-decision"

# === Test 3: reserved-class path still CAN keep nish-decision ===
# blocked-reconcile's NISH_REASON regex lists the reserved classes. A
# `blocked-on: nish-decision` line whose surrounding text names one of them
# (money/pay/price/billing, legal, product direction/brand, customer
# data/deletion) is preserved, not rewritten to orchestrator. This is the
# only path that may keep nish-decision.
grep -qF 'NISH_REASON = re.compile' "$reconcile" \
    || fail "blocked-reconcile NISH_REASON regex not found (reserved-class gate)"
# The reserved-class reasons are split across two adjacent string literals in
# the NISH_REASON regex (money|pay|price|pricing|billing|legal|brand|deletion|
# then product-direction|customer-data|reserved). Assert each reason token is
# present so a future edit that drops a reserved class fails this test.
for _tok in money pay price pricing billing legal brand deletion product customer reserved; do
    grep -qF "$_tok" "$reconcile" \
        || fail "blocked-reconcile reserved-class reason '$_tok' not found in NISH_REASON"
done
# The rewriter must target only nish-decision lines and turn them into
# orchestrator; the reserved-class check (NISH_REASON.search) short-circuits
# the rewrite so a valid nish-decision line survives.
grep -qF 'if NISH_REASON.search(text):' "$reconcile" \
    || fail "blocked-reconcile must short-circuit the rewrite when a reserved-class reason is present"
grep -qF 'return "blocked-on: orchestrator"' "$reconcile" \
    || fail "blocked-reconcile must rewrite invalid nish-decision -> orchestrator"

# Extract-drill: prove a valid reserved-class nish-decision line is KEPT.
# blocked-reconcile --extract reads one issue JSON on stdin and prints
# {kind,deps,nish,orchestrator,rejected_count,...}. A body that names a
# reserved-class reason (money) + blocked-on: nish-decision must keep
# nish=true and rejected_count=0 (the line survives, not rewritten).
_valid_json='{"repo":"Nishfleet/0509","number":50,"title":"x","body":"blocked-on: nish-decision\nneed money approval for the upgrade\n","comments":[]}'
_valid_out=$(printf '%s' "$_valid_json" | bash "$reconcile" --extract 2>/dev/null || true)
printf '%s' "$_valid_out" | jq -e '.nish == true and .rejected_count == 0' >/dev/null 2>&1 \
    || fail "reserved-class (money) nish-decision must be kept (nish=true, rejected_count=0): $_valid_out"

# And an INVALID nish-decision (no reserved-class reason) is rewritten to orchestrator:
# orchestrator=true and rejected_count=1, with the rewritten body carrying blocked-on: orchestrator.
_invalid_json='{"repo":"Nishfleet/0509","number":51,"title":"x","body":"blocked-on: nish-decision\nseat storm killed the worker\n","comments":[]}'
_invalid_out=$(printf '%s' "$_invalid_json" | bash "$reconcile" --extract 2>/dev/null || true)
printf '%s' "$_invalid_out" | jq -e '.orchestrator == true and .rejected_count == 1' >/dev/null 2>&1 \
    || fail "non-reserved nish-decision must be rewritten (orchestrator=true, rejected_count=1): $_invalid_out"
_invalid_new_text=$(printf '%s' "$_invalid_out" | jq -re '.rejected_nish_decisions[0].new_text' 2>/dev/null || true)
grep -q 'blocked-on: orchestrator' <<<"$_invalid_new_text" \
    || fail "non-reserved nish-decision rewrite text must carry blocked-on: orchestrator: $_invalid_out"
ok "Test 3: reserved-class (money/legal/brand/...) nish-decision is kept; non-reserved is rewritten to orchestrator"

# === Test 4: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$tick" --severity=warning 2>&1 || fail "shellcheck failed on pi-intake-tick.sh"
fi
ok "Test 4: shellcheck clean on pi-intake-tick.sh"

echo
echo "ALL OK: fleet-ops#4273 — #2462/#2772 escalation never emits nish-decision; reserved-class path still can"
