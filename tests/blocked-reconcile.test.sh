#!/usr/bin/env bash
# tests/blocked-reconcile.test.sh
#
# Proves the agent-blocked reconciler (fleet-ops#29 / #364):
#   - work-item deps come from blocked-on: lines, "blocked by #N", and
#     GitHub's native blockedBy field — not from prose #N mentions
#   - a closed issue / merged PR requeues (agent-blocked → agent-ready)
#   - a closed-unmerged PR does not
#   - nish-decision issues stay labelled until a later comment carries
#     `decision-resolved:` with no live `blocked-on:` (fleet-ops#563);
#     then they requeue from live state
#   - struck-through ~~blocked-on:~~ body lines are ignored
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

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"blocked-on: #10\nblocked-on: nish-decision\nlegal review needed.\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "nish-decision" ]] || fail "valid nish marker wins over dep: $got"
[[ "$(printf '%s' "$got" | jq '.deps|length')" == "1" ]] || fail "dep still recorded: $got"
[[ "$(printf '%s' "$got" | jq -r '.rejected_count')" == "0" ]] || fail "valid nish must not be rejected: $got"
ok "valid nish-decision marker wins; dep is recorded but not auto-requeued"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"blocked-on: #10\nblocked-on: nish-decision\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "work-item" ]] || fail "invalid nish rewritten; dep becomes the blocker: $got"
[[ "$(printf '%s' "$got" | jq '.deps|length')" == "1" ]] || fail "dep still recorded: $got"
[[ "$(printf '%s' "$got" | jq -r '.rejected_count')" == "1" ]] || fail "invalid nish must be rejected: $got"
[[ "$(printf '%s' "$got" | jq -r '.orchestrator')" == "true" ]] || fail "orchestrator flag must be set: $got"
[[ "$(printf '%s' "$got" | jq -r '.rejected_nish_decisions[0].new_text')" == *"blocked-on: orchestrator"* ]] || fail "nish must be rewritten to orchestrator: $got"
ok "invalid nish-decision is rewritten to orchestrator; dep remains"

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

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"blocked-on: nish-decision\nmoney\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.nish')" == "true" ]] || fail "valid nish flag: $got"
[[ "$(printf '%s' "$got" | jq -r '.nish_resolved')" == "false" ]] || fail "unresolved valid nish: $got"
[[ "$(printf '%s' "$got" | jq -r '.rejected_count')" == "0" ]] || fail "valid nish must not be rejected: $got"
ok "valid unresolved nish-decision sets nish=true nish_resolved=false"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"blocked-on: nish-decision\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.nish')" == "false" ]] || fail "invalid nish must be rewritten: $got"
[[ "$(printf '%s' "$got" | jq -r '.orchestrator')" == "true" ]] || fail "orchestrator flag must be set: $got"
[[ "$(printf '%s' "$got" | jq -r '.rejected_count')" == "1" ]] || fail "invalid nish must be rejected: $got"
ok "invalid nish-decision is rejected and becomes orchestrator"

# fleet-ops#364 fixture body: closed-deps-plus-nish, matching #180's shape.
got=$(extract '{"repo":"Nishfleet/fleet-ops","number":180,"title":"gap-closure loop","body":"blocked-on: #149\nblocked-on: #153\nblocked-on: nish-decision\n","comments":[{"body":"approved as written. Claim and build.\n\ndecision-resolved:\n"}]}')
[[ "$(printf '%s' "$got" | jq -r '.nish')" == "true" ]] || fail "180 nish: $got"
[[ "$(printf '%s' "$got" | jq -r '.nish_resolved')" == "true" ]] || fail "180 resolved: $got"
[[ "$(printf '%s' "$got" | jq '.deps|length')" == "2" ]] || fail "180 deps: $got"
[[ "$(printf '%s' "$got" | jq -r '.deps[0].ref')" == "Nishfleet/fleet-ops#149" ]] || fail "180 dep0: $got"
ok "decision-resolved: in a later comment marks nish-decision resolved; deps stay recorded"

