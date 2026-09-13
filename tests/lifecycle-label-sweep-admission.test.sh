#!/usr/bin/env bash
# tests/lifecycle-label-sweep-admission.test.sh
#
# Proves fleet-ops#4022: a scout-candidate issue whose body already passes
# the spec gate is admitted to agent-ready (it is ready work, not a
# proposal); a spec-less one older than 72h gets exactly ONE bounce
# comment and is NOT re-bounced or re-labelled on the next sweep; and the
# unlabeled pass does not re-apply scout-candidate to an issue bounced
# within the cooldown (kills the churn loop).
#
# Required by fleet-ops#4022:
#   (a) a spec-carrying scout-candidate becomes agent-ready
#   (b) a spec-less one gets exactly one bounce comment and NO relabel on
#       a second sweep run
# Plus the cooldown re-apply guard (scope point 3).
#
# fleet-ops#5887: park (awaiting-runtime-gate) wins over scout-candidate
# admission. A parked spec-passing scout-candidate is NOT admitted; a
# dual-labeled leftover drops agent-ready; un-park is one edit.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/lifecycle-label-sweep"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

# --- live sweep with mocked gh --------------------------------------------
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

cat >"$scratch/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DIR/gh.log"
case "$1" in
  issue)
    case "$2" in
      list)
        cat "$FAKE_DIR/list.json"
        exit 0
        ;;
      view)
        num="$3"
        if [[ -f "$FAKE_DIR/view-${num}.json" ]]; then
          cat "$FAKE_DIR/view-${num}.json"
          exit 0
        fi
        echo '{"labels":[],"title":"x"}'
        exit 0
        ;;
      edit)
        printf '%s\n' "$*" >>"$FAKE_DIR/edits.log"
        exit 0
        ;;
      comment)
        printf '%s\n' "$*" >>"$FAKE_DIR/comments.log"
        exit 0
        ;;
      close)
        exit 0
        ;;
      *) echo "unexpected gh issue $*" >&2; exit 1 ;;
    esac
    ;;
  label)
    exit 0
    ;;
  api)
    # --unpark pre-check reads the issue's labels (fleet-ops#5887).
    cat "$FAKE_DIR/api-issue.json"
    exit 0
    ;;
  pr)
    echo '[]'
    exit 0
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh" "$bin"
export FAKE_DIR="$scratch"
export PATH="$scratch/bin:$PATH"
export LIFECYCLE_SWEEP_LOCKDIR="$scratch/lock"
export LIFECYCLE_SWEEP_REPOS="Nishfleet/0509"
export LIFECYCLE_SWEEP_NOW="2026-09-06T17:00:00Z"
# fleet-ops#5890: the refusal-dedup state now lives in the sweep summary —
# point it at the scratch, or the test reads+writes the production state file.
export LIFECYCLE_SWEEP_SUMMARY="$scratch/summary.json"
# fleet-ops#3445: the sweep re-PATHs to /home/nish/.local/bin first and mints
# a real App token when GH_TOKEN is unset, bypassing the fake gh. Set a stub.
export GH_TOKEN="test-stub"
unset LIFECYCLE_SWEEP_DRILL || true

# 72h before NOW — any createdAt at or before this is old enough to bounce.
OLD_CREATED="2026-09-01T00:00:00Z"
NEW_CREATED="2026-09-06T10:00:00Z"

