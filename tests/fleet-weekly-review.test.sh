#!/usr/bin/env bash
# tests/fleet-weekly-review.test.sh
#
# Proves fleet-ops#1146 (Weekly Fleet Review) end-to-end against a
# stubbed seat and a stubbed pi:
#   (a) matrix rows for the two new ledger rules are enforced (the
#       canary covers the new content even before the live ledger
#       line appears in this checkout).
#   (b) MANIFEST ships the new bin/, lib/, prompts/, and units.
#   (c) install.sh enable --now the new timer (fleet-ops#183 class).
#   (d) timer shape: Named reason + OnCalendar Sunday 04:00 IST +
#       [Install] + WantedBy=timers.target.
#   (e) bin/fleet-weekly-review runs the three phases against a
#       fixture, the ratchet produces deterministic no-evidence moves
#       for every wired gate, and bin/fleet-quality-ratchet REJECTS a
#       loosening move without --loosen-with-decision <sha>.
#   (f) lib/quality-ratchet.py emits the ratchet ledger line atomically
#       and ACCEPTs a tightening move without a decision sha.
#   (g) nested CI host: rule-enforcement.test.sh nests this test so CI
#       cannot skip it without a workflow edit.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

bin_wfr="$repo_root/bin/fleet-weekly-review"
bin_ratchet="$repo_root/bin/fleet-quality-ratchet"
lib_ratchet="$repo_root/lib/quality-ratchet.py"
svc="$repo_root/systemd/fleet-weekly-review.service"
timer="$repo_root/systemd/fleet-weekly-review.timer"
prompt_research="$repo_root/prompts/weekly-review-research.md"
prompt_conference="$repo_root/prompts/weekly-review-conference.md"
prompt_ratchet="$repo_root/prompts/weekly-review-ratchet.md"
install_sh="$repo_root/install.sh"
manifest="$repo_root/MANIFEST"
matrix="$repo_root/config/rule-enforcement.json"

# (preflight) every file must exist
for f in "$bin_wfr" "$bin_ratchet" "$lib_ratchet" "$svc" "$timer" \
         "$prompt_research" "$prompt_conference" "$prompt_ratchet" \
         "$install_sh" "$manifest" "$matrix"; do
    [[ -f "$f" ]] || fail "missing: $f"
done
[[ -x "$bin_wfr" ]] || fail "not executable: $bin_wfr"
[[ -x "$bin_ratchet" ]] || fail "not executable: $bin_ratchet"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

# (a) matrix rows for the two new rules are enforced.
for src in \
    "decisions-ledger.md: 2026-08-27 | Weekly Fleet Review approved" \
    "decisions-ledger.md: 2026-08-27 | Quality ratchet (Nish)"
do
    status=$(jq -r --arg src "$src" '.rules[] | select(.source == $src) | .status' "$matrix")
    [[ "$status" == "enforced" ]] || fail "matrix must have $src as enforced, got ${status:-missing}"
    ok "matrix row for $src is enforced"
done

# (b) MANIFEST ships every new file.
for line in \
    "bin/fleet-weekly-review /home/nish/.local/bin/fleet-weekly-review" \
    "bin/fleet-quality-ratchet /home/nish/.local/bin/fleet-quality-ratchet" \
    "lib/quality-ratchet.py /home/nish/.local/lib/pi-packet/quality-ratchet.py" \
    "prompts/weekly-review-research.md /home/nish/.pi/agent/prompts/weekly-review-research.md" \
    "prompts/weekly-review-conference.md /home/nish/.pi/agent/prompts/weekly-review-conference.md" \
    "prompts/weekly-review-ratchet.md /home/nish/.pi/agent/prompts/weekly-review-ratchet.md" \
    "systemd/fleet-weekly-review.service /home/nish/.config/systemd/user/fleet-weekly-review.service" \
    "systemd/fleet-weekly-review.timer /home/nish/.config/systemd/user/fleet-weekly-review.timer"
do
    grep -Fxq "$line" "$manifest" || fail "MANIFEST missing: $line"
done
ok "(b) MANIFEST ships every Weekly Review file"

