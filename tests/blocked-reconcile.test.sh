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

# fleet-ops#4260: a credential boundary is Nish-reserved (only he can mint an
# account token), so `blocked-on: nish-decision` with a credential reason must
# survive the reconcile instead of being rerouted to the orchestrator, which
# re-parks the issue as needs-orchestrator (FleetNeedsOrchestratorStale).
got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"blocked-on: nish-decision\nNish must mint the Cloudflare Analytics:Read credential.\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "nish-decision" ]] || fail "credential boundary is Nish-reserved: $got"
[[ "$(printf '%s' "$got" | jq -r '.rejected_count')" == "0" ]] || fail "credential nish-decision must not be rejected: $got"
ok "credential boundary stays a nish-decision"

# fleet-ops#4776: credentials (plural), secret, token, and account-login are
# Nish-reserved too. A blocked-on: nish-decision line with any of these
# reasons must survive the reconcile (not be rewritten to orchestrator),
# otherwise the issue bounces between needs-orchestrator and nish-decision
# every tick (FleetNeedsOrchestratorStale).
for reason in \
  "mint a Cloudflare Analytics:Read token needs Nish's login" \
  "rotate the deploy secret" \
  "Nish must mint the Cloudflare Analytics:Read credentials." \
  "blocked on account login — only Nish has the password"; do
  got=$(extract "$(jq -nc --arg r "$reason" '{repo:"Nishfleet/0509",number:50,title:"x",body:("blocked-on: nish-decision\n"+$r+"\n"),comments:[]}')")
  [[ "$(printf '%s' "$got" | jq -r '.kind')" == "nish-decision" ]] || fail "nish-reserved reason should stay nish-decision [$reason]: $got"
  [[ "$(printf '%s' "$got" | jq -r '.rejected_count')" == "0" ]] || fail "nish-reserved reason must not be rejected [$reason]: $got"
done
ok "credentials/secret/token/account-login reasons stay nish-decision (fleet-ops#4776)"

# An unrelated reason (no Nish-reserved keyword) is still rejected — existing
# behavior preserved (fleet-ops#4776 accept bullet 2).
got=$(extract '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"blocked-on: nish-decision\njust needs a code review and a docs pass\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.orchestrator')" == "true" ]] || fail "unrelated reason should set orchestrator flag: $got"
[[ "$(printf '%s' "$got" | jq -r '.rejected_count')" == "1" ]] || fail "unrelated reason must be rejected: $got"
ok "unrelated reason is still rejected (existing behavior preserved)"

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

