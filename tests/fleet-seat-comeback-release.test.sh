#!/usr/bin/env bash
# tests/fleet-seat-comeback-release.test.sh
#
# fleet-ops#2421: the ACTIVE release path for walled seats. A seat whose
# wall clock (bench_until ?? usable_at) has passed is re-probed through the
# real router with a TOOL-USING probe (pi --print): a bash-compute packet whose computed token must appear in the output; an inline-only PONG-ok answer does NOT release (tool-503 stays benched)— on a successful probe
# the seat is UNWALLED (healthy observation written to the ledger); on a
# failed probe it stays walled and the extension re-anchors. Loud check:
# after the sweep, walled seats still holding EXPIRED wall clocks with
# nothing released -> exit 1 + fleet_seat_comeback_release_stalled=1.
#
# This test builds a scratch SEATS_DIR with known fixtures and a stub
# PI_BIN (never touches the real pi / real ledger), then asserts:
#   - selection: only genuinely-expired walled seats are probed; test__
#     fixtures, .spawn-bench pseudo-seats, corpses (except the
#     fleet-ops#3156 no-wall prober-corpse subclass) and future-wall seats
#     are never probed (the two predecessor-killer bugs, fleet-ops#2394).
#   - release: a successful probe unwalls the seat (health_class=healthy,
#     usable_at/bench_until null, count 0) -> released_total increments,
#     last-green written, exit 0.
#   - loud stall: a failed probe with no re-anchor leaves the seat expired
#     -> released_this_run=0 -> exit 1 + stalled=1 + no last-green.
#   - override: a wall-expired seat probed within MIN_INTERVAL_S is
#     re-probed anyway (the stale-wall unstick path, fleet-ops#2421
#     follow-up 2026-08-31 straitly/gpt-5.6-sol — a timeout leaves the
#     extension unable to re-anchor, so the wall stays stale and the
#     min-interval would otherwise block re-probing forever).
#   - future-wall: a seat whose usable_at is still in the future is
#     never probed (the wall-in-future check is the only remaining
#     throttle; it precedes the min-interval check).
#   - overdue-clears (fleet-ops#2520): the FleetSeatComebackOverdue alert
#     keys on the metrics-side fleet_seat_comeback_overdue_total, exported
#     from _read_comeback_overdue against the SAME ledger. A past-wall
#     seat must count overdue BEFORE the sweep; after the sweep the count
#     must be 0 — probed+unwalled on a successful probe, or re-benched
#     into the future on a probe failure (the #2493 timeouts). The count
#     legitimately stays 1 only in the one stuck case: the wall cannot be
#     advanced (read-only ledger, section 3c).
#   - retirement (fleet-ops#2716): a corpse ledger (seat_dead=true,
#     health_class=corpse) whose observed_at has aged past the corpse
#     grace window (default 6h) is PHYSICALLY moved out of the live
#     roster into a dated lanes/seats-corpse-retired-<UTC-ts>/ dir; a
#     fresh corpse (inside grace) or a corpse still carrying a future
#     wall clock is held. This is the terminal step of the seat
#     lifecycle this organ owns (seat-caps.json retiring the slug only
#     stops the rotation, #2708).
#   - comeback-release stuck corpses (fleet-ops#3156/#3229): a no-wall
#     corpse from a RECOVERABLE source — the PROBER-created no-wall corpse
#     (failure_mode comeback_never_released, wall null) AND a no-wall corpse
#     from a transient failure mode (rate_limit / transient_http / cli_timeout
#     / transient_other / empty_run / overload) — is the lived seats_dead
#     stuck case: inside its 6h grace nothing releases or retires it. It now
#     gets ONE second-chance re-probe: on success it is UNWALLED (transitions
#     OUT of corpse). fleet-ops#3508: a FAILED rate_limit re-probe that does
#     NOT establish a wall is a BOUNDED COMEBACK, not a retire — a 429
#     resets over a bounded window, so the corpse is re-anchored to
#     usable_at=now+walled_comeback.rate_limit_s (default 900s) and re-enters
#     the walled path; only a non-recoverable failed re-probe (the stuck
#     prober corpse, comeback_never_released) is RETIRED immediately (grace
#     bypass). A no-wall corpse from a PERMANENT class (credentials_bad
#     401/403, quota_exhausted-by-age 402) and any corpse still owed a
#     comeback clock stay held/terminal.
#
# Sandbox: scratch SEATS_DIR/state/prom + stub pi only. No live ledger,
# no live pi, no systemd.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
BIN="$repo_root/bin/fleet-seat-comeback-release"
# fleet-ops#2661: bin/fleet-seat-comeback-release sources seat-lib.sh
# (seat_ledger_path + _record_learned_cap) for the overload-strike +
# provider-wide wall. The bin's `[[ -f "$SEAT_LIB" ]]` guard makes the
# source OPTIONAL — on hosted CI $HOME/.local/lib/pi-packet/seat-lib.sh
# is absent, seat-lib never loads, seat_is_overload_bench returns 1,
# register_overload_strike is never called, and the pong-ok test sees
# `got 0` strikes (PR #2685/#2687 P14 red). Point the bin at the in-repo
# seat-lib explicitly so the contract is "tests provide seat-lib", matching
# every other fleet-ops seat-lib test (pi-scout-seat-rotation,
# keystone-routing, pi-issue-run-*).
export PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# Metrics-side overdue count (_read_comeback_overdue in
# libexec/fleet-metrics-export.py) over $SEATDIR, evaluated at NOW_EPOCH
# (the sweep's frozen now). This is exactly what feeds
# fleet_seat_comeback_overdue_total, the FleetSeatComebackOverdue alert
# source — asserting 0 here proves the sweep cleared the overdue metric.
overdue_n() {
    # $1 optional: explicit seat dir (defaults to the global $SEATDIR). The
    # metrics _read_comeback_overdue MUST see the SAME scratch seat-caps the
    # bin sweep used (the module defaults point at the live config, which
    # lacks the test-only seats and would exclude them on a host where that
    # config exists — the pre-existing host-vs-CI nondeterminism removed
    # here, fleet-ops#3993). Mirrors tests/fleet-metrics-export.test.sh's
    # SEAT_CAPS_DEFAULT/SEAT_CAPS_FALLBACK wiring.
    local dir="${1:-$SEATDIR}"
    python3 - "$repo_root/libexec/fleet-metrics-export.py" "$dir" "$TMPD/seat-caps.json" "$NOW_EPOCH" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.SEAT_LEDGER = Path(sys.argv[2])
m.SEAT_CAPS_DEFAULT = Path(sys.argv[3])
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/seat-caps.json")
m.time.time = lambda: int(sys.argv[4])
cb_n, _ = m._read_comeback_overdue()
print(cb_n)
PY
}

command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 required (exporter overdue assertion, fleet-ops#2520)"

# Fixed NOW so the test is stable regardless of when it runs.
NOW_ISO="2026-08-30T12:00:00Z"
NOW_EPOCH=$(date -u -d "$NOW_ISO" +%s)

TMPD="$(mktemp -d -t seat-comeback-release.XXXXXX)"
SEATDIR="$TMPD/seats"
mkdir -p "$SEATDIR"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT INT TERM

# fleet-ops#3928: every `bash "$BIN"` below inherits this. The bin sources
# seat-lib, and its retire path (write_parked_ledger -> seat_log) must never
# append to the live watch.log — pin the audit line to the harness scratch
# instead of the production ~/.local/state/pi-packet/watch.log.
export SEAT_LOG_FILE="$TMPD/watch.log"
# fleet-ops#4819: pin the actions.log to the harness scratch so a test release
# never appends to the live alert-repair actions.log.
export FLEET_SEAT_COMEBACK_ACTIONS_LOG="$TMPD/actions.log"

# --- stub pi: SUCCESS stub exits 0 with "OK", FAILURE stub exits 1 -------
cat > "$TMPD/pi-tool-ok" <<'EOF'
#!/usr/bin/env bash
# A healthy tool-using probe: prints the computed token of `echo $((6*7))`
# and emits a PACKET-VERDICT tools=1 line on stderr (the authoritative
# tool-count signal the comeback-release probe parses, fleet-ops#4819).
printf 'PACKET-VERDICT tools=1 class=worked\n' >&2
printf '42\n'
exit 0
EOF
cat > "$TMPD/pi-pong-ok" <<'EOF'
#!/usr/bin/env bash
# A partial-storm seat: answers inline "OK" but no tool result (no token).
# Emits PACKET-VERDICT tools=0 class=no-tools on stderr — the standing-smoke
# shape that must NEVER release an empty-run bench (fleet-ops#4819).
printf 'PACKET-VERDICT tools=0 class=no-tools\n' >&2
printf 'OK\n'
exit 0
EOF
cat > "$TMPD/pi-fail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$TMPD/pi-timeout" <<'EOF'
#!/usr/bin/env bash
exit 124
EOF
# fleet-ops#3179: a failed probe that ALSO simulates the seat-health
# extension reclassifying the corpse DURING the probe. The real pi --print
# triggers the extension, which writes a new ledger entry on a real HTTP
# response (e.g. 402 quota_exhausted re-writes health_class=quota_exhausted,
# seat_dead=false, usable_at 24h in the future). This stub mirrors that
# race: it rewrites the seat's ledger file with a walled non-corpse entry
# THEN exits 1 (probe failure — no tool token in the output).
cat > "$TMPD/pi-fail-reclassify" <<'EOF'
#!/usr/bin/env bash
# Simulate the seat-health extension reclassifying a corpse during a
# failed probe. Derive the ledger file from --provider/--model args and
# PI_SEAT_HEALTH_LEDGER_DIR, rewrite it with a walled non-corpse entry,
# then exit 1 (probe failure — no tool token in the output).
_provider="" _model=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider) _provider="$2"; shift 2 ;;
        --model) _model="$2"; shift 2 ;;
        *) shift ;;
    esac
done
_ledger_dir="${PI_SEAT_HEALTH_LEDGER_DIR:-}"
if [[ -n "$_provider" && -n "$_model" && -n "$_ledger_dir" ]]; then
    _base="${_provider}__${_model//\//_}.json"
    _seat_file="$_ledger_dir/$_base"
    if [[ -f "$_seat_file" ]]; then
        now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
        future=$(date -u -d "@$(($(date -u +%s) + 86400))" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || echo "$now")
        tmp="$_seat_file.$$.tmp"
        jq -nc --arg provider "$_provider" --arg model "$_model" \
            --arg now "$now" --arg future "$future" \
            '{provider:$provider, model:$model, http_status:402, retry_after:null,
              health_class:"quota_exhausted", retryable:true, seat_dead:false,
              poison_ladder:false, observed_at:$now, source:"provider_fetch",
              failure_mode:"quota_exhausted", usable_at:$future,
              consecutive_failure_count:44}' > "$tmp" 2>/dev/null && mv "$tmp" "$_seat_file" 2>/dev/null || true
    fi
fi
exit 1
EOF
# fleet-ops#3301: a failed probe that ALSO simulates the seat-health
# extension re-anchoring a 429 retry window DURING the probe. Live
# 2026-09-04T16:30Z: pi --print on mimo-v2.5-free returned HTTP 429, the
# extension wrote usable_at +15min, rebench_seat skipped ("wall moved to
# the future"), then corpse_seat wiped that window to usable_at=null.
# This stub mirrors the extension write, then exits 1 (no tool token).
cat > "$TMPD/pi-fail-reanchor-429" <<'EOF'
#!/usr/bin/env bash
_provider="" _model=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider) _provider="$2"; shift 2 ;;
        --model) _model="$2"; shift 2 ;;
        *) shift ;;
    esac
done
_ledger_dir="${PI_SEAT_HEALTH_LEDGER_DIR:-}"
if [[ -n "$_provider" && -n "$_model" && -n "$_ledger_dir" ]]; then
    _base="${_provider}__${_model//\//_}.json"
    _seat_file="$_ledger_dir/$_base"
    if [[ -f "$_seat_file" ]]; then
        # Frozen future wall relative to FLEET_SEAT_COMEBACK_NOW=2026-08-30T12:00:00Z
        # (the live journal shape: observed_at=now, usable_at=now+15min).
        tmp="$_seat_file.$$.tmp"
        jq -nc --arg provider "$_provider" --arg model "$_model" \
            '{provider:$provider, model:$model, http_status:429, retry_after:null,
              health_class:"rate_limited", retryable:true, seat_dead:false,
              poison_ladder:false, observed_at:"2026-08-30T12:00:04.204Z",
              source:"provider_fetch", failure_mode:"rate_limit",
              usable_at:"2026-08-30T12:15:04.204Z",
              consecutive_failure_count:27}' > "$tmp" 2>/dev/null && mv "$tmp" "$_seat_file" 2>/dev/null || true
    fi
fi
exit 1
EOF
chmod +x "$TMPD/pi-tool-ok" "$TMPD/pi-pong-ok" "$TMPD/pi-fail" "$TMPD/pi-timeout" "$TMPD/pi-fail-reclassify" "$TMPD/pi-fail-reanchor-429"

# --- synthetic fixtures ---------------------------------------------------
# 1. Walled, wall clock EXPIRED, release-at-expiry class (overload_bench,
#    bench_until past). Probe owed -> released on success.
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF

# 2. Walled, wall clock EXPIRED, quota_exhausted (the issue's straitly
#    shape). Probe owed -> released on success.
cat > "$SEATDIR/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00.000Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":23}
EOF

# 3. Walled but wall clock in the FUTURE (held). Must NOT be probed.
cat > "$SEATDIR/opencode__nemotron-3-ultra-free.json" << 'EOF'
{"provider":"opencode","model":"nemotron-3-ultra-free","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T08:00:00Z","source":"after_provider_response","failure_mode":"rate_limit","usable_at":"2026-08-30T23:00:00.094Z","consecutive_failure_count":3}
EOF

# 4. test__ fixture (provider == "test"), wall EXPIRED. Must NEVER be
#    probed (the fleet-ops#2394 predecessor-killer).
cat > "$SEATDIR/test__test.json" << 'EOF'
{"provider":"test","model":"test","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-29T03:43:09.561Z","source":"after_provider_response","failure_mode":"rate_limit","usable_at":"2026-08-29T03:58:09.561Z","consecutive_failure_count":2}
EOF

# 5. .spawn-bench pseudo-seat, wall EXPIRED. Must NEVER be probed.
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.spawn-bench.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","usable_at":"2026-08-29T16:36:06Z","reason":"no_block:rc=0","written_at":"2026-08-29T16:31:06Z","backoff_s":300}
EOF

