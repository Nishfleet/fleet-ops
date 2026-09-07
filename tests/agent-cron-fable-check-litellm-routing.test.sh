#!/usr/bin/env bash
# tests/agent-cron-fable-check-litellm-routing.test.sh
#
# fleet-ops#4181 P2: proves agent-cron-run fable-check routes to the
# LiteLLM proxy (litellm/judge) instead of seat-lib pick_seat. The proxy
# owns the fallback chain (cursor -> xai -> openrouter -> worker-capable);
# seat-lib still owns every other caller until P3.
#
# Acceptance:
#   - fable-check slug -> pi invoked with --provider litellm --model judge
#   - pick_seat is NOT called for fable-check (seat-lib bypassed)
#   - a non-fable-check slug still uses pick_seat (no regression)
#   - AGENT_CRON_SKIP_LITELLM=1 falls back to pick_seat (escape hatch)
#
# Offline. Stubbed seat-lib + stubbed pi. No live proxy needed.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/agent-cron-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t fable-litellm.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# Stub seat-lib: pick_seat records that it was called and returns a seat.
# The test checks pick_seat was NOT called for fable-check.
stub_lib="$scratch/seat-lib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
ATTEMPTS_DIR="${ATTEMPTS_DIR:-/tmp/agent-cron-attempts-stub}"
mkdir -p "$ATTEMPTS_DIR"
seat_log() { :; }
task_weight() { echo "light"; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
pick_seat() {
    echo "pick_seat CALLED" >> "${PICK_SEAT_RECORD}"
    printf 'cursor\tcursor-grok-4.6-high\n'
    return 0
}
litellm_pick_seat() { pick_seat; }
EOF

# Fake pi that records argv + stdin and prints a DIGEST line.
fake_pi="$scratch/pi"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PI_RECORD_ARGS"
cat > "$PI_RECORD_STDIN"
printf 'fable check body\nDIGEST:: fleet judge digest line\n'
EOF
chmod +x "$fake_pi"

# Fake hermes so the success path does not hit the network.
fake_hermes="$scratch/hermes"
cat >"$fake_hermes" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_hermes"

record_args="$scratch/pi.args"
record_stdin="$scratch/pi.stdin"
pick_seat_record="$scratch/pick_seat.log"
prompts_dir="$scratch/prompts"
log_dir="$scratch/cron-output"
mkdir -p "$prompts_dir" "$log_dir"
printf '# fable-check prompt\njudge the fleet.\n' >"$prompts_dir/fable-check.md"
printf '# other slug prompt\ndo something else.\n' >"$prompts_dir/other-slug.md"

export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export PATH="$scratch:$PATH"
export PROMPTS_DIR="$prompts_dir"
export LOG_DIR="$log_dir"
export WORKDIR="$scratch"
export PI_RECORD_ARGS="$record_args"
export PI_RECORD_STDIN="$record_stdin"
export PICK_SEAT_RECORD="$pick_seat_record"
export HERMES_RECORD="$scratch/hermes.log"
export ATTEMPTS_DIR="$scratch/attempts"

# --- scenario 1: fable-check -> litellm/judge, pick_seat NOT called ----------
rm -f "$record_args" "$record_stdin" "$pick_seat_record"
set +e
"$bin" fable-check >"$scratch/run1.out" 2>"$scratch/run1.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario 1: must exit 0, got $rc (stderr: $(cat "$scratch/run1.err"))"
grep -q -- '--provider litellm' "$record_args" \
  || fail "scenario 1: pi must run on provider litellm, got: $(cat "$record_args")"
grep -q -- '--model judge' "$record_args" \
  || fail "scenario 1: pi must run on model judge, got: $(cat "$record_args")"
[[ ! -f "$pick_seat_record" ]] \
  || fail "scenario 1: pick_seat must NOT be called for fable-check, got: $(cat "$pick_seat_record")"
ok "scenario 1: fable-check -> litellm/judge, pick_seat bypassed"

# --- scenario 2: non-fable slug still uses pick_seat (no regression) ---------
rm -f "$record_args" "$record_stdin" "$pick_seat_record"
set +e
"$bin" other-slug >"$scratch/run2.out" 2>"$scratch/run2.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario 2: must exit 0, got $rc (stderr: $(cat "$scratch/run2.err"))"
grep -q -- '--provider cursor' "$record_args" \
  || fail "scenario 2: pi must run on provider cursor (from pick_seat), got: $(cat "$record_args")"
grep -q -- '--model cursor-grok-4.6-high' "$record_args" \
  || fail "scenario 2: pi must run on model cursor-grok-4.6-high (from pick_seat), got: $(cat "$record_args")"
[[ -f "$pick_seat_record" ]] \
  || fail "scenario 2: pick_seat must be called for non-fable slugs"
ok "scenario 2: non-fable slug -> pick_seat (no regression)"

# --- scenario 3: AGENT_CRON_SKIP_LITELLM=1 -> pick_seat fallback -------------
rm -f "$record_args" "$record_stdin" "$pick_seat_record"
set +e
AGENT_CRON_SKIP_LITELLM=1 "$bin" fable-check >"$scratch/run3.out" 2>"$scratch/run3.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario 3: must exit 0, got $rc (stderr: $(cat "$scratch/run3.err"))"
grep -q -- '--provider cursor' "$record_args" \
  || fail "scenario 3: pi must run on provider cursor (skip-litellm fallback), got: $(cat "$record_args")"
[[ -f "$pick_seat_record" ]] \
  || fail "scenario 3: pick_seat must be called when AGENT_CRON_SKIP_LITELLM=1"
ok "scenario 3: AGENT_CRON_SKIP_LITELLM=1 -> pick_seat fallback"

ok "fable-check-litellm-routing: fable-check routes to litellm/judge, non-fable uses pick_seat, skip hatch works"
