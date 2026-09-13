#!/usr/bin/env bash
# tests/pi-issue-run-empty-success.test.sh
#
# fleet-ops#4457: a run that ends SUCCESS (real output, exit 0) but opens NO
# PR and does NOT close the issue is an EMPTY-SUCCESS — a wasted claim. The
# blind spot measured 51% of sessions logging "SUCCESS" while shipping
# nothing. Every such session must be classed `empty-success`:
#   (1) a `PACKET-VERDICT class=empty-success seat=<prov>/<model> output_bytes=<n>`
#       line is appended to the .out packet (so the accept criterion and the
#       judge's measure.sh can grep `class=empty-success`);
#   (2) a per-seat empty-success counter is written to the seat ledger
#       (*.empty-success.json) so the top offender seats can be named.
# It is NOT benched (the seat produced real text — not a seat fault) and the
# exit code stays 0 (a real-output success). Control: a run that DID ship a PR
# is a real success — no empty-success class, no counter increment.
#
# Runs entirely offline: stubbed models.json, seat-caps.json, ledger dir, a
# fake pi and gh, and PI_ISSUES_DIR redirected into scratch.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-issue-empty-success.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"

# P14: the worker App creds file must exist and mint before pi runs.
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"

STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
ISSUES_DIR="$scratch/issues"
mkdir -p "$ISSUES_DIR"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"

export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_SEAT_HEALTH_SIDECAR="$scratch/pi-seat-health.json"
export PI_ISSUES_DIR="$ISSUES_DIR"
export PI_MODELS_JSON="$scratch/models.json"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export XDG_RUNTIME_DIR="$scratch/xdg"
export PI_SEAT_LIB_CHECK_SYSTEMD=0
mkdir -p "$XDG_RUNTIME_DIR"

stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"

# Fake pi: real output, exit 0 — a genuine success that produced text but (per
# the gh stub below) shipped no PR. This is the empty-success fixture.
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
printf 'Real output: I looked at the issue but did not open a PR.\n'
exit 0
STUB
chmod +x "$stub_bin/pi"

cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
# Default: no open PR, issue open -> empty-success. Set GH_SHIP=1 to simulate
# a shipped PR.
if [[ "${GH_SHIP:-0}" == "1" ]]; then
    if [[ "$*" == *"--jq"* ]]; then
        printf 'open\n'
        exit 0
    fi
    printf '[{"number":42,"state":"open"}]\n'
    exit 0
fi
if [[ "$*" == *"--jq"* ]]; then
    printf 'open\n'
    exit 0
fi
printf '[]\n'
exit 0
STUB
chmod +x "$stub_bin/gh"

cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
printf 'export GH_TOKEN=fake-test-token-cccccccccccccccc\n'
exit 0
STUB
chmod +x "$stub_bin/worker-token"
export WORKER_TOKEN_BIN="$stub_bin/worker-token"

cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" list-units "* ]]; then
  for i in 1 2 3 4; do
    printf 'pi-issue@poison-glm-5-2-%s.service loaded active running poison\n' "$i"
    printf 'pi-issue@poison-swe-1-7-%s.service loaded active running poison\n' "$i"
  done
  exit 0
fi
if [[ "$args" == *" show "* ]] && [[ "$args" == *"ExecStart"* ]]; then
  if [[ "$args" == *"glm-5-2"* ]]; then
    printf '/home/nish/.local/bin/pi --print --provider devin --model glm-5-2\n'
  else
    printf '/home/nish/.local/bin/pi --print --provider devin --model swe-1-7\n'
  fi
  exit 0
fi
exit 0
STUB
chmod +x "$stub_bin/systemctl"

export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"
export PI_BIN="$stub_bin/pi"

cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "glm-5-2", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 },
        { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "providers": {
    "devin": { "cap": 4, "class": "subscription", "remote_agent": true, "models": { "glm-5-2": 4, "swe-1-7": 4 } }
  }
}
JSON

export PI_PACKET_SEAT_LIB="$repo_root/lib/litellm-seat.sh"
export EMPTY_RUN_RETRY_MAX=0

# =============================================================================
# (a) SUCCESS + real output + no PR, issue open -> empty-success class.
# =============================================================================
inst="fleet-ops-4457"
printf 'Implement one GitHub issue: fleet-ops#4457.\nTARGET: repo Nishfleet/fleet-ops issue 4457 unit pi-issue-fleet-ops-4457\n' >"$ISSUES_DIR/${inst}.in"

set +e
bash "$bin" "$inst" >"$scratch/run.out" 2>"$scratch/run.err"
rc=$?
set -e

[[ "$rc" == "0" ]] \
  || fail "empty-success is a real-output SUCCESS — must exit 0 (not benched, not a failing claim), got rc=$rc err=$(cat "$scratch/run.err")"

