#!/usr/bin/env bash
# tests/ram-metric-compare.test.sh
#
# fleet-ops#202: pin the memory.current vs VmRSS mismatch recorder.
#
#   1. The #202 live shape (12 units, 822.6 MB cgroup vs 35 MB VmRSS)
#      reports mismatch=1 and those p95s. Does not edit ram_gb_per_worker.
#   2. Equal metrics report mismatch=0.
#   3. Zero units still exit 0 and write a state file.
#   4. Admission uses ram_gb_per_worker from the cap map (0.65 as of #5955), no self-calibrate.
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
# 4. admission charges per-repo MemoryHigh (fleet-ops#3679), fallback 1.5
#    The flat ram_gb_per_worker (1.5) is now ONLY the fallback for repos
#    without a worker_memory row; each active worker is charged its repo's
#    MemoryHigh (0509 2.5G, fleet-ops 2.5G per #3885, heavy 1.0G from #3495) divided
#    by the fallback. fleet-ops#3930 (2026-09-06) REMOVED the MemoryHigh band for
#    fleet-ops + 0509 (it is what made oomd pressure-kill a random sibling), so
#    those repos now have no row MemoryHigh and are charged the fallback 1.5.
#    Drift history: #1246 flagged the 1.5 lock stale after
#    #1168 set 0.6; #1270 locked the assertion at 0.6 and #1284 fixed the
#    docstrings; #1558 later re-measured down to 0.5; #3679 raised the charge
#    to 2.0 and made it per-repo; #4164 (2026-09-07) lowered it to 1.0 after
#    re-measurement showed the 2.0 charge admitted only 4 workers at 12GB free
#    while kills came from per-unit MemoryMax=4G caps, not concurrency;
#    #4838 (2026-09-10) restored 2.0 after measured MemoryPeak p50 ~1.9G
#    against a 1.0 charge oversubscribed the box; #4896 (2026-09-10) set an
#    interim 1.5 once #4893 removed local coverage/tsc from workers (the
#    remeasure-4891 timer re-prices to measured p95 on 2026-09-11).
#    #5955 (2026-09-12) lowered it to 0.65: cgroup memory.current p95 637.2 MB
#    (n=13, bin/ram-metric-compare); 24h finished-worker MemoryPeak n=875 p50 288 MB,
#    p90 2.0G, p95 2.3G, max 4.0G (= MemoryMax), peaks short and non-coincident;
#    admission also double-counts active workers via active_ram_charge in
#    pi-intake-tick.sh (MemAvailable already net of running workers), which
#    starved intake to cap=5/active=7 at 10.8G free. Double-count fix -> #4263.
#    Coupling rule (fleet-ops#1190, the #1168
#    drift that broke this test): the "0.65" below is a deliberate lock.
#    When you change ram_gb_per_worker in config/seat-caps.json, update this
#    assertion and the ok line below in the SAME commit/PR. The config value
#    is the source of truth; this test exists to catch a config change that
#    forgets its measurement doc.
# =========================================================================
#    2026-09-11 (Nish: "DO IT NOW"): 1.0 — remeasure-4891 run 3 (213 workers/24h)
#    median 1.50G p95 3.00G INCLUDED pre-#4893 workers running coverage/tsc; the
#    instantaneous cgroup p95 of the six live post-#4893 workers is 226 MB
#    (bin/ram-metric-compare 2026-09-11 17:13Z). ram_cap = (MemAvail 10.9G - 2.5G floor)/1.0 = 8.
#    Backstops unchanged: per-unit MemoryMax=4G, slice MemoryHigh=12G, oomd 80%.
#    If FleetOomdKillsHigh fires (fleet_oomd_kills_6h > 3), restore 1.5 and say so here.
#    2026-09-12 (#5955): 0.65 — mem.current p95 637.2 MB (n=13, bin/ram-metric-compare
#    2026-09-12T10:53:16Z); 24h MemoryPeak n=875 p50 288M p90 2.0G p95 2.3G max 4.0G (=MemoryMax);
#    6h oomd kills at 8-10 workers = 1 (pi-issue@fleet-ops-5887, per-unit 4G cap).
#    ram_cap = (MemAvail 10.8G - 2.5G floor)/0.65 ≈ 12.
#    Backstops unchanged: per-unit MemoryMax=4G, slice MemoryHigh=12G, oomd 80%.
[[ "$(jq -r '.ram_gb_per_worker' "$caps")" == "0.65" ]] \
    || fail "ram_gb_per_worker must be 0.65 (got $(jq -r '.ram_gb_per_worker' "$caps")) — update this assertion and the scenario-4 comment in the same PR (fleet-ops#1190)"
