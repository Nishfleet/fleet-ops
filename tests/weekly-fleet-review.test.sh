#!/usr/bin/env bash
# tests/weekly-fleet-review.test.sh
#
# Proves fleet-ops#1146 + ledger 2026-08-27 | Weekly Fleet Review approved:
#   (a) matrix row is enforced with a real mechanism/proof
#   (b) MANIFEST ships the timer, service, and prompt (no new bin/)
#   (c) ExecStart is agent-cron-run weekly-fleet-review (help-first: that
#       runner already does seat-rotate + pi --print; a second wrapper is
#       the restic-forget class)
#   (d) timer has a Named reason + OnCalendar Sunday + [Install] +
#       Persistent (post-maintenance — fires after vps-weekly-update
#       and quality-research-weekly)
#   (e) install.sh enable --now the timer (fleet-ops#183 class)
#   (f) prompt locks the 5-action cap, the signal-attribution rule,
#       the blind 5-lens structure, and the "claimed work only" output
#   (g) role-quality-gates catalog ships the new role with the bypass
#       check helper, and live audit is green
#   (h) agent-cron-run with this slug succeeds on a stubbed pi (the
#       deliverable run; outermost edge stubbed)
# Nested from tests/rule-enforcement.test.sh so CI cannot skip it without
# a workflow edit this token cannot push.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/agent-cron-run"
svc="$repo_root/systemd/fleet-weekly-fleet-review.service"
timer="$repo_root/systemd/fleet-weekly-fleet-review.timer"
prompt="$repo_root/prompts/weekly-fleet-review.md"
install_sh="$repo_root/install.sh"
manifest="$repo_root/MANIFEST"
matrix="$repo_root/config/rule-enforcement.json"
role_gates="$repo_root/config/role-quality-gates.json"
role_gates_lib="$repo_root/lib/role-quality-gates.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$svc" ]] || fail "missing $svc"
[[ -f "$timer" ]] || fail "missing $timer"
[[ -f "$prompt" ]] || fail "missing $prompt"
[[ -f "$install_sh" ]] || fail "missing $install_sh"
[[ -f "$manifest" ]] || fail "missing $manifest"
[[ -f "$matrix" ]] || fail "missing $matrix"
[[ -f "$role_gates" ]] || fail "missing $role_gates"
[[ -f "$role_gates_lib" ]] || fail "missing $role_gates_lib"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"

# (a) matrix
jq -e '.rules[] | select(.id == "led-2026-08-27-weekly-fleet-review-approved" and .status == "enforced")' \
  "$matrix" >/dev/null || fail "led-2026-08-27-weekly-fleet-review-approved must be status=enforced"
mech=$(jq -r '.rules[] | select(.id == "led-2026-08-27-weekly-fleet-review-approved") | .mechanism' "$matrix")
printf '%s\n' "$mech" | grep -q 'weekly-fleet-review' \
  || fail "mechanism must name weekly-fleet-review (got: $mech)"
printf '%s\n' "$mech" | grep -q '5 specced actions' \
  || fail "mechanism must lock the 5-action cap (got: $mech)"
proof=$(jq -r '.rules[] | select(.id == "led-2026-08-27-weekly-fleet-review-approved") | .proof' "$matrix")
printf '%s\n' "$proof" | grep -q 'systemd/fleet-weekly-fleet-review.timer' \
  || fail "proof must name the timer (got: $proof)"
printf '%s\n' "$proof" | grep -q 'prompts/weekly-fleet-review.md' \
  || fail "proof must name the prompt (got: $proof)"
printf '%s\n' "$proof" | grep -q 'tests/weekly-fleet-review.test.sh' \
  || fail "proof must name this test (got: $proof)"
ok "(a) led-2026-08-27-weekly-fleet-review-approved is enforced with mechanism+proof"

# (b) MANIFEST — prompt + units, no new bin/
grep -Fxq "systemd/fleet-weekly-fleet-review.service /home/nish/.config/systemd/user/fleet-weekly-fleet-review.service" "$manifest" \
  || fail "MANIFEST missing fleet-weekly-fleet-review.service"
grep -Fxq "systemd/fleet-weekly-fleet-review.timer /home/nish/.config/systemd/user/fleet-weekly-fleet-review.timer" "$manifest" \
  || fail "MANIFEST missing fleet-weekly-fleet-review.timer"
