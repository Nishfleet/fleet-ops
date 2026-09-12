#!/usr/bin/env bash
# tests/agent-cron-writes-refused.test.sh
#
# fleet-ops#5189: a seat behind a tool-approval gate (cursor's --auto-review
# classifier on cursor/cursor-grok-4.6-high, devin's --sandbox permission
# mode) can end a run rc=0 while every write the agent attempted was
# refused — the run "succeeds", the report says the verdicts did not post,
# and nothing escalates. The orchestrator-decision-sweep drafted 10+
# verdicts across five 2026-09-10 sweeps and landed none; the parked
# needs-orchestrator queue never drained.
#
# The fix has three parts, all pinned here:
#
#   1. is_writes_refused (seatlib) detects the WRITES-REFUSED contract
#      sentinel AND the refusal phrases the gated seats already emit
#      ("approval cards rejected", "blocked by auto-review", devin's
#      "rejected a tool call").
#   2. mark_seat_writes_refused_bench (seatlib) writes a config_fault
#      ledger entry (seat_dead=false — infrastructure, never seat yield)
#      whose usable_at window (default 3600s) OUTLASTS the caller unit's
#      RestartSec=900, so the systemd retry walks the senior ladder instead
#      of re-picking the same gated seat.
#   3. agent-cron-run checks the captured output on the rc=0 path, records
#      the refused run's output into the dated log file, benches the seat,
#      and exits 1 (loud: Restart= -> OnFailure escalation).
#
# Offline: stubbed seat-caps.json/ledger for the seatlib sections; a stub
# seatlib + fake pi for the agent-cron-run end-to-end.
# Hosted by tests/seat.lib.test.sh (workers cannot add a ci.yml line).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/litellm-seat.sh"
bin="$repo_root/bin/agent-cron-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