if grep -q 'ram_governor_recalibrate\|ram_governor_effective_gb' "$lib"; then
    fail "seat-lib.sh must not self-calibrate per_worker from live RSS (#489 keeps the config as the source of truth)"
fi
grep -q 'per="$SEAT_RAM_GB_PER_WORKER"' "$lib" \
    || fail "ram_governor_cap must still divide by SEAT_RAM_GB_PER_WORKER"
# fleet-ops#3679: admission charges per-repo MemoryHigh, not a flat 2.0.
# ram_charge_gb_for must exist and return the repo's MemoryHigh in GB.
grep -q 'ram_charge_gb_for()' "$lib" \
    || fail "seat-lib.sh must define ram_charge_gb_for (per-repo charge, fleet-ops#3679)"
# fleet-ops light has NO MemoryHigh after #3930 -> fallback 0.65; unknown repo -> fallback 0.65.
fo_charge=$(SEAT_CAPS_JSON="$caps" bash -c 'source "$0"; _seat_caps_loaded=0; load_seat_caps; ram_charge_gb_for fleet-ops light' "$lib")
[[ "$fo_charge" == "0.65" ]] || fail "ram_charge_gb_for fleet-ops light want fallback 0.65 got '$fo_charge'"
unk_charge=$(SEAT_CAPS_JSON="$caps" bash -c 'source "$0"; _seat_caps_loaded=0; load_seat_caps; ram_charge_gb_for unknown-repo light' "$lib")
[[ "$unk_charge" == "0.65" ]] || fail "ram_charge_gb_for unknown-repo light want fallback 0.65 got '$unk_charge'"
ok "4. admission charges per-repo MemoryHigh (fallback 0.65), no self-calibrate"

# =========================================================================
# 5. 35 MB cannot be cited as cgroup memory.current
# =========================================================================
comment=$(jq -r '._comment_ram_governor' "$caps")
echo "$comment" | grep -q 'fleet-ops#202' \
    || fail "seat-caps ram-governor comment must cite fleet-ops#202"
echo "$comment" | grep -q 'memory.current' \
    || fail "seat-caps ram-governor comment must name memory.current"
echo "$comment" | grep -q 'VmRSS' \
    || fail "seat-caps ram-governor comment must name VmRSS"
echo "$comment" | grep -q '822.6' \
    || fail "seat-caps ram-governor comment must record the 822.6 MB live p95"
if echo "$comment" | grep -q '35 MB'; then
    echo "$comment" | grep -q 'process VmRSS' \
        || fail "35 MB in the ram-governor comment must be labelled process VmRSS"
fi
grep -q 'fleet-ops#202' "$docs" || fail "docs/ram-governor-tree.md must cite fleet-ops#202"
grep -q 'memory.current' "$docs" || fail "docs/ram-governor-tree.md must name memory.current"
grep -q 'VmRSS' "$docs" || fail "docs/ram-governor-tree.md must name VmRSS"
grep -q 'ram-metric-compare' "$readme" || fail "README must name ram-metric-compare"
ok "5. 35 MB is labelled process VmRSS; memory.current + #202 are recorded"

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

# =========================================================================
# 8. ram_governor_cap sanity assertion: fail loud if cap >= 64
# =========================================================================
# A MB-vs-GB slip (or a bogus tiny per-worker budget) can make the governor
# claim thousands of workers. It must refuse to emit a cap >= 64.
sanity_caps="$scratch/caps-sanity.json"
jq '.ram_gb_per_worker = 0.0001' "$caps" > "$sanity_caps"
set +e
out=$(PI_PACKET_STATE="$scratch/pi-packet-sanity" SEAT_CAPS_JSON="$sanity_caps" \
    bash -c 'source "$0"; _seat_caps_loaded=0; load_seat_caps; ram_governor_cap 2>/dev/null' "$lib")
rc=$?
set -e
[[ "$rc" -ne 0 ]] \
    || fail "ram_governor_cap must fail loud when computed cap >= 64 (rc=$rc)"
[[ -z "$out" ]] \
    || fail "ram_governor_cap must not emit a huge cap on sanity fail (got '$out')"
ok "8. ram_governor_cap fails loud when a unit slip yields cap >= 64"

echo
echo "ALL OK"
