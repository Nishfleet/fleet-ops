#!/usr/bin/env bash
# tests/hand-rolled-plumbing.test.sh
#
# Proves the mechanical hard-reject (fleet-ops #223, Nish 2026-08-26):
# presence of hand-rolled orchestration in a unified diff = REJECT, with
# the replacement primitive named. Pure-logic / tests / docs do not fire.
# The ledger line must appear verbatim on the conference packet.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
script="$repo_root/.github/scripts/hand-rolled-plumbing.mjs"
conf="$repo_root/.github/scripts/senior-panel-conference.mjs"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$script" ]] || fail "detector not found: $script"
node --check "$script" || fail "detector failed node --check"
node "$script" --help >/dev/null || fail "detector --help failed"

cd "$repo_root"

run() { printf '%s' "$1" | node "$script"; }

sleep_poll_diff='diff --git a/bin/poller.sh b/bin/poller.sh
--- a/bin/poller.sh
+++ b/bin/poller.sh
@@ -1,2 +1,6 @@
 #!/usr/bin/env bash
-echo start
+while true; do
+  check_status
+  sleep 5
+done
'

r="$(run "$sleep_poll_diff")"
printf '%s' "$r" | jq -e 'length >= 1' >/dev/null || fail "sleep-poll must fire"
printf '%s' "$r" | jq -e 'any(.id == "sleep-poll")' >/dev/null || fail "sleep-poll id"
printf '%s' "$r" | jq -e 'any(.replacement | test("timer|OnFailure|path unit"))' >/dev/null \
  || fail "sleep-poll must name a systemd replacement"
ok "sleep-poll loop -> finding with replacement named"

retry_diff='diff --git a/lib/retry.sh b/lib/retry.sh
--- a/lib/retry.sh
+++ b/lib/retry.sh
@@ -1,1 +1,5 @@
-true
+backoff=2
+for i in 1 2 3; do
+  try || sleep "$backoff"
+done
'

r="$(run "$retry_diff")"
printf '%s' "$r" | jq -e 'any(.id == "retry-backoff")' >/dev/null || fail "retry-backoff must fire"
printf '%s' "$r" | jq -e 'any(.replacement | test("Restart="))' >/dev/null \
  || fail "retry-backoff must name Restart="
ok "retry/backoff + sleep -> finding names Restart="

watchdog_diff='diff --git a/bin/pi-hang-watchdog b/bin/pi-hang-watchdog
--- /dev/null
+++ b/bin/pi-hang-watchdog
@@ -0,0 +1,4 @@
+#!/usr/bin/env bash
+while true; do
+  sleep 30
+done
'

r="$(run "$watchdog_diff")"
printf '%s' "$r" | jq -e 'any(.id == "watchdog")' >/dev/null || fail "watchdog path must fire"
printf '%s' "$r" | jq -e 'any(.replacement | test("WatchdogSec"))' >/dev/null \
  || fail "watchdog must name WatchdogSec="
ok "watchdog script with poll loop -> WatchdogSec="

daemon_diff='diff --git a/bin/queue-runner b/bin/queue-runner
--- /dev/null
+++ b/bin/queue-runner
@@ -0,0 +1,3 @@
+#!/usr/bin/env bash
+while true; do
+  drain_queue
+done
'

r="$(run "$daemon_diff")"
printf '%s' "$r" | jq -e 'any(.id == "dispatch-daemon")' >/dev/null || fail "while-true in bin/ must fire"
printf '%s' "$r" | jq -e 'any(.replacement | test("pi-systemd-run"))' >/dev/null \
  || fail "dispatch-daemon must name pi-systemd-run"
ok "while true in bin/ -> pi-systemd-run"

# Tests and docs are out of scope (pure-logic / commentary).
tests_diff='diff --git a/tests/foo.test.sh b/tests/foo.test.sh
--- a/tests/foo.test.sh
+++ b/tests/foo.test.sh
@@ -0,0 +1,4 @@
+while true; do
+  sleep 5
+done
'
r="$(run "$tests_diff")"
[[ "$(printf '%s' "$r" | jq -r 'length')" == "0" ]] || fail "tests/ must not fire"
ok "tests/ sleep-poll is ignored"

