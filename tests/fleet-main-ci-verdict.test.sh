#!/usr/bin/env bash
# tests/fleet-main-ci-verdict.test.sh
#
# fleet-ops#2963: fleet_main_ci_green must refresh within one 5-minute
# exporter tick (no 30-minute shared cache), read a PUSH-run verdict that
# skipped/cancelled runs can never forge, record its source timestamp, and
# stay visibly unknown — never green — when evidence is missing. Hermetic:
# gh is stubbed on PATH and the textfile is redirected with FLEET_PROM_OUT.
#
# Proves:
#   1. promtool accepts config/fleet_rules.yml and the restored FleetMainRed
#      fires on a held red and stays silent at 29m / on green.
#   2. Green verdict emits 1 plus fleet_main_ci_run_timestamp_seconds equal
#      to the verdict run's updated_at.
#   3. Fresh red emits 0.
#   4. Recovery: a red textfile flips to 1 on the very next probe run —
#      nothing is pinned for 30 minutes.
#   5. A cancelled/skipped/null head falls through to the last real verdict;
#      a list with no real verdict emits NO series (unknown, not red, not
#      green).
#   6. Empty workflow_runs and a gh failure both emit no series while the
#      probe still writes the file and exits 0.
#   7. No cache machinery: the probe source names no repo-snapshot-cache or
#      PR_CACHE_TTL, and the run leaves no cache file behind.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
probe="$repo_root/libexec/fleet-metrics-probe.sh"
rules="$repo_root/config/fleet_rules.yml"
fixture="$here/fixtures/fleet-main-red.promtool.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT INT TERM
mkdir -p "$TD/bin"

command -v promtool >/dev/null || fail "promtool not on PATH"
command -v jq >/dev/null || fail "jq not on PATH"

# --- 1. rules file valid + restored FleetMainRed behaves ---------------------
promtool check rules "$rules" >/dev/null || fail "promtool check rules failed"
ok "promtool check rules $rules"

promtool test rules "$fixture" >/dev/null || fail "promtool test rules failed on the FleetMainRed fixture"
ok "FleetMainRed fires on held red at 31m, silent at 29m and on green"

# --- 2. gh stub ---------------------------------------------------------------
# Dispatches on the endpoint arg; honours --jq like real gh so the probe's
# verdict filter runs for real. GH_FAKE_PUSH_FILE carries the JSON served for
# the branch=main&event=push call; GH_FAKE_PUSH_FAIL=1 makes gh exit 1.
# rate_limit answers under the fleet-ops#5762 20% floor so the GraphQL
# merge-queue call is skipped and the output stays small.
cat >"$TD/bin/gh" <<'EOF'
#!/bin/sh
endpoint=""; jq_expr=""
while [ $# -gt 0 ]; do
  case "$1" in
    api) shift ;;
    --jq) jq_expr="$2"; shift 2 ;;
    -f) shift 2 ;;
    *) endpoint="$1"; shift ;;
  esac
done
emit() { if [ -n "$jq_expr" ]; then jq -r "$jq_expr"; else cat; fi; }
case "$endpoint" in
  rate_limit)
    printf '{"rate":{"remaining":800,"limit":5000}}\n' | emit ;;
  *event=push*)
    [ "${GH_FAKE_PUSH_FAIL:-0}" = 1 ] && exit 1
    cat "$GH_FAKE_PUSH_FILE" | emit ;;
  *status=queued*|*status=in_progress*|*status=completed*)
    printf '{"total_count":0,"workflow_runs":[]}\n' | emit ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TD/bin/gh"

write_push() { printf '%s\n' "$1" > "$TD/push.json"; }

run_probe() {
  env -i \
    HOME="$TD" \
    PATH="$TD/bin:/usr/bin:/bin" \
    FLEET_PROM_OUT="$TD/fleet.prom" \
    CI_PROBE_NOW=1789891200 \
    CI_PROBE_REPOS="0509" \
    GH_FAKE_PUSH_FILE="$TD/push.json" \
    ${GH_FAKE_PUSH_FAIL:+GH_FAKE_PUSH_FAIL="$GH_FAKE_PUSH_FAIL"} \
    /bin/sh "$probe"
}

# --- 3. green verdict + source timestamp --------------------------------------
write_push '{"workflow_runs":[{"conclusion":"success","updated_at":"2026-09-20T08:00:00Z"}]}'
run_probe || fail "probe exited non-zero on green"
ts_green=$(date -u -d '2026-09-20T08:00:00Z' +%s)
grep -q "fleet_main_ci_green{repo=\"0509\"} 1" "$TD/fleet.prom" \
  || fail "green verdict did not emit 1; got: $(grep fleet_main_ci "$TD/fleet.prom" || true)"
