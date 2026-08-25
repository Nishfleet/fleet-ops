#!/usr/bin/env bash
# tests/oomd-drill.test.sh
#
# fleet-ops#62: lock the oomd drill's shape and --check path. Does NOT drive
# the memory hog — that is a live operator command (bin/oomd-drill) and the
# 2026-08-26 01:24 IST proof is already recorded on the worker slice.
#
# What it proves:
#   1. Drill slice / hog / script / MANIFEST entries exist with the keys
#      that keep the hog bounded and scoped away from lifelines.
#   2. Production worker slice stays kill @ 80% (measurement-derived).
#   3. --check succeeds against a fake systemd (CI has no systemd-oomd).
#   4. --check fails when oomd is inactive.
#   5. systemd-analyze verify accepts the hog unit (when the tool exists).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

drill="$repo_root/bin/oomd-drill"
slice="$repo_root/systemd/oomd-drill.slice"
hog="$repo_root/systemd/oomd-drill-hog.service"
manifest="$repo_root/MANIFEST"
worker_slice=$(printf '%s\n' "$repo_root"/systemd/app-pi*issue.slice)

[[ -x "$drill" ]] || fail "not executable: $drill"
[[ -f "$slice" ]] || fail "missing: $slice"
[[ -f "$hog" ]] || fail "missing: $hog"
[[ -f "$worker_slice" ]] || fail "missing worker slice: $worker_slice"
bash -n "$drill" || fail "oomd-drill: bash syntax error"

# 1. Drill slice: same kill mechanism as production, low trip, hard bound.
grep -q '^\[Slice\]$' "$slice" || fail "oomd-drill.slice: missing [Slice]"
grep -q '^ManagedOOMMemoryPressure=kill$' "$slice" \
  || fail "oomd-drill.slice: ManagedOOMMemoryPressure=kill"
grep -q '^ManagedOOMMemoryPressureLimit=5%$' "$slice" \
  || fail "oomd-drill.slice: Limit must be 5% (drill trip, not production 80%)"
grep -q '^MemoryHigh=128M$' "$slice" || fail "oomd-drill.slice: MemoryHigh=128M"
grep -q '^MemoryMax=1G$' "$slice" || fail "oomd-drill.slice: MemoryMax=1G (hog bound)"
grep -q '^MemorySwapMax=0$' "$slice" || fail "oomd-drill.slice: MemorySwapMax=0"
if grep -q '^ManagedOOMSwap=' "$slice"; then
  fail "oomd-drill.slice must not set ManagedOOMSwap"
fi
ok "drill slice is kill@5% with MemoryMax=1G"

# 2. Hog: throwaway, inside the drill slice, RuntimeMaxSec backstop, no [Install].
grep -q '^Slice=oomd-drill.slice$' "$hog" || fail "hog must set Slice=oomd-drill.slice"
grep -q '^RuntimeMaxSec=180$' "$hog" || fail "hog must set RuntimeMaxSec=180"
grep -q '^ExecStart=/usr/bin/python3 ' "$hog" || fail "hog ExecStart must be /usr/bin/python3"
if grep -q '^\[Install\]$' "$hog"; then
  fail "hog must not have [Install] (never auto-starts)"
fi
ok "hog is a throwaway python allocator under oomd-drill.slice"

# 3. Production worker slice stays the measurement-derived 80% kill.
grep -q '^ManagedOOMMemoryPressure=kill$' "$worker_slice" \
  || fail "app-pi-issue.slice: ManagedOOMMemoryPressure=kill"
grep -q '^ManagedOOMMemoryPressureLimit=80%$' "$worker_slice" \
  || fail "app-pi-issue.slice: Limit must stay 80%"
if grep -q '^MemoryMax=' "$worker_slice"; then
  fail "app-pi-issue.slice must not set MemoryMax (bounds live on pi-issue@.service)"
fi
ok "worker slice is kill@80% with no slice MemoryMax"

# 4. MANIFEST installs the drill as user-scope copies, not /etc.
grep -Fxq "systemd/oomd-drill.slice /home/nish/.config/systemd/user/oomd-drill.slice" "$manifest" \
  || fail "MANIFEST missing oomd-drill.slice"
grep -Fxq "systemd/oomd-drill-hog.service /home/nish/.config/systemd/user/oomd-drill-hog.service" "$manifest" \
  || fail "MANIFEST missing oomd-drill-hog.service"
grep -Fxq "bin/oomd-drill /home/nish/.local/bin/oomd-drill" "$manifest" \
  || fail "MANIFEST missing bin/oomd-drill"
ok "MANIFEST installs drill units + script in user scope"

# 5. --check against a fake systemd (CI path).
fake="$(mktemp -d)"
trap 'rm -rf "$fake"' EXIT
cat >"$fake/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet systemd-oomd.service") exit 0 ;;
  "--user cat oomd-drill.slice") exit 0 ;;
  "--user cat oomd-drill-hog.service") exit 0 ;;
  *) echo "unexpected systemctl: $*" >&2; exit 1 ;;
esac
FAKE
cat >"$fake/sudo" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "-n true") exit 0 ;;
  *) echo "unexpected sudo: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake/systemctl" "$fake/sudo"
out="$(SYSTEMCTL="$fake/systemctl" SUDO="$fake/sudo" "$drill" --check 2>&1)" || {
  fail "--check should succeed against a healthy fake systemd, got: $out"
}
printf '%s\n' "$out" | grep -q 'prerequisites ok' || fail "--check must log prerequisites ok: $out"
ok "--check passes when oomd + drill units + sudo are present"

# 6. --check fails closed if oomd is down.
cat >"$fake/systemctl-down" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet systemd-oomd.service") exit 1 ;;
  *) echo "unexpected systemctl: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake/systemctl-down"
set +e
err="$(SYSTEMCTL="$fake/systemctl-down" SUDO="$fake/sudo" "$drill" --check 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "--check must exit 1 when oomd is inactive, got rc=$rc ($err)"
printf '%s\n' "$err" | grep -q 'systemd-oomd is not active' \
  || fail "--check must name the missing oomd: $err"
ok "--check fails closed when systemd-oomd is inactive"

# 7. Bad flag.
set +e
err="$("$drill" --bogus 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "bad flag must exit 1, got $rc ($err)"
ok "unknown flag is refused"

# 8. systemd-analyze on the hog (syntax). Skip if the tool is missing.
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify --man=no "$hog" >/dev/null \
    || fail "systemd-analyze verify failed for oomd-drill-hog.service"
  ok "systemd-analyze verify accepts oomd-drill-hog.service"
else
  echo "SKIP: systemd-analyze not on PATH"
fi

echo "OK: oomd-drill shape and --check path locked"
