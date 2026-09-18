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
# All hermetic: scratch textfile + scratch dispatch
# ledger. (The keystone-hc-ping seam is gone: the detached healthchecks.io
# ping was deleted with that script in the 2026-09-18 glue sweep — its URL
# was never provisioned.) Hosted by ci.yml directly.
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



# Stub journalctl: cases feed the unit journal via JOURNAL_STUB_TEXT.
cat >"$scratch/journalctl-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${JOURNAL_STUB_TEXT:-}"
exit 0
EOF
chmod +x "$scratch/journalctl-stub"

# Hermetic unit-escalation-write stub (fleet-ops#5456): every success-variant
# death calls the escalation writer; the REAL one would write the LIVE
# $AGENT_STATE/STOP-REASON.json and fire the live stop-escalation.path
# mid-test (the #37-derived false-page class). The stub appends the SAME
# reason/source/unit line the real writer's journal line carries, so the
# assertions stay greppable while the test stays hermetic.
esc_log="$scratch/esc.log"
cat >"$scratch/esc-stub" <<'EOF'
#!/usr/bin/env bash
printf 'STOP-REASON: reason=%s source=%s unit=%s\n' \
    "${UNIT_ESCALATION_REASON:-}" "${UNIT_ESCALATION_SOURCE:-}" "${1:-}" \
    >> "${PI_DEADMAN_TEST_ESC_LOG:?}"
EOF
chmod +x "$scratch/esc-stub"

# Scratch dispatch ledger: the died verdict row lands here, never in the
# live agent-state file.
common=(PI_DEADMAN_TEXTFILE="$tf"
        FLEET_DISPATCH_LEDGER="$ledger"
        PI_DEADMAN_JOURNALCTL="$scratch/journalctl-stub"
        PI_DEADMAN_ESCALATION_BIN="$scratch/esc-stub"
        PI_DEADMAN_TEST_ESC_LOG="$esc_log"
        PI_VERDICT_LIVE_FETCH=0
        )

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
fcl_rc=0
out="$(env "${common[@]}" PI_DEADMAN_DISPATCH=77777777-7777-7777-7777-777777777777 \
    PI_DEADMAN_UNIT=u-falseclaim PI_DEADMAN_CMDLINE="pi --print" \
    PI_DEADMAN_WORKDIR="$claim_repo" \
    PI_DEADMAN_DELIVERABLE="$scratch/false-claim.md" SERVICE_RESULT=success \
    "$deadman" 2>&1)" || fcl_rc=$?
# fleet-ops#5456-F: a false LIVE claim IS a died unit — the dead-man fails
# the unit (exit 1) so OnFailure fires; the packet-verdict rejects the claim
# (fleet-ops#5786). Exit 0 would be the silent death the contract closes.
[[ $fcl_rc -eq 1 ]] || fail "false-claim verdict must exit 1 (died, #5456-F), got $fcl_rc: $out"
grep -q 'unit="u-falseclaim"' "$tf" \
    || fail "a false LIVE claim must write the died series: $(cat "$tf")"
# Glue sweep 2026-09-18: the STOP-REASON escalation write was deleted with the
# escalation tower. The load-bearing signals below (died series, exit 1,
# DEPLOY-CLAIM-FALSE loud, dispatch-ledger verdict) are unchanged.
printf '%s\n' "$out" | grep -q 'reason=unit-false-live-claim' \
    || fail "false claim must name reason=unit-false-live-claim: $out"
printf '%s\n' "$out" | grep -q 'DEPLOY-CLAIM-FALSE' \
    || fail "false claim must loud DEPLOY-CLAIM-FALSE: $out"
grep -q '"unit":"u-falseclaim".*"verdict":"false-live-claim"' "$ledger" \
    || fail "false claim must write verdict=false-live-claim to the dispatch ledger (fleet-ops#6832: an empty verdict= hid the death class): $(cat "$ledger")"
printf '%s\n' "$out" | grep -q 'verdict=false-live-claim' \
    || fail "died log line must name the verdict kind: $out"
ok "deliverable claiming LIVE without a merged SHA -> died + unit-false-live-claim (the 2026-09-12 incident)"

