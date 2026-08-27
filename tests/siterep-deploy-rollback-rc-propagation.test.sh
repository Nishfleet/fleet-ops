#!/usr/bin/env bash
# tests/siterep-deploy-rollback-rc-propagation.test.sh
#
# fleet-ops#653: bin/siterep-deploy-rollback logged
# `FAILED: wrangler rollback exit 0` and `FAILED: post-rollback canary exit 0`
# on every real failure. Cause: `if ! cmd; then rc=$?` — `!` inverts the
# status so the then-branch always sees 0 (same class as fleet-ops#486,
# the heartbeat-wrapper inversion).
#
# The script's WORKTREE_DIR / CREDS_FILE / VERIFY / ROLLBACK_MSG are
# hard-coded at the top, so we copy the script to a scratch dir and patch
# them in. We never touch the real one and never run against the real
# Cloudflare API.
#
# Class lock:
#   A. A stub wrangler that exits 7 must make the script log
#      FAILED: wrangler rollback exit 7 (not 0) and exit 7 (not 0/1).
#   B. A stub wrangler that exits 0 + a stub verify that exits 11 must
#      log FAILED: post-rollback canary exit 11 and exit 11.
#   C. Both stubs exit 0: the script must reach the final log and exit 0.
#      (The gh incident filing is bypassed — this issue owns the rc
#      propagation, not the gh transport. Stub gh to a no-op so the
#      success path is exercised without contacting the real API.)
#   D. Source gate: bin/siterep-deploy-rollback must not capture $?
#      immediately after `if !`. A planted fixture of that shape MUST be
#      rejected (fleet-ops#366: the guard has to fire, not just exist).
# Nested under tests/seat-lib.test.sh because workers cannot add a
# .github/workflows/ci.yml line.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/bin/siterep-deploy-rollback"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$script" ]] || fail "not executable: $script"

scratch="$(mktemp -d -t sdr-rc-prop.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Build a copy of the script with the hard-coded paths pointed at our
# fixtures. We never edit the real file from this test.
patched="$scratch/siterep-deploy-rollback"
sed \
  -e "s|^WORKTREE_DIR=.*|WORKTREE_DIR=\"$scratch/deploy-siterep\"|" \
  -e "s|^CREDS_FILE=.*|CREDS_FILE=\"$scratch/creds.env\"|" \
  -e "s|^VERIFY=.*|VERIFY=\"$scratch/verify\"|" \
  -e "s|^ROLLBACK_MSG=.*|ROLLBACK_MSG=\"rollback-fixture\"|" \
  -e "s|^REPO_SLUG=.*|REPO_SLUG=\"Nishfleet/never-used\"|" \
  "$script" >"$patched"
chmod +x "$patched"

# A fake worktree that looks like a git checkout (the script just checks
# for .git under WORKTREE_DIR). We never actually run wrangler here.
fake_wt="$scratch/deploy-siterep"
mkdir -p "$fake_wt/.git"
touch "$fake_wt/package.json"

# A fake credentials file (the script sources it with set -a; values
# never printed, so the contents only need to be present and parseable).
printf 'CF_API_TOKEN=fake\nCF_ACCOUNT_ID=fake\n' >"$scratch/creds.env"

# A fake verify script — its real exit code is the test input.
cat >"$scratch/verify" <<'SH'
#!/bin/sh
exit "$VERIFY_RC"
SH
chmod +x "$scratch/verify"

# Stub gh so the success path does not contact the real API. The script
# only ever calls `gh issue create`; accept any args and return 0.
ghbin="$scratch/ghbin"
mkdir -p "$ghbin"
cat >"$ghbin/gh" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$ghbin/gh"

# Stub npx — calls the wrangler stub in the same scratch dir. The script's
# `npx wrangler rollback ...` then resolves our wrangler instead of the
# real CLI. We pre-pend $scratch to PATH so this stub is found first.
cat >"$scratch/npx" <<'SH'
#!/bin/sh
# Strip the literal "wrangler" arg that the script always passes first.
# Anything else (rollback, -y, -m, message) is forwarded unchanged.
if [ "$1" = "wrangler" ]; then
  shift
fi
exec "$WRANGLER_BIN" "$@"
SH
chmod +x "$scratch/npx"

# Stub wrangler — its real exit code is the test input. We swap a
# different file in for the wrangler command the script calls.
write_wrangler_stub() {
  local rc="$1"
  cat >"$scratch/wrangler" <<SH
#!/bin/sh
exit $rc
SH
  chmod +x "$scratch/wrangler"
}

