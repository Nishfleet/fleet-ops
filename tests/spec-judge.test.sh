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
grep -qE 'VERDICT:\[\[:space:\]\]\+\(READY\|EDIT\|BLOCK\)' "$lib" \
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

# --- Test 11: spec_judge_parse_replace (Replace "OLD" with "NEW") ---------
pair=$(spec_judge_parse_replace 'Replace "one POST" with "two POST" — note.')
expected=$'one POST\ttwo POST'
[[ "$pair" == "$expected" ]] || fail "Test 11: parse_replace got [$pair] want [$expected]"
# Non-Replace bullets return non-zero (go to binding section).
spec_judge_parse_replace 'Append to step 1: "text"' \
    && fail "Test 11: non-Replace bullet must return non-zero"
ok "Test 11: parse_replace extracts OLD/NEW; non-Replace bullets fall through"

# --- Test 12: spec_judge_landing_order ------------------------------------
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2181 - VERDICT: EDIT

- Replace "a" with "b".

## Cross-ticket

- **Landing order (strictly sequential):** #2181 -> #2189 -> #2193.
- **Counter owner:** #2181.
EOF
order=$(spec_judge_landing_order "$vf")
[[ "$order" == "2181 2189 2193 " ]] || fail "Test 12: landing order got [$order]"
ok "Test 12: landing order parsed from Cross-ticket section"
rm -f "$vf"

# --- Test 13: EDIT apply — anchor found (exact replace) -------------------
# Fake gh: view returns a body containing the anchor; edit/append captures
# the new body. We assert the anchor was replaced in the body pushed back.
_sj_state=$(mktemp -d); export SPEC_JUDGE_STATE_DIR="$_sj_state"
export GH="$here/fake-gh-edit.sh"
cat >"$GH" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  issue)
    case "$2" in
      view) printf '%s' '{"body":"files: a.ts\ndepends-on: none\n\nStep 3 says one POST here."}' ;;
      edit)
        # capture --body-file payload
        while [[ $# -gt 0 ]]; do
          [[ "$1" == "--body-file" ]] && { cp "$2" "$SPEC_JUDGE_STATE_DIR/edit-body.txt"; break; }
          shift
        done ;;
      comment) ;;
    esac ;;
esac
FAKE
chmod +x "$GH"
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2181 - VERDICT: EDIT

- Replace "one POST here." with "two POST here."
EOF
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaX" "$vf"
newbody=$(cat "$SPEC_JUDGE_STATE_DIR/edit-body.txt" 2>/dev/null || true)
[[ "$newbody" == *"two POST here."* ]] || fail "Test 13: anchor not replaced in pushed body"
[[ "$newbody" != *"one POST here."* ]] || fail "Test 13: old anchor still present"
[[ "$newbody" != *"Judge edits (binding)"* ]] || fail "Test 13: binding section added despite anchor found"
ok "Test 13: EDIT anchor found -> exact replace, no binding section"
rm -f "$vf"

# --- Test 14: EDIT apply — anchor NOT found -> binding section -------------
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2182 - VERDICT: EDIT

- Replace "this anchor does not exist in body" with "new text"
- Append to step 1: "extra"
EOF
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaY" "$vf"
newbody=$(cat "$SPEC_JUDGE_STATE_DIR/edit-body.txt" 2>/dev/null || true)
[[ "$newbody" == *"## Judge edits (binding)"* ]] || fail "Test 14: binding section missing"
[[ "$newbody" == *"this anchor does not exist in body"* ]] || fail "Test 14: unanchored bullet missing from binding"
[[ "$newbody" == *"Append to step 1"* ]] || fail "Test 14: non-Replace bullet missing from binding"
ok "Test 14: EDIT anchor not found -> bullets land in binding section"
rm -f "$vf"

# --- Test 15: EDIT apply — depends-on: none rewritten from landing order ---
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2189 - VERDICT: EDIT

- Replace "a" with "b"

## Cross-ticket

- **Landing order (strictly sequential):** #2181 -> #2189.
EOF
# Body has "depends-on: none"; #2189's predecessor is #2181.
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaZ" "$vf"
newbody=$(cat "$SPEC_JUDGE_STATE_DIR/edit-body.txt" 2>/dev/null || true)
[[ "$newbody" == *"depends-on: #2181"* ]] || fail "Test 15: depends-on: none not rewritten to predecessor"
[[ "$newbody" != *"depends-on: none"* ]] || fail "Test 15: depends-on: none still present"
ok "Test 15: depends-on: none rewritten to landing-order predecessor"
rm -f "$vf"

# --- Test 16: BLOCK apply — reason comment + nish-decision for money -------
# Fake gh captures the comment body for the BLOCK issue.
cat >"$GH" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  issue)
    case "$2" in
      view) printf '%s' '{"body":"files: a.ts"}' ;;
      edit) ;;  # label change, ignore
      comment) while [[ $# -gt 0 ]]; do [[ "$1" == "--body" ]] && { printf '%s' "$2" > "$SPEC_JUDGE_STATE_DIR/block-comment.txt"; break; }; shift; done ;;
    esac ;;
esac
FAKE
chmod +x "$GH"
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2199 - VERDICT: BLOCK

- This ticket asks Nish to set the pricing tier; money decision required.
EOF
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaB" "$vf"
bc=$(cat "$SPEC_JUDGE_STATE_DIR/block-comment.txt" 2>/dev/null || true)
[[ "$bc" == *"spec-judged: shaB"* ]] || fail "Test 16: BLOCK marker missing from comment"
[[ "$bc" == *"spec-judge BLOCK reason"* ]] || fail "Test 16: BLOCK reason missing"
[[ "$bc" == *"money decision required"* ]] || fail "Test 16: BLOCK reason text missing"
[[ "$bc" == *"blocked-on: nish-decision"* ]] || fail "Test 16: money reason must add blocked-on: nish-decision"
ok "Test 16: BLOCK money reason -> reason comment + blocked-on: nish-decision"
rm -f "$vf"

# --- Test 17: BLOCK apply — non-Nish reason -> NO nish-decision ------------
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2200 - VERDICT: BLOCK

- Spec is ambiguous about the helper ownership; re-spec before claiming.
EOF
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaC" "$vf"
bc=$(cat "$SPEC_JUDGE_STATE_DIR/block-comment.txt" 2>/dev/null || true)
[[ "$bc" == *"spec-judge BLOCK reason"* ]] || fail "Test 17: BLOCK reason missing"
[[ "$bc" != *"blocked-on: nish-decision"* ]] || fail "Test 17: non-Nish reason must NOT add nish-decision"
ok "Test 17: BLOCK non-Nish reason -> reason comment, no nish-decision"
rm -f "$vf"

# cleanup fake gh
rm -f "$GH"

echo ""
echo "ALL OK: spec-judge gate (fleet-ops#4801)"
