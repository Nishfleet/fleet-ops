#!/usr/bin/env bash
# tests/packet-assembly-graphql-fallback.test.sh
#
# fleet-ops#5781: the blind-audit packet's OPEN_ISSUES_JSON /
# RECENT_MERGES_JSON went silently empty when the nishfleet-worker App
# installation's graphql bucket hit its hourly budget (`gh issue list` ->
# "GraphQL: API rate limit already exceeded for installation ID
# 156789042") while the human user's REST bucket still held ~4984.
#
# Proves packet_gh_read (lib/packet-assembly.sh):
#   1. retries the list via `gh api` REST with GH_TOKEN/GITHUB_TOKEN unset
#      (the user credential — sanctioned for organ reads, fleet-ops#3445 /
#      #5489 _gh_read precedent) when the installation call errors;
#   2. stamps which credential served each list + remaining quota into
#      $PACKET_GH_STAMP_FILE;
#   3. still fails soft (empty stdout, rc 1) when BOTH credentials fail;
#   4. packet_repo_reality emits non-empty lists + the provenance lines.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/packet-assembly.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "lib/packet-assembly.sh not found"

scratch="$(mktemp -d -t packet-gh-fallback.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT

gh_log="$scratch/gh-calls.log"
: >"$gh_log"

# Fake gh: `issue list`/`pr list` fail exactly like the exhausted App
# installation bucket; `api` serves REST fixtures + rate_limit. Every call
# logs its argv and whether GH_TOKEN was set, so the test can prove the
# fallback ran on the user credential.
mkdir -p "$scratch/fakebin"
cat >"$scratch/fakebin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf '%s|GH_TOKEN=%s\n' "$*" "${GH_TOKEN:+set}" >>"$GH_CALLS"
case "$1" in
  issue|pr)
    echo "GraphQL: API rate limit already exceeded for installation ID 156789042" >&2
    exit 1
    ;;
  api)
    path="${2:-}"
    case "$path" in
      rate_limit)
        printf '%s\n' '{"resources":{"core":{"remaining":4984},"graphql":{"remaining":0}}}'
        ;;
      */issues*)
        # REST /issues also returns PRs (pull_request marker) — the
        # caller's jq filter must drop them.
        printf '%s\n' '[{"number":5342,"title":"stale seat ledger","labels":[{"name":"agent-ready"}],"body":"b"},{"number":9999,"title":"a pull request row","pull_request":{"url":"x"}}]'
        ;;
      */pulls*)
        printf '%s\n' '[{"number":5800,"title":"older merge","merged_at":"2026-09-11T03:00:00Z"},{"number":5801,"title":"reap fix","merged_at":"2026-09-12T03:00:00Z"}]'
        ;;
      *) echo "unexpected gh api $*" >&2; exit 1 ;;
    esac
    exit 0
    ;;
  *) echo "unexpected gh $*" >&2; exit 1 ;;
esac
FAKE_GH
chmod +x "$scratch/fakebin/gh"

export GH_CALLS="$gh_log"
# The installation credential is present in env; the fallback must drop it.
export GH_TOKEN="fake-app-installation-token"
export GITHUB_TOKEN="fake-github-token"

run_helper() {  # <helper-args...> — sources the lib in a clean bash
    PACKET_GH="$scratch/fakebin/gh" \
    PACKET_GH_STAMP_FILE="${STAMP_FILE:-$scratch/stamps.txt}" \
    bash -c 'source "$1"; shift; packet_gh_read "$@"' _ "$lib" "$@"
}

: >"$scratch/stamps.txt"

# --- 1. open-issues fallback serves the list ---------------------------------
out=$(run_helper open-issues \
    "repos/Nishfleet/fleet-ops/issues?state=open&per_page=50" \
    '[.[] | select(.pull_request == null) | {number,title,labels:[.labels[]?.name],body}]' \
    -- issue list -R Nishfleet/fleet-ops --state open --json number,title,labels,body -L 50)

printf '%s' "$out" | grep -q '5342' \
    || fail "fallback list must carry issue 5342, got: $out"
printf '%s' "$out" | grep -q 'stale seat ledger' \
    || fail "fallback list must carry the issue title, got: $out"
printf '%s' "$out" | grep -q '9999' \
    && fail "REST /issues pull_request rows must be filtered out, got: $out" || true
ok "open-issues falls back to user REST and filters PR rows"

# --- 2. fallback ran WITHOUT the App token -----------------------------------
grep -q 'issue list.*|GH_TOKEN=set' "$gh_log" \
    || fail "primary call must run under the App credential: $(cat "$gh_log")"
grep -q 'api repos/Nishfleet/fleet-ops/issues?state=open.*|GH_TOKEN=$' "$gh_log" \
    || fail "fallback api call must run with GH_TOKEN unset (user credential): $(cat "$gh_log")"
