#!/usr/bin/env bash
# tests/systemd-analyze-slices.test.sh
#
# fleet-ops#92: a malformed systemd/*.slice must fail CI.
#
# The dedicated unit-verify job in .github/workflows/ci.yml still loops
# only systemd/*.service and systemd/*.timer. Expanding that glob needs a
# Workflows-permission token (nishfleet-worker cannot push
# .github/workflows/**). This file is the class lock that can land without
# that token.
#
# Default `systemd-analyze verify` (no --recursive-errors) exits 0 even
# when the unit has unknown keys or a missing section. --recursive-errors=no
# fails on warnings in the specified unit only, which is the check that
# actually catches a bad slice.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# Worker App tokens cannot add a workflow step. system-dropins-shape.test.sh
# is already in the P14 verify-command list, so this lock rides along there.
grep -Fq 'systemd-analyze-slices.test.sh' "$repo_root/tests/system-dropins-shape.test.sh" \
  || fail "tests/system-dropins-shape.test.sh must invoke systemd-analyze-slices.test.sh"
ok "lock is wired through tests/system-dropins-shape.test.sh (already in P14)"

shopt -s nullglob
slices=("$repo_root"/systemd/*.slice)
shopt -u nullglob
[[ ${#slices[@]} -gt 0 ]] || fail "no systemd/*.slice files found"

if ! command -v systemd-analyze >/dev/null 2>&1; then
  echo "SKIP: systemd-analyze not on PATH"
  echo "OK: systemd-analyze-slices: wiring locked; live verify skipped"
  exit 0
fi

# Precondition: default verify is a silent miss on unknown keys. If a
# future systemd starts failing here, drop --recursive-errors=no below.
probe="$(mktemp -d -t slice-verify-probe.XXXXXX)"
trap 'rm -rf "$probe"' EXIT
printf '[Slice]\nNotARealKey=1\n' >"$probe/bad.slice"
set +e
systemd-analyze verify --man=no "$probe/bad.slice" >/dev/null 2>&1
default_rc=$?
set -e
[[ "$default_rc" -eq 0 ]] \
  || fail "precondition: default verify must exit 0 on an unknown slice key (got rc=$default_rc). If systemd now fails closed, drop --recursive-errors=no from this test."
ok "precondition: default verify ignores unknown slice keys (rc=0)"

# Negative fixture: --recursive-errors=no must reject the same file.
set +e
bad_out="$(systemd-analyze verify --man=no --recursive-errors=no "$probe/bad.slice" 2>&1)"
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]] \
  || fail "malformed slice must fail verify --recursive-errors=no, rc=$bad_rc ($bad_out)"
printf '%s\n' "$bad_out" | grep -q "Unknown key name 'NotARealKey'" \
  || fail "malformed-slice verify must name NotARealKey, got: $bad_out"
ok "drill: unknown slice key fails verify --recursive-errors=no"

# Live repo slices must load clean.
for f in "${slices[@]}"; do
  set +e
  out="$(systemd-analyze verify --man=no --recursive-errors=no "$f" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || fail "systemd-analyze verify failed for $f: $out"
  ok "systemd-analyze verify accepts ${f#"$repo_root"/}"
done

echo "OK: systemd-analyze-slices: malformed slice fails; live slices pass"
