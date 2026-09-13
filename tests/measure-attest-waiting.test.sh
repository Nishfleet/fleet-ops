#!/usr/bin/env bash
# tests/measure-attest-waiting.test.sh
#
# fleet-ops#5870: the judge header must surface agent-ready/agent-blocked
# issues whose latest blocked-status comment mentions an attestation and that
# have had no orchestrator comment for >2h, as `attest-waiting: <n> [#a #b]`.
# Zero is the normal value; a gh failure is UNAVAILABLE, never a fabricated 0.
# measure.sh must carry the line (the new-measure: per fleet-ops#4460).

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
