#!/usr/bin/env bash
# tests/quality-research-weekly.test.sh
#
# Proves fleet-ops#541 continuous-research enforcer:
#   (a) matrix row is enforced with a real mechanism/proof.
#   (b) MANIFEST ships the timer, service, and prompt (no new bin/).
#   (c) ExecStart is agent-cron-run quality-research-weekly (help-first:
#       that runner already does seat-rotate + pi --print; a second
#       wrapper is the restic-forget class).
#   (d) timer has a Named reason + OnCalendar Sunday + [Install].
#   (e) install.sh enable --now the timer (fleet-ops#183 class).
#   (f) agent-cron-run with this slug succeeds on a stubbed pi (the
#       deliverable run; outermost edge stubbed).
# Nested from tests/rule-enforcement.test.sh so CI cannot skip it without
# a workflow edit this token cannot push.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/agent-cron-run"
svc="$repo_root/systemd/quality-research-weekly.service"
timer="$repo_root/systemd/quality-research-weekly.timer"
prompt="$repo_root/prompts/quality-research-weekly.md"
install_sh="$repo_root/install.sh"
manifest="$repo_root/MANIFEST"
matrix="$repo_root/config/rule-enforcement.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$svc" ]] || fail "missing $svc"
[[ -f "$timer" ]] || fail "missing $timer"
[[ -f "$prompt" ]] || fail "missing $prompt"
[[ -f "$install_sh" ]] || fail "missing $install_sh"
[[ -f "$manifest" ]] || fail "missing $manifest"
[[ -f "$matrix" ]] || fail "missing $matrix"
command -v jq >/dev/null 2>&1 || fail "jq missing"

# (a) matrix
jq -e '.rules[] | select(.id == "led-continuous-research" and .status == "enforced")' \
  "$matrix" >/dev/null || fail "led-continuous-research must be status=enforced"
mech=$(jq -r '.rules[] | select(.id == "led-continuous-research") | .mechanism' "$matrix")
printf '%s\n' "$mech" | grep -q 'quality-research-weekly' \
  || fail "mechanism must name quality-research-weekly (got: $mech)"
proof=$(jq -r '.rules[] | select(.id == "led-continuous-research") | .proof' "$matrix")
printf '%s\n' "$proof" | grep -q 'systemd/quality-research-weekly.timer' \
  || fail "proof must name the timer (got: $proof)"
ok "(a) led-continuous-research is enforced with mechanism+proof"

# Catalog: this sweep is a researcher role. The P14 failure on #675 was
# ungated-role for the new prompt and unit. Lock it here so dropping the
# catalog row re-reds CI without a workflow edit.
python3 - "$repo_root/config/role-quality-gates.json" <<'PY' || fail "role-quality-gates catalog missing quality-research-weekly"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
row = next((r for r in data["roles"] if r.get("id") == "researcher"), None)
if row is None:
    raise SystemExit("researcher role missing")
if "quality-research-weekly.md" not in (row.get("prompts") or []):
    raise SystemExit("researcher prompts must include quality-research-weekly.md")
if "quality-research-weekly.service" not in (row.get("units") or []):
    raise SystemExit("researcher units must include quality-research-weekly.service")
PY
ok "catalog: quality-research-weekly is gated as researcher (fleet-ops#541)"

# (b) MANIFEST — prompt + units, no new bin/
grep -Fxq "systemd/quality-research-weekly.service /home/nish/.config/systemd/user/quality-research-weekly.service" "$manifest" \
  || fail "MANIFEST missing quality-research-weekly.service"
grep -Fxq "systemd/quality-research-weekly.timer /home/nish/.config/systemd/user/quality-research-weekly.timer" "$manifest" \
  || fail "MANIFEST missing quality-research-weekly.timer"
grep -Fxq "prompts/quality-research-weekly.md /home/nish/.pi/agent/prompts/quality-research-weekly.md" "$manifest" \
  || fail "MANIFEST missing quality-research-weekly.md"
