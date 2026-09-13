#!/usr/bin/env bash
# tests/agent-cron-packet-size.test.sh
#
# fleet-ops#5739: the fable-check judge packet's inputs (open alarms, stuck
# alert-repair packets, PR lists, one-off follow-through sections) are
# monotonically growing live state. On 2026-09-11T19:00Z the packet hit
# 75495B — +0.7% over the #5309 PROMPT_E2BIG_CAP_BYTES=75000B cap — and the
# hourly fleet judge refused to spawn (PROMPT TOO LARGE, instant exit 1) with
# NO trim/fallback; the OnFailure repair plane burned 4 extra unit starts and
# the judge cycle was silently skipped. The 20:00Z run only worked because
# the packet content happened to dip back under the cap.
#
# Locks the deterministic trim fallback in bin/agent-cron-run
# (fleet-ops#5739):
#   - a packet over PROMPT_E2BIG_CAP_BYTES whose trailing '## ' sections are
#     trimmable is trimmed end-inward (lowest-priority trailing sections
#     first, STANDING / "never delete this section" paragraphs protected)
#     until it fits; the run PROCEEDS and the trim is logged by section
#     name with bytes saved;
#   - the assembled packet pi receives is <= PROMPT_E2BIG_CAP_BYTES;
#   - a fixture at ~2x the cap still produces a fitting packet (the trim
#     is not a one-shot shave — it must cover unbounded growth);
#   - a packet with NO trimmable sections still hits the #5309 fail-loud
#     refusal (PROMPT TOO LARGE, exit 1, pi never spawned);
#   - PROMPT_E2BIG_CAP_BYTES itself is untouched by this fix.
#
# Registered for CI via tests/agent-cron-seat-rotation.test.sh (the P14
# listing gate — unhosted tests fail the listing gate, see #3483) next to
# its sibling agent-cron-prompt-e2big-guard.test.sh (#5309).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/agent-cron-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t agent-cron-trim.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

stub_lib="$scratch/seatlib.sh"
cat >"$stub_lib" <<'EOF'
export HOME="${HOME:-/home/nish}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export PI_BIN="${PI_BIN:-/home/nish/.local/bin/pi}"
ATTEMPTS_DIR="${ATTEMPTS_DIR:-/tmp/agent-cron-attempts-stub}"
mkdir -p "$ATTEMPTS_DIR"
seat_log() { printf '%s\n' "$*" >>"${SEAT_CALLS:?}"; }
task_weight() { echo "light"; }
register_active_seat() { :; }
clear_active_seat() { :; }
is_spawn_etimeout() { return 1; }
is_quota_cap_error() { return 1; }
mark_seat_spawn_fail() { return 0; }
mark_seat_quota_bench() { return 0; }
litellm_seat() { printf 'cursor\tcursor-grok-4.6-high\n'; return 0; }
EOF

# Fake pi: records the byte count of the stdin packet it receives.
fake_pi="$scratch/pi"
cat >"$fake_pi" <<'EOF'
#!/usr/bin/env bash
cat > "$PI_RECORD_STDIN"
wc -c > "$PI_RECORD_STDIN_BYTES"
printf '%s\n' "$*" > "$PI_RECORD_ARGS"
printf 'body\nDIGEST:: d\n'
EOF
chmod +x "$fake_pi"

fake_hermes="$scratch/hermes"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_hermes"
chmod +x "$fake_hermes"

record_args="$scratch/pi.args"
stdin_bytes="$scratch/pi.stdin_bytes"
stdin_file="$scratch/pi.stdin"
seat_calls="$scratch/seat.calls"
prompts_dir="$scratch/prompts"
log_dir="$scratch/cron-output"
mkdir -p "$prompts_dir" "$log_dir"

