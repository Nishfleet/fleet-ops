#!/usr/bin/env bash
# tests/pi-detached-deadman.test.sh
#
# Proves the pi-systemd-run ExecStopPost dead-man verdict hook
# (fleet-ops#4266):
#   1. not armed (no PI_DEADMAN_DISPATCH) -> no-op, exit 0
#   2. clean stop WITHOUT the deliverable (Result=success) -> died series +
#      STOP-REASON writer call (reason=unit-stopped-without-deliverable) +
#      who-stopped line
#   3. non-clean failure (Result=exit-code) -> died series, NO STOP-REASON
#      writer call (the OnFailure rail owns that case; no double summons)
#   4. success with deliverable present -> no died series, stale series for
#      the same unit cleared
#   5. success without deliverable -> STILL a death (exit 0 is not consent)
#   6. --clear <unit> clears the unit's died series by unit NAME (empty
#      dispatch) and does not touch other units
#   7. dry-run prints the verdict and writes nothing
#
# All hermetic: fake escalation writer, fake who-stopped, scratch textfile,
# KEYSTONE_HC_ENV pointing at an unset-URL env file so ping fail-opens
# silent (circle-marked in the job only). Hosted by ci.yml directly.
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
esc_log="$scratch/esc.log"

# Fake STOP-REASON writer: record calls, never write a real unit-escalation.
cat >"$scratch/unit-esc" <<EOF
#!/usr/bin/env bash
echo "unit=\$1 reason=\${UNIT_ESCALATION_REASON:-} source=\${UNIT_ESCALATION_SOURCE:-}" >>"$esc_log"
EOF
chmod +x "$scratch/unit-esc"

# Fake who-stopped: canned audit line.
cat >"$scratch/whostopped" <<'EOF'
#!/usr/bin/env bash
echo "ausearch line for $1"
EOF
chmod +x "$scratch/whostopped"

# Empty HC env -> keystone-hc-ping detached fail-opens silent.
envfile="$scratch/hc.env"
: >"$envfile"

common=(PI_DEADMAN_TEXTFILE="$tf"
        PI_DEADMAN_ESCALATION_BIN="$scratch/unit-esc"
        PI_DEADMAN_WHOSTOPPED_BIN="$scratch/whostopped"
        KEYSTONE_HC_ENV="$envfile")

# --- 1. not armed ------------------------------------------------------------
out="$("$deadman" 2>&1)"
[[ -z "$out" ]] || fail "not-armed must be a pure no-op, got: $out"
ok "not armed (no dispatch id) is a no-op"

# --- 2. clean stop without deliverable ---------------------------------------
env "${common[@]}" PI_DEADMAN_DISPATCH=d1 PI_DEADMAN_UNIT=u-clean \
    PI_DEADMAN_CMDLINE="sleep 1" PI_DEADMAN_DEADLINE=90 \
    PI_DEADMAN_DELIVERABLE="$scratch/missing.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null || fail "dead-man must exit 0 on a death verdict"
grep -q 'fleet_detached_job_died{unit="u-clean",dispatch="d1"' "$tf" \
    || fail "clean-stop-without-deliverable must write the died series: $(cat "$tf")"
grep -q 'reason=unit-stopped-without-deliverable source=pi-detached-deadman' "$esc_log" \
    || fail "clean-stop death must call STOP-REASON writer with the #4266 reason: $(cat "$esc_log")"
ok "clean stop without deliverable: died series + STOP-REASON writer called"

# --- 3. non-clean failure: died series, no STOP-REASON writer ----------------
: >"$esc_log"
env "${common[@]}" PI_DEADMAN_DISPATCH=d2 PI_DEADMAN_UNIT=u-failed \
    PI_DEADMAN_CMDLINE="pi --print foo" SERVICE_RESULT=exit-code \
    "$deadman" 2>/dev/null || fail "exit-code death must exit 0"
grep -q 'unit="u-failed"' "$tf" || fail "exit-code death must write the died series"
[[ -s "$esc_log" ]] && fail "non-clean failure must NOT double-call the STOP-REASON writer: $(cat "$esc_log")"
ok "non-clean failure: died series only, OnFailure rail owns STOP-REASON"

# --- 4. success with deliverable present: no series, stale cleared -----------
touch "$scratch/real.md"
out="$(env "${common[@]}" PI_DEADMAN_DISPATCH=d3 PI_DEADMAN_UNIT=u-clean \
    PI_DEADMAN_CMDLINE="sleep 1" PI_DEADMAN_DEADLINE=90 \
    PI_DEADMAN_DELIVERABLE="$scratch/real.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null)" || fail "success verdict must exit 0"
grep -q 'unit="u-clean"' "$tf" && fail "success with deliverable must clear the stale died series"
grep -q 'unit="u-failed"' "$tf" || fail "success of one unit must not clear another unit's series"
ok "success with deliverable: stale series for THAT unit cleared, others kept"

# --- 5. success WITHOUT deliverable is still a death --------------------------
env "${common[@]}" PI_DEADMAN_DISPATCH=d4 PI_DEADMAN_UNIT=u-exit0 \
    PI_DEADMAN_CMDLINE="pi --print" PI_DEADMAN_DEADLINE=90 \
    PI_DEADMAN_DELIVERABLE="$scratch/never.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null || fail "exit-0-without-deliverable must exit 0"
grep -q 'unit="u-exit0"' "$tf" || fail "exit 0 without deliverable must be a death (the #4266 gap)"
ok "exit 0 without deliverable == death (the exact #4266 gap)"

# --- 6. --clear by unit name --------------------------------------------------
env "${common[@]}" "$deadman" --clear u-failed 2>/dev/null \
    || fail "--clear must exit 0"
grep -q 'unit="u-failed"' "$tf" && fail "--clear must remove the unit's died series"
grep -q 'unit="u-exit0"' "$tf" || fail "--clear of one unit must not clear other units"
ok "--clear removes exactly the named unit's series (empty dispatch)"

# --- 7. dry-run: verdict printed, nothing written -----------------------------
: >"$tf"; : >"$esc_log"
out="$(env "${common[@]}" PI_DEADMAN_DRYRUN=1 PI_DEADMAN_DISPATCH=d5 \
    PI_DEADMAN_UNIT=u-dry PI_DEADMAN_CMDLINE="pi --print" SERVICE_RESULT=success \
    PI_DEADMAN_DELIVERABLE="$scratch/x.md" "$deadman" 2>&1)"
printf '%s\n' "$out" | grep -q 'verdict=died' \
    || fail "dry-run must print the verdict: $out"
[[ -s "$tf" ]] && fail "dry-run must not write the textfile"
[[ -s "$esc_log" ]] && fail "dry-run must not call the STOP-REASON writer"
ok "dry-run prints verdict, writes nothing"

echo "PASS: pi-detached-deadman verdict matrix (7 cases)"