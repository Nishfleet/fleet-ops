#!/usr/bin/env bash
# tests/provider-timeout.test.sh
#
# fleet-ops#3263: bring the devin-provider and cursor-provider Pi extensions
# under fleet-ops management and keep their spawnSync timeout durable.
#
# Background: on 2026-09-04 every heavy packet on the devin seat died at
# exactly 1801s with rc=1 — the provider's spawnSync `timeout` was 1800000ms
# (30 min), just above pi-issue-run's 30-min default but under the real
# watchdog. PI_HANG_TIMEOUT_S is bin/pi-issue-run's kill-after bound
# (default 2520s). The live timeout was raised to 2400000ms; this PR moves
# both providers' index.ts into template/extensions/ + MANIFEST so the run
# can no longer drift back to the 1800s value.
#
# Invariants:
#   1. Both providers are MANIFEST lines (install.sh converges them).
#   2. Both repo copies exist.
#   3. Each provider spawnSync `timeout` (ms) is >= 0.9 x PI_HANG_TIMEOUT_S.
#      The provider must never be killed by the pi hang watchdog, and a
#      timeout below 0.9 x the watchdog is exactly the 2026-09-04 stall:
#      pi deadlocks waiting on a CLI the watchdog is allowed to outlive.
#
# Lock-and-leave. Runs offline in CI (no GitHub App, no live box needed).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
manifest="$repo_root/MANIFEST"

PI_HANG_TIMEOUT_S="${PI_HANG_TIMEOUT_S:-2520}"   # must match bin/pi-issue-run default

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# bar in milliseconds, ceiling so the >= comparison is integer-safe.
bar_ms=$(awk -v t="$PI_HANG_TIMEOUT_S" 'BEGIN { printf "%d", t * 900 }')  # 0.9 * 1000

[[ -f "$manifest" ]] || fail "MANIFEST missing"

providers=(
  "template/extensions/devin-provider/index.ts /home/nish/.pi/agent/extensions/devin-provider/index.ts"
  "template/extensions/cursor-provider/index.ts /home/nish/.pi/agent/extensions/cursor-provider/index.ts"
)

for entry in "${providers[@]}"; do
  src="${entry%% *}"
  dest="${entry##* }"
  # --- 1. MANIFEST declares the install dest -----------------------------
  grep -Fxq "$entry" "$manifest" \
    || fail "MANIFEST missing provider entry: $entry"
  ok "MANIFEST declares: $src -> $dest"

  # --- 2. repo copy exists ------------------------------------------------
  [[ -f "$repo_root/$src" ]] || fail "provider file not in repo: $src"
  ok "repo copy present: $src"

  # --- 3. spawnSync timeout >= 0.9 x PI_HANG_TIMEOUT_S --------------------
  timeout_ms=$(grep -oE 'timeout: *[0-9]+' "$repo_root/$src" \
    | grep -oE '[0-9]+' | tail -n1)
  [[ -n "$timeout_ms" ]] || fail "$src: no 'timeout: <ms>' found"
  if ! [[ "$timeout_ms" =~ ^[0-9]+$ ]]; then
    fail "$src: timeout value '$timeout_ms' is not an integer"
  fi
  if (( timeout_ms < bar_ms )); then
    fail "$src: timeout ${timeout_ms}ms ($((timeout_ms/1000))s) < 0.9 x PI_HANG_TIMEOUT_S ($bar_ms ms / $PI_HANG_TIMEOUT_S s) — spawnSync dies before the hang watchdog"
  fi
  ok "$src: timeout ${timeout_ms}ms >= 0.9 x PI_HANG_TIMEOUT_S=${bar_ms}ms (watchdog ${PI_HANG_TIMEOUT_S}s)"

  # --- 4. a raised live value must not ever appear (1800000 = the 2026-09-04 stall)
  if grep -qE 'timeout: *1800000' "$repo_root/$src"; then
    fail "$src: reintroduced the 1800000ms (30-min) timeout that killed every heavy packet on 2026-09-04"
  fi
  ok "$src: no 1800000ms regression"
done

echo "ALL OK: both providers managed + timeouts >= 0.9 x PI_HANG_TIMEOUT_S"