#!/usr/bin/env bash
# tests/fleet-issue-file-close-duplicates-idempotent.test.sh
#
# fleet-ops#3728: the close-duplicates sweep re-posted the SAME
# possible-duplicate-of marker comment every tick on protected duplicates
# (a protected canonical can never close, so the comment-only branch fired
# every run with no memory of the prior marker). #3728 accumulated ~20
# identical marker comments. The fix: skip re-posting a marker the issue
# already carries for that canonical.
#
# Proves, offline with a fake gh that serves an existing marker comment:
#   1. A protected duplicate that ALREADY carries the marker is skipped
#      (no second gh issue comment call).
#   2. A protected duplicate with NO marker (or a marker for a DIFFERENT
#      canonical) still gets commented.
#   3. The skip is recorded as action="skip" in the run JSON.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/issue-file.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$lib" \
  || fail "issue-file.py failed to parse"

scratch=$(mktemp -d -t close-dups-idem.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

# Fake gh: list serves a fixture; comment logs the call; view serves a
# per-issue comments fixture so issue_has_dup_marker can see prior markers.
mkdir -p "$scratch/fakebin"
cat >"$scratch/fakebin/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
  issue)
    case "$2" in
      list)
        if [[ -f "${GH_OPEN_JSON:-/dev/null}" ]]; then cat "${GH_OPEN_JSON}"; else printf '[]\n'; fi
        ;;
      close)    echo "closed $3" >>"${GH_CLOSED:-/dev/null}" ;;
      comment)  echo "commented $3" >>"${GH_COMMENTED:-/dev/null}" ;;
      view)
        # $3 is the issue number; serve a per-issue comments JSON fixture.
        cfile="${GH_COMMENT_FIXTURE_DIR:-/dev/null}/$3.json"
        if [[ -f "$cfile" ]]; then cat "$cfile"; else printf '{"comments":[]}\n'; fi
        ;;
    esac
    ;;
esac
exit 0
GH
chmod +x "$scratch/fakebin/gh"

export GH="$scratch/fakebin/gh"
export GH_CLOSED="$scratch/closed"
export GH_COMMENTED="$scratch/commented"
export GH_OPEN_JSON="$scratch/gh-open.json"
export GH_COMMENT_FIXTURE_DIR="$scratch/comments"

: >"$scratch/closed"
: >"$scratch/commented"
mkdir -p "$scratch/comments"

# A 2-member same-repo duplicate cluster: #100 (oldest, agent-in-progress =
# protected canonical) and #101 (agent-in-progress = protected, non-canonical).
# Both protected -> neither closes; #101 gets a possible-duplicate comment.
cat >"$scratch/gh-open.json" <<'JSON'
[
  {"number":100,"repository":"Nishfleet/fleet-ops","title":"QualityPostMergeDefectsCeiling at 63.37 since 2026-09-05T08:46Z with chain terminal=detector-red","body":"Alert QualityPostMergeDefectsCeiling firing value 63.37. detector-red. repair chain not reaching green.","url":"u100","labels":["agent-in-progress"],"author":{"login":"app/nishfleet-worker"}},
  {"number":101,"repository":"Nishfleet/fleet-ops","title":"QualityPostMergeDefectsCeiling firing at 74.07 since 2026-09-05T08:46Z detector-red","body":"Alert QualityPostMergeDefectsCeiling firing value 74.07. detector-red terminal. repair chain not reaching green.","url":"u101","labels":["agent-in-progress"],"author":{"login":"app/nishfleet-worker"}}
]
JSON

# --- 1. #101 ALREADY carries the marker for canonical #100 -> skip ---------
cat >"$scratch/comments/101.json" <<'JSON'
{"comments":[
  {"body":"<!-- possible-duplicate-of: Nishfleet/fleet-ops#100 score=0.82 reason=protected -->\nPossible duplicate of Nishfleet/fleet-ops#100 (score 0.82). Not auto-closed: protected.\n"},
  {"body":"some unrelated earlier comment"}
]}
JSON
FLEET_CLOSE_DUPLICATES_OK=1 python3 "$lib" close-duplicates \
    --from-json "$scratch/gh-open.json" --output-json "$scratch/run.json" 2>/dev/null || true

commented=$(jq '.commented' "$scratch/run.json")
skipped=$(jq '.skipped' "$scratch/run.json")
[[ "$commented" -eq 0 ]] || fail "already-marked #101 must NOT be re-commented, got commented=$commented"
[[ "$skipped" -eq 1 ]]   || fail "already-marked #101 must be skipped, got skipped=$skipped"
grep -q "101" "$scratch/commented" && fail "must NOT call gh issue comment on already-marked #101"
# The skip is recorded as action="skip" with an already-marked reason.
jq -e '.actions[] | select(.ref=="Nishfleet/fleet-ops#101" and .action=="skip" and (.reason|startswith("already-marked")))' \
   "$scratch/run.json" >/dev/null || fail "skip action not recorded for #101"
ok "already-marked #101: skipped, no re-comment, action=skip recorded"

# --- 2. #101 has a marker for a DIFFERENT canonical -> still comment --------
: >"$scratch/commented"
cat >"$scratch/comments/101.json" <<'JSON'
{"comments":[
  {"body":"<!-- possible-duplicate-of: Nishfleet/fleet-ops#999 score=0.70 reason=protected -->\nPossible duplicate of Nishfleet/fleet-ops#999 (score 0.70). Not auto-closed: protected.\n"}
]}
JSON
FLEET_CLOSE_DUPLICATES_OK=1 python3 "$lib" close-duplicates \
    --from-json "$scratch/gh-open.json" --output-json "$scratch/run2.json" 2>/dev/null || true

commented=$(jq '.commented' "$scratch/run2.json")
[[ "$commented" -eq 1 ]] || fail "marker for a different canonical must still comment, got commented=$commented"
grep -q "101" "$scratch/commented" || fail "must call gh issue comment on #101 (marker was for a different canonical)"
ok "marker for a different canonical: #101 still commented"

# --- 3. #101 has NO marker -> comment (first-run behavior) ------------------
: >"$scratch/commented"
cat >"$scratch/comments/101.json" <<'JSON'
{"comments":[]}
JSON
FLEET_CLOSE_DUPLICATES_OK=1 python3 "$lib" close-duplicates \
    --from-json "$scratch/gh-open.json" --output-json "$scratch/run3.json" 2>/dev/null || true

commented=$(jq '.commented' "$scratch/run3.json")
[[ "$commented" -eq 1 ]] || fail "no-marker #101 must be commented, got commented=$commented"
grep -q "101" "$scratch/commented" || fail "must call gh issue comment on no-marker #101"
ok "no-marker #101: commented (first-run behavior preserved)"

echo "OK: close-duplicates idempotent marker (fleet-ops#3728)"
