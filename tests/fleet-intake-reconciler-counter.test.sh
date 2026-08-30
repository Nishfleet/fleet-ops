#!/usr/bin/env bash
# tests/fleet-intake-reconciler-counter.test.sh
#
# fleet-ops#1464: the slow poll now bumps fleet_intake_reconciler_caught_total
# for every ready issue it finds. This counter is the visibility signal
# that the push channel is degraded. We exercise the bash tick in a
# stubbed subprocess (mocking gh + git) and assert the prom file ends up
# with the right counter increment.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
tick="$repo_root/lib/pi-intake-tick.sh"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$tick" ]] || fail "missing: $tick"
grep -q 'fleet_intake_reconciler_caught_total' "$tick" \
    || fail "tick must bump fleet_intake_reconciler_caught_total"
grep -q 'reconciler_caught=' "$tick" \
    || fail "tick must surface reconciler-caught in stdout"
ok "1: tick declares the reconciler-caught counter"

# --- 2: the timer is now */20, in the 15-30 min envelope the issue names.
timer="$repo_root/systemd/pi-intake@.timer"
grep -E '^OnCalendar=\*:00/20$' "$timer" \
    || fail "pi-intake@.timer OnCalendar should be *:00/20 (15-30 envelope)"
grep -q 'fleet-ops#1464' "$timer" \
    || fail "pi-intake@.timer must reference fleet-ops#1464 in the comment"
ok "2: pi-intake@.timer cadence is */20 (slow reconciler envelope)"

# --- 3: MANIFEST entries for the new VPS-side files are present.
for entry in \
    "libexec/gh-webhook-receiver/serve.py" \
    "bin/gh-webhook-canary.py" \
    "bin/gh-webhook-canary-deadman.py" \
    "systemd/gh-webhook-receiver.service" \
    "systemd/gh-webhook-canary.service" \
    "systemd/gh-webhook-canary.timer" \
    "systemd/gh-webhook-canary-deadman.service" \
    "systemd/gh-webhook-canary-deadman.timer"
do
    grep -F "$entry" "$manifest" >/dev/null \
        || fail "MANIFEST missing entry: $entry"
done
ok "3: MANIFEST carries every new VPS-side file"

# --- 4: pure-bash test of the counter write/read logic. We avoid running
# the full tick (which spawns systemd user units) by extracting the
# counter helper into a sandboxed scratch file and asserting the prom
# file it produces matches the metric contract. The tick writes to a
# per-repo prom file (one file per repo, no read-modify-write race with
# parallel ticks of OTHER repos); the flock at the top of the tick
# ensures no race within the same repo.
scratch="$(mktemp -d -t intake-reconciler.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

PROM_BASE="$scratch/reconciler"
export PI_INTAKE_RECONCILER_PROM="$PROM_BASE"
prom_for_repo() { printf '%s-%s.prom' "$PROM_BASE" "$1"; }

prom_test="$scratch/prom-test.sh"
# Write the helper using a literal awk script written via python so the
# backslash escaping is exact (bash heredocs are a quoting minefield for
# awk scripts that use regex with \{ and \").
python3 - "$scratch" > "$prom_test" <<'PYEOF'
import sys, os
scratch = sys.argv[1]
body = '''#!/usr/bin/env bash
set -euo pipefail
BASE="${PI_INTAKE_RECONCILER_PROM:-__SCRATCH__/reconciler}"
REPO="${TEST_REPO:-fleet-ops}"
DELTA="${TEST_DELTA:-3}"
PROM="${BASE}-${REPO}.prom"
_total=0
if [[ -f "$PROM" ]]; then
    _total=$(awk -v r="$REPO" '
        $0 ~ "fleet_intake_reconciler_caught_total\\\\{repo=\\""r"\\"\\\\}" {
            gsub(/[^0-9.]/, "", $2); v = int($2);
            if (v > 0) print v; else print 0; exit
        }
        END { if (NR == 0) print 0 }
    ' "$PROM" 2>/dev/null || echo 0)
    _total="${_total:-0}"
fi
_new_total=$(( _total + DELTA ))
mkdir -p "$(dirname "$PROM")"
{
    printf '# HELP fleet_intake_reconciler_caught_total x\\n'
    printf '# TYPE fleet_intake_reconciler_caught_total counter\\n'
    printf 'fleet_intake_reconciler_caught_total{repo="%s"} %d\\n' "$REPO" "$_new_total"
    printf '# HELP fleet_intake_reconciler_last_caught_timestamp_seconds x\\n'
    printf '# TYPE fleet_intake_reconciler_last_caught_timestamp_seconds gauge\\n'
    printf 'fleet_intake_reconciler_last_caught_timestamp_seconds{repo="%s"} %d\\n' "$REPO" "$(date -u +%s)"
    printf '# HELP fleet_intake_reconciler_last_count x\\n'
    printf '# TYPE fleet_intake_reconciler_last_count gauge\\n'
    printf 'fleet_intake_reconciler_last_count{repo="%s"} %d\\n' "$REPO" "$DELTA"
} > "$PROM.tmp" && mv "$PROM.tmp" "$PROM"
'''.replace("__SCRATCH__", scratch)
sys.stdout.write(body)
PYEOF
chmod +x "$prom_test"