export PI_PACKET_SEAT_LIB="$stub_lib"
export PI_BIN="$fake_pi"
export PATH="$scratch:$PATH"
export PROMPTS_DIR="$prompts_dir"
export LOG_DIR="$log_dir"
export WORKDIR="$scratch"
export PI_RECORD_ARGS="$record_args"
export PI_RECORD_STDIN_BYTES="$stdin_bytes"
export PI_RECORD_STDIN="$stdin_file"
export SEAT_CALLS="$seat_calls"
export HERMES_RECORD="$scratch/hermes.log"
export ATTEMPTS_DIR="$scratch/attempts"

# Fixture builder: preamble + protected STANDING section + big trimmable
# trailing '## ' sections (one-off follow-through / alarm / PR-list rows),
# shaped like the live agent-state/fleet-landing-watch/fable-check.md packet.
# $1 = slug, $2 = total approximate bytes, $3 = list file of trimmable
# section headings.
build_packet() {
    local slug="$1" total="$2"
    local head="## One-off follow-through: alarm sweep rows (any judge; delete when done)"
    local line
    {
        printf 'You are the hourly fleet judge (fleet-ops#5739 fixture). Measure, judge, repair, one Telegram line.\n\n'
        printf '## STANDING, PERMANENT: the box goes ham 24x7 (Nish 2026-09-10; every judge, every run, never delete this section)\n'
        printf 'Idle capacity next to ready work is a FAULT. vmstat 3 2 | tail -1 every run.\n\n'
    } >"$prompts_dir/$slug.md"
    # Fill to the requested size with trimmable '## ' sections, oldest-first
    # ordering so the LAST sections are the lowest priority (trimmed first).
    while (( $(wc -c <"$prompts_dir/$slug.md") < total )); do
        printf '%s\n' "$head"
        printf '%s\n' "1. open FAILED-COMMAND-SWALLOWED alarm row — probe, then file or repair (scan 2026-09-11)."
        printf '2. stuck alert-repair packet row fleet-ops#5647 family — bounded stay check (fleet-ops#5739).\n'
    done >>"$prompts_dir/$slug.md"
}

run_slug() {
    rm -f "$stdin_bytes" "$seat_calls"
    set +e
    "$bin" "$1" >"$scratch/run.out" 2>"$scratch/run.err"
    RUNRC=$?
    set -e
}

# --- scenario 1: packet sized just over the cap -> trimmed, run proceeds ----
# 75495 bytes = the live overflow observed 2026-09-11T19:00Z (+0.7%).
build_packet over1 75495
set +e
"$bin" over1 >"$scratch/run1.out" 2>"$scratch/run1.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario 1: trimmable packet ran to 75495B > cap must be TRIMMED and run, got exit $rc (stderr: $(tail -3 "$scratch/run1.err"; ls -l "$stdin_file" 2>/dev/null))"
[[ -s "$stdin_bytes" ]] || fail "scenario 1: pi must be spawned after the trim"
got_bytes=$(cat "$stdin_bytes")
(( got_bytes <= 75000 )) || fail "scenario 1: assembled packet is ${got_bytes}B > the 75000B cap"
grep -q 'PROMPT TRIMMED' "$scratch/run1.err" \
  || fail "scenario 1: stderr must announce the trim, got: $(cat "$scratch/run1.err" | tail -3)"
grep -q 'STANDING' "$stdin_file" \
  || fail "scenario 1: protected STANDING section must survive the trim"
grep -q 'One-off follow-through' "$seat_calls" \
  || fail "scenario 1: trim log must NAME the dropped sections, got: $(cat "$seat_calls")"
grep -q 'trim total' "$seat_calls" \
  || fail "scenario 1: trim log must report totals (sections dropped + bytes saved)"
ok "scenario 1: 75495B packet trimmed under cap, run proceeded, sections named in the log"

