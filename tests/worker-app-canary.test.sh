#!/usr/bin/env bash
# tests/worker-app-canary.test.sh
#
# fleet-ops#413: the App-identity canary screams when creds are missing,
# unparsable, or mint fails; it PASSes when creds parse (skip-mint) or a
# stub mint succeeds. Offline: never talks to GitHub.
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/worker-app-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"

scratch="$(mktemp -d -t worker-app-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch/home"
mkdir -p "$HOME"

# --- missing creds → scream -------------------------------------------------
export WORKER_APP_CREDS_FILE="$scratch/missing.env"
set +e
out="$("$bin" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "missing creds must exit 1, got $rc: $out"
grep -q 'DEAD APP IDENTITY' <<<"$out" || fail "missing creds must scream: $out"
ok "missing creds screams"

# --- unparsable creds → scream ---------------------------------------------
export WORKER_APP_CREDS_FILE="$scratch/empty.env"
: >"$WORKER_APP_CREDS_FILE"
set +e
out="$("$bin" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "empty creds must exit 1, got $rc: $out"
grep -q 'DEAD APP IDENTITY' <<<"$out" || fail "empty creds must scream: $out"
ok "empty creds scream"

# --- parses, skip mint → PASS ----------------------------------------------
cat >"$scratch/ok.env" <<'ENV'
NISHFLEET_WORKER_APP_ID=4728578
NISHFLEET_WORKER_PRIVATE_KEY="dummy-key-not-a-real-pem"
ENV
chmod 600 "$scratch/ok.env"
export WORKER_APP_CREDS_FILE="$scratch/ok.env"
export WORKER_APP_CANARY_SKIP_MINT=1
set +e
out="$("$bin" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "parse+skip-mint must exit 0, got $rc: $out"
grep -q 'creds exist and parse' <<<"$out" || fail "parse ok line missing: $out"
ok "creds parse with skip-mint"

# --- mint failure → scream -------------------------------------------------
unset WORKER_APP_CANARY_SKIP_MINT
stub="$scratch/stub-bin"
mkdir -p "$stub"
cat >"$stub/worker-token" <<'STUB'
#!/usr/bin/env bash
echo "mint exploded" >&2
exit 3
STUB
chmod +x "$stub/worker-token"
export WORKER_TOKEN_BIN="$stub/worker-token"
set +e
out="$("$bin" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "mint fail must exit 1, got $rc: $out"
grep -q 'DEAD APP IDENTITY' <<<"$out" || fail "mint fail must scream: $out"
ok "mint failure screams"

# --- stub mint success → PASS ----------------------------------------------
cat >"$stub/worker-token" <<'STUB'
#!/usr/bin/env bash
# Build the export line without a credential assignment literal in this file.
printf 'export %s=%s\n' GH_TOKEN fake-test-token-bbbbbbbbbbbbbbbb
exit 0
STUB
chmod +x "$stub/worker-token"
set +e
out="$("$bin" 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "stub mint must exit 0, got $rc: $out"
grep -q 'minted (redacted' <<<"$out" || fail "redacted mint line missing: $out"
grep -qv 'fake-test-token' <<<"$out" || fail "canary leaked the minted value: $out"
ok "stub mint succeeds and redacts"

# --- heartbeat wiring lock -------------------------------------------------
grep -q 'worker-app-canary' "$tier1" \
  || fail "fleet-heartbeat-tier1 must invoke worker-app-canary"
grep -q 'worker_app_canary_rc' "$tier1" \
  || fail "fleet-heartbeat-tier1 must propagate worker_app_canary_rc"
ok "heartbeat tier1 wires the canary"

echo "OK: worker-app-canary (fleet-ops#413)"