# 9b. Same claim in the unit journal (not the deliverable file) still dies.
printf 'deliverable written\n' >"$scratch/clean.md"
jb_rc=0
env "${common[@]}" PI_DEADMAN_DISPATCH=88888888-8888-8888-8888-888888888888 \
    PI_DEADMAN_UNIT=u-journalclaim PI_DEADMAN_CMDLINE="pi --print" \
    PI_DEADMAN_WORKDIR="$claim_repo" \
    PI_DEADMAN_DELIVERABLE="$scratch/clean.md" SERVICE_RESULT=success \
    JOURNAL_STUB_TEXT="- **Live on this host immediately**: deploy-clone is checked out on the fix branch" \
    "$deadman" 2>/dev/null || jb_rc=$?
[[ $jb_rc -eq 1 ]] || fail "journal-claim verdict must exit 1 (died, #5456-F), got $jb_rc"
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
bc_rc=0
env "${common[@]}" PI_DEADMAN_DISPATCH=abababab-abab-abab-abab-abababababab \
    PI_DEADMAN_UNIT=u-branchclaim PI_DEADMAN_CMDLINE="pi --print" \
    PI_DEADMAN_WORKDIR="$claim_repo" \
    PI_DEADMAN_DELIVERABLE="$scratch/branch-claim.md" SERVICE_RESULT=success \
    "$deadman" 2>/dev/null || bc_rc=$?
[[ $bc_rc -eq 1 ]] || fail "branch-claim verdict must exit 1 (died, #5456-F), got $bc_rc"
grep -q 'unit="u-branchclaim"' "$tf" \
    || fail "a LIVE claim citing an unmerged branch SHA must die"
ok "LIVE claim citing an unmerged branch SHA -> died (PR open, not live)"

# --- 10. bounce attribution: error class + owning unit (fleet-ops#5799) -------
# The 2026-09-12 incident: a deliberate stop+start of fleet-litellm-proxy (the
# shared text-lane organ) killed two in-flight runs with a bare
# "Connection error." and the dead-man recorded only the VICTIM — the
# DetachedJobDied repair packet blamed the worker, and a salvage note even
# inherited a wrong 401 root cause. The dead-man must classify the provider
# error class from the journal it ALREADY reads and, for connection-class
# deaths, attribute the cause when the proxy organ completed a stop+start
# inside the victim's window. Both ride the EXISTING gauge series as extra
# labels and the STOP-REASON rail carries a bounce: line. Hermetic: the
# journalctl stub answers BOTH the unit-journal and the proxy-journal reads
# with the same canned text — which is exactly what makes the attribution
# provable: the canned systemd lines are both the victim's start-timestamp
# source and the proxy's Stopping/Started evidence.
FIX10='2026-09-13T10:29:46+0530: Stopping fleet-litellm-proxy.service
2026-09-13T10:29:49+0530: Started fleet-litellm-proxy.service
2026-09-13T10:30:15+0530: pi[2299775]: Connection error.'

# 10a. Dry-run first: the verdict prints WITH the attribution, writes nothing.
out="$(env "${common[@]}" PI_DEADMAN_DRYRUN=1 PI_DEADMAN_DISPATCH=10101010-1010-1010-1010-101010101010 \
    PI_DEADMAN_UNIT=u-bounce PI_DEADMAN_CMDLINE="pi --print" SERVICE_RESULT=success \
    PI_DEADMAN_DELIVERABLE="$scratch/missing-bounce.md" JOURNAL_STUB_TEXT="$FIX10" \
    "$deadman" 2>&1)"
printf '%s\n' "$out" | grep -q 'verdict=died unit=u-bounce' \
    || fail "dry-run must still print the verdict: $out"
printf '%s\n' "$out" | grep -q 'bounce: error_class=connection cause_unit=fleet-litellm-proxy (fleet-ops#5799)' \
    || fail "dry-run must print the bounce attribution: $out"
grep -q 'u-bounce' "$tf" && fail "dry-run must not write the attribution series: $(cat "$tf")"
ok "dry-run: connection-class death prints error_class + cause_unit, writes nothing"

# 10b. Real died path: the gauge series carries both labels and the bounce:
# line reaches stderr (the journal -> STOP-REASON detail -> repair-packet
# rail), while the #4266 STOP-REASON reason is untouched.
: >"$esc_log"
if out="$(env "${common[@]}" PI_DEADMAN_DISPATCH=10101010-1010-1010-1010-101010101010 \
    PI_DEADMAN_UNIT=u-bounce PI_DEADMAN_CMDLINE="pi --print" SERVICE_RESULT=success \
    PI_DEADMAN_DELIVERABLE="$scratch/missing-bounce.md" JOURNAL_STUB_TEXT="$FIX10" \
    "$deadman" 2>&1)"; then fail "bounce-attribution death must exit 1 (died verdict flips the unit failed, fleet-ops#5456)"; fi
