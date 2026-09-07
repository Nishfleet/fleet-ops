#!/usr/bin/env bash
# tests/fleet-close-and-archive-repo.test.sh
#
# Replay drill for bin/fleet-close-and-archive-repo (fleet-ops#3268, child
# of the waste-cut decision fleet-ops#3128): proving the retire-a-dead-repo
# loop offline with a stubbed `gh`.
#
# The live requirement (fleet2 archive) is admin-gated — archiving a repo
# needs Administration, which the nishfleet-worker App token does NOT have
# (verified live: `gh repo archive Nishfleet/fleet2 --yes` -> "Resource not
# accessible by integration (archiveRepository)"). So this drill locks:
#   1. dry-run enumerates open PRs and mutates nothing (no pr close, no
#      repo archive calls).
#   2. --apply closes every open PR with the one comment, then issues the
#      archive command even when the underlying scope is admin-gated.
#   3. The archive step, when the stub refuses (Administration-gated),
#      surfaces ARCHIVE-ADMIN-GATED loudly and exits 0 (close path done) —
#      it never claims the repo was archived.
#   4. Clean repo (total_count 0) -> exit 0, "no open PRs", archive offered
#      in dry-run.
#   5. Missing gh / empty GH_TOKEN -> exit 2.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-close-and-archive-repo"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t fleet-caa.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

gh_fake="$scratch/gh"
gh_log="$scratch/gh.log"
# archive-refusal-gated: stub refuses the archive like the worker App token
# does (Administration scope), but logs it so the drill sees the call.
ARCHIVE_MODE="${ARCHIVE_MODE:-gated}"
cat >"$gh_fake" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\${GH_LOG:-/dev/null}"
case "\$1" in
  api)
    if [[ "\$2" == search/issues* ]]; then
      if [[ "\${CAA_OPEN_JSON:-}" != "" ]]; then
        cat "\$CAA_OPEN_JSON"
      else
        echo '{"total_count":0,"items":[]}'
      fi
      exit 0
    fi
    echo '{}'; exit 0
    ;;
  pr)
    exit 0  # fake a successful close
    ;;
  repo)
    if [[ "\$2" == "archive" ]]; then
      if [[ "\$ARCHIVE_MODE" == "ok" ]]; then
        exit 0
      fi
      echo "GraphQL: Resource not accessible by integration (archiveRepository)" >&2
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export FLEET_CAA_GH="$gh_fake"
export GH_LOG="$gh_log"
export FLEET_CAA_NO_TOKEN=1

export GH_TOKEN=x   # satisfy the tool's GH_TOKEN prereq; stub never calls real gh

write_open() { cat >"$scratch/open.json"; }