docs_diff='diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -0,0 +1,2 @@
+while true; do sleep 5; done
+backoff retry cooldown watchdog
'
r="$(run "$docs_diff")"
[[ "$(printf '%s' "$r" | jq -r 'length')" == "0" ]] || fail "docs must not fire"
ok "markdown commentary is ignored"

# Comment-only mention of sleep in a real file is ignored.
comment_diff='diff --git a/bin/parse.sh b/bin/parse.sh
--- a/bin/parse.sh
+++ b/bin/parse.sh
@@ -0,0 +1,2 @@
+# do not sleep 5 in a while loop; use a timer
+echo parse
'
r="$(run "$comment_diff")"
[[ "$(printf '%s' "$r" | jq -r 'length')" == "0" ]] || fail "comment-only must not fire"
ok "comment-only sleep mention is ignored"

# Pure parse/compute with no loop+sleep is clean.
clean_diff='diff --git a/bin/parse.sh b/bin/parse.sh
--- a/bin/parse.sh
+++ b/bin/parse.sh
@@ -0,0 +1,3 @@
+#!/usr/bin/env bash
+jq -r .name
+echo done
'
r="$(run "$clean_diff")"
[[ "$(printf '%s' "$r" | jq -r 'length')" == "0" ]] || fail "pure parse must be clean"
ok "pure-logic parse script is clean"

# Conference: ledger line is on every packet; plumbing diff REJECTS even
# when the stub outcome is approve.
packet_clean='{"repo":"Nishfleet/fleet-ops","prNumber":223,"prTitle":"t","prBody":"b","diff":"","changedFiles":["docs/a.md"],"additions":1,"deletions":0,"closingIssueNumber":223,"closingIssueBody":"i","ciCheckRuns":[],"triggers":["control-plane-paths"],"headSha":"abc123"}'
r="$(printf '%s' "$packet_clean" | node "$conf")"
ban="$(printf '%s' "$r" | jq -r '.packet.handBuiltPlumbingBan')"
printf '%s' "$ban" | grep -q "HARD REJECTION CRITERION (Nish, 2026-08-26, ledgered 'hand-built plumbing BAN')" \
  || fail "packet must include the ledger line verbatim"
printf '%s' "$ban" | grep -q "presence of the pattern = REJECT with the replacement primitive named" \
  || fail "packet ledger line is truncated"
printf '%s' "$r" | jq -r '.commentBody' | grep -q '<!-- senior-panel:abc123 -->' \
  || fail "comment must be hash-bounded with head sha"
ok "packet carries ledger line verbatim; comment is hash-bounded"

# A sleep-poll diff REJECTS even with --outcome=approve (mechanical, not a vote).
packet_dirty="$(jq -nc --arg diff "$sleep_poll_diff" \
  '{repo:"Nishfleet/fleet-ops",prNumber:223,prTitle:"t",prBody:"b",diff:$diff,changedFiles:["bin/poller.sh"],additions:4,deletions:1,closingIssueNumber:223,closingIssueBody:"i",ciCheckRuns:[],triggers:["control-plane-paths"],headSha:"deadbeef"}')"
r="$(printf '%s' "$packet_dirty" | node "$conf" --outcome=approve)"
[[ "$(printf '%s' "$r" | jq -r '.result')" == "REJECT" ]] \
  || fail "plumbing diff must REJECT even when stub would approve: $(printf '%s' "$r" | jq -c '{result,mode}')"
printf '%s' "$r" | jq -e '.packet.plumbingFindings | length >= 1' >/dev/null \
  || fail "findings must be on the packet"
printf '%s' "$r" | jq -r '.commentBody' | grep -q 'HARD REJECTION (not a judgment call)' \
  || fail "comment must say mechanical hard rejection"
printf '%s' "$r" | jq -r '.commentBody' | grep -q 'timer\|OnFailure\|path unit' \
  || fail "comment must name the replacement primitive"
ok "plumbing diff mechanically REJECTS; stub approve cannot override"

echo "OK: hand-rolled plumbing detector + conference hard-reject"
