#!/usr/bin/env bash
# tests/fleet-vibes-canary.test.sh
#
# Proves the "never decide by vibes — always measure" canary (fleet-ops#538)
# offline:
#   1. Clean: ram_gb_per_worker cited with a dated bin/... measurement and
#      every provider cap carries a dated measurement citation -> exit 0,
#      no filing.
#   2. Gate: ram_gb_per_worker missing -> exit 1, LOUD.
#   3. Gate: ram_gb_per_worker cited with a date but NO bin/ measurement
#      command (only a vibe phrase) -> exit 1, LOUD.
#   4. Gate: ram_gb_per_worker citation has a bin/ command but no date ->
#      exit 1, LOUD.
#   5. Detector: a provider cap>0 with no citation -> exit 0, files a
#      ticket (observe-to-open), tick stays green.
#   6. Detector: a provider cap>0 cited only by a top-level _comment_*
#      that names the provider + date + marker -> exit 0, no file.
#   7. Detector: a provider cap>0 cited by a top-level _comment_* that
#      does NOT name the provider -> exit 0, files (the citation must
#      name what it covers).
#   8. Detector: a provider cap=0 with no dated reason -> exit 0, files.
#   9. Detector: a provider cap=0 with a dated reason -> exit 0, no file.
#  10. Detector: a bare "feels right" citation is NOT a marker -> files.
#  11. Detector: a fleet-ops# ref alone is NOT a marker -> files.
#  12. Dedup: an open issue carrying the marker -> no second create.
#  13. File cap: more findings than FLEET_VIBES_CANARY_CAP -> excess
#      deferred, no error.
#  14. Broken: seat-caps missing / unparseable / jq missing -> exit 1.
#  15. Production seat-caps: gate clean; orcarouter is the one known
#      uncited cap and is filed (observe-to-open), exit 0.
#  16. Heartbeat-tier1 wires the canary and propagates a fail-loud gate.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-vibes-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"
command -v jq >/dev/null 2>&1 || fail "jq missing"

scratch="$(mktemp -d -t vibes-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_VIBES_CANARY_REPO="Nishfleet/fleet-ops"

gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
gh_creates="$scratch/creates.log"
gh_open="$scratch/open.json"
: >"$gh_log"
: >"$gh_creates"
echo '[]' >"$gh_open"
export GH="$gh_fake"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    cat "${GH_OPEN_ISSUES:-/dev/null}" 2>/dev/null || echo '[]'
    ;;
  *"issue create"*)
    # Record the title (the --title arg) so tests can assert filings.
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) printf '%s\n' "$2" >>"${GH_CREATES:-/dev/null}"; break ;;
      esac
      shift
    done
    echo "https://github.com/Nishfleet/fleet-ops/issues/$RANDOM"
    ;;
  *)
    echo "fake-gh: $*" >&2
    ;;
esac
FAKE
chmod +x "$gh_fake"
export GH_LOG="$gh_log"
export GH_CREATES="$gh_creates"
export GH_OPEN_ISSUES="$gh_open"

# Build a minimal clean seat-caps fixture. The marker set is exercised by
# the dirty variants below.
clean_caps="$scratch/clean.json"
cat >"$clean_caps" <<'JSON'
{
  "ram_gb_per_worker": 1.5,
  "_comment_ram_governor": "ram_gb_per_worker=1.5 (2026-08-26, fleet-ops#45). Mechanical re-measurement: bin/ram-measure (n=14, p95 4.4 GB). Re-derive with bin/ram-metric-compare.",
  "_comment_quota_bench": "quota_bench_default_s (fleet-ops#90): cline=604800 (ClinePass weekly cap), devin=900 (devin 15-min rate limit).",
  "providers": {
    "devin": {
      "cap": 4,
      "class": "prepaid-quota",
      "quota_bench_default_s": 900,
      "models": { "glm-5-2": 3 }
    },
    "cline": {
      "cap": 2,
      "class": "prepaid-quota",
      "quota_bench_default_s": 604800,
      "models": { "cline-pass/deepseek-v4-flash": 2 },
      "_comment_glm53": "2026-08-27: ClinePass GLM 5.3 flash probed 2026-08-26 (404 on flash slug). bin/fleet-cline-glm53-canary auto-files."
    },
    "groq": {
      "cap": 0,
      "class": "free",
      "reason": "2026-08-25 credentials_bad on openai/gpt-oss-120b; no working credential."
    }
  },
  "_comment_seat_roster": "Nish 2026-08-25: devin probed live and answering (HTTP 200)."
}
JSON