# fleet-ops#4626: date-gate `re-open-<ISO>[-smoke]` is a first-class form, not
# a silent nish-decision. The live #4447 line is the fixture.
got=$(extract '{"repo":"Nishfleet/fleet-ops","number":4447,"title":"x","body":"blocked-on: re-open-2026-09-14T16:14Z-alibaba-smoke-ok\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "date-gate" ]] || fail "re-open date-gate kind: $got"
[[ "$(printf '%s' "$got" | jq -r '.nish')" == "false" ]] || fail "date-gate must not be nish-decision: $got"
[[ "$(printf '%s' "$got" | jq -r '.date_gates[0].at')" == "2026-09-14T16:14:00Z" ]] || fail "date-gate at: $got"
[[ "$(printf '%s' "$got" | jq -r '.date_gates[0].smoke')" == "alibaba-smoke-ok" ]] || fail "date-gate smoke: $got"
ok "blocked-on: re-open-<ISO>-<smoke> extracts as date-gate (fleet-ops#4626)"

got=$(extract '{"repo":"Nishfleet/fleet-ops","number":50,"title":"x","body":"blocked-on: re-open-2026-09-14T16:14:00Z\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "date-gate" ]] || fail "bare re-open kind: $got"
[[ "$(printf '%s' "$got" | jq -r '.date_gates[0].smoke')" == "" ]] || fail "bare re-open smoke must be empty: $got"
ok "blocked-on: re-open-<ISO> with no smoke extracts as date-gate"

# fleet-ops#4626: a blocked-on value that matches no known form is LOUD, not
# a silent nish-decision, so a prose gate can never park an issue quietly.
got=$(extract '{"repo":"Nishfleet/fleet-ops","number":50,"title":"x","body":"blocked-on: wait-for-the-moon\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "unknown-form" ]] || fail "unknown form kind: $got"
[[ "$(printf '%s' "$got" | jq -r '.nish')" == "false" ]] || fail "unknown form must not masquerade as nish-decision: $got"
[[ "$(printf '%s' "$got" | jq -r '.unknown_forms[0]')" == "wait-for-the-moon" ]] || fail "unknown form raw: $got"
ok "unknown blocked-on form extracts as unknown-form, not nish-decision"

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
        # fleet-ops#4260: the reconcile also lists the needs-orchestrator
        # label; serve that query from list-orch.json (default empty).
        if [[ "$*" == *needs-orchestrator* ]]; then
          if [[ -f "$FAKE_DIR/list-orch.json" ]]; then
            cat "$FAKE_DIR/list-orch.json"
          else
            echo '[]'
          fi
          exit 0
        fi
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
    rel="${rel%%\?*}"
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

# fleet-ops#4260: stub systemctl so the needs-orchestrator trigger can never
# start a real unit under test. is-active reports inactive so the start path
# is exercised; every call is logged to systemctl.log.
cat >"$scratch/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/systemctl.log"
if [[ "$*" == *is-active* ]]; then
  exit 1
fi
exit 0
FAKE
chmod +x "$scratch/bin/systemctl"

export FAKE_DIR="$scratch"
export PATH="$scratch/bin:$PATH"
# fleet-ops#5101: point GH at the stub so the bin's App-token mint guard
# ("${GH:-gh}" == "gh") skips the PATH prepend + live mint entirely — the
# suite stays hermetic and can never touch the real tracker.
export GH="$scratch/bin/gh"
export BLOCKED_RECONCILE_LOCKDIR="$scratch/lock"
export BLOCKED_RECONCILE_TRIAGE="$scratch/triage.md"
export BLOCKED_RECONCILE_STATE="$scratch/state.json"
# fleet-ops#4794: pin every absolute state path the reconciler can read into
# the scratch dir so a local run measures the fixture, never the host. The
# intake JSON is only consulted when BLOCKED_RECONCILE_REPOS is unset, but
# pinning it here keeps the suite hermetic even if that override is dropped.
export BLOCKED_RECONCILE_INTAKE_JSON="$scratch/intake.json"
export BLOCKED_RECONCILE_REPOS="Nishfleet/0509"
export BLOCKED_RECONCILE_NOW="2026-08-26T00:00:00Z"
export BLOCKED_RECONCILE_STICKY_SECS=0

# fleet-ops#4794: the live blocked queue must stay untouched by the suite. If
# BLOCKED_RECONCILE_STATE ever stops pointing at the scratch dir, the run
# reads (and writes) Nish's real queue and the assertions below go red.
LIVE_BLOCKED_QUEUE="/home/nish/.local/state/fleet-heartbeat/blocked-queue.json"
if [[ -f "$LIVE_BLOCKED_QUEUE" ]]; then
    live_queue_before="$(cat "$LIVE_BLOCKED_QUEUE")"
else
    live_queue_before=""
fi

# fleet-ops#3310/#3527: provide the seatlib data the infra auto-release path
# needs for a dry-run pick-seat. A real run uses the fleet's live state.
mkdir -p "$scratch/pi-packet/attempts" "$scratch/pi-packet/active-seats" "$scratch/pi-packet/ledger"
cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "devin":   { "models": [ { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 } ] },
    "opencode":{ "models": [ { "id": "nemotron-3-ultra-free", "cost": { "input": 0 }, "reasoning": false, "contextWindow": 100000 } ] }
  }
}
JSON
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "prepaid_providers_in_order": [],
  "senior_seats_in_order": [],
  "providers": {
    "devin":    { "cap": 4, "class": "prepaid-quota", "models": { "swe-1-7": 4 } },
    "opencode": { "cap": 3, "class": "free", "models": { "nemotron-3-ultra-free": 1 } }
  }
}
JSON
export PI_PACKET_STATE="$scratch/pi-packet"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
# fleet-ops#4395: isolate the seat-health ledger so the infra-block re-queue
# drill (Case 8a) is hermetic. seatlib reads LEDGER_DIR from
# PI_SEAT_HEALTH_LEDGER_DIR at source time; without this the drill reads the
# LIVE fleet ledger and the result depends on production seat state (e.g.
# opencode rate_limited in prod makes the test fail). An empty ledger dir
# makes every allowlisted seat fail-open as usable.
mkdir -p "$scratch/seat-ledger"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/seat-ledger"

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
# fleet-ops#4794: prove the run drained the FIXTURE queue, not the host queue.
# The scratch state.json must reflect the fixture (count=0 after the drain),
# and the live queue file must be byte-identical to how it was before the run.
[[ -f "$scratch/state.json" ]] || fail "fixture state.json not written: $(ls -la "$scratch")"
[[ "$(jq -r '.count' "$scratch/state.json")" == "0" ]] \
    || fail "fixture state must show the drained fixture, not the host queue: $(cat "$scratch/state.json")"
