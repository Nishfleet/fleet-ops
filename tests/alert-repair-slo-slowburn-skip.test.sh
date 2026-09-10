#!/usr/bin/env bash
# tests/alert-repair-slo-slowburn-skip.test.sh
#
# fleet-ops#2672: lock FleetSloMainGreenSlowBurn into the repair skip rails
# so the main_green slow-burn SLO (a WFR-input lagging integrator,
# fleet-ops#1291) can never spawn a repair worker or escalate a canary chain.
# The alert fired repeatedly since 2026-08-30: Alertmanager's 6h repeat
# dispatched a fresh worker every cycle (6+ dispatches in 3 days), every
# worker Failed/RESOLVED with the same verdict (the burn-rate windows flush
# on their own 30m/6h schedule; repair mechanism-impossible — the underlying
# CI red is owned by FleetMainRed), and each new chain stalled at hop=verify
# until its deadline — the chain_stalled=1 at 2026-09-01T15:23Z this issue
# was filed for, with the verify hop re-seating onto an empty-run benched
# seat. The seat-burn loop PR #2441 closed the sibling
# FleetSloSeatAvailSlowBurn the same way.
#
# Offline (no live Prom/Alertmanager). Hosted by
# tests/ci-standards-audit.test.sh so it runs in P14 without a
# workflow-file edit.
#
# Proves:
#   1. The name is in libexec/alert-repair-dispatch SKIP_SET exactly once.
#   2. Dispatcher stub: firing the alert through the real dispatcher with a
#      mocked environment logs `SKIP reason=skip-list`, adds no DISPATCH
#      line, and spawns no worker (no pi-systemd-run).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
dispatch_bin="$repo_root/libexec/alert-repair-dispatch"
name="FleetSloMainGreenSlowBurn"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$dispatch_bin" ]] || fail "not executable: $dispatch_bin"
python3 -m py_compile "$dispatch_bin" || fail "py_compile failed"

scratch="$(mktemp -d -t alert-repair-slo-slowburn.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

# --- 1. dispatcher SKIP_SET contains the name exactly once -----------------
# The literal must carry the name once and only once. Comments elsewhere
# in the file (e.g. a later history note that names the alert) do not
# count against this — we count occurrences INSIDE the SKIP_SET literal,
# not in the whole file.
python3 - "$dispatch_bin" "$name" <<'PY' || fail "dispatcher SKIP_SET shape failed"
import ast, re, sys
src = open(sys.argv[1]).read()
name = sys.argv[2]
m = re.search(r"SKIP_SET = (\{.*?\})", src, re.S)
assert m, "SKIP_SET not found in alert-repair-dispatch"
skip = ast.literal_eval(m.group(1))
assert name in skip, f"{name} missing from SKIP_SET: {skip}"
in_literal = m.group(1).count(f'"{name}"')
assert in_literal == 1, f"{name} must appear exactly once inside SKIP_SET literal, got {in_literal}"
print(f"OK: dispatcher SKIP_SET contains {name} (one occurrence in literal)")
PY

# --- 2. dispatcher stub: SKIP reason=skip-list, no DISPATCH, no spawn ------
# Same shape as tests/alert-repair-wfr-trend-skip.test.sh / the
# FleetSloSeatAvailSlowBurn fire_skip (tests/alert-repair-claim-mutex.test.sh,
# fleet-ops#2429): firing the alert through the real dispatcher with a mocked
# pi-systemd-run PATH must log SKIP, add no DISPATCH line, and never invoke
# the worker spawner.
export ALERT_REPAIR_PACKET_DIR="$scratch/agent-state/alert-repair"
export PACKET_DIR="$scratch/agent-state/alert-repair"
mkdir -p "$PACKET_DIR"

mock_bin="$scratch/mock-bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/pi-systemd-run" <<'MOCK'
#!/usr/bin/env bash
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] mock-pi-systemd-run args=$*" >> "${MOCK_LOG:-/dev/null}"
exit 0
MOCK
chmod +x "$mock_bin/pi-systemd-run"
export MOCK_LOG="$scratch/mock-pi-systemd-run.log"

: >"$PACKET_DIR/actions.log"
: >"$MOCK_LOG"
AMX_ALERT_1_LABEL_alertname="$name" \
AMX_ALERT_1_LABEL_severity="warning" \
AMX_ALERT_1_LABEL_service="fleet" \
AMX_LABEL_repo="fleet-ops" \
AMX_STATUS="firing" \
AMX_RECEIVER="test-receiver" \
PATH="$mock_bin:$PATH" \
HOME="$scratch" \
"$dispatch_bin" \
    >"$scratch/dispatch.out" 2>"$scratch/dispatch.err"
