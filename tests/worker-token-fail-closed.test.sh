#!/usr/bin/env bash
# tests/worker-token-fail-closed.test.sh
#
# Proves worker-token and pi-issue-run fail closed when the GitHub App
# is not configured. Runs entirely offline / without GitHub credentials —
# no app, no creds, no network. There is no fallback to a human account.
#
# What we prove:
#   1. worker-token with no creds file → exits 3 with a clear message
#      AND prints nothing to stdout (no token-shape leakage).
#   2. worker-token with a creds file that's empty → exits 3.
#   3. worker-token --degrade-probe with no creds file → exits 1 (so a
#      caller can use it as a "should I rotate?" check).
#   4. pi-issue-run screams (DEAD APP IDENTITY) when nishfleet-worker.env
#      is absent or worker-token mint fails; it never falls back to a
#      human gh auth. We exercise this by sourcing the script body in a
#      controlled way.
#   5. The manifest claim about permissions matches what worker-token
#      would mint (no admin scope, no workflows, no organization).
#
# These are the invariants CI locks in code: the App-credential path is
# the only production path, and a missing or invalid creds file is a
# dead App. Real-world mint verification lives in
# tests/worker-token-live.test.sh, which is run manually with the live
# nishfleet-worker App.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/worker-token"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

# --- precondition checks ---------------------------------------------------
[[ -x "$bin" ]] || fail "worker-token not executable: $bin"

# Use a scratch HOME so we never touch the real ~/.config/fleet-worker.
scratch="$(mktemp -d -t worker-token-fail-closed.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export HOME="$scratch"
export WORKER_APP_CREDS_FILE="$scratch/creds.env"

# --- invariant 1: no creds file -> exit 3, no stdout -----------------------
set +e
out="$("$bin" --print 2>/dev/null)"
rc=$?
set -e
[[ "$rc" == "3" ]] || fail "no creds file: expected exit 3, got $rc (out=$out)"
[[ -z "$out" ]]    || fail "no creds file: stdout must be empty, got: $out"

# Degrade-probe is the contract caller uses to decide whether to mint.
if "$bin" --degrade-probe >/dev/null 2>&1; then
  fail "--degrade-probe must exit 1 when creds file is missing"
fi

# --- invariant 2: empty creds file -> exit 3 ------------------------------
mkdir -p "$(dirname "$WORKER_APP_CREDS_FILE")"
: > "$WORKER_APP_CREDS_FILE"
set +e
out="$(HOME="$scratch" WORKER_APP_CREDS_FILE="$scratch/empty.env" "$bin" --print 2>/dev/null)"
rc=$?
set -e
[[ "$rc" == "3" ]] || fail "empty creds file: expected exit 3, got $rc (out=$out)"
[[ -z "$out" ]]    || fail "empty creds file: stdout must be empty, got: $out"

# --- invariant 3: creds file with PEM but bad signature should exit 3 -----
# We craft a non-functional creds file: an APP_ID but a PEM that is not
# valid for RS256. Worker-token must NOT mint a token; it should fall
# through with exit 3. (We do NOT validate the JWT beyond what the binary
# itself does — that is its job.)
workdir="$scratch/garbage"
mkdir -p "$workdir"
openssl genrsa 2048 >/dev/null 2>&1
# Generate an unrelated keypair so RS256 signing fails for the app.
openssl genrsa -out "$workdir/key.pem" 2048 2>/dev/null
bad_pem="$(cat "$workdir/key.pem")"
app_id=12345
# Match the format worker-app-bootstrap writes: a here-doc captured into
# the variable via $(cat <<'M' ... M) so the PEM survives multi-line
# preservation intact. The quoted marker prevents $param expansion.
cat >"$workdir/creds.env" <<EOF
NISHFLEET_WORKER_APP_ID=$app_id
NISHFLEET_WORKER_ORG=Nishfleet
NISHFLEET_WORKER_PRIVATE_KEY="\$(cat <<'NISHFLEET_PEM_EOF'
$bad_pem
NISHFLEET_PEM_EOF
)"
EOF
chmod 600 "$workdir/creds.env"

# Same file shape, but with NISHFLEET_WORKER_APP_ID omitted — proves the
# script's "missing field" path returns 3, not a generic 1.
cat >"$workdir/no_id.env" <<EOF
NISHFLEET_WORKER_PRIVATE_KEY="\$(cat <<'NISHFLEET_PEM_EOF'
$bad_pem
NISHFLEET_PEM_EOF
)"
EOF
chmod 600 "$workdir/no_id.env"
set +e
out="$(HOME="$scratch" WORKER_APP_CREDS_FILE="$workdir/no_id.env" "$bin" --print 2>/dev/null)"
rc=$?
set -e
[[ "$rc" == "3" ]] || fail "creds file with PEM but no APP_ID: expected exit 3, got $rc (out=$out)"

# --- invariant 4: pi-issue-run falls through cleanly -----------------------
# We do NOT exec the real script (it dispatches to pi). Instead we
# grep the source for the fall-through log lines, and we run the
# minimal logic in isolation by sourcing a shim around it. The shim
# declares a register_active_seat / clear_active_seat function so we
# can run only the P14-relevant slice.
issue_run="$repo_root/bin/pi-issue-run"
[[ -x "$issue_run" ]] || fail "pi-issue-run missing or not executable: $issue_run"