# fleet-ops#563 / #145 shape: worker ask with copy-paste example + live blocked-on.
# The task is not a valid nish-decision reason, so the lines are rejected and
# rerouted to the orchestrator.
got=$(extract '{"repo":"Nishfleet/fleet-ops","number":145,"title":"red-on-main: Repo standards sync","body":"blocked-on: nish-decision\n","comments":[{"body":"Rotate FLEET_SYNC_PAT. When that dispatch is green, copy this line:\n\ndecision-resolved: FLEET_SYNC_PAT rotated\n\nblocked-on: nish-decision\n"}]}')
[[ "$(printf '%s' "$got" | jq -r '.nish')" == "false" ]] || fail "145 nish must be rejected: $got"
[[ "$(printf '%s' "$got" | jq -r '.nish_resolved')" == "false" ]] || fail "145 worker ask must not resolve: $got"
[[ "$(printf '%s' "$got" | jq -r '.orchestrator')" == "true" ]] || fail "145 orchestrator flag: $got"
[[ "$(printf '%s' "$got" | jq -r '.rejected_count')" == "2" ]] || fail "145 rejected count: $got"
ok "#145 worker ask with invalid nish-decision is rerouted to orchestrator"

got=$(extract '{"repo":"Nishfleet/fleet-ops","number":145,"title":"red-on-main: Repo standards sync","body":"blocked-on: nish-decision\n","comments":[{"body":"Rotate FLEET_SYNC_PAT. When that dispatch is green, copy this line:\n\ndecision-resolved: FLEET_SYNC_PAT rotated\n\nblocked-on: nish-decision\n"},{"body":"decision-resolved: FLEET_SYNC_PAT rotated\n"}]}')
[[ "$(printf '%s' "$got" | jq -r '.nish_resolved')" == "true" ]] || fail "145 later marker must resolve: $got"
ok "#145 later comment that is only the marker extracts nish_resolved=true"

got=$(extract '{"repo":"Nishfleet/fleet-ops","number":145,"title":"red-on-main: Repo standards sync","body":"blocked-on: nish-decision\n","comments":[{"body":"Rotate FLEET_SYNC_PAT.\n\ndecision-resolved: FLEET_SYNC_PAT rotated\n\nblocked-on: nish-decision\n"},{"body":"~~blocked-on: nish-decision~~\n\ndecision-resolved: FLEET_SYNC_PAT rotated\n"}]}')
[[ "$(printf '%s' "$got" | jq -r '.nish_resolved')" == "true" ]] || fail "145 struck+marker must resolve: $got"
ok "later comment with struck blocked-on plus marker extracts nish_resolved=true"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"blocked-on: nish-decision\ndecision-resolved: example\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.nish_resolved')" == "false" ]] || fail "body ask must not resolve: $got"
ok "issue body with live blocked-on: plus a decision-resolved: example stays unresolved"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"~~blocked-on: nish-decision~~\ndecision-resolved:\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.nish_resolved')" == "true" ]] || fail "struck body plus marker: $got"
ok "body with struck blocked-on plus decision-resolved: extracts nish_resolved=true"

got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"~~blocked-on: #10~~\n~~blocked-on: nish-decision~~\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq '.deps|length')" == "0" ]] || fail "struck dep leaked: $got"
[[ "$(printf '%s' "$got" | jq -r '.nish')" == "false" ]] || fail "struck nish leaked: $got"
ok "struck-through blocked-on lines are ignored"

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

