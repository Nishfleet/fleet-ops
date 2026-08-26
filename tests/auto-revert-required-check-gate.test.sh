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
      record "ISSUE_COMMENT $*"
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
