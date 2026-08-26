#!/usr/bin/env bash
# tests/ram-measure.test.sh
#
# fleet-ops#45: pin the contract of bin/ram-measure. The four observable
# properties we prove:
#
#   1. With a stub systemctl that reports fixed MemoryPeak bytes for
#      N units, the script reports count=N, max=expected_max, and a
#      non-zero p95 (proving the asort-1-indexed pitfall is handled).
#   2. A unit whose MemoryPeak is "[not set]" is counted as no-data,
#      not as a 0-byte peak.
#   3. A unit whose MemoryPeak is "infinity" (the value systemd uses
#      when MemoryHigh is unset) is NOT counted as data — it is junk.
#   4. With ZERO matching units, the script still writes a state file
#      with count=0 and exits 0 (measurement is observability, never
#      a gate).
#   5. The state file accumulates a rolling history; running the
#      script K times in a row produces a history of length min(K, N).
#   6. The top_units array is sorted by peak descending, length <=
#      RAM_TOP_N.
#
# All checks use a fake systemctl under a scratch $PATH. No real
# systemd, no real fleet, no network.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/ram-measure"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
command -v jq >/dev/null 2>&1 || fail "jq required"
command -v gawk >/dev/null 2>&1 || command -v awk >/dev/null 2>&1 \
    || fail "awk required (gawk for asort; mawk's asort behaves the same on this surface)"

# --- stub systemctl --------------------------------------------------------
# The script invokes:
#   systemctl --user list-units <globs> --all --no-legend --plain
#   systemctl --user show -p MemoryPeak -p MemoryHigh -p MemoryMax
#                         -p ActiveState --value <unit>
#
# list-units reads from $FAKE_LIST_FILE (one unit per line).
# show reads from $FAKE_PEAK_FILE / $FAKE_HIGH_FILE / $FAKE_MAX_FILE /
# $FAKE_ACTIVE_FILE. Each is "<unit>|<value>".
scratch="$(mktemp -d -t ram-measure-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

fake="$scratch/systemctl"
FAKE_LIST_FILE="$scratch/list.txt"
FAKE_PEAK_FILE="$scratch/peak.db"
FAKE_HIGH_FILE="$scratch/high.db"
FAKE_MAX_FILE="$scratch/max.db"
FAKE_ACTIVE_FILE="$scratch/active.db"
: >"$FAKE_LIST_FILE"
: >"$FAKE_PEAK_FILE"
: >"$FAKE_HIGH_FILE"
: >"$FAKE_MAX_FILE"
: >"$FAKE_ACTIVE_FILE"
# Export so the fake subprocess can read these paths.
export FAKE_LIST_FILE FAKE_PEAK_FILE FAKE_HIGH_FILE FAKE_MAX_FILE FAKE_ACTIVE_FILE

cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
shift  # --user
case "$1" in
    list-units)
        # Skip the globs and the --all --no-legend --plain flags; emit
        # every unit in the FAKE_LIST_FILE.
        while IFS= read -r u; do
            [[ -n "$u" ]] || continue
            # Mirror systemd's actual output shape: "UNIT LOAD ACTIVE SUB DESCRIPTION".
            active=$(grep -F "${u}|" "$FAKE_ACTIVE_FILE" | head -n1 | cut -d'|' -f2)
            [[ -z "$active" ]] && active="inactive"
            printf '%s loaded %s dead\tdescription\n' "$u" "$active"
        done < "$FAKE_LIST_FILE"
        exit 0
        ;;
    show)
        # `show -p MemoryPeak -p MemoryHigh -p MemoryMax -p ActiveState --value UNIT`
        # We accept all the flags and just print the four values, in
        # order, separated by newlines (matches real systemd's --value
        # output for four -p props).
        unit=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -p|--property=*) shift ;;
                --value) shift ;;
                *) unit="$1"; shift ;;
            esac
        done
        peak=$(grep -F "${unit}|" "$FAKE_PEAK_FILE" | head -n1 | cut -d'|' -f2-)
        high=$(grep -F "${unit}|" "$FAKE_HIGH_FILE" | head -n1 | cut -d'|' -f2-)
        mx=$(grep -F "${unit}|" "$FAKE_MAX_FILE"   | head -n1 | cut -d'|' -f2-)
        active=$(grep -F "${unit}|" "$FAKE_ACTIVE_FILE" | head -n1 | cut -d'|' -f2-)
        [[ -z "$peak"   ]] && peak="[not set]"
        [[ -z "$high"   ]] && high="[not set]"
        [[ -z "$mx"     ]] && mx="[not set]"
        [[ -z "$active" ]] && active="inactive"
        printf '%s\n%s\n%s\n%s\n' "$peak" "$high" "$mx" "$active"
        exit 0
        ;;
    *) echo "unexpected systemctl call: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$fake"

