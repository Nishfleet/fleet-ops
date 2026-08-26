#!/usr/bin/env bash
# tests/ram-governor-self-calibrate.test.sh
#
# fleet-ops#193: ram_gb_per_worker is measured from live pi-issue cgroup
# memory.current, not a hand-set 0.75 G vibe. This test drives the
# arithmetic with stubbed RSS distributions and a stubbed MemAvailable
# so CI does not depend on the runner's /proc/meminfo.
#
# Proven:
#   1. Cold start (<10 samples) uses the config seed (0.75 G) → ram_cap=10
#      on a 10 GiB MemAvailable fixture (the old vibe ceiling).
#   2. 35 MB p95 (10 samples) clamps to the 128 MB floor → ram_cap=60,
#      seat_max clamps at provider-cap sum (19), not RAM.
#   3. 1 GB p95 clamps to the 1.5 GB ceiling → ram_cap=5, lanes shrink.
#   4. Persisted distribution is reused by a fresh shell (seed-from-last).
#   5. A >25% tick-over-tick move logs an AUDIT line; a no-op tick does not.
#   6. Live cgroup files (fake tree) are actually read.
#   7. Heartbeat tier1 calls ram_governor_recalibrate (no new timer).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/seat-lib.sh"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "seat-lib.sh not found: $lib"
command -v jq >/dev/null || fail "jq required"

scratch="$(mktemp -d -t ram-gov-193.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# 10 GiB MemAvailable. spare = 10240 - 2500 = 7740 MB = 7.5586 GiB.
#   / 0.75  → 10 lanes (cold-start seed)
#   / 0.125 → 60 lanes (128 MB floor)
#   / 1.5   →  5 lanes (1.5 GB ceiling)
cat >"$scratch/meminfo" <<'EOF'
MemTotal:       16384000 kB
MemAvailable:   10485760 kB
EOF

# Provider caps sum to 19, matching production order-of-magnitude so the
# 35 MB path is provider-capped and the 1 GB path is RAM-capped.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 0.75,
  "providers": {
    "devin":       { "cap": 4, "class": "subscription", "models": { "glm-5-2": 4 } },
    "cursor":      { "cap": 1, "class": "subscription", "models": { "composer-2.5": 1 } },
    "cline":       { "cap": 2, "class": "subscription", "models": { "cline-pass/deepseek-v4-flash": 2 } },
    "minimax":     { "cap": 2, "class": "metered",       "models": { "MiniMax-M3": 2 } },
    "ollama":      { "cap": 2, "class": "free",          "models": { "deepseek-v4-flash:0731": 2 } },
    "commandcode": { "cap": 2, "class": "free",          "models": { "deepseek/deepseek-v4-flash": 2 } },
    "hetzner":     { "cap": 2, "class": "free" },
    "zenmux":      { "cap": 2, "class": "metered" },
    "openrouter":  { "cap": 2, "class": "metered" }
  }
}
JSON

export PI_PACKET_STATE="$scratch/state"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export SEAT_RAM_GOVERNOR_STATE="$scratch/ram-governor.json"
export SEAT_MEMINFO="$scratch/meminfo"
export SEAT_RAM_GOVERNOR_STUB_RSS_FILE="$scratch/rss.txt"
export PI_SEAT_HEALTH_LEDGER_DIR="$scratch/ledger"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
mkdir -p "$PI_PACKET_STATE" "$PI_SEAT_HEALTH_LEDGER_DIR"

bytes_35m=$((35 * 1024 * 1024))   # 36700160
bytes_1g=$((1024 * 1024 * 1024))  # 1073741824

write_rss() {
  local n="$1" bytes="$2" i
  : >"$SEAT_RAM_GOVERNOR_STUB_RSS_FILE"
  for ((i=0; i<n; i++)); do
    printf '%s\n' "$bytes" >>"$SEAT_RAM_GOVERNOR_STUB_RSS_FILE"
  done
}

run_recal() {
  bash -c 'source "$0"; load_seat_caps; ram_governor_recalibrate' "$lib"
}

# ============================================================================
# 7. Heartbeat wiring — no new timer, arithmetic inside the existing tick
# ============================================================================
grep -q 'ram_governor_recalibrate' "$tier1" \
  || fail "tier1 must call ram_governor_recalibrate (fleet-ops#193)"
grep -q '8b. ram-governor' "$tier1" \
  || fail "tier1 must log the 8b ram-governor pass"
ok "tier1 calls ram_governor_recalibrate (no new timer)"

# ============================================================================
# 1. Cold start: 9 samples of 35 MB still use the 0.75 G seed
# ============================================================================
rm -f "$SEAT_RAM_GOVERNOR_STATE"
write_rss 9 "$bytes_35m"
out=$(run_recal)
echo "$out" | grep -q 'source=cold_start' || fail "cold: expected source=cold_start, got: $out"
echo "$out" | grep -q 'samples=9' || fail "cold: expected samples=9, got: $out"
echo "$out" | grep -q 'per_worker_gb=0.75' || fail "cold: expected per_worker_gb=0.75, got: $out"
echo "$out" | grep -q 'ram_cap=10' || fail "cold: expected ram_cap=10 on 10GiB/0.75G, got: $out"
echo "$out" | grep -q 'seat_max=10' || fail "cold: expected seat_max=10 (RAM binds vs caps=19), got: $out"
echo "$out" | grep -q 'audit=0' || fail "cold: first tick has no prev, audit must be 0, got: $out"
ok "cold start (<10 samples) keeps 0.75 G seed → ram_cap=10"

