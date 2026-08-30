#!/usr/bin/env bash
# tests/sgscan.test.sh
#
# Regression tests for the sgscan semgrep wrapper (fleet-ops#796).
# Uses a fake `semgrep` so the suite is fast and deterministic; the real
# semgrep binary is only required to exist on the host that runs CI.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/sgscan"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t sgscan-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT

make_repo() {
    local d="$1"
    git init -q -b main "$d"
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    printf 'hello\n' >"$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit -qm baseline
    git -C "$d" update-ref refs/remotes/origin/HEAD HEAD
}

fake_bin="$scratch/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/semgrep" <<'FAKE'
#!/usr/bin/env bash
# Fake semgrep for sgscan regression tests.
# Behaviour is driven by environment variables:
#   FAKE_SGSCAN_EXIT      exit code (default 0)
#   FAKE_SGSCAN_JSON      JSON to write to stdout
#   FAKE_SGSCAN_ARGS_FILE file to append the received arguments to

exit_code="${FAKE_SGSCAN_EXIT:-0}"
if [ -n "${FAKE_SGSCAN_JSON+set}" ]; then
  json="${FAKE_SGSCAN_JSON}"
else
  json='{"version":"1.172.0","results":[],"errors":[],"paths":{"scanned":[]},"time":{}}'
fi

if [[ -n "${FAKE_SGSCAN_ARGS_FILE:-}" ]]; then
    printf '%s\n' "$*" >> "$FAKE_SGSCAN_ARGS_FILE"
fi

printf '%s' "$json"
exit "$exit_code"
FAKE
chmod +x "$fake_bin/semgrep"