# --- scenario 2: fixture at ~2x the cap still produces a fitting packet -----
build_packet huge2 149000
set +e
"$bin" huge2 >"$scratch/run2.out" 2>"$scratch/run2.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario 2: ~2x cap fixture must still run (trim is unbounded), got $rc (stderr: $(tail -3 "$scratch/run2.err"))"
got_bytes=$(cat "$stdin_bytes")
(( got_bytes <= 75000 )) || fail "scenario 2: assembled packet is ${got_bytes}B > cap at ~2x fixture size"
ok "scenario 2: 149000B fixture (2x cap) trimmed to a fitting packet — unbounded-growth proof"

# --- scenario 3: no trimmable sections -> #5309 fail-loud refusal stays ----
# Plain prose packet over the cap with zero '## ' sections: there is nothing
# to drop, so the loud refusal (exit 1, no spawn) must remain.
head -c 80000 /dev/zero | tr '\0' 'x' | sed 's/x/prose line of the flat packet without any markdown sections.\\n/g' >"$scratch/flat_raw"
head -c 80000 /dev/zero | tr '\0' 'p' | fold -w 78 | sed 's/^p*$/flat line of the packet without any markdown sections/' >"$prompts_dir/flat.md"
# Build deterministically: 1100 lines of ~76 bytes = ~83KB.
printf 'flat packet line without markdown sections, repeated to exceed the cap. 00000\n' | head -c 0 >/dev/null
: >"$prompts_dir/flat.md"
for i in $(seq 1 1100); do printf 'flat packet line %04d without markdown sections, just prose filler text here.\n' "$i"; done >>"$prompts_dir/flat.md"
rm -f "$stdin_bytes"
set +e
"$bin" flat >"$scratch/run3.out" 2>"$scratch/run3.err"
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario 3: untrimmable oversize packet must still exit 1 (fail-loud), got $rc"
grep -q 'PROMPT TOO LARGE' "$scratch/run3.err" \
  || fail "scenario 3: fail-loud refusal line must be kept for non-trimmable overflow"
[[ ! -s "$stdin_bytes" ]] \
  || fail "scenario 3: pi must NOT be spawned on an untrimmable packet"
ok "scenario 3: non-trimmable overflow still fails loud with PROMPT TOO LARGE (fleet-ops#5309 kept)"

# --- scenario 4: cap value untouched ---------------------------------------
grep -n 'PROMPT_E2BIG_CAP_BYTES:-75000' "$bin" >/dev/null \
  || fail "scenario 4: PROMPT_E2BIG_CAP_BYTES default must stay 75000 (the cap itself must not change)"
ok "scenario 4: PROMPT_E2BIG_CAP_BYTES=75000 cap unchanged"

# --- class lock: protected-section contract pinned in isolation ------------
# Extract the trimmer itself from bin/agent-cron-run and drive it on a toy
# packet: the STANDING / "never delete this section" section must survive
# while trailing trimmable sections are dropped, even at a tiny cap.
sec_src="$(sed -n '/^trim_packet_sections()/,/^}/p' "$bin")"
[[ -n "$sec_src" ]] || fail "class lock: trim_packet_sections missing from agent-cron-run"
printf 'preamble rank-one motives text stays here.\n\n## STANDING, PERMANENT: ham 24x7 (never delete this section)\nprotected body line.\n## One-off: alarm rows\nold alarm row 1\nold alarm row 2\n' >"$scratch/prot.md"
bash -c "$sec_src; trim_packet_sections \"$scratch/prot.md\" \"$scratch/prot.out\" 40" >"$scratch/prot.log" 2>&1
[[ "$(tail -1 "$scratch/prot.out")" == "protected body line." ]] \
  || fail "class lock: STANDING/never-delete sections must survive the trim, got: $(tail -3 "$scratch/prot.out")"
grep -q 'trim: dropped section' "$scratch/prot.log" \
  || fail "class lock: per-section drop lines must name what was dropped"

ok "agent-cron packet size trim: over-cap packet trims under cap deterministically, 2x-cap fixture fits, non-trimmable overflow still fails loud, cap unchanged"