grep -q "fleet_main_ci_run_timestamp_seconds{repo=\"0509\"} $ts_green" "$TD/fleet.prom" \
  || fail "source timestamp wrong/missing; expected $ts_green; got: $(grep fleet_main_ci_run_timestamp "$TD/fleet.prom" || true)"
ok "green verdict emits 1 with source timestamp $ts_green"

# --- 4. fresh red --------------------------------------------------------------
write_push '{"workflow_runs":[{"conclusion":"failure","updated_at":"2026-09-20T08:30:00Z"}]}'
run_probe || fail "probe exited non-zero on red"
grep -q "fleet_main_ci_green{repo=\"0509\"} 0" "$TD/fleet.prom" \
  || fail "fresh red did not emit 0; got: $(grep fleet_main_ci "$TD/fleet.prom" || true)"
ok "fresh red emits 0"

# --- 5. recovery: next tick flips red -> green, no 30-minute pin ----------------
write_push '{"workflow_runs":[{"conclusion":"success","updated_at":"2026-09-20T08:35:00Z"}]}'
run_probe || fail "probe exited non-zero on recovery"
grep -q "fleet_main_ci_green{repo=\"0509\"} 1" "$TD/fleet.prom" \
  || fail "recovery did not flip the textfile to 1 on the next run; got: $(grep fleet_main_ci "$TD/fleet.prom" || true)"
ok "recovery from red lands on the very next probe run — nothing cached"

# --- 6. cancelled/skipped/null heads are not verdicts ---------------------------
write_push '{"workflow_runs":[
  {"conclusion":null,"updated_at":"2026-09-20T09:10:00Z"},
  {"conclusion":"cancelled","updated_at":"2026-09-20T09:05:00Z"},
  {"conclusion":"skipped","updated_at":"2026-09-20T09:02:00Z"},
  {"conclusion":"success","updated_at":"2026-09-20T09:00:00Z"}]}'
run_probe || fail "probe exited non-zero on cancelled-head list"
grep -q "fleet_main_ci_green{repo=\"0509\"} 1" "$TD/fleet.prom" \
  || fail "cancelled/skipped head did not fall through to the success verdict"
grep -q "fleet_main_ci_run_timestamp_seconds{repo=\"0509\"} $(date -u -d '2026-09-20T09:00:00Z' +%s)" "$TD/fleet.prom" \
  || fail "timestamp is not the verdict run's own updated_at"
ok "pending/cancelled/skipped heads fall through to the last real verdict"

# --- 7. no real verdict at all -> series absent (unknown, not red) --------------
write_push '{"workflow_runs":[{"conclusion":"cancelled","updated_at":"2026-09-20T09:10:00Z"},{"conclusion":"skipped","updated_at":"2026-09-20T09:05:00Z"}]}'
run_probe || fail "probe exited non-zero on all-nonverdict list"
if grep -q 'fleet_main_ci_green{repo="0509"}' "$TD/fleet.prom"; then
  fail "all-cancelled/skipped list still emitted a verdict"
fi
if grep -q 'fleet_main_ci_run_timestamp_seconds{repo="0509"}' "$TD/fleet.prom"; then
  fail "timestamp emitted with no verdict run"
fi
ok "no real verdict -> both series absent (visibly unknown)"

# --- 8. missing CI evidence -> series absent ------------------------------------
write_push '{"workflow_runs":[]}'
run_probe || fail "probe exited non-zero on empty run list"
if grep -q 'fleet_main_ci_green{repo="0509"}' "$TD/fleet.prom"; then
  fail "empty workflow_runs emitted a verdict"
fi
ok "missing CI evidence -> series absent, file still written"

# --- 9. GitHub failure -> series absent, probe exits 0 ----------------------------
GH_FAKE_PUSH_FAIL=1 run_probe || fail "probe exited non-zero on gh failure"
if grep -q 'fleet_main_ci_green{repo="0509"}' "$TD/fleet.prom"; then
  fail "gh failure emitted a verdict"
fi
[[ -s "$TD/fleet.prom" ]] || fail "textfile missing after gh failure"
unset GH_FAKE_PUSH_FAIL
ok "gh failure -> series absent, textfile still written, exit 0"

# --- 10. no cache machinery ------------------------------------------------------
if grep -Eq 'repo-snapshot-cache|PR_CACHE_TTL' "$probe"; then
  fail "probe source still references the shared 30-minute cache"
fi
if find "$TD" -name '*snapshot*' -o -name '*cache*' | grep -q .; then
  fail "probe run left a cache file behind: $(find "$TD" -name '*snapshot*' -o -name '*cache*')"
fi
ok "no repo-snapshot-cache / PR_CACHE_TTL anywhere in the probe"

echo "ALL PASS"