# ============================================================================
# 2. 35 MB p95 → 128 MB floor → ram_cap=60, seat_max=provider-cap sum (19)
# ============================================================================
# Same state file already has 9 samples; one more tick of 10 identical
# 35 MB readings pushes n to 10 (trailing window keeps 64).
write_rss 10 "$bytes_35m"
out=$(run_recal)
echo "$out" | grep -q 'source=measured' || fail "35mb: expected source=measured, got: $out"
echo "$out" | grep -q 'per_worker_gb=0.1250' || fail "35mb: expected per_worker_gb=0.1250 (128 MB floor), got: $out"
echo "$out" | grep -q 'ram_cap=60' || fail "35mb: expected ram_cap=60, got: $out"
echo "$out" | grep -q 'seat_max=19' || fail "35mb: expected seat_max=19 (provider-cap sum, not RAM), got: $out"
echo "$out" | grep -q 'audit=1' || fail "35mb: 0.75 → 0.125 is >25%, expected audit=1, got: $out"
grep -q 'AUDIT per_worker_gb' "$PI_PACKET_STATE/watch.log" \
  || fail "35mb: must seat_log the AUDIT line"
ok "35 MB p95 clamps to 128 MB floor → ram_cap=60, seat_max=19 (provider-cap)"

# ============================================================================
# 5b. No-op tick (same distribution) does not re-audit
# ============================================================================
: >"$PI_PACKET_STATE/watch.log"
write_rss 10 "$bytes_35m"
out=$(run_recal)
echo "$out" | grep -q 'audit=0' || fail "noop: same per_worker must not audit, got: $out"
if grep -q 'AUDIT per_worker_gb' "$PI_PACKET_STATE/watch.log"; then
  fail "noop: must not seat_log AUDIT on a no-op tick"
fi
ok "no-op tick does not re-audit"

# ============================================================================
# 4. Fresh shell seeds from the persisted distribution (no new samples)
# ============================================================================
: >"$SEAT_RAM_GOVERNOR_STUB_RSS_FILE"
out=$(run_recal)
echo "$out" | grep -q 'source=measured' || fail "persist: expected source=measured, got: $out"
echo "$out" | grep -q 'per_worker_gb=0.1250' || fail "persist: expected persisted 0.1250, got: $out"
echo "$out" | grep -q 'seat_max=19' || fail "persist: expected seat_max=19, got: $out"
ok "fresh shell seeds from persisted distribution"

# ============================================================================
# 3. 1 GB p95 → 1.5 GB ceiling → ram_cap=5, lanes shrink below provider cap
# ============================================================================
write_rss 10 "$bytes_1g"
# Drop the old 35 MB samples so p95 is the 1 GB population (overwrite state
# by using a fresh file: recalibrate appends, so clear state first).
rm -f "$SEAT_RAM_GOVERNOR_STATE"
out=$(run_recal)
echo "$out" | grep -q 'source=measured' || fail "1g: expected source=measured, got: $out"
echo "$out" | grep -q 'per_worker_gb=1.5000' || fail "1g: expected per_worker_gb=1.5000 (1.5 GB ceiling), got: $out"
echo "$out" | grep -q 'ram_cap=5' || fail "1g: expected ram_cap=5, got: $out"
echo "$out" | grep -q 'seat_max=5' || fail "1g: expected seat_max=5 (RAM binds, lanes shrink), got: $out"
ok "1 GB p95 clamps to 1.5 GB ceiling → ram_cap=5, lanes shrink"

# ============================================================================
# 6. Fake cgroup tree is actually read (no stub file)
# ============================================================================
rm -f "$SEAT_RAM_GOVERNOR_STATE"
unset SEAT_RAM_GOVERNOR_STUB_RSS_FILE
uid=$(id -u)
croot="$scratch/cgroup"
slice="$croot/user.slice/user-${uid}.slice/user@${uid}.service/app.slice/app-pi\\x2dissue.slice"
failed="$croot/user.slice/user-${uid}.slice/user@${uid}.service/app.slice/app-pi\\x2dissue\\x2dfailed.slice"
i=0
while (( i < 10 )); do
  d="$slice/pi-issue@demo-${i}.service"
  mkdir -p "$d"
  printf '%s\n' "$bytes_35m" >"$d/memory.current"
  i=$((i+1))
done
# A failed-unit cgroup must NOT be sampled (would pollute p95).
mkdir -p "$failed/pi-issue-failed@nope.service"
printf '%s\n' "$bytes_1g" >"$failed/pi-issue-failed@nope.service/memory.current"

export SEAT_RAM_GOVERNOR_CGROUP_ROOT="$croot"
out=$(run_recal)
echo "$out" | grep -q 'source=measured' || fail "cgroup: expected source=measured, got: $out"
echo "$out" | grep -q 'samples=10' || fail "cgroup: expected samples=10 (failed unit skipped), got: $out"
echo "$out" | grep -q 'per_worker_gb=0.1250' || fail "cgroup: expected 128 MB floor from 35 MB files, got: $out"
echo "$out" | grep -q 'seat_max=19' || fail "cgroup: expected seat_max=19, got: $out"
ok "cgroup memory.current files are read; issue-failed skipped"

ok "ram-governor self-calibrate: cold start, 35 MB → provider-cap, 1 GB → RAM shrink, persist, audit, cgroup read"
