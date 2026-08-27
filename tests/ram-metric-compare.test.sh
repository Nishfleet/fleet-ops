#!/usr/bin/env bash
# tests/ram-metric-compare.test.sh
#
# fleet-ops#202: pin the memory.current vs VmRSS mismatch recorder.
#
#   1. The #202 live shape (12 units, 822.6 MB cgroup vs 35 MB VmRSS)
#      reports mismatch=1 and those p95s. Does not edit ram_gb_per_worker.
#   2. Equal metrics report mismatch=0.
#   3. Zero units still exit 0 and write a state file.
#   4. Admission formula uses memory.current p95*3 clamped to 1.5 GB (fleet-ops#489).
#   5. Comments that cite 35 MB must label it as process VmRSS and must
#      also cite memory.current + fleet-ops#202 (so the class cannot
#      silently return as "RSS means cgroup").
#   6. Heartbeat section 14 and MANIFEST wire the new binary.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/ram-metric-compare"
caps="$repo_root/config/seat-caps.json"
lib="$repo_root/lib/seat-lib.sh"
docs="$repo_root/docs/ram-governor-tree.md"
readme="$repo_root/README.md"
heartbeat="$repo_root/bin/fleet-heartbeat-tier1"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq required"

scratch="$(mktemp -d -t ram-metric-compare-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# #202 live numbers: p95_bytes=862556160 (=822.6 MiB), 35 MiB VmRSS.
CURRENT_P95=862556160
RSS_35=$((35 * 1024 * 1024))

# =========================================================================
# 1. #202 fixture: 12 live units, cgroup p95 822.6 MB vs VmRSS 35 MB
# =========================================================================
stub1="$scratch/stub-202.txt"
: >"$stub1"
for _ in $(seq 1 12); do
    printf '%s %s\n' "$CURRENT_P95" "$RSS_35" >>"$stub1"
done
state1="$scratch/state1"
before_gb=$(jq -r '.ram_gb_per_worker' "$caps")
out=$(RAM_STATE_DIR="$state1" RAM_COMPARE_STUB_FILE="$stub1" bash "$bin" 2>/dev/null) \
    || fail "ram-metric-compare exited non-zero on the #202 fixture"
after_gb=$(jq -r '.ram_gb_per_worker' "$caps")
[[ "$before_gb" == "$after_gb" ]] \
    || fail "ram_gb_per_worker must not change (before=$before_gb after=$after_gb)"
echo "$out" | grep -q 'mismatch=1' || fail "822.6 vs 35 MB must flag mismatch=1; got: $out"
echo "$out" | grep -q 'current_p95_mb=822.6' || fail "current p95 must be 822.6; got: $out"
echo "$out" | grep -q 'rss_p95_mb=35.0' || fail "rss p95 must be 35.0; got: $out"
echo "$out" | grep -q 'formula unchanged' || fail "stdout must say formula unchanged; got: $out"
state_json="$state1/ram-metric-compare.json"
[[ -f "$state_json" ]] || fail "state file missing"
[[ "$(jq -r '.n' "$state_json")" == "12" ]] || fail "n must be 12"
[[ "$(jq -r '.mismatch' "$state_json")" == "1" ]] || fail "state mismatch must be 1"
[[ "$(jq -r '.current_p95_bytes' "$state_json")" == "$CURRENT_P95" ]] \
    || fail "state current_p95_bytes mismatch"
ok "1. #202 fixture flags mismatch, records both p95s, leaves ram_gb_per_worker alone"

# =========================================================================
# 2. equal metrics -> no mismatch
# =========================================================================
stub2="$scratch/stub-equal.txt"
: >"$stub2"
for _ in $(seq 1 8); do
    printf '%s %s\n' "$RSS_35" "$RSS_35" >>"$stub2"
done
state2="$scratch/state2"
out=$(RAM_STATE_DIR="$state2" RAM_COMPARE_STUB_FILE="$stub2" bash "$bin" 2>/dev/null) \
    || fail "equal-metrics run exited non-zero"
echo "$out" | grep -q 'mismatch=0' || fail "equal metrics must be mismatch=0; got: $out"
echo "$out" | grep -q 'ratio=1.0' || fail "equal metrics ratio must be 1.0; got: $out"
ok "2. equal memory.current and VmRSS report mismatch=0"

# =========================================================================
# 3. zero units still exit 0
# =========================================================================
stub3="$scratch/stub-empty.txt"
: >"$stub3"
state3="$scratch/state3"
out=$(RAM_STATE_DIR="$state3" RAM_COMPARE_STUB_FILE="$stub3" bash "$bin" 2>/dev/null) \
    || fail "empty run must exit 0"
