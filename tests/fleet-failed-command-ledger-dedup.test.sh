#!/usr/bin/env bash
# tests/fleet-failed-command-ledger-dedup.test.sh
#
# fleet-ops#1071: the open-list dedup relies on `gh issue list` returning
# the just-filed issue. When gh fails (no auth, 5xx, network blip, stale
# token), open_json becomes [] and the dedup falls through — every tick
# files a duplicate. Live #1071: 5-7 duplicates per slug across
# consecutive ticks on 2026-08-27T05:10-05:14Z.
#
# The fix is a per-tick local dedup ledger at
# $FLEET_FAILED_COMMAND_LEDGER (default /var/tmp/fleet-failed-command-flagged.filed).
# The ledger is consulted as a last-resort dedup, after the open-list and
# closed-search dedups have run, so healthy gh is unaffected and a single
# gh outage cannot fan out 5-7 duplicates. The ledger is pruned when the
# slug stops being a finding (so a future re-encounter of the same
# session can re-file).
#
# This test simulates the gh-broken case: every `gh` call returns [] /
# no JSON, like a 401 or 5xx. The detector must still dedup a slug
# across consecutive ticks via the ledger.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-failed-command-flagged"
lib="$repo_root/lib/failed-command-flagged.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t failed-command-ledger.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

sessions="$scratch/sessions/ws"
mkdir -p "$sessions"

# Mock gh: every list call returns [] (no JSON for `open` or
# `closed --search`). Simulates gh returning 401 / 5xx / network blip —
# exactly the failure mode the live #1071 cluster came from. issue
# create still works (so the bin can file when it gets past the dedups),
# so the test can also assert "no duplicate was created on tick 2".
cat >"$scratch/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
case "$cmd" in
  issue)
    sub="$1"; shift
    case "$sub" in
      create)
        title=""; body=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --title) title="$2"; shift 2 ;;
            --body) body="$2"; shift 2 ;;
            --repo|-R) shift 2 ;;
            *) shift ;;
          esac
        done
        store="${GH_MOCK_STORE:-}"
        if [ -n "$store" ]; then
          n=$(find "$store" -maxdepth 1 -name 'issue-*.body' 2>/dev/null | wc -l)
          f="$store/issue-$((n+1)).body"
          printf '%s\n' "$title" > "$f"
          printf '%s\n' "$body" >> "$f"
        fi
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
      list)
        # Always return [] — gh is "broken" (401 / 5xx / network blip).
        printf '[]\n'
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/gh"

write_session() {
  local name="$1"
  local jsonl="$2"
  printf '%s\n' "$jsonl" >"$sessions/$name.jsonl"
  touch -d "2026-08-27T00:00:00Z" "$sessions/$name.jsonl"
}

run_bin() {
  local file_issues="${1:-0}"
  set +e
  FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
  FLEET_FAILED_COMMAND_LIB="$lib" \
  FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
  FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
  FLEET_FAILED_COMMAND_NOW="2026-08-27T00:10:00Z" \
  FLEET_FAILED_COMMAND_FILE_ISSUES="$file_issues" \
  FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
  FLEET_FAILED_COMMAND_LEDGER="$scratch/ledger.filed" \
  GH="$scratch/gh" \
  GH_MOCK_STORE="$scratch/gh-issues" \
  FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
    "$bin" >/dev/null 2>"$scratch/err.log"
  local rc=$?
  set -e
  echo "$rc"
}

gh_store="$scratch/gh-issues"
mkdir -p "$gh_store"

# --- 1. gh broken: tick 1 files, tick 2 dedupes via ledger -----------------
# The mock gh returns [] for every list call. Without the ledger, tick 2
# would file a duplicate. With the ledger, tick 2 dedupes.
slug="2026-08-26t05-10-00-000z-01a03e61-gh-broken-ledger-dedup-shape"
write_session "$slug" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'