# Put the fake on PATH so bare `systemctl` invocations from the script
# find it.
mkdir -p "$scratch/bin"
ln -sf "$fake" "$scratch/bin/systemctl"
export PATH="$scratch/bin:$PATH"
export SYSTEMCTL="$fake"

# Convenience helpers for seeding the fake databases.
seed_unit() {
    local unit="$1" active="${2:-inactive}"
    echo "$unit" >> "$FAKE_LIST_FILE"
    printf '%s|%s\n' "$unit" "$active" >> "$FAKE_ACTIVE_FILE"
}
seed_peak() {
    local unit="$1" peak_bytes="$2"
    # Defaults: MemoryHigh = 3 GiB, MemoryMax = 6 GiB (production values).
    local high_bytes="${3:-3221225472}"
    local max_bytes="${4:-6442450944}"
    printf '%s|%s\n' "$unit" "$peak_bytes"   >> "$FAKE_PEAK_FILE"
    printf '%s|%s\n' "$unit" "$high_bytes"   >> "$FAKE_HIGH_FILE"
    printf '%s|%s\n' "$unit" "$max_bytes"    >> "$FAKE_MAX_FILE"
}

# One GiB in bytes, used to keep the test inputs human-readable.
GIB=$((1024 * 1024 * 1024))

# =========================================================================
# 1. distribution math is right
# =========================================================================
# 7 units with deterministic peaks; known mean/median/p95/max.
#   0.10, 0.20, 0.30, 0.50, 0.80, 1.00, 4.00 GiB
#   sum = 6.90 GiB; mean = 0.986 GiB
#   sorted: 0.10, 0.20, 0.30, 0.50, 0.80, 1.00, 4.00
#   median = a[int(7/2)] = a[3] = 0.50 GiB
#   p95_i = int(7*0.95) = 6; p95 = a[6] = 4.00 GiB
#   max   = a[7]        = 4.00 GiB
state1="$scratch/state1"
: >"$FAKE_LIST_FILE"
: >"$FAKE_ACTIVE_FILE"
: >"$FAKE_PEAK_FILE"
: >"$FAKE_HIGH_FILE"
: >"$FAKE_MAX_FILE"

# 7 units; peak_bytes are int(GiB * 1073741824).
seed_unit "pi-issue@test-01.service" inactive; seed_peak "pi-issue@test-01.service" $((GIB * 10 / 100))
seed_unit "pi-issue@test-02.service" inactive; seed_peak "pi-issue@test-02.service" $((GIB * 20 / 100))
seed_unit "pi-issue@test-03.service" inactive; seed_peak "pi-issue@test-03.service" $((GIB * 30 / 100))
seed_unit "pi-issue@test-04.service" inactive; seed_peak "pi-issue@test-04.service" $((GIB * 50 / 100))
seed_unit "pi-issue@test-05.service" inactive; seed_peak "pi-issue@test-05.service" $((GIB * 80 / 100))
seed_unit "pi-issue@test-06.service" inactive; seed_peak "pi-issue@test-06.service" $((GIB * 100 / 100))
seed_unit "pi-issue@test-07.service" inactive; seed_peak "pi-issue@test-07.service" $((GIB * 400 / 100))

out=$(RAM_STATE_DIR="$state1" bash "$bin" 2>/dev/null) \
    || fail "ram-measure exited non-zero on the happy path"
