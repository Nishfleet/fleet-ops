#!/usr/bin/env bash
# tests/blocked-reconcile.test.sh
#
# Proves the agent-blocked reconciler (fleet-ops#29):
#   - work-item deps come from blocked-on: lines, "blocked by #N", and
#     GitHub's native blockedBy field — not from prose #N mentions
#   - a closed issue / merged PR requeues (agent-blocked → agent-ready)
#   - a closed-unmerged PR does not
#   - nish-decision issues stay labelled and are published with count+age
#   - overlapping sweeps no-op
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/blocked-reconcile"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

extract() {
    printf '%s' "$1" | "$bin" --extract
}

# --- extract: machine-checkable vs nish-decision --------------------------
got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"do the thing","body":"blocked-on: #10\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "work-item" ]] || fail "blocked-on #10 should be work-item: $got"
[[ "$(printf '%s' "$got" | jq -r '.deps[0].ref')" == "Nishfleet/0509#10" ]] || fail "dep ref: $got"
ok "blocked-on: #10 is a work-item dep"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"do the thing","body":"blocked-on: Nishfleet/fleet-ops#29\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.deps[0].ref')" == "Nishfleet/fleet-ops#29" ]] || fail "cross-repo: $got"
ok "blocked-on: owner/repo#n is a cross-repo dep"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"do the thing","body":"blocked-on: https://github.com/Nishfleet/0509/pull/88\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.deps[0].hint')" == "pr" ]] || fail "pr url hint: $got"
[[ "$(printf '%s' "$got" | jq -r '.deps[0].number')" == "88" ]] || fail "pr url number: $got"
ok "blocked-on: pull URL is a PR dep"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"Fix sitemap (blocked by #937)","body":"wait","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "work-item" ]] || fail "title blocked by #N: $got"
[[ "$(printf '%s' "$got" | jq -r '.deps[0].ref')" == "Nishfleet/0509#937" ]] || fail "title dep: $got"
ok "title 'blocked by #N' is a work-item dep"

got=$(extract '{"repo":"Nishfleet/0509","number":964,"title":"GEO: make the Offer Timeline citable (blocked by Bet-3)","body":"metric: x","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "nish-decision" ]] || fail "Bet-3 should be nish-decision: $got"
[[ "$(printf '%s' "$got" | jq '.deps|length')" == "0" ]] || fail "Bet-3 must not invent a dep: $got"
ok "title 'blocked by Bet-3' is a nish-decision, not a dep"

got=$(extract '{"repo":"Nishfleet/0509","number":963,"title":"re-add pages once they serve 200","body":"dropped from SITEMAP_PATHS in #937 because they returned 404","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "nish-decision" ]] || fail "prose #937 must not be a dep: $got"
[[ "$(printf '%s' "$got" | jq '.deps|length')" == "0" ]] || fail "prose #937 leaked as dep: $got"
ok "prose #N mention is ignored"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"blocked-on: nish-decision\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "nish-decision" ]] || fail "explicit nish-decision: $got"
ok "explicit blocked-on: nish-decision"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"blocked-on: #10\nblocked-on: nish-decision\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "nish-decision" ]] || fail "nish marker wins over dep: $got"
[[ "$(printf '%s' "$got" | jq '.deps|length')" == "1" ]] || fail "dep still recorded: $got"
ok "nish-decision marker wins; dep is recorded but not auto-requeued"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"go","comments":[{"body":"claimed by pi-issue-0509-50 at 2026-08-25T05:47:37Z"}]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "nish-decision" ]] || fail "claim comment: $got"
ok "claim comments are ignored"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"go","blockedBy":[{"number":12,"state":"OPEN","repository":{"nameWithOwner":"Nishfleet/0509"}}]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "work-item" ]] || fail "native blockedBy: $got"
[[ "$(printf '%s' "$got" | jq -r '.deps[0].ref')" == "Nishfleet/0509#12" ]] || fail "native dep: $got"
[[ "$(printf '%s' "$got" | jq -r '.deps[0].state')" == "open" ]] || fail "native state: $got"
ok "GitHub native blockedBy is a work-item dep"