command -v jq >/dev/null || fail "jq required"
[[ -f "$lib" ]] || fail "seatlib.sh not found: $lib"
[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t agent-cron-writes-refused.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Minimal seat-caps.json so seatlib loads.
cat >"$scratch/seat-caps.json" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": ["cursor"],
  "providers": {
    "cursor": {
      "cap": 2, "class": "prepaid-quota",
      "quota_bench_default_s": 900,
      "models": {"cursor-grok-4.6-high": 2}
    }
  },
  "error_classes": {
    "quota_bench": {
      "matcher": "is_quota_cap_error",
      "writer": "mark_seat_quota_bench",
      "default_window_s_seconds": "quota_bench_default_s",
      "trigger_order": 2,
      "description": "Hard cap / quota wall."
    }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "cursor": {
      "models": [
        { "id": "cursor-grok-4.6-high", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON
export PI_MODELS_JSON="$scratch/models.json"

# Offline: no live systemd units in cap accounting.
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export SEAT_LIVE_QUOTA_PROM="$scratch/no-live-quota.prom"

LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_PACKET_STATE="$scratch/state"
export XDG_RUNTIME_DIR="$scratch/xdg"
mkdir -p "$XDG_RUNTIME_DIR"

# ============================================================================
# 1. seatlib: is_writes_refused matcher
# ============================================================================
match() {
    bash -c 'source "$0"; load_seat_caps; is_writes_refused "$1" "$2"' \
        "$lib" "$1" "$2" >/dev/null 2>&1
}

# 1a. The contract sentinel matches.
set +e; match "orchestrator-decision-sweep: decided=0 dep=10 nish=3 closed=0 skipped=11
WRITES-REFUSED: gh issue comment + label edits refused by approval gate" ""; rc=$?; set -e
[[ "$rc" == "0" ]] || fail "is_writes_refused must match the WRITES-REFUSED sentinel (rc=$rc)"
ok "is_writes_refused: matches WRITES-REFUSED sentinel"

# 1b. Observed refusal phrases match (the exact wording the 2026-09-10
# stalled sweeps produced on cursor/cursor-grok-4.6-high).
for phrase in \
    "GitHub write of the verdict comment was blocked twice by auto-review; approval cards rejected" \
    "The GitHub comments did not post (approval card rejected, same stall as the last two sweeps)" \
    "GitHub comments, closes, and needs-orchestrator removal did not land (auto-review blocked; approval cards rejected)" \
    "blocked by Cursor auto-review (approval card rejected)" \
    "warning: rejected a tool call that requires confirmation. Running in non-interactive mode"; do
    set +e; match "$phrase" ""; rc=$?; set -e
    [[ "$rc" == "0" ]] || fail "is_writes_refused must match observed refusal phrase: '$phrase' (rc=$rc)"
done
ok "is_writes_refused: matches all observed refusal phrases (cursor auto-review + devin permission mode)"

# 1c. A clean sweep output does NOT match (no false positive on the
# ordinary success text, including a benign 'did not' prose line).
set +e; match "All verdicts posted. orchestrator-decision-sweep: decided=2 dep=7 nish=3 closed=0 skipped=0" ""; rc=$?; set -e
[[ "$rc" == "1" ]] || fail "is_writes_refused must NOT match a clean sweep output (rc=$rc)"
ok "is_writes_refused: clean sweep output does not match"

# 1d. A quota wall does NOT match.
set +e; match "INFERENCE_CAP_ERROR: weekly limit" ""; rc=$?; set -e
[[ "$rc" == "1" ]] || fail "is_writes_refused must NOT match a quota error (rc=$rc)"
ok "is_writes_refused: quota error does not match"

# 1e. Empty input does NOT match.
set +e; match "" ""; rc=$?; set -e
[[ "$rc" == "1" ]] || fail "is_writes_refused must NOT match empty input (rc=$rc)"
ok "is_writes_refused: empty input does not match"

# ============================================================================
# 2. mark_seat_writes_refused_bench: config_fault ledger, NEVER retired,
#    window outlasts RestartSec=900
# ============================================================================
rm -f "$LEDGER"/*.json 2>/dev/null || true
set +e
bash -c 'source "$0"; load_seat_caps; mark_seat_writes_refused_bench "$1" "$2" "$3"' \
    "$lib" "cursor" "cursor-grok-4.6-high" "agent-cron:orchestrator-decision-sweep" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "mark_seat_writes_refused_bench must return 0 on success (rc=$rc)"

ledger_file="$LEDGER/cursor__cursor-grok-4.6-high.json"
[[ -f "$ledger_file" ]] || fail "ledger not created: $ledger_file"

hc=$(jq -r '.health_class' "$ledger_file")
[[ "$hc" == "config_fault" ]] \
    || fail "health_class must be config_fault, got '$hc'"
fm=$(jq -r '.failure_mode' "$ledger_file")
[[ "$fm" == "writes-refused" ]] \
    || fail "failure_mode must be writes-refused, got '$fm'"
seat_dead=$(jq -r '.seat_dead' "$ledger_file")
[[ "$seat_dead" == "false" ]] \
    || fail "seat_dead must stay false — an approval gate is infrastructure, NOT yield (got '$seat_dead')"
lec=$(jq -r '.last_error_class' "$ledger_file")
[[ "$lec" == "writes-refused" ]] \
    || fail "last_error_class must be writes-refused, got '$lec'"

# The bench must outlast RestartSec=900 or the systemd retry re-picks the
# same gated seat (senior-review tried-seats drop once usable, #4220).
usable_at=$(jq -r '.usable_at' "$ledger_file")
usable_s=$(date -u -d "$usable_at" +%s 2>/dev/null || echo 0)
now_s=$(date -u +%s)
delta=$((usable_s - now_s))
[[ "$delta" -gt 900 ]] \
    || fail "usable_at must be >900s in the future to outlast the unit RestartSec (delta=${delta}s, usable_at=$usable_at)"
ok "mark_seat_writes_refused_bench: config_fault, writes-refused, seat_dead=false, usable_at ${delta}s out (> RestartSec=900)"

# 2b. seat_usable must skip the benched seat while the bench holds.
set +e
bash -c 'source "$0"; load_seat_caps; seat_usable "$1" "$2"' \
    "$lib" "cursor" "cursor-grok-4.6-high" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "seat_usable must skip the writes-refused-benched seat while the bench holds (rc=$rc)"
ok "seat_usable: benched seat is skipped (pick-seat retry walks the ladder)"

# ============================================================================
# 3. agent-cron-run end-to-end: refused output on rc=0 -> exit 1 + bench +
#    output recorded; clean output -> exit 0 as before
# ============================================================================
bench_record="$scratch/bench.calls"
stub_lib="$scratch/stub-seatlib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
ATTEMPTS_DIR="${ATTEMPTS_DIR:-/tmp/agent-cron-wr-attempts-stub}"
mkdir -p "$ATTEMPTS_DIR"
seat_log() { :; }
task_weight() { echo "light"; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
# The real matcher is unit-tested above; the e2e exercises the wiring with
# the contract sentinel, the marker the prompt guarantees.
is_writes_refused() { grep -q 'WRITES-REFUSED' <<<"$1$2"; }
mark_seat_writes_refused_bench() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$BENCH_RECORD"; return 0; }
litellm_seat() { printf 'cursor\tcursor-grok-4.6-high\n'; return 0; }
EOF

fake_pi="$scratch/pi"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'sweep prose: five needs-orchestrator tickets still sit; comments did not post.\n'
printf 'orchestrator-decision-sweep: decided=0 dep=10 nish=3 closed=0 skipped=11\n'
printf 'WRITES-REFUSED: gh issue comment/close/edit refused by the seat approval gate\n'
EOF
chmod +x "$fake_pi"

fake_hermes="$scratch/hermes"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_hermes"
chmod +x "$fake_hermes"

prompts_dir="$scratch/prompts"
log_dir="$scratch/cron-output"
mkdir -p "$prompts_dir" "$log_dir" "$scratch/attempts"
printf '# test sweep prompt\nrun the sweep.\n' >"$prompts_dir/orchestrator-decision-sweep.md"

export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export PATH="$scratch:$PATH"
export PROMPTS_DIR="$prompts_dir"
export LOG_DIR="$log_dir"
export WORKDIR="$scratch"
export ATTEMPTS_DIR="$scratch/attempts"
export BENCH_RECORD="$bench_record"

set +e
"$bin" orchestrator-decision-sweep >"$scratch/run.out" 2>"$scratch/run.err"
rc=$?
set -e
[[ "$rc" == "1" ]] \
    || fail "e2e: a run whose output carries WRITES-REFUSED must exit 1 (loud), got $rc (stderr: $(cat "$scratch/run.err"))"
ok "e2e: WRITES-REFUSED output -> exit 1 (was the silent rc=0 stall)"

# The seat must be benched so the systemd retry walks the ladder.
[[ -s "$bench_record" ]] || fail "e2e: mark_seat_writes_refused_bench must be called on a refused run"
grep -q $'cursor\tcursor-grok-4.6-high\tagent-cron:orchestrator-decision-sweep' "$bench_record" \
    || fail "e2e: bench call must carry the seat and the slug reason, got: $(cat "$bench_record")"
ok "e2e: refused seat benched (cursor/cursor-grok-4.6-high, reason names the slug)"

# The refused run's output must be recorded in the dated log file — the
# drafted verdicts are the evidence.
out_file="$log_dir/orchestrator-decision-sweep-$(date -u +%Y-%m-%d).md"
[[ -f "$out_file" ]] || fail "e2e: refused run output must be recorded to $out_file"
grep -q 'WRITES-REFUSED' "$out_file" \
    || fail "e2e: recorded output must carry the WRITES-REFUSED header, got: $(cat "$out_file")"
grep -q 'skipped=11' "$out_file" \
    || fail "e2e: recorded output must carry the run text, got: $(cat "$out_file")"
ok "e2e: refused run recorded in the dated log with the WRITES-REFUSED header"

# The tried-seats file must NOT be reset (success resets it; a refused run
# is not a success — the retry must not re-offer a clean slate).
tried_file="$ATTEMPTS_DIR/agent-cron-orchestrator-decision-sweep.tried-seats"
[[ -f "$tried_file" ]] && grep -q 'cursor/cursor-grok-4.6-high' "$tried_file" \
    || fail "e2e: tried-seats must still list the refused seat, got: $(cat "$tried_file" 2>/dev/null || echo MISSING)"
ok "e2e: tried-seats retains the refused seat (no success-path reset)"

# --- control: a clean run still exits 0 -------------------------------------
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'all verdicts posted.\n'
printf 'orchestrator-decision-sweep: decided=2 dep=7 nish=3 closed=0 skipped=0\n'
EOF
chmod +x "$fake_pi"
: >"$bench_record"
set +e
"$bin" orchestrator-decision-sweep >"$scratch/run2.out" 2>"$scratch/run2.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "control: a clean run must still exit 0, got $rc (stderr: $(cat "$scratch/run2.err"))"
[[ ! -s "$bench_record" ]] || fail "control: a clean run must NOT bench the seat, got: $(cat "$bench_record")"
ok "control: clean run exits 0, no bench (detector does not false-positive the normal path)"

# ============================================================================
# 4. Regression pins
# ============================================================================
grep -q 'WRITES-REFUSED' "$repo_root/prompts/orchestrator-decision-sweep.md" \
    || fail "REGRESSION PIN (fleet-ops#5189): the sweep prompt must declare the WRITES-REFUSED contract"
ok "prompt declares the WRITES-REFUSED sentinel contract"

grep -q 'is_writes_refused' "$bin" \
    || fail "agent-cron-run must call is_writes_refused"
grep -q 'mark_seat_writes_refused_bench' "$bin" \
    || fail "agent-cron-run must call mark_seat_writes_refused_bench"
ok "agent-cron-run wires is_writes_refused + mark_seat_writes_refused_bench"

grep -q 'SEAT_WRITES_REFUSED_BENCH_S' "$lib" \
    || fail "seatlib must define SEAT_WRITES_REFUSED_BENCH_S"
ok "seatlib carries SEAT_WRITES_REFUSED_BENCH_S"

echo
echo "ALL OK: agent-cron-writes-refused.test.sh (fleet-ops#5189)"