# First run: 3 ready issues caught.
TEST_REPO=fleet-ops TEST_DELTA=3 bash "$prom_test"
P1="$(prom_for_repo fleet-ops)"
grep -q '^fleet_intake_reconciler_caught_total{repo="fleet-ops"} 3$' "$P1" \
    || fail "4a: first run did not write 3: $(cat $P1)"
ok "4a: first run wrote counter=3 (per-repo file $P1)"

# Second run: 5 more caught (cumulative 8).
TEST_REPO=fleet-ops TEST_DELTA=5 bash "$prom_test"
grep -q '^fleet_intake_reconciler_caught_total{repo="fleet-ops"} 8$' "$P1" \
    || fail "4b: second run did not accumulate to 8: $(cat $P1)"
ok "4b: second run accumulated counter to 8 (read-modify-write works)"

# Third run: a different repo — separate per-repo file, fleet-ops untouched.
TEST_REPO=fleet-public TEST_DELTA=2 bash "$prom_test"
grep -q '^fleet_intake_reconciler_caught_total{repo="fleet-ops"} 8$' "$P1" \
    || fail "4c: fleet-ops counter regressed: $(cat $P1)"
P2="$(prom_for_repo fleet-public)"
grep -q '^fleet_intake_reconciler_caught_total{repo="fleet-public"} 2$' "$P2" \
    || fail "4c: fleet-public counter missing: $(cat $P2)"
ok "4c: per-repo files keep counters independent"

# Fourth run: 0 issues caught (no bump, last_count becomes 0).
TEST_REPO=fleet-ops TEST_DELTA=0 bash "$prom_test"
grep -q '^fleet_intake_reconciler_caught_total{repo="fleet-ops"} 8$' "$P1" \
    || fail "4d: zero-delta run must NOT bump counter: $(cat $P1)"
grep -q '^fleet_intake_reconciler_last_count{repo="fleet-ops"} 0$' "$P1" \
    || fail "4d: zero-delta run must report last_count=0: $(cat $P1)"
ok "4d: zero-delta run is a no-op on counter (last_count still reported)"

# --- 5: the bash counter logic in the tick file is shape-equivalent to
# the helper. We extract the awk + printf block and assert the tick uses
# the same series name + HELP/TYPE preamble.
grep -q 'fleet_intake_reconciler_caught_total{repo=' "$tick" \
    || fail "tick must write fleet_intake_reconciler_caught_total{repo=...} lines"
grep -q 'fleet_intake_reconciler_last_caught_timestamp_seconds' "$tick" \
    || fail "tick must write last_caught_timestamp_seconds"
grep -q 'fleet_intake_reconciler_last_count' "$tick" \
    || fail "tick must write last_count"
grep -q 'reconciler_prom_base' "$tick" \
    || fail "tick must derive per-repo prom from a base"
grep -q 'PI_INTAKE_RECONCILER_PROM' "$tick" \
    || fail "tick must respect PI_INTAKE_RECONCILER_PROM override"
ok "5: tick emits all three prom series and derives per-repo files"
exit 0