grep -Fxq "prompts/weekly-fleet-review.md /home/nish/.pi/agent/prompts/weekly-fleet-review.md" "$manifest" \
  || fail "MANIFEST missing weekly-fleet-review.md"
if grep -E '^bin/weekly-fleet-review ' "$manifest"; then
  fail "must not add bin/weekly-fleet-review; agent-cron-run already runs slugs"
fi
ok "(b) MANIFEST ships units+prompt and no new bin/"

# (c) ExecStart is the proven runner
grep -q '^ExecStart=/home/nish/.local/bin/agent-cron-run weekly-fleet-review$' "$svc" \
  || fail "service ExecStart must invoke agent-cron-run weekly-fleet-review"
grep -q 'Restart=on-failure' "$svc" \
  || fail "service must Restart=on-failure so a transient 429 re-seats"
ok "(c) ExecStart is agent-cron-run weekly-fleet-review"

# (d) timer shape — post-maintenance, Sunday 04:30 IST
grep -q '^# Named reason:' "$timer" \
  || fail "timer must carry a Named reason (fleet-unjustified-wait)"
grep -q '^OnCalendar=Sun \*\-\*\-\* 04:30:00 Asia/Kolkata$' "$timer" \
  || fail "timer must fire Sunday 04:30 IST (post-vps-weekly-update + post-quality-research-weekly)"
grep -q '^\[Install\]$' "$timer" \
  || fail "timer must carry [Install]"
grep -q '^WantedBy=timers.target$' "$timer" \
  || fail "timer [Install] must WantedBy=timers.target"
grep -q '^Persistent=true$' "$timer" \
  || fail "timer must be Persistent so a missed Sunday still fires"
ok "(d) timer has Named reason, Sunday 04:30 IST, [Install], Persistent"

# (e) install enable (fleet-ops#183)
grep -Fq -- '"$SYSTEMCTL" --user enable --now fleet-weekly-fleet-review.timer' "$install_sh" \
  || fail "install.sh must enable --now fleet-weekly-fleet-review.timer"
ok "(e) install.sh enables the weekly timer"

# (f) prompt locks the contract — cap, signal, blind, "claimed work only"
grep -q 'AGENT_CRON_SLUG=weekly-fleet-review' "$prompt" \
  || fail "prompt must confirm AGENT_CRON_SLUG=weekly-fleet-review"
grep -q 'Adopt ≤ 5' "$prompt" \
  || fail "prompt must lock the Adopt ≤ 5 cap (output contract)"
grep -q 'signal: wfr-action/' "$prompt" \
  || fail "prompt must require signal: wfr-action/ attribution for self-score"
grep -q 'claimed work only' "$prompt" \
  || fail "prompt must say 'claimed work only' (no Nish report)"
grep -q -i 'blind' "$prompt" \
  || fail "prompt must mention the blind 5-lens structure"
grep -q '5-lens' "$prompt" \
  || fail "prompt must name the 5 lenses"
grep -q '5 lenses' "$prompt" \
  || fail "prompt must enumerate the 5 lenses"
grep -q 'DIGEST::' "$prompt" \
  || fail "prompt must tell the agent to emit DIGEST:: for agent-cron-run"
ok "(f) prompt locks the 5-action cap, signal, blind structure, claimed-work-only"

# (g) role-quality-gates catalog + bypass check helper
jq -e '.roles[] | select(.id == "weekly-fleet-review")' "$role_gates" >/dev/null \
  || fail "role-quality-gates.json must include weekly-fleet-review role"
jq -e '.roles[] | select(.id == "weekly-fleet-review") | .prompts | index("weekly-fleet-review.md")' "$role_gates" >/dev/null \
  || fail "weekly-fleet-review role must list weekly-fleet-review.md in prompts[]"
jq -e '.roles[] | select(.id == "weekly-fleet-review") | .units | index("fleet-weekly-fleet-review.service")' "$role_gates" >/dev/null \
  || fail "weekly-fleet-review role must list fleet-weekly-fleet-review.service in units[]"
jq -e '.roles[] | select(.id == "weekly-fleet-review") | .bypass_checks | index("weekly_fleet_review_output_contract")' "$role_gates" >/dev/null \
  || fail "weekly-fleet-review role must name the weekly_fleet_review_output_contract bypass check"
jq -e '.roles[] | select(.id == "weekly-fleet-review") | .bypass_checks | index("quality_ratchet_contract")' "$role_gates" >/dev/null \
  || fail "weekly-fleet-review role must name the quality_ratchet_contract bypass check"