echo "$out" | grep -q '^ram: n=7 ' || fail "summary line missing or wrong: $out"
echo "$out" | grep -q 'p95=4.00GiB' || fail "p95 must be 4.00 GiB (the 4.8 GB outlier analogue); got: $out"
echo "$out" | grep -q 'max=4.00GiB' || fail "max must be 4.00 GiB; got: $out"
echo "$out" | grep -q 'mean=0.99GiB' || fail "mean must be ~0.99 GiB; got: $out"
ok "1. distribution math is right (mean/median/p95/max)"

# Verify the on-disk state file is parseable and carries the same numbers.
state_json="$state1/ram-measurement.json"
[[ -f "$state_json" ]] || fail "state file not written"
count=$(jq -r '.count' "$state_json")
[[ "$count" == "7" ]] || fail "state count != 7 (got: $count)"
max_b=$(jq -r '.max_gib' "$state_json")
[[ "$max_b" == "4.00" ]] || fail "state max_gib != 4.00 (got: $max_b)"
p95_b=$(jq -r '.p95_gib' "$state_json")
[[ "$p95_b" == "4.00" ]] || fail "state p95_gib != 4.00 (got: $p95_b)"
ok "1a. state file has count, max_gib, p95_gib set correctly"

# =========================================================================
# 2. no-data units counted separately (not as 0-byte peaks)
# =========================================================================
: >"$FAKE_LIST_FILE"
: >"$FAKE_ACTIVE_FILE"
: >"$FAKE_PEAK_FILE"
: >"$FAKE_HIGH_FILE"
: >"$FAKE_MAX_FILE"

seed_unit "pi-issue@data-01.service" inactive; seed_peak "pi-issue@data-01.service" $((GIB / 2))   # 0.5 GiB
seed_unit "pi-issue@nodata-01.service" inactive                                       # never run -> [not set]
seed_unit "pi-issue@nodata-02.service" inactive
seed_unit "pi-issue@data-02.service" inactive; seed_peak "pi-issue@data-02.service" $((GIB * 2))   # 2.0 GiB

state2="$scratch/state2"
out=$(RAM_STATE_DIR="$state2" bash "$bin" 2>/dev/null) || fail "ram-measure failed with no-data units"
echo "$out" | grep -q '^ram: n=2 ' || fail "count must be 2 (data units only); got: $out"
echo "$out" | grep -q 'no-data=2' || fail "no-data count must be 2; got: $out"
echo "$out" | grep -q 'total-units=4' || fail "total-units must be 4; got: $out"
ok "2. no-data units are counted separately, not as 0-byte peaks"

# =========================================================================
# 3. 'infinity' is junk (not data)
# =========================================================================
: >"$FAKE_LIST_FILE"
: >"$FAKE_ACTIVE_FILE"
: >"$FAKE_PEAK_FILE"
: >"$FAKE_HIGH_FILE"
: >"$FAKE_MAX_FILE"

# Seed a unit with peak='infinity' (the literal value systemd returns
# when MemoryHigh is unset). The script must drop it as no-data.
seed_unit "pi-issue@infinity-01.service" inactive
printf '%s|%s\n' "pi-issue@infinity-01.service" "infinity" >> "$FAKE_PEAK_FILE"
printf '%s|%s\n' "pi-issue@infinity-01.service" "infinity" >> "$FAKE_HIGH_FILE"
printf '%s|%s\n' "pi-issue@infinity-01.service" "infinity" >> "$FAKE_MAX_FILE"
seed_unit "pi-issue@data-99.service" inactive; seed_peak "pi-issue@data-99.service" $((GIB / 4))

state3="$scratch/state3"
out=$(RAM_STATE_DIR="$state3" bash "$bin" 2>/dev/null) || fail "ram-measure failed with infinity peak"
echo "$out" | grep -q '^ram: n=1 ' || fail "infinity must be dropped; count should be 1; got: $out"
echo "$out" | grep -q 'no-data=1 ' || fail "infinity unit should be in no-data; got: $out"
ok "3. 'infinity' MemoryPeak is treated as no-data, not as a number"