# Tick 1: file
rc=$(run_bin 1)
[[ "$rc" == "1" ]] || fail "tick 1 should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FILED" "$scratch/err.log" || fail "tick 1 must file: $(cat "$scratch/err.log")"
issue_count=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$issue_count" == "1" ]] || fail "tick 1 must file exactly one issue (got $issue_count)"
[[ -f "$scratch/ledger.filed" ]] || fail "tick 1 must create the ledger"
grep -qxF "$slug" "$scratch/ledger.filed" || fail "tick 1 must record the slug on the ledger"
ok "live #1071: gh-broken tick 1 files and records on ledger"

# Tick 2: gh still broken; must dedup via ledger, NOT file a duplicate
rc=$(run_bin 1)
[[ "$rc" == "1" ]] || fail "tick 2 should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "deduped via ledger" "$scratch/err.log" \
  || fail "tick 2 must dedup via ledger: $(cat "$scratch/err.log")"
issue_count=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$issue_count" == "1" ]] || fail "tick 2 must not file a duplicate (got $issue_count)"
ok "live #1071: gh-broken tick 2 dedupes via ledger (no duplicate filed)"

# Tick 3-7: the 5-7 duplicates cluster from the live scenario
for i in 3 4 5 6 7; do
  rc=$(run_bin 1)
  [[ "$rc" == "1" ]] || fail "tick $i should exit 1 (got $rc)"
  grep -q "deduped via ledger" "$scratch/err.log" \
    || fail "tick $i must dedup via ledger: $(cat "$scratch/err.log")"
done
issue_count=$(find "$gh_store" -maxdepth 1 -name 'issue-*.body' | wc -l)
[[ "$issue_count" == "1" ]] || fail "after 7 ticks, must still have only one issue (got $issue_count)"
ok "live #1071: 5-7 consecutive ticks under gh outage yield exactly one filed issue"

# --- 2. ledger prune: a fresh tick without the session prunes the ledger --
# Remove the session file (or let the window age it out). The slug is
# no longer a finding AND not in grace, so the ledger should drop it.
rm -f "$sessions/${slug}.jsonl"

# Same NOW so the window still covers the file. Use a fresh NOW outside
# the 24h window so the session ages out and the slug is no longer a
# finding.
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-29T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
FLEET_FAILED_COMMAND_LEDGER="$scratch/ledger.filed" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-prune.log"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "aged-out tick should exit 0 (got $rc) $(cat "$scratch/err-prune.log")"
grep -q "pruned $slug" "$scratch/err-prune.log" \
  || fail "aged-out tick must prune $slug: $(cat "$scratch/err-prune.log")"
[[ ! -s "$scratch/ledger.filed" ]] || fail "aged-out tick must empty the ledger ($(cat "$scratch/ledger.filed"))"
ok "live #1071: ledger prunes slugs that are no longer a finding (no blocking re-filings)"

# --- 3. fresh tick after prune: a re-encounter of the same slug can file --
# The session file is back. The ledger is empty. The detector files a
# new issue, treating it as a new finding (which it is — the prior
# issue was already on observe-to-close track, not on a re-file track).
write_session "$slug" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'
touch -d "2026-08-29T00:00:00Z" "$sessions/${slug}.jsonl"

# A second re-encounter: a new slug, fresh sessions directory, fresh
# ledger. The detector must file a new issue (no false-positive ledger
# hit because the prior one was pruned).
slug_two="2026-08-29t00-00-00-000z-post-prune-reencounter"
write_session "$slug_two" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad2","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad2","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'

rc=$(run_bin 1)
[[ "$rc" == "1" ]] || fail "post-prune tick should exit 1 (got $rc) $(cat "$scratch/err.log")"
grep -q "FILED" "$scratch/err.log" || fail "post-prune tick must file: $(cat "$scratch/err.log")"
grep -qxF "$slug_two" "$scratch/ledger.filed" \
  || fail "post-prune tick must record $slug_two on the ledger"
ok "live #1071: a real new finding is filed even after a prior slug was pruned"

