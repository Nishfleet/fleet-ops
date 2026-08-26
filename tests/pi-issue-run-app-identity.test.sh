#!/usr/bin/env bash
# tests/pi-issue-run-app-identity.test.sh
#
# fleet-ops#413/#440: the App creds file must exist and mint. A missing file
# or a mint failure must scream (exit 1, no child pi). When mint succeeds, pi
# runs under the minted identity. There is no fallback to the human gh auth.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-issue-run"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t pi-issue-app-id.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
unset WORKER_APP_CREDS_FILE || true

STATE_DIR="$scratch/state"
mkdir -p "$STATE_DIR/attempts" "$STATE_DIR/active-seats"
LEDGER="$scratch/ledger"
mkdir -p "$LEDGER"
ISSUES_DIR="$scratch/issues"
mkdir -p "$ISSUES_DIR"

export PI_PACKET_STATE="$STATE_DIR"
export PI_SEAT_HEALTH_LEDGER_DIR="$LEDGER"
export PI_ISSUES_DIR="$ISSUES_DIR"
export PI_PACKET_SEAT_LIB="$repo_root/lib/seat-lib.sh"

stub_bin="$scratch/stub-bin"
mkdir -p "$stub_bin"
pi_marker="$scratch/pi-ran"

cat >"$stub_bin/pi" <<STUB
#!/usr/bin/env bash
printf 'ran\\n' >"$pi_marker"
printf 'OK https://github.com/Nishfleet/fleet-ops/pull/4130\\n'
exit 0
STUB
chmod +x "$stub_bin/pi"
export PI_BIN="$stub_bin/pi"

cat >"$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/gh"

cat >"$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$stub_bin/systemctl"

export PATH="$stub_bin:/usr/local/bin:/usr/bin:/bin"
export SEAT_CAPS_JSON="$scratch/seat-caps.json"
export PI_MODELS_JSON="$scratch/models.json"

cat >"$SEAT_CAPS_JSON" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "free_providers_in_order": [],
  "providers": {
    "devin": {
      "cap": 4,
      "class": "subscription",
      "models": { "swe-1-7": 4 }
    }
  }
}
JSON
cat >"$PI_MODELS_JSON" <<'JSON'
{
  "providers": {
    "devin": {
      "models": [
        { "id": "swe-1-7", "cost": { "input": 0 }, "reasoning": true, "contextWindow": 200000 }
      ]
    }
  }
}
JSON

echo 'noop' > "$ISSUES_DIR/app-id.in"

# --- 1. creds present + mint fail → scream, pi must not run ---------------
mkdir -p "$HOME/.config/fleet-worker"
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
echo "mint failed" >&2
exit 3
STUB
chmod +x "$stub_bin/worker-token"
export WORKER_TOKEN_BIN="$stub_bin/worker-token"
rm -f "$pi_marker"
set +e
"$bin" app-id >"$scratch/out1" 2>"$scratch/err1"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "creds+mint-fail must be non-zero, got 0: $(cat "$scratch/err1")"
grep -q 'DEAD APP IDENTITY' "$scratch/err1" \
  || fail "creds+mint-fail must scream: $(cat "$scratch/err1")"
[[ ! -f "$pi_marker" ]] || fail "pi must not run after a dead App identity"
ok "creds + mint fail screams and does not run pi"

# --- 2. creds absent → scream, pi must not run -----------------------------
rm -f "$HOME/.config/fleet-worker/nishfleet-worker.env"
rm -f "$pi_marker"
# Fresh instance so tried-seats from case 1 does not exhaust the only seat.
echo 'noop' > "$ISSUES_DIR/app-id-absent.in"
set +e
"$bin" app-id-absent >"$scratch/out2" 2>"$scratch/err2"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "absent creds must be non-zero, got 0: $(cat "$scratch/err2")"
grep -q 'DEAD APP IDENTITY' "$scratch/err2" \
  || fail "absent creds must scream: $(cat "$scratch/err2")"
[[ ! -f "$pi_marker" ]] || fail "pi must not run when creds are absent"
ok "absent creds scream and do not run pi"

# --- 3. creds present + mint success → pi runs ------------------------------
: >"$HOME/.config/fleet-worker/nishfleet-worker.env"
chmod 600 "$HOME/.config/fleet-worker/nishfleet-worker.env"
cat >"$stub_bin/worker-token" <<'STUB'
#!/usr/bin/env bash
printf 'export %s=%s\n' GH_TOKEN fake-test-token-cccccccccccccccc
exit 0
STUB
chmod +x "$stub_bin/worker-token"
rm -f "$pi_marker"
echo 'noop' > "$ISSUES_DIR/app-id-ok.in"
set +e
"$bin" app-id-ok >"$scratch/out3" 2>"$scratch/err3"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "mint success should run pi, got $rc: $(cat "$scratch/err3")"
grep -q 'nishfleet-worker App token' "$scratch/err3" \
  || fail "mint success must log rotation: $(cat "$scratch/err3")"
[[ -f "$pi_marker" ]] || fail "pi must run after a successful mint"
ok "creds + mint success runs pi as the App identity"

echo "OK: pi-issue-run App identity scream/fall-through (fleet-ops#413)"