ok "fallback call drops GH_TOKEN/GITHUB_TOKEN (user credential)"

# --- 3. stamp names the serving credential + quota ---------------------------
grep -q 'gh-credential open-issues: served-by=user-rest' "$scratch/stamps.txt" \
    || fail "stamp must name served-by=user-rest: $(cat "$scratch/stamps.txt")"
grep -q 'quota=core=4984' "$scratch/stamps.txt" \
    || fail "stamp must carry the serving credential's remaining quota: $(cat "$scratch/stamps.txt")"
ok "stamp carries served-by credential + remaining quota"

# --- 4. merged-PRs fallback (RECENT_MERGES_JSON) ------------------------------
out=$(run_helper recent-merges \
    "repos/Nishfleet/fleet-ops/pulls?state=closed&per_page=100" \
    '[.[] | select(.merged_at != null)] | sort_by(.merged_at) | reverse | .[0:20] | map({number,title,mergedAt:.merged_at})' \
    -- pr list -R Nishfleet/fleet-ops --state merged --json number,title,mergedAt -L 20)

printf '%s' "$out" | grep -q '5801' || fail "merged-prs fallback must carry PR 5801, got: $out"
printf '%s' "$out" | grep -q 'mergedAt' || fail "merged-prs fallback must reshape merged_at -> mergedAt, got: $out"
# Newest merge first after the sort.
first_num=$(printf '%s' "$out" | jq -r '.[0].number')
[[ "$first_num" == "5801" ]] || fail "merged-prs fallback must sort newest first, got: $out"
grep -q 'gh-credential recent-merges: served-by=user-rest' "$scratch/stamps.txt" \
    || fail "recent-merges stamp missing: $(cat "$scratch/stamps.txt")"
ok "recent-merges falls back, reshapes snake_case, sorts newest-first"

# --- 5. double failure stays soft ---------------------------------------------
mkdir -p "$scratch/fakebin-dead"
cat >"$scratch/fakebin-dead/gh" <<'FAKE_GH'
#!/usr/bin/env bash
case "$1" in
  issue|pr) echo "GraphQL: API rate limit already exceeded for installation ID 156789042" >&2; exit 1 ;;
  api)
    if [[ "${2:-}" == "rate_limit" ]]; then
      printf '%s\n' '{"resources":{"core":{"remaining":0},"graphql":{"remaining":0}}}'
      exit 0
    fi
    echo "HTTP 403: API rate limit already exceeded for user" >&2
    exit 1
    ;;
  *) exit 1 ;;
esac
FAKE_GH
chmod +x "$scratch/fakebin-dead/gh"
: >"$scratch/stamps-dead.txt"
set +e
out=$(PACKET_GH="$scratch/fakebin-dead/gh" \
    PACKET_GH_STAMP_FILE="$scratch/stamps-dead.txt" \
    bash -c 'source "$1"; shift; packet_gh_read "$@"' _ "$lib" open-issues \
        "repos/Nishfleet/fleet-ops/issues?state=open&per_page=50" \
        '[.[] | select(.pull_request == null) | {number,title}]' \
        -- issue list -R Nishfleet/fleet-ops --state open --json number,title -L 50)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "double failure must return 1, got rc=$rc out=$out"
[[ -z "$out" ]] || fail "double failure must print nothing (caller's || echo '[]' supplies it), got: $out"
grep -q 'served-by=unavailable' "$scratch/stamps-dead.txt" \
    || fail "double failure must stamp served-by=unavailable: $(cat "$scratch/stamps-dead.txt")"
ok "double failure prints nothing, rc=1, stamps served-by=unavailable"

# --- 6. packet_repo_reality integration ---------------------------------------
# Both list kinds dead on the App credential; the block must still carry the
# REST-served issues/merges and print the provenance lines into the packet.
out=$(PACKET_GH="$scratch/fakebin/gh" PACKET_GH_STAMP_FILE="" \
    bash -c 'source "$1"; packet_repo_reality 0509' _ "$lib" 2>/dev/null)
printf '%s' "$out" | grep -q '#5342: stale seat ledger' \
    || fail "packet_repo_reality Open issues must carry #5342 via fallback, got: $out"
printf '%s' "$out" | grep -q 'reap fix' \
    || fail "packet_repo_reality merged titles must carry 'reap fix' via fallback, got: $out"
printf '%s' "$out" | grep -q 'gh-credential open-issues: served-by=user-rest' \
    || fail "packet_repo_reality must stamp the serving credential, got: $out"
printf '%s' "$out" | grep -q 'gh-credential merged-prs: served-by=user-rest' \
    || fail "packet_repo_reality must stamp merged-prs credential, got: $out"
ok "packet_repo_reality serves non-empty lists via fallback + provenance lines"

echo "PASS: packet-assembly graphql fallback (fleet-ops#5781)"
