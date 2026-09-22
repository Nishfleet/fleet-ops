#!/usr/bin/env bash
# tests/am-executor-claim.test.sh
#
# fleet-ops#6347: two Alertmanager firings for one gauge must collapse into
# one repair. The glue sweep deleted pi-systemd-run transients and
# claim-reconcile; the mutex now lives on the am-executor command itself
# (bin/am-executor-claim). This drill is hermetic: stub systemctl, a
# scratch ALERT_STATE_DIR, no live units, no network.
#
# Drills (the issue's acceptance, mapped onto the inline pi --print path):
#   1. --help exits 0 and names the ceremony.
#   2. Two firings 1s apart with a 5s stub (the 8s/30s production analogue)
#      -> exactly one execution and one claim record while the first is live.
#   3. A firing while a live alert-repair-<Alertname>-* unit is reported
#      -> exit 0 skipped-live-worker, command not run.
#   4. After the stub exits (EXIT trap = the deleted sweep) the next
#      firing runs and writes a new claim.
#   6. fleet-sync links the repo YAML onto the live -f path.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/am-executor-claim"
yaml="$repo_root/config/prometheus-am-executor.yml"
sync_unit="$repo_root/systemd/fleet-sync.service"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$bin" ]] || fail "missing $bin"
chmod +x "$bin"
[[ -f "$yaml" ]] || fail "missing $yaml"

scratch="$(mktemp -d -t am-executor-claim.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

state="$scratch/state"
mkdir -p "$state" "$scratch/bin"
runs="$scratch/runs"
: >"$runs"

# Stub systemctl: prints LIVE_UNITS_FILE contents for list-units, else silence.
cat >"$scratch/bin/systemctl" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    list-units)
      if [ -n "${LIVE_UNITS_FILE:-}" ] && [ -f "$LIVE_UNITS_FILE" ]; then
        cat "$LIVE_UNITS_FILE"
      fi
      exit 0
      ;;
  esac
done
exit 0
EOF
chmod +x "$scratch/bin/systemctl"

payload() {
  local name="${1:-FakeGauge}"
  printf '{"status":"firing","commonLabels":{"alertname":"%s"},"groupLabels":{"alertname":"%s"},"alerts":[{"status":"firing","labels":{"alertname":"%s"}}]}\n' \
    "$name" "$name" "$name"
}

run_claim() {
  env -i \
    HOME="$scratch" \
    PATH="$scratch/bin:/usr/bin:/bin" \
    ALERT_STATE_DIR="$state" \
    SYSTEMCTL="$scratch/bin/systemctl" \
    LIVE_UNITS_FILE="${LIVE_UNITS_FILE:-}" \
    AM_EXECUTOR_CLAIM_UNIT="am-executor-claim-test" \
    "$bin" "$@"
}

# --- 1. --help --------------------------------------------------------------
help_out="$("$bin" --help 2>&1)" || fail "--help must exit 0"
printf '%s\n' "$help_out" | grep -q 'skipped-live-worker' \
  || fail "--help must name skipped-live-worker"
printf '%s\n' "$help_out" | grep -q 'fleet-ops#6347' \
  || fail "--help must cite fleet-ops#6347"
ok "--help exits 0 and names the ceremony"

# --- 2. overlapping firings: one execution, one claim -----------------------
stub="$scratch/bin/stub-repair"
cat >"$stub" <<EOF
#!/bin/sh
printf 'run\n' >>"$runs"
# Hold the flock for long enough that a second firing overlaps.
sleep 5
EOF
chmod +x "$stub"

payload FakeGauge | run_claim "$stub" &
pid1=$!

# Wait until the first claim lands (or the background job dies).
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$state/fake-gauge.json" ]] && break
  kill -0 "$pid1" 2>/dev/null || break
  sleep 0.1
done
[[ -f "$state/fake-gauge.json" ]] || fail "first firing did not write a claim record"

claim1="$(cat "$state/fake-gauge.json")"
echo "$claim1" | jq -e '.alertname=="FakeGauge"' >/dev/null \
  || fail "claim record missing alertname: $claim1"
