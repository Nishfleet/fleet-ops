#!/usr/bin/env bash
# tests/console-truth-pytest.test.sh
#
# fleet-ops#5072: libexec/fleet-console-pi/test_console_truth.py (the
# console-truth suite, including the fleet-ops#4996 argv regressions) was
# invoked by nothing — not ci.yml, not a tests/*.test.sh host, not pytest
# discovery — so a console-truth regression could land with a green suite
# nobody ran. This wrapper runs the suite so a red run fails a PR.
#
# Hosted by tests/console-tile-verify.test.sh (P14-reachable via
# tests/ci-standards-audit.test.sh, listed in ci.yml). The worker App
# cannot push .github/workflows/**, so the host line is the gate path.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

suite="$repo_root/libexec/fleet-console-pi/test_console_truth.py"
[[ -f "$suite" ]] || fail "missing $suite"

# pytest is not in the hosted runner's system python. Prefer the system
# python's pytest module, then a pytest on PATH (VPS uv tool), else install
# the pinned release — the same pip mechanism ci.yml uses for pyyaml and
# semgrep.
if python3 -m pytest --version >/dev/null 2>&1; then
  run=(python3 -m pytest)
elif command -v pytest >/dev/null 2>&1; then
  run=(pytest)
else
  python3 -m pip install --no-input "pytest==9.1.1" \
    || fail "pytest unavailable and pip install failed"
  run=(python3 -m pytest)
fi

# pytest exit codes: 0 = all passed, 5 = none collected — both non-zero
# outcomes fail here, so a renamed/emptied suite cannot go silent-green.
"${run[@]}" -q "$suite" || fail "console-truth pytest suite failed"
ok "console-truth pytest suite green"

echo "PASS: console-truth-pytest"