got=$(extract '{"repo":"Nishfleet/0509","number":10,"title":"x","body":"blocked-on: #10\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq '.deps|length')" == "0" ]] || fail "self-ref: $got"
ok "self-reference is ignored"

# --- live sweep with mocked gh --------------------------------------------
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/api/Nishfleet/0509/issues" "$scratch/api/Nishfleet/0509/pulls"

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
        cat "$FAKE_DIR/view-${3}.json"
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
      *) echo "unexpected gh issue $*" >&2; exit 1 ;;
    esac
    ;;
  api)
    if [[ "${2:-}" == "graphql" ]]; then
      # Default: no native blockedBy. Per-issue override via graphql-<num>.json
      # is not parsed from argv here; tests that need native blockedBy write
      # graphql.json with the node already in state.
      if [[ -f "$FAKE_DIR/graphql.json" ]]; then
        cat "$FAKE_DIR/graphql.json"
        exit 0
      fi
      echo '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[]}}}}}'
      exit 0
    fi
    if [[ "${2:-}" == "-X" && "${3:-}" == "PATCH" ]]; then
      printf '%s\n' "$*" >>"$FAKE_DIR/patches.log"
      exit 0
    fi
    path="$2"
    if [[ "$path" == repos/*/issues/*/comments ]]; then
      echo '[]'
      exit 0
    fi
    rel="${path#repos/}"
    f="$FAKE_DIR/api/${rel}.json"
    if [[ -f "$f" ]]; then
      cat "$f"
      exit 0
    fi
    echo '{"message":"Not Found"}' >&2
    exit 1
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$scratch/bin/gh"
export FAKE_DIR="$scratch"
export PATH="$scratch/bin:$PATH"
export BLOCKED_RECONCILE_LOCKDIR="$scratch/lock"
export BLOCKED_RECONCILE_TRIAGE="$scratch/triage.md"
export BLOCKED_RECONCILE_STATE="$scratch/state.json"
export BLOCKED_RECONCILE_REPOS="Nishfleet/0509"
export BLOCKED_RECONCILE_NOW="2026-08-26T00:00:00Z"
export BLOCKED_RECONCILE_STICKY_SECS=0

