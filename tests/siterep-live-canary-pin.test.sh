#!/usr/bin/env bash
# tests/siterep-live-canary-pin.test.sh
#
# Proves the canary pin wrapper in bin/siterep-live-canary:
#   1. Pin is enabled for hourly runs outside the daily real-E2E hour.
#   2. Pin is disabled once per UTC day at SITEREP_CANARY_DAILY_E2E_HOUR.
#   3. SITEREP_CANARY_PIN=force-real disables the pin for a one-off run.
#
# The canary script normally touches a live siterep worktree, git, and npm.
# This test keeps it hermetic by stubbing date/npm (as required) and also
# git/node so the test runs in CI without a real siterep checkout.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/siterep-live-canary"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t siterep-canary-pin.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Fake worktree: the canary only checks that $WORKTREE/.git exists.
worktree="$scratch/siterep"
mkdir -p "$worktree/.git"

# Stub directory prepended to PATH.
stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"

# date: return the hour the test asks for; pass everything else to the real date.
cat > "$stub_bin/date" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "-u +%H" ]]; then
  printf '%02d\n' "${TEST_DATE_HOUR:-0}"
else
  exec /usr/bin/date "$@"
fi
STUB
chmod +x "$stub_bin/date"

# git: the canary runs "fetch public main" and "reset --hard public/main".
# Those are not what this test is about, so make them no-ops.
cat > "$stub_bin/git" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/git"

# node: the canary only checks that node is on PATH; it never runs it.
cat > "$stub_bin/node" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/node"

# npm: record the SITEREP_CANARY_PIN value on "npm run" invocations, then
# exit 0.  "npm install" is also a no-op.  All other npm subcommands pass.
cat > "$stub_bin/npm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "run" ]]; then
  printf '%s SITEREP_CANARY_PIN=%s\n' "$*" "${SITEREP_CANARY_PIN:-}" >> "$TEST_CANARY_PIN_LOG"
fi
echo "ok"
exit 0
STUB
chmod +x "$stub_bin/npm"

export PATH="$stub_bin:$PATH"
export SITEREP_CANARY_WORKTREE="$worktree"
export SITEREP_LAYOUT_SMOKE_BASE_URL="http://canary.test"
export SITEREP_LAYOUT_SMOKE_TIMEOUT_MS="1000"
export TEST_CANARY_PIN_LOG="$scratch/pin.log"
touch "$TEST_CANARY_PIN_LOG"

run_canary() {
  # Run the canary and capture its stdout.  With the stubs above it must exit 0.
  local out
  out="$("$bin" 2>&1)" || fail "canary exited nonzero (rc=$?): $out"
  printf '%s\n' "$out"
}

# --- Case 1: default daily E2E hour (03), current hour 05 -> pin enabled ------
export TEST_DATE_HOUR=5
unset SITEREP_CANARY_PIN
unset SITEREP_CANARY_DAILY_E2E_HOUR

out="$(run_canary)"

printf '%s\n' "$out" | grep -q 'canary pin ENABLED' \
  || fail "hour 05 should enable canary pin. output:\n$out"
grep -q 'run monitor:live SITEREP_CANARY_PIN=1' "$TEST_CANARY_PIN_LOG" \
  || fail "monitor:live should see SITEREP_CANARY_PIN=1 (hour 05). log:\n$(cat "$TEST_CANARY_PIN_LOG")"
ok "hour 05 (default daily 03) keeps pin enabled"

# --- Case 2: default daily E2E hour (03), current hour 03 -> pin disabled -----
: > "$TEST_CANARY_PIN_LOG"
export TEST_DATE_HOUR=3
unset SITEREP_CANARY_PIN
unset SITEREP_CANARY_DAILY_E2E_HOUR

out="$(run_canary)"

printf '%s\n' "$out" | grep -q 'canary pin DISABLED (daily real E2E hour' \
  || fail "hour 03 (default daily E2E) should disable canary pin. output:\n$out"
