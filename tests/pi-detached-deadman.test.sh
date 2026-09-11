#!/usr/bin/env bash
# tests/pi-detached-deadman.test.sh
#
# Proves the pi-systemd-run ExecStopPost dead-man verdict hook
# (fleet-ops#4266, exit contract revised by fleet-ops#5456):
#   1. not armed (no PI_DEADMAN_DISPATCH) -> no-op, exit 0
#   2. clean stop WITHOUT the deliverable (Result=success) -> died series +
#      dispatch-ledger verdict row (verdict=no-deliverable) + EXIT 1 so the
#      unit lands `failed` and OnFailure carries the death to the dispatcher
#      (the #5456 change: ExecStopPost nonzero marks the unit failed —
#      clean stops used to stay Result=success and die silently)
#   3. non-clean failure (Result=exit-code) -> died series + verdict row
#      (verdict=died:exit-code) + exit 1
#   4. success with deliverable present -> no died series, stale series for
#      the same unit cleared, exit 0
#   5. success without deliverable -> STILL a death (exit 0 is not consent);
#      an EMPTY deliverable file is a death too
#   5b. non-UUID dispatch (placeholder like "x") -> NO died series written,
#      rejection logged (fleet-ops#4777 test-pollution guard); success-clear
#      path unaffected
#   6. --clear <unit> clears the unit's died series by unit NAME (empty
#      dispatch) and does not touch other units
#   7. dry-run prints the verdict and writes nothing, exit 0
#   8. repeated write/clear cycles never duplicate the HELP/TYPE header
#      (node_exporter rejects a textfile with a second HELP line) and the
#      file stays 0644 so node_exporter (User=prometheus) can read it
#
# All hermetic: fake who-stopped, scratch textfile + scratch dispatch
# ledger, KEYSTONE_HC_ENV pointing at an unset-URL env file so ping
# fail-opens silent (circle-marked in the job only). Hosted by ci.yml
# directly.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
deadman="$repo_root/bin/pi-detached-deadman"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$deadman" ]] || fail "not executable: $deadman"
bash -n "$deadman" || fail "syntax: $deadman"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
tf="$scratch/fleet-detached.prom"
ledger="$scratch/dispatch-ledger.jsonl"

# Fake who-stopped: canned audit line.
cat >"$scratch/whostopped" <<'EOF'
#!/usr/bin/env bash
echo "ausearch line for $1"
EOF
chmod +x "$scratch/whostopped"

# Empty HC env -> keystone-hc-ping detached fail-opens silent.
envfile="$scratch/hc.env"
: >"$envfile"

# Scratch dispatch ledger: the died verdict row lands here, never in the
# live agent-state file.
common=(PI_DEADMAN_TEXTFILE="$tf"
        FLEET_DISPATCH_LEDGER="$ledger"
        PI_DEADMAN_WHOSTOPPED_BIN="$scratch/whostopped"
        KEYSTONE_HC_ENV="$envfile")

# --- 1. not armed ------------------------------------------------------------
out="$("$deadman" 2>&1)"
[[ -z "$out" ]] || fail "not-armed must be a pure no-op, got: $out"
ok "not armed (no dispatch id) is a no-op"

# --- 2. clean stop without deliverable -> exit 1 (unit must land failed) ---
if env "${common[@]}" PI_DEADMAN_DISPATCH=11111111-1111-1111-1111-111111111111 PI_DEADMAN_UNIT=u-clean \
    PI_DEADMAN_CMDLINE="sleep 1" PI_DEADMAN_DEADLINE=90 \
    PI_DEADMAN_DELIVERABLE="$scratch/missing.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null; then fail "clean-stop death must exit 1 so the unit lands failed"; fi
grep -q 'fleet_detached_job_died{unit="u-clean",dispatch="11111111-1111-1111-1111-111111111111"' "$tf" \
    || fail "clean-stop-without-deliverable must write the died series: $(cat "$tf")"
# The verdict row is the dispatcher's resume/dispatch input.
grep -q '"unit":"u-clean".*"verdict":"no-deliverable"' "$ledger" \
    || fail "clean-stop death must write verdict=no-deliverable to the dispatch ledger: $(cat "$ledger")"
ok "clean stop without deliverable: died series + verdict=no-deliverable + exit 1"

# --- 3. non-clean failure: died series + verdict row + exit 1 ----------------
if env "${common[@]}" PI_DEADMAN_DISPATCH=22222222-2222-2222-2222-222222222222 PI_DEADMAN_UNIT=u-failed \
    PI_DEADMAN_CMDLINE="pi --print foo" SERVICE_RESULT=exit-code \
    "$deadman" 2>/dev/null; then fail "exit-code death must exit 1"; fi
grep -q 'unit="u-failed"' "$tf" || fail "exit-code death must write the died series"
grep -q '"unit":"u-failed".*"verdict":"died:exit-code"' "$ledger" \
    || fail "non-clean death must write a verdict row: $(cat "$ledger")"