# --- 1. --help exits 0 and prints usage ------------------------------------
set +e
out=$("$bin" --help 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "--help must exit 0, got $rc: $out"
printf '%s\n' "$out" | grep -q 'Usage:' || fail "--help must print usage: $out"
ok "--help exits 0 and prints usage"

# --- 2. unknown flags exit 7 and do not crash with JSONDecodeError ----------
make_repo "$scratch/repo"
cd "$scratch/repo"
set +e
out=$("$bin" --diff origin/main...origin/main 2>&1)
rc=$?
set -e
[[ "$rc" == "7" ]] || fail "unknown flag must exit 7, got $rc: $out"
if printf '%s\n' "$out" | grep -qi 'JSONDecodeError'; then
    fail "unknown flag must not produce JSONDecodeError: $out"
fi
ok "unknown flag exits 7 without JSONDecodeError"

# --- 3. bare sgscan in a no-diff repo uses --baseline-commit and exits 0 ----
make_repo "$scratch/repo3"
cd "$scratch/repo3"
args_file="$scratch/args3"
set +e
PATH="$fake_bin:$PATH" FAKE_SGSCAN_ARGS_FILE="$args_file" \
  out=$(PATH="$fake_bin:$PATH" FAKE_SGSCAN_ARGS_FILE="$args_file" "$bin" 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "no-diff clean repo must exit 0, got $rc: $out"
printf '%s\n' "$out" | grep -q 'No new security findings\.' \
  || fail "must report no findings: $out"
grep -q -- '--baseline-commit' "$args_file" \
  || fail "must pass --baseline-commit in a no-diff repo (args: $(cat "$args_file"))"
ok "no-diff repo exits 0 and passes --baseline-commit"

# --- 4. ERROR finding maps to exit 2 and prints the finding -----------------
make_repo "$scratch/repo4"
cd "$scratch/repo4"
printf 'x\n' >> "$scratch/repo4/README.md"
git -C "$scratch/repo4" add README.md
git -C "$scratch/repo4" commit -qm feature
set +e
PATH="$fake_bin:$PATH" FAKE_SGSCAN_JSON='{"version":"1.172.0","results":[{"check_id":"python.lang.security.audit.eval-detected","path":"app.py","start":{"line":1},"extra":{"severity":"ERROR","message":"eval is dangerous"}}],"errors":[],"paths":{"scanned":["app.py"]},"time":{}}' \
  out=$(PATH="$fake_bin:$PATH" FAKE_SGSCAN_JSON='{"version":"1.172.0","results":[{"check_id":"python.lang.security.audit.eval-detected","path":"app.py","start":{"line":1},"extra":{"severity":"ERROR","message":"eval is dangerous"}}],"errors":[],"paths":{"scanned":["app.py"]},"time":{}}' "$bin" 2>&1)
rc=$?
set -e
[[ "$rc" == "2" ]] || fail "ERROR finding must exit 2, got $rc: $out"
printf '%s\n' "$out" | grep -q '\[ERROR\]' || fail "must print [ERROR] finding: $out"
ok "ERROR finding exits 2"

# --- 5. WARNING finding with --json outputs JSON and exits 1 ----------------
make_repo "$scratch/repo5"
cd "$scratch/repo5"
printf 'x\n' >> "$scratch/repo5/README.md"
git -C "$scratch/repo5" add README.md
git -C "$scratch/repo5" commit -qm feature
set +e
PATH="$fake_bin:$PATH" FAKE_SGSCAN_JSON='{"version":"1.172.0","results":[{"check_id":"python.lang.security.audit.hardcoded.credentials","path":"config.py","start":{"line":2},"extra":{"severity":"WARNING","message":"possible hardcoded credential"}}],"errors":[],"paths":{"scanned":["config.py"]},"time":{}}' \
  out=$(PATH="$fake_bin:$PATH" FAKE_SGSCAN_JSON='{"version":"1.172.0","results":[{"check_id":"python.lang.security.audit.hardcoded.credentials","path":"config.py","start":{"line":2},"extra":{"severity":"WARNING","message":"possible hardcoded credential"}}],"errors":[],"paths":{"scanned":["config.py"]},"time":{}}' "$bin" --json 2>/dev/null)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "WARNING finding with --json must exit 1, got $rc: $out"
if ! printf '%s\n' "$out" | python3 -m json.tool >/dev/null 2>&1; then
    fail "--json output must be valid JSON: $out"
fi
printf '%s\n' "$out" | grep -q '"severity"' || fail "JSON output must contain findings: $out"
ok "WARNING --json exits 1 and emits valid JSON"

# --- 6. semgrep fatal (exit 2) maps to wrapper exit 3, not finding exit 2 ----
make_repo "$scratch/repo6"
cd "$scratch/repo6"
set +e
PATH="$fake_bin:$PATH" FAKE_SGSCAN_EXIT=2 FAKE_SGSCAN_JSON='' \
  out=$(PATH="$fake_bin:$PATH" FAKE_SGSCAN_EXIT=2 FAKE_SGSCAN_JSON='' "$bin" 2>&1)
rc=$?
set -e
[[ "$rc" == "3" ]] || fail "semgrep fatal must exit 3, got $rc: $out"
printf '%s\n' "$out" | grep -qi 'semgrep failed' || fail "must report semgrep failure: $out"
ok "semgrep fatal exit 2 maps to wrapper exit 3"

# --- 7. invalid JSON from semgrep maps to wrapper exit 3 --------------------
make_repo "$scratch/repo7"
cd "$scratch/repo7"
set +e
PATH="$fake_bin:$PATH" FAKE_SGSCAN_JSON='this is not json' \
  out=$(PATH="$fake_bin:$PATH" FAKE_SGSCAN_JSON='this is not json' "$bin" 2>&1)
rc=$?
set -e
[[ "$rc" == "3" ]] || fail "invalid JSON must exit 3, got $rc: $out"
printf '%s\n' "$out" | grep -qi 'could not parse semgrep output' || fail "must report parse failure: $out"
ok "invalid semgrep JSON maps to wrapper exit 3"

echo "ALL PASS"