if grep -q 'run monitor:live SITEREP_CANARY_PIN=1' "$TEST_CANARY_PIN_LOG"; then
  fail "monitor:live should NOT see SITEREP_CANARY_PIN=1 (hour 03). log:\n$(cat "$TEST_CANARY_PIN_LOG")"
fi
grep -q 'run monitor:live SITEREP_CANARY_PIN=' "$TEST_CANARY_PIN_LOG" \
  || fail "monitor:live should record an empty SITEREP_CANARY_PIN. log:\n$(cat "$TEST_CANARY_PIN_LOG")"
ok "hour 03 (default daily E2E) disables pin"

# --- Case 3: SITEREP_CANARY_PIN=force-real -> pin disabled --------------------
: > "$TEST_CANARY_PIN_LOG"
export TEST_DATE_HOUR=5
export SITEREP_CANARY_PIN=force-real
unset SITEREP_CANARY_DAILY_E2E_HOUR

out="$(run_canary)"

printf '%s\n' "$out" | grep -q 'canary pin DISABLED via SITEREP_CANARY_PIN=force-real' \
  || fail "SITEREP_CANARY_PIN=force-real should disable canary pin. output:\n$out"
if grep -q 'run monitor:live SITEREP_CANARY_PIN=1' "$TEST_CANARY_PIN_LOG"; then
  fail "force-real: monitor:live should NOT see SITEREP_CANARY_PIN=1. log:\n$(cat "$TEST_CANARY_PIN_LOG")"
fi
grep -q 'run monitor:live SITEREP_CANARY_PIN=' "$TEST_CANARY_PIN_LOG" \
  || fail "force-real: monitor:live should record an empty SITEREP_CANARY_PIN. log:\n$(cat "$TEST_CANARY_PIN_LOG")"
ok "SITEREP_CANARY_PIN=force-real disables pin"

# --- Case 4: SITEREP_CANARY_DAILY_E2E_HOUR=08 with leading zero, current 08 ----
# This exercises the base-10 arithmetic guard: 08 and 09 would otherwise be
# mis-parsed as invalid octal by bash.
: > "$TEST_CANARY_PIN_LOG"
export TEST_DATE_HOUR=8
export SITEREP_CANARY_DAILY_E2E_HOUR=08
unset SITEREP_CANARY_PIN

out="$(run_canary)"

printf '%s\n' "$out" | grep -q 'canary pin DISABLED (daily real E2E hour' \
  || fail "hour 08 (daily 08) should disable canary pin. output:\n$out"
if grep -q 'run monitor:live SITEREP_CANARY_PIN=1' "$TEST_CANARY_PIN_LOG"; then
  fail "hour 08 (daily 08) should NOT see SITEREP_CANARY_PIN=1. log:\n$(cat "$TEST_CANARY_PIN_LOG")"
fi
grep -q 'run monitor:live SITEREP_CANARY_PIN=' "$TEST_CANARY_PIN_LOG" \
  || fail "hour 08 (daily 08) should record an empty SITEREP_CANARY_PIN. log:\n$(cat "$TEST_CANARY_PIN_LOG")"
ok "hour 08 (custom daily E2E 08) disables pin with leading-zero base-10 parse"

# --- Case 5: SITEREP_CANARY_DAILY_E2E_HOUR=08, current 10 -> pin enabled ------
: > "$TEST_CANARY_PIN_LOG"
export TEST_DATE_HOUR=10
export SITEREP_CANARY_DAILY_E2E_HOUR=08
unset SITEREP_CANARY_PIN

out="$(run_canary)"

printf '%s\n' "$out" | grep -q 'canary pin ENABLED' \
  || fail "hour 10 (daily 08) should enable canary pin. output:\n$out"
grep -q 'run monitor:live SITEREP_CANARY_PIN=1' "$TEST_CANARY_PIN_LOG" \
  || fail "hour 10 (daily 08) should see SITEREP_CANARY_PIN=1. log:\n$(cat "$TEST_CANARY_PIN_LOG")"
ok "hour 10 (custom daily 08) keeps pin enabled"