ok "non-clean failure: died series + verdict row + exit 1"

# --- 4. success with deliverable present: no series, stale cleared -----------
printf "ok\\n" > "$scratch/real.md"
out="$(env "${common[@]}" PI_DEADMAN_DISPATCH=33333333-3333-3333-3333-333333333333 PI_DEADMAN_UNIT=u-clean \
    PI_DEADMAN_CMDLINE="sleep 1" PI_DEADMAN_DEADLINE=90 \
    PI_DEADMAN_DELIVERABLE="$scratch/real.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null)" || fail "success verdict must exit 0"
grep -q 'unit="u-clean"' "$tf" && fail "success with deliverable must clear the stale died series"
grep -q 'unit="u-failed"' "$tf" || fail "success of one unit must not clear another unit's series"
ok "success with deliverable: stale series for THAT unit cleared, others kept"

# --- 5. success WITHOUT deliverable is still a death --------------------------
if env "${common[@]}" PI_DEADMAN_DISPATCH=44444444-4444-4444-4444-444444444444 PI_DEADMAN_UNIT=u-exit0 \
    PI_DEADMAN_CMDLINE="pi --print" PI_DEADMAN_DEADLINE=90 \
    PI_DEADMAN_DELIVERABLE="$scratch/never.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null; then fail "exit-0-without-deliverable must exit 1"; fi
grep -q 'unit="u-exit0"' "$tf" || fail "exit 0 without deliverable must be a death (the #4266 gap)"
ok "exit 0 without deliverable == death (the exact #4266 gap)"

# --- 5a. an EMPTY deliverable file is a death too ------------------------------
: >"$scratch/empty.md"
if env "${common[@]}" PI_DEADMAN_DISPATCH=45454545-4545-4545-4545-454545454545 PI_DEADMAN_UNIT=u-empty \
    PI_DEADMAN_CMDLINE="pi --print" PI_DEADMAN_DEADLINE=90 \
    PI_DEADMAN_DELIVERABLE="$scratch/empty.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null; then fail "empty deliverable must exit 1"; fi
grep -q '"unit":"u-empty".*"verdict":"no-deliverable"' "$ledger" \
    || fail "empty deliverable file must be a death (missing OR empty)"
ok "empty deliverable file == death (the -s check)"

# --- 5b. test-pollution guard: non-UUID dispatch writes NO died series --------
# Live regression (fleet-ops#4777): a phantom `test-unit` / dispatch="x" series
# fired DetachedJobDied for 8h and polluted every repair packet. A DEATH write
# must refuse a non-UUID dispatch (placeholder, not a real pi-systemd-run run
# id) so a future test or manual run that forgets PI_DEADMAN_TEXTFILE cannot
# pollute the production alert. The refusal is logged to stderr and the
# success-clear / --clear paths (dispatch="") are unaffected.
log_out="$(env "${common[@]}" PI_DEADMAN_DISPATCH=x PI_DEADMAN_UNIT=u-testpollution \
    PI_DEADMAN_CMDLINE="pi --print" SERVICE_RESULT=exit-code \
    "$deadman" 2>&1)" && fail "non-UUID dispatch death must exit 1"
grep -q 'unit="u-testpollution"' "$tf" \
    && fail "non-UUID dispatch must NOT write a died series: $(cat "$tf")"
printf '%s\n' "$log_out" | grep -q 'refusing death write: dispatch=x' \
    || fail "non-UUID dispatch must log the rejected dispatch: $log_out"
ok "non-UUID dispatch (x) writes no died series and logs the rejection (fleet-ops#4777)"

# The guard must not break the success-clear path: a real UUID death written
# earlier is still clearable by a success verdict for the same unit.
env "${common[@]}" PI_DEADMAN_DISPATCH=66666666-6666-6666-6666-666666666666 PI_DEADMAN_UNIT=u-clearok \
    PI_DEADMAN_CMDLINE="sleep 1" SERVICE_RESULT=exit-code \
    "$deadman" 2>/dev/null || true   # rc=1 IS the death contract now; the series is the assertion
grep -q 'unit="u-clearok"' "$tf" || fail "UUID death must still write the died series"
printf "ok\\n" > "$scratch/ok.md"
env "${common[@]}" PI_DEADMAN_DISPATCH=66666666-6666-6666-6666-666666666666 PI_DEADMAN_UNIT=u-clearok \
    PI_DEADMAN_CMDLINE="sleep 1" PI_DEADMAN_DELIVERABLE="$scratch/ok.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null || fail "success-clear must exit 0"
grep -q 'unit="u-clearok"' "$tf" && fail "success-clear must still remove the unit's died series"
ok "success-clear path unaffected by the dispatch-shape guard"

# --- 6. --clear by unit name --------------------------------------------------
env "${common[@]}" "$deadman" --clear u-failed 2>/dev/null \
    || fail "--clear must exit 0"