dispatch_rc=$?
[[ "$dispatch_rc" == 0 ]] \
    || fail "$name dispatch must exit 0, got rc=$dispatch_rc (stderr: $(cat "$scratch/dispatch.err"))"
grep -q "SKIP alertname=$name.*reason=skip-list" "$PACKET_DIR/actions.log" \
    || fail "$name must log SKIP reason=skip-list; actions.log: $(cat "$PACKET_DIR/actions.log")"
disps=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
[[ "$disps" == "0" ]] \
    || fail "$name must not add a DISPATCH line, got $disps: $(cat "$PACKET_DIR/actions.log")"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] \
    || fail "$name must not spawn a worker, mock invoked $spawns times: $(cat "$MOCK_LOG")"
ok "$name: dispatcher SKIP reason=skip-list, no DISPATCH, no spawn"

echo "OK: fleet-ops#2672 slow-burn skip-list lock passes"

# ============================================================================
# fleet-ops#4773: FleetSloSeatAvailSlowBurn auto-file-or-link after 1h
# Proves BOTH directions + idempotence (accept-5):
#   (a) firing >1h + no existing claim -> files exactly ONE, no spawn.
#   (b) firing >1h + live claim -> LINKS (no file), idempotent across a 2nd tick.
#   (c) firing <=1h -> plain SKIP, no file (no premature filing).
# The skip-list entry STAYS throughout (no repair worker spawned).
# ============================================================================

slowburn="FleetSloSeatAvailSlowBurn"

# Mock gh + fleet-issue-file on PATH. gh records every call; fleet-issue-file
# prints a /issues/<num> URL on success and records the file call.
mock_bin2="$scratch/mock-bin2"
mkdir -p "$mock_bin2"
GH_CALLS="$scratch/gh-calls.log"
FILE_CALLS="$scratch/file-calls.log"
export GH_CALLS FILE_CALLS
: >"$GH_CALLS"
: >"$FILE_CALLS"

# `gh issue list --search <signal>` returns the canned JSON; the test
# toggles GH_LIST_JSON between "[]" (no existing) and a real issue.
GH_LIST_JSON="[]"
export GH_LIST_JSON
cat >"$mock_bin2/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_CALLS:-/dev/null}"
if [[ "$1 $2" == "issue list" ]]; then
    printf '%s' "${GH_LIST_JSON:-[]}"
elif [[ "$1 $2" == "issue comment" ]]; then
    : # heartbeat comment on the linked issue — best effort, exit 0.
fi
exit 0
GH
chmod +x "$mock_bin2/gh"

cat >"$mock_bin2/fleet-issue-file" <<'FILE'
#!/usr/bin/env bash
echo "fleet-issue-file $*" >> "${FILE_CALLS:-/dev/null}"
echo "https://github.com/Nishfleet/fleet-ops/issues/4773"
exit 0
FILE
chmod +x "$mock_bin2/fleet-issue-file"

reset_log() { : >"$PACKET_DIR/actions.log"; : >"$GH_CALLS"; : >"$FILE_CALLS"; }

fire_slowburn() {
    local start="$1"
    AMX_ALERT_1_LABEL_alertname="$slowburn" \
    AMX_ALERT_1_LABEL_severity="warning" \
    AMX_ALERT_1_LABEL_service="fleet" \
    AMX_ALERT_1_START="$start" \
    AMX_LABEL_repo="fleet-ops" \
    AMX_STATUS="firing" \
    AMX_RECEIVER="test-receiver" \
    PATH="$mock_bin2:$mock_bin:$PATH" \
    HOME="$scratch" \
    FLEET_ISSUE_FILE="$mock_bin2/fleet-issue-file" \
    GH="$mock_bin2/gh" \
    FLEET_SLOWBURN_REPO="Nishfleet/fleet-ops" \
    FLEET_SLOWBURN_SIGNAL="slo/seat-availability-slowburn" \
    "$dispatch_bin" \
        >"$scratch/sb.out" 2>"$scratch/sb.err"
}

# AMX sends AMX_ALERT_<i>_START as a Unix epoch integer in production (see
# packet-file evidence: `starts_at: 1789051780`), so the test must carry an
# epoch integer here too — an ISO 8601 start masked the original bug.
two_h_ago="$(date -u -d '2 hours ago' +%s 2>/dev/null || date -u -v-2H +%s)"
ten_m_ago="$(date -u -d '10 minutes ago' +%s 2>/dev/null || date -u -v-10M +%s)"
# ISO 8601 backward-compat form (still accepted by the parser).
two_h_ago_iso="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2H +%Y-%m-%dT%H:%M:%SZ)"

# --- (c) firing <=1h: plain SKIP, NO file, NO link, NO spawn -----------------
reset_log
fire_slowburn "$ten_m_ago"; rc=$?
[[ "$rc" == 0 ]] || fail "(c) short-firing dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
files=$(grep -c 'fleet-issue-file' "$FILE_CALLS" || true)
[[ "$files" == "0" ]] \
    || fail "(c) short-firing must NOT file, got $files file calls: $(cat "$FILE_CALLS")"