# Case 6: fleet-ops#364 fixture — closed issue deps + unanswered invalid nish-decision
# stay blocked and are rerouted to the orchestrator.
mkdir -p "$scratch/api/Nishfleet/0509/issues"
cat >"$scratch/list.json" <<'JSON'
[{"number":180,"title":"gap-closure loop","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-180.json" <<'JSON'
{"title":"gap-closure loop","body":"blocked-on: #149\nblocked-on: #153\nblocked-on: nish-decision\n","createdAt":"2026-08-25T06:00:00Z","comments":[]}
JSON
echo '{"state":"closed"}' >"$scratch/api/Nishfleet/0509/issues/149.json"
echo '{"state":"closed"}' >"$scratch/api/Nishfleet/0509/issues/153.json"
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err180-blocked.txt")
grep -q 'requeued=0' <<<"$out" || fail "unanswered nish must not requeue: $out"
grep -q 'count=1' <<<"$out" || fail "unanswered nish stays in queue: $out"
grep -q 'add-label needs-orchestrator' "$scratch/edits.log" || fail "invalid nish must get needs-orchestrator label: $(cat "$scratch/edits.log")"
grep -q 'blocked-on: orchestrator' "$scratch/edits.log" || fail "invalid nish body must be rewritten: $(cat "$scratch/edits.log")"
grep -q 'remaining=orchestrator' "$scratch/comments.log" || fail "sticky should name remaining orchestrator: $(cat "$scratch/comments.log")"
[[ "$(jq -r '.rejected_nish_decisions' "$scratch/state.json")" == "1" ]] || fail "state must record one rejected nish: $(cat "$scratch/state.json")"
ok "closed deps + invalid nish-decision stay blocked and route to orchestrator"

# Case 7: same fixture body, later comment has decision-resolved: → requeue
cat >"$scratch/view-180.json" <<'JSON'
{"title":"gap-closure loop","body":"blocked-on: #149\nblocked-on: #153\nblocked-on: nish-decision\n","createdAt":"2026-08-25T06:00:00Z","comments":[{"body":"approved as written. Claim and build.\n\ndecision-resolved:\n"}]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err180-resolved.txt")
grep -q 'requeued=1' <<<"$out" || fail "resolved nish + closed deps should requeue: $out"
grep -q 'count=0' <<<"$out" || fail "resolved fixture should drain: $out"
grep -q 'remove-label agent-blocked' "$scratch/edits.log" || fail "364 missing label remove: $(cat "$scratch/edits.log")"
grep -q 'add-label agent-ready' "$scratch/edits.log" || fail "364 missing label add: $(cat "$scratch/edits.log")"
grep -q 'blocker cleared' "$scratch/comments.log" || fail "364 missing evidence comment: $(cat "$scratch/comments.log")"
grep -q 'nish-decision' "$scratch/comments.log" || fail "evidence should name nish-decision: $(cat "$scratch/comments.log")"
ok "fixture body + decision-resolved: requeues from live state"

# Case 7b: fleet-ops#563 / #145 shape — worker ask must not requeue; later marker must
cat >"$scratch/list.json" <<'JSON'
[{"number":145,"title":"red-on-main: Repo standards sync","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-145.json" <<'JSON'
{"title":"red-on-main: Repo standards sync","body":"blocked-on: nish-decision\n","createdAt":"2026-08-25T06:00:00Z","comments":[{"body":"Rotate FLEET_SYNC_PAT. When that dispatch is green, copy this line:\n\ndecision-resolved: FLEET_SYNC_PAT rotated\n\nblocked-on: nish-decision\n"}]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err145-ask.txt")
grep -q 'requeued=0' <<<"$out" || fail "#145 worker ask must not requeue: $out"
grep -q 'count=1' <<<"$out" || fail "#145 worker ask stays in queue: $out"
grep -q 'add-label needs-orchestrator' "$scratch/edits.log" || fail "#145 worker ask must get needs-orchestrator: $(cat "$scratch/edits.log")"
grep -q 'blocked-on: orchestrator' "$scratch/edits.log" || fail "#145 worker ask body must be rewritten: $(cat "$scratch/edits.log")"
grep -q 'remaining=orchestrator' "$scratch/comments.log" || fail "#145 sticky should name orchestrator: $(cat "$scratch/comments.log")"
ok "#145 worker ask with invalid nish-decision is rerouted to orchestrator"

cat >"$scratch/view-145.json" <<'JSON'
{"title":"red-on-main: Repo standards sync","body":"blocked-on: nish-decision\n","createdAt":"2026-08-25T06:00:00Z","comments":[{"body":"Rotate FLEET_SYNC_PAT. When that dispatch is green, copy this line:\n\ndecision-resolved: FLEET_SYNC_PAT rotated\n\nblocked-on: nish-decision\n"},{"body":"decision-resolved: FLEET_SYNC_PAT rotated\n"}]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err145-resolved.txt")
grep -q 'requeued=1' <<<"$out" || fail "#145 later marker should requeue: $out"
grep -q 'count=0' <<<"$out" || fail "#145 later marker should drain: $out"
grep -q 'remove-label agent-blocked' "$scratch/edits.log" || fail "#145 missing label remove: $(cat "$scratch/edits.log")"
grep -q 'add-label agent-ready' "$scratch/edits.log" || fail "#145 missing label add: $(cat "$scratch/edits.log")"
ok "#145 later comment that is only the marker requeues from live state"

# Case 7c: invalid nish-decision in a comment with a URL is PATCH-rewritten
# to `blocked-on: orchestrator`, while the body is also rewritten and the
# issue is labelled `needs-orchestrator`.
cat >"$scratch/list.json" <<'JSON'
[{"number":146,"title":"comment rewrite test","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-146.json" <<'JSON'
{"title":"comment rewrite test","body":"blocked-on: nish-decision\n","createdAt":"2026-08-25T06:00:00Z","comments":[{"body":"blocked-on: nish-decision\n","url":"https://github.com/Nishfleet/0509/issues/146#issuecomment-12345"}]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"
: >"$scratch/patches.log"

out=$("$bin" 2>"$scratch/err146-rewrite.txt")
grep -q 'requeued=0' <<<"$out" || fail "#146 comment rewrite must not requeue: $out"
grep -q 'count=1' <<<"$out" || fail "#146 stays in queue: $out"
grep -q 'add-label needs-orchestrator' "$scratch/edits.log" || fail "#146 missing label add: $(cat "$scratch/edits.log")"
grep -q 'blocked-on: orchestrator' "$scratch/edits.log" || fail "#146 body not rewritten: $(cat "$scratch/edits.log")"
grep -q 'repos/Nishfleet/0509/issues/comments/12345' "$scratch/patches.log" || fail "#146 comment not PATCHed: $(cat "$scratch/patches.log")"
grep -q 'blocked-on: orchestrator' "$scratch/patches.log" || fail "#146 comment body not rewritten: $(cat "$scratch/patches.log")"
grep -q 'remaining=orchestrator' "$scratch/comments.log" || fail "#146 sticky should name orchestrator: $(cat "$scratch/comments.log")"
[[ "$(jq -r '.rejected_nish_decisions' "$scratch/state.json")" == "2" ]] || fail "#146 state must record two rejected nish lines: $(cat "$scratch/state.json")"
ok "invalid nish in body + comment is rewritten, PATCHed, and labelled"

# Case 8: drill — close a fixture blocker, next pass flips the label
cat >"$scratch/list.json" <<'JSON'
[{"number":90,"title":"drill","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-90.json" <<'JSON'
{"title":"drill","body":"blocked-on: #10\n","createdAt":"2026-08-25T06:00:00Z","comments":[]}
JSON
echo '{"state":"open"}' >"$scratch/api/Nishfleet/0509/issues/10.json"
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err-drill-open.txt")
grep -q 'requeued=0' <<<"$out" || fail "drill open dep must stay blocked: $out"
[[ -s "$scratch/edits.log" ]] && fail "drill must not flip while open: $(cat "$scratch/edits.log")"

echo '{"state":"closed"}' >"$scratch/api/Nishfleet/0509/issues/10.json"
: >"$scratch/edits.log"
: >"$scratch/comments.log"
out=$("$bin" 2>"$scratch/err-drill-closed.txt")
grep -q 'requeued=1' <<<"$out" || fail "drill next pass must requeue: $out"
grep -q 'remove-label agent-blocked' "$scratch/edits.log" || fail "drill missing label remove: $(cat "$scratch/edits.log")"
grep -q 'add-label agent-ready' "$scratch/edits.log" || fail "drill missing label add: $(cat "$scratch/edits.log")"
ok "drill: close fixture blocker, next reconcile pass flips the label"

# Case 9: overlapping flock no-op
export BLOCKED_RECONCILE_LOCKDIR="$scratch/lock-overlap"
mkdir -p "$BLOCKED_RECONCILE_LOCKDIR"
exec 9>"$BLOCKED_RECONCILE_LOCKDIR/sweep.lock"
flock -n 9 || fail "could not hold overlap lock"
out=$("$bin" 2>"$scratch/err7.txt")
exec 9>&-
printf '%s\n' "$out" | grep -q 'no-op' || fail "overlap must print no-op, got: $out"
ok "overlapping sweep is a no-op"

# Case 10: contracts exist so the classifier keeps working
grep -q 'blocked-on:' "$repo_root/prompts/worker.md" || fail "worker.md must tell workers to write blocked-on: lines"
grep -q 'decision-resolved:' "$repo_root/prompts/worker.md" || fail "worker.md must tell answerers to write decision-resolved:"
grep -q '~~blocked-on:' "$repo_root/prompts/worker.md" || fail "worker.md must tell workers to strike through resolved blocked-on lines"
grep -q 'blocked-reconcile' "$repo_root/bin/fleet-heartbeat-tier1" || fail "tier1 must call blocked-reconcile"
ok "worker.md and heartbeat-tier1 carry the contract"