if grep -E '^bin/quality-research-weekly ' "$manifest"; then
  fail "must not add bin/quality-research-weekly; agent-cron-run already runs slugs"
fi
ok "(b) MANIFEST ships units+prompt and no new bin/"

# (c) ExecStart is the proven runner
grep -q '^ExecStart=/home/nish/.local/bin/agent-cron-run quality-research-weekly$' "$svc" \
  || fail "service ExecStart must invoke agent-cron-run quality-research-weekly"
grep -q 'Restart=on-failure' "$svc" \
  || fail "service must Restart=on-failure so a transient 429 re-seats"
ok "(c) ExecStart is agent-cron-run quality-research-weekly"

# (d) timer shape
grep -q '^# Named reason:' "$timer" \
  || fail "timer must carry a Named reason (fleet-unjustified-wait)"
grep -q '^OnCalendar=Sun \*\-\*\-\* 03:00:00 Asia/Kolkata$' "$timer" \
  || fail "timer must fire Sunday 03:00 IST"
grep -q '^\[Install\]$' "$timer" \
  || fail "timer must carry [Install]"
grep -q '^WantedBy=timers.target$' "$timer" \
  || fail "timer [Install] must WantedBy=timers.target"
grep -q '^Persistent=true$' "$timer" \
  || fail "timer must be Persistent so a missed Sunday still fires"
ok "(d) timer has Named reason, Sunday 03:00 IST, [Install]"

# (e) install enable (fleet-ops#183)
grep -Fq -- '"$SYSTEMCTL" --user enable --now quality-research-weekly.timer' "$install_sh" \
  || fail "install.sh must enable --now quality-research-weekly.timer"
ok "(e) install.sh enables the weekly timer"

# Prompt locks the ledger line and DIGEST:: contract
grep -q 'continuous research' "$prompt" \
  || fail "prompt must name the continuous research ledger line"
grep -q 'quality-first-recos.md' "$prompt" \
  || fail "prompt must name the recos file"
grep -q 'DIGEST::' "$prompt" \
  || fail "prompt must tell the agent to emit DIGEST:: for agent-cron-run"
grep -q 'AGENT_CRON_SLUG=quality-research-weekly' "$prompt" \
  || fail "prompt must confirm AGENT_CRON_SLUG"
ok "prompt names the ledger line, recos file, and DIGEST::"

# (f) deliverable run — stub pi and hermes only
scratch=$(mktemp -d -t quality-research-weekly.XXXXXX)
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
printf 'delta sweep body\nDIGEST:: weekly quality research: no new deltas\n'
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
"$bin" quality-research-weekly >"$scratch/run.out" 2>"$scratch/run.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "agent-cron-run quality-research-weekly must exit 0 (rc=$rc err=$(cat "$scratch/run.err"))"
grep -q -- '--provider devin' "$PI_RECORD_ARGS" \
  || fail "pi must run on stubbed seat, got: $(cat "$PI_RECORD_ARGS")"
grep -q 'AGENT_CRON_SLUG=quality-research-weekly' "$PI_RECORD_STDIN" \
  || fail "pi stdin must carry AGENT_CRON_SLUG"
grep -q 'quality-first-recos.md' "$PI_RECORD_STDIN" \
  || fail "pi stdin must carry the real weekly prompt"
grep -q 'weekly quality research: no new deltas' "$HERMES_RECORD" \
  || fail "DIGEST:: must ship via hermes, got: $(cat "$HERMES_RECORD" 2>/dev/null)"
out_file="$log_dir/quality-research-weekly-$(date -u +%Y-%m-%d).md"
[[ -f "$out_file" ]] || fail "cron output file missing: $out_file"
grep -q 'seat=devin/glm-5-2' "$out_file" \
  || fail "output file must record the seat"
ok "(f) agent-cron-run quality-research-weekly exits 0 on stubbed pi"

# Nested CI host
grep -Fq 'bash "$here/quality-research-weekly.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this file"
ok "contracts: nested CI host"

ok "quality-research-weekly: matrix, MANIFEST, agent-cron-run slug, timer, install, stubbed run"