echo "$claim1" | jq -e '.unit=="am-executor-claim-test"' >/dev/null \
  || fail "claim record missing unit: $claim1"
echo "$claim1" | jq -e '.fired_at' >/dev/null \
  || fail "claim record missing fired_at: $claim1"

sleep 1
set +e
out2="$(payload FakeGauge | run_claim "$stub" 2>&1)"
rc2=$?
set -e
[[ "$rc2" -eq 0 ]] || fail "overlapping firing must exit 0, got $rc2: $out2"
printf '%s\n' "$out2" | grep -q 'skipped-live-worker' \
  || fail "overlapping firing must log skipped-live-worker: $out2"

wait "$pid1" || fail "first stub repair failed"

run_count="$(grep -c '^run$' "$runs" || true)"
[[ "$run_count" -eq 1 ]] || fail "overlapping firings must run the stub once, got $run_count"
# EXIT trap released the claim.
[[ ! -f "$state/fake-gauge.json" ]] || fail "claim file must be released after the worker exits"
ok "two overlapping firings -> one execution, one claim, second skipped-live-worker"

# --- 3. firing while held by the copied systemctl probe ---------------------
: >"$runs"
printf 'alert-repair-HeldGauge-20260919T000000Z.service loaded active running dummy\n' \
  >"$scratch/live-units"
LIVE_UNITS_FILE="$scratch/live-units"
set +e
out3="$(payload HeldGauge | run_claim "$stub" 2>&1)"
rc3=$?
set -e
unset LIVE_UNITS_FILE
[[ "$rc3" -eq 0 ]] || fail "held-unit firing must exit 0, got $rc3: $out3"
printf '%s\n' "$out3" | grep -q 'skipped-live-worker' \
  || fail "held-unit firing must log skipped-live-worker: $out3"
run_count="$(grep -c '^run$' "$runs" || true)"
[[ "$run_count" -eq 0 ]] || fail "held-unit firing must not run the stub, got $run_count"
[[ ! -f "$state/held-gauge.json" ]] || fail "held-unit firing must not write a claim"
ok "firing while alert-repair-<Alertname>-* is live -> exit-0 skipped-live-worker"

# --- 4. after worker exit the next firing spawns ----------------------------
: >"$runs"
payload FakeGauge | run_claim "$stub" || fail "post-exit firing must run"
run_count="$(grep -c '^run$' "$runs" || true)"
[[ "$run_count" -eq 1 ]] || fail "post-exit firing must run the stub once, got $run_count"
ok "after worker exit (EXIT trap = sweep) the next firing spawns"

# --- 4b. production path: AMX_LABEL_alertname, empty stdin ------------------
: >"$runs"
env -i \
  HOME="$scratch" \
  PATH="$scratch/bin:/usr/bin:/bin" \
  ALERT_STATE_DIR="$state" \
  SYSTEMCTL="$scratch/bin/systemctl" \
  AM_EXECUTOR_CLAIM_UNIT="am-executor-claim-test" \
  AMX_LABEL_alertname="EnvGauge" \
  AMX_STATUS="firing" \
  "$bin" "$stub" </dev/null \
  || fail "AMX_LABEL_alertname firing must run"
run_count="$(grep -c '^run$' "$runs" || true)"
[[ "$run_count" -eq 1 ]] || fail "AMX env firing must run the stub once, got $run_count"
ok "AMX_LABEL_alertname (the executor's real dispatch) claims and runs"

# --- 6. fleet-sync links the YAML onto the live -f path ---------------------
grep -q 'config/prometheus-am-executor.yml' "$sync_unit" \
  || fail "fleet-sync.service must link config/prometheus-am-executor.yml"
grep -q 'prometheus-am-executor/config.yml' "$sync_unit" \
  || fail "fleet-sync.service must target ~/.config/prometheus-am-executor/config.yml"
ok "fleet-sync links the repo YAML onto the live -f path"

echo "am-executor-claim: all scenarios passed (fleet-ops#6347)"
