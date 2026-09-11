#!/usr/bin/env bash
# tests/auto-revert-recovery.test.sh
#
# The fleet-ops#5597 drill: pins BOTH halves of the consecutive-red repair.
#
#   1. consecutive red (>=2 completed failing runs of the watched workflow on
#      main) -> ONE range-revert PR from a repair/red-main-* branch, opened,
#      armed, and filed LOUD: an ALERT: line on stdout plus an auto-filed
#      issue naming the reverted shas and the failing run ids.
#   2. a refusal (checks non-green, no revert PR opened) -> exit 0 with the
#      explicit `refused: checks non-green on <sha>` step summary. NOT
#      conclusion=failure — a red Auto revert run is a false red signal in
#      exactly the window humans and detectors read.
#
# Fully mocked: fake gh + fake git (push is a no-op) so the drill runs
# offline in CI, exactly like its cousin tests/auto-revert-required-check-gate.test.sh.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/auto-revert.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "auto-revert script not found: $script"

scratch="$(mktemp -d -t auto-revert-recovery.XXXXXX)"
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

# Fake gh: replay the workflow-runs streak fixture, record every call.
# The workflows-runs endpoint is what makes a run "consecutively red"
# (fleet-ops#5597): the drill exercises the real streak-counting branch,
# not a mock of it.
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
      repos/*/actions/workflows/*/runs*)
        # fleet-ops#5597: the consecutive-red streak reads the completed
        # push runs of the triggering workflow on main, newest first.
        src="$WORKFLOW_RUNS_JSON"
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
    if [ "$sub" = "list" ]; then
      record "PR_LIST $*"
      # empty: no open repair/red-main-* or revert/* PR
      exit 0
    elif [ "$sub" = "create" ]; then
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

# Build a scratch main: one green baseline, then two commits that each
# landed red. The last-green sha is a real ancestor, exactly like the
# 2026-09-11 19:27-19:36Z four-red incident.
repo="$scratch/repo"
mkdir -p "$repo"
(
  cd "$repo"
  git init -q
  git config user.name "Test"
  git config user.email "test@example.com"
  : > a.txt
  git add a.txt
  git commit -q -m "initial green baseline"
  echo "one" > a.txt
  git add a.txt
  git commit -q -m "fix(tests): red landing one"
  echo "two" > a.txt
  git add a.txt
  git commit -q -m "fix(tests): red landing two"
)
green_sha="$(cd "$repo" && git rev-parse HEAD~2)"
red1_sha="$(cd "$repo" && git rev-parse HEAD~1)"
red2_sha="$(cd "$repo" && git rev-parse HEAD)"
red1_short="$(printf '%s' "$red1_sha" | cut -c1-7)"
red2_short="$(printf '%s' "$red2_sha" | cut -c1-7)"
head_short="$(printf '%s' "$red2_sha" | cut -c1-7)"

# Workflows-runs fixture: newest first, like the live runs API. Two
# consecutive failures then the last green run of the watched workflow.
runs_fixture="$scratch/workflow-runs.json"
cat >"$runs_fixture" <<EOF
{
  "workflow_runs": [
    {"conclusion": "failure", "head_sha": "$red2_sha", "id": 34639736242, "html_url": "https://github.com/Nishfleet/fleet-ops/actions/runs/34639736242"},
    {"conclusion": "failure", "head_sha": "$red1_sha", "id": 34638927976, "html_url": "https://github.com/Nishfleet/fleet-ops/actions/runs/34638927976"},
    {"conclusion": "success", "head_sha": "$green_sha", "id": 34600000001, "html_url": "https://github.com/Nishfleet/fleet-ops/actions/runs/34600000001"}
  ]
}
EOF

# ---------------------------------------------------------------------------
# Scenario R: consecutive red (streak 2) -> range-revert PR, armed, LOUD.
# ---------------------------------------------------------------------------
summary_r="$scratch/summary-r.txt"
: > "$summary_r"
calls_r="$scratch/calls-r"
: > "$calls_r"

set +e
(
  cd "$repo"
  env PATH="$fake_bin:$PATH" \
    HOME="$scratch" \
    GH_TOKEN="fake-token" \
    REPO="Nishfleet/fleet-ops" \
    HEAD_SHA="$red2_sha" \
    RUN_NAME="CI" \
    RUN_URL="https://github.com/Nishfleet/fleet-ops/actions/runs/34639736242" \
    WORKFLOW_ID="123456" \
    WORKFLOW_RUNS_JSON="$runs_fixture" \
    GH_CALLS_FILE="$calls_r" \
    GITHUB_STEP_SUMMARY="$summary_r" \
    bash "$script"
) >"$scratch/scenario-r.out" 2>"$scratch/scenario-r.err"
rc=$?
set -e

[[ "$rc" == "0" ]] || fail "scenario R: expected exit 0, got $rc (stderr: $(cat "$scratch/scenario-r.err"))"
grep -q "ALERT: consecutive-red main" "$scratch/scenario-r.out" \
  || fail "scenario R: expected an ALERT: line, got: $(cat "$scratch/scenario-r.out")"
grep -q "head=repair/red-main-$head_short " "$calls_r" \
  || fail "scenario R: expected a repair/red-main-* revert PR, got calls: $(cat "$calls_r")"
grep -q "PR_MERGE" "$calls_r" \
  || fail "scenario R: expected the recovery PR to be auto-merge armed, got calls: $(cat "$calls_r")"
grep -q "ISSUE_CREATE title=AUTO-REVERT RECOVERY" "$calls_r" \
  || fail "scenario R: expected a loud recovery issue, got calls: $(cat "$calls_r")"
grep -q "34639736242" "$calls_r" && grep -q "34638927976" "$calls_r" \
  || fail "scenario R: the recovery issue must name BOTH failing run ids, got calls: $(cat "$calls_r")"