# 1. Clean -> exit 0, no filing.
: >"$gh_creates"
SEAT_CAPS_JSON="$clean_caps" FLEET_VIBES_CANARY_FILE=1 "$bin" >/tmp/vibes1.log 2>&1 \
  || fail "clean fixture must exit 0 (rc=$?)"
[[ -s "$gh_creates" ]] && fail "clean fixture must not file (filed=$(cat "$gh_creates"))"
ok "1. clean fixture: gate + detectors clean, exit 0, no filing"

# 2. Gate: ram_gb_per_worker missing -> exit 1.
no_ram="$scratch/no_ram.json"
jq 'del(.ram_gb_per_worker)' "$clean_caps" >"$no_ram"
SEAT_CAPS_JSON="$no_ram" FLEET_VIBES_CANARY_FILE=0 "$bin" >/tmp/vibes2.log 2>&1 \
  && fail "missing ram_gb_per_worker must exit 1"
grep -q "VIBES-GATE-VIOLATION" "$triage" || fail "missing ram must be LOUD in triage"
ok "2. gate: missing ram_gb_per_worker -> exit 1, LOUD"

# 3. Gate: ram citation has a date but NO bin/ measurement command -> exit 1.
vibe_ram="$scratch/vibe_ram.json"
jq '._comment_ram_governor = "ram_gb_per_worker=1.5 (2026-08-26). Feels right for a typical worker."' \
  "$clean_caps" >"$vibe_ram"
: >"$triage"
SEAT_CAPS_JSON="$vibe_ram" FLEET_VIBES_CANARY_FILE=0 "$bin" >/tmp/vibes3.log 2>&1 \
  && fail "vibe-only ram citation must exit 1"
grep -q "VIBES-GATE-VIOLATION" "$triage" || fail "vibe ram must be LOUD"
ok "3. gate: ram citation with date but no bin/ command -> exit 1 (a vibe is not a measurement)"

# 4. Gate: ram citation has bin/ command but no date -> exit 1.
nodate_ram="$scratch/nodate_ram.json"
jq '._comment_ram_governor = "ram_gb_per_worker=1.5. Re-measure with bin/ram-measure (n=14, p95 4.4 GB)."' \
  "$clean_caps" >"$nodate_ram"
: >"$triage"
SEAT_CAPS_JSON="$nodate_ram" FLEET_VIBES_CANARY_FILE=0 "$bin" >/tmp/vibes4.log 2>&1 \
  && fail "undated ram citation must exit 1"
grep -q "VIBES-GATE-VIOLATION" "$triage" || fail "undated ram must be LOUD"
ok "4. gate: ram citation with bin/ command but no date -> exit 1"

# 5. Detector: provider cap>0 with no citation -> exit 0, files.
uncited_cap="$scratch/uncited_cap.json"
jq '.providers.orcarouter = {"cap": 1, "class": "free", "models": {"orcarouter/free": 1}}' \
  "$clean_caps" >"$uncited_cap"
: >"$gh_creates"
SEAT_CAPS_JSON="$uncited_cap" FLEET_VIBES_CANARY_FILE=1 "$bin" >/tmp/vibes5.log 2>&1 \
  || fail "uncited cap detector must exit 0 (rc=$?)"
grep -q "orcarouter cap=1 has no measurement citation" /tmp/vibes5.log \
  || fail "detector must log the uncited cap"
grep -qi "vibes: orcarouter cap=1 has no measurement citation" "$gh_creates" \
  || fail "detector must file the uncited cap (creates=$(cat "$gh_creates"))"
ok "5. detector: uncited provider cap -> exit 0, files (observe-to-open)"

# 6. Detector: provider cap>0 cited only by a top-level _comment_* naming
#    the provider + date + marker -> exit 0, no file.
topcited="$scratch/topcited.json"
jq '.providers.zenmux = {"cap": 2, "class": "metered"} | ._comment_zenmux = "Nish 2026-08-25: zenmux probed live and answering (HTTP 200)."' \
  "$clean_caps" >"$topcited"
: >"$gh_creates"
SEAT_CAPS_JSON="$topcited" FLEET_VIBES_CANARY_FILE=1 "$bin" >/tmp/vibes6.log 2>&1 \
  || fail "top-level-cited cap must exit 0 (rc=$?)"
