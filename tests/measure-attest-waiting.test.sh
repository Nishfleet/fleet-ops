#!/usr/bin/env bash
# tests/measure-attest-waiting.test.sh
#
# fleet-ops#5870: the judge header must surface agent-ready/agent-blocked
# issues whose latest blocked-status comment mentions an attestation and that
# have had no orchestrator comment for >2h, as `attest-waiting: <n> [#a #b]`.
# Zero is the normal value; a gh failure is UNAVAILABLE, never a fabricated 0.
# measure.sh must carry the line (the new-measure: per fleet-ops#4460).
# fleet-ops#6257: historical attest comments are not a wait when a later
# decision-resolved: or a last blocked-on dep form is the newest state, or
# when the attest-referenced PR head is already merged. A latest-state
# attest request still waits.

set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
lib="$repo_root/lib/attest-waiting.sh"
measure="$repo_root/measure.sh"

[[ -f "$lib" ]] || fail "missing lib/attest-waiting.sh"
[[ -f "$measure" ]] || fail "missing measure.sh"
grep -q 'attest-waiting' "$measure" \
    || fail "measure.sh must source the attest-waiting detector"

scratch="$(mktemp -d -t attest-waiting.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

ATTEST_COMMENTS_5000='[{"at":"2026-09-12T03:00:00Z","who":"nishfleet-worker","assoc":"NONE","body":"needs an admin gate-integrity-attest on the PR; cannot self-attest"}]'
ATTEST_COMMENTS_5001='[{"at":"2026-09-12T02:00:00Z","who":"nishfleet-worker","assoc":"NONE","body":"needs an admin gate-integrity-attest on the PR"},{"at":"2026-09-12T08:00:00Z","who":"nish3451","assoc":"OWNER","body":"gate-integrity-attest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
ATTEST_COMMENTS_5002='[{"at":"2026-09-12T03:00:00Z","who":"nishfleet-worker","assoc":"NONE","body":"needs an admin gate-integrity-attest on the PR"}]'
ATTEST_LIST='[{"number":5000,"labels":[{"name":"agent-blocked"}]},{"number":5001,"labels":[{"name":"agent-blocked"}]},{"number":5002,"labels":[{"name":"agent-blocked"}]},{"number":5003,"labels":[{"name":"agent-ready"}]}]'

cat > "$scratch/gh" <<GH
#!/usr/bin/env bash
case "\$*" in
  *repos/Nishfleet/0509/issues/5000/comments*) echo '$ATTEST_COMMENTS_5000' ;;
  *repos/Nishfleet/0509/issues/5001/comments*) echo '$ATTEST_COMMENTS_5001' ;;
  *repos/Nishfleet/0509/issues/5002/comments*) echo '$ATTEST_COMMENTS_5002' ;;
  *repos/Nishfleet/0509/issues/5003/comments*) echo '[]' ;;
  *issue*list*) echo '$ATTEST_LIST' ;;
esac
GH
chmod +x "$scratch/gh"

# shellcheck disable=SC1090
source "$lib"

export PATH="$scratch:$PATH"
# shellcheck disable=SC2034
ATTEST_WAITING_NOW="2026-09-12T09:45:00Z"   # 5000: attest 03:00Z (~6.75h stale)

line=$(attest_waiting_line "Nishfleet/0509") || fail "detector must exit 0"
grep -q '^attest-waiting:' <<<"$line" || fail "no attest-waiting line: $line"

# 1. #5000: attest mention, no orchestrator reply -> waiting.
grep -q '#5000' <<<"$line" || fail "#5000 must be waiting: $line"
# 2. #5003 lists as agent-ready but never mentioned attest -> not waiting.
grep -q '#5003' <<<"$line" && fail "#5003 has no attest mention: $line"
# 3. #5001 was answered by the orchestrator (OWNER attest AFTER the request)
#    -> not waiting.
grep -q '#5001' <<<"$line" && fail "#5001 was attested after the request: $line"
# #5002 also waits; total must be exactly the waiting set (n=2).
grep -q '#5002' <<<"$line" || fail "#5002 must be waiting: $line"
grep -q '^attest-waiting: 2' <<<"$line" || fail "total must be 2: $line"
ok "waiting set matches the fixture (#5000 #5002): $line"

# 4. Fresh attest (< stale threshold) -> zero is the normal value.
line2=$(ATTEST_WAITING_NOW="2026-09-12T04:00:00Z" attest_waiting_line "Nishfleet/0509") \
    || fail "fresh detector run must exit 0"
[[ "$line2" == "attest-waiting: 0" ]] || fail "fresh attest (<2h) must be 0: $line2"
ok "zero is the normal value when the attest is fresh"

# 5. gh failure must not pretend success: the same line prints UNAVAILABLE.
cat > "$scratch/gh-fail" <<'GH'
#!/usr/bin/env bash
echo "gh: boom" >&2
exit 1
GH
chmod +x "$scratch/gh-fail"
mv "$scratch/gh" "$scratch/gh.ok"
mv "$scratch/gh-fail" "$scratch/gh"

line3=$(attest_waiting_line "Nishfleet/0509") || fail "gh failure path must still exit 0"
grep -q 'attest-waiting: UNAVAILABLE:gh-error' <<<"$line3" \
    || fail "gh failure must print UNAVAILABLE, never a 0: $line3"
ok "a gh failure flags UNAVAILABLE:gh-error (never a fabricated 0)"

# Restore the working stub for the fleet-ops#6257 newest-state pins.
mv "$scratch/gh.ok" "$scratch/gh"