# Run the script with the stubbed npx → wrangler and verify scripts.
# PATH must put our stubs before real npx/wrangler, and before real gh.
run_script() {
  local wrangler_rc="$1" verify_rc="$2"
  write_wrangler_stub "$wrangler_rc"
  printf '#!/bin/sh\nexit %s\n' "$verify_rc" >"$scratch/verify"
  chmod +x "$scratch/verify"
  WRANGLER_BIN="$scratch/wrangler" \
    env "PATH=$scratch:$ghbin:$PATH" \
    "$patched" 2>&1
}

# --- A. wrangler failure with rc=7 must propagate ----------------------------
set +e
out="$(run_script 7 0 2>&1)"
rc=$?
set -e
[[ "$rc" == "7" ]] || fail "A: script must exit 7 when wrangler stub exits 7, got $rc ($out)"
printf '%s\n' "$out" | grep -q 'FAILED: wrangler rollback exit 7' \
  || fail "A: log must say wrangler rollback exit 7, not 0. got: $out"
printf '%s\n' "$out" | grep -q 'FAILED: wrangler rollback exit 0' \
  && fail "A: inverted capture still logs FAILED (... exit 0): $out"
ok "A: wrangler exit 7 -> log exit 7, script exit 7"

# --- B. wrangler ok, verify failure with rc=11 must propagate ----------------
set +e
out="$(run_script 0 11 2>&1)"
rc=$?
set -e
[[ "$rc" == "11" ]] || fail "B: script must exit 11 when verify stub exits 11, got $rc ($out)"
printf '%s\n' "$out" | grep -q 'FAILED: post-rollback canary exit 11' \
  || fail "B: log must say post-rollback canary exit 11, not 0. got: $out"
printf '%s\n' "$out" | grep -q 'FAILED: post-rollback canary exit 0' \
  && fail "B: inverted capture still logs FAILED (... exit 0): $out"
ok "B: verify exit 11 -> log exit 11, script exit 11"

# --- C. both stubs ok: script reaches the final log and exits 0 --------------
set +e
out="$(run_script 0 0 2>&1)"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "C: script must exit 0 when both stubs exit 0, got $rc ($out)"
printf '%s\n' "$out" | grep -q 'rollback complete; incident filed' \
  || fail "C: success path must reach the final log. got: $out"
printf '%s\n' "$out" | grep -q 'FAILED' \
  && fail "C: success path must not log FAILED: $out"
ok "C: both stubs exit 0 -> final log, script exit 0"

# --- D. source gate + drill (fleet-ops#366) ---------------------------------
scan_inverted() {
  python3 - "$@" <<'PY'
import re, sys
from pathlib import Path

def has_inverted_capture(path: Path) -> bool:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return False
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        if not re.match(r"if[ \t]+!.+then[ \t]*$", stripped):
            continue
        j = i + 1
        while j < len(lines) and (not lines[j].strip() or lines[j].lstrip().startswith("#")):
            j += 1
        if j >= len(lines):
            continue
        nxt = lines[j].lstrip()
        if re.match(r"\w+=\$\?[ \t]*$", nxt):
            return True
    return False

hits = []
for arg in sys.argv[1:]:
    path = Path(arg)
    if path.is_dir():
        for child in sorted(path.rglob("*")):
            if child.is_file() and has_inverted_capture(child):
                hits.append(str(child))
    elif path.is_file() and has_inverted_capture(path):
        hits.append(str(path))
if hits:
    print("\n".join(hits))
    sys.exit(1)
sys.exit(0)
PY
}

set +e
scan_out="$(scan_inverted "$script" 2>&1)"
scan_rc=$?
set -e
[[ "$scan_rc" == "0" ]] || fail "D: inverted if-! / rc=\$? capture still in siterep-deploy-rollback: $scan_out"
ok "D: siterep-deploy-rollback has no if-! then rc=\$? capture"

drill="$scratch/drill"
mkdir -p "$drill"
cat >"$drill/bad.sh" <<'SH'
#!/usr/bin/env bash
if ! "$WRAP"; then
    rc=$?
    echo "FAILED (rc=$rc)"
fi
SH
set +e
drill_out="$(scan_inverted "$drill" 2>&1)"
drill_rc=$?
set -e
[[ "$drill_rc" != "0" ]] || fail "D: drill planted if-! then rc=\$? and the scanner stayed quiet"
ok "D: drill: planted inverted capture is rejected"

# Nested CI host (workers cannot add a ci.yml line).
grep -Fq 'bash "$here/siterep-deploy-rollback-rc-propagation.test.sh"' "$here/seat-lib.test.sh" \
  || fail "seat-lib.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "nested under seat-lib.test.sh"

echo "ALL OK"
