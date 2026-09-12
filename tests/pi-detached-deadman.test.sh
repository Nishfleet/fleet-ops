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
#   5b. non-UUID dispatch (placeholder like "x") -> NO died series written,
#      rejection logged (fleet-ops#4777 test-pollution guard); success-clear
#      path unaffected
#   6. --clear <unit> clears the unit's died series by unit NAME (empty
#      dispatch) and does not touch other units
#   7. dry-run prints the verdict and writes nothing
#   8. repeated write/clear cycles never duplicate the HELP/TYPE header
#      (node_exporter rejects a textfile with a second HELP line) and the
#      file stays 0644 so node_exporter (User=prometheus) can read it
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

# Stub journalctl: cases feed the unit journal via JOURNAL_STUB_TEXT.
cat >"$scratch/journalctl-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${JOURNAL_STUB_TEXT:-}"
exit 0
EOF
chmod +x "$scratch/journalctl-stub"

common=(PI_DEADMAN_TEXTFILE="$tf"
        PI_DEADMAN_ESCALATION_BIN="$scratch/unit-esc"
        PI_DEADMAN_WHOSTOPPED_BIN="$scratch/whostopped"
        PI_DEADMAN_JOURNALCTL="$scratch/journalctl-stub"
        PI_VERDICT_LIVE_FETCH=0
        KEYSTONE_HC_ENV="$envfile")

# --- 1. not armed ------------------------------------------------------------
out="$("$deadman" 2>&1)"
[[ -z "$out" ]] || fail "not-armed must be a pure no-op, got: $out"
ok "not armed (no dispatch id) is a no-op"

# --- 2. clean stop without deliverable ---------------------------------------
env "${common[@]}" PI_DEADMAN_DISPATCH=11111111-1111-1111-1111-111111111111 PI_DEADMAN_UNIT=u-clean \
    PI_DEADMAN_CMDLINE="sleep 1" PI_DEADMAN_DEADLINE=90 \
    PI_DEADMAN_DELIVERABLE="$scratch/missing.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null || fail "dead-man must exit 0 on a death verdict"
grep -q 'fleet_detached_job_died{unit="u-clean",dispatch="11111111-1111-1111-1111-111111111111"' "$tf" \
    || fail "clean-stop-without-deliverable must write the died series: $(cat "$tf")"
grep -q 'reason=unit-stopped-without-deliverable source=pi-detached-deadman' "$esc_log" \
    || fail "clean-stop death must call STOP-REASON writer with the #4266 reason: $(cat "$esc_log")"
ok "clean stop without deliverable: died series + STOP-REASON writer called"

# --- 3. non-clean failure: died series, no STOP-REASON writer ----------------
: >"$esc_log"
env "${common[@]}" PI_DEADMAN_DISPATCH=22222222-2222-2222-2222-222222222222 PI_DEADMAN_UNIT=u-failed \
    PI_DEADMAN_CMDLINE="pi --print foo" SERVICE_RESULT=exit-code \
    "$deadman" 2>/dev/null || fail "exit-code death must exit 0"
grep -q 'unit="u-failed"' "$tf" || fail "exit-code death must write the died series"
[[ -s "$esc_log" ]] && fail "non-clean failure must NOT double-call the STOP-REASON writer: $(cat "$esc_log")"
ok "non-clean failure: died series only, OnFailure rail owns STOP-REASON"

# --- 4. success with deliverable present: no series, stale cleared -----------
touch "$scratch/real.md"
out="$(env "${common[@]}" PI_DEADMAN_DISPATCH=33333333-3333-3333-3333-333333333333 PI_DEADMAN_UNIT=u-clean \
    PI_DEADMAN_CMDLINE="sleep 1" PI_DEADMAN_DEADLINE=90 \
    PI_DEADMAN_DELIVERABLE="$scratch/real.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null)" || fail "success verdict must exit 0"
grep -q 'unit="u-clean"' "$tf" && fail "success with deliverable must clear the stale died series"
grep -q 'unit="u-failed"' "$tf" || fail "success of one unit must not clear another unit's series"
ok "success with deliverable: stale series for THAT unit cleared, others kept"

