#!/usr/bin/env bash
# tests/spec-judge.test.sh
#
# fleet-ops#4801: the spec-judge gate (Kimi K3 Max over batches of
# agent-ready tickets that share files, BEFORE a worker may claim them).
# This pins the mechanical logic in lib/spec-judge.sh and its wiring in
# lib/pi-intake-tick.sh without a live systemd/gh environment.
#
# Proves:
#   1. Batch grouping: shared file, same directory, exemption for singles.
#   2. Overlapping groups merge into connected components.
#   3. Batch sha is stable and changes when a member body changes.
#   4. Marker detection (spec-judged: <sha> comment) and re-judge on body
#      change.
#   5. Verdict parsing: READY / EDIT / BLOCK.
#   6. Rate cap: never more than SPEC_JUDGE_RATE_MAX launches per hour.
#   7. Failure fallback: one relaunch, then clear + comment on second.
#   8. In-flight marker: at most one judge per repo; members skipped.
#   9. Intake tick wiring: sources the lib, runs apply + failure fallback,
#      skips batch members in the claim loop.
#  10. shellcheck is clean on both files.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/spec-judge.sh"
tick="$repo_root/lib/pi-intake-tick.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "lib/spec-judge.sh missing"
[[ -f "$tick" ]] || fail "lib/pi-intake-tick.sh missing"

# --- Test 1: batch grouping (shared file, same dir, singles exempt) -------
source "$lib"
issues='[
  {"number":1,"body":"files: app/lib/foo.ts, app/lib/bar.ts"},
  {"number":2,"body":"files: app/lib/foo.ts"},
  {"number":3,"body":"files: docs/readme.md"},
  {"number":4,"body":"files: docs/readme.md, app/lib/bar.ts"},
  {"number":5,"body":"no files line here"}
]'
out=$(spec_judge_group_batches "$issues")
count=$(printf '%s' "$out" | jq 'length')
[[ "$count" == "1" ]] || fail "Test 1: expected 1 merged batch, got $count: $out"
nums=$(printf '%s' "$out" | jq -c '.[0].numbers')
[[ "$nums" == "[1,2,3,4]" ]] || fail "Test 1: expected merged batch [1,2,3,4], got $nums"
ok "Test 1: shared-file + same-dir issues merge into one batch; singles exempt"

# --- Test 2: two separate batches stay separate ---------------------------
issues2='[
  {"number":1,"body":"files: app/lib/foo.ts"},
  {"number":2,"body":"files: app/lib/foo.ts"},
  {"number":3,"body":"files: docs/readme.md"},
  {"number":4,"body":"files: docs/readme.md"}
]'
out2=$(spec_judge_group_batches "$issues2")
count2=$(printf '%s' "$out2" | jq 'length')
[[ "$count2" == "2" ]] || fail "Test 2: expected 2 batches, got $count2: $out2"
ok "Test 2: two disjoint shared-file groups stay separate"