if [[ -f "$LIVE_BLOCKED_QUEUE" ]]; then
    live_queue_after="$(cat "$LIVE_BLOCKED_QUEUE")"
    [[ "$live_queue_after" == "$live_queue_before" ]] \
        || fail "live blocked queue was touched by the run: host queue must stay untouched"
else
    [[ ! -f "$LIVE_BLOCKED_QUEUE" ]] \
        || fail "live blocked queue appeared during the run"
fi
ok "closed issue dep requeues to agent-ready"
ok "run drained the fixture queue, not the host queue (fleet-ops#4794)"

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

# Case 4b: fleet-ops#5131 — an absorbed ticket parked by the spec-judge must
# never requeue when the absorbing issue closes. Live shape: 0509#2385 carries
# a worker's `blocked-on: Nishfleet/0509#2381` comment (the absorption is the
# reason), and the judge park adds a `blocked-on: orchestrator` line. That line
# forces all_cleared=0 on every pass, so the resolved ref cannot flip the label
# back to agent-ready (the fleet-ops#1083 requeue class).
cat >"$scratch/list.json" <<'JSON'
[{"number":2385,"title":"reccos: delete the two sneaker-resale canary tests","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"},{"name":"needs-orchestrator"}]}]
JSON
cat >"$scratch/view-2385.json" <<'JSON'
{"title":"reccos: delete the two sneaker-resale canary tests","body":"files: tests/a.test.ts","createdAt":"2026-08-25T06:00:00Z","comments":[{"body":"blocked: absorbed by Nishfleet/0509#2381 (binding judge edit: Absorbs #2385).\n\nblocked-on: Nishfleet/0509#2381"},{"body":"spec-judge: absorbed by #2381 - the binding judge edit on #2381 declares this ticket subsumed.\n\nblocked-on: orchestrator"}]}
JSON
echo '{"state":"closed"}' >"$scratch/api/Nishfleet/0509/issues/2381.json"
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err4b.txt")
grep -q 'requeued=0' <<<"$out" || fail "absorbed park must not requeue when the absorbing issue closes: $out"
[[ -s "$scratch/edits.log" ]] && fail "absorbed park must not flip labels back: $(cat "$scratch/edits.log")"
grep -q 'kind=orchestrator' "$scratch/comments.log" || fail "absorbed park should publish kind=orchestrator: $(cat "$scratch/comments.log")"
ok "fleet-ops#5131: absorbed park stays parked when the absorbing issue closes (ref resolved, label untouched)"

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