# --- 5. success WITHOUT deliverable is still a death --------------------------
env "${common[@]}" PI_DEADMAN_DISPATCH=44444444-4444-4444-4444-444444444444 PI_DEADMAN_UNIT=u-exit0 \
    PI_DEADMAN_CMDLINE="pi --print" PI_DEADMAN_DEADLINE=90 \
    PI_DEADMAN_DELIVERABLE="$scratch/never.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null || fail "exit-0-without-deliverable must exit 0"
grep -q 'unit="u-exit0"' "$tf" || fail "exit 0 without deliverable must be a death (the #4266 gap)"
ok "exit 0 without deliverable == death (the exact #4266 gap)"

# --- 5b. test-pollution guard: non-UUID dispatch writes NO died series --------
# Live regression (fleet-ops#4777): a phantom `test-unit` / dispatch="x" series
# fired DetachedJobDied for 8h and polluted every repair packet. A DEATH write
# must refuse a non-UUID dispatch (placeholder, not a real pi-systemd-run run
# id) so a future test or manual run that forgets PI_DEADMAN_TEXTFILE cannot
# pollute the production alert. The refusal is logged to stderr and the
# success-clear / --clear paths (dispatch="") are unaffected.
log_out="$(env "${common[@]}" PI_DEADMAN_DISPATCH=x PI_DEADMAN_UNIT=u-testpollution \
    PI_DEADMAN_CMDLINE="pi --print" SERVICE_RESULT=exit-code \
    "$deadman" 2>&1)" || fail "non-UUID dispatch death must exit 0"
grep -q 'unit="u-testpollution"' "$tf" \
    && fail "non-UUID dispatch must NOT write a died series: $(cat "$tf")"
printf '%s\n' "$log_out" | grep -q 'refusing death write: dispatch=x' \
    || fail "non-UUID dispatch must log the rejected dispatch: $log_out"
ok "non-UUID dispatch (x) writes no died series and logs the rejection (fleet-ops#4777)"

# The guard must not break the success-clear path: a real UUID death written
# earlier is still clearable by a success verdict for the same unit.
env "${common[@]}" PI_DEADMAN_DISPATCH=66666666-6666-6666-6666-666666666666 PI_DEADMAN_UNIT=u-clearok \
    PI_DEADMAN_CMDLINE="sleep 1" SERVICE_RESULT=exit-code \
    "$deadman" 2>/dev/null || fail "UUID death must still write"
grep -q 'unit="u-clearok"' "$tf" || fail "UUID death must still write the died series"
touch "$scratch/ok.md"
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

# --- 7. dry-run: verdict printed, nothing written -----------------------------
: >"$tf"; : >"$esc_log"
out="$(env "${common[@]}" PI_DEADMAN_DRYRUN=1 PI_DEADMAN_DISPATCH=55555555-5555-5555-5555-555555555555 \
    PI_DEADMAN_UNIT=u-dry PI_DEADMAN_CMDLINE="pi --print" SERVICE_RESULT=success \
    PI_DEADMAN_DELIVERABLE="$scratch/x.md" "$deadman" 2>&1)"
printf '%s\n' "$out" | grep -q 'verdict=died' \
    || fail "dry-run must print the verdict: $out"
[[ -s "$tf" ]] && fail "dry-run must not write the textfile"
[[ -s "$esc_log" ]] && fail "dry-run must not call the STOP-REASON writer"
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
        "$deadman" 2>/dev/null || fail "header-cycle write $i must exit 0"
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

# --- 9. false LIVE-claim gate (fleet-ops#5786) --------------------------------
# The 2026-09-12 incident: an alert-repair unit exited 0 after reporting the
# GraphQL-drain gate "LIVE on this host" while its PR was still open with
# auto-merge off — the deploy clone was checked out on the fix branch, so the
# claim was false. The dead-man must turn that clean stop into a death:
# died series + STOP-REASON reason=unit-false-live-claim. Fixture repo:
# main_sha is merged (origin/main); branch_sha is still on the branch.
claim_repo="$scratch/claim-repo"
git init -q -b main "$claim_repo"
git -C "$claim_repo" config user.email t@t
git -C "$claim_repo" config user.name t
git -C "$claim_repo" commit -qm init --allow-empty
main_sha=$(git -C "$claim_repo" rev-parse HEAD)
git -C "$claim_repo" remote add origin "$claim_repo"
git -C "$claim_repo" fetch -q origin
git -C "$claim_repo" checkout -qb fix/issue-x
git -C "$claim_repo" commit -qm wip --allow-empty
branch_sha=$(git -C "$claim_repo" rev-parse HEAD)
git -C "$claim_repo" checkout -q main

