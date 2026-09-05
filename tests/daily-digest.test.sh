#!/usr/bin/env bash
# tests/daily-digest.test.sh
#
# fleet-ops#3285: the daily digest must carry a 'spend last 24h' line reading
# fleet_seat_spend_usd{provider} from Prometheus (the metrics #3283 exports).
#
# Offline replay drill (no real Telegram, no real Prometheus, no real gh):
# the digest is run under a mock PATH (stub gh/systemctl/curl) with a canned
# Prometheus spend response, HERMES_BIN pointed at a capture stub, and the
# composed body is asserted to contain the exact spend line. It proves the
# compose path end-to-end without texting Nish. A second case drives the
# absent-metric path (fleet_seat_spend_usd not yet exported, until #3283
# lands) and asserts the graceful fallback.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
digest="$repo_root/libexec/daily-digest"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$digest" ]] || fail "daily-digest not found: $digest"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

scratch="$(mktemp -d -t daily-digest-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- stub binaries -----------------------------------------------------------
mkdir -p "$scratch/bin"
cat >"$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
# stub: never touches the real API; the digest's PR-search just gets an
# empty result so pr_line becomes the "no PRs" variant.
if [[ "$*" == *search* ]]; then
  echo '[]'
else
  echo '{}'
fi
SH
cat >"$scratch/bin/systemctl" <<'SH'
#!/usr/bin/env bash
# stub: no failed units.
exit 0
SH
cat >"$scratch/bin/curl" <<'SH'
#!/usr/bin/env bash
# stub: serve a canned Promise spend response for /api/v1/query, an empty
# alert list for /api/v1/alerts.
for a in "$@"; do
  case "$a" in
    *api/v1/query*)  cat "$SPEND_RESPONSE" 2>/dev/null || echo '{}'; exit 0 ;;
    *api/v1/alerts*) echo '{"status":"success","data":{"alerts":[]}}'; exit 0 ;;
  esac
done
echo '{}'
SH
cat >"$scratch/bin/hermes" <<'SH'
#!/usr/bin/env bash
# capture stub: write the digest body to a file, never send.
printf '%s' "${@: -1}" > "$DAILY_DIGEST_CAPTURE"
echo '{"ok":true,"message_id":"drill-1"}'
SH
chmod +x "$scratch/bin/gh" "$scratch/bin/systemctl" "$scratch/bin/curl" "$scratch/bin/hermes"

export PATH="$scratch/bin:$PATH"

# --- syntax gate -------------------------------------------------------------
bash -n "$digest" || fail "daily-digest has a bash syntax error"
ok "bash -n passes"

# --- case 1: spend metrics present -------------------------------------------
cat >"$scratch/spend.json" <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[
  {"metric":{"provider":"minimax"},"value":[1.0,"4.14"]},
  {"metric":{"provider":"openrouter"},"value":[1.0,"8.20"]}
]}}
JSON
env SPEND_RESPONSE="$scratch/spend.json" \
    DAILY_DIGEST_CAPTURE="$scratch/body1.txt" \
    HERMES_BIN="$scratch/bin/hermes" \
    bash "$digest" >/dev/null 2>&1
[[ -f "$scratch/body1.txt" ]] || fail "case 1: digest did not invoke the hermes stub"
grep -q "Spend last 24h: \$12.34 (openrouter \$8.20, minimax \$4.14)." "$scratch/body1.txt" \
  || fail "case 1: spend line missing/incorrect: $(grep 'Spend last 24h' "$scratch/body1.txt" || echo none)"
ok "case 1: spend line composed: '$(grep 'Spend last 24h' "$scratch/body1.txt")'"

# --- case 2: metric absent (unitl #3283 merges) ------------------------------
cat >"$scratch/spend-empty.json" <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[]}}
JSON
env SPEND_RESPONSE="$scratch/spend-empty.json" \
    DAILY_DIGEST_CAPTURE="$scratch/body2.txt" \
    HERMES_BIN="$scratch/bin/hermes" \
    bash "$digest" >/dev/null 2>&1
[[ -f "$scratch/body2.txt" ]] || fail "case 2: digest did not invoke the hermes stub"
grep -q "Spend last 24h: not available yet." "$scratch/body2.txt" \
  || fail "case 2: absent-metric fallback missing: $(grep 'Spend last 24h' "$scratch/body2.txt" || echo none)"
ok "case 2: absent-metric fallback: '$(grep 'Spend last 24h' "$scratch/body2.txt")'"

echo "all daily-digest spend cases passed"