# The any-state classifier that re-added needs-orchestrator lived in
# bin/blocked-reconcile (deleted 2026-09-18, second-cut-B). The churn cannot
# return through that binary.
[[ ! -e "$repo_root/bin/blocked-reconcile" ]] \
    || fail "bin/blocked-reconcile must stay deleted (fleet-ops#6257)"
ok "bin/blocked-reconcile stays deleted (the any-state churn engine is gone)"

# --- fleet-ops#6257: classify from newest state, not any-state -------------
# 2997: historical admin-attest comment, later blocked-checked echo, then a
# live dep blocked-on (Nishfleet/0509#3190) plus decision-resolved.
# Worker restamp of a dep form (not an OWNER comment). OWNER already
# suppresses via orch_ts; this pin is the any-state bug.
C_2997='[{"at":"2026-09-12T05:54:00Z","who":"nishfleet-worker","assoc":"NONE","body":"Blocked on the last gate: admin attestation is required; workers cannot self-attest."},{"at":"2026-09-12T09:51:00Z","who":"nishfleet-worker","assoc":"NONE","body":"blocked-checked: 2026-09-13T04:52:14Z still-blocked kind=orchestrator-attest age=36h remaining=Nishfleet/0509#3190 (open), orchestrator-attest"},{"at":"2026-09-13T01:59:00Z","who":"nishfleet-worker","assoc":"NONE","body":"blocked-on: Nishfleet/0509#3190\n"}]'
# Historical attest + a later decision-resolved: with no live blocked-on.
C_RESOLVED='[{"at":"2026-09-12T03:00:00Z","who":"nishfleet-worker","assoc":"NONE","body":"needs an admin gate-integrity-attest on the PR; cannot self-attest"},{"at":"2026-09-12T08:00:00Z","who":"nishfleet-worker","assoc":"NONE","body":"decision-resolved: attest landed; remaining wait is the dep.\n"}]'
# Latest state still requests an admin attest. Must stay waiting (#6257 must-not).
C_LIVE='[{"at":"2026-09-12T03:00:00Z","who":"nishfleet-worker","assoc":"NONE","body":"blocked-on: Nishfleet/0509#3190\n"},{"at":"2026-09-12T08:00:00Z","who":"nishfleet-worker","assoc":"NONE","body":"needs an admin gate-integrity-attest on the PR; cannot self-attest"}]'
# attest-requested for a head that already merged. Never actionable.
MERGED_SHA='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
OPEN_SHA='cccccccccccccccccccccccccccccccccccccccc'
C_MERGED="[{\"at\":\"2026-09-12T03:00:00Z\",\"who\":\"nishfleet-worker\",\"assoc\":\"NONE\",\"body\":\"attest-requested: ${MERGED_SHA}\nneeds an admin gate-integrity-attest; cannot self-attest\"}]"
C_OPEN="[{\"at\":\"2026-09-12T03:00:00Z\",\"who\":\"nishfleet-worker\",\"assoc\":\"NONE\",\"body\":\"attest-requested: ${OPEN_SHA}\nneeds an admin gate-integrity-attest; cannot self-attest\"}]"
LIST_6257='[{"number":2997,"labels":[{"name":"agent-blocked"}]},{"number":6001,"labels":[{"name":"agent-blocked"}]},{"number":6002,"labels":[{"name":"agent-blocked"}]},{"number":6003,"labels":[{"name":"agent-blocked"}]},{"number":6004,"labels":[{"name":"agent-blocked"}]}]'

cat > "$scratch/gh" <<GH
#!/usr/bin/env bash
case "\$*" in
  *repos/Nishfleet/0509/issues/2997/comments*) echo '$C_2997' ;;
  *repos/Nishfleet/0509/issues/6001/comments*) echo '$C_RESOLVED' ;;
  *repos/Nishfleet/0509/issues/6002/comments*) echo '$C_LIVE' ;;
  *repos/Nishfleet/0509/issues/6003/comments*) echo '$C_MERGED' ;;
  *repos/Nishfleet/0509/issues/6004/comments*) echo '$C_OPEN' ;;
  *repos/Nishfleet/0509/commits/${MERGED_SHA}/pulls*) echo '[{"merged_at":"2026-09-12T07:00:00Z","number":3145}]' ;;
  *repos/Nishfleet/0509/commits/${OPEN_SHA}/pulls*) echo '[{"merged_at":null,"number":9999}]' ;;
  *issue*list*) echo '$LIST_6257' ;;
esac
GH
chmod +x "$scratch/gh"

line4=$(ATTEST_WAITING_NOW="2026-09-13T12:00:00Z" attest_waiting_line "Nishfleet/0509") \
    || fail "6257 detector run must exit 0"
grep -q '^attest-waiting:' <<<"$line4" || fail "no attest-waiting line: $line4"

grep -q '#2997' <<<"$line4" && fail "0509#2997 last blocked-on is a dep form; historical attest must not wait: $line4"
ok "0509#2997 pin: last blocked-on dep form suppresses historical attest"

grep -q '#6001' <<<"$line4" && fail "later decision-resolved: must suppress historical attest: $line4"
ok "later decision-resolved: suppresses historical attest"

grep -q '#6002' <<<"$line4" || fail "latest state still requesting attest must wait: $line4"
ok "latest-state attest request still waits (must-not)"

grep -q '#6003' <<<"$line4" && fail "attest for a merged head must not wait: $line4"
ok "merged-head attest-requested is not actionable"

grep -q '#6004' <<<"$line4" || fail "attest-requested for an unmerged head must wait: $line4"
ok "unmerged-head attest-requested still waits"

grep -q '^attest-waiting: 2 ' <<<"$line4" \
    || fail "waiting set must be exactly #6002 #6004: $line4"
ok "6257 waiting set is the live requests only: $line4"
