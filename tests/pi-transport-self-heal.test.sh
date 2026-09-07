#!/usr/bin/env bash
# tests/pi-transport-self-heal.test.sh
#
# fleet-ops#3237: regression test for the pi transport self-heal wrapper.
#
# The 2026-09-03 incident starved the fleet for 33h after a worker clobbered
# ~/.local/bin/pi with a 0-byte root-owned file. The pi-transport-check probe
# caught the fault but could not repair it because the escalation path itself
# runs pi. The self-heal wrapper on the existing pi-transport-check unit fixes
# that: it calls the probe before and after, heals via npm rebuild
# (npm re-creates the bin symlink — no hand-written symlink logic), falls back
# to npm install at the pinned version, and only exits 1 if the package itself
# is broken.
#
# This test runs entirely offline with stubbed npm / python3 / pi-transport-check
# in a scratch directory. It proves the three outcomes:
#   1. clobbered bin -> npm rebuild succeeds -> PI-TRANSPORT-HEALED via npm rebuild
#   2. clobbered bin -> npm rebuild fails, npm install@pinned succeeds -> HEALED
#   3. clobbered bin -> both npm rebuild and install fail -> exit 1 (escalation)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/bin/pi-transport-self-heal"
dropin="$repo_root/systemd/pi-transport-check.service.d/20-self-heal.conf"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$script" ]] || fail "missing executable: $script"
[[ -f "$dropin" ]] || fail "missing drop-in: $dropin"

# --- shape: files are MANIFESTed and wired on the EXISTING unit ---------------
grep -Fxq "bin/pi-transport-self-heal /home/nish/.local/bin/pi-transport-self-heal" "$manifest" \
  || fail "MANIFEST missing bin/pi-transport-self-heal"
grep -Fxq "systemd/pi-transport-check.service.d/20-self-heal.conf /home/nish/.config/systemd/user/pi-transport-check.service.d/20-self-heal.conf" "$manifest" \
  || fail "MANIFEST missing 20-self-heal drop-in"
ok "self-heal script and drop-in are present and MANIFESTed"

grep -q '^\[Service\]$' "$dropin" || fail "drop-in must have [Service]"
grep -q '^ExecStart=$' "$dropin" || fail "drop-in must reset the base ExecStart"
grep -q '^ExecStart=/home/nish/.local/bin/pi-transport-self-heal$' "$dropin" \
  || fail "drop-in must set ExecStart to the self-heal wrapper on the existing unit"
ok "self-heal is wired as ExecStart on the existing pi-transport-check unit (no new unit)"

grep -q 'PI-TRANSPORT-OK (no heal needed)' "$script" \
  || fail "script must short-circuit when the probe is already healthy"
grep -q 'PI-TRANSPORT-HEALED' "$script" || fail "script must report healed"
grep -q 'npm rebuild -g' "$script" || fail "script must use npm rebuild"
grep -q 'npm install -g' "$script" || fail "script must use npm install fallback"
grep -q 'pi-bin-clobbered-' "$script" || fail "script must back up the clobbered bin"
grep -q 'run_probe' "$script" || fail "script must re-run the probe after heal"
if grep -qE '^[^#]*(\bln -s|\bln -sf)' "$script"; then
  fail "script must not hand-write a symlink (use npm re-link)"
fi
ok "script uses npm re-link, re-runs the probe, and backs up the clobbered bin"

# --- functional: offline self-heal drill with stubbed npm/python/probe -------
scratch="$(mktemp -d -t pi-transport-self-heal.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

mkdir -p "$scratch/bin" "$scratch/state" "$scratch/seats"

export PI_BIN="$scratch/pi"
export PI_TRANSPORT_CHECK="$scratch/bin/pi-transport-check"
export PI_TRANSPORT_HEAL_STATE="$scratch/state"
export SEAT_LEDGER_DIR="$scratch/seats"
export FAKE_NPM_CLI_TARGET="$scratch/cli.js"
export FAKE_NPM_REBUILD_FAIL=0
export FAKE_NPM_INSTALL_FAIL=0
export PATH="$scratch/bin:$PATH"

# fake cli.js: correct shebang and >300 bytes
{
  printf '#!/usr/bin/env node\n'
  for _ in {1..20}; do
    printf '// padding to exceed 300 bytes 1234567890123456789012345678901234567890\n'
  done
} >"$FAKE_NPM_CLI_TARGET"
size="$(stat -c %s "$FAKE_NPM_CLI_TARGET")"
(( size >= 300 )) || fail "fake cli.js is only $size bytes, need >= 300"

# fake npm: rebuild or install re-creates the $PI_BIN symlink to $FAKE_NPM_CLI_TARGET
cat >"$scratch/bin/npm" <<'FAKE_NPM'
#!/usr/bin/env bash
set -eu
PI_BIN="${PI_BIN:?}"
target="${FAKE_NPM_CLI_TARGET:?}"
cmd="${1:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|@*) shift ;;
    *) shift ;;
  esac