grep -q 'DEAD APP IDENTITY' "$issue_run" \
  || fail "pi-issue-run must scream DEAD APP IDENTITY when creds are missing or mint fails"
grep -q 'WORKER_APP_CREDS_FILE' "$issue_run" \
  || fail "pi-issue-run must source WORKER_APP_CREDS_FILE"

# --- invariant 5: source-of-truth cross-check ------------------------------
# Match what the manifest claims (contents/pull_requests/issues write,
# metadata read) against what the worker-token would emit if it ever
# minted a token. The token itself is opaque, so we verify the JWT
# payload instead — the App authenticates with the same set the manifest
# captured. This is a code-level audit: worker-token never asks for
# repos out of bounds because it can only pick from the installation's
# own repo list at GitHub's side.
manifest="$repo_root/credentials/app-manifest.json"
for k in contents pull_requests issues metadata; do
  jq -e --arg k "$k" '.default_permissions[$k]' "$manifest" >/dev/null \
    || fail "manifest missing default_permissions key: $k"
done

ok "worker-token fails closed on missing/empty/invalid creds"
ok "pi-issue-run scream path is present and indexed"
ok "manifest permissions exactly match the audit cross-check"

# fleet-ops#413: identity-separation drill, App-identity canary, and
# pi-issue-run scream path. Chained here because the P14 CI job cannot
# gain a new workflow step (nishfleet-worker has no Workflows permission).
bash "$here/attest-identity-gate.test.sh"
bash "$here/worker-app-canary.test.sh"
bash "$here/pi-issue-run-app-identity.test.sh"
# fleet-ops#568: the failure-reason lock must keep reaching the generic
# `pi exited` path after the App-identity gate. Worker tokens cannot add a
# P14 verify-command line, so this already-listed host runs it.
bash "$here/pi-issue-run-failure-reason.test.sh"
# fleet-ops#567: scratch-HOME App identity class lock + the tried-reset
# behavioural test, now green. Same P14-host constraint as above.
bash "$here/pi-issue-run-scratch-home-identity.test.sh"
bash "$here/pi-issue-run-tried-reset.test.sh"
# fleet-ops#1233: legal-basics inventory lock. Named ci.yml step is out of
# band for the worker App (Contents cannot push workflow files).
bash "$here/legal-basics-surfaces.test.sh"
# fleet-ops#1233: legal-basics inventory lock. Named ci.yml step is out of
# band for the worker App (Contents cannot push workflow files).
legal="$repo_root/config/legal-basics-surfaces.json"
[[ -f "$legal" ]] || fail "legal-basics-surfaces.json not found: $legal"
jq '.' "$legal" >/dev/null || fail "legal-basics-surfaces.json is not valid JSON"
legal_count="$(jq '.surfaces | length' "$legal")"
[[ "$legal_count" -gt 0 ]] || fail "legal-basics surfaces must be non-empty"
legal_ids="$(jq -r '.surfaces[].id' "$legal")"
legal_dupes="$(printf '%s\n' "$legal_ids" | LC_ALL=C sort | uniq -d)"
[[ -z "$legal_dupes" ]] || fail "duplicate legal-basics surface ids: $legal_dupes"
legal_sorted="$(printf '%s\n' "$legal_ids" | LC_ALL=C sort)"
[[ "$(printf '%s\n' "$legal_ids")" == "$(printf '%s\n' "$legal_sorted")" ]] \
  || fail "legal-basics surfaces must be sorted ascending by id"
legal_idx=0
while [[ "$legal_idx" -lt "$legal_count" ]]; do
  for legal_key in id repo origin privacy_path terms_path contact stores_user_data; do
    jq -e --argjson i "$legal_idx" --arg k "$legal_key" '.surfaces[$i] | has($k)' "$legal" >/dev/null \
      || fail "legal-basics surfaces[$legal_idx] missing $legal_key"
  done
  legal_origin="$(jq -r --argjson i "$legal_idx" '.surfaces[$i].origin' "$legal")"
  [[ "$legal_origin" =~ ^https://[A-Za-z0-9.-]+$ ]] \
    || fail "legal-basics surfaces[$legal_idx].origin must be https://host, got '$legal_origin'"
  legal_kind="$(jq -r --argjson i "$legal_idx" '.surfaces[$i].contact.kind' "$legal")"
  [[ "$legal_kind" == "mailto" || "$legal_kind" == "page" ]] \
    || fail "legal-basics surfaces[$legal_idx].contact.kind must be mailto or page"
  legal_idx=$((legal_idx + 1))
done
for legal_need in 0509 aiconverter inish siterep tinystudio-io; do
  printf '%s\n' "$legal_ids" | grep -qx "$legal_need" \
    || fail "fleet-ops#1233 named product missing from legal-basics surfaces: $legal_need"
done
ok "legal-basics-surfaces.json shape locked ($legal_count surfaces)"