[[ -s "$gh_creates" ]] && fail "top-level-cited cap must not file (filed=$(cat "$gh_creates"))"
ok "6. detector: cap cited by a top-level _comment_* naming the provider -> no file"

# 7. Detector: top-level _comment_* that does NOT name the provider -> files.
noname="$scratch/noname.json"
jq '.providers.zenmux = {"cap": 2, "class": "metered"} | ._comment_other = "Nish 2026-08-25: devin probed live and answering (HTTP 200)."' \
  "$clean_caps" >"$noname"
: >"$gh_creates"
SEAT_CAPS_JSON="$noname" FLEET_VIBES_CANARY_FILE=1 "$bin" >/tmp/vibes7.log 2>&1 \
  || fail "non-name top-level citation must exit 0 (rc=$?)"
grep -qi "vibes: zenmux cap=2 has no measurement citation" "$gh_creates" \
  || fail "detector must file zenmux (creates=$(cat "$gh_creates"))"
ok "7. detector: top-level citation that does not name the provider -> files"

# 8. Detector: cap=0 with no dated reason -> exit 0, files.
cap0_noreason="$scratch/cap0_noreason.json"
jq '.providers.inferx = {"cap": 0, "class": "free", "reason": "unproven promo, no packet carried."}' \
  "$clean_caps" >"$cap0_noreason"
: >"$gh_creates"
SEAT_CAPS_JSON="$cap0_noreason" FLEET_VIBES_CANARY_FILE=1 "$bin" >/tmp/vibes8.log 2>&1 \
  || fail "cap0 no-reason detector must exit 0 (rc=$?)"
grep -qi "vibes: inferx cap=0 has no dated reason" "$gh_creates" \
  || fail "detector must file inferx cap0 (creates=$(cat "$gh_creates"))"
ok "8. detector: cap=0 with no dated reason -> files"

# 9. Detector: cap=0 with a dated reason -> no file. (groq in clean fixture)
: >"$gh_creates"
SEAT_CAPS_JSON="$clean_caps" FLEET_VIBES_CANARY_FILE=1 "$bin" >/tmp/vibes9.log 2>&1 \
  || fail "dated-reason cap0 must exit 0 (rc=$?)"
grep -qi "groq" "$gh_creates" && fail "dated-reason cap0 must not file"
ok "9. detector: cap=0 with a dated reason -> no file"

# 10. A bare "feels right" citation is NOT a marker -> files.
feels="$scratch/feels.json"
jq '.providers.feelsprov = {"cap": 1, "class": "free", "models": {"x": 1}, "_note": "2026-08-26: cap=1 feels right for this provider."}' \
  "$clean_caps" >"$feels"
: >"$gh_creates"
SEAT_CAPS_JSON="$feels" FLEET_VIBES_CANARY_FILE=1 "$bin" >/tmp/vibes10.log 2>&1 \
  || fail "feels-right detector must exit 0 (rc=$?)"
grep -qi "vibes: feelsprov cap=1 has no measurement citation" "$gh_creates" \
  || fail "feels-right must file (creates=$(cat "$gh_creates"))"
ok "10. detector: a 'feels right' citation is not a marker -> files"

# 11. A fleet-ops# ref alone is NOT a marker -> files.
refonly="$scratch/refonly.json"
jq '.providers.refprov = {"cap": 1, "class": "free", "models": {"x": 1}, "_note": "2026-08-26: see fleet-ops#999 for context."}' \
  "$clean_caps" >"$refonly"
: >"$gh_creates"
SEAT_CAPS_JSON="$refonly" FLEET_VIBES_CANARY_FILE=1 "$bin" >/tmp/vibes11.log 2>&1 \
  || fail "ref-only detector must exit 0 (rc=$?)"
grep -qi "vibes: refprov cap=1 has no measurement citation" "$gh_creates" \
  || fail "ref-only must file (creates=$(cat "$gh_creates"))"
ok "11. detector: a fleet-ops# ref alone is not a marker -> files"

# 12. Dedup: an open issue carrying the marker -> no second create.
: >"$gh_creates"
echo '[{"number": 777, "body": "vibes-canary: refprov cap-no-measurement\nmore text"}]' >"$gh_open"
SEAT_CAPS_JSON="$refonly" FLEET_VIBES_CANARY_FILE=1 "$bin" >/tmp/vibes12.log 2>&1 \
  || fail "dedup must exit 0 (rc=$?)"