done
case "$cmd" in
  rebuild)
    if [[ "${FAKE_NPM_REBUILD_FAIL:-0}" == "1" ]]; then
      echo "fake npm: rebuild fails" >&2
      exit 1
    fi
    rm -f "$PI_BIN"
    ln -s "$target" "$PI_BIN"
    ;;
  install)
    if [[ "${FAKE_NPM_INSTALL_FAIL:-0}" == "1" ]]; then
      echo "fake npm: install fails" >&2
      exit 1
    fi
    rm -f "$PI_BIN"
    ln -s "$target" "$PI_BIN"
    ;;
  *)
    echo "fake npm: unknown command $cmd" >&2
    exit 1
    ;;
esac
FAKE_NPM
chmod +x "$scratch/bin/npm"

# fake python3: the self-heal reads the pinned version from the installed
# package.json. We stub it to return a fixed version without touching the
# real ~/.local tree.
cat >"$scratch/bin/python3" <<'FAKE_PY'
#!/usr/bin/env bash
# Ignore the -c script and echo the pinned version the self-heal expects.
echo '0.84.4'
FAKE_PY
chmod +x "$scratch/bin/python3"

# fake pi-transport-check probe: green only when $PI_BIN is a symlink to the
# fake cli.js. This mirrors the real probe's purpose without needing node.
cat >"$PI_TRANSPORT_CHECK" <<'FAKE_PROBE'
#!/usr/bin/env bash
set -eu
PI_BIN="${PI_BIN:?}"
target="${FAKE_NPM_CLI_TARGET:?}"
if [[ -L "$PI_BIN" ]] && [[ "$(readlink -f "$PI_BIN")" == "$(readlink -f "$target")" ]]; then
  sz=$(stat -c %s "$target")
  echo "PI-TRANSPORT-OK size=$sz version=0.84.4"
  exit 0
fi
echo "PI-TRANSPORT-CORRUPT: PI_BIN is not a symlink to $target" >&2
exit 1
FAKE_PROBE
chmod +x "$PI_TRANSPORT_CHECK"

# clobber the bin (0-byte regular file, same shape as the incident)
: >"$PI_BIN"

# 1. npm rebuild succeeds
out=$(bash "$script" 2>&1) || fail "self-heal failed on the rebuild-success path: $out"
printf '%s\n' "$out"
grep -q 'PI-TRANSPORT-HEALED via npm rebuild' <<<"$out" \
  || fail "expected HEALED via npm rebuild; got: $out"
[[ -L "$PI_BIN" ]] || fail "PI_BIN is not a symlink after rebuild heal"
[[ "$(readlink -f "$PI_BIN")" == "$(readlink -f "$FAKE_NPM_CLI_TARGET")" ]] \
  || fail "PI_BIN symlink points to the wrong target"
backed_up=$(find "$PI_TRANSPORT_HEAL_STATE" -maxdepth 1 -type f -name 'pi-bin-clobbered-*' -print -quit)
[[ -n "$backed_up" ]] \
  || fail "clobbered artifact was not backed up to $PI_TRANSPORT_HEAL_STATE"
ok "rebuild path: clobbered bin backed up, symlink restored, probe re-runs green"

# 2. npm rebuild fails, npm install@pinned succeeds
rm -f "$PI_BIN" && : >"$PI_BIN"
export FAKE_NPM_REBUILD_FAIL=1
out=$(bash "$script" 2>&1) || fail "self-heal failed on the install-fallback path: $out"
printf '%s\n' "$out"
grep -q 'PI-TRANSPORT-HEALED via npm install@0.84.4' <<<"$out" \
  || fail "expected HEALED via npm install@0.84.4; got: $out"
[[ -L "$PI_BIN" ]] || fail "PI_BIN is not a symlink after install fallback"
[[ "$(readlink -f "$PI_BIN")" == "$(readlink -f "$FAKE_NPM_CLI_TARGET")" ]] \
  || fail "PI_BIN symlink points to the wrong target after install fallback"
ok "install fallback path: npm rebuild failure falls back to npm install@pinned and heals"

# 3. both fail -> only escalate (exit 1)
rm -f "$PI_BIN" && : >"$PI_BIN"
export FAKE_NPM_INSTALL_FAIL=1
if out=$(bash "$script" 2>&1); then
  fail "expected exit 1 when package itself is broken; got: $out"
fi
printf '%s\n' "$out"
grep -q 'PI-TRANSPORT-CORRUPT: self-heal failed' <<<"$out" \
  || fail "expected unrecoverable message; got: $out"
[[ ! -L "$PI_BIN" ]] || fail "PI_BIN should still be clobbered when self-heal gives up"
ok "escalation path: exits 1 and reports unrecoverable when package itself is broken"

ok "pi-transport-self-heal.test.sh: all paths green"
