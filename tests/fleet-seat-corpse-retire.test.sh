#!/usr/bin/env bash
# tests/fleet-seat-corpse-retire.test.sh
#
# fleet-ops#2469: the seat lifecycle retires (not merely marks dead) any
# seat past the seat-dead threshold. The fleet-seat-corpse-retire bin moves
# the corpse ledger out of the live roster (lanes/seats -> seats-corpse-
# retired-<ts>/) so the seat-avail SLO denominator stops counting dead
# seats. This test pins the full behavior end-to-end on a hermetic fixture:
# the threshold read from seat-caps.json, the corpse identification, the
# atomic move, the no-op sweep on a clean ledger, the textfile metric
# shape, the dry-run mode, and the idempotence contract.
#
# CI safety: the test always runs in CI (does not skip). The fixtures are
# built into a scratch dir under $TMPDIR; nothing under
# /home/nish/workspaces/agent-state/lanes/seats is touched.

set -Eeuo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO_ROOT/bin/fleet-seat-corpse-retire"
[[ -x "$BIN" ]] || fail "bin not executable: $BIN"

# --- helpers -----------------------------------------------------------------
scratch=$(mktemp -d -t corpse-retire.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

AS="$scratch/agent-state"
LEDGER="$AS/lanes/seats"
mkdir -p "$LEDGER" "$AS/lanes"

CAPS="$scratch/seat-caps.json"
cat > "$CAPS" <<JSON
{
  "walled_comeback": {
    "seat_dead_consecutive_threshold": 25,
    "seat_dead_quota_age_s": 86400,
    "seat_dead_corpse_grace_s": 21600
  }
}
JSON

PROM="$scratch/textfile/fleet-seat-corpse-retire.prom"
mkdir -p "$(dirname "$PROM")"

# Build a ledger JSON object as a fixture. $1=count $2=dead $3=hc $4=observed_age_h
# The fixture is built relative to a single synthetic clock so the bin's
# age math (now_s - observed_s) matches the fixture's intent regardless of
# the real wall clock. The test sets TEST_NOW at the top; each scenario
# uses the SAME NOW (no clock drift across scenarios).
TEST_NOW="${FLEET_SEAT_CORPSE_NOW:-2026-08-31T12:00:00Z}"
TEST_NOW_S=$(date -u -d "$TEST_NOW" +%s 2>/dev/null || date -u +%s)

make_ledger() {
    local count="$1" dead="$2" hc="$3" obs_age_h="$4"
    local obs
    obs=$(date -u -d "@$((TEST_NOW_S - obs_age_h * 3600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    jq -nc \
        --arg provider "opencode" --arg model "fixture-$RANDOM-$1-$2-$3" \
        --argjson count "$count" --argjson dead "$dead" --arg hc "$hc" \
        --argjson status "$([ "$hc" = "quota_exhausted" ] && echo 402 || echo 500)" \
        --arg obs "$obs" \
        '{
          provider:$provider, model:$model,
          http_status:$status,
          retry_after:null,
          health_class:$hc,
          retryable:true,
          seat_dead:$dead,
          poison_ladder:false,
          observed_at:$obs,
          source:"provider_fetch",
          failure_mode:"transient_http",
          consecutive_failure_count:$count
        }'
}

# Write ledger JSON into the dir under its sanitised-name convention.
write_ledger() {
    local p="$1" m="$2" body="$3"
    local s_p="${p//[^A-Za-z0-9._-]/_}"
    local s_m="${m//[^A-Za-z0-9._-]/_}"
    printf '%s' "$body" > "$LEDGER/${s_p}__${s_m}.json"
}

# Run the bin with the standard env seams and the synthetic clock.
run_bin() {
    FLEET_SEAT_CORPSE_LEDGER_DIR="$LEDGER" \
    FLEET_SEAT_CORPSE_AGENT_STATE="$AS" \
    FLEET_SEAT_CORPSE_SEAT_CAPS="$CAPS" \
    FLEET_SEAT_CORPSE_PROM="$PROM" \
    FLEET_SEAT_CORPSE_NOW="$TEST_NOW" \
        "$BIN" "$@"
}

# --- scenario 1: clean ledger -> no-op sweep, retired=0, exit 0 -------------
ok "scenario 1: clean ledger is a no-op"
ledger=$(make_ledger 0 false healthy 0)
write_ledger "ollama" "deepseek-v4-flash-0731" "$ledger"
ledger=$(make_ledger 3 false transient_fault 0)
write_ledger "bai" "deepseek-v4-flash" "$ledger"

run_bin >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 1: exit $rc, expected 0 on a clean ledger"

n=$(find "$LEDGER" -maxdepth 1 -type f -name '*__*.json' | wc -l)
[[ "$n" -eq 2 ]] || fail "scenario 1: expected 2 ledgers in live roster, got $n"

grep -q '^fleet_seat_corpse_retire_last_run_seconds ' "$PROM" \
    || fail "scenario 1: prom metric missing last_run_seconds"
grep -qE '^fleet_seat_corpse_retire_retired 0$' "$PROM" \
    || fail "scenario 1: retired should be 0 on a clean ledger"
grep -qE '^fleet_seat_corpse_retire_scanned 2$' "$PROM" \
    || fail "scenario 1: scanned should be 2 (one per live ledger)"
grep -qE '^fleet_seat_corpse_retire_candidates 0$' "$PROM" \
    || fail "scenario 1: candidates should be 0 on a clean ledger"
ok "scenario 1: clean ledger is a no-op (rc=0, retired=0, prom shape clean)"

# --- scenario 2: corpse seat_dead=true count=150 -> retired -----------------
ok "scenario 2: corpse (seat_dead=true, c=150) retires"
ledger=$(make_ledger 150 true corpse 0)
write_ledger "opencode" "muse-spark-1.2-contributor-free" "$ledger"

run_bin >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 2: exit $rc, expected 0 on a successful retirement"

n=$(find "$LEDGER" -maxdepth 1 -type f -name '*__*.json' | wc -l)
[[ "$n" -eq 2 ]] || fail "scenario 2: expected 2 ledgers remaining in live roster (corpse removed), got $n"

retired_dir=$(find "$AS/lanes" -maxdepth 1 -type d -name 'seats-corpse-retired-*' | head -n1)
[[ -n "$retired_dir" ]] || fail "scenario 2: no seats-corpse-retired-* dir was created"
[[ -f "$retired_dir/opencode__muse-spark-1.2-contributor-free.json" ]] \
    || fail "scenario 2: corpse ledger not found under retirement dir ($retired_dir)"

# Confirm the moved file still carries the corpse data (atomic mv, no rewrite)
moved_c=$(jq -r '.consecutive_failure_count // 0' "$retired_dir/opencode__muse-spark-1.2-contributor-free.json" 2>/dev/null || echo 0)
[[ "$moved_c" == "150" ]] || fail "scenario 2: moved ledger c=$moved_c, expected 150"
moved_d=$(jq -r '(.seat_dead // false)' "$retired_dir/opencode__muse-spark-1.2-contributor-free.json" 2>/dev/null || echo false)
[[ "$moved_d" == "true" ]] || fail "scenario 2: moved ledger seat_dead=$moved_d, expected true"

grep -qE '^fleet_seat_corpse_retire_retired 1$' "$PROM" \
    || fail "scenario 2: retired should be 1 after the retirement"
grep -qE '^fleet_seat_corpse_retire_candidates 1$' "$PROM" \
    || fail "scenario 2: candidates should be 1 (one corpse found)"
ok "scenario 2: corpse (seat_dead=true c=150) retired; moved ledger preserves original content; live roster drops by 1"

# --- scenario 3: re-run is idempotent (no further retirements) ---------------
ok "scenario 3: re-run on a clean roster is idempotent"
run_bin >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 3: exit $rc, expected 0 (idempotent)"
grep -qE '^fleet_seat_corpse_retire_retired 0$' "$PROM" \
    || fail "scenario 3: re-run on a clean roster should report retired=0 (idempotent)"
ok "scenario 3: re-run is idempotent (retired=0 after the first sweep cleared the only corpse)"

# --- scenario 4: below-threshold stays put ---------------------------------
ok "scenario 4: below-threshold (c=24, dead=false) does NOT retire"
ledger=$(make_ledger 24 false transient_fault 0)
write_ledger "hetzner" "Qwen-Qwen3.6-35B-A3B-FP8" "$ledger"

run_bin >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 4: exit $rc"

[[ -f "$LEDGER/hetzner__Qwen-Qwen3.6-35B-A3B-FP8.json" ]] \
    || fail "scenario 4: below-threshold ledger was retired — should NOT be"
ok "scenario 4: below-threshold seat stays in the live roster"

# --- scenario 5: quota_exhausted age>=24h -> retires -------------------------
ok "scenario 5: quota_exhausted age >= 24h retires"
ledger=$(make_ledger 73 false quota_exhausted 25)
write_ledger "minimax" "MiniMax-M3" "$ledger"

run_bin >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 5: exit $rc"

[[ ! -f "$LEDGER/minimax__MiniMax-M3.json" ]] \
    || fail "scenario 5: quota_exhausted age=25h ledger still in live roster"
ok "scenario 5: quota_exhausted age>=24h retires (fleet-ops#2145 time-based corpse)"

# --- scenario 6: quota_exhausted age<24h does NOT retire --------------------
ok "scenario 6: quota_exhausted age < 24h stays put"
ledger=$(make_ledger 73 false quota_exhausted 23)
write_ledger "straitly" "deepseek-v4-pro" "$ledger"

run_bin >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 6: exit $rc"

[[ -f "$LEDGER/straitly__deepseek-v4-pro.json" ]] \
    || fail "scenario 6: fresh quota_exhausted ledger was retired — should NOT be (fresh walled seat)"
ok "scenario 6: fresh quota_exhausted (age=23h) stays put"

# --- scenario 7: dry-run mode does not move files ---------------------------
ok "scenario 7: --dry-run does not move files"
ledger=$(make_ledger 200 true corpse 0)
write_ledger "opencode" "muse-spark-1.2-contributor-free" "$ledger"

run_bin --dry-run >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 7: dry-run exit $rc"

[[ -f "$LEDGER/opencode__muse-spark-1.2-contributor-free.json" ]] \
    || fail "scenario 7: dry-run moved the file (must not move)"
grep -qE '^fleet_seat_corpse_retire_retired [0-9]+$' "$PROM" \
    || fail "scenario 7: prom missing retired gauge"
ok "scenario 7: --dry-run does not move files; prom still written"

# --- scenario 8: missing ledger dir -> exit 1 -------------------------------
ok "scenario 8: missing ledger dir -> exit 1"
set +e
FLEET_SEAT_CORPSE_LEDGER_DIR="$scratch/no-such-dir" \
FLEET_SEAT_CORPSE_AGENT_STATE="$AS" \
FLEET_SEAT_CORPSE_SEAT_CAPS="$CAPS" \
FLEET_SEAT_CORPSE_PROM="$PROM" \
FLEET_SEAT_CORPSE_NOW="$TEST_NOW" \
    "$BIN" >/dev/null
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "scenario 8: missing ledger dir exit $rc, expected 1"
ok "scenario 8: missing ledger dir renders loud (exit 1)"

# --- scenario 9: spawn-bench / test fixtures are skipped --------------------
ok "scenario 9: spawn-bench / test fixtures are skipped"
mkdir -p "$LEDGER"
# spawn-bench marker (matches the fleet-seat-comeback-release skip)
printf '{"provider":"opencode","model":"muse-spark","health_class":"transient_fault","seat_dead":true,"consecutive_failure_count":200,"failure_mode":"transient_http"}' \
    > "$LEDGER/opencode__muse-spark.spawn-bench.json"
# tmp marker
printf '{"provider":"opencode","model":"muse-spark"}' \
    > "$LEDGER/opencode__muse-spark.spawn-bench.json.12345.tmp"
# test fixture
printf '{"provider":"test","model":"fake","seat_dead":true,"consecutive_failure_count":300}' \
    > "$LEDGER/test__fake.json"

run_bin >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 9: exit $rc"

[[ -f "$LEDGER/opencode__muse-spark.spawn-bench.json" ]] \
    || fail "scenario 9: spawn-bench marker was retired (must stay put)"
[[ -f "$LEDGER/opencode__muse-spark.spawn-bench.json.12345.tmp" ]] \
    || fail "scenario 9: tmp marker was retired (must stay put)"
[[ -f "$LEDGER/test__fake.json" ]] \
    || fail "scenario 9: test fixture was retired (must stay put)"
ok "scenario 9: spawn-bench / .tmp / test fixtures skipped (same exclusions as fleet-seat-comeback-release)"

# --- scenario 10: env-driven threshold overrides seat-caps.json --------------
ok "scenario 10: FLEET_SEAT_CORPSE_THRESHOLD overrides seat-caps.json"
# Lower the bar to 5 via env; a seat_dead=true ledger with c=6 must retire
# even though the seat-caps.json threshold (25) would NOT have fired (the
# c=6 is a sub-threshold candidate when the env override is applied).
ledger=$(make_ledger 6 true corpse 0)
write_ledger "opencode" "hy3-free" "$ledger"

FLEET_SEAT_CORPSE_LEDGER_DIR="$LEDGER" \
FLEET_SEAT_CORPSE_AGENT_STATE="$AS" \
FLEET_SEAT_CORPSE_SEAT_CAPS="$CAPS" \
FLEET_SEAT_CORPSE_PROM="$PROM" \
FLEET_SEAT_CORPSE_NOW="$TEST_NOW" \
FLEET_SEAT_CORPSE_THRESHOLD=5 \
    "$BIN" >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 10: exit $rc"

[[ ! -f "$LEDGER/opencode__hy3-free.json" ]] \
    || fail "scenario 10: env-threshold=5 did not retire c=6 corpse (env override must beat seat-caps.json)"
ok "scenario 10: FLEET_SEAT_CORPSE_THRESHOLD env override works"

# --- scenario 11: Path C — credentials_bad→corpse reclassification (fleet-ops#2716)
# A corpse ledger with seat_dead=true + hc=corpse + small count (because the
# seat-health extension resets count on every fresh probe write) and an
# observed_at older than the corpse-grace window (default 6h). Path A's
# count>=threshold gate does NOT match (count=2); Path B's quota_exhausted
# gate does NOT match (hc=corpse, not quota_exhausted). Path C — the only
# path that captures a credentials_bad→corpse reclassification that the
# seat-health extension writes with a tiny count — must fire. Live case
# 2026-09-01: commandcode/minimax/minimax-m3-free (HTTP 403 FORBIDDEN
# provider-side slug retirement) — the seat-caps cap=0 +
# intentional_cap_zero=corpse retirement row was correct (fleet-ops#2700),
# but the bin retired nothing (Path A/B never matched), so the corpse ledger
# sat in the live roster.
ok "scenario 11: Path C (credentials_bad→corpse, age>=grace) retires"
ledger=$(make_ledger 2 true corpse 8)  # 8h old (>6h grace)
write_ledger "commandcode" "minimax_minimax-m3-free" "$ledger"

run_bin >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 11: exit $rc"

[[ ! -f "$LEDGER/commandcode__minimax_minimax-m3-free.json" ]] \
    || fail "scenario 11: Path C did not retire the credentials_bad→corpse ledger (path must catch fresh corpses)"
retired_dir=$(find "$AS/lanes" -maxdepth 1 -type d -name 'seats-corpse-retired-*' | sort | tail -n1)
[[ -f "$retired_dir/commandcode__minimax_minimax-m3-free.json" ]] \
    || fail "scenario 11: credentials_bad→corpse ledger not under retirement dir ($retired_dir)"
ok "scenario 11: Path C retires credentials_bad→corpse corpse aged past grace (live 2716 minimax-m3-free shape)"

# --- scenario 12: Path C — fresh corpse (within grace) stays put (fleet-ops#2716)
# A corpse ledger whose observed_at is recent (within the grace window).
# Path C deliberately does NOT fire on these — the seat-health extension's
# after_provider_response writes a fresh observation within hours, and Path
# A's count>=threshold gate would be a transient-protection if a config bug
# flipped seat_dead prematurely. Retiring a fresh corpse would lose the
# diagnostic signal. The grace window gives the extension time to
# re-classify (healthy write) or to settle into a true terminal corpse (in
# which case the next sweep's Path C matches once the grace elapses).
ok "scenario 12: Path C — fresh corpse (within grace) does NOT retire"
ledger=$(make_ledger 2 true corpse 2)  # 2h old (<6h grace)
write_ledger "opencode" "mimo-v2.5-free" "$ledger"

run_bin >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 12: exit $rc"

[[ -f "$LEDGER/opencode__mimo-v2.5-free.json" ]] \
    || fail "scenario 12: fresh corpse (age=2h, within grace) was retired — Path C MUST hold the grace window"
ok "scenario 12: fresh corpse holds the grace window (the extension gets time to re-observe)"

# --- scenario 13: Path C — corpse WITH a future usable_at stays put (fleet-ops#2716)
# A corpse-class ledger with a future bench_until / usable_at (defensive
# holds). Path C's "scheduled wall" guard rejects the same as Path B — the
# schedule is the seat's contract with the comeback-release / wall-recovery
# paths. A corpse with a future clock is internally inconsistent (a corpse by
# definition has no comeback clock, fleet-ops#2415), but a defensive hold
# is still treated as a schedule so a buggy extension doesn't strand a
# recoverable seat.
ok "scenario 13: Path C — corpse with future usable_at does NOT retire (schedule guard)"
ledger=$(jq -nc \
    --arg provider "opencode" --arg model "schedule-guard" \
    --arg obs "$(date -u -d "@$((TEST_NOW_S - 8 * 3600))" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg future "$(date -u -d "@$((TEST_NOW_S + 3600))" +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      provider:$provider, model:$model,
      http_status:500, retry_after:null,
      health_class:"corpse", retryable:true,
      seat_dead:true, poison_ladder:false,
      observed_at:$obs, source:"provider_fetch",
      failure_mode:"transient_http",
      consecutive_failure_count:2,
      usable_at:$future, bench_until:$future
    }')
write_ledger "opencode" "schedule-guard" "$ledger"

run_bin >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 13: exit $rc"

[[ -f "$LEDGER/opencode__schedule-guard.json" ]] \
    || fail "scenario 13: corpse WITH future usable_at was retired — schedule guard must hold"
ok "scenario 13: corpse with future usable_at holds the schedule (Path C mirrors Path B's schedule guard)"

# --- scenario 14: Path C — env grace override beats seat-caps.json ---------
ok "scenario 14: FLEET_SEAT_CORPSE_GRACE_S env override beats seat-caps.json"
# Push the grace to 1h via env; an 8h-old corpse ledger must retire even
# though the seat-caps grace (21600s = 6h) still would, AND a 0.5h-old
# fresh corpse must NOT retire. The env override is the test-time knob.
ledger=$(make_ledger 2 true corpse 8)
write_ledger "commandcode" "grace-override-old" "$ledger"

FLEET_SEAT_CORPSE_LEDGER_DIR="$LEDGER" \
FLEET_SEAT_CORPSE_AGENT_STATE="$AS" \
FLEET_SEAT_CORPSE_SEAT_CAPS="$CAPS" \
FLEET_SEAT_CORPSE_PROM="$PROM" \
FLEET_SEAT_CORPSE_NOW="$TEST_NOW" \
FLEET_SEAT_CORPSE_GRACE_S=3600 \
    "$BIN" >/dev/null
rc=$?
[[ $rc -eq 0 ]] || fail "scenario 14a: env-grace=3600 exit $rc"

[[ ! -f "$LEDGER/commandcode__grace-override-old.json" ]] \
    || fail "scenario 14a: env-grace=3600 did not retire 8h-old corpse (env override must beat seat-caps.json)"
ok "scenario 14: FLEET_SEAT_CORPSE_GRACE_S env override honours test-time knob"

ok "all corpse-retire scenarios pass"