grep -qi "vibes: refprov cap=1 has no measurement citation" "$gh_creates" \
  && fail "dedup must not file a second time (creates=$(cat "$gh_creates"))"
grep -q "dedup: open Nishfleet/fleet-ops#777" /tmp/vibes12.log \
  || fail "dedup must log the existing issue"
ok "12. dedup: open issue with the marker -> no second create"

# Reset open issues for the cap test.
echo '[]' >"$gh_open"

# 13. File cap: more findings than the cap -> excess deferred, no error.
many="$scratch/many.json"
base="$(cat "$clean_caps")"
for p in p1 p2 p3 p4 p5 p6; do
  base=$(jq --arg p "$p" --argjson cap 1 '.providers[$p] = {"cap": 1, "class": "free", "models": {"x": 1}}' <<<"$base")
done
printf '%s' "$base" >"$many"
: >"$gh_creates"
SEAT_CAPS_JSON="$many" FLEET_VIBES_CANARY_FILE=1 FLEET_VIBES_CANARY_CAP=2 "$bin" >/tmp/vibes13.log 2>&1 \
  || fail "file-cap must exit 0 (rc=$?)"
filed=$(wc -l <"$gh_creates")
(( filed == 2 )) || fail "file cap=2 must file exactly 2 (filed=$filed)"
grep -q "file cap reached" /tmp/vibes13.log || fail "must log cap reached"
ok "13. file cap: excess findings deferred to next tick (filed=$filed cap=2)"

# 14. Broken: seat-caps missing / unparseable -> exit 1.
: >"$triage"
SEAT_CAPS_JSON="$scratch/nope.json" FLEET_VIBES_CANARY_FILE=0 "$bin" >/tmp/vibes14a.log 2>&1 \
  && fail "missing seat-caps must exit 1"
grep -q "VIBES-CANARY-BROKEN" "$triage" || fail "missing seat-caps must be LOUD"
bad_json="$scratch/bad.json"
printf '{ not json' >"$bad_json"
: >"$triage"
SEAT_CAPS_JSON="$bad_json" FLEET_VIBES_CANARY_FILE=0 "$bin" >/tmp/vibes14b.log 2>&1 \
  && fail "unparseable seat-caps must exit 1"
grep -q "VIBES-CANARY-BROKEN" "$triage" || fail "unparseable seat-caps must be LOUD"
ok "14. broken: missing / unparseable seat-caps -> exit 1, LOUD"

# 15. Production seat-caps: gate clean; orcarouter is the one known uncited
#     cap and is filed (observe-to-open), exit 0.
prod_caps="$repo_root/config/seat-caps.json"
if [[ -f "$prod_caps" ]]; then
  : >"$gh_creates"
  echo '[]' >"$gh_open"
  SEAT_CAPS_JSON="$prod_caps" FLEET_VIBES_CANARY_FILE=1 "$bin" >/tmp/vibes15.log 2>&1 \
    || fail "production seat-caps must exit 0 (rc=$?) — gate clean, detector files"
  grep -q "GATE: ram_gb_per_worker" /tmp/vibes15.log \
    || fail "production gate must pass (ram_gb_per_worker measured)"
  # orcarouter is the known pre-existing uncited cap; the detector files it.
  grep -q "orcarouter cap=1 has no measurement citation" /tmp/vibes15.log \
    || fail "production detector must flag orcarouter (the known uncited cap)"
  ok "15. production seat-caps: gate clean; orcarouter filed (observe-to-open), exit 0"
else
  ok "15. production seat-caps not present (hosted CI) — skip"
fi

# 16. Heartbeat-tier1 wires the canary and propagates a fail-loud gate.
grep -q "fleet-vibes-canary" "$tier1" \
  || fail "heartbeat-tier1 must wire fleet-vibes-canary"
grep -q "vibes_canary_rc" "$tier1" \
  || fail "heartbeat-tier1 must track vibes_canary_rc"
grep -q 'vibes_canary_rc' "$tier1" && \
  grep -A2 'vibes_canary_rc' "$tier1" | grep -q 'exit' \
  || fail "heartbeat-tier1 must propagate vibes_canary_rc to exit"
ok "16. heartbeat-tier1 wires the canary and propagates fail-loud"

echo "OK: fleet-vibes-canary: gate, detector, dedup, cap, broken, production, heartbeat wiring"