grep -q 'error_class="connection",cause_unit="fleet-litellm-proxy"' "$tf" \
    || fail "connection+bounce death must carry BOTH attribution labels: $(cat "$tf")"
printf '%s\n' "$out" | grep -q 'bounce: error_class=connection cause_unit=fleet-litellm-proxy (fleet-ops#5799)' \
    || fail "the died path must send the bounce: line to stderr (STOP-REASON rail): $out"
printf '%s\n' "$out" | grep -q 'reason=unit-stopped-without-deliverable' \
    || fail "attribution must not disturb the #4266 clean-stop reason: $out"
ok "connection-class death + proxy stop+start: gauge labels + bounce: line, #4266 reason untouched"

# 10c. Connection-class death WITHOUT a proxy stop+start in the window:
# error_class=connection, cause_unit stays EMPTY (honest attribution — the
# organ is only named when its own journal shows the bounce).
if out="$(env "${common[@]}" PI_DEADMAN_DISPATCH=10101010-1010-1010-1010-101010101011 \
    PI_DEADMAN_UNIT=u-nobounce PI_DEADMAN_CMDLINE="pi --print" SERVICE_RESULT=exit-code \
    JOURNAL_STUB_TEXT='2026-09-13T10:30:15+0530: pi[2299775]: Connection error.' \
    "$deadman" 2>/dev/null)"; then fail "connection-without-bounce death must exit 1 (died verdict, fleet-ops#5456)"; fi
grep -q 'error_class="connection",cause_unit=""' "$tf" \
    || fail "connection without a proxy stop+start must leave cause_unit empty: $(cat "$tf")"
ok "connection-class death WITHOUT a proxy bounce: cause_unit stays empty"

# 10d. 401-class death (the #5788 missing-key class the salvage notes wrongly
# blamed for the 2026-09-12 incident): classified, NO cause attribution.
if out="$(env "${common[@]}" PI_DEADMAN_DISPATCH=10101010-1010-1010-1010-101010101012 \
    PI_DEADMAN_UNIT=u-401 PI_DEADMAN_CMDLINE="pi --print" SERVICE_RESULT=exit-code \
    JOURNAL_STUB_TEXT='2026-09-13T11:00:01+0530: pi[1]: litellm 401.' \
    "$deadman" 2>/dev/null)"; then fail "401-class death must exit 1 (died verdict, fleet-ops#5456)"; fi
grep -q 'error_class="401",cause_unit=""' "$tf" \
    || fail "401-class death must classify: $(cat "$tf")"
ok "401-class death (the #5788 class) classifies without a bounce claim"

# 10e. No provider error found: BOTH labels empty — an honest miss, never a
# suppressed death (the verdict and the series are unchanged).
if out="$(env "${common[@]}" PI_DEADMAN_DISPATCH=10101010-1010-1010-1010-101010101013 \
    PI_DEADMAN_UNIT=u-noclass PI_DEADMAN_CMDLINE="pi --print" SERVICE_RESULT=exit-code \
    JOURNAL_STUB_TEXT='2026-09-13T11:00:01+0530: pi[1]: some other provider note.' \
    "$deadman" 2>/dev/null)"; then fail "no-class death must exit 1 (died verdict, fleet-ops#5456)"; fi
grep -q 'error_class="",cause_unit=""' "$tf" \
    || fail "no-provider-error death must leave both labels empty: $(cat "$tf")"
ok "no provider error in journal: both labels empty (honest miss, death still recorded)"


# 10g. A helper that prints NOTHING still gets the fallback — its remaining
# domain is a missing/silent helper, not an answered query.
cat >"$scratch/whostopped-silent" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$scratch/whostopped-silent"
if out="$(env "${common[@]}" PI_DEADMAN_WHOSTOPPED_BIN="$scratch/whostopped-silent" \
    PI_DEADMAN_DISPATCH=10101010-1010-1010-1010-101010101015 \
    PI_DEADMAN_UNIT=u-silent PI_DEADMAN_CMDLINE="pi --print" SERVICE_RESULT=exit-code \
    "$deadman" 2>&1)"; then fail "silent-helper death must exit 1 (died verdict, fleet-ops#5456)"; fi
printf '%s\n' "$out" | grep -q 'who-stopped: no audit trail (auditd not installed?)' \
    || fail "a silent helper must still fall back to the no-trail note: $out"
ok "silent helper still gets the no-audit-trail fallback"

echo "PASS: pi-detached-deadman verdict matrix (23 cases)"