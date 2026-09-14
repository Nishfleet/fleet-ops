#!/usr/bin/env bash
# tests/pi-issue-run-no-deployments-class.test.sh
#
# fleet-ops#6781: LiteLLM proxy 429 {"message":"No deployments available for
# selected model, Try again in 300 seconds. Passed model=<group>"} means the
# model group has ZERO healthy upstream deployments. Before the fix it booked
# error_class=unknown -> a 300s spawn bench at best, and the claim re-ran on
# the StartLimitBurst restart loop (0509-2952 twice inside one hour;
# fleet-ops#6731 re-died on the same wall minutes after the judge cleared its
# reclaim). This test pins:
#
#   1. is_no_deployments_error matches the literal (with and without the 429
#      prefix), and rejects empty / bare-429 / unrelated provider errors.
#   2. classify_death_error classes the literal as quota_no_deployments, and
#      the ladder still classes a quota wall as quota_cap first.
#   3. mark_seat_no_deployments_bench writes a real ledger entry
#      (health_class=quota_bench, failure_mode=quota_no_deployments,
#      http_status=429, source=provider_quota_window) with usable_at on the
#      advertised retry window (300s floor) plus the clobber-proof
#      spawn-bench marker, and seat_usable then refuses the seat.
#   4. Replay: a 0-tool fast death on the literal exits the runner 0 (infra
#      re-queue via intake — never the Restart= loop), writes
#      error_class=quota_no_deployments on the synthetic PACKET-VERDICT, and
#      leaves last-death-class=infra so the WORK reclaim cap is untouched.
#
# Runs entirely offline: stubbed pi/gh/systemctl/worker-token, scratch
# seat-caps.json, scratch ledger dir, no systemd.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"
lib="$repo_root/lib/litellm-seat.sh"
[[ -f "$lib" ]] || { echo "FAIL: litellm-seat.sh not found: $lib" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }
command -v jq >/dev/null || fail "jq required"

LIVE_LITERAL='429: {"message":"No deployments available for selected model, Try again in 300 seconds. Passed model=worker-cheap.","type":"None","param":"None","code":"429"}'

# ============================================================================
# 1-3. Matcher / classifier / writer — offline against the sourced library
# ============================================================================
scratch="$(mktemp -d -t no-deployments.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

cat >"$scratch/seat-caps.json" <<'JSON'
{
  "free_providers_in_order": ["commandcode"],
  "providers": {
    "litellm": {
      "cap": 4, "class": "proxy",
      "models": {"worker-cheap": 4, "worker-capable": 4, "worker-private": 4, "senior": 2, "judge": 1}
    },
    "devin": {
      "cap": 4, "class": "subscription",
      "quota_bench_default_s": 900,
      "models": {"glm-5-2": 4, "swe-2-max": 4}
    },
    "commandcode": {
      "cap": 1, "class": "free",
      "models": {"laguna-s-2.1-free": 1}
    }
  }
}
JSON
export SEAT_CAPS_JSON="$scratch/seat-caps.json"