# --- Case (a): spec-carrying scout-candidate → agent-ready -----------------
cat >"$scratch/list.json" <<JSON
[{"number":1262,"title":"fix(gate): Gate-B e2e fails on every deploy","body":"Reproduces on every deploy since 2026-08-26.\n\n- required: a test that seeds a Gate-B failure and asserts the deploy halts.\n- accept: deploys halt on Gate-B failure.\n- termination: bash tests/gate-b.test.sh exits 0.\n","labels":[{"name":"scout-candidate"}],"createdAt":"$OLD_CREATED","comments":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/errA.txt")
grep -q 'admitted=1' <<<"$out" || fail "(a) admitted count: $out"
grep -q -- '--remove-label scout-candidate' "$scratch/edits.log" \
  || fail "(a) must drop scout-candidate: $(cat "$scratch/edits.log")"
grep -q -- '--add-label agent-ready' "$scratch/edits.log" \
  || fail "(a) must add agent-ready: $(cat "$scratch/edits.log")"
grep -q 'scout-candidate passed spec gate' "$scratch/comments.log" \
  || fail "(a) admit comment: $(cat "$scratch/comments.log")"
ok "(a) spec-carrying scout-candidate → agent-ready (admitted)"

# --- Case (b): spec-less scout-candidate, >72h → exactly one bounce, no
# relabel on a second sweep run --------------------------------------------
cat >"$scratch/list.json" <<JSON
[{"number":1409,"title":"fix(search): results page 500s on empty query","body":"The search results page returns a 500 when the query is empty. Reproduced locally.\n","labels":[{"name":"scout-candidate"}],"createdAt":"$OLD_CREATED","comments":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/errB1.txt")
grep -q 'bounced=1' <<<"$out" || fail "(b) first sweep bounced count: $out"
# exactly one bounce comment on the first sweep
bounce_count=$(grep -c -- 'scout-candidate-bounce:' "$scratch/comments.log" || true)
[[ "$bounce_count" -eq 1 ]] \
  || fail "(b) first sweep must post exactly one bounce comment, got $bounce_count: $(cat "$scratch/comments.log")"
# NO label edit on a bounce (the issue is left for the scout to specify)
if [[ -s "$scratch/edits.log" ]]; then
  fail "(b) first sweep must not edit labels on a bounce: $(cat "$scratch/edits.log")"
fi
ok "(b) first sweep: one bounce comment, no relabel"

# Second sweep: the bounce comment is now visible on the issue (simulated by
# reflecting it into view-1409.json, the lazy-fetch source the sweep reads
# via `gh issue view --json comments` since fleet-ops#4091). The sweep must
# NOT re-bounce and NOT relabel.
cat >"$scratch/list.json" <<JSON
[{"number":1409,"title":"fix(search): results page 500s on empty query","body":"The search results page returns a 500 when the query is empty. Reproduced locally.\n","labels":[{"name":"scout-candidate"}],"createdAt":"$OLD_CREATED","comments":[]}]
JSON
cat >"$scratch/view-1409.json" <<JSON
{"comments":[{"author":{"login":"nishfleet-worker[bot]"},"body":"scout-candidate-bounce: spec gate failed at 2026-09-06T16:00:00Z (fleet-ops#4022)\nmissing: add a \`termination:\`/\`accept:\`/\`required:\`/\`metric:\` line so this issue can be admitted to agent-ready.","createdAt":"2026-09-06T16:00:00Z"}]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/errB2.txt")
grep -q 'bounced=0' <<<"$out" || fail "(b) second sweep must not re-bounce: $out"
if [[ -s "$scratch/edits.log" ]]; then
  fail "(b) second sweep must not relabel: $(cat "$scratch/edits.log")"
fi
if [[ -s "$scratch/comments.log" ]]; then
  fail "(b) second sweep must not comment: $(cat "$scratch/comments.log")"
fi
ok "(b) second sweep: no re-bounce, no relabel (cooldown holds)"

# --- Case (c): spec-less scout-candidate younger than 72h → left alone
# (give the scout time to specify; do not bounce fresh issues) ------------
cat >"$scratch/list.json" <<JSON
[{"number":2001,"title":"fix(search): typo in empty state","body":"Just a description with no spec line.\n","labels":[{"name":"scout-candidate"}],"createdAt":"$NEW_CREATED","comments":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/errC.txt")
grep -q 'bounced=0' <<<"$out" || fail "(c) young issue must not bounce: $out"
if [[ -s "$scratch/edits.log" ]]; then
  fail "(c) young issue must not relabel: $(cat "$scratch/edits.log")"
fi
if [[ -s "$scratch/comments.log" ]]; then
  fail "(c) young issue must not be commented: $(cat "$scratch/comments.log")"
fi
ok "(c) spec-less scout-candidate younger than 72h → left alone (no premature bounce)"

# --- Case (d): unlabeled issue with a bounce comment within cooldown →
# scout-candidate is NOT re-applied (scope point 3, kills the churn loop) --
cat >"$scratch/list.json" <<JSON
[{"number":1409,"title":"fix(search): results page 500s on empty query","body":"The search results page returns a 500 when the query is empty. Reproduced locally.\n","labels":[],"createdAt":"$OLD_CREATED","comments":[]}]
JSON
cat >"$scratch/view-1409.json" <<JSON
{"comments":[{"author":{"login":"nishfleet-worker[bot]"},"body":"scout-candidate-bounce: spec gate failed at 2026-09-06T16:00:00Z (fleet-ops#4022)\nmissing: add a \`termination:\`/\`accept:\`/\`required:\`/\`metric:\` line so this issue can be admitted to agent-ready.","createdAt":"2026-09-06T16:00:00Z"}]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/errD.txt")
if grep -q -- '--add-label scout-candidate' "$scratch/edits.log"; then
  fail "(d) must NOT re-apply scout-candidate within cooldown: $(cat "$scratch/edits.log")"
fi
if [[ -s "$scratch/comments.log" ]]; then
  fail "(d) must not comment on a bounced unlabeled issue: $(cat "$scratch/comments.log")"
fi
ok "(d) unlabeled issue bounced within cooldown → scout-candidate NOT re-applied (churn loop killed)"

# --- Case (e): a spec-less scout-candidate whose bounce is OLDER than the
# cooldown re-enters the queue: the unlabeled-pass re-apply guard no longer
# blocks it, and the admission pass re-bounces (the window expired). ------
OLD_BOUNCE="2026-08-20T00:00:00Z"
cat >"$scratch/list.json" <<JSON
[{"number":1409,"title":"fix(search): results page 500s on empty query","body":"The search results page returns a 500 when the query is empty. Reproduced locally.\n","labels":[{"name":"scout-candidate"}],"createdAt":"$OLD_CREATED","comments":[]}]
JSON
cat >"$scratch/view-1409.json" <<JSON
{"comments":[{"author":{"login":"nishfleet-worker[bot]"},"body":"scout-candidate-bounce: spec gate failed at $OLD_BOUNCE (fleet-ops#4022)\nmissing: add a \`termination:\`/\`accept:\`/\`required:\`/\`metric:\` line so this issue can be admitted to agent-ready.","createdAt":"$OLD_BOUNCE"}]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/errE.txt")
grep -q 'bounced=1' <<<"$out" || fail "(e) expired cooldown must re-bounce: $out"
bounce_count=$(grep -c -- 'scout-candidate-bounce:' "$scratch/comments.log" || true)
[[ "$bounce_count" -eq 1 ]] \
  || fail "(e) expired cooldown must post exactly one new bounce, got $bounce_count: $(cat "$scratch/comments.log")"
ok "(e) bounce older than cooldown expires → re-bounce allowed (window is finite)"

# --- Case (f): discarded+scout-candidate is NOT admitted (terminal state) -
cat >"$scratch/list.json" <<JSON
[{"number":1558,"title":"Remove or document dormant channels","body":"- required: a named gate\n- accept: gate passes\n- termination: bash tests/x.test.sh\n","labels":[{"name":"scout-candidate"},{"name":"discarded"}],"createdAt":"$OLD_CREATED","comments":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/errF.txt")
grep -q 'admitted=0' <<<"$out" || fail "(f) discarded must not be admitted: $out"
if grep -q -- '--add-label agent-ready' "$scratch/edits.log"; then
  fail "(f) discarded+scout-candidate must not be admitted: $(cat "$scratch/edits.log")"
fi
ok "(f) discarded+scout-candidate is a terminal state — not admitted"

# --- Case (g): fleet-ops#5887 — parked scout-candidate that PASSES the spec
# gate must NOT be admitted. Park (awaiting-runtime-gate) wins; promotion
# is deferred. The skip line names the issue and the park label.
cat >"$scratch/list.json" <<JSON
[{"number":2213,"title":"route diet phase 1: logged-in app goes from 26 routes to 8 screens","body":"Reproduces on every deploy since 2026-08-26.\n\n- required: a test that seeds a Gate-B failure and asserts the deploy halts.\n- accept: deploys halt on Gate-B failure.\n- termination: bash tests/gate-b.test.sh exits 0.\n","labels":[{"name":"scout-candidate"},{"name":"awaiting-runtime-gate"}],"createdAt":"$OLD_CREATED","comments":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/errG.txt")
grep -q 'admitted=0' <<<"$out" || fail "(g) parked scout-candidate must not be admitted: $out"
if grep -q -- '--add-label agent-ready' "$scratch/edits.log"; then
  fail "(g) parked issue must NOT gain agent-ready: $(cat "$scratch/edits.log")"
fi
grep -q '2213: skip agent-ready (parked: awaiting-runtime-gate)' "$scratch/errG.txt" \
  || fail "(g) skip line must name the issue and park label: $(cat "$scratch/errG.txt")"
ok "(g) parked scout-candidate passing spec gate → NOT admitted; skip line logged (fleet-ops#5887)"

# --- Case (h): parked unlabeled issue must not gain scout-candidate or
# agent-ready (the unlabeled pass would otherwise queue it for admit).
cat >"$scratch/list.json" <<JSON
[{"number":2208,"title":"fix(analysis): inferDestinationType classifies apps.apple.com as app destinations","body":"Reproduces on every deploy.\n\n- required: a named gate\n- accept: gate passes\n- termination: bash tests/x.test.sh exits 0.\n","labels":[{"name":"awaiting-runtime-gate"}],"createdAt":"$OLD_CREATED","comments":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/errH.txt")
if grep -q -- '--add-label agent-ready' "$scratch/edits.log"; then
  fail "(h) parked unlabeled must NOT gain agent-ready: $(cat "$scratch/edits.log")"
fi
if grep -q -- '--add-label scout-candidate' "$scratch/edits.log"; then
  fail "(h) parked unlabeled must NOT gain scout-candidate: $(cat "$scratch/edits.log")"
fi
grep -q '2208: skip agent-ready (parked: awaiting-runtime-gate)' "$scratch/errH.txt" \
  || fail "(h) unlabeled park skip must be logged: $(cat "$scratch/errH.txt")"
ok "(h) parked unlabeled issue is left parked — no scout-candidate, no agent-ready (fleet-ops#5887)"

# --- Case (i): dual-labeled leftover agent-ready + awaiting-runtime-gate
# is healed by dropping agent-ready. Park stays on. No un-park.
cat >"$scratch/list.json" <<JSON
[{"number":2213,"title":"route diet phase 1: logged-in app goes from 26 routes to 8 screens","body":"Reproduces on every deploy.\n\n- required: a named gate\n- accept: gate passes\n- termination: bash tests/x.test.sh exits 0.\n","labels":[{"name":"agent-ready"},{"name":"awaiting-runtime-gate"}],"createdAt":"$OLD_CREATED","comments":[]}]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/errI.txt")
grep -q 'healed=1' <<<"$out" || fail "(i) dual-label heal count: $out"
grep -q -- '--remove-label agent-ready' "$scratch/edits.log" \
  || fail "(i) dual-label must drop agent-ready: $(cat "$scratch/edits.log")"
if grep -q -- '--remove-label awaiting-runtime-gate' "$scratch/edits.log"; then
  fail "(i) dual-label heal must NOT un-park: $(cat "$scratch/edits.log")"
fi
if grep -q -- '--add-label' "$scratch/edits.log"; then
  fail "(i) dual-label heal must not add any label: $(cat "$scratch/edits.log")"
fi
ok "(i) agent-ready + awaiting-runtime-gate leftover → drop agent-ready, park stays (fleet-ops#5887)"

# --- Case (j): un-park is one edit that drops the gate AND adds agent-ready.
# Nothing else in this file may remove awaiting-runtime-gate without adding
# agent-ready on the same line.
grep -q -- '--remove-label awaiting-runtime-gate --add-label agent-ready' "$bin" \
  || fail "(j) unpark_runtime_gate must pair both flags on one gh issue edit"
while IFS= read -r line; do
  printf '%s' "$line" | grep -q -- '--add-label agent-ready' \
    || fail "(j) every awaiting-runtime-gate remove must also add agent-ready: $line"
done < <(grep -- '--remove-label awaiting-runtime-gate' "$bin" || true)
ok "(j) un-park path is one edit: drop awaiting-runtime-gate + add agent-ready (fleet-ops#5887)"

# --- Case (k): --unpark REPO#NUM is the sanctioned restore: one edit drops
# the park and adds agent-ready; it refuses a non-parked issue.
cat >"$scratch/api-issue.json" <<'JSON'
["awaiting-runtime-gate"]
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"
out=$("$bin" --unpark Nishfleet/0509#2213 2>"$scratch/errK.txt") \
  || fail "(k) --unpark exit: $(cat "$scratch/errK.txt")"
grep -q -- '--remove-label awaiting-runtime-gate --add-label agent-ready' "$scratch/edits.log" \
  || fail "(k) --unpark must pair both flags in one edit: $(cat "$scratch/edits.log")"
[ "$(grep -c 'issue edit' "$scratch/edits.log")" = "1" ] \
  || fail "(k) --unpark must be exactly one edit: $(cat "$scratch/edits.log")"
grep -q 'un-park awaiting-runtime-gate by fleet-heartbeat' "$scratch/comments.log" \
  || fail "(k) --unpark must leave an audit comment: $(cat "$scratch/comments.log")"
ok "(k) --unpark restores agent-ready in the same edit that drops the park (fleet-ops#5887)"

# --- Case (l): --unpark refuses an issue that does not carry the park.
cat >"$scratch/api-issue.json" <<'JSON'
["agent-ready"]
JSON
: >"$scratch/edits.log"
if "$bin" --unpark Nishfleet/0509#2213 >"$scratch/outL.txt" 2>&1; then
  fail "(l) --unpark must refuse a non-parked issue: $(cat "$scratch/outL.txt")"
fi
grep -q 'nothing to un-park' "$scratch/outL.txt" \
  || fail "(l) refusal must say why: $(cat "$scratch/outL.txt")"
[ ! -s "$scratch/edits.log" ] \
  || fail "(l) refusal must not edit: $(cat "$scratch/edits.log")"
ok "(l) --unpark refuses a non-parked issue without editing (fleet-ops#5887)"

echo "all lifecycle-label-sweep-admission cases passed"
