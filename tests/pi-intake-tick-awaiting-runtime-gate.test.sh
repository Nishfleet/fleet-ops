#!/usr/bin/env bash
# tests/pi-intake-tick-awaiting-runtime-gate.test.sh
#
# fleet-ops#4540: the protected-merged slow-spaced reclaim spin. A protected
# (owner-authored or critical-path) OPEN issue whose delivery PR is already
# MERGED and whose body carries a `termination:` clause naming a future
# runtime event stays OPEN by design (observe-to-close is comment-only on
# protected issues, fleet-ops#1435), while every existing anti-loop gate
# misses the SLOW spin: MAX_RECLAIMS (#2462) resets on any non-empty-output
# run and the window gate (#2772) sees only ~3 claims per 2h at the 15-min
# cooldown spacing (< cap 4). Live case: #4460 re-claimed 9x in 9h after
# PR #4498 merged. This test pins the park detector contract:
#
#   1. PARK_MAX_CLAIMS env var is defined (overridable for tests).
#   2. A labelled issue is skipped cheaply (before the body fetch / network)
#      with skipped-awaiting-runtime-gate.
#   3. The detector counts CUMULATIVE (all-time) claims from the claims-log
#      snapshot, not windowed.
#   4. The detector requires: protected (critical-path label OR
#      nish3451-authored) AND a `termination:` clause AND a merged
#      claim-branch delivery PR — all three, else no park.
#   5. On trip: awaiting-runtime-gate label added, agent-ready removed,
#      a machine-readable comment posted, and the issue skipped.
#   6. The body fetch carries the author (needed for the owner-authored
#      protection check).
#   7. bin/fleet-merged-pr-close applies the same label when it posts the
#      protected observe-to-close note for a merged delivery PR.
#   8. shellcheck clean on both changed files.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
close_bin="$repo_root/bin/fleet-merged-pr-close"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"
[[ -f "$close_bin" ]] || fail "bin/fleet-merged-pr-close missing"

# === Test 1: PARK_MAX_CLAIMS env var defined ===
grep -qF 'PARK_MAX_CLAIMS="${PI_INTAKE_PARK_MAX_CLAIMS:-3}"' "$tick" \
    || fail "PARK_MAX_CLAIMS env var not found (must be overridable for tests)"
ok "Test 1: PARK_MAX_CLAIMS env var defined (default 3, overridable)"

# === Test 2: cheap label skip before the body fetch ===
grep -qF 'skipped-awaiting-runtime-gate' "$tick" \
    || fail "skipped-awaiting-runtime-gate skip message not found"
grep -qF 'index("awaiting-runtime-gate") != null' "$tick" \
    || fail "awaiting-runtime-gate label check not found"
label_line=$(grep -n 'index("awaiting-runtime-gate") != null' "$tick" | head -1 | cut -d: -f1)
body_line=$(grep -n '_body_json=$(_gh_read issue view "$N" -R "$FULL" --json body,author' "$tick" | head -1 | cut -d: -f1)
[[ -n "$label_line" && -n "$body_line" ]] || fail "label check or body fetch line not found"
(( label_line < body_line )) \
    || fail "awaiting-runtime-gate label skip (line $label_line) must precede the body fetch (line $body_line) — parked issues must cost zero network"
ok "Test 2: awaiting-runtime-gate label skip precedes the body fetch (zero network for parked issues)"

# === Test 3: cumulative (all-time) claim count, not windowed ===
grep -qF '_park_claims=$(awk -v n="$N" -v repo="$REPO"' "$tick" \
    || fail "cumulative claims awk pass not found"
# The awk must NOT carry a cutoff bound (that would make it windowed —
# the windowed count is exactly the #2772 gap).
if sed -n '/_park_claims=\$(awk/,+2p' "$tick" | grep -q 'cutoff'; then
    fail "cumulative claim count must not be windowed (no cutoff in the #4540 awk pass)"
fi
ok "Test 3: detector counts cumulative (all-time) claims from the claims-log snapshot"