cat >"$scratch/models.json" <<'JSON'
{
  "providers": {
    "litellm": { "models": [
      { "id": "worker-cheap", "cost": { "input": 0 }, "contextWindow": 200000 },
      { "id": "worker-capable", "cost": { "input": 0 }, "contextWindow": 200000 },
      { "id": "worker-private", "cost": { "input": 0 }, "contextWindow": 200000 },
      { "id": "senior", "cost": { "input": 0 }, "contextWindow": 200000 },
      { "id": "judge", "cost": { "input": 0 }, "contextWindow": 200000 }
    ]},
    "devin": { "models": [
      { "id": "glm-5-2", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 },
      { "id": "swe-2-max", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
    ]},
    "commandcode": { "models": [
      { "id": "laguna-s-2.1-free", "cost": { "input": 0 }, "contextWindow": 200000 }
    ]}
  }
}
JSON
export PI_MODELS_JSON="$scratch/models.json"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
export SEAT_LIVE_QUOTA_PROM="$scratch/no-live-quota.prom"

LEDGER="$scratch/ledger"; mkdir -p "$LEDGER"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_PACKET_STATE="$scratch/state"
export XDG_RUNTIME_DIR="$scratch/xdg"
mkdir -p "$XDG_RUNTIME_DIR" "$PI_PACKET_STATE"

# --- 1. is_no_deployments_error ---------------------------------------------
# 1a. The live literal (429 prefix + JSON body) on stderr.
set +e
bash -c 'source "$0"; load_seat_caps; is_no_deployments_error "$1" "$2"' \
    "$lib" "" "$LIVE_LITERAL" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_no_deployments_error must match the live 429 literal (rc=$rc)"
ok "is_no_deployments_error: matches live 429 literal"

# 1b. The literal without the 429 prefix, on stdout.
set +e
bash -c 'source "$0"; load_seat_caps; is_no_deployments_error "$1" "$2"' \
    "$lib" 'No deployments available for selected model, Try again in 300 seconds.' "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "is_no_deployments_error must match the literal without the 429 prefix (rc=$rc)"
ok "is_no_deployments_error: matches literal without 429 prefix"

# 1c. Rejects a bare 429 rate limit.
set +e
bash -c 'source "$0"; load_seat_caps; is_no_deployments_error "$1" "$2"' \
    "$lib" "429 Too Many Requests" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "is_no_deployments_error must NOT match a bare 429 (rc=$rc)"
ok "is_no_deployments_error: rejects bare 429"

# 1d. Rejects an unrelated provider error and empty input.
set +e
bash -c 'source "$0"; load_seat_caps; is_no_deployments_error "$1" "$2"' \
    "$lib" "" "provider transport error: upstream connection reset by peer" >/dev/null 2>&1
rc=$?
[[ "$rc" == "1" ]] || fail "is_no_deployments_error must NOT match an unrelated provider error (rc=$rc)"
bash -c 'source "$0"; load_seat_caps; is_no_deployments_error "$1" "$2"' \
    "$lib" "" "" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "is_no_deployments_error must NOT match empty input (rc=$rc)"
ok "is_no_deployments_error: rejects unrelated error + empty input"

# --- 2. classify_death_error -------------------------------------------------
out_file="$scratch/death-out.txt"; err_file="$scratch/death-err.txt"
printf '%s\n' "$LIVE_LITERAL" >"$err_file"; : >"$out_file"
set +e
dec_out=$(bash -c 'source "$0"; load_seat_caps; classify_death_error "$1" "$2" "$3"' \
    "$lib" "$out_file" "$err_file" "" 2>/dev/null)
set -e
dec_cls=$(printf '%s\n' "$dec_out" | sed -n '1p')
[[ "$dec_cls" == "quota_no_deployments" ]] \
    || fail "classify_death_error must classify the no-deployments 429 as quota_no_deployments, got '$dec_cls'"
ok "classify_death_error: no-deployments 429 -> quota_no_deployments (not unknown)"

# 2b. Ordering: a real quota wall still classes quota_cap (the new branch
# must not shadow it).
printf 'Error: 402 Payment Required: You have exhausted your budget. Please add funds\n' >"$err_file"; : >"$out_file"
set +e
dec_out=$(bash -c 'source "$0"; load_seat_caps; classify_death_error "$1" "$2" "$3"' \
    "$lib" "$out_file" "$err_file" "" 2>/dev/null)
set -e
dec_cls=$(printf '%s\n' "$dec_out" | sed -n '1p')
[[ "$dec_cls" == "quota_cap" ]] \
    || fail "classify_death_error must still classify the 402 budget literal as quota_cap, got '$dec_cls'"
ok "classify_death_error: 402 budget literal still -> quota_cap"

# --- 3. mark_seat_no_deployments_bench ---------------------------------------
now_epoch=$(date -u +%s)
set +e
bash -c 'source "$0"; load_seat_caps; mark_seat_no_deployments_bench "$1" "$2" "$3"' \
    "$lib" "litellm" "worker-cheap" "$LIVE_LITERAL" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "mark_seat_no_deployments_bench must return 0 on success (rc=$rc)"
ok "mark_seat_no_deployments_bench: returns 0 for litellm/worker-cheap"

ledger_path="$LEDGER/litellm__worker-cheap.json"
[[ -f "$ledger_path" ]] || fail "ledger entry not written: $ledger_path"
hc=$(jq -r '.health_class // ""' "$ledger_path" 2>/dev/null || echo "")
[[ "$hc" == "quota_bench" ]] || fail "ledger health_class must be quota_bench, got '$hc'"
fm=$(jq -r '.failure_mode // ""' "$ledger_path" 2>/dev/null || echo "")
[[ "$fm" == "quota_no_deployments" ]] || fail "ledger failure_mode must be quota_no_deployments, got '$fm'"
hs=$(jq -r '.http_status // ""' "$ledger_path" 2>/dev/null || echo "")
[[ "$hs" == "429" ]] || fail "ledger http_status must be 429 (honest status, not the 402 money wall), got '$hs'"
src=$(jq -r '.source // ""' "$ledger_path" 2>/dev/null || echo "")
[[ "$src" == "provider_quota_window" ]] || fail "ledger source must be provider_quota_window (not money_boundary), got '$src'"
ok "mark_seat_no_deployments_bench: ledger health_class=quota_bench failure_mode=quota_no_deployments http=429 source=provider_quota_window"

# 3b. usable_at honours the advertised 300s retry window.
usable_at=$(jq -r '.usable_at // ""' "$ledger_path" 2>/dev/null || echo "")
[[ -n "$usable_at" ]] || fail "ledger usable_at is empty"
ua_epoch=$(date -u -d "$usable_at" +%s 2>/dev/null || echo 0)
[[ "$ua_epoch" =~ ^[0-9]+$ ]] || fail "ledger usable_at is not a valid timestamp: $usable_at"
diff=$(( ua_epoch - now_epoch ))
(( diff > 240 && diff < 360 )) || fail "advertised 'Try again in 300 seconds' should bench ~300s, got ${diff}s"
ok "mark_seat_no_deployments_bench: usable_at=$usable_at (~300s advertised window, diff=${diff}s)"

# 3c. Clobber-proof spawn-bench marker written too.
marker_path="$LEDGER/litellm__worker-cheap.spawn-bench.json"
[[ -f "$marker_path" ]] || fail "spawn-bench marker not written: $marker_path"
m_mode=$(jq -r '.failure_mode // ""' "$marker_path" 2>/dev/null || echo "")
[[ "$m_mode" == "quota_no_deployments" ]] || fail "marker failure_mode must be quota_no_deployments, got '$m_mode'"
ok "mark_seat_no_deployments_bench: clobber-proof spawn-bench marker written (failure_mode=quota_no_deployments)"

# 3d. seat_usable refuses the benched seat.
set +e
bash -c 'source "$0"; load_seat_caps; _SEAT_USABLE_SILENT=1 seat_usable "$1" "$2"' \
    "$lib" "litellm" "worker-cheap" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "seat_usable must return 1 (unusable) for the no-deployments-benched seat (rc=$rc)"
ok "seat_usable: refuses litellm/worker-cheap while benched"

# 3e. A larger advertised window wins over the floor ("Try again in 900
# seconds" -> ~900s bench on a different seat).
now_epoch=$(date -u +%s)
set +e
bash -c 'source "$0"; load_seat_caps; mark_seat_no_deployments_bench "$1" "$2" "$3"' \
    "$lib" "litellm" "worker-capable" 'No deployments available for selected model, Try again in 900 seconds. Passed model=worker-capable.' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "mark_seat_no_deployments_bench (900s window) must return 0 (rc=$rc)"
ua2=$(jq -r '.usable_at // ""' "$LEDGER/litellm__worker-capable.json" 2>/dev/null || echo "")
ua2_epoch=$(date -u -d "$ua2" +%s 2>/dev/null || echo 0)
diff=$(( ua2_epoch - now_epoch ))
(( diff > 840 && diff < 960 )) || fail "advertised 'Try again in 900 seconds' should bench ~900s, got ${diff}s"
ok "mark_seat_no_deployments_bench: advertised 900s window honoured (diff=${diff}s)"

# ============================================================================
# 4. Replay: 0-tool fast death on the literal -> infra re-queue (exit 0),
#    error_class=quota_no_deployments, last-death-class=infra, seat benched.
# ============================================================================
export HOME="$scratch/home"; mkdir -p "$HOME/.config/fleet-worker"; : >"$HOME/.config/fleet-worker/nishfleet-worker.env"; chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
STATE_DIR="$scratch/state"; mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
ISSUES_DIR="$scratch/issues"; mkdir -p "$ISSUES_DIR"
export PI_ISSUES_DIR="$ISSUES_DIR" FLEET_DEBUG_PLAYBOOK_GATE=0 EMPTY_RUN_RETRY_MAX=0 SPAWN_FAIL_MAX_S=1 PI_HANG_TIMEOUT_S=60 PI_HANG_BENCH_MIN_S=1
stub_bin="$scratch/stub-bin"; mkdir -p "$stub_bin"
printf 'exit 0\n' >"$stub_bin/gh"; chmod +x "$stub_bin/gh"
printf 'printf "export GH_TOKEN=fake-test-token-cccccccccccccccc\\n"\nexit 0\n' >"$stub_bin/worker-token"; chmod +x "$stub_bin/worker-token"; export WORKER_TOKEN_BIN="$stub_bin/worker-token"
printf 'exit 0\n' >"$stub_bin/systemctl"; chmod +x "$stub_bin/systemctl"
export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"
export PI_PACKET_SEAT_LIB="$lib"
export FLEET_DEBUG_PLAYBOOK_SESSION_DIR="$scratch/sessions"; mkdir -p "$FLEET_DEBUG_PLAYBOOK_SESSION_DIR"

# Clean slate: sections 3x benched litellm/worker-cheap + worker-capable. The
# replay must be the ONLY writer under test, and a pre-benched worker-cheap
# would also change which seat the pick lands on.
rm -f "$LEDGER"/*.json

inst="fleet-ops-6781a"
printf 'Implement one GitHub issue: fleet-ops#6781 replay.\n' >"$ISSUES_DIR/${inst}.in"
cat >"$stub_bin/pi" <<STUB
#!/usr/bin/env bash
sd=""; while [[ \$# -gt 0 ]]; do case "\$1" in --session-dir) sd="\$2"; shift 2;; *) shift;; esac; done
mkdir -p "\$sd"; printf '%s\n' '{"type":"session","version":3,"id":"x","timestamp":"2026-09-14T00:00:00.000Z","cwd":"/tmp"}' >"\$sd/2026-09-14T00-00-00-000Z_nd.jsonl"
echo '$LIVE_LITERAL' >&2
exit 1
STUB
chmod +x "$stub_bin/pi"; export PI_BIN="$stub_bin/pi"
set +e; bash "$bin" "$inst" >"$scratch/run.out" 2>"$scratch/run.err"; rcR=$?; set -e

# The infra re-queue exit is 0 — the claim goes back through intake with a
# fresh pick, never a Restart=on-failure burn on the same dead group.
[[ "$rcR" == "0" ]] || fail "runner must exit 0 (infra re-queue) on a no-deployments 429, got $rcR: $(tail -5 "$scratch/run.err")"
ok "replay: runner exits 0 (infra re-queue, no StartLimitBurst burn)"

grep -qE 'PACKET-VERDICT[[:space:]]+tools=0[[:space:]]+class=no-tools[[:space:]]+error_class=quota_no_deployments' "$ISSUES_DIR/${inst}.out" \
  || fail "synthetic verdict line must carry error_class=quota_no_deployments: $(cat "$ISSUES_DIR/${inst}.out")"
grep -q 'No deployments available for selected model' "$ISSUES_DIR/${inst}.out" \
  || fail "verdict line must carry the literal error tail: $(cat "$ISSUES_DIR/${inst}.out")"
ok "replay: synthetic PACKET-VERDICT carries error_class=quota_no_deployments + literal"

ldc=$(cat "$STATE_DIR/attempts/pi-issue-${inst}.last-death-class" 2>/dev/null || echo "")
[[ "$ldc" == "infra" ]] || fail "last-death-class must be infra (never the WORK reclaim cap), got '$ldc'"
ok "replay: last-death-class=infra (reclaim-count untouched)"

# The picked seat (litellm group via a live proxy, or the direct fallback on
# a proxy-less host) must carry the quota_no_deployments bench in its ledger
# entry. Read fields with jq — _seat_merge_error_class rewrites the file
# pretty-printed, so a raw grep for '"failure_mode":"..."' misses. The
# .spawn-bench.json marker shares the failure_mode string; the ledger entry
# is the .json WITHOUT the .spawn-bench suffix.
bench_file=""
for f in "$LEDGER"/*.json; do
    [[ -f "$f" ]] || continue
    [[ "$f" == *.spawn-bench.json ]] && continue
    [[ "$(jq -r '.failure_mode // ""' "$f" 2>/dev/null)" == "quota_no_deployments" ]] && bench_file="$f" && break
done
[[ -n "$bench_file" ]] || fail "no seat ledger carries failure_mode=quota_no_deployments: $(ls "$LEDGER" 2>/dev/null)"
[[ "$(jq -r '.health_class // ""' "$bench_file" 2>/dev/null)" == "quota_bench" ]] \
    || fail "benched ledger health_class must be quota_bench: $(cat "$bench_file")"
ok "replay: picked seat benched ($(basename "$bench_file"), health_class=quota_bench)"
grep -q 'NO-DEPLOYMENTS 429' "$scratch/run.err" \
  || fail "seat log must carry the NO-DEPLOYMENTS 429 classification line: $(tail -10 "$scratch/run.err")"
ok "replay: seat log carries the NO-DEPLOYMENTS 429 classification line"

echo
echo "PASS: pi-issue-run-no-deployments-class"
