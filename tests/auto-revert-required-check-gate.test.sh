#!/usr/bin/env bash
# tests/auto-revert-required-check-gate.test.sh
#
# Proves auto-revert only opens a revert PR when a required status check
# failed. Non-required failures (e.g. P14 tests / PR checks) become a halt
# issue and exit 0 without reverting.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/auto-revert.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "auto-revert script not found: $script"

scratch="$(mktemp -d -t auto-revert-gate.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

fake_bin="$scratch/fake-bin"
mkdir -p "$fake_bin"
real_git="$(command -v git)"
[[ -n "$real_git" ]] || fail "real git not found"

# Fake git: delegate everything to the real git, but make `push` a no-op
# so the test never reaches the network.
cat >"$fake_bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then
  exit 0
fi
exec $real_git "\$@"
EOF
chmod +x "$fake_bin/git"

# Fake gh: replay branch protection and check-runs fixtures, record calls.
cat >"$fake_bin/gh" <<'GH'
#!/usr/bin/env bash
record() { printf '%s\n' "$*" >> "$GH_CALLS_FILE"; }
cmd="$1"
shift
case "$cmd" in
  label)
    record "LABEL $*"
    exit 0
    ;;
  api)
    endpoint="$1"
    shift
    case "$endpoint" in
      repos/*/issues/*/comments)
        issue_num="$(printf '%s' "$endpoint" | awk -F/ '{print $(NF-1)}')"
        record "ISSUE_COMMENT $issue_num REST"
        cat >/dev/null || true
        if [ -n "${GH_COMMENT_REST_FAIL:-}" ]; then
          echo "REST: comment create failed" >&2
          exit 1
        fi
        exit 0
        ;;
    esac
    filter=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --paginate) shift ;;
        --jq) filter="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$endpoint" in
      repos/*/branches/main/protection)
        src="$REQUIRED_CONTEXTS_JSON"
        ;;
      repos/*/commits/*/check-runs)
        src="$CHECK_RUNS_JSON"
        ;;
      *)
        src=""
        ;;
    esac
    if [ -z "$src" ] || [ ! -f "$src" ]; then
      exit 0
    fi
    if [ -n "$filter" ]; then
      jq -r "$filter" < "$src"
    else
      cat "$src"
    fi
    exit 0
    ;;
  issue)
    sub="$1"
    shift
    if [ "$sub" = "list" ]; then
      record "ISSUE_LIST $*"
      jq_filter=""
      search_q=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --jq) jq_filter="$2"; shift 2 ;;
          --search) search_q="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      json=""
      # Simulate GitHub title search: return rolling issue(s) only when the
      # search query's exact phrase matches the existing halt title. This
      # mirrors production (title-based, label-independent) so the test
      # proves consolidation works even when the label never sticks.
      if [ -n "${GH_HALT_ISSUE_TITLE:-}" ] && [ -n "$search_q" ] \
         && [[ "$search_q" == *"$GH_HALT_ISSUE_TITLE"* ]]; then
        if [ -n "${GH_HALT_ISSUE_NUMBERS:-}" ]; then
          json="$(jq -n --arg t "$GH_HALT_ISSUE_TITLE" --arg nums "$GH_HALT_ISSUE_NUMBERS" \
            '($nums | split(" ")) | map(select(length > 0)) | map({number: (.|tonumber), title: $t})')"
        elif [ -n "${GH_HALT_ISSUE_NUMBER:-}" ]; then
          json="$(jq -n --arg t "$GH_HALT_ISSUE_TITLE" --argjson n "$GH_HALT_ISSUE_NUMBER" \
            '[{number: $n, title: $t}]')"
        fi
      fi
      if [ -n "$json" ]; then
        if [ -n "$jq_filter" ]; then
          printf '%s\n' "$json" | jq -r "$jq_filter"
        else
          printf '%s\n' "$json"
        fi
      fi
      exit 0
    elif [ "$sub" = "create" ]; then
      title=""; body=""; label=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --repo|-R) shift 2 ;;
          --title) title="$2"; shift 2 ;;
          --body) body="$2"; shift 2 ;;
          --label) label="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      record "ISSUE_CREATE title=$title body=$body label=$label"
      exit 0
    elif [ "$sub" = "comment" ]; then
      # Production AUTO_REVERT_PAT cannot call GraphQL addComment (fleet-ops#596).
      # Always fail this subcommand so a revert to `gh issue comment` reddens A2/A3.
      record "ISSUE_COMMENT_GRAPHQL $*"
      echo "GraphQL: Resource not accessible by personal access token (addComment)" >&2
      exit 1
    elif [ "$sub" = "close" ]; then
      record "ISSUE_CLOSE $*"
      exit 0
    fi
    exit 0
    ;;
  pr)
    sub="$1"
    shift
    if [ "$sub" = "create" ]; then
      title=""; body=""; base=""; head=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --repo|-R) shift 2 ;;
          --title) title="$2"; shift 2 ;;
          --body) body="$2"; shift 2 ;;
          --base) base="$2"; shift 2 ;;
          --head) head="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      record "PR_CREATE title=$title head=$head base=$base body=$body"
      printf 'https://github.com/Nishfleet/fleet-ops/pull/999\n'
      exit 0
    elif [ "$sub" = "merge" ]; then
      record "PR_MERGE $*"
      exit 0
    fi
    exit 0
    ;;
  *)
    record "UNKNOWN $cmd $*"
    exit 0
    ;;
esac
GH
chmod +x "$fake_bin/gh"

# Required-status-checks fixture (matches the live branch protection).
required_contexts="$scratch/required-contexts.json"
cat >"$required_contexts" <<'EOF'
{
  "required_status_checks": {
    "contexts": ["Gitleaks", "Semgrep", "Shellcheck", "systemd-analyze"],
    "checks": [
      {"context": "Gitleaks", "app_id": 15368},
      {"context": "Semgrep", "app_id": 15368},
      {"context": "Shellcheck", "app_id": 15368},
      {"context": "systemd-analyze"}
    ]
  }
}
EOF

# Build a tiny git repo on main with one green commit to revert.
repo="$scratch/repo"
mkdir -p "$repo"
(
  cd "$repo"
  git init
  git config user.name "Test"
  git config user.email "test@example.com"
  : > a.txt
  git add a.txt
  git commit -m "initial"
  echo "change" > a.txt
  git add a.txt
  git commit -m "fix(tests): a green change"
)
head_sha="$(cd "$repo" && git rev-parse HEAD)"

# Scenario A: only the non-required P14 check failed. Should skip revert.
check_runs_a="$scratch/check-runs-a.json"
cat >"$check_runs_a" <<'EOF'
{
  "check_runs": [
    {"name": "Gitleaks", "conclusion": "success", "status": "completed"},
    {"name": "Semgrep", "conclusion": "success", "status": "completed"},
    {"name": "Shellcheck", "conclusion": "success", "status": "completed"},
    {"name": "systemd-analyze", "conclusion": "success", "status": "completed"},
    {"name": "P14 tests / PR checks", "conclusion": "failure", "status": "completed"}
  ]
}
EOF
calls_a="$scratch/calls-a"
: > "$calls_a"

set +e
(
  cd "$repo"
  env PATH="$fake_bin:$PATH" \
    HOME="$scratch" \
    GH_TOKEN="fake-token" \
    REPO="Nishfleet/fleet-ops" \
    HEAD_SHA="$head_sha" \
    RUN_NAME="CI" \
    RUN_URL="https://github.com/Nishfleet/fleet-ops/actions/runs/123" \
    GH_CALLS_FILE="$calls_a" \
    REQUIRED_CONTEXTS_JSON="$required_contexts" \
    CHECK_RUNS_JSON="$check_runs_a" \
    bash "$script"
) >"$scratch/scenario-a.out" 2>"$scratch/scenario-a.err"
rc=$?
set -e

[[ "$rc" == "0" ]] || fail "scenario A: expected exit 0, got $rc (stderr: $(cat "$scratch/scenario-a.err"))"
grep -q "ISSUE_CREATE title=AUTO-REVERT SKIP" "$calls_a" \
  || fail "scenario A: expected a halt issue titled AUTO-REVERT SKIP, got calls: $(cat "$calls_a")"
grep -q "P14 tests / PR checks" "$calls_a" \
  || fail "scenario A: expected the issue body to name the non-required check, got calls: $(cat "$calls_a")"
if grep -q "PR_CREATE\|PR_MERGE" "$calls_a"; then
  fail "scenario A: must not open or merge a revert PR, got calls: $(cat "$calls_a")"
fi
ok "scenario A: only P14 tests / PR checks failed -> halt issue, no revert"

# Scenario A2 (dedup, label-independent): an open halt issue already exists.
# GH_HALT_ISSUE_TITLE simulates a rolling issue whose title matches but whose
# auto-revert-halt label never stuck (the production bug). halt() must find it
# by title and comment, not create a duplicate.
calls_a2="$scratch/calls-a2"
: > "$calls_a2"

set +e
(
  cd "$repo"
  env PATH="$fake_bin:$PATH" \
    HOME="$scratch" \
    GH_TOKEN="fake-token" \
    REPO="Nishfleet/fleet-ops" \
    HEAD_SHA="$head_sha" \
    RUN_NAME="CI" \
    RUN_URL="https://github.com/Nishfleet/fleet-ops/actions/runs/125" \
    GH_CALLS_FILE="$calls_a2" \
    REQUIRED_CONTEXTS_JSON="$required_contexts" \
    CHECK_RUNS_JSON="$check_runs_a" \
    GH_HALT_ISSUE_NUMBER="42" \
    GH_HALT_ISSUE_TITLE="AUTO-REVERT SKIP: only non-required checks failed" \
    bash "$script"
) >"$scratch/scenario-a2.out" 2>"$scratch/scenario-a2.err"
rc=$?
set -e

[[ "$rc" == "0" ]] || fail "scenario A2: expected exit 0, got $rc (stderr: $(cat "$scratch/scenario-a2.err"))"
grep -q "ISSUE_LIST" "$calls_a2" \
  || fail "scenario A2: expected halt() to look up the existing open issue, got calls: $(cat "$calls_a2")"
grep -q "ISSUE_LIST.*--search" "$calls_a2" \
  || fail "scenario A2: expected halt() to look up the rolling issue by --search (title), got calls: $(cat "$calls_a2")"
if grep -q "ISSUE_LIST.*--label" "$calls_a2"; then
  fail "scenario A2: dedup must not depend on --label (the label never sticks in production), got calls: $(cat "$calls_a2")"
fi
grep -q "ISSUE_COMMENT 42 " "$calls_a2" \
  || fail "scenario A2: expected a comment on the existing halt issue #42, got calls: $(cat "$calls_a2")"
if grep -q "ISSUE_CREATE" "$calls_a2"; then
  fail "scenario A2: must not create a new halt issue when one is already open, got calls: $(cat "$calls_a2")"
fi
if grep -q "ISSUE_CLOSE" "$calls_a2"; then
  fail "scenario A2: a single rolling issue must not be closed, got calls: $(cat "$calls_a2")"
fi
if grep -q "PR_CREATE\|PR_MERGE" "$calls_a2"; then
  fail "scenario A2: must not open or merge a revert PR, got calls: $(cat "$calls_a2")"
fi
ok "scenario A2: existing halt issue found by title (label never stuck) -> comment, no duplicate ISSUE_CREATE"

# Scenario A2b: an open issue whose title only mentions SKIP must not count
# as the rolling halt issue (live cousin: fleet-ops#360).
calls_a2b="$scratch/calls-a2b"
: > "$calls_a2b"

set +e
(
  cd "$repo"
  env PATH="$fake_bin:$PATH" \
    HOME="$scratch" \
    GH_TOKEN="fake-token" \
    REPO="Nishfleet/fleet-ops" \
    HEAD_SHA="$head_sha" \
    RUN_NAME="CI" \
    RUN_URL="https://github.com/Nishfleet/fleet-ops/actions/runs/126" \
    GH_CALLS_FILE="$calls_a2b" \
    REQUIRED_CONTEXTS_JSON="$required_contexts" \
    CHECK_RUNS_JSON="$check_runs_a" \
    GH_HALT_ISSUE_NUMBER="360" \
    GH_HALT_ISSUE_TITLE="fix(auto-revert): SKIP-issue dedup still spawns separate issues after #336" \
    bash "$script"
) >"$scratch/scenario-a2b.out" 2>"$scratch/scenario-a2b.err"
rc=$?
set -e

[[ "$rc" == "0" ]] || fail "scenario A2b: expected exit 0, got $rc (stderr: $(cat "$scratch/scenario-a2b.err"))"
grep -q "ISSUE_CREATE title=AUTO-REVERT SKIP" "$calls_a2b" \
  || fail "scenario A2b: a non-matching title must not satisfy dedup, got calls: $(cat "$calls_a2b")"
if grep -q "ISSUE_COMMENT" "$calls_a2b"; then
  fail "scenario A2b: must not comment on an unrelated issue, got calls: $(cat "$calls_a2b")"
fi
ok "scenario A2b: unrelated SKIP-mentioning issue does not satisfy dedup"

# Scenario A3 (consolidate): several unlabeled SKIP issues already exist
# (GitHub returns newest first). halt() must comment on the oldest and close
# the extras as duplicates of it.
calls_a3="$scratch/calls-a3"
: > "$calls_a3"

set +e
(
  cd "$repo"
  env PATH="$fake_bin:$PATH" \
    HOME="$scratch" \
    GH_TOKEN="fake-token" \
    REPO="Nishfleet/fleet-ops" \
    HEAD_SHA="$head_sha" \
    RUN_NAME="CI" \
    RUN_URL="https://github.com/Nishfleet/fleet-ops/actions/runs/127" \
    GH_CALLS_FILE="$calls_a3" \
    REQUIRED_CONTEXTS_JSON="$required_contexts" \
    CHECK_RUNS_JSON="$check_runs_a" \
    GH_HALT_ISSUE_NUMBERS="108 42 99" \
    GH_HALT_ISSUE_TITLE="AUTO-REVERT SKIP: only non-required checks failed" \
    bash "$script"
) >"$scratch/scenario-a3.out" 2>"$scratch/scenario-a3.err"
rc=$?
set -e

[[ "$rc" == "0" ]] || fail "scenario A3: expected exit 0, got $rc (stderr: $(cat "$scratch/scenario-a3.err"))"
grep -q "ISSUE_COMMENT 42 " "$calls_a3" \
  || fail "scenario A3: expected a comment on the oldest issue #42, got calls: $(cat "$calls_a3")"
grep -q "ISSUE_CLOSE 99 " "$calls_a3" \
  || fail "scenario A3: expected extra #99 to be closed, got calls: $(cat "$calls_a3")"
grep -q "ISSUE_CLOSE 108 " "$calls_a3" \
  || fail "scenario A3: expected extra #108 to be closed, got calls: $(cat "$calls_a3")"
grep -q "ISSUE_CLOSE 99 .*--duplicate-of 42" "$calls_a3" \
  || fail "scenario A3: extras must close as duplicates of #42, got calls: $(cat "$calls_a3")"
if grep -q "ISSUE_CLOSE 42 " "$calls_a3"; then
  fail "scenario A3: the rolling (oldest) issue must stay open, got calls: $(cat "$calls_a3")"
fi
if grep -q "ISSUE_CREATE" "$calls_a3"; then
  fail "scenario A3: must not create a new halt issue when rolling issues exist, got calls: $(cat "$calls_a3")"
fi
ok "scenario A3: multiple SKIP issues -> comment on oldest, close extras as duplicates"

# Scenario A5 (fleet-ops#596): REST comment create fails. SKIP must still
# exit 0 — the halt issue already exists; a comment API failure must not
# paint Auto revert red on main.
calls_a5="$scratch/calls-a5"
: > "$calls_a5"

set +e
(
  cd "$repo"
  env PATH="$fake_bin:$PATH" \
    HOME="$scratch" \
    GH_TOKEN="fake-token" \
    REPO="Nishfleet/fleet-ops" \
    HEAD_SHA="$head_sha" \
    RUN_NAME="CI" \
    RUN_URL="https://github.com/Nishfleet/fleet-ops/actions/runs/128" \
    GH_CALLS_FILE="$calls_a5" \
    REQUIRED_CONTEXTS_JSON="$required_contexts" \
    CHECK_RUNS_JSON="$check_runs_a" \
    GH_HALT_ISSUE_NUMBER="42" \
    GH_HALT_ISSUE_TITLE="AUTO-REVERT SKIP: only non-required checks failed" \
    GH_COMMENT_REST_FAIL="1" \
    bash "$script"
) >"$scratch/scenario-a5.out" 2>"$scratch/scenario-a5.err"
rc=$?
set -e

[[ "$rc" == "0" ]] || fail "scenario A5: expected exit 0 when REST comment fails, got $rc (stderr: $(cat "$scratch/scenario-a5.err"))"
grep -q "ISSUE_COMMENT 42 " "$calls_a5" \
  || fail "scenario A5: expected a REST comment attempt on #42, got calls: $(cat "$calls_a5")"
if grep -q "ISSUE_COMMENT_GRAPHQL" "$calls_a5"; then
  fail "scenario A5: must not fall back to GraphQL gh issue comment, got calls: $(cat "$calls_a5")"
fi
if grep -q "ISSUE_CREATE" "$calls_a5"; then
  fail "scenario A5: must not create a new halt issue when one is already open, got calls: $(cat "$calls_a5")"
fi
if grep -q "PR_CREATE\|PR_MERGE" "$calls_a5"; then
  fail "scenario A5: must not open or merge a revert PR, got calls: $(cat "$calls_a5")"
fi
ok "scenario A5: REST comment failure on existing SKIP issue -> exit 0, no revert"

# Scenario B: the required Semgrep check failed. Should open a revert PR.
check_runs_b="$scratch/check-runs-b.json"
cat >"$check_runs_b" <<'EOF'
{
  "check_runs": [
    {"name": "Gitleaks", "conclusion": "success", "status": "completed"},
    {"name": "Semgrep", "conclusion": "failure", "status": "completed"},
    {"name": "Shellcheck", "conclusion": "success", "status": "completed"},
    {"name": "systemd-analyze", "conclusion": "success", "status": "completed"},
    {"name": "P14 tests / PR checks", "conclusion": "success", "status": "completed"}
  ]
}
EOF
calls_b="$scratch/calls-b"
: > "$calls_b"

set +e
(
  cd "$repo"
  env PATH="$fake_bin:$PATH" \
    HOME="$scratch" \
    GH_TOKEN="fake-token" \
    REPO="Nishfleet/fleet-ops" \
    HEAD_SHA="$head_sha" \
    RUN_NAME="CI" \
    RUN_URL="https://github.com/Nishfleet/fleet-ops/actions/runs/124" \
    GH_CALLS_FILE="$calls_b" \
    REQUIRED_CONTEXTS_JSON="$required_contexts" \
    CHECK_RUNS_JSON="$check_runs_b" \
    bash "$script"
) >"$scratch/scenario-b.out" 2>"$scratch/scenario-b.err"
rc=$?
set -e

[[ "$rc" == "0" ]] || fail "scenario B: expected exit 0, got $rc (stderr: $(cat "$scratch/scenario-b.err"))"
grep -q "PR_CREATE title=revert:" "$calls_b" \
  || fail "scenario B: expected a revert PR to be created, got calls: $(cat "$calls_b")"
grep -q "head=revert/" "$calls_b" \
  || fail "scenario B: expected the revert PR to be from a revert/* branch, got calls: $(cat "$calls_b")"
grep -q "PR_MERGE" "$calls_b" \
  || fail "scenario B: expected auto-merge to be armed, got calls: $(cat "$calls_b")"
if grep -q "ISSUE_CREATE" "$calls_b"; then
  fail "scenario B: must not create a halt issue when a required check failed, got calls: $(cat "$calls_b")"
fi
ok "scenario B: Semgrep (required) failed -> revert PR created and armed"

ok "auto-revert gates on required checks: non-required skips, required reverts"

# fleet-ops#596: GraphQL `gh issue comment` reddens Auto revert on a PAT.
# The fake `issue comment` subcommand always exits 1 with that production
# error, so A2/A3 fail if the script reverts. Also lock the source.
if grep -E '^[[:space:]]*gh[[:space:]]+issue[[:space:]]+comment[[:space:]]' "$script"; then
  fail "auto-revert.sh must post comments via REST (gh api .../comments), not GraphQL gh issue comment"
fi
if ! grep -q 'repos/${REPO}/issues/${num}/comments' "$script"; then
  fail "auto-revert.sh must POST comments to repos/\$REPO/issues/\$num/comments"
fi
ok "contract: halt comments use REST, not GraphQL gh issue comment"

# fleet-ops#349: stale auto-revert PRs must close themselves so heartbeat
# cannot auto-merge them after main has moved. A named ci.yml step is out
# of band for the worker App (Contents cannot push workflow files).
bash "$here/fleet-stale-auto-revert-sweep.test.sh"