echo "$out" | grep -q 'n=0' || fail "empty run n must be 0; got: $out"
echo "$out" | grep -q 'mismatch=0' || fail "empty run mismatch must be 0; got: $out"
[[ -f "$state3/ram-metric-compare.json" ]] || fail "empty run must still write state"
ok "3. zero units exit 0 and write state"

# =========================================================================
# 4. admission formula uses memory.current, no self-calibrate
# =========================================================================
[[ "$(jq -r '.ram_gb_per_worker' "$caps")" == "0.6" ]] \
    || fail "ram_gb_per_worker must be 0.6 (got $(jq -r '.ram_gb_per_worker' "$caps"))"
if grep -q 'ram_governor_recalibrate\|ram_governor_effective_gb' "$lib"; then
    fail "seat-lib.sh must not self-calibrate per_worker from live RSS (#489 keeps the config as the source of truth)"
fi
grep -q 'per="$SEAT_RAM_GB_PER_WORKER"' "$lib" \
    || fail "ram_governor_cap must still divide by SEAT_RAM_GB_PER_WORKER"
ok "4. admission formula uses memory.current, config is source of truth, no self-calibrate"

# =========================================================================
# 5. comment records the #489 metric decision (memory.current, not VmRSS)
# =========================================================================
comment=$(jq -r '._comment_ram_governor' "$caps")
echo "$comment" | grep -q 'fleet-ops#489' \
    || fail "seat-caps ram-governor comment must cite fleet-ops#489 (the metric decision)"
echo "$comment" | grep -q 'memory.current' \
    || fail "seat-caps ram-governor comment must name memory.current"
echo "$comment" | grep -q 'VmRSS' \
    || fail "seat-caps ram-governor comment must name VmRSS (the rejected metric)"
if echo "$comment" | grep -q '35 MB'; then
    echo "$comment" | grep -q 'process VmRSS' \
        || fail "35 MB in the ram-governor comment must be labelled process VmRSS"
fi
grep -q 'fleet-ops#202' "$docs" || fail "docs/ram-governor-tree.md must cite fleet-ops#202"
grep -q 'memory.current' "$docs" || fail "docs/ram-governor-tree.md must name memory.current"
grep -q 'VmRSS' "$docs" || fail "docs/ram-governor-tree.md must name VmRSS"
grep -q 'ram-metric-compare' "$readme" || fail "README must name ram-metric-compare"
ok "5. comment records #489 metric decision; memory.current + VmRSS named"

# =========================================================================
# 6. heartbeat + MANIFEST wiring
# =========================================================================
grep -q 'ram-metric-compare' "$heartbeat" \
    || fail "fleet-heartbeat-tier1 must invoke ram-metric-compare"
grep -q 'FLEET_RAM_COMPARE_BIN' "$heartbeat" \
    || fail "fleet-heartbeat-tier1 must honour FLEET_RAM_COMPARE_BIN"
grep -q 'bin/ram-metric-compare /home/nish/.local/bin/ram-metric-compare' "$manifest" \
    || fail "MANIFEST must install ram-metric-compare"
ok "6. heartbeat section 14 and MANIFEST wire ram-metric-compare"

# =========================================================================
# 7. live walk: activating oneshot + named properties (systemd 255 order)
# =========================================================================
# pi-issue@ is Type=oneshot, so the worker is activating not active.
# systemd 255 prints MainPID before MemoryCurrent regardless of -p order.
fake="$scratch/fake-systemctl"
mkdir -p "$scratch/proc/4242"
printf 'VmRSS:\t    35840 kB\n' >"$scratch/proc/4242/status"
cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
case "$1" in
    list-units)
        printf '%s loaded activating start\tdescription\n' 'pi-issue@live-01.service'
        exit 0
        ;;
    show)
        # Deliberately MainPID first, matching live systemd 255.
        printf 'MainPID=4242\nMemoryCurrent=862556160\n'
        exit 0
        ;;
    *) echo "unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake"
state7="$scratch/state7"
out=$(SYSTEMCTL="$fake" RAM_STATE_DIR="$state7" RAM_COMPARE_PROC_ROOT="$scratch/proc" \
    bash "$bin" 2>/dev/null) \
    || fail "live-walk run exited non-zero"
echo "$out" | grep -q 'n=1' || fail "activating unit must be counted; got: $out"
echo "$out" | grep -q 'current_p95_mb=822.6' || fail "must read MemoryCurrent by name not line 1; got: $out"
echo "$out" | grep -q 'rss_p95_mb=35.0' || fail "must read VmRSS from MainPID; got: $out"
echo "$out" | grep -q 'mismatch=1' || fail "live walk of #202 shape must mismatch; got: $out"
ok "7. activating oneshot + named properties (not --value order)"

echo
echo "ALL OK"