# Case 1: closed issue dep → requeue
cat >"$scratch/list.json" <<'JSON'
[{"number":50,"title":"do the thing","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-50.json" <<'JSON'
{"title":"do the thing","body":"blocked-on: #10\n","createdAt":"2026-08-25T06:00:00Z","comments":[]}
JSON
echo '{"state":"closed"}' >"$scratch/api/Nishfleet/0509/issues/10.json"
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err1.txt")
grep -q 'count=0' <<<"$out" || fail "requeue should drain count: $out"
grep -q 'requeued=1' <<<"$out" || fail "requeue count: $out"
grep -q 'remove-label agent-blocked' "$scratch/edits.log" || fail "missing label remove: $(cat "$scratch/edits.log")"
grep -q 'add-label agent-ready' "$scratch/edits.log" || fail "missing label add: $(cat "$scratch/edits.log")"
grep -q 'blocker cleared' "$scratch/comments.log" || fail "missing requeue comment: $(cat "$scratch/comments.log")"
ok "closed issue dep requeues to agent-ready"

# Case 2: open issue dep → still blocked, published
cat >"$scratch/list.json" <<'JSON'
[{"number":51,"title":"wait","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-51.json" <<'JSON'
{"title":"wait","body":"blocked-on: #10\n","createdAt":"2026-08-25T06:00:00Z","comments":[]}
JSON
echo '{"state":"open"}' >"$scratch/api/Nishfleet/0509/issues/10.json"
: >"$scratch/edits.log"
: >"$scratch/comments.log"
rm -f "$scratch/state.json"

out=$("$bin" 2>"$scratch/err2.txt")
grep -q 'count=1' <<<"$out" || fail "open dep should stay: $out"
grep -q 'requeued=0' <<<"$out" || fail "should not requeue: $out"
[[ -s "$scratch/edits.log" ]] && fail "must not edit labels when still blocked: $(cat "$scratch/edits.log")"
grep -q 'blocked-checked:' "$scratch/comments.log" || fail "missing last-checked: $(cat "$scratch/comments.log")"
[[ "$(jq -r '.count' "$scratch/state.json")" == "1" ]] || fail "state count: $(cat "$scratch/state.json")"
[[ "$(jq -r '.oldest' "$scratch/state.json")" == "Nishfleet/0509#51" ]] || fail "oldest ref: $(cat "$scratch/state.json")"
[[ "$(jq -r '.oldest_age_h' "$scratch/state.json")" == "18" ]] || fail "oldest age: $(cat "$scratch/state.json")"
grep -q 'count: 1' "$scratch/triage.md" || fail "triage missing count: $(cat "$scratch/triage.md")"
grep -q 'Nishfleet/0509#51' "$scratch/triage.md" || fail "triage missing item: $(cat "$scratch/triage.md")"
ok "open dep stays blocked; count and oldest age are published"

# Case 3: nish-decision (live 0509#964 shape) → desk-triage, no requeue
cat >"$scratch/list.json" <<'JSON'
[{"number":964,"title":"GEO: make the Offer Timeline citable (blocked by Bet-3)","createdAt":"2026-08-25T05:48:35Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-964.json" <<'JSON'
{"title":"GEO: make the Offer Timeline citable (blocked by Bet-3)","body":"metric: the ledger","createdAt":"2026-08-25T05:48:35Z","comments":[]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err3.txt")
grep -q 'count=1' <<<"$out" || fail "nish-decision stays in queue: $out"
[[ -s "$scratch/edits.log" ]] && fail "nish-decision must not flip labels: $(cat "$scratch/edits.log")"
grep -q 'kind=nish-decision' "$scratch/comments.log" || fail "sticky should name nish-decision: $(cat "$scratch/comments.log")"
grep -q 'kind=nish-decision' "$scratch/triage.md" || fail "triage should name nish-decision: $(cat "$scratch/triage.md")"
ok "nish-decision stays labelled and surfaces on the desk-triage file"

# Case 4: merged PR requeues; closed-unmerged PR does not
cat >"$scratch/list.json" <<'JSON'
[{"number":70,"title":"after the pr","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-70.json" <<'JSON'
{"title":"after the pr","body":"blocked-on: https://github.com/Nishfleet/0509/pull/88\n","createdAt":"2026-08-25T06:00:00Z","comments":[]}
JSON
echo '{"state":"closed","pull_request":{}}' >"$scratch/api/Nishfleet/0509/issues/88.json"
echo '{"state":"closed","merged":true}' >"$scratch/api/Nishfleet/0509/pulls/88.json"
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err4.txt")
grep -q 'requeued=1' <<<"$out" || fail "merged PR should requeue: $out"
ok "merged PR dep requeues"

echo '{"state":"closed","merged":false}' >"$scratch/api/Nishfleet/0509/pulls/88.json"
: >"$scratch/edits.log"
: >"$scratch/comments.log"
out=$("$bin" 2>"$scratch/err5.txt")
grep -q 'requeued=0' <<<"$out" || fail "closed-unmerged PR must not requeue: $out"
grep -q 'count=1' <<<"$out" || fail "closed-unmerged stays: $out"
ok "closed-unmerged PR does not requeue"

# Case 5: agent-in-progress skip
cat >"$scratch/list.json" <<'JSON'
[{"number":80,"title":"claimed","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"},{"name":"agent-in-progress"}]}]
JSON
: >"$scratch/edits.log"
out=$("$bin" 2>"$scratch/err6.txt")
grep -q 'requeued=0' <<<"$out" || fail "in-progress skip requeued: $out"
[[ -s "$scratch/edits.log" ]] && fail "in-progress must not edit: $(cat "$scratch/edits.log")"
ok "agent-in-progress + agent-blocked is left alone"

# Case 6: overlapping flock no-op
export BLOCKED_RECONCILE_LOCKDIR="$scratch/lock-overlap"
mkdir -p "$BLOCKED_RECONCILE_LOCKDIR"
exec 9>"$BLOCKED_RECONCILE_LOCKDIR/sweep.lock"
flock -n 9 || fail "could not hold overlap lock"
out=$("$bin" 2>"$scratch/err7.txt")
exec 9>&-
printf '%s\n' "$out" | grep -q 'no-op' || fail "overlap must print no-op, got: $out"
ok "overlapping sweep is a no-op"

# Case 7: contracts exist so the classifier keeps working
grep -q 'blocked-on:' "$repo_root/prompts/worker.md" || fail "worker.md must tell workers to write blocked-on: lines"
grep -q 'blocked-reconcile' "$repo_root/bin/fleet-heartbeat-tier1" || fail "tier1 must call blocked-reconcile"
ok "worker.md and heartbeat-tier1 carry the contract"