# Case 8a: aged blocked-on: infra re-queues when a healthy capable seat exists
# (fleet-ops#3310/#3527). The blocked-on: infra comment is 3h old; a healthy
# opencode free seat is available, so the issue is re-queued and the WORK cap
# + systemic markers are reset.
cat >"$scratch/list.json" <<'JSON'
[{"number":99,"title":"infra block test","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-99.json" <<'JSON'
{"title":"infra block test","body":"some work\n\nblocked-on: infra\n","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}],"comments":[{"body":"fleet-ops#3310: ...\n\nblocked-on: infra\n","createdAt":"2026-08-25T21:00:00Z"}]}
JSON
printf '1' >"$PI_PACKET_STATE/attempts/pi-issue-0509-99.reclaim-count"
printf '1' >"$PI_PACKET_STATE/attempts/pi-issue-0509-99.systemic"
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err-infra.txt")
grep -q 'requeued=1' <<<"$out" || fail "aged infra block must requeue: $out"
grep -q 'remove-label agent-blocked' "$scratch/edits.log" || fail "infra requeue missing label remove: $(cat "$scratch/edits.log")"
grep -q 'add-label agent-ready' "$scratch/edits.log" || fail "infra requeue missing label add: $(cat "$scratch/edits.log")"
grep -q 'blocked-reconcile: infra-block released' "$scratch/comments.log" || fail "infra release marker missing: $(cat "$scratch/comments.log")"
[[ ! -f "$PI_PACKET_STATE/attempts/pi-issue-0509-99.reclaim-count" ]] || fail "reclaim-count must be reset"
[[ ! -f "$PI_PACKET_STATE/attempts/pi-issue-0509-99.systemic" ]] || fail "systemic marker must be reset"
ok "aged blocked-on: infra re-queues when a healthy capable seat exists"

# Case 8b: young blocked-on: infra stays blocked
# The infra marker is only 1.5h old, so it is too young to release.
cat >"$scratch/view-99.json" <<'JSON'
{"title":"infra block test","body":"some work\n\nblocked-on: infra\n","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}],"comments":[{"body":"fleet-ops#3310: ...\n\nblocked-on: infra\n","createdAt":"2026-08-25T22:30:00Z"}]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err-infra-young.txt")
grep -q 'requeued=0' <<<"$out" || fail "young infra block must not requeue: $out"
grep -q 'remaining=infra (too young' "$scratch/comments.log" || fail "young infra missing too-young sticky: $(cat "$scratch/comments.log")"
ok "young blocked-on: infra stays blocked"

# Case 8c: second infra-block release inside 24h escalates to senior-review
# A previous release comment is in the history, so a second aged infra block
# posts blocked-on: senior-review instead of re-queuing.
cat >"$scratch/view-99.json" <<'JSON'
{"title":"infra block test","body":"some work\n\nblocked-on: infra\n","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}],"comments":[{"body":"blocked-reconcile: infra-block released at 2026-08-25T20:00:00Z\n","createdAt":"2026-08-25T20:00:00Z"},{"body":"fleet-ops#3310: ...\n\nblocked-on: infra\n","createdAt":"2026-08-25T21:00:00Z"}]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err-infra-escalate.txt")
grep -q 'requeued=0' <<<"$out" || fail "second infra release must not requeue: $out"
grep -q 'blocked-on: senior-review' "$scratch/comments.log" || fail "second infra release must escalate: $(cat "$scratch/comments.log")"
grep -q 'kind=senior-review' "$scratch/comments.log" || fail "escalation sticky must be senior-review: $(cat "$scratch/comments.log")"
ok "second infra-block release within 24h escalates to senior-review"

# Case 8d: blocked-on: senior-review stays blocked
# After escalation, the issue is pinned at senior-review and does not auto-release.
cat >"$scratch/list.json" <<'JSON'
[{"number":98,"title":"senior review test","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-98.json" <<'JSON'
{"title":"senior review test","body":"blocked-on: senior-review\n","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}],"comments":[{"body":"escalated.\n\nblocked-on: senior-review\n","createdAt":"2026-08-25T21:00:00Z"}]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err-senior.txt")
grep -q 'requeued=0' <<<"$out" || fail "senior-review must not requeue: $out"
grep -q 'count=1' <<<"$out" || fail "senior-review must stay in queue: $out"
grep -q 'remaining=senior-review' "$scratch/comments.log" || fail "senior-review sticky missing: $(cat "$scratch/comments.log")"
ok "blocked-on: senior-review stays blocked"

# Case 8e: fleet-ops#4260 — a blocked-on: orchestrator item publishes
# kind=orchestrator in the snapshot (it must not masquerade as nish-decision).
cat >"$scratch/list.json" <<'JSON'
[{"number":97,"title":"orch kind test","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-97.json" <<'JSON'
{"title":"orch kind test","body":"blocked-on: orchestrator\n","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}],"comments":[]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"
: >"$scratch/systemctl.log"

out=$("$bin" 2>"$scratch/err-orch-kind.txt")
grep -q 'count=1' <<<"$out" || fail "orchestrator item stays in queue: $out"
[[ "$(jq -r '.items[0].kind' "$scratch/state.json")" == "orchestrator" ]] \
    || fail "orchestrator item must publish kind=orchestrator: $(cat "$scratch/state.json")"
grep -q 'kind=orchestrator' "$scratch/comments.log" \
    || fail "sticky must name kind=orchestrator: $(cat "$scratch/comments.log")"
# Belt path (fleet-ops#4260): an aged kind=orchestrator item triggers the
# decision sweep even with an empty needs-orchestrator label list — the
# trigger rides the blocked queue itself, not only the label.
grep -q 'start agent-cron-orchestrator-decision-sweep.service' "$scratch/systemctl.log" \
    || fail "aged orchestrator-blocked item must trigger the sweep: $(cat "$scratch/systemctl.log")"
ok "blocked-on: orchestrator publishes kind=orchestrator in the snapshot"

# Case 11: fleet-ops#4260 — an aged needs-orchestrator issue triggers the
# orchestrator decision sweep (stock systemctl start, stubbed here).
cat >"$scratch/list.json" <<'JSON'
[]
JSON
cat >"$scratch/list-orch.json" <<'JSON'
[{"number":200,"createdAt":"2026-08-25T22:00:00Z","labels":[{"name":"needs-orchestrator"}]}]
JSON
: >"$scratch/systemctl.log"

out=$("$bin" 2>"$scratch/err-orch.txt")
grep -q 'needs_orchestrator=1' <<<"$out" || fail "needs-orchestrator count missing: $out"
grep -q 'start agent-cron-orchestrator-decision-sweep.service' "$scratch/systemctl.log" \
    || fail "aged needs-orchestrator must start the decision sweep: $(cat "$scratch/systemctl.log")"
[[ "$(jq -r '.needs_orchestrator.count' "$scratch/state.json")" == "1" ]] \
    || fail "snapshot needs_orchestrator.count: $(cat "$scratch/state.json")"
[[ "$(jq -r '.needs_orchestrator.p50_age_s' "$scratch/state.json")" == "7200" ]] \
    || fail "snapshot needs_orchestrator.p50_age_s: $(cat "$scratch/state.json")"
ok "aged needs-orchestrator item starts the orchestrator decision sweep"

# Case 11b: a young needs-orchestrator item does NOT trigger the sweep.
cat >"$scratch/list-orch.json" <<'JSON'
[{"number":201,"createdAt":"2026-08-25T23:30:00Z","labels":[{"name":"needs-orchestrator"}]}]
JSON
: >"$scratch/systemctl.log"

out=$("$bin" 2>"$scratch/err-orch-young.txt")
grep -q 'needs_orchestrator=1' <<<"$out" || fail "young item still counted: $out"
if grep -q 'start ' "$scratch/systemctl.log"; then
    fail "young needs-orchestrator must not start the sweep: $(cat "$scratch/systemctl.log")"
fi
ok "young needs-orchestrator item is counted but does not trigger the sweep"

# Case 11c: an agent-in-progress needs-orchestrator item is skipped (a live
# worker owns it — it is not parked).
cat >"$scratch/list-orch.json" <<'JSON'
[{"number":202,"createdAt":"2026-08-25T10:00:00Z","labels":[{"name":"needs-orchestrator"},{"name":"agent-in-progress"}]}]
JSON
: >"$scratch/systemctl.log"

out=$("$bin" 2>"$scratch/err-orch-inprog.txt")
grep -q 'needs_orchestrator=0' <<<"$out" || fail "in-progress item must not count: $out"
[[ ! -s "$scratch/systemctl.log" ]] || fail "in-progress item must not trigger: $(cat "$scratch/systemctl.log")"
ok "agent-in-progress needs-orchestrator item is skipped"

# Case 11d: the p50 is time IN the needs-orchestrator class, not issue age.
# A ticket created three weeks ago but parked 5 minutes ago is a fresh ask,
# not a stalled drain: it must not trip FleetNeedsOrchestratorStale — and it
# must not be a false-clear either (the age still reports the 5 minutes).
mkdir -p "$scratch/api/Nishfleet/0509/issues/203"
cat >"$scratch/api/Nishfleet/0509/issues/203/timeline.json" <<'JSON'
[{"event":"labeled","label":{"name":"agent-ready"},"created_at":"2026-08-01T00:00:00Z"},
 {"event":"unlabeled","label":{"name":"agent-ready"},"created_at":"2026-08-25T23:50:00Z"},
 {"event":"labeled","label":{"name":"needs-orchestrator"},"created_at":"2026-08-25T23:55:00Z"}]
JSON
cat >"$scratch/list-orch.json" <<'JSON'
[{"number":203,"createdAt":"2026-08-01T00:00:00Z","labels":[{"name":"needs-orchestrator"}]}]
JSON
: >"$scratch/systemctl.log"

out=$("$bin" 2>"$scratch/err-orch-old-parks-new.txt")
grep -q 'needs_orchestrator=1' <<<"$out" || fail "old-but-newly-parked item must count: $out"
[[ "$(jq -r '.needs_orchestrator.p50_age_s' "$scratch/state.json")" == "300" ]] \
    || fail "p50 must be time in class (300s), not issue age: $(cat "$scratch/state.json")"
if grep -q 'start ' "$scratch/systemctl.log"; then
    fail "a ticket parked 5 minutes ago must not start the sweep: $(cat "$scratch/systemctl.log")"
fi
ok "needs-orchestrator age is time in the class, not issue age"

# Case 11e: the same ticket, parked for over 2h, still trips the detector.
cat >"$scratch/api/Nishfleet/0509/issues/203/timeline.json" <<'JSON'
[{"event":"labeled","label":{"name":"needs-orchestrator"},"created_at":"2026-08-25T21:00:00Z"}]
JSON
: >"$scratch/systemctl.log"

out=$("$bin" 2>"$scratch/err-orch-genuine.txt")
[[ "$(jq -r '.needs_orchestrator.p50_age_s' "$scratch/state.json")" == "10800" ]] \
    || fail "a 3h-parked item must still report 3h: $(cat "$scratch/state.json")"
grep -q 'start agent-cron-orchestrator-decision-sweep.service' "$scratch/systemctl.log" \
    || fail "a 3h-parked item must start the sweep: $(cat "$scratch/systemctl.log")"
ok "a genuinely parked needs-orchestrator item still starts the decision sweep"

rm -f "$scratch/list-orch.json"
rm -rf "$scratch/api/Nishfleet/0509/issues/203"

# fleet-ops#4626 Case 12a: past date-gate + stub smoke rc=0 -> requeue (label flip).
# NOW is 2026-08-26 (already past 2026-08-25T00:00:00Z). Smoke is a stub that
# returns 0 so the named check does not hit a live provider.
mkdir -p "$scratch/smoke"
cat >"$scratch/smoke/alibaba-smoke-ok" <<'SMOKE'
#!/usr/bin/env bash
exit 0
SMOKE
chmod +x "$scratch/smoke/alibaba-smoke-ok"
export BLOCKED_RECONCILE_SMOKE_DIR="$scratch/smoke"
cat >"$scratch/list.json" <<'JSON'
[{"number":4447,"title":"date gate past","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-4447.json" <<'JSON'
{"title":"date gate past","body":"blocked-on: re-open-2026-08-25T00:00:00Z-alibaba-smoke-ok\n","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}],"comments":[]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err-date-past.txt")
grep -q 'requeued=1' <<<"$out" || fail "past date-gate + smoke 0 must requeue: $out err=$(cat "$scratch/err-date-past.txt")"
grep -q 'remove-label agent-blocked' "$scratch/edits.log" || fail "past date-gate must drop agent-blocked: $(cat "$scratch/edits.log")"
grep -q 'add-label agent-ready' "$scratch/edits.log" || fail "past date-gate must add agent-ready: $(cat "$scratch/edits.log")"
grep -qE 'date-gate|re-open' "$scratch/comments.log" "$scratch/err-date-past.txt" || fail "past date-gate must name the form: comments=$(cat "$scratch/comments.log") err=$(cat "$scratch/err-date-past.txt")"
ok "past date-gate + stub smoke 0 flips agent-blocked -> agent-ready"

# fleet-ops#4626 Case 12b: future date-gate stays blocked, labels untouched.
cat >"$scratch/list.json" <<'JSON'
[{"number":4448,"title":"date gate future","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-4448.json" <<'JSON'
{"title":"date gate future","body":"blocked-on: re-open-2026-09-14T16:14Z-alibaba-smoke-ok\n","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}],"comments":[]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err-date-future.txt")
grep -q 'requeued=0' <<<"$out" || fail "future date-gate must not requeue: $out"
[[ -s "$scratch/edits.log" ]] && fail "future date-gate must not flip labels: $(cat "$scratch/edits.log")"
grep -qE 'date-gate|re-open' "$scratch/err-date-future.txt" "$scratch/comments.log" || fail "future date-gate must stay loud as date-gate: err=$(cat "$scratch/err-date-future.txt") comments=$(cat "$scratch/comments.log")"
ok "future date-gate stays blocked and is not flipped"

# fleet-ops#4626 Case 12c: unknown form is LOUD (stderr + sticky), never silent.
cat >"$scratch/list.json" <<'JSON'
[{"number":4449,"title":"unknown form","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-4449.json" <<'JSON'
{"title":"unknown form","body":"blocked-on: wait-for-the-moon\n","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}],"comments":[]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err-unknown.txt")
grep -q 'requeued=0' <<<"$out" || fail "unknown form must not requeue: $out"
[[ -s "$scratch/edits.log" ]] && fail "unknown form must not flip labels: $(cat "$scratch/edits.log")"
grep -qE 'unknown-form|unknown form|LOUD' "$scratch/err-unknown.txt" || fail "unknown form must be LOUD on stderr: $(cat "$scratch/err-unknown.txt")"
grep -q 'wait-for-the-moon' "$scratch/err-unknown.txt" "$scratch/comments.log" || fail "unknown form must name the raw value: err=$(cat "$scratch/err-unknown.txt") comments=$(cat "$scratch/comments.log")"
ok "unknown blocked-on form is LOUD and stays blocked"

# fleet-ops#4626 Case 12d: past date-gate + smoke fail re-parks at usable_at.
cat >"$scratch/smoke/alibaba-smoke-ok" <<'SMOKE'
#!/usr/bin/env bash
# Simulate a walled seat: print usable_at so the reconciler can re-park.
echo 'usable_at=2026-09-15T03:51:36Z'
exit 1
SMOKE
chmod +x "$scratch/smoke/alibaba-smoke-ok"
cat >"$scratch/list.json" <<'JSON'
[{"number":4450,"title":"date gate smoke fail","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}]}]
JSON
cat >"$scratch/view-4450.json" <<'JSON'
{"title":"date gate smoke fail","body":"blocked-on: re-open-2026-08-25T00:00:00Z-alibaba-smoke-ok\n","createdAt":"2026-08-25T06:00:00Z","labels":[{"name":"agent-blocked"}],"comments":[]}
JSON
: >"$scratch/edits.log"
: >"$scratch/comments.log"

out=$("$bin" 2>"$scratch/err-smoke-fail.txt")
grep -q 'requeued=0' <<<"$out" || fail "failed smoke must not requeue: $out err=$(cat "$scratch/err-smoke-fail.txt")"
[[ -s "$scratch/edits.log" ]] && fail "failed smoke must not flip labels: $(cat "$scratch/edits.log")"
grep -q 're-open-2026-09-15T03:51:36Z-alibaba-smoke-ok' "$scratch/comments.log" \
    || fail "failed smoke must re-park at usable_at: $(cat "$scratch/comments.log")"
ok "failed smoke re-parks with blocked-on: re-open-<usable_at>-<smoke>"

unset BLOCKED_RECONCILE_SMOKE_DIR

# --- fleet-ops#5870: attest blockers are orchestrator-attest, never nish ---
# Replay of the three live instances (0509#3068, 0509#3144, fleet-ops#5760):
# each parked as kind=nish-decision at 07:45-07:57Z on 2026-09-12; all three
# must classify as orchestrator-attest, zero as nish-decision.
epy() { printf '%s' "$1" | "$bin" --extract; }
out1=$(epy '{"repo":"Nishfleet/0509","number":3068,"title":"delete uptime-health.yml","body":"blocked-on: nish-decision\nDeleting the workflow needs a gate-integrity-attest from a repository admin; workers may not self-attest.\n","comments":[]}')
[[ "$(printf '%s' "$out1" | jq -r '.kind')" == "orchestrator-attest" ]] || fail "#3068 replay must be orchestrator-attest: $out1"
out2=$(epy '{"repo":"Nishfleet/0509","number":3144,"title":"ads-prog-seo prose","body":"needs an admin gate-integrity-attest on the PR; I cannot post it\n","comments":[]}')
[[ "$(printf '%s' "$out2" | jq -r '.kind')" == "orchestrator-attest" ]] || fail "#3144 replay must be orchestrator-attest: $out2"
out3=$(epy '{"repo":"Nishfleet/fleet-ops","number":5760,"title":"x","body":"blocked-on: nish-decision\nverifier-attest requires an admin identity; waiting.\n","comments":[]}')
[[ "$(printf '%s' "$out3" | jq -r '.kind')" == "orchestrator-attest" ]] || fail "#5760 replay must be orchestrator-attest: $out3"
ok "three #5870 replay instances classify orchestrator-attest, zero nish-decision"

# The pin: a blocker body containing gate-integrity-attest NEVER yields
# kind=nish-decision, even when the wording trips the Nish-reserved vocabulary.
got=$(epy '{"repo":"Nishfleet/0509","number":50,"title":"x","body":"blocked-on: nish-decision\nLikely needs a gate-integrity-attest from an admin (an authority reserved to staff).\n","comments":[]}')
[[ "$(printf '%s' "$got" | jq -r '.kind')" != "nish-decision" ]] || fail "gate-integrity-attest blocker must never be nish-decision: $got"
[[ "$(printf '%s' "$got" | jq -r '.kind')" == "orchestrator-attest" ]] || fail "attest pin kind: $got"
ok "a blocker body containing gate-integrity-attest never yields kind=nish-decision"

# Clean up the helper so later cases do not see it.
unset -f epy

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
help_out=$("$bin" --help 2>&1) || fail "--help must exit 0"
grep -q 're-open-' <<<"$help_out" || fail "--help must document re-open-<ISO> date-gates: $help_out"
grep -q 'unknown-form' <<<"$help_out" || fail "--help must document unknown-form: $help_out"
ok "worker.md and heartbeat-tier1 carry the contract"
ok "--help documents re-open-<ISO> date-gates and unknown-form (fleet-ops#4626)"