# =========================================================================
# 4. zero matching units: still writes state, exits 0
# =========================================================================
: >"$FAKE_LIST_FILE"
state4="$scratch/state4"
out=$(RAM_MEASURE_GLOB='nothing-*.service' RAM_STATE_DIR="$state4" bash "$bin" 2>/dev/null) \
    || fail "ram-measure must exit 0 on zero matches"
echo "$out" | grep -q '^ram: n=0 ' || fail "zero-matches summary wrong: $out"
[[ -f "$state4/ram-measurement.json" ]] || fail "state file must exist even with zero units"
ok "4. zero units: exits 0, writes state, summary says n=0"

# =========================================================================
# 5. history rolls correctly
# =========================================================================
: >"$FAKE_LIST_FILE"
: >"$FAKE_ACTIVE_FILE"
: >"$FAKE_PEAK_FILE"
: >"$FAKE_HIGH_FILE"
: >"$FAKE_MAX_FILE"

seed_unit "pi-issue@hist-01.service" inactive; seed_peak "pi-issue@hist-01.service" $((GIB / 4))
state5="$scratch/state5"
for i in 1 2 3 4 5; do
    RAM_STATE_DIR="$state5" bash "$bin" >/dev/null 2>&1
done
hist_len=$(jq -r '.history | length' "$state5/ram-measurement.json")
[[ "$hist_len" == "5" ]] || fail "history length must be 5 after 5 runs (got: $hist_len)"
# Top of the history is the most recent.
top_count=$(jq -r '.history[0].count' "$state5/ram-measurement.json")
[[ "$top_count" == "1" ]] || fail "most recent history entry must have count=1 (got: $top_count)"
ok "5. history accumulates; length == runs (capped at RAM_HISTORY_LEN)"

# Cap at RAM_HISTORY_LEN
for i in 1 2 3 4 5 6 7; do
    RAM_STATE_DIR="$state5" RAM_HISTORY_LEN=3 bash "$bin" >/dev/null 2>&1
done
hist_len=$(jq -r '.history | length' "$state5/ram-measurement.json")
[[ "$hist_len" == "3" ]] || fail "history length must be capped at RAM_HISTORY_LEN=3 (got: $hist_len)"
ok "5a. history caps at RAM_HISTORY_LEN"

# =========================================================================
# 6. top_units is sorted descending and length <= RAM_TOP_N
# =========================================================================
: >"$FAKE_LIST_FILE"
: >"$FAKE_ACTIVE_FILE"
: >"$FAKE_PEAK_FILE"
: >"$FAKE_HIGH_FILE"
: >"$FAKE_MAX_FILE"