# 9a. The verbatim incident deliverable text in the promised file.
printf '%s\n' "fix landed as PR https://github.com/Nishfleet/fleet-ops/pull/5762 (branch fix/issue-file-gh-rate-limit-gate) and LIVE on this host (deploy-clone checked out on the branch); after merge, return deploy-clone to main." \
    >"$scratch/false-claim.md"
: >"$esc_log"
out="$(env "${common[@]}" PI_DEADMAN_DISPATCH=77777777-7777-7777-7777-777777777777 \
    PI_DEADMAN_UNIT=u-falseclaim PI_DEADMAN_CMDLINE="pi --print" \
    PI_DEADMAN_WORKDIR="$claim_repo" \
    PI_DEADMAN_DELIVERABLE="$scratch/false-claim.md" SERVICE_RESULT=success \
    "$deadman" 2>&1)" || fail "false-claim verdict must exit 0"
grep -q 'unit="u-falseclaim"' "$tf" \
    || fail "a false LIVE claim must write the died series: $(cat "$tf")"
grep -q 'reason=unit-false-live-claim source=pi-detached-deadman' "$esc_log" \
    || fail "false claim must write STOP-REASON unit-false-live-claim: $(cat "$esc_log")"
printf '%s\n' "$out" | grep -q 'DEPLOY-CLAIM-FALSE' \
    || fail "false claim must loud DEPLOY-CLAIM-FALSE: $out"
ok "deliverable claiming LIVE without a merged SHA -> died + unit-false-live-claim (the 2026-09-12 incident)"

# 9b. Same claim in the unit journal (not the deliverable file) still dies.
printf 'deliverable written\n' >"$scratch/clean.md"
env "${common[@]}" PI_DEADMAN_DISPATCH=88888888-8888-8888-8888-888888888888 \
    PI_DEADMAN_UNIT=u-journalclaim PI_DEADMAN_CMDLINE="pi --print" \
    PI_DEADMAN_WORKDIR="$claim_repo" \
    PI_DEADMAN_DELIVERABLE="$scratch/clean.md" SERVICE_RESULT=success \
    JOURNAL_STUB_TEXT="- **Live on this host immediately**: deploy-clone is checked out on the fix branch" \
    "$deadman" 2>/dev/null || fail "journal-claim verdict must exit 0"
grep -q 'unit="u-journalclaim"' "$tf" \
    || fail "a journal-side false LIVE claim must write the died series"
ok "unit journal claiming live-on-host without a merged SHA -> died"

# 9c. A claim that cites the merged SHA on the same line is clean.
printf 'gate is LIVE on this host: %s is on origin/main\n' "$main_sha" \
    >"$scratch/true-claim.md"
env "${common[@]}" PI_DEADMAN_DISPATCH=99999999-9999-9999-9999-999999999999 \
    PI_DEADMAN_UNIT=u-trueclaim PI_DEADMAN_CMDLINE="pi --print" \
    PI_DEADMAN_WORKDIR="$claim_repo" \
    PI_DEADMAN_DELIVERABLE="$scratch/true-claim.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null || fail "true-claim verdict must exit 0"
if grep -q 'unit="u-trueclaim"' "$tf"; then
    fail "a LIVE claim citing a merged origin/main SHA must not die"
fi
ok "LIVE claim citing a merged origin/main SHA -> success (gate is not a blanket ban)"

# 9d. A claim citing the unmerged branch SHA still dies — the incident shape.
printf 'fix is DEPLOYED to production: %s\n' "$branch_sha" \
    >"$scratch/branch-claim.md"
env "${common[@]}" PI_DEADMAN_DISPATCH=abababab-abab-abab-abab-abababababab \
    PI_DEADMAN_UNIT=u-branchclaim PI_DEADMAN_CMDLINE="pi --print" \
    PI_DEADMAN_WORKDIR="$claim_repo" \
    PI_DEADMAN_DELIVERABLE="$scratch/branch-claim.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null || fail "branch-claim verdict must exit 0"
grep -q 'unit="u-branchclaim"' "$tf" \
    || fail "a LIVE claim citing an unmerged branch SHA must die"
ok "LIVE claim citing an unmerged branch SHA -> died (PR open, not live)"

echo "PASS: pi-detached-deadman verdict matrix (16 cases)"