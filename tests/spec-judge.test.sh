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
[[ -s "$SPEC_JUDGE_STATE_DIR/unavailable-fleet-ops-abc123.json" ]] \
    || fail "Test 7: second failure must leave a durable unavailable-<repo>-<sha>.json record"
jq -e '.batch == [1,2] and .newest_issue == 2 and .unit == "spec-judge-fleet-ops-abc123"' \
    "$SPEC_JUDGE_STATE_DIR/unavailable-fleet-ops-abc123.json" >/dev/null 2>&1 \
    || fail "Test 7: unavailable record must carry repo/sha/unit/batch/newest_issue"
ok "Test 7: failure fallback relaunches once, then clears on second failure"

# --- Test 7b: a dropped fallback comment is LOUD, and the durable record ---
# still lands (fleet-ops#5438 — no silent drop).
sj_fail_gh() { return 1; }
GH=sj_fail_gh
rm -f "$SPEC_JUDGE_STATE_DIR"/unavailable-*.json
echo '{"repo":"fleet-ops","batch":[5,9],"sha":"feedface","unit":"spec-judge-fleet-ops-feedface","launched_at":"x","relaunched":true}' \
    > "$SPEC_JUDGE_STATE_DIR/inflight-fleet-ops.json"
t7b_err=$(spec_judge_failure_fallback "fleet-ops" "Nishfleet/fleet-ops" 2>&1)
printf '%s' "$t7b_err" | grep -q 'ALERT spec-judge: gh issue comment' \
    || fail "Test 7b: dropped fallback comment must emit an ALERT line, got: $t7b_err"
[[ -s "$SPEC_JUDGE_STATE_DIR/unavailable-fleet-ops-feedface.json" ]] \
    || fail "Test 7b: durable record must exist even when the comment fails"
unset -f sj_fail_gh
GH=/bin/echo
ok "Test 7b: dropped failure-fallback comment is ALERT-loud + durable record survives"

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