links=$(grep -c '\] LINK ' "$PACKET_DIR/actions.log" || true)
[[ "$links" == "0" ]] || fail "(c) short-firing must NOT link, got $links"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] || fail "(c) short-firing must not spawn, got $spawns"
grep -q "SKIP alertname=$slowburn.*reason=skip-list" "$PACKET_DIR/actions.log" \
    || fail "(c) short-firing must log SKIP reason=skip-list: $(cat "$PACKET_DIR/actions.log")"
ok "(c) firing <=1h: SKIP reason=skip-list, no file, no link, no spawn"

# --- (a) firing >1h + no existing claim: files exactly ONE, no spawn ---------
reset_log
GH_LIST_JSON="[]"
fire_slowburn "$two_h_ago"; rc=$?
[[ "$rc" == 0 ]] || fail "(a) long-firing dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
filed=$(grep -c '\] FILED ' "$PACKET_DIR/actions.log" || true)
[[ "$filed" == "1" ]] \
    || fail "(a) long-firing + no existing must FILE exactly one, got $filed: $(cat "$PACKET_DIR/actions.log")"
files=$(grep -c 'fleet-issue-file' "$FILE_CALLS" || true)
[[ "$files" == "1" ]] \
    || fail "(a) must invoke fleet-issue-file exactly once, got $files: $(cat "$FILE_CALLS")"
grep -q '\] FILED .*issue=#4773' "$PACKET_DIR/actions.log" \
    || fail "(a) FILED line must record issue #4773: $(cat "$PACKET_DIR/actions.log")"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] \
    || fail "(a) must NOT spawn a worker (skip-list stays), got $spawns"
disps=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
[[ "$disps" == "0" ]] || fail "(a) must NOT add a DISPATCH line, got $disps"
ok "(a) firing >1h + no existing claim: FILED exactly one #4773, no spawn, no DISPATCH"

# --- (b) firing >1h + live claim: LINKS, no file, idempotent across 2nd tick --
reset_log
GH_LIST_JSON='[{"number":4242,"title":"alarm: FleetSloSeatAvailSlowBurn [slo/seat-availability-slowburn]"}]'
fire_slowburn "$two_h_ago"; rc=$?
[[ "$rc" == 0 ]] || fail "(b) link dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
links=$(grep -c '\] LINK ' "$PACKET_DIR/actions.log" || true)
[[ "$links" == "1" ]] \
    || fail "(b) must LINK exactly once, got $links: $(cat "$PACKET_DIR/actions.log")"
grep -q '\] LINK .*issue=#4242' "$PACKET_DIR/actions.log" \
    || fail "(b) LINK line must record issue #4242: $(cat "$PACKET_DIR/actions.log")"
files=$(grep -c 'fleet-issue-file' "$FILE_CALLS" || true)
[[ "$files" == "0" ]] \
    || fail "(b) must NOT file when a live claim exists, got $files: $(cat "$FILE_CALLS")"
comments=$(grep -c 'issue comment' "$GH_CALLS" || true)
[[ "$comments" == "1" ]] \
    || fail "(b) must post one heartbeat comment, got $comments: $(cat "$GH_CALLS")"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] || fail "(b) must NOT spawn, got $spawns"

# Idempotence: a second tick (same live claim) LINKS again, files NOTHING.
reset_log
fire_slowburn "$two_h_ago"; rc=$?
[[ "$rc" == 0 ]] || fail "(b2) second tick must exit 0, got rc=$rc"
links2=$(grep -c '\] LINK ' "$PACKET_DIR/actions.log" || true)
[[ "$links2" == "1" ]] \
    || fail "(b2) second tick must LINK exactly once (idempotent), got $links2"
files2=$(grep -c 'fleet-issue-file' "$FILE_CALLS" || true)
[[ "$files2" == "0" ]] \
    || fail "(b2) second tick must NOT file (idempotent), got $files2: $(cat "$FILE_CALLS")"
ok "(b) firing >1h + live claim: LINK #4242 + heartbeat, no file; idempotent across 2nd tick"