# --- 4. env var override: FLEET_FAILED_COMMAND_LEDGER redirects the file --
# The bin must honor FLEET_FAILED_COMMAND_LEDGER so tests and operators
# can point the ledger at a private location (e.g. tmpfs, a per-seat
# directory) without touching the bin. We assert the default ledger at
# /var/tmp is NOT touched when an override is set.
custom="$scratch/custom-ledger.filed"
rm -f "$custom"
default_ledger="/var/tmp/fleet-failed-command-flagged.filed"
# Snapshot the default ledger size before the override run.
default_before=0
[[ -f "$default_ledger" ]] && default_before=$(wc -c <"$default_ledger")
# Use a fresh session so the detector has a real finding to file.
# Clear the prior findings from steps 1-3 so the detector files exactly
# one new issue for the env-override shape.
rm -f "$sessions"/*.jsonl
slug_env="2026-08-29t01-00-00-000z-env-override-shape"
write_session "$slug_env" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_env","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_env","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'
# Re-touch the session so the 24h window at NOW=2026-08-29T01:10:00Z
# includes it (write_session's default touch is 2026-08-27T00:00:00Z).
touch -d "2026-08-29T01:00:00Z" "$sessions/${slug_env}.jsonl"
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-29T01:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
FLEET_FAILED_COMMAND_LEDGER="$custom" \
GH="$scratch/gh" \
GH_MOCK_STORE="$gh_store" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-custom.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "custom-ledger tick should exit 1 (got $rc) $(cat "$scratch/err-custom.log")"
[[ -f "$custom" ]] || fail "custom-ledger path must be created"
grep -qxF "$slug_env" "$custom" \
  || fail "custom-ledger must record the slug $(cat "$custom")"
# The default /var/tmp/ ledger must not gain a new entry for $slug_env.
# (It may have older entries from prior failed runs; the assertion is
# that $slug_env is NOT in it.)
if [[ -f "$default_ledger" ]] && grep -qxF "$slug_env" "$default_ledger"; then
  fail "default ledger must not record $slug_env when env override is set"
fi
ok "FLEET_FAILED_COMMAND_LEDGER env override: detector honors the custom path"

# --- 5. ledger survives an open-list / closed-list mismatch ----------------
# A healthy gh tick that finds the issue already open must dedup via
# the open list (not the ledger), so the ledger stays a fallback. This
# is the cross-check: when the open list works, the ledger is invisible.
gh_store2="$scratch/gh-issues2"
mkdir -p "$gh_store2"
# Mock gh that returns the just-filed issue on --state open.
cat >"$scratch/gh-healthy" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
store="${GH_MOCK_STORE:?}"
cmd="$1"; shift
case "$cmd" in
  issue)
    sub="$1"; shift
    case "$sub" in
      list)
        state_filter="open"
        while [ "$#" -gt 0 ]; do
          case "$1" in --state) state_filter="$2"; shift 2 ;; --limit|--json|--repo|-R) shift 2 ;; *) shift ;; esac
        done
        printf '[\n'
        first=1
        for f in "$store"/issue-*.body; do
          [ -f "$f" ] || continue
          num=$(basename "$f" .body)
          num=${num#issue-}
          is_closed=""
          [ -f "$store/issue-${num}.closed" ] && is_closed="1"
          if [ "$state_filter" = "open" ] && [ -n "$is_closed" ]; then continue; fi
          body=$(tail -n +2 "$f")
          if [ "$first" = 1 ]; then first=0; else printf ',\n'; fi
          printf '{"number":%s,"state":"OPEN","title":"","body":%s,"comments":[]}' \
            "$num" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$body")"
        done
        printf '\n]\n'
        ;;
      comment)
        : # observe-to-close may try to comment, but we only need list to work
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999#issuecomment-1"
        ;;
      create)
        : # not used in this test
        echo "https://github.com/Nishfleet/fleet-ops/issues/9999"
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$scratch/gh-healthy"

slug3="2026-08-29t00-00-00-000z-healthy-gh-ledger-invisible"
# Pre-populate an open issue for the slug (as if a prior healthy tick
# had filed it).
printf '%s\n' "fix(failed-command): $slug3" >"$gh_store2/issue-42.body"
printf '\nThe session-close lint found a swallowed failure.\n\nsignal: failed-command-flagged/%s\n' "$slug3" >>"$gh_store2/issue-42.body"

write_session "$slug3" '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_bad3","name":"bash","arguments":{"command":"false"}}]}}
{"type":"message","message":{"role":"toolResult","toolCallId":"call_bad3","toolName":"bash","isError":true,"content":[{"type":"text","text":"\n\nCommand exited with code 1"}]}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Moving on."}]}}'
# write_session's default touch is 2026-08-27T00:00:00Z. Re-touch so the
# 24h window at NOW=2026-08-29T00:10:00Z includes it.
touch -d "2026-08-29T00:00:00Z" "$sessions/${slug3}.jsonl"

# Run with the healthy gh, ledger pre-seeded with the slug. The
# detector must dedup via the open list, NOT touch the ledger
# (because the open-list path returns before the ledger check).
echo "$slug3" >"$scratch/ledger-healthy.filed"
set +e
FLEET_FAILED_COMMAND_SESSIONS="$scratch/sessions" \
FLEET_FAILED_COMMAND_LIB="$lib" \
FLEET_FAILED_COMMAND_WINDOW_HOURS="24" \
FLEET_FAILED_COMMAND_GRACE_MINUTES="0" \
FLEET_FAILED_COMMAND_NOW="2026-08-29T00:10:00Z" \
FLEET_FAILED_COMMAND_FILE_ISSUES=1 \
FLEET_FAILED_COMMAND_ISSUE_REPO="Nishfleet/fleet-ops" \
FLEET_FAILED_COMMAND_LEDGER="$scratch/ledger-healthy.filed" \
GH="$scratch/gh-healthy" \
GH_MOCK_STORE="$gh_store2" \
FLEET_HEARTBEAT_TRIAGE="$scratch/triage.md" \
  "$bin" >/dev/null 2>"$scratch/err-healthy.log"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "healthy-gh tick should exit 1 (got $rc) $(cat "$scratch/err-healthy.log")"
grep -q "deduped via open list" "$scratch/err-healthy.log" \
  || fail "healthy-gh tick must dedup via open list, not ledger: $(cat "$scratch/err-healthy.log")"
if grep -q "deduped via ledger" "$scratch/err-healthy.log"; then
  fail "healthy-gh tick must NOT use the ledger when open-list dedup already works"
fi
ok "healthy gh: ledger is invisible — open-list dedup is authoritative"

# --- 6. contracts: ledger path is overridable, docstring cites #1071 ------
# Same cross-file pin pattern as the other failed-command tests: the
# lib's docstring must cite #1071 so a future drop of the citation is
# caught.
grep -Fq 'fleet-ops#1071' "$repo_root/lib/failed-command-flagged.py" \
  || fail "lib/failed-command-flagged.py docstring must cite fleet-ops#1071"
ok "lib/failed-command-flagged.py docstring cites #1071"
grep -Fq 'fleet-ops#1071' "$repo_root/bin/fleet-failed-command-flagged" \
  || fail "bin/fleet-failed-command-flagged header must cite fleet-ops#1071"
ok "bin/fleet-failed-command-flagged header cites #1071"

# Lock the env-var seam in the header docstring so a future refactor
# that drops the FLEET_FAILED_COMMAND_LEDGER env var is caught.
grep -Fq 'FLEET_FAILED_COMMAND_LEDGER' "$repo_root/bin/fleet-failed-command-flagged" \
  || fail "bin/fleet-failed-command-flagged must document FLEET_FAILED_COMMAND_LEDGER"
ok "FLEET_FAILED_COMMAND_LEDGER env var is documented in the bin header"

# Lock this test in the seat-lib.test.sh host so it runs on CI (worker
# token cannot add a new workflow line in ci.yml).
grep -Fq 'fleet-failed-command-ledger-dedup.test.sh' "$repo_root/tests/seat-lib.test.sh" \
  || fail "tests/seat-lib.test.sh must invoke fleet-failed-command-ledger-dedup.test.sh (fleet-ops#1071)"
ok "seat-lib.test.sh hosts this file"

echo "OK: fleet-failed-command-ledger-dedup: gh-broken deduplication survives 5-7 consecutive ticks (live #1071)"