grep -q 'def check_weekly_fleet_review_output_contract' "$role_gates_lib" \
  || fail "lib/role-quality-gates.py must define check_weekly_fleet_review_output_contract"
grep -q '"weekly_fleet_review_output_contract": check_weekly_fleet_review_output_contract' "$role_gates_lib" \
  || fail "BYPASS_CHECKS must register check_weekly_fleet_review_output_contract"
grep -q 'def check_quality_ratchet_contract' "$role_gates_lib" \
  || fail "lib/role-quality-gates.py must define check_quality_ratchet_contract"

# Live audit must be green — the new role, prompt, and unit cannot show
# up as findings (or the role-gate auditor is itself broken).
set +e
live=$(python3 "$role_gates_lib" audit --repo-root "$repo_root" --catalog "$role_gates" 2>&1)
live_rc=$?
set -e
echo "$live" | jq -e . >/dev/null || fail "live audit did not emit JSON: $live"
if echo "$live" | jq -e '.findings[] | select(.id == "weekly-fleet-review")' >/dev/null; then
  fail "live audit re-flagged weekly-fleet-review (regression of #1146): $(echo "$live" | jq -c '.findings')"
fi
if echo "$live" | jq -e '.findings[] | select(.detail | test("weekly-fleet-review"; "i"))' >/dev/null; then
  fail "live audit has weekly-fleet-review-related findings: $(echo "$live" | jq -c '.findings')"
fi
[[ "$live_rc" == "0" ]] || fail "live audit non-zero (rc=$live_rc) — role catalog may be incomplete"
ok "(g) role-quality-gates catalog green, live audit clean for weekly-fleet-review"

# (h) deliverable run — stub pi and hermes only
scratch=$(mktemp -d -t weekly-fleet-review.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

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

fake_pi="$scratch/pi"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PI_RECORD_ARGS"
cat > "$PI_RECORD_STDIN"
printf 'wfr body\nDIGEST:: weekly-fleet-review: 0 filed, 0 discards, 0 boundary; cap=5; ratio=0.0\n'
EOF
chmod +x "$fake_pi"

fake_hermes="$scratch/hermes"
cat >"$fake_hermes" <<'EOF'
#!/usr/bin/env bash
echo "hermes stub: $*" >> "$HERMES_RECORD"
exit 0
EOF
chmod +x "$fake_hermes"

log_dir="$scratch/cron-output"
mkdir -p "$log_dir"
export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export PATH="$scratch:$PATH"
export PROMPTS_DIR="$repo_root/prompts"
export LOG_DIR="$log_dir"
export WORKDIR="$scratch"
export PI_RECORD_ARGS="$scratch/pi.args"
export PI_RECORD_STDIN="$scratch/pi.stdin"
export HERMES_RECORD="$scratch/hermes.log"
export ATTEMPTS_DIR="$scratch/attempts"

set +e
"$bin" weekly-fleet-review >"$scratch/run.out" 2>"$scratch/run.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "agent-cron-run weekly-fleet-review must exit 0 (rc=$rc err=$(cat "$scratch/run.err"))"
grep -q -- '--provider devin' "$PI_RECORD_ARGS" \
  || fail "pi must run on stubbed seat, got: $(cat "$PI_RECORD_ARGS")"
grep -q 'AGENT_CRON_SLUG=weekly-fleet-review' "$PI_RECORD_STDIN" \
  || fail "pi stdin must carry AGENT_CRON_SLUG=weekly-fleet-review"
grep -q 'weekly-fleet-review' "$PI_RECORD_STDIN" \
  || fail "pi stdin must carry the real WFR prompt slug"
grep -q 'weekly-fleet-review:' "$HERMES_RECORD" \
  || fail "DIGEST:: must ship via hermes, got: $(cat "$HERMES_RECORD" 2>/dev/null)"
out_file="$log_dir/weekly-fleet-review-$(date -u +%Y-%m-%d).md"
[[ -f "$out_file" ]] || fail "cron output file missing: $out_file"
grep -q 'seat=devin/glm-5-2' "$out_file" \
  || fail "output file must record the seat"
ok "(h) agent-cron-run weekly-fleet-review exits 0 on stubbed pi"

# Nested CI host
grep -Fq 'bash "$here/weekly-fleet-review.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this file"
ok "contracts: nested CI host"

ok "weekly-fleet-review: matrix, MANIFEST, agent-cron-run slug, timer, install, prompt contract, role gate, stubbed run"
