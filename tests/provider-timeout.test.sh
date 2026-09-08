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
  "template/extensions/cursor-cloud-provider/index.ts /home/nish/.pi/agent/extensions/cursor-cloud-provider/index.ts"
)

# A no-match grep exits 1, which under `set -euo pipefail` aborts the loop
# for an HTTP provider (cursor-cloud) that intentionally has no subprocess
# timeout. Capture patterns as bare integers, fail-open to empty.
_capture_run_ceiling() {
	# $1 = file, $2 = first pattern, $3 = second pattern. Prints a bare integer.
	local out
	out=$(grep -oE "$2" "$1" 2>/dev/null | grep -oE "$3" 2>/dev/null | tail -n1 || true)
	printf '%s\n' "$out"
}

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

  # --- 3. effective run ceiling >= 0.9 x PI_HANG_TIMEOUT_S -------------------
  # devin/cursor use a spawnSync `timeout: <ms>`. cursor-cloud is an HTTP
  # provider (no subprocess) — its run is bounded by the poll loop
  # MAX_POLLS x POLL_INTERVAL_MS. Both must stay >= 0.9 x the hang watchdog.
  timeout_ms=$(_capture_run_ceiling "$repo_root/$src" 'timeout: *[0-9]+' '[0-9]+')
  if [[ -z "$timeout_ms" ]]; then
    # HTTP/poll-loop form: MAX_POLLS and POLL_INTERVAL_MS constants.
    max_polls=$(_capture_run_ceiling "$repo_root/$src" 'MAX_POLLS *[=:] *[0-9]+' '[0-9]+')
    interval_ms=$(_capture_run_ceiling "$repo_root/$src" 'POLL_INTERVAL_MS *[=:] *[0-9]+' '[0-9]+')
    if [[ -n "$max_polls" && -n "$interval_ms" ]]; then
      timeout_ms=$(( max_polls * interval_ms ))
    else
      fail "$src: no 'timeout: <ms>' and no MAX_POLLS/POLL_INTERVAL_MS bound"
    fi
  fi
  if ! [[ "$timeout_ms" =~ ^[0-9]+$ ]]; then
    fail "$src: timeout value '$timeout_ms' is not an integer"
  fi
  if (( timeout_ms < bar_ms )); then
    fail "$src: timeout ${timeout_ms}ms ($((timeout_ms/1000))s) < 0.9 x PI_HANG_TIMEOUT_S ($bar_ms ms / $PI_HANG_TIMEOUT_S s) — provider dies before the hang watchdog"
  fi
  ok "$src: effective ceiling ${timeout_ms}ms >= 0.9 x PI_HANG_TIMEOUT_S=${bar_ms}ms (watchdog ${PI_HANG_TIMEOUT_S}s)"

  # --- 4. a raised live value must not ever appear (1800000 = the 2026-09-04 stall)
  if grep -qE 'timeout: *1800000' "$repo_root/$src"; then
    fail "$src: reintroduced the 1800000ms (30-min) timeout that killed every heavy packet on 2026-09-04"
  fi
  ok "$src: no 1800000ms regression"
done

echo "ALL OK: all managed providers + ceilings >= 0.9 x PI_HANG_TIMEOUT_S"