grep -q "$red1_short" "$calls_r" && grep -q "$red2_short" "$calls_r" \
  || fail "scenario R: the recovery issue must name BOTH reverted shas ($red1_short, $red2_short), got calls: $(cat "$calls_r")"
grep -q "repaired: opened" "$summary_r" \
  || fail "scenario R: expected a repaired: step-summary line, got: $(cat "$summary_r")"
ok "scenario R: consecutive red -> repair/red-main-* PR, armed, ALERT + issue naming shas and run ids"

# Single-failure fixture: streak 1 -> the single-red path (used by N).
runs_fixture_one_red="$scratch/workflow-runs-one-red.json"
cat >"$runs_fixture_one_red" <<EOF
{
  "workflow_runs": [
    {"conclusion": "failure", "head_sha": "$red1_sha", "id": 34638927976, "html_url": "https://github.com/Nishfleet/fleet-ops/actions/runs/34638927976"}
  ]
}
EOF

# ---------------------------------------------------------------------------
# Scenario N: single red, main moved -> refusal. Ends 0 (never a false red)
# with the explicit `refused: checks non-green on <sha>` step summary.
# ---------------------------------------------------------------------------
summary_n="$scratch/summary-n.txt"
: > "$summary_n"
calls_n="$scratch/calls-n"
: > "$calls_n"

# Scenario R left the repair/red-main-* branch checked out; the single-red
# refusal runs against main itself.
git -C "$repo" checkout -q main

set +e
(
  cd "$repo"
  env PATH="$fake_bin:$PATH" \
    HOME="$scratch" \
    GH_TOKEN="fake-token" \
    REPO="Nishfleet/fleet-ops" \
    HEAD_SHA="$red1_sha" \
    RUN_NAME="CI" \
    RUN_URL="https://github.com/Nishfleet/fleet-ops/actions/runs/34638927976" \
    WORKFLOW_ID="123456" \
    WORKFLOW_RUNS_JSON="$runs_fixture_one_red" \
    GH_CALLS_FILE="$calls_n" \
    GH_HALT_ISSUE_NUMBER="43" \
    GH_HALT_ISSUE_TITLE="AUTO-REVERT HALT: main moved after the red commit" \
    GITHUB_STEP_SUMMARY="$summary_n" \
    bash "$script"
) >"$scratch/scenario-n.out" 2>"$scratch/scenario-n.err"
rc=$?
set -e

[[ "$rc" == "0" ]] || fail "scenario N: expected exit 0 (refusal is not a failure), got $rc (stderr: $(cat "$scratch/scenario-n.err"))"
grep -q "refused: checks non-green on $red1_sha" "$summary_n" \
  || fail "scenario N: expected the refused: checks non-green step summary, got: $(cat "$summary_n")"
if grep -q "PR_CREATE\|PR_MERGE" "$calls_n"; then
  fail "scenario N: a refusal must not open or merge a revert PR, got calls: $(cat "$calls_n")"
fi
grep -q "ISSUE_COMMENT 43 " "$calls_n" \
  || fail "scenario N: the refusal must still be filed loud (comment on the halt issue), got calls: $(cat "$calls_n")"
ok "scenario N: single red, main moved -> refused: exit 0, refused: summary, loud filing, no revert PR"

# ---------------------------------------------------------------------------
# Scenario N2: only a non-required check failed (the P14 shape) -> refusal.
# Same contract: exit 0, refused: summary, no revert PR.
# ---------------------------------------------------------------------------
check_runs_p14="$scratch/check-runs-p14.json"
cat >"$check_runs_p14" <<'EOF'
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
summary_n2="$scratch/summary-n2.txt"
: > "$summary_n2"
calls_n2="$scratch/calls-n2"
: > "$calls_n2"

git -C "$repo" checkout -q main 2>/dev/null || true

set +e
(
  cd "$repo"
  env PATH="$fake_bin:$PATH" \
    HOME="$scratch" \
    GH_TOKEN="fake-token" \
    REPO="Nishfleet/fleet-ops" \
    HEAD_SHA="$red2_sha" \
    RUN_NAME="CI" \
    RUN_URL="https://github.com/Nishfleet/fleet-ops/actions/runs/34639736242" \
    WORKFLOW_ID="123456" \
    WORKFLOW_RUNS_JSON="$runs_fixture_one_red" \
    GH_CALLS_FILE="$calls_n2" \
    REQUIRED_CONTEXTS_JSON="$required_contexts" \
    CHECK_RUNS_JSON="$check_runs_p14" \
    GITHUB_STEP_SUMMARY="$summary_n2" \
    bash "$script"
) >"$scratch/scenario-n2.out" 2>"$scratch/scenario-n2.err"
rc=$?
set -e

[[ "$rc" == "0" ]] || fail "scenario N2: expected exit 0 (refusal is not a failure), got $rc (stderr: $(cat "$scratch/scenario-n2.err"))"
grep -q "refused: checks non-green on $red2_sha" "$summary_n2" \
  || fail "scenario N2: expected the refused: checks non-green step summary, got: $(cat "$summary_n2")"
if grep -q "PR_CREATE\|PR_MERGE" "$calls_n2"; then
  fail "scenario N2: only-non-required failure must not open or merge a revert PR, got calls: $(cat "$calls_n2")"
fi
grep -q "AUTO-REVERT SKIP: only non-required checks failed" "$calls_n2" \
  || fail "scenario N2: expected the loud SKIP halt filing, got calls: $(cat "$calls_n2")"
ok "scenario N2: only non-required (P14) failure -> refused: exit 0, refused: summary, SKIP filing, no revert PR"

echo "auto-revert-recovery: consecutive-red repairs, refusals stay green"
