#!/usr/bin/env bash
# tests/dispatch-ledger-fixture-sweep.test.sh
#
# Proves bin/dispatch-ledger-fixture-sweep (fleet-ops#2768):
#   - before sweep, 3+ open fixture rows exist for the fixture alertnames
#   - after sweep, ZERO open fixture rows for those alertnames (the issue's
#     acceptance metric: terminal != true on alert-repair-<fixture>- rows)
#   - ALL fixture rows are marked terminal (open AND already-closed rows) with
#     terminal_reason="fixture_alertname_no_prometheus_rule"
#   - non-fixture rows are byte-identical after the sweep (no collateral)
#   - a malformed line survives untouched (sweep cannot brick the ledger)
#   - a pre-sweep backup is created (rollback provision)
#   - the sweep is idempotent: a second run marks nothing new
#
# Runs entirely offline against a scratch ledger; never touches
# $AGENT_STATE/dispatch-ledger.jsonl.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
sweep="$repo_root/bin/dispatch-ledger-fixture-sweep"
FIXTURE_JQ='( .unit // .packet_path // "" ) | test("alert-repair-(NoClassParkAlert|ClassExpiredAlert|NoParkKeyAlert)-")'

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

echo "=== sweep: $sweep ==="
[[ -x "$sweep" ]] || fail "dispatch-ledger-fixture-sweep not executable"
command -v jq >/dev/null 2>&1 || fail "jq is required"

scratch="$(mktemp -d -t dispatch-sweep-test.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

LEDGER="$scratch/dispatch-ledger.jsonl"

# --- hermetic fixture: 4 open fixture rows, 1 closed fixture row,
#     2 non-fixture rows (1 open, 1 closed), 1 malformed line. --------------
cat >"$LEDGER" <<'JSON'
{"id":"fx-open-1","ts":"2026-08-31T11:17:28Z","unit":"alert-repair-NoClassParkAlert-20260831T111728Z","packet_path":"/state/dispatch-packets/alert-repair-NoClassParkAlert-20260831T111728Z-111.md","status":"open","retries":0}
{"id":"fx-open-2","ts":"2026-08-31T11:17:57Z","unit":"alert-repair-ClassExpiredAlert-20260831T111757Z","packet_path":"/state/dispatch-packets/alert-repair-ClassExpiredAlert-20260831T111757Z-222.md","status":"open","retries":0}
{"id":"fx-open-3","ts":"2026-08-31T11:17:57Z","unit":"alert-repair-NoParkKeyAlert-20260831T111757Z","packet_path":"/state/dispatch-packets/alert-repair-NoParkKeyAlert-20260831T111757Z-333.md","status":"open","retries":0}
{"id":"fx-open-4","ts":"2026-09-01T15:46:23Z","unit":"alert-repair-NoClassParkAlert-20260901T154623Z","packet_path":"/state/dispatch-packets/alert-repair-NoClassParkAlert-20260901T154623Z-444.md","status":"open","retries":0}
{"id":"fx-closed-1","ts":"2026-08-31T11:17:28Z","unit":"alert-repair-NoClassParkAlert-20260831T111728Z-r1","packet_path":"/state/dispatch-packets/alert-repair-NoClassParkAlert-20260831T111728Z-555.md","status":"completed","verdict":"success","closed_ts":"2026-08-31T11:52:05Z","retries":1}
{"id":"real-open-1","ts":"2026-09-02T15:44:12Z","unit":"alert-repair-FleetSeatComebackOverdue-20260902T154412Z","packet_path":"/state/dispatch-packets/alert-repair-FleetSeatComebackOverdue-20260902T154412Z-666.md","status":"open","retries":0}
{"id":"real-closed-1","ts":"2026-09-02T15:44:12Z","unit":"alert-repair-FleetSeatComebackOverdue-20260902T154412Z-r1","packet_path":"/state/dispatch-packets/alert-repair-FleetSeatComebackOverdue-20260902T154412Z-777.md","status":"completed","verdict":"success","closed_ts":"2026-09-02T15:52:11Z","retries":1}
{"id":"no-unit-row","ts":"2026-08-31T18:22:37Z","packet_path":"/state/salvage/some-packet.md","status":"salvaged","salvage_status":"pushed"}
JSON

open_fixture_rows() {
    jq -c "select($FIXTURE_JQ) | select(.terminal != true)" "$1" | wc -l
}
status_open_fixture_rows() {
    jq -c "select($FIXTURE_JQ) | select(.status == \"open\")" "$1" | wc -l
}

before_metric="$(open_fixture_rows "$LEDGER")"
before_status_open="$(status_open_fixture_rows "$LEDGER")"
echo "before: open-fixture(terminal!=true)=$before_metric status-open=$before_status_open"
[ "$before_metric" -ge 3 ] || fail "expected 3+ open fixture rows before sweep, got $before_metric"
[ "$before_status_open" -ge 3 ] || fail "expected 3+ status-open fixture rows before sweep, got $before_status_open"