# (c) install.sh enable --now.
grep -Fq -- '"$SYSTEMCTL" --user enable --now fleet-weekly-review.timer' "$install_sh" \
    || fail "install.sh must enable --now fleet-weekly-review.timer"
ok "(c) install.sh enables the Weekly Review timer"

# (d) timer shape.
grep -q '^# Named reason:' "$timer" \
    || fail "timer must carry a Named reason"
grep -q '^OnCalendar=Sun \*\-\*\-\* 04:00:00 Asia/Kolkata$' "$timer" \
    || fail "timer must fire Sunday 04:00 IST"
grep -q '^\[Install\]$' "$timer" \
    || fail "timer must carry [Install]"
grep -q '^WantedBy=timers.target$' "$timer" \
    || fail "timer [Install] must WantedBy=timers.target"
grep -q '^Persistent=true$' "$timer" \
    || fail "timer must be Persistent so a missed Sunday still fires"
ok "(d) timer has Named reason, Sunday 04:00 IST, [Install]"

# (e) bin/fleet-weekly-review runs against a fixture.
scratch=$(mktemp -d -t fleet-weekly-review.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub seat-lib so pick_seat returns a fake seat.
stub_lib="$scratch/seat-lib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
ATTEMPTS_DIR="${ATTEMPTS_DIR:-/tmp/agent-cron-attempts-stub}"
mkdir -p "$ATTEMPTS_DIR"
seat_log() { :; }
task_weight() { echo "heavy"; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
pick_seat() {
    printf 'devin\tglm-5-2\n'
    return 0
}
EOF

# Fixture: a full six-lens findings JSON.
lens_findings="$scratch/lens-findings.json"
cat >"$lens_findings" <<'JSON'
{
  "lenses": {
    "throughput":    {"summary": "median 12 merges/day; within target.", "findings": []},
    "output_quality": {"summary": "sampled 6 PRs; 5 PASS, 1 PARTIAL.", "findings": []},
    "machinery":      {"summary": "no failed units; quotas healthy.", "findings": []},
    "truth_docs":     {"summary": "vault clean; no stale claims.", "findings": []},
    "outside_world":  {"summary": "no material frontier deltas this week.", "findings": []},
    "security":       {"summary": "no scope creep; secrets scan clean.", "findings": [], "boundary_notify": []}
  }
}
JSON

conference_out="$scratch/conference-out.json"
cat >"$conference_out" <<'JSON'
{"actions": [], "discards": [], "boundary_notify": [], "self_score": {"prior_week_actions_logged": 0, "prior_week_actions_landed": 0, "ratchet_state": "ok"}}
JSON

# Stub pi: just produces empty stdout; the orchestrator uses the fixture.
fake_pi="$scratch/pi"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_pi"

export WFR_STATE_DIR="$scratch/state"
export WFR_PI_BIN="$fake_pi"
export WFR_SEAT_LIB="$stub_lib"
export WFR_DECISIONS_LEDGER="$scratch/ledger.md"
export WFR_FAKE_NOW="2026-08-23T04:00:00Z"
export WFR_DRILL="1"
export WFR_DRILL_LENS_FINDINGS="$lens_findings"
export WFR_DRILL_CONFERENCE_OUT="$conference_out"
export PATH="$scratch:$PATH"

set +e
"$bin_wfr" >"$scratch/run.out" 2>"$scratch/run.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "fleet-weekly-review must exit 0 rc=$rc err=$(cat "$scratch/run.err")"

# The ratchet ran and recorded no-evidence moves for every wired gate.
ratchet_out="$WFR_STATE_DIR/reports/$(printf '%s' "$WFR_FAKE_NOW" | tr -c 'A-Za-z0-9' '_')/ratchet-out.json"
[[ -f "$ratchet_out" ]] || fail "ratchet output missing: $ratchet_out"
move_count=$(jq '.moves | length' "$ratchet_out")
[[ "$move_count" -ge 6 ]] || fail "expected >= 6 ratchet moves (one per GATES row), got $move_count"
all_no_evidence=$(jq '[.moves[] | select(.action != "no-evidence")] | length' "$ratchet_out")
[[ "$all_no_evidence" == "0" ]] || fail "no live parsers are wired; all moves must be no-evidence, got $all_no_evidence stepped"
ok "(e) fleet-weekly-review three-phase run on fixtures"

# (f) bin/fleet-quality-ratchet rejects loosening without a sha.
cat >"$scratch/ledger.md" <<'EOF'
# Decisions ledger

- 2026-08-27 | Weekly Fleet Review approved | nish says lets go
- 2026-08-27 | Quality ratchet (Nish) | one-way tightening

EOF

set +e
"$bin_ratchet" propose \
    --gate verify-block-reproduction-rate \
    --new-value 0.80 \
    --evidence "test: would loosen current 0.90 -> 0.80" \
    --ledger "$scratch/ledger.md" >"$scratch/propose.out" 2>"$scratch/propose.err"
loosen_rc=$?
set -e
[[ "$loosen_rc" != "0" ]] || fail "loosening move must REJECT without --loosen-with-decision <sha> (rc=0)"
grep -q 'REJECT loosening' "$scratch/propose.err" \
    || fail "rejection must explain why (got: $(cat "$scratch/propose.err"))"
ok "(f1) fleet-quality-ratchet REJECTS loosening without a sha"

# (f2) tightening without a decision sha is accepted.
set +e
"$bin_ratchet" propose \
    --gate verify-block-reproduction-rate \
    --new-value 0.94 \
    --evidence "test: tightening 0.90 -> 0.94 (current+step)" \
    --ledger "$scratch/ledger.md" >"$scratch/propose.out" 2>"$scratch/propose.err"
tighten_rc=$?
set -e
[[ "$tighten_rc" == "0" ]] || fail "tightening move must ACCEPT (rc=$tighten_rc err=$(cat "$scratch/propose.err"))"
grep -q 'gate=verify-block-reproduction-rate' "$scratch/ledger.md" \
    || fail "tightening must write a ratchet line into the ledger"
grep -q 'new-bar=0.94' "$scratch/ledger.md" \
    || fail "tightening must record new-bar=0.94"
ok "(f2) fleet-quality-ratchet ACCEPTs tightening and writes the ledger line"

# (f3) loosening with a sha that IS in the ledger is accepted.
set +e
sha_marker="loosen-ok-sha-1234567890abcdef"
cat >>"$scratch/ledger.md" <<EOF
- 2026-08-27 | Loosen test grant | $sha_marker
EOF
"$bin_ratchet" propose \
    --gate verify-block-reproduction-rate \
    --new-value 0.88 \
    --evidence "test: loosening with a real sha" \
    --loosen-with-decision "$sha_marker" \
    --ledger "$scratch/ledger.md" >"$scratch/propose.out" 2>"$scratch/propose.err"
loosen_ok_rc=$?
set -e
[[ "$loosen_ok_rc" == "0" ]] || fail "loosening with a ledger sha must ACCEPT (rc=$loosen_ok_rc err=$(cat "$scratch/propose.err"))"
ok "(f3) loosening with a ledger-recorded sha is accepted"

# (f4) loosening with a sha that is NOT in the ledger REJECTS.
set +e
"$bin_ratchet" propose \
    --gate verify-block-reproduction-rate \
    --new-value 0.86 \
    --evidence "test: loosening with a fake sha" \
    --loosen-with-decision "definitely-not-in-the-ledger" \
    --ledger "$scratch/ledger.md" >"$scratch/propose.out" 2>"$scratch/propose.err"
loosen_bad_rc=$?
set -e
[[ "$loosen_bad_rc" != "0" ]] || fail "loosening with an unknown sha must REJECT"
grep -q 'not found in ledger' "$scratch/propose.err" \
    || fail "rejection must explain the missing sha"
ok "(f4) loosening with an unknown sha REJECTS"

# (g) nested CI host. Same pattern as the other role-gate tests.
grep -Fq 'bash "$here/fleet-weekly-review.test.sh"' "$here/rule-enforcement.test.sh" \
    || fail "rule-enforcement.test.sh must nest this file so CI cannot skip it without a workflow edit"
ok "(g) nested CI host"

ok "fleet-weekly-review: matrix, MANIFEST, install, timer shape, three-phase drill, ratchet one-way"