# === Test 4: all three preconditions required ===
grep -qF '_park_protected=1' "$tick" || fail "protection check not found"
grep -qF 'grep -qi '\''termination:'\' "$tick" \
    || fail "termination: clause check not found"
grep -qF -- '--head "claim/issue-$N" --state merged' "$tick" \
    || fail "merged claim-branch delivery PR probe not found"
ok "Test 4: park requires protection + termination: clause + merged claim-branch PR"

# === Test 5: on trip, label flip + comment + skip ===
grep -qF -- '--add-label awaiting-runtime-gate --remove-label agent-ready' "$tick" \
    || fail "park label flip (add awaiting-runtime-gate, remove agent-ready) not found"
grep -qF 'skipped-parked-protected-merged' "$tick" \
    || fail "park skip message not found"
ok "Test 5: park trip flips the label and skips with skipped-parked-protected-merged"

# === Test 6: body fetch carries the author ===
grep -qF -- '--json body,author' "$tick" \
    || fail "body fetch must request the author field (owner-authored protection check)"
grep -qF '_issue_author=$(printf '\''%s'\'' "$_body_json" | jq -r '\''.author.login // ""'\'')' "$tick" \
    || fail "author extraction from the body fetch not found"
ok "Test 6: body fetch carries the author for the owner-authored check"

# === Test 7: fleet-merged-pr-close parks on the protected-delivery path ===
grep -qF 'fleet-ops#4540' "$close_bin" \
    || fail "bin/fleet-merged-pr-close missing the #4540 park block"
grep -qF -- '--add-label awaiting-runtime-gate --remove-label agent-ready' "$close_bin" \
    || fail "bin/fleet-merged-pr-close must add awaiting-runtime-gate AND remove agent-ready on the protected-delivery path (parked is not claimable)"
park_line=$(grep -n -- '--add-label awaiting-runtime-gate' "$close_bin" | head -1 | cut -d: -f1)
protected_note_line=$(grep -n 'post_note "$repo" "$num" "$murl" "$mnum" protected' "$close_bin" | head -1 | cut -d: -f1)
[[ -n "$park_line" && -n "$protected_note_line" ]] || fail "park or protected-note line not found"
(( park_line > protected_note_line )) \
    || fail "the #4540 park label must be added after the protected observe-to-close note (same gated path)"
ok "Test 7: fleet-merged-pr-close parks alongside the protected note (delivery path)"

# === Test 8: the park label is ensured (created) before it is added ===
# gh issue edit --add-label does NOT auto-create a missing label (it fails
# "<name> not found"), so the park would silently no-op on a repo where the
# label does not yet exist. Both writers must provision the label first
# (idempotent --force), and the create must precede the add in source order.
for f in "$tick" "$close_bin"; do
    grep -qF 'label create awaiting-runtime-gate' "$f" \
        || fail "$f: missing 'label create awaiting-runtime-gate' (gh issue edit --add-label cannot auto-create a missing label)"
    grep -qF -- '--force' "$f" \
        || fail "$f: label create must be idempotent (--force)"
    create_line=$(grep -n 'label create awaiting-runtime-gate' "$f" | head -1 | cut -d: -f1)
    add_line=$(grep -n -- '--add-label awaiting-runtime-gate' "$f" | head -1 | cut -d: -f1)
    [[ -n "$create_line" && -n "$add_line" ]] || fail "$f: label create or add line not found"
    (( create_line < add_line )) \
        || fail "$f: label create (line $create_line) must precede the --add-label (line $add_line)"
done
ok "Test 8: awaiting-runtime-gate label is provisioned (create --force) before it is added in both writers"

# === Test 9: shellcheck ===
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$tick" --severity=warning
    shellcheck -x "$close_bin" --severity=warning
    ok "Test 9: shellcheck clean"
else
    echo "SKIP: Test 9: shellcheck not installed"
fi

echo "ALL OK: awaiting-runtime-gate park detector (fleet-ops#4540)"