# --- Test 3: batch sha stable + changes on body change --------------------
sha1=$(spec_judge_batch_sha "body1
body2")
sha1b=$(spec_judge_batch_sha "body1
body2")
[[ "$sha1" == "$sha1b" ]] || fail "Test 3: sha must be stable for identical bodies"
sha2=$(spec_judge_batch_sha "body1
body3")
[[ "$sha1" != "$sha2" ]] || fail "Test 3: sha must change when a body changes"
ok "Test 3: batch sha is stable and changes on body change"

# --- Test 4: marker detection + re-judge on body change --------------------
# Use a fake gh that returns a marker comment for the newest member.
fake_gh() {
    if [[ "$1" == "issue" && "$2" == "view" ]]; then
        # newest member 4 has the marker; others do not
        if [[ "$3" == "4" ]]; then
            printf '{"comments":[{"body":"spec-judged: %s"}]}' "$MARKER_SHA"
        else
            printf '{"comments":[]}'
        fi
        return 0
    fi
    return 0
}
export GH=fake_gh
MARKER_SHA="abc123"
spec_judge_has_marker "Nishfleet/fleet-ops" "4" "abc123" \
    || fail "Test 4: marker present must be detected"
spec_judge_has_marker "Nishfleet/fleet-ops" "4" "different" \
    && fail "Test 4: mismatched sha must NOT be detected as marker"
ok "Test 4: marker detection matches sha; re-judge on body change (sha mismatch)"

# --- Test 5: verdict parsing (READY / EDIT / BLOCK) -----------------------
# The apply function must recognize all three verdict kinds.
grep -qF 'VERDICT:[[:space:]](READY|EDIT|BLOCK)' "$lib" \
    || fail "Test 5: verdict parser must recognize READY/EDIT/BLOCK"
ok "Test 5: verdict parser recognizes READY/EDIT/BLOCK"

# --- Test 6: rate cap ------------------------------------------------------
export SPEC_JUDGE_STATE_DIR="$(mktemp -d)"
export SPEC_JUDGE_RATE_MAX=3
# Bump 3 times -> cap reached.
spec_judge_rate_bump; spec_judge_rate_bump; spec_judge_rate_bump
spec_judge_rate_ok && fail "Test 6: rate cap must be reached after 3 launches"
# A fresh hour has headroom.
hour="$(date -u +%Y%m%d%H)"
rm -f "$SPEC_JUDGE_STATE_DIR/rate-$hour"
spec_judge_rate_ok || fail "Test 6: fresh hour must have headroom"
ok "Test 6: fleet-wide hourly rate cap (3/hour) enforced"

# --- Test 7: failure fallback (one relaunch, then clear) -------------------
export PI_SYSTEMD_RUN=/bin/echo
export SYSTEMCTL=/bin/echo
export GH=/bin/echo
echo '{"repo":"fleet-ops","batch":[1,2],"sha":"abc123","unit":"spec-judge-fleet-ops-abc123","launched_at":"x","relaunched":false}' \
    > "$SPEC_JUDGE_STATE_DIR/inflight-fleet-ops.json"
spec_judge_failure_fallback "fleet-ops" "Nishfleet/fleet-ops"
relaunched=$(jq -r '.relaunched' "$SPEC_JUDGE_STATE_DIR/inflight-fleet-ops.json" 2>/dev/null || echo "")
[[ "$relaunched" == "true" ]] || fail "Test 7: first failure must mark relaunched=true"
spec_judge_failure_fallback "fleet-ops" "Nishfleet/fleet-ops"
[[ -f "$SPEC_JUDGE_STATE_DIR/inflight-fleet-ops.json" ]] \
    && fail "Test 7: second failure must clear the in-flight marker"
ok "Test 7: failure fallback relaunches once, then clears on second failure"

# --- Test 8: in-flight marker + member skip --------------------------------
echo '{"repo":"fleet-ops","batch":[1,2],"sha":"abc123","unit":"spec-judge-fleet-ops-abc123","launched_at":"x","relaunched":false}' \
    > "$SPEC_JUDGE_STATE_DIR/inflight-fleet-ops.json"
spec_judge_inflight "fleet-ops" || fail "Test 8: in-flight marker must be detected"
spec_judge_skip_member "fleet-ops" "1" || fail "Test 8: member 1 must be skipped"
spec_judge_skip_member "fleet-ops" "3" && fail "Test 8: non-member 3 must NOT be skipped"
ok "Test 8: in-flight marker gates member claims"

# --- Test 9: intake tick wiring --------------------------------------------
grep -qF 'spec_judge_failure_fallback "$REPO" "$FULL"' "$tick" \
    || fail "Test 9: tick must run failure fallback"
grep -qF 'spec_judge_apply "$REPO" "$FULL"' "$tick" \
    || fail "Test 9: tick must apply landed verdicts"
grep -qF 'spec_judge_group_batches' "$tick" \
    || fail "Test 9: tick must run batch detection"
grep -qF 'spec_judge_skip_member "$REPO" "$N"' "$tick" \
    || fail "Test 9: tick must skip batch members in the claim loop"
grep -qF 'spec_judge_launch "$REPO" "$FULL"' "$tick" \
    || fail "Test 9: tick must launch the judge"
ok "Test 9: intake tick wires apply, failure fallback, batch detection, gate, and member skip"

# --- Test 10: shellcheck ---------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$lib" --severity=warning
    shellcheck "$tick" --severity=warning
    ok "Test 10: shellcheck clean on spec-judge.sh and pi-intake-tick.sh"
else
    echo "SKIP: Test 10: shellcheck not installed"
fi

echo ""
echo "ALL OK: spec-judge gate (fleet-ops#4801)"
