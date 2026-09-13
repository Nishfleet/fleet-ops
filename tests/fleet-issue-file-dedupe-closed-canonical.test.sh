#!/usr/bin/env bash
# tests/fleet-issue-file-dedupe-closed-canonical.test.sh
#
# fleet-ops#5666: the file-time dedupe corpus was open-only, so a detector
# re-firing on stale state re-filed a blocker whose canonical had just
# closed-as-delivered — land-or-close #5652 closed at 00:16Z when PR #5544
# merged, and a stale-observation audit re-filed the same blocker as #5666
# at 00:41Z (zero open issues named the PR, so nothing deduped it).
#
# fleet-ops#5687 (reopened): the #5666 fix suppressed the re-filing into a
# COMMENT on the closed canonical — a silent drop, since nobody claims a
# closed issue and the intake never sees it. A closed-delivered canonical
# match now re-files as a NEW claimable issue that links the canonical
# (recurrence marker), plus a best-effort link-back comment on the canonical.
#
# Proves, offline with a fake gh:
#   1. A filing matching a closed-delivered canonical is re-FILED
#      (action=filed-recurrence, canonical_state=closed, recurrence-of
#      marker in the body, agent-ready defaulted when no labels passed)
#      and the canonical gets a link-back comment.
#   2. A completed close with NO closing-PR reference does not link.
#   3. A NOT_PLANNED close does not link (mass-close guard's fight).
#   4. A delivered close older than the window does not link.
#   5. FLEET_ISSUE_FILE_CLOSED_HOURS=0 disables the closed corpus.
#   6. An OPEN duplicate still wins over a closed canonical (comment path).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/issue-file.py"
bin="$repo_root/bin/fleet-issue-file"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$bin" ]] || fail "missing $bin"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$lib" \
  || fail "issue-file.py failed to parse"