# --- (d) multi-alert: SlowBurn at index 2 uses ITS start, not index 1's ------
# A non-skip-listed decoy at index 1 fires 10m ago; SlowBurn at index 2 fires
# 2h ago. The skip loop continues past the decoy (not in SKIP_SET), reaches
# SlowBurn, and must use SlowBurn's start (2h -> past threshold -> FILE), NOT
# the decoy's (10m -> skip-short). Proves the index lookup fix.
reset_log
GH_LIST_JSON="[]"
AMX_ALERT_1_LABEL_alertname="FleetMainRed" \
AMX_ALERT_1_LABEL_severity="warning" \
AMX_ALERT_1_LABEL_service="fleet" \
AMX_ALERT_1_START="$ten_m_ago" \
AMX_ALERT_2_LABEL_alertname="$slowburn" \
AMX_ALERT_2_LABEL_severity="warning" \
AMX_ALERT_2_LABEL_service="fleet" \
AMX_ALERT_2_START="$two_h_ago" \
AMX_LABEL_repo="fleet-ops" \
AMX_STATUS="firing" \
AMX_RECEIVER="test-receiver" \
PATH="$mock_bin2:$mock_bin:$PATH" \
HOME="$scratch" \
FLEET_ISSUE_FILE="$mock_bin2/fleet-issue-file" \
GH="$mock_bin2/gh" \
FLEET_SLOWBURN_REPO="Nishfleet/fleet-ops" \
FLEET_SLOWBURN_SIGNAL="slo/seat-availability-slowburn" \
    "$dispatch_bin" \
        >"$scratch/sb.out" 2>"$scratch/sb.err"; rc=$?
[[ "$rc" == 0 ]] || fail "(d) multi-alert dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
filed=$(grep -c '\] FILED ' "$PACKET_DIR/actions.log" || true)
[[ "$filed" == "1" ]] \
    || fail "(d) SlowBurn at idx2 (>1h) must FILE using its own start, got $filed: $(cat "$PACKET_DIR/actions.log")"
files=$(grep -c 'fleet-issue-file' "$FILE_CALLS" || true)
[[ "$files" == "1" ]] \
    || fail "(d) must invoke fleet-issue-file once, got $files: $(cat "$FILE_CALLS")"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] || fail "(d) must NOT spawn, got $spawns"
ok "(d) multi-alert: SlowBurn at idx2 (>1h) FILED using its own start, not idx1's short decoy"

# --- (e) ISO 8601 start ALSO works (backward-compat) -------------------------
# AMX sends epoch in production, but the parser still accepts ISO 8601 so a
# future/legacy sender is not broken. Same long-firing shape as (a), ISO form.
reset_log
GH_LIST_JSON="[]"
fire_slowburn "$two_h_ago_iso"; rc=$?
[[ "$rc" == 0 ]] || fail "(e) ISO-start dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
filed=$(grep -c '\] FILED ' "$PACKET_DIR/actions.log" || true)
[[ "$filed" == "1" ]] \
    || fail "(e) ISO-start long-firing must FILE exactly one, got $filed: $(cat "$PACKET_DIR/actions.log")"
files=$(grep -c 'fleet-issue-file' "$FILE_CALLS" || true)
[[ "$files" == "1" ]] \
    || fail "(e) ISO-start must invoke fleet-issue-file once, got $files: $(cat "$FILE_CALLS")"
ok "(e) ISO 8601 start also works (backward-compat): FILED exactly one"

# --- (f) ISO 8601 start WITH fractional milliseconds + Z (live AMX shape) -------
# Live Alertmanager (http://127.0.0.1:9093/api/v2/alerts?active=true) sends
# startsAt like "2026-09-08T09:51:03.742Z" — ISO 8601 with .fff fraction and
# trailing Z. The parser's _slowburn_firing_seconds handles this via its
# s[:19] fallback, but no test locked the exact live shape. Two bugs (#4998,
# #5012) were timestamp-shape mismatches — lock it so a future ms regression
# is caught. Fixed past literal is fine: >1h elapsed is a lower-bound check.
reset_log
GH_LIST_JSON="[]"
live_amx_start="2026-09-08T09:51:03.742Z"
fire_slowburn "$live_amx_start"; rc=$?
[[ "$rc" == 0 ]] || fail "(f) live-AMX-ms-start dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
filed=$(grep -c '\] FILED ' "$PACKET_DIR/actions.log" || true)
[[ "$filed" == "1" ]] \
    || fail "(f) live-AMX-ms-start long-firing must FILE exactly one, got $filed: $(cat "$PACKET_DIR/actions.log")"
files=$(grep -c 'fleet-issue-file' "$FILE_CALLS" || true)
[[ "$files" == "1" ]] \
    || fail "(f) live-AMX-ms-start must invoke fleet-issue-file once, got $files: $(cat "$FILE_CALLS")"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] \
    || fail "(f) live-AMX-ms-start must NOT spawn a worker (skip-list stays), got $spawns"
disps=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
[[ "$disps" == "0" ]] || fail "(f) live-AMX-ms-start must NOT add a DISPATCH line, got $disps"
ok "(f) ISO 8601 start with fractional ms + Z (live AMX shape): FILED exactly one"

echo "OK: fleet-ops#4773 slowburn file-or-link both directions + idempotence pass"