#!/usr/bin/env bash
# tests/console-truth-pytest.test.sh
#
# fleet-ops#5072: libexec/fleet-console-pi/test_console_truth.py (the console
# truth suite, including the fleet-ops#4996 `gh issue view` argv regressions)
# was invoked by nothing — not ci.yml, not a tests/*.test.sh host, not pytest
# discovery — so a console-truth regression could land on a green suite nobody
# ran. This wrapper runs the suite on a gate, and proves the gate has teeth by
# reintroducing the #4996 argv bug in a scratch copy and requiring a red run.
#
# Hosted by tests/console-tile-verify.test.sh (P14-reachable through
# tests/ci-standards-audit.test.sh, which ci.yml lists). The worker App cannot
# push .github/workflows/**, so a host line is the only gate path
# (fleet-ops#566).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

suite="$repo_root/libexec/fleet-console-pi/test_console_truth.py"
[[ -f "$suite" ]] || fail "missing $suite"

# Resolve a pytest runner. Hosted CI's system python has no pytest module and
# the worker App cannot add an install line to ci.yml, so fall back to a pytest
# on PATH (the VPS uv tool) and then to the pinned pip install ci.yml already
# uses for pyyaml and semgrep. A runner that cannot be resolved is a hard FAIL:
# a truth gate that silently does not run is the bug this test exists for.
if python3 -m pytest --version >/dev/null 2>&1; then
  run=(python3 -m pytest)
elif command -v pytest >/dev/null 2>&1 && pytest --version >/dev/null 2>&1; then
  run=(pytest)
else
  python3 -m pip install --no-input "pytest==9.1.1" \
    || fail "no pytest runner: 'python3 -m pytest' and 'pytest' are both missing, and 'python3 -m pip install pytest==9.1.1' failed"
  python3 -m pytest --version >/dev/null 2>&1 \
    || fail "'python3 -m pip install pytest==9.1.1' reported success but 'python3 -m pytest --version' still fails"
  run=(python3 -m pytest)
fi

# The whole suite must run: pytest exits 5 when it collects nothing, but a
# narrowed collection (a renamed or deleted test) still exits 0. Tie the passed
# count to the number of test functions on disk so the gate cannot go quiet
# while staying green.
expected="$(grep -c '^def test_' "$suite")"
(( expected > 0 )) || fail "no 'def test_' functions found in $suite"

out="$("${run[@]}" -q "$suite" 2>&1)" || {
  printf '%s\n' "$out" >&2
  fail "console-truth suite is red (${run[*]} $suite)"
}
printf '%s\n' "$out"
grep -qE "^${expected} passed" <<<"$out" \
  || fail "expected ${expected} passed from $suite, got: $(tail -n 1 <<<"$out")"
ok "console-truth suite green (${expected} passed)"

# Teeth: reintroducing the fleet-ops#4996 argv bug (the repo and the issue
# number both passed positionally to `gh issue view`, which accepts one) must
# turn this gate red. Mutate a scratch copy — never the tree — and require the
# argv test to be the named failure, so a red for an unrelated reason cannot
# stand in for the drill.
scratch="$(mktemp -d)"
trap 'rm -r "$scratch"' EXIT
cp "$repo_root"/libexec/fleet-console-pi/*.py "$scratch/"
sed -i 's|"issue", "view", str(number),|"issue", "view", repo, str(number),|' \
  "$scratch/generate.py"
grep -qF '"issue", "view", repo, str(number),' "$scratch/generate.py" \
  || fail "drill mutation did not apply — the #4996 argv line moved; update this drill"
if drill_out="$("${run[@]}" -q "$scratch/test_console_truth.py" 2>&1)"; then
  printf '%s\n' "$drill_out" >&2
  fail "the #4996 argv regression was reintroduced and the truth suite still PASSED — this gate has no teeth"
fi
grep -q "test_questions_issue_view_argv_takes_one_positional" <<<"$drill_out" \
  || {
    printf '%s\n' "$drill_out" >&2
    fail "drill run failed for the wrong reason: the argv test is not named in the red output"
  }
ok "injected #4996 argv regression -> truth suite red (gate has teeth)"

echo "PASS: console-truth-pytest"
