#!/usr/bin/env bash
# tests/packet-direction-live-metric.test.sh
#
# fleet-ops#5699: the 0509 scout packet Direction block gains a live
# production-D1 metric line (signups_24h / signups_30d / last_signup) read
# at packet assembly, replace-or-UNAVAILABLE per field — never a fabricated
# 0, never a silent drop. Hermetic: the curl/jq seams are stubbed so the
# test runs green offline.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/packet-assembly.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$lib" ]] || fail "lib/packet-assembly.sh not found"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ledger="$tmp/decisions-ledger.md"
cat >"$ledger" <<'M'
## 2026-09-09 — 0509 direction

committed to ACQUISITION direction (metric: signups/week).
M

# Stub curl in $tmp/curl — success mode returns canned D1 JSON, error mode
# returns a failing API payload (fed SQL lands in debug file $tmp/last-body).
cat >"$tmp/curl" <<'EOS'
#!/usr/bin/env bash
# read the --data body from stdin, echo it to the debug file, print canned json
if [[ ${STUB_MODE:-success} == "success" ]]; then
  cat >/dev/null
  printf '{"success":true,"result":[{"results":[{"n":"%s"}]}]}' "$CANNED_N"
else
  cat >"$tmp/last-body" >/dev/null 2>&1 || true
  printf '{"success":false,"errors":[{"message":"token expired"}]}'
fi
EOS
chmod +x "$tmp/curl"
cat >"$tmp/jq" <<'EOS'
#!/usr/bin/env bash
exec "$(command -v jq)" "$@"
EOS
chmod +x "$tmp/jq"

token_env="$tmp/deploy-ci.env"
printf 'CLOUDFLARE_API_TOKEN=stub-token\n' >"$token_env"

run_block() {
  ( export PACKET_DIRECTION_LEDGER_FILE="$ledger"
    export PACKET_DIRECTION_SECTION="2026-09-09 — 0509 direction"
    export PACKET_PRODUCT_CF_FILE="$token_env"
    export PACKET_CURL="$tmp/curl"
    export PACKET_JQ="$tmp/jq"
    export CANNED_N=${CANNED_N:-0}
    export STUB_MODE=${STUB_MODE:-success}
    source "$lib"
    packet_direction_block )
}

out="$(run_block)"

# --- 1. the live-read shape renders the real numbers (stubbed seams) ---
grep -q'live metric (production D1, read at packet assembly): signups_24h=0 signups_30d=0 last_signup=0' <<<"$out" \
  || fail "live metric line missing the stubbed zero counts"
grep -q 'live metric (production D1, read at packet assembly):' <<<"$out" || fail "live metric line missing from Direction block"
ok "live metric line present in the Direction block"

# Shape check: three fields on the live line, each filled or UNAVAILABLE.
live_line="$(grep 'live metric (production D1' <<<"$out")"
for f in signups_24h signups_30d last_signup; do
  echo "$live_line" | grep -qE "(^| )$f=[^ ]" || fail "live line lacks a non-empty $f field"
done
ok "live metric line carries filled-in signups_24h= signups_30d= last_signup= fields"

# --- 2. real numbers: stub returns actual counts ----------------------------
CANNED_N=2 out_n="$(run_block)"
echo "$out_n" | grep -q 'signups_24h=2 signups_30d=2' || fail "stubbed real numbers not rendered verbatim (got: $(grep -o 'live metric.*' <<<"$out_n" | head -c 200))"
ok "live-read shape renders the real numbers"

# --- 3. token-missing / file-missing renders UNAVAILABLE:<why> --------------
out_missing="$( ( export PACKET_DIRECTION_LEDGER_FILE="$ledger"
  export PACKET_DIRECTION_SECTION="2026-09-09 — 0509 direction"
  export PACKET_PRODUCT_CF_FILE="$tmp/absent.env"
  export PACKET_CURL="$tmp/curl" PACKET_JQ="$tmp/jq"
  unset CANNED_N STUB_MODE
  source "$lib"; packet_direction_block ) )"
echo "$out_missing" | grep -q 'signups_30d=UNAVAILABLE:cf-token-file-missing' || fail "missing token file did not render UNAVAILABLE:<why>"
echo "$out_missing" | grep -q 'UNAVAILABLE:' || fail "missing-file case lacks UNAVAILABLE marker"
echo "$out_missing" | grep -qE 'signups_30d=0( |$)' && fail "missing token file rendered a fabricated 0"
ok "token-file-missing renders signups_30d=UNAVAILABLE:<why>, never a fabricated 0"

nofile_token="$tmp/no-token.env"
printf 'SOMETHING_ELSE=1\n' >"$nofile_token"
out_notoken="$( ( export PACKET_DIRECTION_LEDGER_FILE="$ledger"
  export PACKET_DIRECTION_SECTION="2026-09-09 — 0509 direction"
  export PACKET_PRODUCT_CF_FILE="$nofile_token"
  export PACKET_CURL="$tmp/curl" PACKET_JQ="$tmp/jq"
  source "$lib"; packet_direction_block ) )"
echo "$out_notoken" | grep -q 'signups_30d=UNAVAILABLE:no-cf-token' || fail "token-in-file-missing key did not render UNAVAILABLE:no-cf-token"
ok "file-present-but-no-token renders UNAVAILABLE:no-cf-token"

# API error response → UNAVAILABLE:<why>, not a fabricated 0
out_err="$(CANNED_N=0 STUB_MODE=error run_block)"
echo "$out_err" | grep -q 'UNAVAILABLE:token expired' || fail "API error did not render UNAVAILABLE:<why> (got: $(grep -o 'UNAVAILABLE[^ ]*' <<<"$out_err" | head -1))"
echo "$out_err" | grep -qE 'signups_30d=0( |$)' && fail "API error rendered a fabricated 0"
ok "D1 API error degrades to UNAVAILABLE:<why>, never a fabricated 0"

# --- 4. assembled packet: the ledger prose is no longer the only metric -----
out_full="$(run_block)"
ledger=$ledger
# the frozen snapshot claim from the ledger must not be the last word
grep -q 'live metric (production D1' <<<"$out_full" || fail "ledger prose-only Direction block"
grep -q 'against the live `signups_30d=` value above' <<<"$out_full" || fail "block does not instruct evaluating A.7/A.8 against the live value"
grep -q 'A.8 acquisition-first condition' <<<"$out_full" || fail "block does not name the A.8 condition"
ok "block directs evaluation of A.7 half-cap / A.8 condition against the live value, not the ledger snapshot"

echo "all packet-direction-live-metric checks passed"