# (1) the .out packet carries the class=empty-success PACKET-VERDICT line with
#     seat and output bytes.
out=$(cat "$PI_ISSUES_DIR/${inst}.out" 2>/dev/null || true)
echo "$out" | grep -qF 'PACKET-VERDICT class=empty-success' \
  || fail "output must carry a PACKET-VERDICT class=empty-success line, got: $out"
echo "$out" | grep -qF 'class=empty-success seat=litellm/' \
  || fail "empty-success line must name the seat, got: $out"
echo "$out" | grep -qE 'class=empty-success seat=litellm/[0-9A-Za-z.-]+ output_bytes=[0-9]+' \
  || fail "empty-success line must carry output_bytes, got: $out"
ok "empty-success: PACKET-VERDICT class=empty-success seat=<np>/<nm> output_bytes=<n> appended to .out"

# (2) retired (fleet-ops#4263): the per-seat empty-success counter lived in the
# deleted routing library's seat ledger; the verdict line above is the record.

# The run must NOT be benched (no empty_run ledger, no spawn-fail ledger).
no_bench_ledger() {
    local f
    for f in "$LEDGER"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *.empty-success.json ]] && continue
        return 1
    done
    return 0
}
no_bench_ledger || fail "empty-success must NOT create a bench ledger; got: $(ls "$LEDGER")"
ok "empty-success is not benched (no empty_run/spawn-fail ledger) — seat produced real text"

# reclaim-count is NOT reset (claim-loop cap stays tall, fleet-ops#2462/#2772).
rc_file="$STATE_DIR/attempts/pi-issue-${inst}.reclaim-count"
[[ -f "$rc_file" ]] || fail "reclaim-count must NOT be reset on empty-success (claim-loop cap stays tall)"
ok "reclaim-count NOT reset (claim-loop cap stays tall)"

# =============================================================================
# (b) control: SUCCESS + real output + a PR WAS shipped -> real success, NO
#     empty-success class, counter unchanged.
# =============================================================================
printf 'Implement one GitHub issue: fleet-ops#9999.\nTARGET: repo Nishfleet/fleet-ops issue 9999 unit pi-issue-fleet-ops-9999\n' >"$ISSUES_DIR/fleet-ops-9999.in"
GH_SHIP=1 bash "$bin" "fleet-ops-9999" >"$scratch/run-ship.out" 2>"$scratch/run-ship.err" || {
    cat "$scratch/run-ship.err"; fail "shipped success must exit 0";
}
out_ship=$(cat "$PI_ISSUES_DIR/fleet-ops-9999.out" 2>/dev/null || true)
echo "$out_ship" | grep -qF 'Real output' \
  || fail "shipped run output missing, got: $out_ship"
if echo "$out_ship" | grep -qF 'class=empty-success'; then
    fail "a run that shipped a PR must NOT be classed empty-success, got: $out_ship"
fi
ok "shipped success (control): NOT classed empty-success"

# =============================================================================
# (c) retired with the seat ledger (fleet-ops#4263).

# =============================================================================
# (d) fleet-ops#4690: "error connecting to localhost" is the sandbox-
#     localhost class, not empty-success and not a 900s empty-run bench.
# =============================================================================
cat >"$stub_bin/pi" <<'STUB'
#!/usr/bin/env bash
printf 'gh failed: error connecting to localhost (proxy at localhost:3128)\n'
exit 0
STUB
chmod +x "$stub_bin/pi"
printf 'Implement one GitHub issue: fleet-ops#4690.\nTARGET: repo Nishfleet/fleet-ops issue 4690 unit pi-issue-fleet-ops-4690\n' >"$ISSUES_DIR/fleet-ops-4690.in"
: >"$STATE_DIR/attempts/pi-issue-fleet-ops-4690.tried-seats" 2>/dev/null || true
set +e
bash "$bin" "fleet-ops-4690" >"$scratch/run-4690.out" 2>"$scratch/run-4690.err"
rc4690=$?
set -e
[[ "$rc4690" == "1" ]] \
  || fail "sandbox-localhost signature must fail the claim (exit 1), got rc=$rc4690 err=$(cat "$scratch/run-4690.err")"
out4690=$(cat "$PI_ISSUES_DIR/fleet-ops-4690.out" 2>/dev/null || true)
if echo "$out4690" | grep -qF 'class=empty-success'; then
    fail "sandbox-localhost must NOT be classed empty-success, got: $out4690"
fi
grep -q 'sandbox-localhost-unresolvable' "$scratch/run-4690.err" \
  || fail "stderr must name class=sandbox-localhost-unresolvable, got: $(cat "$scratch/run-4690.err")"
if ls "$LEDGER"/*.spawn-bench.json >/dev/null 2>&1; then
    fail "sandbox-localhost must NOT write a 900s empty-run spawn-bench; got: $(ls "$LEDGER")"
fi
ok "sandbox-localhost signature is class=sandbox-localhost-unresolvable, not empty-success, not 900s empty-run"

ok "fleet-ops#4457: SUCCESS-no-PR is classed empty-success (verdict line), not benched, shipped control stays clean"