# 6. Corpse (seat_dead=true, class corpse), wall EXPIRED. Terminal
#    (fleet-ops#2327/#2415) — never probed, never released.
cat > "$SEATDIR/devin__glm-5-2.json" << 'EOF'
{"provider":"devin","model":"glm-5-2","http_status":503,"retry_after":null,"health_class":"corpse","retryable":true,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-29T00:00:00Z","source":"after_provider_response","failure_mode":"transient_http","usable_at":"2026-08-29T01:00:00Z","consecutive_failure_count":150}
EOF

# 7. Healthy seat. Never probed.
cat > "$SEATDIR/bai__deepseek-v4-flash.json" << 'EOF'
{"provider":"bai","model":"deepseek-v4-flash","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF

# fleet-ops#3737: a "healthy" ledger is not proof of release when the seat
# carries a fresh wrapper bench marker that is still its latest evidence —
# seat-health.ts writes healthy on a transport 200 during the very run that
# exits 0 with 0B stdout, so the bench survives only in the marker. The
# router holds such a seat for this organ's probe; an expired fresh marker
# owes a probe before re-admission.
#
# 7a. Healthy ledger + FRESH EXPIRED marker, marker is latest evidence
#     (ledger observed_at == marker written_at — the mid-run 200 clobber).
#     Probe owed -> released on success / re-benched on failure.
cat > "$SEATDIR/ollama__deepseek-v4-flash_0731.json" << 'EOF'
{"provider":"ollama","model":"deepseek-v4-flash:0731","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF
cat > "$SEATDIR/ollama__deepseek-v4-flash_0731.spawn-bench.json" << 'EOF'
{"provider":"ollama","model":"deepseek-v4-flash:0731","usable_at":"2026-08-30T11:15:00Z","reason":"pi-issue:fleet-ops-3737:provider-no-op:stdout=0B","written_at":"2026-08-30T11:00:00Z","backoff_s":900,"failure_mode":"empty_run","consecutive_failure_count":3,"writer":"mark_seat_empty_run"}
EOF
# 7b. Healthy ledger + fresh expired marker, but the ledger observation is
#     NEWER than the marker's written_at — a post-bench success already
#     proved the seat. Never probed.
cat > "$SEATDIR/minimax__m3-free.json" << 'EOF'
{"provider":"minimax","model":"m3-free","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:30:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF
cat > "$SEATDIR/minimax__m3-free.spawn-bench.json" << 'EOF'
{"provider":"minimax","model":"m3-free","usable_at":"2026-08-30T10:15:00Z","reason":"pi-issue:provider-no-op:stdout=0B","written_at":"2026-08-30T10:00:00Z","backoff_s":900,"failure_mode":"empty_run","consecutive_failure_count":1,"writer":"mark_seat_empty_run"}
EOF
# 7c. Healthy ledger + STALE marker (written >24h ago — archaeology).
#     Never probed; the marker no longer gates.
cat > "$SEATDIR/opencode__mimo-v2.5-free.json" << 'EOF'
{"provider":"opencode","model":"mimo-v2.5-free","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-29T11:00:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF
cat > "$SEATDIR/opencode__mimo-v2.5-free.spawn-bench.json" << 'EOF'
{"provider":"opencode","model":"mimo-v2.5-free","usable_at":"2026-08-29T11:15:00Z","reason":"pi-issue:provider-no-op:stdout=0B","written_at":"2026-08-29T11:00:00Z","backoff_s":900,"failure_mode":"empty_run","consecutive_failure_count":2,"writer":"mark_seat_empty_run"}
EOF

STATE="$TMPD/state.json"
PROM="$TMPD/release.prom"

# fleet-ops#3661: the sweep now rejects phantom seat keys (a provider/model
# pair not present in seat-caps.json providers.<p>.models.<m>) with a LOUD
# SEAT-KEY-INVALID line and never probes them. Point the sweep at a scratch
# caps fixture that includes every seat the fixtures below use, so the guard
# is exercised deterministically (the real seat-caps.json is absent on hosted
# CI and would otherwise fail-open).
cat > "$TMPD/seat-caps.json" <<'CAPS'
{
  "providers": {
    "bai": {"models": {"deepseek-v4-flash": 1}},
    "cline": {"models": {"z-ai/glm-5.3-flash": 1}},
    "commandcode": {"models": {"poolside/laguna-s-2.1-free": 1, "minimax/minimax-m3-free": 0}},
    "devin": {"models": {"glm-5-2": 1}},
    "hetzner": {"models": {"Qwen/Qwen3.6-35B-A3B-FP8": 0}},
    "minimax": {"models": {"m3-free": 1}},
    "ollama": {"models": {"deepseek-v4-flash:0731": 1}},
    "opencode": {"models": {"hy3-free": 1, "mimo-v-2.5-free": 1, "mimo-v2.5-free": 1, "nemotron-3-ultra-free": 1}},
    "straitly": {"models": {"deepseek/deepseek-v4-pro": 1, "deepseek-v4-pro": 1, "gpt-5.6-sol": 1}},
    "test": {"models": {"test": 1}},
    "xkiro": {"models": {"deepseek/deepseek-v4-pro": 1, "minimax/minimax-m3:free": 1}}
  }
}
CAPS
export SEAT_CAPS_JSON="$TMPD/seat-caps.json"

# --- 1. dry-run: selection ------------------------------------------------
out=$(PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" --dry-run 2>&1)
grep -q "would probe commandcode/poolside/laguna-s-2.1-free" <<<"$out" \
  || fail "dry-run: expired overload_bench seat must be selected for probe: $out"
grep -q "would probe straitly/gpt-5.6-sol" <<<"$out" \
  || fail "dry-run: expired quota_exhausted seat must be selected for probe: $out"
grep -qi "test__test" <<<"$out" && fail "dry-run: test__ fixture must never be probed: $out"
grep -qi "spawn-bench" <<<"$out" && fail "dry-run: spawn-bench pseudo-seat must never be probed: $out"
grep -qi "would probe devin/glm-5-2" <<<"$out" && fail "dry-run: corpse must never be probed: $out"
grep -qi "bai/deepseek" <<<"$out" && fail "dry-run: healthy seat must never be probed: $out"
grep -q "would probe ollama/deepseek-v4-flash:0731" <<<"$out" \
  || fail "dry-run: expired fresh marker on a healthy ledger must be probed (fleet-ops#3737): $out"
grep -q "would PONG-probe opencode/nemotron-3-ultra-free" <<<"$out" \
  || fail "dry-run: long non-money future wall must get the hourly PONG (fleet-ops#4640): $out"
grep -qi "would probe minimax/m3-free" <<<"$out" \
  && fail "dry-run: post-bench healthy observation releases the marker — must not be probed: $out"
grep -qi "would probe opencode/mimo-v2.5-free" <<<"$out" \
  && fail "dry-run: stale (>24h) marker is archaeology — must not be probed: $out"
# fleet-ops#2716: the devin corpse (observed 2026-08-29, ~36h old) IS past
# the 6h corpse grace — dry-run must PREVIEW its retirement but never act.
grep -q "would retire devin/glm-5-2" <<<"$out" \
  || fail "dry-run: aged corpse must be scanned for retirement: $out"
# Dry-run must not touch the ledger, state or prom.
[[ ! -e "$STATE" ]] || fail "dry-run must not write state"
[[ ! -e "$PROM" ]] || fail "dry-run must not write prom"
[[ ! -d "$TMPD/seats-corpse-retired-$NOW_ISO" ]] \
  || fail "dry-run must not create a corpse retirement dir"
[[ -f "$SEATDIR/devin__glm-5-2.json" ]] \
  || fail "dry-run must not move the corpse ledger"
grep -q '"health_class":"overload_bench"' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" \
  || fail "dry-run must not modify the ledger"
ok "dry-run selects owed expired-wall seats and PONG-probes long non-money future walls; test__/spawn-bench/healthy never probed, aged corpse previewed for retirement"

# --- 2. live run, probes SUCCEED: both seats released --------------------
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/live-ok.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "successful probes: expected exit 0, got $rc ($(cat "$TMPD/live-ok.err"))"
health=$(jq -r '.health_class' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$health" == "healthy" ]] || fail "overload_bench seat must be unwalled (healthy), got $health"
jq -e '.usable_at == null and .bench_until == null and .consecutive_failure_count == 0 and .seat_dead == false and .failure_mode == "none"' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "overload_bench seat healthy write must clear the wall and count: $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
health=$(jq -r '.health_class' "$SEATDIR/straitly__gpt-5.6-sol.json")
[[ "$health" == "healthy" ]] || fail "quota_exhausted seat must be unwalled (healthy), got $health"
# fleet-ops#3737: the marker-held healthy seat (7a) was probed and
# released — the unwall write refreshes observed_at past the marker's
# written_at, lifting the router's probe-gate hold. The marker itself is
# kept: its count stays the durable memory for the chronic-no-op merge.
obs=$(jq -r '.observed_at' "$SEATDIR/ollama__deepseek-v4-flash_0731.json")
[[ "$obs" == "$NOW_ISO" ]] \
  || fail "marker-held seat unwall must refresh observed_at to the sweep now ($NOW_ISO), got $obs"
mk_count=$(jq -r '.consecutive_failure_count' "$SEATDIR/ollama__deepseek-v4-flash_0731.spawn-bench.json")
[[ "$mk_count" == "3" ]] \
  || fail "marker must be kept intact on release (count memory for the chronic merge), got $mk_count"
# State + prom reflect the release.
released_total=$(jq -r '.released_total' "$STATE")
[[ "$released_total" == "3" ]] || fail "released_total must be 3, got $released_total"
grep -q "^fleet_seat_comeback_release_released_total 3$" "$PROM" \
  || fail "prom released_total must be 3: $(cat "$PROM")"
grep -q "^fleet_seat_comeback_release_stalled 0$" "$PROM" \
  || fail "prom stalled must be 0: $(cat "$PROM")"
grep -qE "^fleet_seat_comeback_release_last_green_seconds [0-9]+$" "$PROM" \
  || fail "prom last-green must be written on a green sweep: $(cat "$PROM")"
# fleet-ops#2716: the devin corpse (observed 2026-08-29T00:00:00Z, ~36h old)
# is past the 6h corpse grace — the live sweep must PHYSICALLY retire it out
# of the live roster: corpse ledger gone from SEATDIR, present in the dated
# seats-corpse-retired-<ts>/ audit dir, retired_total=1 in prom and state.
# fleet-ops#3669: retirement must leave the seat UNPICKABLE — a seat_dead=true
# / health_class=parked parked ledger is written back into the live roster so
# pick_seat refuses the seat instead of re-picking it via the no-ledger
# fail-open.
[[ -f "$SEATDIR/devin__glm-5-2.json" ]] \
  || fail "corpse retirement must leave a parked ledger in the live roster (fleet-ops#3669)"
_parked_hc=$(jq -r '.health_class // ""' "$SEATDIR/devin__glm-5-2.json" 2>/dev/null || true)
[[ "$_parked_hc" == "parked" ]] \
  || fail "parked ledger must be health_class=parked, got $_parked_hc"
_parked_dead=$(jq -r '.seat_dead // false' "$SEATDIR/devin__glm-5-2.json" 2>/dev/null || true)
[[ "$_parked_dead" == "true" ]] \
  || fail "parked ledger must be seat_dead=true, got $_parked_dead"
retdir="$TMPD/seats-corpse-retired-$NOW_ISO"
[[ -f "$retdir/devin__glm-5-2.json" ]] \
  || fail "retired corpse ledger must land in the dated retirement dir ($retdir): $(ls -la "$TMPD" 2>&1)"
grep -q "^fleet_seat_comeback_release_retired_total 1$" "$PROM" \
  || fail "prom retired_total must be 1: $(cat "$PROM")"
retired_total=$(jq -r '.retired_total' "$STATE")
[[ "$retired_total" == "1" ]] || fail "state retired_total must be 1, got $retired_total"
ok "successful probes release (unwall) both expired seats; corpse retired out of the roster; green prom, exit 0"

# --- 3. re-bench on probe failure (fleet-ops#2493) -----------------------
# The fleet-ops#2493 fix: a probe that fails with no real HTTP response
# (rc=124 timeout, or rc=1 generic failure) leaves the ledger with a
# STALE wall clock in the past. Without re-benching, the next 15-min
# tick finds the same expired wall, re-probes, re-fails, and the loop
# runs forever. Re-bench HERE on probe failure: advance usable_at and
# bench_until to now + REBENCH_BACKOFF_S so the next tick skips the
# seat (wall-in-future check) until the new window passes. The post-
# sweep expired count is 0 (re-benched) so the loud-stall check does
# NOT fire — the release path IS operating, it just couldn't unwall.
# Fresh scratch fixture set: the two expired seats only.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
cat > "$SEATDIR/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00.000Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":23}
EOF
# fleet-ops#3737: a healthy-ledger seat whose fresh expired wrapper marker
# is the latest evidence owes a probe; on failure the MARKER is re-benched
# (the ledger's healthy entry is untouched — the marker is the routing
# authority the router reads first).
cat > "$SEATDIR/ollama__deepseek-v4-flash_0731.json" << 'EOF'
{"provider":"ollama","model":"deepseek-v4-flash:0731","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF
cat > "$SEATDIR/ollama__deepseek-v4-flash_0731.spawn-bench.json" << 'EOF'
{"provider":"ollama","model":"deepseek-v4-flash:0731","usable_at":"2026-08-30T11:15:00Z","reason":"pi-issue:fleet-ops-3737:provider-no-op:stdout=0B","written_at":"2026-08-30T11:00:00Z","backoff_s":900,"failure_mode":"empty_run","consecutive_failure_count":3,"writer":"mark_seat_empty_run"}
EOF
STATE="$TMPD/state-fail.json"
PROM="$TMPD/release-fail.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/live-fail.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "re-bench path: expected exit 0 (re-benched, not loud), got $rc ($(cat "$TMPD/live-fail.err"))"
grep -q "REBENCHED commandcode/poolside/laguna-s-2.1-free" "$TMPD/live-fail.err" \
  || fail "re-bench: must log REBENCHED for the overload_bench seat: $(cat "$TMPD/live-fail.err")"
grep -q "REBENCHED straitly/gpt-5.6-sol" "$TMPD/live-fail.err" \
  || fail "re-bench: must log REBENCHED for the quota_exhausted seat: $(cat "$TMPD/live-fail.err")"
# The ledger now carries the fresh bench: usable_at and bench_until are
# in the future (now + 900s = 2026-08-30T12:15:00Z) and the source is
# comeback_release_rebench. The prior class is replaced (the wall is
# the truth now, not the prior failure class).
new_usable=$(jq -r '.usable_at' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
new_usable_epoch=$(date -u -d "$new_usable" +%s 2>/dev/null || echo 0)
(( new_usable_epoch > NOW_EPOCH )) || fail "re-bench: usable_at must be in the future, got $new_usable (epoch=$new_usable_epoch, now=$NOW_EPOCH)"
jq -e '.source == "comeback_release_rebench" and .failure_mode == "overload_503" and .health_class == "overload_bench" and .consecutive_failure_count == 6' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "re-bench: overload seat must PRESERVE overload_bench/overload_503 across re-bench (fleet-ops#2661), count incremented: $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
jq -e '.source == "comeback_release_rebench" and .consecutive_failure_count == 24' \
  "$SEATDIR/straitly__gpt-5.6-sol.json" >/dev/null \
  || fail "re-bench: quota seat count must increment: $(cat "$SEATDIR/straitly__gpt-5.6-sol.json")"
# fleet-ops#3737: the marker-held healthy seat was probed, failed, and its
# MARKER re-benched — usable_at advanced to the future, written_at
# refreshed to the sweep now, count incremented, mode preserved. The
# healthy ledger entry is left as-is (the marker is the routing authority).
grep -q "re-benched wrapper marker ollama/deepseek-v4-flash:0731" "$TMPD/live-fail.err" \
  || fail "marker re-bench: must log re-benched for the marker-held seat: $(cat "$TMPD/live-fail.err")"
jq -e '.failure_mode == "empty_run" and .consecutive_failure_count == 4 and .writer == "comeback_release_rebench" and .release_requires == "real-work-probe" and .citation == "fleet-ops#3737"' \
  "$SEATDIR/ollama__deepseek-v4-flash_0731.spawn-bench.json" >/dev/null \
  || fail "marker re-bench: count must increment, mode preserved, writer tagged, release_requires+citation injected (fleet-ops#4819): $(cat "$SEATDIR/ollama__deepseek-v4-flash_0731.spawn-bench.json")"
mk_usable=$(jq -r '.usable_at' "$SEATDIR/ollama__deepseek-v4-flash_0731.spawn-bench.json")
mk_usable_epoch=$(date -u -d "$mk_usable" +%s 2>/dev/null || echo 0)
(( mk_usable_epoch > NOW_EPOCH )) \
  || fail "marker re-bench: usable_at must be in the future, got $mk_usable"
mk_written=$(jq -r '.written_at' "$SEATDIR/ollama__deepseek-v4-flash_0731.spawn-bench.json")
[[ "$mk_written" == "$NOW_ISO" ]] \
  || fail "marker re-bench: written_at must refresh to the sweep now, got $mk_written"
# Prom reflects the re-bench (not a stall): stalled=0, walled_expired=0,
# probed_total advanced, last-green written.
grep -q "^fleet_seat_comeback_release_stalled 0$" "$PROM" \
  || fail "re-bench: prom stalled must be 0 (re-benched, not stalled): $(cat "$PROM")"
grep -qE "^fleet_seat_comeback_release_walled_expired 0$" "$PROM" \
  || fail "re-bench: prom walled_expired must be 0 (walls advanced): $(cat "$PROM")"
grep -qE "^fleet_seat_comeback_release_last_green_seconds [0-9]+$" "$PROM" \
  || fail "re-bench: prom last-green must be written (the release path is operating): $(cat "$PROM")"
grep -q "^fleet_seat_comeback_release_probed_total 3$" "$PROM" \
  || fail "re-bench: prom probed_total must be 3: $(cat "$PROM")"
ok "re-bench: probe failure advances the wall to now+REBENCH_BACKOFF_S; no loud stall, next tick skips"

# --- 3b. re-bench: subsequent tick with future wall skips the seat -------
# After re-bench, the wall is in the future. The next 15-min tick should
# skip the seat via the wall-in-future check (the only remaining
# throttle). A second probe attempt must NOT happen (no point — the
# wall is fresh, the next probe is owed only after the new window).
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"transient_fault","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T12:05:00Z","source":"comeback_release_rebench","failure_mode":"comeback_rebench","usable_at":"2026-08-30T13:00:00Z","bench_until":"2026-08-30T13:00:00Z","bench_window_s":900,"consecutive_failure_count":6}
EOF
STATE="$TMPD/state-rebench-skip.json"
PROM="$TMPD/release-rebench-skip.prom"
out=$(PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" --dry-run 2>&1)
grep -qi "poolside" <<<"$out" \
  && fail "re-bench follow-up: future-wall seat must NOT be re-probed: $out"
released_total=$(jq -r '.released_total' "$STATE" 2>/dev/null || echo 0)
[[ "$released_total" == "0" ]] || fail "re-bench follow-up: released_total must be 0, got $released_total"
ok "re-bench follow-up: future-wall seat is skipped by the wall-in-future check (no probe, no release)"

# --- 3c. loud stall: re-bench itself FAILS (ledger unwritable) -----------
# The loud-stall check still fires when re-bench cannot advance the
# wall (e.g. the ledger directory is read-only). The release path is
# then genuinely stuck: probes fail AND re-bench fails, so the wall
# stays in the past. Simulate by making the ledger dir read-only so
# the re-bench write errors out (mv fails). Note: bash atomic write
# creates a tmp file in the same dir, so a read-only dir blocks BOTH
# the re-bench and any future write.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
STATE="$TMPD/state-stall.json"
PROM="$TMPD/release-stall.prom"
chmod 0555 "$SEATDIR"  # read+exec only; writes blocked
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/live-stall.err"
stall_rc=$?
set -e
chmod 0755 "$SEATDIR"  # restore for cleanup
[[ "$stall_rc" == "1" ]] || fail "re-bench-fails: expected exit 1 (loud), got $stall_rc ($(cat "$TMPD/live-stall.err"))"
grep -q "LOUD \[COMEBACK-RELEASE-STALLED\]" "$TMPD/live-stall.err" \
  || fail "re-bench-fails: must render the LOUD line: $(cat "$TMPD/live-stall.err")"
grep -q "^fleet_seat_comeback_release_stalled 1$" "$PROM" \
  || fail "re-bench-fails: prom stalled must be 1: $(cat "$PROM")"
# fleet-ops#2806: the same read-only shape leaves usable_at in the past by
# ~2h (> one probe interval) after the sweep — the interval-breach loud
# channel must fire its own LOUD line and gauge (the releaser had a full
# probe cycle and could not move the wall).
grep -q "LOUD \[COMEBACK-RELEASE-INTERVAL-BREACH\]" "$TMPD/live-stall.err" \
  || fail "re-bench-fails: must render the INTERVAL-BREACH LOUD line: $(cat "$TMPD/live-stall.err")"
grep -q "^fleet_seat_comeback_release_interval_breached_total 1$" "$PROM" \
  || fail "re-bench-fails: prom interval_breached_total must be 1: $(cat "$PROM")"
grep -q "fleet_seat_comeback_release_interval_breached{seat=\"commandcode__poolside_laguna-s-2.1-free.json\"} 1" "$PROM" \
  || fail "re-bench-fails: prom interval_breached per-seat series must name the seat: $(cat "$PROM")"
# The overdue metric must STAY 1 here — this is the one honest stuck case
# (wall cannot be advanced), and it is what keeps the alert loud instead
# of the sweep clearing the overdue count while the seat is unreachable.
stuck_overdue=$(overdue_n)
[[ "$stuck_overdue" == "1" ]] \
  || fail "re-bench-fails: overdue count must stay 1 (wall cannot be advanced), got $stuck_overdue"
ok "loud stall still fires when re-bench cannot advance the wall (read-only ledger); overdue stays 1"

# --- 4. override: wall-expired + recent probe -> probe anyway (unstick) --
# The fleet-ops#2421 follow-up (2026-08-31 straitly/gpt-5.6-sol): a probe
# failure (rc=124 timeout) leaves the wall clock stale (extension cannot
# re-anchor without a real HTTP response). The previous min-interval
# skip then blocked re-probing forever, firing LOUD every 15 min. With
# the wall clock already EXPIRED the seat is owed a comeback; the
# min-interval only throttles hammering of future-wall seats. A
# recently-probed seat whose wall is still expired MUST be re-probed so
# the wall can refresh (real response -> extension re-anchors) or the
# seat can be unwalled (probe succeeds).
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
STATE="$TMPD/state-override.json"
PROM="$TMPD/release-override.prom"
# 60s ago: within MIN_INTERVAL (900s). Wall is EXPIRED. Old code skipped;
# fixed code overrides and probes anyway.
jq -nc --argjson lp "{\"commandcode__poolside_laguna-s-2.1-free.json\": $((NOW_EPOCH - 60))}" \
  '{last_probe: $lp, probed_total: 0, released_total: 0}' > "$STATE"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/override.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "override: expected exit 0 (release on success), got $rc ($(cat "$TMPD/override.err"))"
grep -q "override min-interval for commandcode/poolside/laguna-s-2.1-free" "$TMPD/override.err" \
  || fail "override: must log the min-interval override line: $(cat "$TMPD/override.err")"
health=$(jq -r '.health_class' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$health" == "healthy" ]] || fail "override: seat must be unwalled (healthy), got $health"
released_total=$(jq -r '.released_total' "$STATE")
[[ "$released_total" == "1" ]] || fail "override: released_total must be 1, got $released_total"
grep -q "^fleet_seat_comeback_release_stalled 0$" "$PROM" \
  || fail "override: prom stalled must be 0: $(cat "$PROM")"
ok "override: wall-expired + recent probe -> probe anyway (unstick), release succeeds, exit 0"

# --- 5. money future-wall seat: skipped (fleet-ops#4659 / #3284). A 402
#       / quota_exhausted wall stays held until expiry. Non-money long
#       walls are the #4640 PONG path (test 23).
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/opencode__nemotron-3-ultra-free.json" << 'EOF'
{"provider":"opencode","model":"nemotron-3-ultra-free","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T08:00:00Z","source":"money_boundary","failure_mode":"quota_exhausted","usable_at":"2026-08-30T23:00:00.094Z","consecutive_failure_count":3}
EOF
STATE="$TMPD/state-future.json"
PROM="$TMPD/release-future.prom"
jq -nc '{last_probe: {}, probed_total: 0, released_total: 0}' > "$STATE"
out=$(PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" --dry-run 2>&1)
grep -qi "nemotron" <<<"$out" \
  && fail "money future-wall seat must never be probed: $out"
released_total=$(jq -r '.released_total' "$STATE")
[[ "$released_total" == "0" ]] || fail "money future-wall seat must not increment released_total: $released_total"
ok "money future-wall seat: skipped, no probe, no release (fleet-ops#4640 money hold)"

# --- 6. overdue metric clears (fleet-ops#2520) -----------------------------
# The FleetSeatComebackOverdue alert keys on fleet_seat_comeback_overdue_total
# (exported from _read_comeback_overdue). A sweep that re-probes + unwalls
# (success) or advances the wall (re-bench on a probe failure with no real
# response, fleet-ops#2493) must leave the ledger with that count at 0 —
# otherwise a fixed sweep still leaves the alert stuck, which is exactly
# the sustained-overdue failure this issue names. Both paths are pinned
# end-to-end against the real exporter function on the SAME scratch ledger
# the sweep just operated on.

# 6a. probe SUCCEEDS: past-wall seat is overdue before, unwalled after.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00.000Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":23}
EOF
STATE="$TMPD/state-overdue-ok.json"
PROM="$TMPD/release-overdue-ok.prom"
before=$(overdue_n)
[[ "$before" == "1" ]] || fail "overdue-clears: past-wall seat must count overdue BEFORE the sweep (got $before)"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/overdue-ok.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "overdue-clears: sweep must exit 0 on success path, got $rc ($(cat "$TMPD/overdue-ok.err"))"
health=$(jq -r '.health_class' "$SEATDIR/straitly__gpt-5.6-sol.json")
[[ "$health" == "healthy" ]] || fail "overdue-clears: seat must be unwalled (healthy), got $health"
after=$(overdue_n)
[[ "$after" == "0" ]] || fail "overdue-clears: _read_comeback_overdue must be 0 AFTER the sweep (unwall), got $after"
ok "overdue metric clears: past-wall seat probed + unwalled -> comeback-overdue count 0"

# 6b. probe FAILS with no real response (rc=124 timeout, the #2493 shape):
#     the wall cannot be re-anchored by the extension, so the sweep must
#     re-bench it into the future. The pre-#2505 bin left the wall in the
#     past after such a failure (next tick re-probes, re-fails, alert
#     sustains) — this assertion is the regression pin for that class.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00.000Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":23}
EOF
STATE="$TMPD/state-overdue-rebench.json"
PROM="$TMPD/release-overdue-rebench.prom"
before=$(overdue_n)
[[ "$before" == "1" ]] || fail "overdue-rebench: past-wall seat must count overdue BEFORE the sweep (got $before)"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    FLEET_SEAT_COMEBACK_TIMEOUT_S=2 \
    PI_BIN="$TMPD/pi-timeout" \
    bash "$BIN" >/dev/null 2>"$TMPD/overdue-rebench.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "overdue-rebench: sweep must exit 0 (re-benched, not loud), got $rc ($(cat "$TMPD/overdue-rebench.err"))"
grep -q "REBENCHED straitly/gpt-5.6-sol" "$TMPD/overdue-rebench.err" \
  || fail "overdue-rebench: must log REBENCHED: $(cat "$TMPD/overdue-rebench.err")"
after=$(overdue_n)
[[ "$after" == "0" ]] || fail "overdue-rebench: _read_comeback_overdue must be 0 AFTER the sweep (wall advanced), got $after"
ok "overdue metric clears: probe failure re-benches the wall into the future -> comeback-overdue count 0 (fleet-ops#2520 regression pin)"

# --- 7. PONG-ok inline answer -> NOT released (fleet-ops#2661) ----------
# A partial 503 storm is PONG-compatible: a 1-token inline "OK" probe
# passes but tool-loading 503s. The tool-using probe must keep such a seat
# benched: an inline-only "OK" answer (no tool result, no computed token) does
# NOT release. This is the regression fixture the issue names: PONG-ok but
# tool-503 -> does NOT release. The probe fails -> re-bench (overload class
# preserved) + a 1st overload strike registered on that provider.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
STATE="$TMPD/state-pong.json"
PROM="$TMPD/release-pong.prom"
LEARNED="$TMPD/learned-caps-pong.json"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-pong-ok" \
    LEARNED_CAPS_JSON="$LEARNED" \
    bash "$BIN" >/dev/null 2>"$TMPD/pong.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "pong-ok: expected exit 0 (re-benched, not loud), got $rc ($(cat "$TMPD/pong.err"))"
health=$(jq -r '.health_class' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$health" == "overload_bench" ]] || fail "pong-ok: seat must STAY benched (overload_bench), got $health"
grep -q "REBENCHED commandcode/poolside/laguna-s-2.1-free" "$TMPD/pong.err" \
  || fail "pong-ok: must log REBENCHED (re-bench on inline-only probe failure): $(cat "$TMPD/pong.err")"
released_total=$(jq -r '.released_total' "$STATE")
[[ "$released_total" == "0" ]] || fail "pong-ok: inline-only probe must NOT release (released_total must be 0, got $released_total)"
# The first overload strike is registered on that provider (the re-bench preserved the
# overload class;the strike counter is the escalation-to-provider-wall premiso).
strikes=$(jq -r '.overload_strikes.commandcode.count // 0' "$STATE")
[[ "$strikes" == "1" ]] || fail "pong-ok: inline-only probe failure must register 1 overload strike (got $strikes)"
grep -q "OVERLOAD WALL" "$TMPD/pong.err" && fail "pong-ok: 1 strike must NOT arm the wall yet: $(cat "$TMPD/pong.err")"
ok "PONG-ok inline answer -> seat stays benched (1 overload strike, no release)"

# --- 8. >=4 overload strikes within  2h -> exponential provider-wide wall (fleet-ops#2661) --
# A partial storm re-benches seats every bench window; 4 consecutive overload_503
# strikes within the  2h window arm an exponential provider-wide wall via the learned-caps
# mechanism (learned-caps.json providers.<p>.bench_until, the SAME primitive the
# rate_limit/quota classes use) — so the release path cannot keep unwalling walls
# straight back into the storm. A quota_exhausted seat's failures are NOT overload
# strikes (they must not arm the wall).
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
cat > "$SEATDIR/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00.000Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":23}
EOF
STATE="$TMPD/state-wall.json"
PROM="$TMPD/release-wall.prom"
LEARNED="$TMPD/learned-caps-wall.json"
printf '%s\n' '{"providers":{}}' > "$LEARNED"
# 4 sweeps, each 70s apart, a short rebench window (60s, so the wall
# expires between sweeps and every probe re-fails. At the 4th sweep the strike
# count hits 4 within the  2h window -> the exponential provider-wide wall arms.
 
for run in  1 2 3 4; do
  RUN_NOW=$(date -u -d "2026-08-30T12:00:00Z + $((run * 70)) seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$NOW_ISO")
  set +e
  PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
      FLEET_SEAT_COMEBACK_STATE="$STATE" \
      FLEET_SEAT_COMEBACK_PROM="$PROM" \
      FLEET_SEAT_COMEBACK_NOW="$RUN_NOW" \
      FLEET_SEAT_COMEBACK_REBENCH_BACKOFF_S=60 \
      PI_BIN="$TMPD/pi-fail" \
      LEARNED_CAPS_JSON="$LEARNED" \
      bash "$BIN" >/dev/null 2>"$TMPD/wall.err.$run"
  rc=$?
  set -e
  [[ "$rc" == "0" ]] || fail "overload-wall run $run: expected exit 0 (re-benched, not loud), got $rc"
done
# 4 strikes on commandcode within the window (first_at=+70s, last=+280s:
#210s apart <7200s) ->the wall armed. straitly's quota failures are not overload
# strikes -> no wall for it.
strikes=$(jq -r '.overload_strikes.commandcode.count //  0' "$STATE")
[[ "$strikes" == "4" ]] || fail "overload-wall: commandcode must rack 4 overload strikes, got $strikes"
walls_total=$(jq -r '.walls_total // 0' "$STATE")
[[ "$walls_total" == "1" ]] || fail "overload-wall: walls_total must be 1, got $walls_total"
jq -e '.providers.commandcode.bench_until != null and .providers.commandcode.learned_cap == 1' "$LEARNED" >/dev/null \
  || fail "overload-wall: provider-wide wall must land in learned-caps.json for commandcode: $(cat "$LEARNED")"
jq -e '.providers.straitly == null' "$LEARNED" >/dev/null \
  || fail "overload-wall: quota failures must NOT arm a provider wall (straitly should not appear): $(cat "$LEARNED")"
grep -q "OVERLOAD WALL commandcode" "$TMPD/wall.err.4" \
  || fail "overload-wall:the 4th sweep must log OVERLOAD WALL: $(cat "$TMPD/wall.err.4")"
ok "4 overload strikes within  2h -> exponential provider-wide wall via learned-caps.bench_until"

# --- 9. fleet-ops#2638: force probe on overdue usable_at (unstick) -------
# The lived 2026-09-01T09:45Z heartbeat case: a seat had usable_at past but
# bench_until was held by a recent re-bench (the prober's own re-bench
# write). The prober was skipping it because wall_end_of prefers bench_until;
# the re-bench loop held the seat indefinitely. The fix: track usable_at
# SEPARATELY from bench_until; an overdue usable_at forces a real probe
# even when bench_until is held. Same cadence as a normal re-bench cycle
# (a probe every bench window) — but the probe ACTUALLY FIRES instead of
# being silently skipped. A successful probe unwalls; a failed probe
# re-benches again.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"comeback_release_rebench","failure_mode":"overload_503","bench_until":"2026-08-30T13:00:00Z","usable_at":"2026-08-30T10:00:00Z","bench_window_s":900,"consecutive_failure_count":15}
EOF
STATE="$TMPD/state-force-util.json"
PROM="$TMPD/release-force-util.prom"
out=$(PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" --dry-run 2>&1)
grep -q "force probe commandcode/poolside/laguna-s-2.1-free" <<<"$out" \
  || fail "force-util: must log the force-probe line: $out"
grep -q "usable_at 2026-08-30T10:00:00Z past, bench_until 2026-08-30T13:00:00Z held by re-bench" <<<"$out" \
  || fail "force-util: must name both clocks and the held bench_until: $out"
grep -q "would probe commandcode/poolside/laguna-s-2.1-free" <<<"$out" \
  || fail "force-util: must actually probe (dry-run): $out"
ok "force probe: usable_at past + bench_until held -> prober fires anyway (fleet-ops#2638)"

# --- 9b. force probe succeeds: overdue usable_at seat unwalled ----------
# Live run with the same fixture: the prober should fire and unwall.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"comeback_release_rebench","failure_mode":"overload_503","bench_until":"2026-08-30T13:00:00Z","usable_at":"2026-08-30T10:00:00Z","bench_window_s":900,"consecutive_failure_count":15}
EOF
STATE="$TMPD/state-force-ok.json"
PROM="$TMPD/release-force-ok.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/force-ok.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "force-util-ok: expected exit 0 (released), got $rc ($(cat "$TMPD/force-ok.err"))"
grep -q "force probe commandcode/poolside/laguna-s-2.1-free" "$TMPD/force-ok.err" \
  || fail "force-util-ok: must log the force-probe line: $(cat "$TMPD/force-ok.err")"
health=$(jq -r '.health_class' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$health" == "healthy" ]] || fail "force-util-ok: seat must be unwalled (healthy), got $health"
released_total=$(jq -r '.released_total' "$STATE")
[[ "$released_total" == "1" ]] || fail "force-util-ok: released_total must be 1, got $released_total"
ok "force probe succeeds: overdue usable_at seat unwalled, released_total=1 (fleet-ops#2638)"

# --- 10. fleet-ops#2638: corpse at SEAT_DEAD_CONSECUTIVE_THRESHOLD -------
# The lived mimo-42x-429s and poolside-23x-503s case: probes fail,
# consecutive_failure_count climbs past the threshold, but the prober
# never wrote seat_dead=true — the seat kept re-benching forever. The
# fix: after re-bench, if the count has crossed the threshold, write
# seat_dead=true with cleared wall clocks (fleet-ops#2415 convention).
# seat_usable already holds seat_dead=true terminally (fleet-ops#2327),
# so the next sweep skips the seat entirely. Test pins the boundary: a
# seat at count=24 + a failed probe -> count becomes 25 -> corpse.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":24}
EOF
STATE="$TMPD/state-corpse.json"
PROM="$TMPD/release-corpse.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/corpse.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "corpse: expected exit 0 (corpsed, not loud), got $rc ($(cat "$TMPD/corpse.err"))"
grep -q "REBENCHED commandcode/poolside/laguna-s-2.1-free" "$TMPD/corpse.err" \
  || fail "corpse: must log REBENCHED first (the failed probe re-benches): $(cat "$TMPD/corpse.err")"
grep -q "CORPSED commandcode/poolside/laguna-s-2.1-free" "$TMPD/corpse.err" \
  || fail "corpse: must log CORPSED after the re-bench crosses threshold: $(cat "$TMPD/corpse.err")"
# Ledger: seat_dead=true, health_class=corpse, wall clocks cleared,
# source=comeback_release_corpse, count=25 (one above the start of 24).
jq -e '.seat_dead == true and .health_class == "corpse" and .bench_until == null and .usable_at == null and .source == "comeback_release_corpse" and .failure_mode == "comeback_never_released" and .consecutive_failure_count == 25' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "corpse: ledger must be seat_dead=true, wall cleared, count=25: $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
# fleet-ops#3156: a PROBER-created no-wall corpse (failure_mode
# comeback_never_released, wall null) is NOT terminal-skipped. It gets ONE
# second-chance re-probe: with the healthy probe stub the corpse RE-PROBES
# and, on success, UNWALLS (transitions OUT of corpse). It must not be
# re-corpsed (already a corpse) and must not stay stuck.
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/corpse-followup.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "corpse follow-up: expected exit 0, got $rc"
grep -q "corpse re-probe commandcode/poolside/laguna-s-2.1-free: no wall, second-chance re-probe" "$TMPD/corpse-followup.err" \
  || fail "corpse follow-up: no-wall corpse must be re-probed (fleet-ops#3156): $(cat "$TMPD/corpse-followup.err")"
grep -q "UNWALLED commandcode/poolside/laguna-s-2.1-free" "$TMPD/corpse-followup.err" \
  || fail "corpse follow-up: healthy re-probe must unwall the corpse: $(cat "$TMPD/corpse-followup.err")"
# The seat transitioned OUT of corpse: healthy, seat_dead false, streak 0.
jq -e '.seat_dead == false and .health_class == "healthy" and .failure_mode == "none" and .consecutive_failure_count == 0' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "corpse follow-up: seat must transition OUT of corpse (healthy, seat_dead=false): $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
# corpse_total stays 1 (the first pass wrote the corpse; the #3156
# transition-out is not a second corpse write).
corpse_total=$(jq -r '.corpse_total // 0' "$STATE")
[[ "$corpse_total" == "1" ]] || fail "corpse: corpse_total must stay 1, got $corpse_total"
grep -q "^fleet_seat_comeback_release_corpse_total 1$" "$PROM" \
  || fail "corpse: prom corpse_total must be 1: $(cat "$PROM")"
ok "corpse at threshold: c=24 + failed probe -> c=25 corpse write; second-chance re-probe unwalls it OUT of corpse (fleet-ops#2638/#3156)"

# --- 11. fleet-ops#2638: corpse does NOT fire below threshold ------------
# Pin the boundary: a seat at count=23 + failed probe -> count becomes 24
# (< 25) -> re-bench only, NO corpse. Mirrors fleet-ops#2594's corpse-
# boundary contract: only at or above threshold does seat_dead=true land.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":23}
EOF
STATE="$TMPD/state-no-corpse.json"
PROM="$TMPD/release-no-corpse.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/no-corpse.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "no-corpse: expected exit 0 (re-benched, not loud), got $rc ($(cat "$TMPD/no-corpse.err"))"
grep -q "REBENCHED" "$TMPD/no-corpse.err" \
  || fail "no-corpse: must log REBENCHED: $(cat "$TMPD/no-corpse.err")"
grep -q "CORPSED" "$TMPD/no-corpse.err" \
  && fail "no-corpse: must NOT log CORPSED (below threshold): $(cat "$TMPD/no-corpse.err")"
health=$(jq -r '.health_class' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$health" == "overload_bench" ]] || fail "no-corpse: seat must STAY overload_bench (not corpse), got $health"
dead=$(jq -r '.seat_dead' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$dead" == "false" ]] || fail "no-corpse: seat_dead must stay false (below threshold), got $dead"
count=$(jq -r '.consecutive_failure_count' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
[[ "$count" == "24" ]] || fail "no-corpse: count must be 24 (one above 23), got $count"
ok "no corpse below threshold: c=23 + failed probe -> c=24 re-bench only, NO corpse (fleet-ops#2638)"

# --- 12. fleet-ops#2638: never-released metric over a scratch ledger ----
# The metric-exporter's _read_never_released identifies seats the prober
# has been failing on (consecutive_failure_count in [10, 25)) that are
# NOT corpses yet. Pin the shape against the real exporter function on
# the SAME scratch ledger the bin operates on — same pattern as test 6
# (fleet-ops#2520) which pins the comeback-overdue count clear path.
# A scratch ledger with three seats verifies the boundaries:
#   - count=5  (below 10): NOT never-released (fresh single failure).
#   - count=15 (in [10,25)): IS never-released (the lived poolside case).
#   - count=24 (in [10,25)): IS never-released (the lived mimo case).
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","consecutive_failure_count":15}
EOF
cat > "$SEATDIR/opencode__mimo-v2.5-free.json" << 'EOF'
{"provider":"opencode","model":"mimo-v-2.5-free","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:00:00Z","source":"provider_fetch","failure_mode":"rate_limit","usable_at":"2026-08-30T09:30:21.000Z","consecutive_failure_count":24}
EOF
cat > "$SEATDIR/cline__z-ai_glm-5.3-flash.json" << 'EOF'
{"provider":"cline","model":"z-ai/glm-5.3-flash","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"none","consecutive_failure_count":0}
EOF
# never_released_n() over $SEATDIR (mirrors tests 6's overdue_n()).
# Also wires the scratch seat-caps so _read_never_released's phantom-key guard
# sees the test's caps on every host (fleet-ops#3993, same determinism fix as
# overdue_n).
never_released_n() {
    python3 - "$repo_root/libexec/fleet-metrics-export.py" "$SEATDIR" "$TMPD/seat-caps.json" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.SEAT_LEDGER = Path(sys.argv[2])
m.SEAT_CAPS_DEFAULT = Path(sys.argv[3])
m.SEAT_CAPS_FALLBACK = Path("/nonexistent/seat-caps.json")
nr_n, _ = m._read_never_released()
print(nr_n)
PY
}
nr=$(never_released_n)
[[ "$nr" == "2" ]] \
  || fail "never-released: must count 2 stuck seats (poolside c=15, mimo c=24; healthy glm excluded), got $nr"
ok "never-released metric: 2 stuck seats counted (poolside+mimo), healthy seat excluded (fleet-ops#2638)"

# --- 13. corpse-ledger retirement (fleet-ops#2716) ------------------------
# The terminal step of the seat lifecycle this organ owns: a corpse
# (seat_dead=true, health_class=corpse) ledger must not sit in the live
# roster forever — seat-caps.json retiring the slug (cap 0 +
# intentional_cap_zero=corpse, fleet-ops#2708) stops the rotation but the
# ledger file keeps counting as roster membership in the census
# (daily-digest 'Total seen', fleet metrics exporter seat_table n). The
# corpse is physically moved into lanes/seats-corpse-retired-<UTC-ts>/
# once its observed_at ages past CORPSE_GRACE_S (default 6h). A fresh
# corpse (inside grace) and a corpse that still carries a future wall
# clock are held.
#
# Fixed NOW for this section (independent of the sweep sections above) so
# the dated retirement dir is a clean scratch name.
NOW2_ISO="2026-08-30T13:00:00Z"
RETSEAT="$TMPD/seats13"
RETDIR="$TMPD/seats-corpse-retired-$NOW2_ISO"

# 13a. grace hold: a fresh corpse (1h old, inside the 6h grace window)
#      must NOT be retired — the recovery window is still open. Uses a
#      credentials_bad corpse (fleet-ops#3229: a PERMANENT class is NOT in
#      the recoverable-mode re-probe carve-out, so it is held silently and
#      the #2716 grace/retirement path is what this exercises — a transient
#      corpse would now be re-probed out of corpse before retirement).
rm -rf "$RETSEAT"; mkdir -p "$RETSEAT"; rm -rf "$RETDIR"
cat > "$RETSEAT/devin__glm-5-2.json" << 'EOF'
{"provider":"devin","model":"glm-5-2","http_status":403,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T12:00:00Z","source":"after_provider_response","failure_mode":"credentials_bad","usable_at":null,"consecutive_failure_count":30}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13a.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13a.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13a.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13a: grace-hold sweep must exit 0, got $rc ($(cat "$TMPD/ret13a.err"))"
[[ -f "$RETSEAT/devin__glm-5-2.json" ]] \
  || fail "13a: fresh corpse (age 1h < grace 6h) must NOT be retired: $(cat "$TMPD/ret13a.err")"
[[ ! -d "$RETDIR" ]] || fail "13a: no retirement dir may be created while the corpse is inside grace: $(ls -la "$TMPD" 2>&1)"
grep -q "RETIRED" "$TMPD/ret13a.err" \
  && fail "13a: fresh corpse must not be retired: $(cat "$TMPD/ret13a.err")"
ok "13a: fresh corpse inside the 6h grace window is held (recovery window still open)"

# 13b. grace override + retirement: the same 1h-old corpse with
#      FLEET_SEAT_COMEBACK_CORPSE_GRACE_S=3600 is past grace -> retired.
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13b.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13b.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    FLEET_SEAT_COMEBACK_CORPSE_GRACE_S=3600 \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13b.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13b: retirement sweep must exit 0, got $rc ($(cat "$TMPD/ret13b.err"))"
# fleet-ops#3669: retirement must leave the seat UNPICKABLE. The corpse ledger
# is moved into the dated audit dir AND a seat_dead=true / health_class=parked
# parked ledger is written back into the live roster (the shared writer in
# lib/seat-lib.sh), so pick_seat refuses the seat instead of re-picking it
# via the "NO HEALTH DATA (no ledger file) — assuming usable" fail-open.
[[ -f "$RETSEAT/devin__glm-5-2.json" ]] \
  || fail "13b: a parked ledger must be left in the live roster after retirement (fleet-ops#3669): $(ls "$RETSEAT")"
_parked_hc=$(jq -r '.health_class // ""' "$RETSEAT/devin__glm-5-2.json" 2>/dev/null || true)
[[ "$_parked_hc" == "parked" ]] \
  || fail "13b: parked ledger must be health_class=parked, got $_parked_hc"
_parked_dead=$(jq -r '.seat_dead // false' "$RETSEAT/devin__glm-5-2.json" 2>/dev/null || true)
[[ "$_parked_dead" == "true" ]] \
  || fail "13b: parked ledger must be seat_dead=true, got $_parked_dead"
# fleet-ops#3603: a corpse-retired ledger must carry a bench_reason so the
# fail-open corpse detector (which flags bench_reason=null as the fail-open
# corpse shape) never re-files a durably-benched corpse. The cap=0 corpse row
# (config/seat-caps.json) is the real bench; bench_reason makes it visible.
_parked_br=$(jq -r '.bench_reason // ""' "$RETSEAT/devin__glm-5-2.json" 2>/dev/null || true)
[[ -n "$_parked_br" ]] \
  || fail "13b: parked ledger must carry a bench_reason (fail-open corpse shape, fleet-ops#3603): $_parked_br"
_parked_lec=$(jq -r '.last_error_class // ""' "$RETSEAT/devin__glm-5-2.json" 2>/dev/null || true)
[[ "$_parked_lec" == "corpse_retired" ]] \
  || fail "13b: parked ledger must carry last_error_class=corpse_retired, got '$_parked_lec'"
[[ -f "$RETDIR/devin__glm-5-2.json" ]] \
  || fail "13b: corpse ledger must land in seats-corpse-retired-<ts>/: $(ls -la "$TMPD" 2>&1)"
grep -q "^fleet_seat_comeback_release_retired_total 1$" "$TMPD/prom13b.prom" \
  || fail "13b: prom retired_total must be 1: $(cat "$TMPD/prom13b.prom")"
# Idempotence: a second sweep with the parked ledger in the live roster must
# not re-retire (the parked ledger is health_class=parked, not corpse, so
# retire_corpse holds it) and must keep retired_total=1.
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13b.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13b.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    FLEET_SEAT_COMEBACK_CORPSE_GRACE_S=3600 \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13b2.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13b idem: re-run on an empty ledger must exit 0, got $rc ($(cat "$TMPD/ret13b2.err"))"
grep -q "^fleet_seat_comeback_release_retired_total 1$" "$TMPD/prom13b.prom" \
  || fail "13b idem: retired_total must stay 1 across re-runs: $(cat "$TMPD/prom13b.prom")"
retired_total=$(jq -r '.retired_total' "$TMPD/state13b.json")
[[ "$retired_total" == "1" ]] || fail "13b idem: state retired_total must stay 1, got $retired_total"
ok "13b: corpse past grace (env override 3600s) retired out of the roster; re-run idempotent"

# 13c. defensive hold: an OLD corpse that still carries a FUTURE wall clock
#      is held (a clock means a comeback is still owed — fleet-ops#2394 shape).
rm -rf "$RETSEAT"; mkdir -p "$RETSEAT"; rm -rf "$RETDIR"
cat > "$RETSEAT/opencode__mimo-v2.5-free.json" << 'EOF'
{"provider":"opencode","model":"mimo-v2.5-free","http_status":429,"retry_after":null,"health_class":"corpse","retryable":true,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-29T01:00:00Z","source":"after_provider_response","failure_mode":"rate_limit","usable_at":null,"bench_until":"2026-08-30T14:00:00Z","consecutive_failure_count":150}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13c.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13c.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    FLEET_SEAT_COMEBACK_CORPSE_GRACE_S=3600 \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13c.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13c: future-clock-corpse sweep must exit 0, got $rc ($(cat "$TMPD/ret13c.err"))"
[[ -f "$RETSEAT/opencode__mimo-v2.5-free.json" ]] \
  || fail "13c: corpse with a future wall clock must NOT be retired: $(cat "$TMPD/ret13c.err")"
[[ ! -d "$RETDIR" ]] || fail "13c: no retirement dir may be created for a held corpse: $(ls -la "$TMPD" 2>&1)"
grep -q "RETIRED" "$TMPD/ret13c.err" \
  && fail "13c: future-clock corpse must not be retired: $(cat "$TMPD/ret13c.err")"
ok "13c: old corpse still carrying a future wall clock is held (comeback still owed)"

# 13d. clean sweep: a roster with no corpses retires nothing (retired_total
#      stays 0), creates no retirement dir, exit 0.
rm -rf "$RETSEAT"; mkdir -p "$RETSEAT"; rm -rf "$RETDIR"
cat > "$RETSEAT/bai__deepseek-v4-flash.json" << 'EOF'
{"provider":"bai","model":"deepseek-v4-flash","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T12:30:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF
cat > "$RETSEAT/opencode__nemotron-3-ultra-free.json" << 'EOF'
{"provider":"opencode","model":"nemotron-3-ultra-free","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T08:00:00Z","source":"provider_fetch","failure_mode":"rate_limit","usable_at":"2026-08-30T23:00:00Z","consecutive_failure_count":3}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13d.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13d.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13d.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13d: clean sweep must exit 0, got $rc ($(cat "$TMPD/ret13d.err"))"
[[ ! -d "$RETDIR" ]] || fail "13d: clean roster must create no retirement dir: $(ls -la "$TMPD" 2>&1)"
grep -q "^fleet_seat_comeback_release_retired_total 0$" "$TMPD/prom13d.prom" \
  || fail "13d: prom retired_total must be 0 on a clean roster: $(cat "$TMPD/prom13d.prom")"
ok "13d: clean roster (healthy + rate_limited) retires nothing, creates no dir (fleet-ops#2716)"

# 13e. fleet-ops#3947: bench_reason backfill on a HELD corpse. Two shapes
#      land in the live roster with bench_reason=null and read as the
#      fail-open corpse shape to the seat-health census, which re-files the
#      same "no bench overlay" ticket every tick:
#        (a) a FRESH credentials_bad 401/403 corpse the seat-health
#            extension just escalated (seat_dead=true, usable_at=null, no
#            bench_reason — write_parked_ledger has not run yet, age inside
#            the 6h grace so retire_corpse holds it).
#        (b) an OLD pre-#3603 parked corpse (bench_until=far_future, no
#            bench_reason) that retire_corpse's future-wall hold never
#            re-parks.
#      The sweep must backfill the durable bench literal on BOTH via a
#      field-merge that PRESERVES health_class / failure_mode / seat_dead
#      (so FleetDeadCredentialSeats still fires on the credentials_bad
#      signal) — the corpse is recognisable as benched the moment the sweep
#      sees it, not 6h later (and never for the future-wall shape).
rm -rf "$RETSEAT"; mkdir -p "$RETSEAT"; rm -rf "$RETDIR"
# (a) fresh credentials_bad corpse, 1h old (inside 6h grace), no wall, no bench_reason
cat > "$RETSEAT/commandcode__minimax_minimax-m3-free.json" << 'EOF'
{"provider":"commandcode","model":"minimax/minimax-m3-free","http_status":403,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T12:00:00Z","source":"after_provider_response","failure_mode":"credentials_bad","usable_at":null,"consecutive_failure_count":30}
EOF
# (b) old pre-#3603 parked corpse, far-future bench_until, no bench_reason
cat > "$RETSEAT/hetzner__Qwen_Qwen3.6-35B-A3B-FP8.json" << 'EOF'
{"provider":"hetzner","model":"Qwen/Qwen3.6-35B-A3B-FP8","http_status":null,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T12:00:00Z","source":"corpse_retirement","failure_mode":"corpse_retired","bench_until":"2036-08-30T12:00:00Z","usable_at":"2036-08-30T12:00:00Z","consecutive_failure_count":0}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13e.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13e.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13e.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13e: bench_reason backfill sweep must exit 0, got $rc ($(cat "$TMPD/ret13e.err"))"
# Both corpses are HELD (fresh inside grace / future wall) — not retired.
[[ -f "$RETSEAT/commandcode__minimax_minimax-m3-free.json" ]] \
  || fail "13e: fresh credentials_bad corpse must NOT be retired (held in grace): $(cat "$TMPD/ret13e.err")"
[[ -f "$RETSEAT/hetzner__Qwen_Qwen3.6-35B-A3B-FP8.json" ]] \
  || fail "13e: old future-wall corpse must NOT be retired: $(cat "$TMPD/ret13e.err")"
[[ ! -d "$RETDIR" ]] || fail "13e: no retirement dir may be created for held corpses: $(ls -la "$TMPD" 2>&1)"
# (a) fresh credentials_bad corpse: bench_reason backfilled, signal preserved.
_br_a=$(jq -r '.bench_reason // ""' "$RETSEAT/commandcode__minimax_minimax-m3-free.json" 2>/dev/null || true)
[[ -n "$_br_a" ]] \
  || fail "13e: fresh credentials_bad corpse must get bench_reason backfilled (fleet-ops#3947): got '$_br_a'"
_hc_a=$(jq -r '.health_class // ""' "$RETSEAT/commandcode__minimax_minimax-m3-free.json" 2>/dev/null || true)
[[ "$_hc_a" == "corpse" ]] \
  || fail "13e: backfill must PRESERVE health_class=corpse, got '$_hc_a' (FleetDeadCredentialSeats signal)"
_fm_a=$(jq -r '.failure_mode // ""' "$RETSEAT/commandcode__minimax_minimax-m3-free.json" 2>/dev/null || true)
[[ "$_fm_a" == "credentials_bad" ]] \
  || fail "13e: backfill must PRESERVE failure_mode=credentials_bad, got '$_fm_a'"
_sd_a=$(jq -r '.seat_dead // false' "$RETSEAT/commandcode__minimax_minimax-m3-free.json" 2>/dev/null || true)
[[ "$_sd_a" == "true" ]] \
  || fail "13e: backfill must PRESERVE seat_dead=true, got '$_sd_a'"
_lec_a=$(jq -r '.last_error_class // ""' "$RETSEAT/commandcode__minimax_minimax-m3-free.json" 2>/dev/null || true)
[[ "$_lec_a" == "credentials_bad" ]] \
  || fail "13e: backfill must set last_error_class=credentials_bad (the failure_mode), got '$_lec_a'"
# (b) old future-wall corpse: bench_reason backfilled, signal preserved.
_br_b=$(jq -r '.bench_reason // ""' "$RETSEAT/hetzner__Qwen_Qwen3.6-35B-A3B-FP8.json" 2>/dev/null || true)
[[ -n "$_br_b" ]] \
  || fail "13e: old future-wall corpse must get bench_reason backfilled (fleet-ops#3947): got '$_br_b'"
_hc_b=$(jq -r '.health_class // ""' "$RETSEAT/hetzner__Qwen_Qwen3.6-35B-A3B-FP8.json" 2>/dev/null || true)
[[ "$_hc_b" == "corpse" ]] \
  || fail "13e: backfill must PRESERVE health_class=corpse on the old corpse, got '$_hc_b'"
_fm_b=$(jq -r '.failure_mode // ""' "$RETSEAT/hetzner__Qwen_Qwen3.6-35B-A3B-FP8.json" 2>/dev/null || true)
[[ "$_fm_b" == "corpse_retired" ]] \
  || fail "13e: backfill must PRESERVE failure_mode=corpse_retired, got '$_fm_b'"
# Idempotence: a second sweep must not re-write (bench_reason already set).
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$RETSEAT" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state13e.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom13e.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW2_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret13e2.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "13e: idempotent re-sweep must exit 0, got $rc ($(cat "$TMPD/ret13e2.err"))"
_br_a2=$(jq -r '.bench_reason // ""' "$RETSEAT/commandcode__minimax_minimax-m3-free.json" 2>/dev/null || true)
[[ "$_br_a" == "$_br_a2" ]] \
  || fail "13e: idempotent re-sweep must not change bench_reason: '$_br_a' -> '$_br_a2'"
ok "13e: held corpse (fresh credentials_bad + old future-wall) gets bench_reason backfilled, signal preserved (fleet-ops#3947)"

# --- 14. fleet-ops#2806: corpse on the merged own-failure streak -------
# The lived nemotron/mimo shape: the seat-health extension re-anchors the
# wall into the future on each release-probe failure (skip re-bench), and
# its own consecutive_failure_count only increments on real responses at
# its own cadence (15->17 across 8h of 15-min probes) — so the pre-#2806
# corpse path, gated on the LEDGER count after a probe, never fired in a
# useful window. The organ now keeps its own per-seat failure streak in
# the state file (own_failures), seeded from the ledger count at first
# sighting and advanced on EVERY probe failure, and corpses on the MERGED
# streak (max of ledger count and own streak). Here the ledger count is a
# low 5 (the extension never counted most failures) while the own streak
# sits at 24 — one more failed probe crosses the threshold -> corpse.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"2026-08-30T10:02:47Z","usable_at":"2026-08-30T10:02:47Z","bench_window_s":600,"consecutive_failure_count":5}
EOF
STATE="$TMPD/state-own-streak.json"
PROM="$TMPD/release-own-streak.prom"
# Own streak pre-seeded at 24 (extension count sat at 5 — the gap the
# merged-streak fix closes). One failed probe -> 25 -> corpse.
jq -nc '{"last_probe":{}, "probed_total": 0, "released_total": 0, "own_failures": {"commandcode__poolside_laguna-s-2.1-free.json": 24}}' > "$STATE"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/own-streak.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "own-streak corpse: expected exit 0 (corpsed, not loud), got $rc ($(cat "$TMPD/own-streak.err"))"
grep -q "REBENCHED commandcode/poolside/laguna-s-2.1-free" "$TMPD/own-streak.err" \
  || fail "own-streak corpse: must log REBENCHED (failed probe re-benches): $(cat "$TMPD/own-streak.err")"
grep -q "CORPSED commandcode/poolside/laguna-s-2.1-free" "$TMPD/own-streak.err" \
  || fail "own-streak corpse: must log CORPSED on the merged streak: $(cat "$TMPD/own-streak.err")"
# Corpse write carries the MERGED streak count (25 = own 24 + this failure):
# seat_dead=true, class corpse, wall clocks cleared, source comeback_release_corpse.
jq -e '.seat_dead == true and .health_class == "corpse" and .bench_until == null and .usable_at == null and .source == "comeback_release_corpse" and .consecutive_failure_count == 25' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "own-streak corpse: ledger must be seat_dead=true, wall cleared, count=25: $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
# fleet-ops#3156: the prober-created no-wall corpse gets ONE second-chance
# re-probe — with the healthy stub it transitions OUT of corpse (unwalled).
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/own-streak-followup.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "own-streak corpse follow-up: expected exit 0, got $rc"
grep -q "UNWALLED commandcode/poolside/laguna-s-2.1-free" "$TMPD/own-streak-followup.err" \
  || fail "own-streak corpse follow-up: no-wall corpse must be re-probed and unwalled (fleet-ops#3156): $(cat "$TMPD/own-streak-followup.err")"
jq -e '.seat_dead == false and .health_class == "healthy"' \
  "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" >/dev/null \
  || fail "own-streak corpse follow-up: seat must transition OUT of corpse: $(cat "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")"
corpse_total=$(jq -r '.corpse_total // 0' "$STATE")
[[ "$corpse_total" == "1" ]] || fail "own-streak corpse: corpse_total must be 1, got $corpse_total"
ok "corpse on merged own-failure streak: own=24 + failed probe -> 25 corpse; #3156 re-probe unwalls it out of corpse (fleet-ops#2806/#3156)"

# --- 15. fleet-ops#2806: no interval-breach false positive in-cadence ----
# A seat whose usable_at passed less than one probe interval ago (500s <
# 900s) is mid-cycle: the sweep probes it (the wall is past), the probe
# fails, and the re-bench advances the wall into the future. The breach
# gauge must stay 0 (the releaser IS operating — a past-by-<interval wall
# at sweep start is its normal job), exit 0, no LOUD line.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << EOF
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":503,"retry_after":null,"health_class":"overload_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T09:52:47Z","source":"overload_bench","failure_mode":"overload_503","bench_until":"$(date -u -d '2026-08-30T12:00:00Z - 500 seconds' +%Y-%m-%dT%H:%M:%SZ)","usable_at":"$(date -u -d '2026-08-30T12:00:00Z - 500 seconds' +%Y-%m-%dT%H:%M:%SZ)","bench_window_s":600,"consecutive_failure_count":5}
EOF
STATE="$TMPD/state-in-cadence.json"
PROM="$TMPD/release-in-cadence.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/in-cadence.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "in-cadence: expected exit 0 (re-benched, not loud), got $rc ($(cat "$TMPD/in-cadence.err"))"
grep -q "REBENCHED commandcode/poolside/laguna-s-2.1-free" "$TMPD/in-cadence.err" \
  || fail "in-cadence: must log REBENCHED (failed probe re-benches the mid-cycle wall): $(cat "$TMPD/in-cadence.err")"
grep -q "INTERVAL-BREACH" "$TMPD/in-cadence.err" \
  && fail "in-cadence: past-by-<interval wall must NOT breach: $(cat "$TMPD/in-cadence.err")"
grep -q "^fleet_seat_comeback_release_interval_breached_total 0$" "$PROM" \
  || fail "in-cadence: prom interval_breached_total must be 0: $(cat "$PROM")"
grep -q "^fleet_seat_comeback_release_stalled 0$" "$PROM" \
  || fail "in-cadence: prom stalled must be 0 (re-benched): $(cat "$PROM")"
new_usable=$(jq -r '.usable_at' "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json")
new_usable_epoch=$(date -u -d "$new_usable" +%s 2>/dev/null || echo 0)
(( new_usable_epoch > NOW_EPOCH )) || fail "in-cadence: wall must be advanced into the future, got $new_usable"
ok "in-cadence: past-by-<interval wall probed + re-benched, breach gauge 0, exit 0 (fleet-ops#2806)"

# --- 16. fleet-ops#2806: own-failure streak resets on a healthy interlude --
# The streak must NOT persist across a recovery: a seat that is observed
# healthy (real worker passed it, or the extension re-wrote it healthy)
# breaks the consecutive-failure streak even though the release organ did
# not probe it this sweep. Without the reset, a seat that recovered and
# then re-walled would carry its old streak forward and corpse too fast.
# State holds own_failures=24; the ledger is HEALTHY -> sweep clears the
# streak (state own_failures=0) and takes no other action, exit 0.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/commandcode__poolside_laguna-s-2.1-free.json" << 'EOF'
{"provider":"commandcode","model":"poolside/laguna-s-2.1-free","http_status":200,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:55:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF
STATE="$TMPD/state-streak-reset.json"
PROM="$TMPD/release-streak-reset.prom"
jq -nc '{"last_probe":{}, "probed_total": 0, "released_total": 0, "own_failures": {"commandcode__poolside_laguna-s-2.1-free.json": 24}}' > "$STATE"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/streak-reset.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "streak-reset: expected exit 0, got $rc ($(cat "$TMPD/streak-reset.err"))"
grep -qi "poolside" "$TMPD/streak-reset.err" \
  && fail "streak-reset: healthy seat must not be probed or mentioned: $(cat "$TMPD/streak-reset.err")"
own_failures=$(jq -r '.own_failures["commandcode__poolside_laguna-s-2.1-free.json"] // 0' "$STATE")
[[ "$own_failures" == "0" ]] \
  || fail "streak-reset: own_failures must reset to 0 on a healthy observation, got $own_failures: $(cat "$STATE")"
grep -q "^fleet_seat_comeback_release_interval_breached_total 0$" "$PROM" \
  || fail "streak-reset: prom interval_breached_total must be 0: $(cat "$PROM")"
ok "own-failure streak resets on a healthy interlude; no probe, no breach (fleet-ops#2806)"

# --- 17. fleet-ops#3156: no-wall corpse comeback-release paths ------------
# The lived seats_dead stuck case (opencode/mimo-v2.5-free c=25,
# straitly/deepseek-v4-pro c=43): the prober corpsed the seat
# (failure_mode=comeback_never_released, wall clocks null) but inside its
# 6h grace NOTHING releases or retires it — the corpse sits as seats_dead
# for the full grace window with no probe ever fired. The fix: a
# no-wall prober corpse gets ONE second-chance re-probe — success unwalls
# it (transition OUT of corpse, covered by the follow-up asserts above),
# failure RETIRES it immediately (grace bypass). Other corpse sources
# inside grace stay held (recovery window still open, no re-probe).

# 17a. failed second-chance re-probe -> explicit immediate retirement.
#      A fresh prober no-wall corpse (age 1h < 6h grace) with a FAILING
#      probe must be retired at once (no 6h wait), retired_total=1.
rm -rf "$TMPD/seats17" "$TMPD/seats-corpse-retired-$NOW_ISO"
mkdir -p "$TMPD/seats17"
cat > "$TMPD/seats17/opencode__mimo-v2.5-free.json" << 'EOF'
{"provider":"opencode","model":"mimo-v2.5-free","http_status":null,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"comeback_release_corpse","failure_mode":"comeback_never_released","usable_at":null,"bench_until":null,"consecutive_failure_count":25,"corpse_threshold":25}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state17a.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom17a.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17a.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17a: failed re-probe retirement sweep must exit 0, got $rc ($(cat "$TMPD/ret17a.err"))"
grep -q "corpse re-probe opencode/mimo-v2.5-free: no wall, second-chance re-probe" "$TMPD/ret17a.err" \
  || fail "17a: no-wall corpse must be re-probed (fleet-ops#3156): $(cat "$TMPD/ret17a.err")"
grep -q "explicitly retired opencode/mimo-v2.5-free after failed no-wall corpse re-probe" "$TMPD/ret17a.err" \
  || fail "17a: failed re-probe must explicitly retire the corpse: $(cat "$TMPD/ret17a.err")"
# fleet-ops#3669: retirement leaves a parked ledger in the live roster so the
# seat stays UNPICKABLE (the corpse ledger itself is moved to the audit dir).
[[ -f "$TMPD/seats17/opencode__mimo-v2.5-free.json" ]] \
  || fail "17a: retirement must leave a parked ledger in the live roster (fleet-ops#3669): $(ls "$TMPD/seats17")"
_parked_hc=$(jq -r '.health_class // ""' "$TMPD/seats17/opencode__mimo-v2.5-free.json" 2>/dev/null || true)
[[ "$_parked_hc" == "parked" ]] \
  || fail "17a: parked ledger must be health_class=parked, got $_parked_hc"
[[ -f "$TMPD/seats-corpse-retired-$NOW_ISO/opencode__mimo-v2.5-free.json" ]] \
  || fail "17a: retired corpse must land in the dated retirement dir: $(ls -la "$TMPD/seats-corpse-retired-$NOW_ISO" 2>&1)"
grep -q "^fleet_seat_comeback_release_retired_total 1$" "$TMPD/prom17a.prom" \
  || fail "17a: prom retired_total must be 1 (grace bypass): $(cat "$TMPD/prom17a.prom")"
ok "17a: failed second-chance re-probe retires the no-wall corpse immediately (grace bypass, fleet-ops#3156)"

# 17b. fleet-ops#3229: a no-wall corpse from a RECOVERABLE transient failure
#      mode (transient_http, source after_provider_response — the shape that
#      used to be held silently under the #3156 source guard) inside grace is
#      now re-probed. With a healthy probe stub the corpse transitions OUT of
#      corpse (unwalled) instead of parking dead for the full 6h grace — a
#      transient condition can clear on its own, so one bounded probe during
#      grace lets the seat recover the moment it clears.
rm -rf "$TMPD/seats17"
mkdir -p "$TMPD/seats17"
cat > "$TMPD/seats17/devin__glm-5-2.json" << 'EOF'
{"provider":"devin","model":"glm-5-2","http_status":503,"retry_after":null,"health_class":"corpse","retryable":true,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"transient_http","usable_at":null,"consecutive_failure_count":150}
EOF
rm -rf "$TMPD/seats-corpse-retired-$NOW_ISO"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state17b.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom17b.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17b.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17b: transient-corpse re-probe sweep must exit 0, got $rc ($(cat "$TMPD/ret17b.err"))"
grep -q "corpse re-probe devin/glm-5-2: no wall, second-chance re-probe" "$TMPD/ret17b.err" \
  || fail "17b: recoverable-mode no-wall corpse must be re-probed (fleet-ops#3229): $(cat "$TMPD/ret17b.err")"
grep -q "UNWALLED devin/glm-5-2" "$TMPD/ret17b.err" \
  || fail "17b: healthy re-probe must unwall the transient corpse: $(cat "$TMPD/ret17b.err")"
jq -e '.seat_dead == false and .health_class == "healthy"' \
  "$TMPD/seats17/devin__glm-5-2.json" >/dev/null \
  || fail "17b: transient corpse must land healthy after the re-probe: $(cat "$TMPD/seats17/devin__glm-5-2.json")"
grep -q "^fleet_seat_comeback_release_released_total 1$" "$TMPD/prom17b.prom" \
  || fail "17b: prom released_total must be 1: $(cat "$TMPD/prom17b.prom")"
ok "17b: recoverable-mode no-wall corpse inside grace is re-probed and unwalled (fleet-ops#3229)"

# 17c. non-dead seat with NO wall clock (bench_until and usable_at null) is
#      no longer silently skipped (the removed pre-#3156 defensive hold):
#      it is re-probed and, on success, unwalled. Proves the non-dead
#      no-wall class cannot sit stuck forever either.
rm -rf "$TMPD/seats17"
mkdir -p "$TMPD/seats17"
cat > "$TMPD/seats17/straitly__deepseek-v4-pro.json" << 'EOF'
{"provider":"straitly","model":"deepseek-v4-pro","http_status":null,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:55:00Z","source":"provider_fetch","failure_mode":"rate_limit","usable_at":null,"bench_until":null,"consecutive_failure_count":3}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state17c.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom17c.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17c.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17c: no-wall non-dead sweep must exit 0, got $rc ($(cat "$TMPD/ret17c.err"))"
grep -q "UNWALLED straitly/deepseek-v4-pro" "$TMPD/ret17c.err" \
  || fail "17c: no-wall non-dead seat must be re-probed and unwalled (fleet-ops#3156): $(cat "$TMPD/ret17c.err")"
jq -e '.seat_dead == false and .health_class == "healthy"' \
  "$TMPD/seats17/straitly__deepseek-v4-pro.json" >/dev/null \
  || fail "17c: seat must land healthy after the no-wall re-probe: $(cat "$TMPD/seats17/straitly__deepseek-v4-pro.json")"
grep -q "^fleet_seat_comeback_release_released_total 1$" "$TMPD/prom17c.prom" \
  || fail "17c: prom released_total must be 1: $(cat "$TMPD/prom17c.prom")"
ok "17c: non-dead no-wall seat re-probed and released, not silently stuck (fleet-ops#3156)"

# 17d. fleet-ops#3179: extension reclassifies the corpse DURING a failed
#      re-probe. The real pi --print triggers the seat-health extension,
#      which writes a new ledger entry on a real HTTP response (e.g. 402
#      quota_exhausted) BEFORE the bash probe_seat returns. The ledger
#      file is NO LONGER a corpse (health_class=quota_exhausted,
#      seat_dead=false, usable_at 24h future). The pre-#3179 code called
#      retire_corpse --force, which saw a non-corpse file, returned 1
#      ("held"), and logged the misleading "retire failed — held" even
#      though the seat was reclassified, not held. The fix: re-read the
#      ledger after the failed probe; if the extension reclassified it,
#      log the reclassification (the seat has a comeback clock now); only
#      force-retire when the ledger is STILL a corpse.
rm -rf "$TMPD/seats17" "$TMPD/seats-corpse-retired-$NOW_ISO"
mkdir -p "$TMPD/seats17"
cat > "$TMPD/seats17/straitly__deepseek_deepseek-v4-pro.json" << 'EOF'
{"provider":"straitly","model":"deepseek/deepseek-v4-pro","http_status":null,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"comeback_release_corpse","failure_mode":"comeback_never_released","usable_at":null,"bench_until":null,"consecutive_failure_count":43,"corpse_threshold":25}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state17d.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom17d.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail-reclassify" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17d.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17d: extension-reclassify sweep must exit 0, got $rc ($(cat "$TMPD/ret17d.err"))"
grep -q "corpse re-probe straitly/deepseek/deepseek-v4-pro: no wall, second-chance re-probe" "$TMPD/ret17d.err" \
  || fail "17d: no-wall corpse must be re-probed (fleet-ops#3156): $(cat "$TMPD/ret17d.err")"
grep -q "extension reclassified to health_class=quota_exhausted" "$TMPD/ret17d.err" \
  || fail "17d: must log extension reclassification, not 'retire failed — held' (fleet-ops#3179): $(cat "$TMPD/ret17d.err"))"
# The seat must NOT be retired (it was reclassified, not force-retired).
[[ ! -d "$TMPD/seats-corpse-retired-$NOW_ISO" || ! -f "$TMPD/seats-corpse-retired-$NOW_ISO/straitly__deepseek_deepseek-v4-pro.json" ]] \
  || fail "17d: reclassified corpse must NOT be retired: $(ls -la "$TMPD/seats-corpse-retired-$NOW_ISO" 2>&1)"
# The seat must still be in the live roster, now as quota_exhausted (not corpse).
[[ -f "$TMPD/seats17/straitly__deepseek_deepseek-v4-pro.json" ]] \
  || fail "17d: reclassified seat must remain in live roster: $(ls "$TMPD/seats17")"
jq -e '.health_class == "quota_exhausted" and .seat_dead == false' \
  "$TMPD/seats17/straitly__deepseek_deepseek-v4-pro.json" >/dev/null \
  || fail "17d: seat must be quota_exhausted not corpse after extension reclassification: $(cat "$TMPD/seats17/straitly__deepseek_deepseek-v4-pro.json")"
# retired_total must NOT have incremented (the seat was not retired).
grep -q "^fleet_seat_comeback_release_retired_total 0$" "$TMPD/prom17d.prom" \
  || fail "17d: prom retired_total must be 0 (reclassified, not retired): $(cat "$TMPD/prom17d.prom")"
ok "17d: extension reclassifies corpse during failed re-probe — logged as reclassification, not 'retire failed — held' (fleet-ops#3179)"

# 17e. fleet-ops#3229 (the issue's exact shape): a no-wall corpse from a
#      rate_limit failure mode written by the seat-health extension
#      (source=provider_fetch, http_status=429 — the lived
#      opencode/mimo-v2.5-free c=30 corpse that parked dead for the 6h grace
#      with no probe ever fired) inside grace is re-probed. With a FAILING
#      probe stub the corpse is explicitly retired immediately (grace bypass)
#      — the bounded re-probe confirms the seat is still dead and delists it
#      at once instead of waiting the full 6h. This is the issue's option 1:
#      a bounded re-probe, not a forever cycle.
rm -rf "$TMPD/seats17" "$TMPD/seats-corpse-retired-$NOW_ISO"
mkdir -p "$TMPD/seats17"
cat > "$TMPD/seats17/opencode__mimo-v2.5-free.json" << 'EOF'
{"provider":"opencode","model":"mimo-v2.5-free","http_status":429,"retry_after":null,"health_class":"corpse","retryable":true,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"provider_fetch","failure_mode":"rate_limit","usable_at":null,"bench_until":null,"consecutive_failure_count":30}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state17e.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom17e.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17e.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17e: rate_limit corpse re-probe sweep must exit 0, got $rc ($(cat "$TMPD/ret17e.err"))"
grep -q "corpse re-probe opencode/mimo-v2.5-free: no wall, second-chance re-probe" "$TMPD/ret17e.err" \
  || fail "17e: rate_limit no-wall corpse must be re-probed (fleet-ops#3229): $(cat "$TMPD/ret17e.err")"
# fleet-ops#3508: a failed re-probe of a rate_limit corpse is NOT a terminal
# retire — a 429 resets over a bounded window, so the corpse gets a bounded
# comeback clock (usable_at = now + RATE_LIMIT_COMEBACK_S=900, frozen NOW
# 2026-08-30T12:00:00Z => 12:15:00) and the seat re-enters the walled path.
grep -q "bounded comeback opencode/mimo-v2.5-free: rate_limit corpse re-anchored to usable_at +900s, seat re-enters the walled path" "$TMPD/ret17e.err" \
  || fail "17e: rate_limit corpse must get a bounded comeback, not immediate retire (fleet-ops#3508): $(cat "$TMPD/ret17e.err")"
[[ -f "$TMPD/seats17/opencode__mimo-v2.5-free.json" ]] \
  || fail "17e: rate_limit corpse must STAY in the live roster (bounded comeback, not retired): $(ls "$TMPD/seats17")"
[[ ! -d "$TMPD/seats-corpse-retired-$NOW_ISO" ]] \
  || fail "17e: no retirement dir may be created for a bounded-comeback rate_limit corpse: $(ls -la "$TMPD" 2>&1)"
jq -e '.seat_dead == false and .health_class == "rate_limited" and .failure_mode == "rate_limit" and (.usable_at | contains("2026-08-30T12:15:00")) and .consecutive_failure_count == 30' \
  "$TMPD/seats17/opencode__mimo-v2.5-free.json" >/dev/null \
  || fail "17e: rate_limit corpse ledger must carry a bounded comeback clock (seat_dead=false, usable_at future): $(cat "$TMPD/seats17/opencode__mimo-v2.5-free.json")"
grep -q "^fleet_seat_comeback_release_retired_total 0$" "$TMPD/prom17e.prom" \
  || fail "17e: prom retired_total must be 0 (no retire, bounded comeback): $(cat "$TMPD/prom17e.prom")"
ok "17e: rate_limit no-wall corpse re-probed; failed re-probe gets a bounded comeback clock, not an immediate retire (fleet-ops#3508)"

# 17f. fleet-ops#3229 permanent-mode guard: a no-wall corpse from a
#      PERMANENT failure mode (credentials_bad 401/403 — the model is gone /
#      the key is bad, re-probing cannot help) inside grace is NOT re-probed
#      even with a healthy probe stub; it is held silently for the 6h grace
#      (then retired by the #2716 path). This preserves the #3156 source
#      guard for classes where a re-probe is wasted, while #3229 widens it
#      only for recoverable transient modes.
rm -rf "$TMPD/seats17"
mkdir -p "$TMPD/seats17"
cat > "$TMPD/seats17/opencode__hy3-free.json" << 'EOF'
{"provider":"opencode","model":"hy3-free","http_status":401,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"credentials_bad","usable_at":null,"consecutive_failure_count":30}
EOF
rm -rf "$TMPD/seats-corpse-retired-$NOW_ISO"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state17f.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom17f.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17f.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17f: permanent-corpse guard sweep must exit 0, got $rc ($(cat "$TMPD/ret17f.err"))"
[[ -f "$TMPD/seats17/opencode__hy3-free.json" ]] \
  || fail "17f: permanent no-wall corpse must be held, not retired/re-probed: $(cat "$TMPD/ret17f.err")"
grep -q "re-probe" "$TMPD/ret17f.err" \
  && fail "17f: permanent-mode corpse must NOT be re-probed: $(cat "$TMPD/ret17f.err")"
grep -qi "opencode/hy3-free" "$TMPD/ret17f.err" \
  && fail "17f: permanent-mode corpse must not be mentioned at all (held silently): $(cat "$TMPD/ret17f.err")"
ok "17f: credentials_bad no-wall corpse inside grace is held, never re-probed (permanent-mode guard, fleet-ops#3229)"

# 17g. fleet-ops#3508: the bounded comeback clock is a REAL retry schedule.
#      After 17e re-anchored the rate_limit corpse to usable_at (now+900s),
#      a LATER sweep once the clock has passed re-probes the seat on the
#      normal wall-clock path and, on a healthy probe, UNWALLS it. Proves
#      the seat is not terminal and recovers the moment the rate limit
#      clears — the next seat-probe snapshot sees a released walled seat,
#      not a retired corpse.
rm -rf "$TMPD/seats17" "$TMPD/seats-corpse-retired-$NOW_ISO"
mkdir -p "$TMPD/seats17"
# A rate_limit corpse with no wall (the #3508 shape), frozen at 12:00.
cat > "$TMPD/seats17/opencode__mimo-v2.5-free.json" << 'EOF'
{"provider":"opencode","model":"mimo-v2.5-free","http_status":429,"retry_after":null,"health_class":"corpse","retryable":true,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"provider_fetch","failure_mode":"rate_limit","usable_at":null,"bench_until":null,"consecutive_failure_count":30}
EOF
STATE17G="$TMPD/state17g.json"
PROM17G="$TMPD/prom17g.prom"
# Sweep 1 (NOW=12:00): failed re-probe -> bounded comeback (usable_at 12:15).
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$STATE17G" \
    FLEET_SEAT_COMEBACK_PROM="$PROM17G" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17g1.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17g: sweep1 must exit 0, got $rc ($(cat "$TMPD/ret17g1.err"))"
grep -q "bounded comeback opencode/mimo-v2.5-free" "$TMPD/ret17g1.err" \
  || fail "17g: sweep1 must re-anchor the bounded comeback: $(cat "$TMPD/ret17g1.err")"
jq -e '.seat_dead == false and .usable_at == "2026-08-30T12:15:00.000Z"' \
  "$TMPD/seats17/opencode__mimo-v2.5-free.json" >/dev/null \
  || fail "17g: sweep1 must leave usable_at=12:15:00.000Z: $(cat "$TMPD/seats17/opencode__mimo-v2.5-free.json")"
# Sweep 2 (NOW=12:20, past the 12:15 clock): wall passed -> re-probe; the
# rate limit has cleared -> healthy probe unwalls the seat out of the
# walled path. The seat is recovered, not terminal.
NOW_GO="2026-08-30T12:20:00Z"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$STATE17G" \
    FLEET_SEAT_COMEBACK_PROM="$PROM17G" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_GO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17g2.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17g: sweep2 must exit 0, got $rc ($(cat "$TMPD/ret17g2.err"))"
tail -40 "$TMPD/ret17g2.err" | grep -q "UNWALLED opencode/mimo-v2.5-free" \
  || fail "17g: sweep2 must unwall the seat once the bounded clock passes (recovery): $(cat "$TMPD/ret17g2.err")"
jq -e '.seat_dead == false and .health_class == "healthy" and .failure_mode == "none" and .consecutive_failure_count == 0' \
  "$TMPD/seats17/opencode__mimo-v2.5-free.json" >/dev/null \
  || fail "17g: seat must land healthy after the bounded-comback re-probe: $(cat "$TMPD/seats17/opencode__mimo-v2.5-free.json")"
ok "17g: bounded comeback clock is a real retry schedule — seat unwalls on the next sweep once the clock passes (fleet-ops#3508)"

# 17h. fleet-ops#3638: RUNAWAY CORPSE guard. A no-wall corpse whose
#      consecutive_failure_count has climbed far past the threshold has
#      burned through many second-chance re-probes. The bounce cycle
#      (corpse -> re-probe -> extension reclassifies to walled -> re-probe
#      fails -> re-corpse at count+2 with a FRESH observed_at) resets
#      retire_corpse's 6h grace on every re-corpse, so the no-force retire
#      never fires and the count climbs without bound (lived xkiro seats at
#      117/109). Once the count crosses CORPSE_RUNAWAY_MULT x threshold
#      (default 4x = 100) the corpse is force-retired immediately — the
#      second-chance re-probe is NOT fired. This proves a corpse is either
#      revived (below the line, re-probed) or permanently excluded (at/above
#      the line, retired), and the live roster seat count reflects it (the
#      corpse ledger moves to the dated retirement dir; a parked ledger
#      takes its place so the seat stays unpickable).
rm -rf "$TMPD/seats17" "$TMPD/seats-corpse-retired-$NOW_ISO"
mkdir -p "$TMPD/seats17"
# The issue's exact shape: xkiro/deepseek/deepseek-v4-pro, count=117,
# failure_mode=comeback_never_released, no wall, observed_at 1h ago (inside
# the 6h grace — the no-force retire would HOLD it; the runaway guard must
# fire regardless of grace).
cat > "$TMPD/seats17/xkiro__deepseek_deepseek-v4-pro.json" << 'EOF'
{"provider":"xkiro","model":"deepseek/deepseek-v4-pro","http_status":null,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"comeback_release_corpse","failure_mode":"comeback_never_released","usable_at":null,"bench_until":null,"consecutive_failure_count":117,"corpse_threshold":25}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state17h.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom17h.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17h.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17h: runaway-corpse sweep must exit 0, got $rc ($(cat "$TMPD/ret17h.err"))"
# The runaway guard must fire — NOT the second-chance re-probe. Even with a
# healthy probe stub (pi-tool-ok), a runaway corpse is force-retired without
# probing, because the count proves the second chances are already exhausted.
grep -q "RUNAWAY corpse xkiro/deepseek/deepseek-v4-pro: count=117 >= 4x threshold 25 (line=100) — force-retire, second chances exhausted" "$TMPD/ret17h.err" \
  || fail "17h: runaway guard must log the force-retire line (fleet-ops#3638): $(cat "$TMPD/ret17h.err")"
grep -q "explicitly retired xkiro/deepseek/deepseek-v4-pro as runaway corpse (count=117, fleet-ops#3638)" "$TMPD/ret17h.err" \
  || fail "17h: runaway corpse must be explicitly retired (fleet-ops#3638): $(cat "$TMPD/ret17h.err")"
# The second-chance re-probe must NOT have fired (the runaway guard
# short-circuits before it).
grep -q "second-chance re-probe" "$TMPD/ret17h.err" \
  && fail "17h: runaway corpse must NOT get a second-chance re-probe (count already past the line): $(cat "$TMPD/ret17h.err")"
# fleet-ops#3669: retirement leaves a parked ledger in the live roster so the
# seat stays UNPICKABLE (the corpse ledger itself is moved to the audit dir).
[[ -f "$TMPD/seats17/xkiro__deepseek_deepseek-v4-pro.json" ]] \
  || fail "17h: retirement must leave a parked ledger in the live roster (fleet-ops#3669): $(ls "$TMPD/seats17")"
_parked_hc=$(jq -r '.health_class // ""' "$TMPD/seats17/xkiro__deepseek_deepseek-v4-pro.json" 2>/dev/null || true)
[[ "$_parked_hc" == "parked" ]] \
  || fail "17h: parked ledger must be health_class=parked, got $_parked_hc"
_parked_dead=$(jq -r '.seat_dead // false' "$TMPD/seats17/xkiro__deepseek_deepseek-v4-pro.json" 2>/dev/null || true)
[[ "$_parked_dead" == "true" ]] \
  || fail "17h: parked ledger must be seat_dead=true so the seat stays off the ladder, got $_parked_dead"
# The corpse ledger itself must land in the dated retirement dir.
[[ -f "$TMPD/seats-corpse-retired-$NOW_ISO/xkiro__deepseek_deepseek-v4-pro.json" ]] \
  || fail "17h: retired corpse must land in the dated retirement dir: $(ls -la "$TMPD/seats-corpse-retired-$NOW_ISO" 2>&1)"
grep -q "^fleet_seat_comeback_release_retired_total 1$" "$TMPD/prom17h.prom" \
  || fail "17h: prom retired_total must be 1 (runaway force-retire): $(cat "$TMPD/prom17h.prom")"
# The seat count reflects the retirement: the never-released gauge (which
# skips seat_dead=true) must be 0 over the post-sweep roster — the parked
# ledger is seat_dead=true, so the dead seat is NOT counted as a live
# never-released comeback.
_nr_n=$(python3 - "$repo_root/libexec/fleet-metrics-export.py" "$TMPD/seats17" "$NOW_EPOCH" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.SEAT_LEDGER = Path(sys.argv[2])
m.time.time = lambda: int(sys.argv[3])
nr_n, _ = m._read_never_released()
print(nr_n)
PY
)
[[ "$_nr_n" == "0" ]] \
  || fail "17h: never-released gauge must be 0 after runaway retirement (seat count reflects the dead seat), got $_nr_n"
ok "17h: runaway no-wall corpse (count=117 >= 4x threshold) is force-retired, not re-probed; live roster seat count reflects the retirement (fleet-ops#3638)"

# 17i. fleet-ops#3638 negative: a no-wall corpse just BELOW the runaway
#      line (count=99 < 100 at 4x threshold 25) still gets the second-chance
#      re-probe — the runaway guard only fires at/above the line, leaving
#      genuine slow-recovery seats room below it. With a healthy probe stub
#      the below-line corpse is unwalled (revived), proving the guard does
#      not over-reach.
rm -rf "$TMPD/seats17" "$TMPD/seats-corpse-retired-$NOW_ISO"
mkdir -p "$TMPD/seats17"
cat > "$TMPD/seats17/xkiro__minimax_minimax-m3_free.json" << 'EOF'
{"provider":"xkiro","model":"minimax/minimax-m3:free","http_status":null,"retry_after":null,"health_class":"corpse","retryable":false,"seat_dead":true,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"comeback_release_corpse","failure_mode":"comeback_never_released","usable_at":null,"bench_until":null,"consecutive_failure_count":99,"corpse_threshold":25}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats17" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state17i.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom17i.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-tool-ok" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret17i.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "17i: below-line corpse sweep must exit 0, got $rc ($(cat "$TMPD/ret17i.err"))"
grep -q "corpse re-probe xkiro/minimax/minimax-m3:free: no wall, second-chance re-probe" "$TMPD/ret17i.err" \
  || fail "17i: below-line corpse must still get the second-chance re-probe (fleet-ops#3638): $(cat "$TMPD/ret17i.err")"
grep -q "UNWALLED xkiro/minimax/minimax-m3:free" "$TMPD/ret17i.err" \
  || fail "17i: below-line corpse must be unwalled on a healthy re-probe (not runaway-retired): $(cat "$TMPD/ret17i.err")"
grep -q "RUNAWAY corpse" "$TMPD/ret17i.err" \
  && fail "17i: below-line corpse (count=99 < 100) must NOT trigger the runaway guard: $(cat "$TMPD/ret17i.err")"
jq -e '.seat_dead == false and .health_class == "healthy"' \
  "$TMPD/seats17/xkiro__minimax_minimax-m3_free.json" >/dev/null \
  || fail "17i: below-line corpse must land healthy after the re-probe: $(cat "$TMPD/seats17/xkiro__minimax_minimax-m3_free.json")"
grep -q "^fleet_seat_comeback_release_retired_total 0$" "$TMPD/prom17i.prom" \
  || fail "17i: prom retired_total must be 0 (below the line, revived not retired): $(cat "$TMPD/prom17i.prom")"
ok "17i: below-line no-wall corpse (count=99 < 4x threshold) still gets the second-chance re-probe and is revived (fleet-ops#3638)"

# --- 18. fleet-ops#3176: PQE 1h==1h deadlock — comeback-release must NOT ---
#      re-anchor a quota_exhausted seat whose observed_at is still inside the
#      PROVIDER_QUOTA_WINDOW_S (3600s) window. The live straitly/gpt-5.6-sol
#      + deepseek-v4-pro + qwen3.8-max burn: a 402 with no Retry-After got
#      daily_quota_s=3600 (== the PQE window), comeback-release probed at the
#      1h mark, the fresh 402 re-anchored observed_at=now, and the 1h window
#      never emptied so FleetProviderQuotaExhausted fired forever. The fix:
#      (a) seat-health.ts now defaults quota_exhausted to
#      free_balance_exhausted_s=86400 (strictly longer than 3600s); (b)
#      comeback-release skips probing a quota_exhausted seat whose observed_at
#      is inside the window; (c) comeback-release does NOT corpse a 402 by
#      count (quota_exhausted is time-based, not count-based). This test pins
#      all three on a scratch ledger with the exporter's PQE helper.
# -------------------------------------------------------------------------
# PQE count over $SEATDIR evaluated at a FIXED now (the exporter's
# _read_provider_quota_exhausted uses time.time(); pin it so the test is
# stable regardless of when it runs). Mirrors the overdue_n() helper.
pqe_n() {
    local seatdir="$1" now_epoch="$2"
    python3 - "$repo_root/libexec/fleet-metrics-export.py" "$seatdir" "$now_epoch" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("fme", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.SEAT_LEDGER = Path(sys.argv[2])
m.time.time = lambda: int(sys.argv[3])
n, _ = m._read_provider_quota_exhausted()
print(n)
PY
}

# 18a. Two 402s inside the 1h PQE window, expired usable_at. Comeback tick
#      must SKIP them (PQE gate), leave the ledger UNTOUCHED (observed_at not
#      re-anchored), and NOT probe. PQE total stays 1 (in window) right after
#      the tick — the point is the tick did not re-anchor, so observed_at can
#      still age out.
rm -rf "$TMPD/seats18"
mkdir -p "$TMPD/seats18"
# observed_at 5 min ago (inside 1h window), usable_at 5 min ago (expired wall
# — would normally be probed). count=24 so a count-based corpse would fire at
# 25 if the probe ran and failed (the 3176 guard must prevent both).
cat > "$TMPD/seats18/straitly__gpt-5.6-sol.json" << 'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:55:00Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T11:55:00Z","consecutive_failure_count":24}
EOF
cat > "$TMPD/seats18/straitly__deepseek_deepseek-v4-pro.json" << 'EOF'
{"provider":"straitly","model":"deepseek/deepseek-v4-pro","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:55:00Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T11:55:00Z","consecutive_failure_count":23}
EOF
# Pin the pre-tick PQE total: 2 straitly seats inside the window -> 1 provider.
pre_pqe=$(pqe_n "$TMPD/seats18" "$NOW_EPOCH")
[[ "$pre_pqe" == "1" ]] \
  || fail "18a: pre-tick PQE total must be 1 (2 straitly seats in window), got $pre_pqe"
# Snapshot observed_at BEFORE the tick to prove it is not re-anchored.
obs_before=$(jq -r '.observed_at' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats18" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state18a.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom18a.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret18a.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "18a: PQE-window skip sweep must exit 0, got $rc ($(cat "$TMPD/ret18a.err"))"
# The skip log must name both seats and the PQE window hold.
grep -q "skip probe straitly/gpt-5.6-sol: quota_exhausted observed_at still inside the 3600s PQE window" "$TMPD/ret18a.err" \
  || fail "18a: must log PQE-window skip for gpt-5.6-sol: $(cat "$TMPD/ret18a.err")"
grep -q "skip probe straitly/deepseek/deepseek-v4-pro: quota_exhausted observed_at still inside the 3600s PQE window" "$TMPD/ret18a.err" \
  || fail "18a: must log PQE-window skip for deepseek-v4-pro: $(cat "$TMPD/ret18a.err")"
# No probe, no re-bench, no corpse.
grep -qi "REBENCHED" "$TMPD/ret18a.err" && fail "18a: must NOT re-bench a PQE-window-held seat: $(cat "$TMPD/ret18a.err")"
grep -qi "CORPSED" "$TMPD/ret18a.err" && fail "18a: must NOT corpse a PQE-window-held seat: $(cat "$TMPD/ret18a.err")"
# Ledger UNTOUCHED — observed_at not re-anchored (the deadlock root cause).
obs_after=$(jq -r '.observed_at' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
[[ "$obs_after" == "$obs_before" ]] \
  || fail "18a: observed_at must NOT be re-anchored by the skip (was $obs_before, now $obs_after)"
# count unchanged (no probe, no re-bench increment).
count_after=$(jq -r '.consecutive_failure_count' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
[[ "$count_after" == "24" ]] \
  || fail "18a: count must stay 24 (no probe), got $count_after"
# PQE total right after the tick is still 1 (observed_at unchanged, still in
# window) — the tick did NOT make it worse. The win is observed_at can age out.
post_pqe=$(pqe_n "$TMPD/seats18" "$NOW_EPOCH")
[[ "$post_pqe" == "1" ]] \
  || fail "18a: post-tick PQE total must stay 1 (no re-anchor), got $post_pqe"
ok "18a: PQE-window-held 402s are skipped (no probe, no re-bench, no corpse, observed_at not re-anchored) — the 1h window can age out (fleet-ops#3176)"

# 18b. Advance past the PQE window (now+2h). observed_at is now 2h05m old
#      (outside 3600s). PQE total must be 0 — observed_at aged out because the
#      18a tick did not re-anchor it. This is the closure: without the fix the
#      tick would have re-anchored and PQE would still be 1 here.
NOW_PLUS_2H_ISO="2026-08-30T14:00:00Z"
NOW_PLUS_2H_EPOCH=$(date -u -d "$NOW_PLUS_2H_ISO" +%s)
aged_pqe=$(pqe_n "$TMPD/seats18" "$NOW_PLUS_2H_EPOCH")
[[ "$aged_pqe" == "0" ]] \
  || fail "18b: PQE total must be 0 after observed_at ages out (no re-anchor), got $aged_pqe"
ok "18b: PQE total drops to 0 once observed_at ages out — the 1h==1h deadlock is broken (fleet-ops#3176)"

# 18c. After the window ages out, the next comeback tick DOES probe (the gate
#      releases). A failed probe re-benches but does NOT corpse a 402 by count
#      (quota_exhausted is time-based, not count-based — the live
#      straitly/gpt-5.6-sol was CORPSED at count=38 by the prober's count-based
#      corpse path even though its observed_at was only ~1h old). Pin both: the
#      probe fires, re-benches, count climbs to 25, but seat_dead stays false.
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$TMPD/seats18" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state18c.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/prom18c.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_PLUS_2H_ISO" \
    PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret18c.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "18c: post-window probe sweep must exit 0, got $rc ($(cat "$TMPD/ret18c.err"))"
# The PQE-window skip must NOT fire now (observed_at is outside the window).
grep -q "skip probe straitly/gpt-5.6-sol: quota_exhausted observed_at still inside" "$TMPD/ret18c.err" \
  && fail "18c: must NOT skip a seat whose observed_at is outside the PQE window: $(cat "$TMPD/ret18c.err")"
# The probe fired and re-benched (the wall was expired, the gate released).
grep -q "REBENCHED straitly/gpt-5.6-sol" "$TMPD/ret18c.err" \
  || fail "18c: must re-bench gpt-5.6-sol after the probe fails (gate released): $(cat "$TMPD/ret18c.err")"
# CRITICAL: the 402 must NOT be corpseed by count even though count crosses 25.
grep -q "skip corpse straitly/gpt-5.6-sol: quota_exhausted is time-based" "$TMPD/ret18c.err" \
  || fail "18c: must log skip-corpse for quota_exhausted (time-based, not count-based): $(cat "$TMPD/ret18c.err")"
grep -q "CORPSED straitly/gpt-5.6-sol" "$TMPD/ret18c.err" \
  && fail "18c: must NOT corpse a 402 by count (quota_exhausted is time-based): $(cat "$TMPD/ret18c.err")"
dead=$(jq -r '.seat_dead' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
[[ "$dead" == "false" ]] \
  || fail "18c: seat_dead must stay false for a 402 corpseed-by-count guard, got $dead"
# rebench_seat clobbers quota_exhausted to transient_fault (it only preserves
# overload_bench); the corpse guard uses the PRE-rebench class to decide. The
# ledger post-rebench carries transient_fault (the prober's re-bench class),
# NOT corpse — the time-based corpse fires in seat-health.ts on a real 402
# response at observed_at age >= 24h, not here.
hc=$(jq -r '.health_class' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
[[ "$hc" == "transient_fault" ]] \
  || fail "18c: health_class must be transient_fault (re-bench clobber, not corpse), got $hc"
# count climbed to 25 (the re-bench incremented it) but no corpse.
count=$(jq -r '.consecutive_failure_count' "$TMPD/seats18/straitly__gpt-5.6-sol.json")
[[ "$count" == "25" ]] \
  || fail "18c: count must climb to 25 (re-bench increment), got $count"
ok "18c: post-window probe fires + re-benches, but 402 NOT corpseed by count (time-based, not count-based) — fleet-ops#3176"

# 18d. seat-health.ts backoff pin: a no-Retry-After 402 must default to
#      free_balance_exhausted_s=86400 (strictly longer than the 3600s PQE
#      window), not daily_quota_s=3600. A provider Retry-After still wins.
#      This is the out-of-repo extension; skip if not installed (mirrors the
#      seat-health-quarantine / seat-health-seat-dead CI safety pattern).
EXT_PATH="${FLEET_SEAT_HEALTH_TS:-$HOME/.pi/agent/extensions/seat-health.ts}"
if [[ -f "$EXT_PATH" ]] && command -v node >/dev/null 2>&1; then
    node_major=$(node -e 'console.log(Number.parseInt(process.versions.node.split(".")[0], 10))')
    node_minor=$(node -e 'console.log(Number.parseInt(process.versions.node.split(".")[1], 10))')
    if [[ "$node_major" -ge 22 ]] || { [[ "$node_major" -eq 22 ]] && [[ "$node_minor" -ge 6 ]]; }; then
        backoff_out=$(node --experimental-strip-types --no-warnings=ExperimentalWarning \
            --input-type=module -e "
import { computeUsableAt } from ${EXT_PATH@Q};
const now = Date.now();
const u = computeUsableAt('quota_exhausted', null, now, 0);
const s = u === null ? null : Math.round((Date.parse(u) - now) / 1000);
console.log('BACKOFF:' + s);
" 2>&1 | tail -1)
        [[ "$backoff_out" == BACKOFF:* ]] || fail "18d: node did not emit BACKOFF line (got $backoff_out)"
        backoff="${backoff_out#BACKOFF:}"
        [[ "$backoff" == "86400" ]] \
          || fail "18d: quota_exhausted no-Retry-After backoff must be 86400 (free_balance_exhausted_s, strictly > 3600s PQE window), got $backoff"
        # A provider Retry-After of 3600 still wins (max(base, retry)).
        retry_out=$(node --experimental-strip-types --no-warnings=ExperimentalWarning \
            --input-type=module -e "
import { computeUsableAt } from ${EXT_PATH@Q};
const now = Date.now();
const u = computeUsableAt('quota_exhausted', 3600, now, 0);
const s = u === null ? null : Math.round((Date.parse(u) - now) / 1000);
console.log('RETRY:' + s);
" 2>&1 | tail -1)
        [[ "$retry_out" == RETRY:* ]] || fail "18d: node did not emit RETRY line (got $retry_out)"
        retry="${retry_out#RETRY:}"
        [[ "$retry" == "3600" ]] \
          || fail "18d: quota_exhausted Retry-After=3600 must be honoured (3600), got $retry"
        ok "18d: seat-health.ts quota_exhausted default backoff=86400 (strictly > 3600s PQE window); provider Retry-After=3600 still wins (fleet-ops#3176)"
    else
        ok "18d: SKIP seat-health.ts backoff pin (node < 22.6 for --experimental-strip-types) (fleet-ops#3176)"
    fi
else
    ok "18d: SKIP seat-health.ts backoff pin (extension not installed at $EXT_PATH) (fleet-ops#3176)"
fi

# --- 19. fleet-ops#3301: skip corpse when THIS sweep re-anchored a wall ---
# Lived 2026-09-04T16:30Z opencode/mimo-v2.5-free: wall expired, probe
# failed with HTTP 429, the extension wrote usable_at +15min, rebench_seat
# skipped ("wall moved to the future"), then corpse_seat rewrote the
# ledger to failure_mode=comeback_never_released / usable_at=null. The
# seat then sat at 27 consecutive failures with no retry window. Honour
# the wall: skip the corpse write so the 15-min window stands. Count-based
# corpse still fires on the next sweep IF that sweep's probe does not
# re-anchor (no HTTP window) — test 10 pins that path.
rm -rf "$SEATDIR"
mkdir -p "$SEATDIR"
cat > "$SEATDIR/opencode__mimo-v2.5-free.json" << 'EOF'
{"provider":"opencode","model":"mimo-v2.5-free","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:45:00Z","source":"provider_fetch","failure_mode":"rate_limit","usable_at":"2026-08-30T11:45:00Z","consecutive_failure_count":26}
EOF
STATE="$TMPD/state-3301.json"
PROM="$TMPD/release-3301.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATDIR" \
    FLEET_SEAT_COMEBACK_STATE="$STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-fail-reanchor-429" \
    bash "$BIN" >/dev/null 2>"$TMPD/ret19.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "19: sweep must exit 0, got $rc ($(cat "$TMPD/ret19.err"))"
grep -q "skip rebench opencode/mimo-v2.5-free: wall moved to the future" "$TMPD/ret19.err" \
  || fail "19: must skip rebench because the extension re-anchored: $(cat "$TMPD/ret19.err")"
grep -q "skip corpse opencode/mimo-v2.5-free: extension re-anchored a future wall this sweep" "$TMPD/ret19.err" \
  || fail "19: must skip corpse so the retry window stands (fleet-ops#3301): $(cat "$TMPD/ret19.err")"
grep -q "CORPSED opencode/mimo-v2.5-free" "$TMPD/ret19.err" \
  && fail "19: must NOT corpse a seat whose extension just set a future wall: $(cat "$TMPD/ret19.err")"
jq -e '.seat_dead == false and .health_class == "rate_limited" and .failure_mode == "rate_limit" and .usable_at == "2026-08-30T12:15:04.204Z" and .consecutive_failure_count == 27' \
  "$SEATDIR/opencode__mimo-v2.5-free.json" >/dev/null \
  || fail "19: ledger must keep the extension's 429 retry window, not a no-wall corpse: $(cat "$SEATDIR/opencode__mimo-v2.5-free.json")"
ok "19: extension-reanchored 429 retry window is not wiped by corpse_seat (fleet-ops#3301)"

# --- 20. phantom seat key (fleet-ops#3661) --------------------------------
# A stray devin__swe-1-7-.out.json (a probe-output filename fragment, not a
# real seat) must be SKIPPED by the sweep with a LOUD SEAT-KEY-INVALID line
# and NEVER probed; and a writer call with model swe-1-7-.out must write
# nothing and log LOUD.
PHANTD="$TMPD/seats-phantom"
mkdir -p "$PHANTD"
cat > "$PHANTD/devin__swe-1-7-.out.json" <<'EOF'
{"provider":"devin","model":"swe-1-7-.out","http_status":1,"retry_after":null,"health_class":"transient_other","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"cli_spawn","failure_mode":"transient_other","usable_at":"2026-08-30T11:30:00Z","consecutive_failure_count":18}
EOF
# A stub pi that records every invocation — the phantom must never reach it.
cat > "$TMPD/pi-probe-log" <<'EOF'
#!/usr/bin/env bash
echo "PROBED $*" >>"${PI_PROBE_LOG:-/dev/null}"
exit 1
EOF
chmod +x "$TMPD/pi-probe-log"
: >"$TMPD/probe.log"
PHANT_STATE="$TMPD/state-phantom.json"
PHANT_PROM="$TMPD/release-phantom.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$PHANTD" \
    FLEET_SEAT_COMEBACK_STATE="$PHANT_STATE" \
    FLEET_SEAT_COMEBACK_PROM="$PHANT_PROM" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-probe-log" \
    PI_PROBE_LOG="$TMPD/probe.log" \
    bash "$BIN" >/dev/null 2>"$TMPD/phantom.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "20: phantom sweep must exit 0, got $rc ($(cat "$TMPD/phantom.err"))"
grep -q "LOUD SEAT-KEY-INVALID devin/swe-1-7-.out writer=fleet-seat-comeback-release (phantom)" "$TMPD/phantom.err" \
  || fail "20: phantom must be skipped with the LOUD SEAT-KEY-INVALID line: $(cat "$TMPD/phantom.err")"
[[ ! -s "$TMPD/probe.log" ]] \
  || fail "20: phantom seat must NEVER be probed: $(cat "$TMPD/probe.log")"
# fleet-ops#3993: a probe-artifact phantom can never be unwalled, so it is
# retired OUT of the live roster (not merely left untouched) — otherwise the
# census / thorough detector count it comeback-overdue forever. The ledger
# must no longer be in the roster (moved to seats-phantom-retired-*/).
[[ ! -e "$PHANTD/devin__swe-1-7-.out.json" ]] \
  || fail "20: phantom ledger must be retired out of the roster: $(ls "$PHANTD")"
PHANT_RETIRE="$TMPD/seats-phantom-retired-$NOW_ISO"
[[ -d "$PHANT_RETIRE" && -f "$PHANT_RETIRE/devin__swe-1-7-.out.json" ]] \
  || fail "20: phantom must land in the dated seats-phantom-retired-<ts>/ dir ($PHANT_RETIRE)"
grep -q "RETIRED PHANTOM devin/swe-1-7-.out" "$TMPD/phantom.err" \
  || fail "20: sweep must log the phantom retirement: $(cat "$TMPD/phantom.err")"
ok "20: phantom seat key retired out of roster by comeback-release, never probed (fleet-ops#3661/#3993)"

# Writer call with a phantom model: mark_seat_spawn_fail must write nothing
# and log LOUD. Source seat-lib with a scratch ledger + caps fixture.
PHANT_LEDGER="$TMPD/ledger-writer"
mkdir -p "$PHANT_LEDGER"
PHANT_LOG="$TMPD/seat-lib-writer.log"
: >"$PHANT_LOG"
set +e
out=$(PI_SEAT_LIB_CHECK_TRANSPORT=0 \
    PI_SEAT_HEALTH_LEDGER_DIR="$PHANT_LEDGER" \
    SEAT_CAPS_JSON="$TMPD/seat-caps.json" \
    PI_PACKET_STATE="$TMPD/pi-packet-state" \
    bash -c 'source "$0"; mark_seat_spawn_fail devin "swe-1-7-.out"' "$repo_root/lib/seat-lib.sh" 2>&1)
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "20: writer must reject the phantom key (rc=1), got rc=$rc: $out"
[[ ! -e "$PHANT_LEDGER/devin__swe-1-7-.out.json" ]] \
  || fail "20: writer must write NO ledger for the phantom key: $(ls "$PHANT_LEDGER")"
grep -q "LOUD SEAT-KEY-INVALID devin/swe-1-7-.out writer=mark_seat_spawn_fail" <<<"$out" \
  || fail "20: writer must log the LOUD SEAT-KEY-INVALID line: $out"
ok "20: writer call with phantom model writes nothing and logs LOUD (fleet-ops#3661)"

# ---------------------------------------------------------------------------
# 21. fleet-ops#3993: an expired usable_at deterministically returns the seat.
# Two seats from the thorough heartbeat (2026-09-06T15:45Z) that were stuck
# comeback-overdue because the release organ skipped BOTH as "phantom":
#   - devin/glm-5-2-.out  : a TRUE probe-output fragment (model ends .out).
#                           Can never be unwalled -> RETIRED out of the roster
#                           (the census/detector stop counting it).
#   - orcarouter/free     : a REAL provider seat absent from the seat-caps
#                           models map (cap=0 parked for re-audition). It IS
#                           routable -> RE-PROBED on wall expiry (automated
#                           re-audition) and re-benched into a future wall on
#                           the 402, so it is no longer overdue.
# ---------------------------------------------------------------------------
SEATD21="$TMPD/seats21"
mkdir -p "$SEATD21"
# TRUE phantom: model is a probe-output fragment, usable_at in the past.
cat > "$SEATD21/devin__glm-5-2-.out.json" <<'EOF'
{"provider":"devin","model":"glm-5-2-.out","http_status":1,"retry_after":null,"health_class":"transient_fault","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"cli_spawn","failure_mode":"transient_other","usable_at":"2026-08-30T11:00:00Z","consecutive_failure_count":1}
EOF
# REAL seat absent from the caps models map (orcarouter has no models row),
# quota_exhausted, observed_at OLD (outside the PQE window) so the probe
# fires, usable_at in the past.
cat > "$SEATD21/orcarouter__orcarouter_free.json" <<'EOF'
{"provider":"orcarouter","model":"orcarouter/free","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-29T09:16:51Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T09:16:51Z","consecutive_failure_count":1}
EOF
# A failing probe stub that records every probe invoked.
cat > "$TMPD/pi-probe-log21" <<'EOF'
#!/usr/bin/env bash
echo "PROBED $*" >>"${PI_PROBE_LOG:-/dev/null}"
exit 1
EOF
chmod +x "$TMPD/pi-probe-log21"
: >"$TMPD/probe21.log"
ST21="$TMPD/state21.json"
PROM21="$TMPD/release21.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATD21" \
    FLEET_SEAT_COMEBACK_STATE="$ST21" \
    FLEET_SEAT_COMEBACK_PROM="$PROM21" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-probe-log21" \
    PI_PROBE_LOG="$TMPD/probe21.log" \
    bash "$BIN" >/dev/null 2>"$TMPD/run21.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "21: sweep of the two stuck seats must exit 0, got $rc ($(cat "$TMPD/run21.err"))"

# 1. The TRUE phantom is retired OUT of the live roster (never probed).
[[ ! -e "$SEATD21/devin__glm-5-2-.out.json" ]] \
  || fail "21: devin phantom ledger must be retired out of the roster: $(ls "$SEATD21")"
grep -q "LOUD SEAT-KEY-INVALID devin/glm-5-2-.out writer=fleet-seat-comeback-release (phantom)" "$TMPD/run21.err" \
  || fail "21: devin phantom must log the phantom SEAT-KEY-INVALID line: $(cat "$TMPD/run21.err")"
[[ ! -e "$TMPD/probe21.log" ]] || {
  grep -q "devin/glm-5-2-.out" "$TMPD/probe21.log" && \
    fail "21: devin phantom must NEVER be probed: $(cat "$TMPD/probe21.log")" || true
}

# 2. The REAL orcarouter seat is re-probed (re-audition) and re-benched into
#    a FUTURE wall, so it is no longer comeback-overdue.
grep -q "PROBED.*--provider orcarouter --model orcarouter/free" "$TMPD/probe21.log" \
  || fail "21: real orcarouter seat must be re-probed: $(cat "$TMPD/probe21.log")"
[[ -f "$SEATD21/orcarouter__orcarouter_free.json" ]] \
  || fail "21: orcarouter ledger must remain in the roster (re-bench, not retire)"
ou_a=$(jq -r '.usable_at // ""' "$SEATD21/orcarouter__orcarouter_free.json")
ou_e=$(date -u -d "${ou_a%Z}" +%s)
(( ou_e > NOW_EPOCH )) \
  || fail "21: orcarouter usable_at must be re-benched into the future ($ou_a <= now), got: $(cat "$SEATD21/orcarouter__orcarouter_free.json")"

# 3. The comeback-overdue detector clears: both seats reclassified.
# (Overdue computed against SEATD21, the same ledger the sweep just ran on,
# using the fixed helper so the metrics reads the same scratch caps.)
ocd_n=$(overdue_n "$SEATD21")
[[ "$ocd_n" == "0" ]] || fail "21: comeback-overdue must be 0 after the sweep (both seats reclassified), got $ocd_n"
ok "21: devin phantom retired + real orcarouter re-probed/re-benched -> comeback-overdue 0 (fleet-ops#3993)"

# ---------------------------------------------------------------------------
# 22. fleet-ops#4659: comeback-release must honour a FUTURE spawn-bench
# marker the same way seat_usable does. Lived 2026-09-09: the router's
# pick_seat held straitly/deepseek-v4-pro (spawn-bench until 2026-09-12)
# while comeback-release probed because the ledger usable_at (#3176 1h
# PQE hold) had aged out. A probe on a 402 account wall re-anchors
# observed_at and retriggers FleetProviderQuotaExhausted.
#
# 22a. Listed seat, ledger wall EXPIRED and outside the PQE window, but
#      spawn-bench usable_at still in the future. Must NOT probe, must NOT
#      stall/breach (the hold is intentional), ledger left untouched.
# 22b. Same provider, unlisted slug (the #3993 re-audition path) while a
#      listed sibling already carries a money_boundary / quota wall. Must
#      NOT be the 2nd 402 that keeps PQE firing.
# 22c. Control: listed expired 402 with NO spawn-bench still probes after
#      the PQE window ages out (the #3176 age-out path must survive).
# ---------------------------------------------------------------------------
SEATD22="$TMPD/seats22"
mkdir -p "$SEATD22"
cat > "$TMPD/seat-caps22.json" <<'CAPS'
{
  "providers": {
    "straitly": {"models": {"deepseek/deepseek-v4-pro": 1}}
  }
}
CAPS
# Listed 402, observed_at OUTSIDE the 1h PQE window, usable_at past by
# more than MIN_INTERVAL — without the spawn-bench hold this is a probe
# AND an interval-breach. Spawn-bench usable_at is the live 7d hold.
cat > "$SEATD22/straitly__deepseek_deepseek-v4-pro.json" <<'EOF'
{"provider":"straitly","model":"deepseek/deepseek-v4-pro","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T05:20:02Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T05:20:02Z","bench_until":"2026-08-30T05:20:02Z","consecutive_failure_count":23}
EOF
cat > "$SEATD22/straitly__deepseek_deepseek-v4-pro.spawn-bench.json" <<'EOF'
{"provider":"straitly","model":"deepseek/deepseek-v4-pro","usable_at":"2026-09-12T18:47:00Z","reason":"pqe-repair 7d hold","written_at":"2026-09-05T18:47:00Z","backoff_s":604800,"failure_mode":"quota_exhausted","consecutive_failure_count":1,"writer":"alert-repair"}
EOF
# Unlisted (retired Sol) — #3993 would re-audition this once the ledger
# wall ages out. Provider already has the listed 402/money wall above.
cat > "$SEATD22/straitly__gpt-5.6-sol.json" <<'EOF'
{"provider":"straitly","model":"gpt-5.6-sol","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T05:20:02Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T05:20:02Z","consecutive_failure_count":4}
EOF
cat > "$TMPD/pi-probe-log22" <<'EOF'
#!/usr/bin/env bash
echo "PROBED $*" >>"${PI_PROBE_LOG:-/dev/null}"
exit 1
EOF
chmod +x "$TMPD/pi-probe-log22"
: >"$TMPD/probe22.log"
ST22="$TMPD/state22.json"
PROM22="$TMPD/release22.prom"
before_listed=$(cat "$SEATD22/straitly__deepseek_deepseek-v4-pro.json")
before_unlisted=$(cat "$SEATD22/straitly__gpt-5.6-sol.json")
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATD22" \
    SEAT_CAPS_JSON="$TMPD/seat-caps22.json" \
    FLEET_SEAT_COMEBACK_STATE="$ST22" \
    FLEET_SEAT_COMEBACK_PROM="$PROM22" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-probe-log22" \
    PI_PROBE_LOG="$TMPD/probe22.log" \
    bash "$BIN" >/dev/null 2>"$TMPD/run22.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "22: spawn-bench-held 402 must exit 0 (intentional hold, not stalled), got $rc ($(cat "$TMPD/run22.err"))"
[[ ! -s "$TMPD/probe22.log" ]] \
  || fail "22: must NOT probe a spawn-bench-held 402 or its unlisted sibling: $(cat "$TMPD/probe22.log")"
grep -q "spawn-bench" "$TMPD/run22.err" \
  || fail "22: must log the spawn-bench hold for the listed 402: $(cat "$TMPD/run22.err")"
grep -q "probing straitly/deepseek/deepseek-v4-pro" "$TMPD/run22.err" \
  && fail "22: listed 402 with future spawn-bench must not be probed: $(cat "$TMPD/run22.err")"
grep -q "probing straitly/gpt-5.6-sol" "$TMPD/run22.err" \
  && fail "22: unlisted 402 must not be re-auditioned while the provider already has a quota wall: $(cat "$TMPD/run22.err")"
grep -qi "COMEBACK-RELEASE-STALLED" "$TMPD/run22.err" \
  && fail "22: spawn-bench hold must not trip the stalled loud check: $(cat "$TMPD/run22.err")"
grep -qi "INTERVAL BREACH" "$TMPD/run22.err" \
  && fail "22: spawn-bench hold must not trip interval-breach: $(cat "$TMPD/run22.err")"
[[ "$(cat "$SEATD22/straitly__deepseek_deepseek-v4-pro.json")" == "$before_listed" ]] \
  || fail "22: listed ledger must be left untouched (no re-bench 402 re-anchor)"
[[ "$(cat "$SEATD22/straitly__gpt-5.6-sol.json")" == "$before_unlisted" ]] \
  || fail "22: unlisted ledger must be left untouched"
ok "22a/b: future spawn-bench holds the listed 402; unlisted sibling is not the 2nd 402 (fleet-ops#4659)"

# 22c. Control: same listed 402, NO spawn-bench, PQE window aged out → probe.
SEATD22c="$TMPD/seats22c"
mkdir -p "$SEATD22c"
cat > "$SEATD22c/straitly__deepseek_deepseek-v4-pro.json" <<'EOF'
{"provider":"straitly","model":"deepseek/deepseek-v4-pro","http_status":402,"retry_after":null,"health_class":"quota_exhausted","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T05:20:02Z","source":"provider_fetch","failure_mode":"quota_exhausted","usable_at":"2026-08-30T05:20:02Z","consecutive_failure_count":23}
EOF
: >"$TMPD/probe22c.log"
ST22c="$TMPD/state22c.json"
PROM22c="$TMPD/release22c.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATD22c" \
    SEAT_CAPS_JSON="$TMPD/seat-caps22.json" \
    FLEET_SEAT_COMEBACK_STATE="$ST22c" \
    FLEET_SEAT_COMEBACK_PROM="$PROM22c" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-probe-log22" \
    PI_PROBE_LOG="$TMPD/probe22c.log" \
    bash "$BIN" >/dev/null 2>"$TMPD/run22c.err"
rc=$?
set -e
grep -q "PROBED.*--provider straitly --model deepseek/deepseek-v4-pro" "$TMPD/probe22c.log" \
  || fail "22c: expired 402 with no spawn-bench must still probe after PQE ages out: log=$(cat "$TMPD/probe22c.log") err=$(cat "$TMPD/run22c.err")"
ok "22c: expired 402 without spawn-bench still probes after PQE ages out (fleet-ops#4659)"

# ---------------------------------------------------------------------------
# 23. fleet-ops#4640: a NON-money 24h wall on a cap>0 seat PONGs and
#     releases even while usable_at is in the future. Money 402 hold
#     (test 22) must keep skipping.
# ---------------------------------------------------------------------------
"$BIN" --help >"$TMPD/help.out" 2>/dev/null || fail "23: --help must exit 0"
grep -q -- '--false-wall-drill' "$TMPD/help.out" \
  || fail "23: --help must name --false-wall-drill: $(cat "$TMPD/help.out")"
ok "23: --help names --false-wall-drill"

SEATD23="$TMPD/seats23"
mkdir -p "$SEATD23"
cat > "$TMPD/seat-caps23.json" <<'CAPS'
{
  "providers": {
    "devin": {"cap": 4, "models": {"glm-5-2": 4}}
  }
}
CAPS
# NOW_ISO=2026-08-30T12:00:00Z; wall +24h.
cat > "$SEATD23/devin__glm-5-2.json" <<'EOF'
{"provider":"devin","model":"glm-5-2","http_status":429,"retry_after":null,"health_class":"rate_limited","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"rate_limit","usable_at":"2026-08-31T12:00:00Z","bench_until":"2026-08-31T12:00:00Z","consecutive_failure_count":2,"writer":"mark_seat_quota_bench"}
EOF
cat > "$SEATD23/devin__glm-5-2.spawn-bench.json" <<'EOF'
{"provider":"devin","model":"glm-5-2","usable_at":"2026-08-31T12:00:00Z","reason":"test:false-wall","written_at":"2026-08-30T11:00:00Z","backoff_s":86400,"failure_mode":"rate_limit","consecutive_failure_count":2,"writer":"mark_seat_quota_bench"}
EOF
cat > "$TMPD/pi-pong" <<'EOF'
#!/usr/bin/env bash
echo "PONG"
exit 0
EOF
chmod +x "$TMPD/pi-pong"
ST23="$TMPD/state23.json"
PROM23="$TMPD/release23.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATD23" \
    SEAT_CAPS_JSON="$TMPD/seat-caps23.json" \
    FLEET_SEAT_COMEBACK_STATE="$ST23" \
    FLEET_SEAT_COMEBACK_PROM="$PROM23" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    PI_BIN="$TMPD/pi-pong" \
    bash "$BIN" >/dev/null 2>"$TMPD/run23.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "23: non-money 24h wall PONG must exit 0, got $rc ($(cat "$TMPD/run23.err"))"
grep -q "SEAT-WALL-FALSE" "$TMPD/run23.err" \
  || fail "23: must log SEAT-WALL-FALSE: $(cat "$TMPD/run23.err")"
grep -q "writer=mark_seat_quota_bench" "$TMPD/run23.err" \
  || fail "23: SEAT-WALL-FALSE must name the writer: $(cat "$TMPD/run23.err")"
hc=$(jq -r '.health_class' "$SEATD23/devin__glm-5-2.json")
[[ "$hc" == "healthy" ]] || fail "23: PONG must unwall the seat, got $hc"
[[ ! -f "$SEATD23/devin__glm-5-2.spawn-bench.json" ]] \
  || fail "23: spawn-bench marker must be deleted on false-wall release"
ok "23: non-money 24h wall + PONG -> SEAT-WALL-FALSE + release (fleet-ops#4640)"

# 23b. --false-wall-drill injects a 24h wall and requires SEAT-WALL-FALSE.
SEATD23b="$TMPD/seats23b"
mkdir -p "$SEATD23b"
cat > "$SEATD23b/devin__glm-5-2.json" <<'EOF'
{"provider":"devin","model":"glm-5-2","http_status":200,"retry_after":null,"health_class":"healthy","retryable":false,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"after_provider_response","failure_mode":"none","usable_at":null,"consecutive_failure_count":0}
EOF
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATD23b" \
    SEAT_CAPS_JSON="$TMPD/seat-caps23.json" \
    FLEET_SEAT_COMEBACK_STATE="$TMPD/state23b.json" \
    FLEET_SEAT_COMEBACK_PROM="$TMPD/release23b.prom" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" \
    FLEET_SEAT_COMEBACK_DRILL_PROVIDER="devin" \
    FLEET_SEAT_COMEBACK_DRILL_MODEL="glm-5-2" \
    PI_BIN="$TMPD/pi-pong" \
    bash "$BIN" --false-wall-drill >/dev/null 2>"$TMPD/run23b.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "23b: --false-wall-drill must exit 0, got $rc ($(cat "$TMPD/run23b.err"))"
grep -q "SEAT-WALL-FALSE" "$TMPD/run23b.err" \
  || fail "23b: drill must log SEAT-WALL-FALSE: $(cat "$TMPD/run23b.err")"
grep -q "FALSE-WALL-DRILL pass" "$TMPD/run23b.err" \
  || fail "23b: drill must log pass: $(cat "$TMPD/run23b.err")"
hc=$(jq -r '.health_class' "$SEATD23b/devin__glm-5-2.json")
[[ "$hc" == "healthy" ]] || fail "23b: drill must leave the seat healthy, got $hc"
ok "23b: --false-wall-drill injects 24h wall, PONG-releases, logs SEAT-WALL-FALSE"

# --- 24. fleet-ops#5285 bench-truth: live seat benched = lie -> cleared, counted --
# A cap>0 non-money seat benched 6 DAYS (the lived devin/swe-1-7 record) whose
# bench was written an hour ago and which answers PONG: the probe clears it
# with source=bench_truth_probe, logs SEAT-WALL-FALSE, and the prom carries
# fleet_seat_bench_lied_total{provider,model} 1 (the FleetSeatBenchLied input).
SEATD24="$TMPD/seats24"
mkdir -p "$SEATD24"
cat > "$TMPD/seat-caps24.json" <<'CAPS'
{
  "providers": {
    "devin": {"cap": 4, "models": {"swe-2-max": 4}}
  }
}
CAPS
cat > "$SEATD24/devin__swe-2-max.json" <<'SEAT'
{"provider":"devin","model":"swe-2-max","http_status":429,"retry_after":null,"health_class":"quota_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"provider_quota_window","failure_mode":"quota_cap","bench_until":"2026-09-05T11:00:00Z","usable_at":"2026-09-05T11:00:00Z","bench_window_s":518400,"consecutive_failure_count":25,"writer":"mark_seat_quota_bench"}
SEAT
cat > "$TMPD/pi-pong-true" <<'STUB'
#!/usr/bin/env bash
printf 'PACKET-VERDICT tools=0 class=no-tools\n' >&2
printf 'PONG\n'
exit 0
STUB
chmod +x "$TMPD/pi-pong-true"
ST24="$TMPD/state24.json"; PROM24="$TMPD/release24.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATD24" SEAT_CAPS_JSON="$TMPD/seat-caps24.json" \
    FLEET_SEAT_COMEBACK_STATE="$ST24" FLEET_SEAT_COMEBACK_PROM="$PROM24" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" PI_BIN="$TMPD/pi-pong-true" \
    bash "$BIN" --false-wall-only >/dev/null 2>"$TMPD/run24.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "24: bench-truth sweep must exit 0, got $rc ($(cat "$TMPD/run24.err"))"
grep -q "SEAT-WALL-FALSE devin/swe-2-max writer=mark_seat_quota_bench" "$TMPD/run24.err" \
  || fail "24: must log SEAT-WALL-FALSE naming the writer: $(cat "$TMPD/run24.err")"
jq -e '.health_class == "healthy" and .source == "bench_truth_probe" and .bench_until == null' "$SEATD24/devin__swe-2-max.json" >/dev/null \
  || fail "24: PONG must clear the bench with source=bench_truth_probe: $(cat "$SEATD24/devin__swe-2-max.json")"
grep -q '^fleet_seat_bench_lied_total{provider="devin",model="swe-2-max"} 1$' "$PROM24" \
  || fail "24: prom must count the bench lie: $(cat "$PROM24")"
[[ "$(jq -r '.bench_lied["devin/swe-2-max"]' "$ST24")" == "1" ]] \
  || fail "24: state must persist the bench-lie counter: $(cat "$ST24")"
ok "24: a benched seat that answers PONG is a bench lie -> cleared (source=bench_truth_probe), SEAT-WALL-FALSE, fleet_seat_bench_lied_total=1 (fleet-ops#5285)"

# --- 25. fleet-ops#5285: dead seat stays benched, no lie counted -----------
SEATD25="$TMPD/seats25"
mkdir -p "$SEATD25"
cat > "$SEATD25/devin__swe-2-max.json" <<'SEAT'
{"provider":"devin","model":"swe-2-max","http_status":429,"retry_after":null,"health_class":"quota_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"provider_quota_window","failure_mode":"quota_cap","bench_until":"2026-09-05T11:00:00Z","usable_at":"2026-09-05T11:00:00Z","bench_window_s":518400,"consecutive_failure_count":25,"writer":"mark_seat_quota_bench"}
SEAT
ST25="$TMPD/state25.json"; PROM25="$TMPD/release25.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATD25" SEAT_CAPS_JSON="$TMPD/seat-caps24.json" \
    FLEET_SEAT_COMEBACK_STATE="$ST25" FLEET_SEAT_COMEBACK_PROM="$PROM25" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" PI_BIN="$TMPD/pi-fail" \
    bash "$BIN" --false-wall-only >/dev/null 2>"$TMPD/run25.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "25: failed truth probe must exit 0 (the system working), got $rc ($(cat "$TMPD/run25.err"))"
jq -e '.health_class == "quota_bench" and .bench_until != null' "$SEATD25/devin__swe-2-max.json" >/dev/null \
  || fail "25: a seat that fails its probe must stay benched: $(cat "$SEATD25/devin__swe-2-max.json")"
grep -q 'fleet_seat_bench_lied_total{' "$PROM25" && fail "25: no lie may be counted for a truthful bench: $(cat "$PROM25")"
grep -q "SEAT-WALL-FALSE" "$TMPD/run25.err" && fail "25: no SEAT-WALL-FALSE on a failed probe: $(cat "$TMPD/run25.err")"
ok "25: a benched seat that fails its PONG stays benched; nothing counted (fleet-ops#5285)"

# --- 26. fleet-ops#5285: a bench written < 15 min ago is not yet a suspect ---
# The truth probe is owed at min(advertised reset, 15 min) AFTER the write.
# Same 6-day bench, observed_at = now: skipped with the bench-age reason even
# though the stub would answer PONG. (This is also what keeps the path unit
# from re-probing a seat on the ledger write its own unwall just made.)
SEATD26="$TMPD/seats26"
mkdir -p "$SEATD26"
cat > "$SEATD26/devin__swe-2-max.json" <<'SEAT'
{"provider":"devin","model":"swe-2-max","http_status":429,"retry_after":null,"health_class":"quota_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T12:00:00Z","source":"provider_quota_window","failure_mode":"quota_cap","bench_until":"2026-09-05T11:00:00Z","usable_at":"2026-09-05T11:00:00Z","bench_window_s":518400,"consecutive_failure_count":25,"writer":"mark_seat_quota_bench"}
SEAT
ST26="$TMPD/state26.json"; PROM26="$TMPD/release26.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATD26" SEAT_CAPS_JSON="$TMPD/seat-caps24.json" \
    FLEET_SEAT_COMEBACK_STATE="$ST26" FLEET_SEAT_COMEBACK_PROM="$PROM26" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" PI_BIN="$TMPD/pi-pong-true" \
    bash "$BIN" --false-wall-only >/dev/null 2>"$TMPD/run26.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "26: fresh-bench sweep must exit 0, got $rc ($(cat "$TMPD/run26.err"))"
grep -qE "PONG probe devin/swe-2-max|SEAT-WALL-FALSE" "$TMPD/run26.err" \
  && fail "26: a bench younger than 15 min must not be probed at all: $(cat "$TMPD/run26.err")"
jq -e '.health_class == "quota_bench"' "$SEATD26/devin__swe-2-max.json" >/dev/null \
  || fail "26: a bench written just now must not be probed/cleared: $(cat "$SEATD26/devin__swe-2-max.json")"
ok "26: a bench younger than 15 min is not probed — the truth probe is owed at min(reset, 15 min) after the write (fleet-ops#5285)"

# --- 27. fleet-ops#5285: a policy bench (daily spend cap) is money — never probed --
# Same live stub as 24; the seat answers PONG, but its bench is a
# daily_spend_cap decision. It must stay benched, no lie counted.
SEATD27="$TMPD/seats27"
mkdir -p "$SEATD27"
cat > "$SEATD27/devin__swe-2-max.json" <<'SEAT'
{"provider":"devin","model":"swe-2-max","http_status":429,"retry_after":null,"health_class":"quota_bench","retryable":true,"seat_dead":false,"poison_ladder":false,"observed_at":"2026-08-30T11:00:00Z","source":"daily_spend_cap","failure_mode":"quota_cap","bench_until":"2026-08-31T00:00:00Z","usable_at":"2026-08-31T00:00:00Z","bench_window_s":43200,"consecutive_failure_count":1,"writer":"provider_daily_budget"}
SEAT
ST27="$TMPD/state27.json"; PROM27="$TMPD/release27.prom"
set +e
PI_SEAT_HEALTH_LEDGER_DIR="$SEATD27" SEAT_CAPS_JSON="$TMPD/seat-caps24.json" \
    FLEET_SEAT_COMEBACK_STATE="$ST27" FLEET_SEAT_COMEBACK_PROM="$PROM27" \
    FLEET_SEAT_COMEBACK_NOW="$NOW_ISO" PI_BIN="$TMPD/pi-pong-true" \
    bash "$BIN" --false-wall-only >/dev/null 2>"$TMPD/run27.err"
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "27: policy-bench sweep must exit 0, got $rc ($(cat "$TMPD/run27.err"))"
jq -e '.health_class == "quota_bench" and .source == "daily_spend_cap" and .bench_until != null' "$SEATD27/devin__swe-2-max.json" >/dev/null \
  || fail "27: a daily_spend_cap bench must never be probed or cleared: $(cat "$SEATD27/devin__swe-2-max.json")"
grep -qE "PONG probe devin/swe-2-max|SEAT-WALL-FALSE" "$TMPD/run27.err" \
  && fail "27: a policy bench must not be PONG-probed at all: $(cat "$TMPD/run27.err")"
ok "27: a policy bench (daily_spend_cap) is money — not probed, not cleared, not counted (fleet-ops#5285)"

echo "ALL OK: active come-back release path (fleet-ops#2421) + force-probe-on-overdue-usable_at + corpse-at-threshold + never-released metric (fleet-ops#2638) + own-streak corpse + interval-breach loud check (fleet-ops#2806) + no-wall corpse second-chance re-probe / explicit retire (fleet-ops#3156) + extension-reclassify race (fleet-ops#3179) + PQE 1h==1h deadlock fix (fleet-ops#3176) + skip-corpse-on-reanchored-wall (fleet-ops#3301) + phantom retirement + real-non-caps-seat re-probe (fleet-ops#3993) + spawn-bench-held 402 skip (fleet-ops#4659) + false-wall PONG release (fleet-ops#4640)"