# --- 1. dry-run enumerates, mutates nothing ---------------------------------
: >"$gh_log"
write_open <<'JSON'
{"total_count":2,"items":[{"number":10,"title":"docs(pr-landing): X","html_url":"u10"},{"number":21,"title":"fix(foo): Y","html_url":"u21"}]}
JSON
set +e
out=$(FLEET_CAA_APPLY="" FLEET_CAA_REPO="Nishfleet/fleet2" CAA_OPEN_JSON="$scratch/open.json" \
    "$bin" 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario1: dry-run must exit 0, got rc=$rc ($out)"
echo "$out" | grep -q "open_prs=2" || fail "scenario1: must count 2 open PRs ($out)"
echo "$out" | grep -q "would close #10" || fail "scenario1: must say would close #10 ($out)"
echo "$out" | grep -q "would close #21" || fail "scenario1: must say would close #21 ($out)"
if grep -q " pr close " "$gh_log"; then
  fail "scenario1: dry-run must not call pr close (gh=$(cat "$gh_log"))"
fi
if grep -qE "(^| )repo archive " "$gh_log"; then
  fail "scenario1: dry-run must not call repo archive (gh=$(cat "$gh_log"))"
fi
ok "scenario1: dry-run lists 2 open PRs, no mutation"

# --- 2. apply closes every open PR with the one comment ---------------------
: >"$gh_log"
ARCHIVE_MODE=ok
set +e
out=$(export ARCHIVE_MODE; FLEET_CAA_APPLY=1 FLEET_CAA_REPO="Nishfleet/fleet2" CAA_OPEN_JSON="$scratch/open.json" \
    "$bin" 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario2: apply ok-archive must exit 0, got rc=$rc ($out)"
grep -q "pr close 10 --repo Nishfleet/fleet2 -c " "$gh_log" || fail "scenario2: must close #10 with comment ($(cat "$gh_log"))"
grep -q "pr close 21 --repo Nishfleet/fleet2 -c " "$gh_log" || fail "scenario2: must close #21 with comment ($(cat "$gh_log"))"
grep -q "repo archive Nishfleet/fleet2 --yes" "$gh_log" || fail "scenario2: must attempt archive ($(cat "$gh_log"))"
echo "$out" | grep -q "archived Nishfleet/fleet2" || fail "scenario2: must log archived ($out)"
ok "scenario2: apply closes both PRs with one comment and archives"

# --- 3. apply under an admin-gated archive scope ----------------------------
# The worker App token cannot archive (Administration). The close path still
# runs; the archive step reports ARCHIVE-ADMIN-GATED loudly, does not claim
# success, and the tool exits 0 (the close half a worker CAN do is done).
: >"$gh_log"
ARCHIVE_MODE=gated
set +e
out=$(export ARCHIVE_MODE; FLEET_CAA_APPLY=1 FLEET_CAA_REPO="Nishfleet/fleet2" CAA_OPEN_JSON="$scratch/open.json" \
    "$bin" 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario3: gated-archive apply must exit 0, got rc=$rc ($out)"
echo "$out" | grep -q "ARCHIVE-ADMIN-GATED" || fail "scenario3: must surface ARCHIVE-ADMIN-GATED ($out)"
grep -q "pr close 10 --repo Nishfleet/fleet2 -c " "$gh_log" || fail "scenario3: must still close #10 ($(cat "$gh_log"))"
echo "$out" | grep -q "archived Nishfleet/fleet2" && fail "scenario3: must NOT claim archived when gated ($out)"
ok "scenario3: gated archive surfaced loudly, close done, not falsely claimed"

# --- 4. clean repo ----------------------------------------------------------
: >"$gh_log"
write_open <<'JSON'
{"total_count":0,"items":[]}
JSON
set +e
out=$(FLEET_CAA_APPLY="" FLEET_CAA_REPO="Nishfleet/fleet2" CAA_OPEN_JSON="$scratch/open.json" \
    "$bin" 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario4: clean repo must exit 0, got rc=$rc ($out)"
echo "$out" | grep -q "no open PRs to close" || fail "scenario4: must log no open PRs ($out)"
echo "$out" | grep -q "would archive:" || fail "scenario4: must offer archive in dry-run ($out)"
if grep -qE "(^| )repo archive " "$gh_log"; then
  fail "scenario4: dry-run must not call repo archive ($(cat "$gh_log"))"
fi
ok "scenario4: clean repo exit 0, archive offered in dry-run"

# --- 5. missing gh / empty token -> exit 2 ----------------------------------
set +e
out=$(FLEET_CAA_GH="/nonexistent/gh" FLEET_CAA_NO_TOKEN=1 FLEET_CAA_REPO="Nishfleet/fleet2" \
    "$bin" 2>&1)
rc=$?
set -e
[[ "$rc" == "2" ]] || fail "scenario5: missing gh must exit 2, got rc=$rc ($out)"
set +e
out=$(env -u GH_TOKEN -u FLEET_CAA_NO_TOKEN FLEET_CAA_GH="$gh_fake" FLEET_CAA_REPO="Nishfleet/fleet2" "$bin" 2>&1)
rc=$?
set -e
[[ "$rc" == "2" ]] || fail "scenario5b: empty GH_TOKEN must exit 2, got rc=$rc ($out)"
ok "scenario5: missing gh / empty token exit 2"

echo "ALL FLEET-CLOSE-AND-ARCHIVE-REPO DRILL CHECKS PASSED"