grep -q 'unit="u-failed"' "$tf" && fail "--clear must remove the unit's died series"
grep -q 'unit="u-exit0"' "$tf" || fail "--clear of one unit must not clear other units"
ok "--clear removes exactly the named unit's series (empty dispatch)"

# --- 7. dry-run: verdict printed, nothing written, exit 0 --------------------
: >"$tf"; : >"$ledger"
out="$(env "${common[@]}" PI_DEADMAN_DRYRUN=1 PI_DEADMAN_DISPATCH=55555555-5555-5555-5555-555555555555 \
    PI_DEADMAN_UNIT=u-dry PI_DEADMAN_CMDLINE="pi --print" SERVICE_RESULT=success \
    PI_DEADMAN_DELIVERABLE="$scratch/x.md" "$deadman" 2>&1)"
printf '%s\n' "$out" | grep -q 'verdict=died' \
    || fail "dry-run must print the verdict: $out"
[[ -s "$tf" ]] && fail "dry-run must not write the textfile"
[[ -s "$ledger" ]] && fail "dry-run must not write the ledger"
ok "dry-run prints verdict, writes nothing"

# --- 8. repeated writes never accumulate the HELP/TYPE header -----------------
# Live regression (fleet-ops#4266): the read-modify-write kept the previous
# content's header lines and prepended a fresh pair on every save, so the
# production textfile reached 27 HELP lines and node_exporter rejected the
# whole file ("second HELP line for metric name") — DetachedJobDied could
# never fire. Five write+clear cycles must leave exactly one pair.
: >"$tf"
for i in 1 2 3 4 5; do
    env "${common[@]}" PI_DEADMAN_DISPATCH="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa$i" PI_DEADMAN_UNIT="u-hdr$i" \
        PI_DEADMAN_CMDLINE="sleep 1" SERVICE_RESULT=exit-code \
        "$deadman" 2>/dev/null && fail "header-cycle write $i is a death -> exit 1"
    env "${common[@]}" "$deadman" --clear "u-hdr$i" 2>/dev/null \
        || fail "header-cycle clear $i must exit 0"
done
help_lines=$(grep -c '^# HELP fleet_detached_job_died' "$tf" || true)
type_lines=$(grep -c '^# TYPE fleet_detached_job_died' "$tf" || true)
[[ "$help_lines" == "1" ]] \
    || fail "10 writes must leave exactly one HELP line, got $help_lines: $(cat "$tf")"
[[ "$type_lines" == "1" ]] \
    || fail "10 writes must leave exactly one TYPE line, got $type_lines"
ok "10 write/clear cycles leave one HELP/TYPE pair (no header accumulation)"

# node_exporter runs as User=prometheus: a textfile it cannot read sets
# node_textfile_scrape_error=1 and the series never reaches Prometheus, which
# silently disarms the alert. mkstemp's default 0600 did exactly that live.
mode=$(stat -c '%a' "$tf")
[[ "$mode" == "644" ]] \
    || fail "textfile must be world-readable for node_exporter (User=prometheus), got mode $mode"
ok "textfile is written 0644 so node_exporter can read it"

if command -v promtool >/dev/null 2>&1; then
    promtool check metrics <"$tf" >/dev/null 2>&1 \
        || fail "textfile must parse as Prometheus text format after repeated writes"
    ok "promtool parses the repeatedly-written textfile"
else
    echo "SKIP: promtool not installed (CI runner) — header-count assertion only"
fi


# fleet-ops#4675: systemd sets SERVICE_RESULT only on ExecStopPost. A live
# unit's child that runs this binary by hand inherits PI_DEADMAN_* with
# SERVICE_RESULT unset; before the guard that counted as a death and
# cascaded DetachedJobDied onto healthy repair units (live 2026-09-09).
rm -f "$tf"
env --unset=SERVICE_RESULT "${common[@]}" PI_DEADMAN_DISPATCH=dcli PI_DEADMAN_UNIT=u-cli \
    PI_DEADMAN_CMDLINE="sleep 1" "$deadman" --help >/dev/null 2>&1 \
    || fail "CLI --help must exit 0"
[[ ! -s "$tf" ]] || fail "CLI --help must not write a death metric: $(cat "$tf")"
ok "CLI --help with inherited PI_DEADMAN_* is not a death (fleet-ops#4675)"

rm -f "$tf"
env --unset=SERVICE_RESULT "${common[@]}" PI_DEADMAN_DISPATCH=dcli2 PI_DEADMAN_UNIT=u-cli2 \
    PI_DEADMAN_CMDLINE="sleep 1" "$deadman" >/dev/null 2>&1 \
    || fail "bare CLI call must exit 0"
[[ ! -s "$tf" ]] || fail "bare CLI call (SERVICE_RESULT unset) must not write a death metric"
ok "bare CLI call with SERVICE_RESULT unset is not a death (fleet-ops#4675)"

echo "PASS: pi-detached-deadman verdict matrix (12 cases)"