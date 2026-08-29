#!/usr/bin/env bash
# tests/p14-unstubbed-unit-verify.test.sh
#
# fleet-ops#154: P14 (`ci.yml` verify-command) runs on a hosted runner that
# does not stub VPS ExecStart paths. `systemd-analyze verify` on systemd
# 255+ fails when the ExecStart binary is missing:
#   Command /home/nish/.local/bin/agent-cron-run is not executable: No such file or directory
# That red-on-main'd CI at run 32935434973 (commit 7383611) inside
# tests/agent-cron-seat-rotation.test.sh. Unit syntax belongs in the dedicated
# `systemd-analyze` job, which stubs those paths first.
#
# This file is the class lock. A P14 test that inline-verifies a unit whose
# ExecStart first token is a VPS path is the #154 failure. Re-adding that
# call must fail this test, not wait for main to go red again.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

is_comment_or_empty() {
  local trimmed="${1#"${1%%[![:space:]]*}"}"
  [[ -z "$trimmed" || "$trimmed" == \#* ]]
}

line_has_live_verify() {
  local trimmed="${1#"${1%%[![:space:]]*}"}"
  [[ "$trimmed" =~ systemd-analyze[[:space:]]+verify ]]
}

has_live_verify() {
  local f="$1" line
  [[ -f "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    is_comment_or_empty "$line" && continue
    if line_has_live_verify "$line"; then
      return 0
    fi
  done <"$f"
  return 1
}

extract_p14_tests() {
  local ci="$1/.github/workflows/ci.yml"
  [[ -f "$ci" ]] || return 0
  grep -oE 'bash tests/[^[:space:]]+\.test\.sh' "$ci" | awk '{print $2}' | sort -u
}

execstart_first_token() {
  local unit="$1" line cmd first
  [[ -f "$unit" ]] || return 1
  line="$(grep -E '^ExecStart=' "$unit" | head -n 1)" || return 1
  [[ -n "$line" ]] || return 1
  cmd="${line#ExecStart=}"
  while [[ "$cmd" == [-+@!]* ]]; do
    cmd="${cmd:1}"
  done
  read -r first _ <<<"$cmd"
  [[ -n "$first" ]] || return 1
  printf '%s\n' "$first"
}

is_runner_safe_bin() {
  case "$1" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/lib/*|/usr/libexec/*|/lib/*|/lib64/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

collect_service_rels() {
  local f="$1"
  grep -oE 'systemd/[A-Za-z0-9_@%.\\-]+\.service' "$f" 2>/dev/null | sort -u || true
}

# fleet-ops#718: a bare path reference like `svc=$repo_root/systemd/X.service`
# or a `grep -q` on a unit file is NOT a `systemd-analyze verify` call. The
# class lock fires ONLY when a service is on a line that itself contains a
# live `systemd-analyze verify` invocation. A `seat_svc=...fleet-seat-recovery.service`
# assignment followed by a `grep -q` is a SHAPE check, not a verify, and the
# original detector false-positived on it (red-on-main: CI / P14 tests
# `tests/escalation-units-shape.test.sh verifies systemd/fleet-seat-recovery.service`
# despite the test never passing that path to `systemd-analyze verify`).
# Continuation lines (backslash-newline) collapse into a single logical line
# so `systemd-analyze verify --man=no \ \n systemd/X.service \` flags X.
logical_lines_with_live_verify() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '
    {
      buf = buf $0 "\n"
      if ($0 !~ /\\$/) {
        if (buf !~ /^[[:space:]]*#/ && buf !~ /^[[:space:]]*$/ && buf ~ /systemd-analyze[[:space:]]+verify/) {
          printf "%s", buf
        }
        buf = ""
      }
    }
  ' "$f"
}

collect_verified_service_rels() {
  local f="$1" logical
  while IFS= read -r logical; do
    [[ -n "$logical" ]] || continue
    printf '%s\n' "$logical" | grep -oE 'systemd/[A-Za-z0-9_@%.\\-]+\.service' 2>/dev/null
  done < <(logical_lines_with_live_verify "$f") | sort -u
}

# Print one finding per line. Exit 0 even when findings exist (caller counts).
scan_p14_inline_verify() {
  local root="$1"
  local testrel testfile svc_rel unit token
  while IFS= read -r testrel; do
    [[ -z "$testrel" ]] && continue
    testfile="$root/$testrel"
    [[ -f "$testfile" ]] || continue
    has_live_verify "$testfile" || continue
    glob=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      is_comment_or_empty "$line" && continue
      if [[ "$line" == *'systemd/*.service'* ]]; then
        glob=1
        break
      fi
    done <"$testfile"
    if [[ "$glob" == "1" ]]; then
      shopt -s nullglob
      for unit in "$root"/systemd/*.service; do
        token="$(execstart_first_token "$unit" || true)"
        [[ -n "$token" ]] || continue
        if ! is_runner_safe_bin "$token"; then
          printf '%s verifies %s ExecStart=%s (hosted runner has no VPS stubs)\n' \
            "$testrel" "${unit#"$root"/}" "$token"
        fi
      done
      shopt -u nullglob
      continue
    fi
    while IFS= read -r svc_rel; do
      [[ -z "$svc_rel" ]] && continue
      unit="$root/$svc_rel"
      token="$(execstart_first_token "$unit" || true)"
      [[ -n "$token" ]] || continue
      if ! is_runner_safe_bin "$token"; then
        printf '%s verifies %s ExecStart=%s (hosted runner has no VPS stubs)\n' \
          "$testrel" "$svc_rel" "$token"
      fi
    done < <(collect_verified_service_rels "$testfile")
  done < <(extract_p14_tests "$root")
}

scan_missing_stubs() {
  local root="$1"
  local ci="$root/.github/workflows/ci.yml"
  local unit token
  [[ -f "$ci" ]] || return 0
  shopt -s nullglob
  for unit in "$root"/systemd/*.service; do
    token="$(execstart_first_token "$unit" || true)"
    [[ -n "$token" ]] || continue
    is_runner_safe_bin "$token" && continue
    if ! grep -Fq -- "$token" "$ci"; then
      printf '%s ExecStart=%s is not stubbed in ci.yml unit-verify\n' \
        "${unit#"$root"/}" "$token"
    fi
  done
  shopt -u nullglob
}

write_minimal_ci() {
  local dest="$1"
  local test_rel="$2"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<EOF
name: CI
jobs:
  tests:
    name: P14 tests
    with:
      verify-command: |
        bash ${test_rel}
EOF
}

# --- 1. Drill: missing ExecStart binary makes verify fail -------------------
if command -v systemd-analyze >/dev/null 2>&1; then
  probe="$(mktemp -d -t p14-verify-probe.XXXXXX)"
  cat >"$probe/missing.service" <<'EOF'
[Unit]
Description=fleet-ops#154 missing-binary probe
[Service]
Type=oneshot
ExecStart=/home/nish/.local/bin/definitely-not-installed-154
EOF
  set +e
  probe_err="$(systemd-analyze verify --man=no "$probe/missing.service" 2>&1)"
  probe_rc=$?
  set -e
  rm -rf "$probe"
  [[ "$probe_rc" -ne 0 ]] \
    || fail "systemd-analyze verify must fail when ExecStart binary is missing, rc=$probe_rc"
  printf '%s\n' "$probe_err" | grep -q 'definitely-not-installed-154' \
    || fail "missing-binary verify must name the ExecStart path, got: $probe_err"
  printf '%s\n' "$probe_err" | grep -Eq 'not executable|No such file' \
    || fail "missing-binary verify must report the missing file, got: $probe_err"
  ok "drill: systemd-analyze verify fails on a missing VPS ExecStart binary"
else
  echo "SKIP: systemd-analyze not on PATH (drill); static lock still runs"
fi

# --- 2. Fixture: the #154 pattern must be flagged ---------------------------
scratch="$(mktemp -d -t p14-unstubbed.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

red="$scratch/red-154"
mkdir -p "$red/tests" "$red/systemd" "$red/.github/workflows"
write_minimal_ci "$red/.github/workflows/ci.yml" "tests/agent-cron-seat-rotation.test.sh"
cat >"$red/systemd/agent-cron-0509-daily-market-signal.service" <<'EOF'
[Service]
Type=oneshot
ExecStart=/home/nish/.local/bin/agent-cron-run 0509-daily-market-signal
EOF
cat >"$red/tests/agent-cron-seat-rotation.test.sh" <<'EOF'
#!/usr/bin/env bash
# re-introduction of the fleet-ops#154 inline verify
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify --man=no \
    systemd/agent-cron-0509-daily-market-signal.service >/dev/null 2>&1 \
    || fail "systemd-analyze verify failed for agent-cron units"
fi
EOF
red_findings="$(scan_p14_inline_verify "$red")"
[[ -n "$red_findings" ]] || fail "fixture red-154 must flag the inline agent-cron verify"
printf '%s\n' "$red_findings" | grep -q 'agent-cron-seat-rotation.test.sh' \
  || fail "fixture red-154 must name the P14 test, got: $red_findings"
printf '%s\n' "$red_findings" | grep -q 'agent-cron-run' \
  || fail "fixture red-154 must name the VPS ExecStart, got: $red_findings"
ok "fixture: #154 inline verify of agent-cron is flagged"

# --- 3. Fixture: comment-only verify stays quiet ----------------------------
quiet="$scratch/comment-only"
mkdir -p "$quiet/tests" "$quiet/systemd" "$quiet/.github/workflows"
write_minimal_ci "$quiet/.github/workflows/ci.yml" "tests/agent-cron-seat-rotation.test.sh"
cp "$red/systemd/agent-cron-0509-daily-market-signal.service" \
  "$quiet/systemd/agent-cron-0509-daily-market-signal.service"
cat >"$quiet/tests/agent-cron-seat-rotation.test.sh" <<'EOF'
#!/usr/bin/env bash
# --- systemd-analyze verify on the unit files -------------------------------
# Do NOT re-verify here: systemd-analyze verify false-positives on CI.
echo OK
EOF
quiet_findings="$(scan_p14_inline_verify "$quiet")"
[[ -z "$quiet_findings" ]] || fail "comment-only verify must stay quiet, got: $quiet_findings"
ok "fixture: comment-only systemd-analyze verify stays quiet"

# --- 4. Fixture: /bin/bash -c ExecStart may still be verified ---------------
safe="$scratch/bash-c-ok"
mkdir -p "$safe/tests" "$safe/systemd" "$safe/.github/workflows"
write_minimal_ci "$safe/.github/workflows/ci.yml" "tests/escalation-units-shape.test.sh"
cat >"$safe/systemd/stop-escalation.service" <<'EOF'
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'exec /home/nish/.local/bin/stop-escalation-dispatch'
EOF
cat >"$safe/tests/escalation-units-shape.test.sh" <<'EOF'
#!/usr/bin/env bash
systemd-analyze verify --man=no systemd/stop-escalation.service >/dev/null
EOF
safe_findings="$(scan_p14_inline_verify "$safe")"
[[ -z "$safe_findings" ]] || fail "/bin/bash -c verify must stay quiet, got: $safe_findings"
ok "fixture: verify of a /bin/bash -c unit stays quiet"

# --- 4b. Fixture: the fleet-ops#830 re-breakage shape is flagged ------------
# fleet-ops#830: tests/escalation-units-shape.test.sh once inline-verified
# systemd/fleet-seat-recovery.service (a VPS-only ExecStart). #617 (dd9b454)
# replaced that call with a StartLimitIntervalSec=0 grep. This fixture proves
# the detector still catches that exact re-breakage shape, so a future edit
# that re-introduces it cannot silently re-merge.
seat_red="$scratch/seat-recovery-830"
mkdir -p "$seat_red/tests" "$seat_red/systemd" "$seat_red/.github/workflows"
write_minimal_ci "$seat_red/.github/workflows/ci.yml" "tests/escalation-units-shape.test.sh"
cat >"$seat_red/systemd/fleet-seat-recovery.service" <<'EOF'
[Service]
Type=oneshot
ExecStart=/home/nish/.local/bin/fleet-seat-recovery
EOF
cat >"$seat_red/tests/escalation-units-shape.test.sh" <<'EOF'
#!/usr/bin/env bash
# re-introduction of the fleet-ops#830 inline verify on fleet-seat-recovery
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify --man=no \
    systemd/fleet-seat-recovery.service >/dev/null 2>&1 \
    || fail "systemd-analyze verify failed for fleet-seat-recovery"
fi
EOF
seat_findings="$(scan_p14_inline_verify "$seat_red")"
[[ -n "$seat_findings" ]] || fail "fixture seat-recovery-830 must flag the inline fleet-seat-recovery verify (drill regressed)"
printf '%s\n' "$seat_findings" | grep -q 'escalation-units-shape.test.sh' \
  || fail "fixture seat-recovery-830 must name the P14 test, got: $seat_findings"
printf '%s\n' "$seat_findings" | grep -q 'fleet-seat-recovery' \
  || fail "fixture seat-recovery-830 must name the VPS ExecStart, got: $seat_findings"
ok "fixture: #830 inline verify of fleet-seat-recovery is flagged"

# --- 4c. Fixture: the fleet-ops#884 SKIP block must stay in the units test -
# fleet-ops#884: hosted-CI P14 red-fails with
#   FAIL: systemd-analyze verify failed for fleet-seat-recovery.service:
#   fleet-seat-recovery.service: Command /home/nish/.local/bin/fleet-seat-recovery
#   is not executable: No such file or directory
# because the inline verify needs the VPS bin present. The shipped fix in
# tests/fleet-seat-recovery-units.test.sh step 3 SKIPs the verify when the
# bin is absent and points at the dedicated unit-verify CI job as the syntax
# gate. Pin the SKIP shape so a future edit that strips the SKIP and re-runs
# the inline verify unconditionally cannot silently re-merge (it would
# red-fail hosted CI run #N+1 instead).
units_test="$repo_root/tests/fleet-seat-recovery-units.test.sh"
[[ -f "$units_test" ]] || fail "missing $units_test"
# The SKIP block gates verify on the bin's presence; both halves must remain.
grep -Fq '/home/nish/.local/bin/fleet-seat-recovery' "$units_test" \
  || fail "fleet-seat-recovery-units.test.sh must reference the VPS bin path (gate anchor)"
grep -Fq 'SKIP' "$units_test" \
  || fail "fleet-seat-recovery-units.test.sh must contain a SKIP block (fleet-ops#884)"
grep -Fq 'unit-verify CI job' "$units_test" \
  || fail "fleet-seat-recovery-units.test.sh SKIP must name the unit-verify CI job (named-reason contract)"
# Both branches of the gate must be present (verify path AND skip path).
grep -Fq 'systemd-analyze verify --man=no' "$units_test" \
  || fail "fleet-seat-recovery-units.test.sh must still call systemd-analyze verify on the VPS path"
ok "fixture: #884 SKIP block in fleet-seat-recovery-units.test.sh is locked"

# --- 5. Live repo: agent-cron P14 test has no live verify -------------------
agent_cron="$repo_root/tests/agent-cron-seat-rotation.test.sh"
[[ -f "$agent_cron" ]] || fail "missing $agent_cron"
if has_live_verify "$agent_cron"; then
  fail "tests/agent-cron-seat-rotation.test.sh must not call systemd-analyze verify (fleet-ops#154)"
fi
ok "live: agent-cron-seat-rotation.test.sh has no live systemd-analyze verify"

# --- 6. Live repo: no P14 test repeats the #154 class -----------------------
live_findings="$(scan_p14_inline_verify "$repo_root")"
[[ -z "$live_findings" ]] || fail "P14 tests inline-verify a VPS ExecStart unit:\n$live_findings"
ok "live: no P14 test inline-verifies a VPS ExecStart unit"

# --- 7. Live repo: unit-verify stubs every VPS ExecStart --------------------
stub_findings="$(scan_missing_stubs "$repo_root")"
[[ -z "$stub_findings" ]] || fail "ci.yml unit-verify is missing stubs:\n$stub_findings"
grep -Fq '/home/nish/.local/bin/agent-cron-run' "$repo_root/.github/workflows/ci.yml" \
  || fail "ci.yml unit-verify must stub /home/nish/.local/bin/agent-cron-run"
ok "live: ci.yml stubs every VPS ExecStart including agent-cron-run"

# --- 8. This lock is actually reached from a P14 test -----------------------
# Worker App tokens cannot push .github/workflows/**, so the lock cannot be
# added to verify-command directly. ci-standards-audit.test.sh (already in
# that list) must invoke this file.
grep -Fq 'p14-unstubbed-unit-verify.test.sh' "$repo_root/tests/ci-standards-audit.test.sh" \
  || fail "tests/ci-standards-audit.test.sh must invoke p14-unstubbed-unit-verify.test.sh"
ok "lock is wired through tests/ci-standards-audit.test.sh (already in P14)"

echo "OK: p14-unstubbed-unit-verify: #154 / #884 class lock holds"