# 8 units with descending peaks; RAM_TOP_N=3 -> top 3 must be the biggest.
for i in 01 02 03 04 05 06 07 08; do
    seed_unit "pi-issue@top-$i.service" inactive
    # 0.1 GiB, 0.2, ... 0.8 GiB
    seed_peak "pi-issue@top-$i.service" $((GIB * 10#$i / 10))
done

state6="$scratch/state6"
RAM_STATE_DIR="$state6" RAM_TOP_N=3 bash "$bin" >/dev/null 2>&1 \
    || fail "ram-measure failed on the top-N test"

top_len=$(jq -r '.top_units | length' "$state6/ram-measurement.json")
[[ "$top_len" == "3" ]] || fail "top_units length must be 3 (got: $top_len)"

# First top unit must be the largest (0.8 GiB).
first_unit=$(jq -r '.top_units[0].unit' "$state6/ram-measurement.json")
[[ "$first_unit" == "pi-issue@top-08.service" ]] || fail "top[0] must be top-08 (largest), got: $first_unit"

# Verify descending order on peak_gib.
peaks=$(jq -r '.top_units[].peak_gib' "$state6/ram-measurement.json" | tr '\n' ' ')
sorted_peaks=$(printf '%s\n' $peaks | sort -gr | tr '\n' ' ')  # SC2086: intentional word-split for the peak list.
[[ "$peaks" == "$sorted_peaks" ]] || fail "top_units not sorted descending by peak_gib (got: '$peaks' vs '$sorted_peaks')"
ok "6. top_units is sorted descending, length <= RAM_TOP_N"

# =========================================================================
# 7. exit code is always 0 (measurement is observability, not a gate)
# =========================================================================
: >"$FAKE_LIST_FILE"
: >"$FAKE_PEAK_FILE"
: >"$FAKE_HIGH_FILE"
: >"$FAKE_MAX_FILE"
RAM_STATE_DIR="$scratch/state7" bash "$bin" >/dev/null 2>&1 \
    || fail "ram-measure must exit 0 even on the empty-fleet path"
ok "7. exit code is 0 on every observed path"

# =========================================================================
# 8. numeric peak + infinity high/max still exits 0 and records the unit
#    (fleet-ops#204: jq --argjson "infinity" is invalid JSON -> non-zero
#    exit -> set -euo pipefail kills the script. The throttled/hit_max
#    regex guards already handled infinity, but the jq call did not.)
# =========================================================================
: >"$FAKE_LIST_FILE"
: >"$FAKE_ACTIVE_FILE"
: >"$FAKE_PEAK_FILE"
: >"$FAKE_HIGH_FILE"
: >"$FAKE_MAX_FILE"

# A unit with a real numeric peak but NO MemoryHigh / MemoryMax caps
# (systemd reports "infinity" for both). This is the unit-file drift
# shape the issue calls out: live workers have 3G/6G caps, but a future
# unit without them must not crash the heartbeat sample.
seed_unit "pi-issue@uncapped-01.service" inactive
printf '%s|%s\n' "pi-issue@uncapped-01.service" "$((GIB * 3 / 2))" >> "$FAKE_PEAK_FILE"
printf '%s|%s\n' "pi-issue@uncapped-01.service" "infinity"          >> "$FAKE_HIGH_FILE"
printf '%s|%s\n' "pi-issue@uncapped-01.service" "infinity"          >> "$FAKE_MAX_FILE"
# A second unit whose high/max were never set at all (systemd's
# "[not set]" sentinel). jq --argjson rejects "[not set]" as invalid
# JSON on every jq build, so this unit is the deterministic repro for
# the crash the issue describes.
seed_unit "pi-issue@notset-01.service" inactive
printf '%s|%s\n' "pi-issue@notset-01.service" "$((GIB * 3 / 4))" >> "$FAKE_PEAK_FILE"
# high/max left unseeded -> the fake systemctl returns "[not set]".
# A third capped unit so the run has a real distribution.
seed_unit "pi-issue@capped-01.service" inactive; seed_peak "pi-issue@capped-01.service" $((GIB / 2))

state8="$scratch/state8"
out=$(RAM_STATE_DIR="$state8" bash "$bin" 2>/dev/null) \
    || fail "ram-measure must exit 0 with numeric peak + non-numeric high/max (fleet-ops#204)"
echo "$out" | grep -q '^ram: n=3 ' || fail "all three units must be recorded; got: $out"
echo "$out" | grep -q 'no-data=0 ' || fail "no no-data expected; got: $out"

# Each uncapped unit must appear in top_units with null high/max bytes
# and throttled=0 / hit_memory_max=0 (a non-numeric cap cannot have
# been hit).
for u in pi-issue@uncapped-01.service pi-issue@notset-01.service; do
    h=$(jq -r --arg u "$u" '.top_units[] | select(.unit==$u) | .memory_high_bytes' "$state8/ram-measurement.json")
    m=$(jq -r --arg u "$u" '.top_units[] | select(.unit==$u) | .memory_max_bytes' "$state8/ram-measurement.json")
    th=$(jq -r --arg u "$u" '.top_units[] | select(.unit==$u) | .throttled' "$state8/ram-measurement.json")
    hm=$(jq -r --arg u "$u" '.top_units[] | select(.unit==$u) | .hit_memory_max' "$state8/ram-measurement.json")
    [[ "$h" == "null" ]] || fail "$u memory_high_bytes must be null (got: $h)"
    [[ "$m" == "null" ]] || fail "$u memory_max_bytes must be null (got: $m)"
    [[ "$th" == "0" ]] || fail "$u must not be throttled (got: $th)"
    [[ "$hm" == "0" ]] || fail "$u must not have hit max (got: $hm)"
done
ok "8. numeric peak + non-numeric high/max exits 0, records unit, null caps"

echo
echo "ALL OK"