# capture non-fixture rows + malformed line verbatim for the untouched check
grep -v 'alert-repair-\(NoClassParkAlert\|ClassExpiredAlert\|NoParkKeyAlert\)-' "$LEDGER" > "$scratch/nonfixture-before.txt"

out="$(FLEET_DISPATCH_LEDGER="$LEDGER" bash "$sweep")"
echo "$out"
echo "$out" | grep -q "marked=" || fail "sweep printed no marked= summary"
echo "$out" | grep -q "marked=5" || fail "expected 5 rows marked, got: $out"

backup="$(echo "$out" | sed -n 's/^backup: //p')"
[ -n "$backup" ] && [ -f "$backup" ] || fail "pre-sweep backup missing: $backup"
diff -q "$LEDGER" "$backup" >/dev/null 2>&1 && fail "backup identical to ledger (expected pre-mutation copy)" \
    || ok "pre-sweep backup differs from swept ledger (rollback provision present)"

after_metric="$(open_fixture_rows "$LEDGER")"
after_status_open="$(status_open_fixture_rows "$LEDGER")"
echo "after: open-fixture(terminal!=true)=$after_metric status-open=$after_status_open"
[ "$after_metric" -eq 0 ] || fail "expected ZERO open fixture rows after sweep, got $after_metric"
ok "fixture rows swept: $before_metric -> $after_metric (terminal!=true)"

# the sweep must NOT touch `status` (the issue marks terminal only; the
# completion-canary's last-per-id view must still resolve to the closing
# line). Prove original statuses survive.
orig_status="$(jq -c "select(.id == \"fx-open-1\") | .status" "$LEDGER")"
[ "$orig_status" = '"open"' ] || fail "sweep rewrote status of an open fixture row: $orig_status"
orig_status2="$(jq -c "select(.id == \"fx-closed-1\") | .status" "$LEDGER")"
[ "$orig_status2" = '"completed"' ] || fail "sweep rewrote status of a closed fixture row: $orig_status2"
ok "status field untouched (open row still open, closed row still completed)"

# every fixture row carries the terminal marker + reason
bad_marker="$(jq -c "select($FIXTURE_JQ) | select(.terminal != true or .terminal_reason != \"fixture_alertname_no_prometheus_rule\" or (.terminal_ts | length) == 0)" "$LEDGER" | wc -l)"
[ "$bad_marker" -eq 0 ] || fail "$bad_marker fixture rows lack the full terminal marker"
ok "all fixture rows carry terminal=true + terminal_reason + terminal_ts"

# non-fixture rows + malformed line untouched (byte-identical)
grep -v 'alert-repair-\(NoClassParkAlert\|ClassExpiredAlert\|NoParkKeyAlert\)-' "$LEDGER" > "$scratch/nonfixture-after.txt"
diff -q "$scratch/nonfixture-before.txt" "$scratch/nonfixture-after.txt" >/dev/null \
    || fail "non-fixture rows changed by the sweep"
ok "non-fixture rows and malformed line untouched"

# idempotency: second run marks nothing new, still exits 0
out2="$(FLEET_DISPATCH_LEDGER="$LEDGER" bash "$sweep")"
echo "$out2"
echo "$out2" | grep -q "marked=0" || fail "second run was not a no-op: $out2"
ok "idempotent re-run marks nothing new"

# --- resilience mini-scenario: a malformed line must survive untouched, and
#     the file must not be truncated (line count preserved). ----------------
LEDGER2="$scratch/dispatch-ledger2.jsonl"
cat >"$LEDGER2" <<'JSON'
{"id":"fx-open-5","ts":"2026-09-01T15:46:23Z","unit":"alert-repair-NoParkKeyAlert-20260901T154623Z","packet_path":"/state/dispatch-packets/alert-repair-NoParkKeyAlert-20260901T154623Z-888.md","status":"open","retries":0}
{"id":"malformed-line","ts":"2026-08-31","status":"open","unit":
JSON
before_lines="$(wc -l < "$LEDGER2")"
out3="$(FLEET_DISPATCH_LEDGER="$LEDGER2" bash "$sweep")"
echo "$out3"
echo "$out3" | grep -q "marked=1" || fail "resilience run did not mark the valid fixture row: $out3"
echo "$out3" | grep -q "malformed_skipped=1" || fail "malformed line not counted as skipped: $out3"
after_lines="$(wc -l < "$LEDGER2")"
[ "$after_lines" -eq "$before_lines" ] || fail "ledger truncated by malformed line ($before_lines -> $after_lines)"
grep -q '"malformed-line"' "$LEDGER2" || fail "malformed line lost by the sweep"
ok "malformed line survives; ledger not truncated (lines=$after_lines)"

echo "ALL PASS"