# --- Test 15b (fleet-ops#5107): binding bullet `depends-on: #N` -> structured
# line updated. The #2352 shape: the judge expresses a NEW dependency in a
# non-Replace bullet, which lands in the binding section; the structured
# `depends-on: none` line must carry the number afterwards. Never overwrite
# a real value (the conservative rule). Judge-explicit dep wins over the
# landing-order predecessor (specific beats inferred).
cat >"$GH" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  issue)
    case "$2" in
      view) printf '%s' '{"body":"files: a.ts\ndepends-on: none\n\nStep 3 says one POST here."}' ;;
      edit)
        while [[ $# -gt 0 ]]; do
          [[ "$1" == "--body-file" ]] && { cp "$2" "$SPEC_JUDGE_STATE_DIR/edit-body.txt"; }
          shift
        done ;;
      comment) ;;
    esac ;;
esac
FAKE
chmod +x "$GH"
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2352 - VERDICT: EDIT

- If #2359 lands first, use its shared helper; add `depends-on: #2359`.
EOF
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaD1" "$vf"
newbody=$(cat "$SPEC_JUDGE_STATE_DIR/edit-body.txt" 2>/dev/null || true)
[[ "$newbody" == *"depends-on: #2359"* ]] || fail "Test 15b: structured line not updated from binding bullet, got: $newbody"
[[ "$newbody" != *"depends-on: none"* ]] || fail "Test 15b: depends-on: none still present"
[[ "$newbody" == *"## Judge edits (binding)"* ]] || fail "Test 15b: binding section missing"
ok "Test 15b: binding bullet depends-on: #N -> structured line updated"
rm -f "$vf"

# --- Test 15c (fleet-ops#5107): never overwrite a real depends-on value ---
cat >"$GH" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  issue)
    case "$2" in
      view) printf '%s' '{"body":"files: a.ts\ndepends-on: #2373\n"}' ;;
      edit)
        while [[ $# -gt 0 ]]; do
          [[ "$1" == "--body-file" ]] && { cp "$2" "$SPEC_JUDGE_STATE_DIR/edit-body.txt"; }
          shift
        done ;;
      comment) ;;
    esac ;;
esac
FAKE
chmod +x "$GH"
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2352 - VERDICT: EDIT

- If #2359 lands first, use its shared helper; add `depends-on: #2359`.
EOF
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaD2" "$vf"
newbody=$(cat "$SPEC_JUDGE_STATE_DIR/edit-body.txt" 2>/dev/null || true)
structured=$(printf '%s\n' "$newbody" | grep -E '^depends-on:' || true)
[[ "$structured" == "depends-on: #2373" ]] || fail "Test 15c: real depends-on value must survive, got: $structured"
ok "Test 15c: real depends-on value never overwritten by the binding-bullet scan"
rm -f "$vf"

# --- Test 15d (fleet-ops#5107): binding dep with NO #<n> parks the ticket -
# The #2394 shape: `depends-on: the R1 ticket...` names no issue number.
# The ticket parks on blocked-on: orchestrator + agent-blocked +
# needs-orchestrator labels instead of being claimed.
cat >"$GH" <<'FAKE'
#!/usr/bin/env bash
STATE="$SPEC_JUDGE_STATE_DIR"
case "$1" in
  issue)
    case "$2" in
      view) printf '%s' '{"body":"files: a.ts\ndepends-on: none\n"}' ;;
      edit)
        while [[ $# -gt 0 ]]; do
          [[ "$1" == "--body-file" ]] && { cp "$2" "$STATE/edit-body.txt"; }
          [[ "$1" == "--remove-label" || "$1" == "--add-label" ]] && { printf '%s %s\n' "$1" "$2" >> "$STATE/edit-labels.txt"; }
          shift
        done ;;
      comment) ;;
    esac ;;
esac
FAKE
chmod +x "$GH"
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2394 - VERDICT: EDIT

- Replace `depends-on: none` with `depends-on: the R1 ticket for the cache-HIT claim; this ticket's only deliverable is the doc`.
EOF
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaD3" "$vf"
newbody=$(cat "$SPEC_JUDGE_STATE_DIR/edit-body.txt" 2>/dev/null || true)
[[ "$newbody" == *"blocked-on: orchestrator"* ]] || fail "Test 15d: blocked-on: orchestrator missing from body, got: $newbody"
labels=$(cat "$SPEC_JUDGE_STATE_DIR/edit-labels.txt" 2>/dev/null || true)
[[ "$labels" == *"--remove-label agent-ready"* ]] || fail "Test 15d: agent-ready not removed, got: $labels"
[[ "$labels" == *"--add-label agent-blocked"* ]] || fail "Test 15d: agent-blocked not added, got: $labels"
[[ "$labels" == *"--add-label needs-orchestrator"* ]] || fail "Test 15d: needs-orchestrator not added, got: $labels"
ok "Test 15d: no-number binding dep parks the ticket (blocked-on: orchestrator + labels)"
rm -f "$vf"
rm -f "$SPEC_JUDGE_STATE_DIR/edit-labels.txt"

# --- Test 15e (fleet-ops#5107): judge-explicit dep wins over the predecessor
cat >"$GH" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  issue)
    case "$2" in
      view) printf '%s' '{"body":"files: a.ts\ndepends-on: none\n"}' ;;
      edit)
        while [[ $# -gt 0 ]]; do
          [[ "$1" == "--body-file" ]] && { cp "$2" "$SPEC_JUDGE_STATE_DIR/edit-body.txt"; }
          shift
        done ;;
      comment) ;;
    esac ;;
esac
FAKE
chmod +x "$GH"
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2352 - VERDICT: EDIT

- If #2359 lands first, use its shared helper; add `depends-on: #2359`.

## Cross-ticket

- **Landing order (strictly sequential):** #2181 -> #2352.
EOF
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaD4" "$vf"
newbody=$(cat "$SPEC_JUDGE_STATE_DIR/edit-body.txt" 2>/dev/null || true)
structured=$(printf '%s\n' "$newbody" | grep -E '^depends-on:' || true)
[[ "$structured" == "depends-on: #2359" ]] || fail "Test 15e: judge-explicit dep must win over the inferred predecessor, got: $structured"
ok "Test 15e: judge-explicit dep wins over landing-order predecessor"
rm -f "$vf"

# --- Test 15f (fleet-ops#5107): binding bullet with `depends-on: none` mention
# only (no live dep) must NOT park the ticket: the last token's value governs.
cat >"$GH" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  issue)
    case "$2" in
      view) printf '%s' '{"body":"files: a.ts\ndepends-on: none\n"}' ;;
      edit)
        while [[ $# -gt 0 ]]; do
          [[ "$1" == "--body-file" ]] && { cp "$2" "$SPEC_JUDGE_STATE_DIR/edit-body.txt"; }
          [[ "$1" == "--remove-label" || "$1" == "--add-label" ]] && { printf '%s %s\n' "$1" "$2" >> "$SPEC_JUDGE_STATE_DIR/edit-labels.txt"; }
          shift
        done ;;
      comment) ;;
    esac ;;
esac
FAKE
chmod +x "$GH"
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2401 - VERDICT: EDIT

- Landing is clear now; keep `depends-on: none` until the batch closes.
EOF
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaD5" "$vf"
newbody=$(cat "$SPEC_JUDGE_STATE_DIR/edit-body.txt" 2>/dev/null || true)
[[ "$newbody" != *"blocked-on: orchestrator"* ]] || fail "Test 15f: keep-none bullet must not park, got: $newbody"
[[ ! -s "$SPEC_JUDGE_STATE_DIR/edit-labels.txt" ]] || fail "Test 15f: labels must not change, got: $(cat "$SPEC_JUDGE_STATE_DIR/edit-labels.txt")"
ok "Test 15f: a depends-on: none mention in a binding bullet does not park"
rm -f "$vf"
rm -f "$SPEC_JUDGE_STATE_DIR/edit-labels.txt"

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

# ---------------------------------------------------------------------------
# fleet-ops#5131: `Absorbs #N` in a binding judge edit parks the absorbed
# ticket (0509#2387 was claimed 4m24s after the absorbing PR merged).
# ---------------------------------------------------------------------------
_sj_state18=$(mktemp -d); export SPEC_JUDGE_STATE_DIR="$_sj_state18"
cat >"$here/fake-gh-absorb.sh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  issue)
    case "$2" in
      view)
        if [[ "$*" == *"--json state,labels"* ]]; then
          case "$3" in
            2387) printf '%s' '{"state":"OPEN","labels":[{"name":"agent-ready"},{"name":"machinery"}]}' ;;
            7)    printf '%s' '{"state":"CLOSED","labels":[{"name":"agent-blocked"}]}' ;;
            2388) printf '%s' '{"state":"OPEN","labels":[{"name":"agent-in-progress"}]}' ;;
            *)    printf '%s' '{"state":"OPEN","labels":[]}' ;;
          esac
        else
          printf '%s' '{"body":"files: a.ts"}'
        fi ;;
      edit)
        _line="$*"
        while [[ $# -gt 0 ]]; do
          [[ "$1" == "--body-file" ]] && cp "$2" "$SPEC_JUDGE_STATE_DIR/edit-body.txt" 2>/dev/null
          shift
        done
        printf '%s\n' "$_line" >>"$SPEC_JUDGE_STATE_DIR/edit-calls.txt" ;;
      comment)
        _n="$3"
        while [[ $# -gt 0 ]]; do
          [[ "$1" == "--body" ]] && { printf '%s\n' "$2" >>"$SPEC_JUDGE_STATE_DIR/comment-${_n}.txt"; break; }
          shift
        done ;;
    esac ;;
esac
FAKE
chmod +x "$here/fake-gh-absorb.sh"
export GH="$here/fake-gh-absorb.sh"

# --- Test 18: binding `Absorbs #N` parks the absorbed ticket --------------
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2379 - VERDICT: EDIT

- Absorbs #2387.
EOF
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaAbs" "$vf"
abody=$(cat "$SPEC_JUDGE_STATE_DIR/edit-body.txt" 2>/dev/null || true)
[[ "$abody" == *"## Judge edits (binding)"* ]] \
    || fail "Test 18: absorbing issue must carry the binding section"
[[ "$abody" == *"Absorbs #2387"* ]] || fail "Test 18: binding bullet must be preserved"
calls=$(cat "$SPEC_JUDGE_STATE_DIR/edit-calls.txt" 2>/dev/null || true)
park_line=$(printf '%s\n' "$calls" | grep -F 'issue edit 2387 ' | head -1 || true)
[[ -n "$park_line" ]] || fail "Test 18: absorbed ticket must be edited: [$calls]"
[[ "$park_line" == *"--remove-label agent-ready"* ]] || fail "Test 18: agent-ready must be removed"
[[ "$park_line" == *"--add-label agent-blocked"* ]] || fail "Test 18: agent-blocked must be added"
[[ "$park_line" == *"--add-label needs-orchestrator"* ]] \
    || fail "Test 18: needs-orchestrator must be added so the existing sweep closes it as subsumed"
absorbed_comment=$(cat "$SPEC_JUDGE_STATE_DIR/comment-2387.txt" 2>/dev/null || true)
[[ -n "$absorbed_comment" ]] || fail "Test 18: absorbed ticket must get an explanatory comment"
[[ "$absorbed_comment" == *"blocked-on: orchestrator"* ]] \
    || fail "Test 18: park must carry blocked-on: orchestrator (the only line that makes the park hold)"
[[ "$absorbed_comment" != *"blocked-on: Nishfleet"* && "$absorbed_comment" != *"blocked-on: #"* ]] \
    || fail "Test 18: park must NOT carry a ref to the absorbing issue (that ref requeues on close)"
ok "Test 18: binding 'Absorbs #N' parks the absorbed ticket (agent-ready -> agent-blocked + needs-orchestrator)"
rm -f "$vf"

# --- Test 19: same-tick claim skip for the parked ticket ------------------
# The intake tick fetches its agent-ready list BEFORE the verdict is applied,
# so the label flip alone would let this tick claim the absorbed ticket.
spec_judge_skip_member "fleet-ops" "2387" \
    || fail "Test 19: parked absorbed ticket must be skipped by the claim loop"
spec_judge_skip_member "fleet-ops" "2390" \
    && fail "Test 19: an unrelated ticket must NOT be skipped"
ok "Test 19: parked absorbed ticket is skipped in the same tick (stale ready list)"

# --- Test 20: not-claimable and cross-repo refs touch nothing -------------
vf=$(mktemp)
cat >"$vf" <<'EOF'
## #2379 - VERDICT: EDIT

- Absorbs #7.
- Absorbs #2388.
- Absorbs Nishfleet/0509#99.
EOF
spec_judge_apply "fleet-ops" "Nishfleet/fleet-ops" "shaAbs2" "$vf"
calls2=$(cat "$SPEC_JUDGE_STATE_DIR/edit-calls.txt" 2>/dev/null || true)
for _n in 7 2388 99; do
    [[ "$calls2" != *"issue edit $_n "* ]] \
        || fail "Test 20: ref to $_n must not be parked (closed/in-progress/cross-repo)"
    spec_judge_skip_member "fleet-ops" "$_n" \
        && fail "Test 20: ref to $_n must not be in the park ledger"
done
ok "Test 20: closed, already-claimed and cross-repo refs are left untouched"
rm -f "$vf"

# --- Test 21: a parked ticket can never be requeued by blocked-reconcile --
# blocked-reconcile forces all_cleared=0 whenever `.orchestrator` is true, so
# the park's `blocked-on: orchestrator` line outranks a resolved ref to the
# absorbing issue: even with the ref present and CLOSED+MERGED, the sweep can
# never flip the ticket back to agent-ready. Proved end-to-end (with the real
# sweep) by Case 4b in tests/blocked-reconcile.test.sh.
_extract() {
    printf '%s' "$1" | "$repo_root/bin/blocked-reconcile" --extract
}
# Live shape: the absorbing issue's ref is present in an older comment.
parked_payload='{"repo":"Nishfleet/fleet-ops","number":2387,"title":"move the specs","body":"files: a.ts\n\n## Judge edits (binding)\n\n- Absorbs #2387.","comments":[{"body":"blocked: absorbed by Nishfleet/fleet-ops#2379.\n\nblocked-on: Nishfleet/fleet-ops#2379"},{"body":"spec-judge: absorbed by #2379.\n\nblocked-on: orchestrator"}]}'
out21=$(_extract "$parked_payload")
[[ "$(printf '%s' "$out21" | jq -r '.orchestrator')" == "true" ]] \
    || fail "Test 21: parked ticket must carry the orchestrator block (forces all_cleared=0): $out21"
[[ "$(printf '%s' "$out21" | jq -r '.nish')" == "false" ]] || fail "Test 21: parked ticket must not be nish-blocked"
[[ "$(printf '%s' "$out21" | jq -r '.unknown_forms | length')" == "0" ]] \
    || fail "Test 21: park must not read as an unknown-form block: $out21"
# Contrast: the SAME body with no orchestrator line is a plain work-item whose
# ref resolves the moment the absorbing issue closes — exactly the requeue the
# park has to prevent.
ref_payload='{"repo":"Nishfleet/fleet-ops","number":2387,"title":"x","body":"blocked-on: Nishfleet/fleet-ops#2379","comments":[]}'
out21b=$(_extract "$ref_payload")
[[ "$(printf '%s' "$out21b" | jq '.deps | length')" == "1" ]] \
    || fail "Test 21: contrast payload must parse one dep: $out21b"
[[ "$(printf '%s' "$out21b" | jq -r '.orchestrator')" == "false" ]] \
    || fail "Test 21: contrast payload must not carry the orchestrator block"
ok "Test 21: parked ticket parses to an orchestrator block, so a closed absorbing ref can never requeue it"

# --- Test 22: absorbed-ref extraction is exact ----------------------------
[[ "$(spec_judge_absorbed_refs '- Absorbs #2387.' 'Nishfleet/fleet-ops')" == "2387" ]] \
    || fail "Test 22: bare Absorbs #N must extract"
[[ "$(spec_judge_absorbed_refs '- Absorbed by #12.' 'Nishfleet/fleet-ops')" == "12" ]] \
    || fail "Test 22: Absorbed by #N must extract"
[[ "$(spec_judge_absorbed_refs '- absorbs Nishfleet/fleet-ops#4242' 'Nishfleet/fleet-ops')" == "4242" ]] \
    || fail "Test 22: same-repo owner/repo#N must extract"
[[ -z "$(spec_judge_absorbed_refs '- Absorbs Nishfleet/0509#99.' 'Nishfleet/fleet-ops')" ]] \
    || fail "Test 22: cross-repo ref must NOT extract"
[[ -z "$(spec_judge_absorbed_refs '- Absorbs the retry logic from #123.' 'Nishfleet/fleet-ops')" ]] \
    || fail "Test 22: prose mentioning a #N must NOT extract"
# The judge writes ref LISTS on 0509 (live: #2419 'Absorbs #2428 and #2429',
# #2416 'Absorbs #2424, #2426, #2427'). Every ref must extract.
[[ "$(spec_judge_absorbed_refs '- Absorbs #2428 and #2429 (empty-do subsets).' 'Nishfleet/fleet-ops' | tr '\n' ' ')" == "2428 2429 " ]] \
    || fail "Test 22: 'and'-joined ref list must extract both"
[[ "$(spec_judge_absorbed_refs '- Absorbs #2424, #2426, #2427 (their third file).' 'Nishfleet/fleet-ops' | tr '\n' ' ')" == "2424 2426 2427 " ]] \
    || fail "Test 22: comma-joined ref list must extract all three"
[[ "$(spec_judge_absorbed_refs '- Absorbs #2428 and #2429.' 'Nishfleet/fleet-ops' | wc -l)" == "2" ]] \
    || fail "Test 22: a ref list must not become one ref"
ok "Test 22: absorbed-ref extraction matches only Absorbs/Absorbed-by bullets to same-repo issues"

# cleanup fake gh
rm -f "$GH" "$here/fake-gh-absorb.sh"

echo ""
echo "ALL OK: spec-judge gate (fleet-ops#4801 / #5131)"