scratch=$(mktemp -d -t file-dedupe-closed.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/fakebin"
cat >"$scratch/fakebin/gh" <<'GH'
#!/usr/bin/env bash
state=""
if [[ "$1 $2" == "issue list" ]]; then
  for a in "$@"; do [[ "$a" == "--state" ]] && want=1 || { [[ "${want:-}" == 1 ]] && { state="$a"; want=0; }; }; done
  if [[ "$state" == "closed" ]]; then
    if [[ -f "${GH_CLOSED_JSON:-/dev/null}" ]]; then cat "${GH_CLOSED_JSON}"; else printf '[]\n'; fi
  else
    if [[ -f "${GH_OPEN_JSON:-/dev/null}" ]]; then cat "${GH_OPEN_JSON}"; else printf '[]\n'; fi
  fi
elif [[ "$1 $2" == "issue comment" ]]; then
  echo "commented $3" >>"${GH_COMMENTED:-/dev/null}"
elif [[ "$1 $2" == "issue create" ]]; then
  echo "created args=$*" >>"${GH_CREATED:-/dev/null}"
  prev=""; for a in "$@"; do
    [[ "$prev" == "--body-file" ]] && cat "$a" >>"${GH_CREATE_BODY:-/dev/null}"
    [[ "$prev" == "--body" ]] && printf '%s\n' "$a" >>"${GH_CREATE_BODY:-/dev/null}"
    prev="$a"
  done
  echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
elif [[ "$1 $2" == "issue view" ]]; then
  if [[ -f "${GH_COMMENT_FIXTURE:-/dev/null}" ]]; then cat "${GH_COMMENT_FIXTURE}"; else printf '{"comments":[]}\n'; fi
fi
exit 0
GH
chmod +x "$scratch/fakebin/gh"

export GH="$scratch/fakebin/gh"
export GH_COMMENTED="$scratch/commented"
export GH_CREATED="$scratch/created"
export GH_CREATE_BODY="$scratch/create-body"
export GH_OPEN_JSON="$scratch/gh-open.json"
export GH_CLOSED_JSON="$scratch/gh-closed.json"
: >"$GH_COMMENTED"
: >"$GH_CREATED"
: >"$GH_CREATE_BODY"
printf '[]\n' >"$GH_OPEN_JSON"
printf '{"comments":[]}\n' >"$scratch/comments-empty.json"
export GH_COMMENT_FIXTURE="$scratch/comments-empty.json"

title="land-or-close: PR #5544 (issue-file dedupe re-post suppression) is CONFLICTING — dedupe spam growing"
body="metric: PR #5544 must land or close. observed: CONFLICTING. accept: rebase or close with evidence."

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
old_iso="$(date -u -d '100 hours ago' +%Y-%m-%dT%H:%M:%SZ)"

run_file() {
  "$bin" file --repo Nishfleet/fleet-ops --title "$title" --body "$body" --json \
    >"$scratch/out.json" 2>"$scratch/err"
}

# --- 1. Closed-delivered canonical re-files as a NEW claimable issue --------
# fleet-ops#5687 (reopened): commenting on the closed ticket was a silent
# drop — nobody claims a closed issue. The match must produce a NEW issue
# that links the canonical, claimable by the intake (agent-ready by default).
cat >"$GH_CLOSED_JSON" <<JSON
[{"number":5652,"title":"$title","body":"$body","url":"https://github.com/Nishfleet/fleet-ops/issues/5652","labels":[],"closedAt":"$now_iso","stateReason":"COMPLETED","closedByPullRequestsReferences":[{"number":5544}]}]
JSON
run_file || fail "run 1 exited nonzero"
python3 -c "import json;d=json.load(open('$scratch/out.json'));assert d['action']=='filed-recurrence',d;assert d.get('canonical_state')=='closed',d;assert d['number']==9999,d;assert d['existing']=='Nishfleet/fleet-ops#5652',d" \
  || fail "run 1 should re-file a new issue linking the closed canonical"
[[ -s "$GH_CREATED" ]] || fail "closed-canonical match must create a new issue"
grep -q -- "--label agent-ready" "$GH_CREATED" \
  || fail "unlabeled recurrence filing must default to agent-ready (claimable)"
grep -q "recurrence-of: Nishfleet/fleet-ops#5652" "$GH_CREATE_BODY" \
  || fail "filed body must carry the recurrence-of marker linking the canonical"
[[ -s "$GH_COMMENTED" ]] || fail "expected the link-back comment on the closed canonical"
grep -q "commented 5652" "$GH_COMMENTED" \
  || fail "link-back comment must land on the closed canonical #5652"
ok "closed-delivered canonical re-files as NEW agent-ready issue + link-back comment"

# --- 6. Re-fire while the recurrence issue is open dedupes onto it ----------
# The recurrence issue is OPEN, so the open corpus — not the closed corpus —
# is the dedupe target: the second filing comments on the open issue.
cat >"$GH_OPEN_JSON" <<JSON
[{"number":9999,"title":"$title","body":"recurrence-of marker\n\n$body","url":"https://github.com/Nishfleet/fleet-ops/issues/9999","labels":[{"name":"agent-ready"}]}]
JSON
: >"$GH_CREATED"; : >"$GH_COMMENTED"; : >"$GH_CREATE_BODY"
run_file || fail "run 2 (recurrence open) exited nonzero"
python3 -c "import json;d=json.load(open('$scratch/out.json'));assert d['action']=='commented',d;assert d['number']==9999,d;assert 'canonical_state' not in d,d" \
  || fail "re-fire while the recurrence issue is open must comment on it"
[[ ! -s "$GH_CREATED" ]] || fail "open duplicate must not re-file"
ok "re-fire while recurrence issue is open dedupes onto the open issue"
printf '[]\n' >"$GH_OPEN_JSON"

# --- 2. Completed close with no delivering PR must not suppress --------------
cat >"$GH_CLOSED_JSON" <<JSON
[{"number":5652,"title":"$title","body":"$body","url":"u","labels":[],"closedAt":"$now_iso","stateReason":"COMPLETED","closedByPullRequestsReferences":[]}]
JSON
: >"$GH_CREATED"; : >"$GH_COMMENTED"
run_file || fail "run 3 exited nonzero"
python3 -c "import json;d=json.load(open('$scratch/out.json'));assert d['action']=='filed',d" \
  || fail "completed close without a closing PR must still file"
[[ -s "$GH_CREATED" ]] || fail "expected a create for undelivered close"
ok "completed close with no closing-PR reference does not suppress"

# --- 3. NOT_PLANNED close must not suppress -----------------------------------
cat >"$GH_CLOSED_JSON" <<JSON
[{"number":5652,"title":"$title","body":"$body","url":"u","labels":[],"closedAt":"$now_iso","stateReason":"NOT_PLANNED","closedByPullRequestsReferences":[{"number":5544}]}]
JSON
: >"$GH_CREATED"
run_file || fail "run 4 exited nonzero"
[[ -s "$GH_CREATED" ]] || fail "not_planned close must not suppress a filing"
ok "not_planned close does not suppress"

# --- 4. Delivered close older than the window must not suppress ---------------
cat >"$GH_CLOSED_JSON" <<JSON
[{"number":5652,"title":"$title","body":"$body","url":"u","labels":[],"closedAt":"$old_iso","stateReason":"COMPLETED","closedByPullRequestsReferences":[{"number":5544}]}]
JSON
: >"$GH_CREATED"
run_file || fail "run 5 exited nonzero"
[[ -s "$GH_CREATED" ]] || fail "closed canonical outside the window must not suppress"
ok "stale closed canonical outside window does not suppress"

# --- 5. Window disabled via env ----------------------------------------------
cat >"$GH_CLOSED_JSON" <<JSON
[{"number":5652,"title":"$title","body":"$body","url":"u","labels":[],"closedAt":"$now_iso","stateReason":"COMPLETED","closedByPullRequestsReferences":[{"number":5544}]}]
JSON
: >"$GH_CREATED"
FLEET_ISSUE_FILE_CLOSED_HOURS=0 run_file || fail "run 6 exited nonzero"
[[ -s "$GH_CREATED" ]] || fail "FLEET_ISSUE_FILE_CLOSED_HOURS=0 must disable the closed corpus"
ok "FLEET_ISSUE_FILE_CLOSED_HOURS=0 disables closed-canonical dedupe"

# --- 7. Open duplicate still wins over a closed canonical ---------------------
cat >"$GH_OPEN_JSON" <<JSON
[{"number":6000,"title":"$title","body":"$body","url":"u6000","labels":[]}]
JSON
: >"$GH_CREATED"; : >"$GH_COMMENTED"
run_file || fail "run 7 exited nonzero"
python3 -c "import json;d=json.load(open('$scratch/out.json'));assert d['action']=='commented',d;assert d['number']==6000,d;assert 'canonical_state' not in d,d" \
  || fail "open duplicate must stay the canonical"
ok "open canonical still wins over closed-delivered match"

echo "file-dedupe-closed-canonical: all checks passed"
