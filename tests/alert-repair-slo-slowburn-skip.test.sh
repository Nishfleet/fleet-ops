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
#   3. (fleet-ops#4773) FleetSloSeatAvailSlowBurn firing >1h auto-files
#      exactly one `critical-path` issue when no claim exists (the create
#      carries `--label critical-path`); LINKS + posts exactly one heartbeat
#      (and files nothing) when a labelled claim carrying the `[signal]`
#      key exists; is idempotent across a second tick; and plain-SKIPs under
#      1h. Index lookup, epoch, ISO and live ms-fraction+Z start shapes are
#      all locked.
#   4. (fleet-ops#4773) the two shapes that made the shipped terminus dead:
#      the LIVE DECOY (the open #4773 meta-issue the signal search really
#      returns — an `agent-in-progress` label, no `critical-path` label, no
#      `[signal]` marker in its title) is never linked, never heartbeated
#      and never suppresses the file path (and the search is narrowed
#      server-side with `--label critical-path`); and the DEDUPE COLLAPSE
#      (fleet-issue-file dedupes onto that decoy and prints its URL) logs
#      `FILED-LINK-MISMATCH`, writes no `] FILED ` terminus line, and is
#      reported as the skip-error it is.
#   5. (fleet-ops#4773) the auto-filed terminus is CLAIMABLE: the body the
#      dispatcher really passed (`--body`, captured verbatim by the mock)
#      passes `lib/agent-ready-spec-gate.py check-body --repo fleet-ops`
#      with `SPEC-GATE: ok`. The create's `--title` and `--label critical-path`
#      are asserted individually, from the REAL argv (not a fixture).
#   6. (fleet-ops#4773) fail-closed/robustness: an unreadable `gh issue view`
#      (rc=1, no stdout) is FILED-LINK-MISMATCH with `title='<unavailable>'`,
#      no FILED, skip-error; a non-list `gh issue list` payload and a missing
#      `gh` binary (OSError) never traceback.
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
# Proves BOTH directions + idempotence + the two terminus-collapsing shapes:
#   (a) firing >1h + no existing claim -> files exactly ONE, no spawn.
#   (b) firing >1h + live claim -> LINKS (no file), heartbeat, idempotent
#       across a 2nd tick.
#   (c) firing <=1h -> plain SKIP, no file (no premature filing).
#   (d) multi-alert index lookup, (e) ISO start, (f) live ms+Z ISO start.
#   (g) the LIVE DECOY (#4773) is never linked/commented and never suppresses
#       the file path; (h) the DEDUPE COLLAPSE logs FILED-LINK-MISMATCH, not
#       FILED. Both are the reason fleet-ops#4773 exists.
#   (i) an unreadable read-back (gh issue view rc=1) is never FILED; (j) the
#       body really filed passes the admission spec gate; (k) a non-list gh
#       search response and (l) a missing gh binary stay traceback-free.
# The skip-list entry STAYS throughout (no repair worker spawned).
# ============================================================================

slowburn="FleetSloSeatAvailSlowBurn"

# Mock gh + fleet-issue-file on PATH. gh records EVERY call; fleet-issue-file
# prints a /issues/<num> URL on success and records the file call.
#
# fleet-ops#4773: the mock gh is label-aware and answers BOTH verbs the
# dispatcher really uses:
#   `gh issue list ... --json number,title,labels` -> the canned GH_LIST_JSON
#   `gh issue view <n> ... --json title --jq .title` -> the canned title for
#      <n> from the GH_TITLES registry (rc=1 when unknown, like real gh).
# It deliberately returns the canned list verbatim even when the caller asked
# for `--label critical-path`: a real `gh issue list --search <hyphenated
# signal>` fuzzy-matches on tokenized text and returns non-matching issues
# (live, the #4773 meta-issue), so the dispatcher's OWN re-check is what the
# tests must exercise. The `--label critical-path` flag is asserted from the
# recorded call instead.
mock_bin2="$scratch/mock-bin2"
mkdir -p "$mock_bin2"
GH_CALLS="$scratch/gh-calls.log"
FILE_CALLS="$scratch/file-calls.log"
GH_TITLES="$scratch/gh-titles.tsv"
# What the fleet-issue-file mock really received on the create call
# (fleet-ops#4773): the test binds its title/label/body assertions and the
# spec-gate run to these, never to a hand-written fixture.
FILE_TITLE="$scratch/filed-title.txt"
FILE_BODY="$scratch/filed-body.txt"
FILE_LABEL="$scratch/filed-label.txt"
export GH_CALLS FILE_CALLS GH_TITLES FILE_TITLE FILE_BODY FILE_LABEL
: >"$GH_CALLS"
: >"$FILE_CALLS"
: >"$GH_TITLES"
: >"$FILE_TITLE"
: >"$FILE_BODY"
: >"$FILE_LABEL"

# `gh issue list --search <signal>` returns the canned JSON; the test
# toggles GH_LIST_JSON between "[]" (no existing) and a real issue.
GH_LIST_JSON="[]"
export GH_LIST_JSON
# The number the fleet-issue-file mock claims to have filed. 5555 is
# DELIBERATELY distinct from the #4773 decoy so a real filing can never be
# confused with a link to the meta-issue.
FILE_NUM=5555
export FILE_NUM

# set_gh_issues <list-json> [<number>|<title> ...]
# Writes the canned `gh issue list` result AND the NUMBER<TAB>TITLE registry
# that `gh issue view` and the fleet-issue-file mock read back, so the list
# entry and its viewable title can never drift apart.
set_gh_issues() {
    GH_LIST_JSON="$1"; shift
    export GH_LIST_JSON
    : >"$GH_TITLES"
    local pair
    for pair in "$@"; do
        printf '%s\t%s\n' "${pair%%|*}" "${pair#*|}" >>"$GH_TITLES"
    done
}

# NOTE (fleet-ops#4773): there is deliberately NO `filed_title` fixture. The
# fleet-issue-file mock parses the title it hands back out of the ACTUAL
# `--title` argument `_slowburn_file` passed, so the mock cannot agree with
# itself while the real create drifts.
#
# A live claim the link path must pick: same signal marker, and the
# `critical-path` label that says "this really is a repair-rung claim".
claim_num="4242"
claim_title="alarm: FleetSloSeatAvailSlowBurn [slo/seat-availability-slowburn]"
claim_json="[{\"number\":${claim_num},\"title\":\"${claim_title}\",\"labels\":[{\"name\":\"critical-path\"}]}]"
# The LIVE DECOY: the real #4773 meta-issue, read live with
# `gh issue view 4773 -R Nishfleet/fleet-ops --json title,labels`. Its title
# names the alert but carries NO `[signal]` marker, and its only label is
# `agent-in-progress` — not `critical-path`. A signal search still returns
# it (tokenized fuzzy match), which is what broke the shipped terminus.
decoy_num="4773"
decoy_title="FleetSloSeatAvailSlowBurn should auto-file a repair-rung claim after 1h (follow-up to #4639)"
decoy_json="[{\"number\":${decoy_num},\"title\":\"${decoy_title}\",\"labels\":[{\"name\":\"agent-in-progress\"}]}]"

cat >"$mock_bin2/gh" <<'GH'
#!/usr/bin/env bash
# Mock gh. Records every call, then answers the dispatcher's two verbs.
echo "gh $*" >> "${GH_CALLS:-/dev/null}"
case "${1:-} ${2:-}" in
    "issue list")
        printf '%s' "${GH_LIST_JSON:-[]}"
        ;;
    "issue comment")
        : # heartbeat comment on the linked issue — best effort, exit 0.
        ;;
    "issue close")
        # fleet-ops#5272 observe-to-close: record the close; GH_CLOSE_RC=1
        # simulates a failed close (best-effort, terminus left open).
        if [[ -n "${GH_CLOSE_RC:-}" ]]; then
            exit "$GH_CLOSE_RC"
        fi
        ;;
    "issue view")
        # `gh issue view <n> -R <repo> --json title --jq .title`
        n="${3:-}"
        title=""
        if [[ "$n" =~ ^[0-9]+$ && -s "${GH_TITLES:-/dev/null}" ]]; then
            title="$(awk -F'\t' -v n="$n" \
                '$1 == n { print substr($0, index($0, "\t") + 1); exit }' \
                "${GH_TITLES}")"
        fi
        # An unknown number is a real failure, exactly like real gh: the
        # dispatcher must never treat an unreadable title as a filing.
        [[ -n "$title" ]] || exit 1
        printf '%s\n' "$title"
        ;;
esac
exit 0
GH
chmod +x "$mock_bin2/gh"

cat >"$mock_bin2/fleet-issue-file" <<'FILE'
#!/usr/bin/env bash
# Mock fleet-issue-file. Records the call, then prints the URL of the issue
# it claims to have filed (FILE_NUM; defaults to 5555, never the #4773 decoy).
#
# fleet-ops#4773: the title, label and body the mock reports/captures are
# parsed out of the ACTUAL argv the dispatcher passed — not a hand-written
# fixture — so every FILED assertion binds to what `_slowburn_file` really
# sent. A dispatcher that drops the `[{signal}]` marker from the title or the
# `critical-path` label fails, instead of the mock agreeing with itself.
echo "fleet-issue-file $*" >> "${FILE_CALLS:-/dev/null}"
title=""; body=""; label=""; prev=""
for a in "$@"; do
    case "$prev" in
        --title) title="$a" ;;
        --body)  body="$a" ;;
        --label) label="$a" ;;
    esac
    prev="$a"
done
printf '%s' "$title" > "${FILE_TITLE:-/dev/null}"
printf '%s' "$body"  > "${FILE_BODY:-/dev/null}"
printf '%s' "$label" > "${FILE_LABEL:-/dev/null}"
num="${FILE_NUM:-5555}"
echo "https://github.com/Nishfleet/fleet-ops/issues/${num}"
# Register the passed title as that number's title, so the read-back
# (`gh issue view`) returns exactly what the create call really sent.
# FILE_REGISTER_TITLE=0 means "the create did NOT produce a readable new
# issue": fleet-issue-file deduped onto an existing issue and printed that
# issue's URL (case (h)), or the pointer cannot be read back (case (i)).
if [[ -z "${FILE_REGISTER_TITLE:-}" && -n "$title" ]]; then
    printf '%s\t%s\n' "$num" "$title" >> "${GH_TITLES:-/dev/null}"
fi
exit 0
FILE
chmod +x "$mock_bin2/fleet-issue-file"

# The gh binary the dispatcher is told to use; case (l) points it at a path
# that does not exist to prove a failed exec is a failed lookup, not a crash.
sb_gh="$mock_bin2/gh"

reset_log() {
    : >"$PACKET_DIR/actions.log"; : >"$GH_CALLS"; : >"$FILE_CALLS"
    : >"$FILE_TITLE"; : >"$FILE_BODY"; : >"$FILE_LABEL"
}

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
    GH="$sb_gh" \
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
# Explicitly reset the canned signal search (rather than relying on the
# file's ordering) so this case cannot be perturbed by a later one.
reset_log
set_gh_issues "[]"
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
# Under the threshold the claim lookup must not even be consulted.
lists=$(grep -c 'gh issue list' "$GH_CALLS" || true)
[[ "$lists" == "0" ]] \
    || fail "(c) short-firing must not run the claim search, got $lists: $(cat "$GH_CALLS")"
ok "(c) firing <=1h: SKIP reason=skip-list, no file, no link, no spawn"

# --- (a) firing >1h + no existing claim: files exactly ONE, no spawn ---------
# fleet-ops#4773: the create must carry `--label critical-path`, and the
# dispatcher must read the RETURNED issue's title back through `gh issue view`
# before it may log FILED. The mock files 5555 (not the #4773 decoy).
reset_log
set_gh_issues "[]"
FILE_NUM=5555; export FILE_NUM
fire_slowburn "$two_h_ago"; rc=$?
[[ "$rc" == 0 ]] || fail "(a) long-firing dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
filed=$(grep -c '\] FILED ' "$PACKET_DIR/actions.log" || true)
[[ "$filed" == "1" ]] \
    || fail "(a) long-firing + no existing must FILE exactly one, got $filed: $(cat "$PACKET_DIR/actions.log")"
filed5555=$(grep -c '\] FILED .*issue=#5555' "$PACKET_DIR/actions.log" || true)
[[ "$filed5555" == "1" ]] \
    || fail "(a) FILED line must record the genuinely filed issue #5555: $(cat "$PACKET_DIR/actions.log")"
files=$(grep -c 'fleet-issue-file' "$FILE_CALLS" || true)
[[ "$files" == "1" ]] \
    || fail "(a) must invoke fleet-issue-file exactly once, got $files: $(cat "$FILE_CALLS")"
grep -q -- '--label critical-path' "$FILE_CALLS" \
    || fail "(a) the create must carry --label critical-path: $(cat "$FILE_CALLS")"
# fleet-ops#4773 (finding C): assert the label and the `[{signal}]` title
# marker INDIVIDUALLY, from the argv the dispatcher really passed (the mock
# parsed `--label`/`--title` out of "$@"), so a mutant dropping EITHER one
# fails on its own assertion instead of hiding behind a fixture.
[[ "$(cat "$FILE_LABEL")" == "critical-path" ]] \
    || fail "(a) the create's --label must be exactly critical-path, got '$(cat "$FILE_LABEL")'"
case "$(cat "$FILE_TITLE")" in
    *"[slo/seat-availability-slowburn]") ;;
    *) fail "(a) the create title must carry the [signal] marker: $(cat "$FILE_TITLE")" ;;
esac
case "$(cat "$FILE_TITLE")" in
    "alarm: "*) ;;
    *) fail "(a) the create title must keep the alarm: prefix: $(cat "$FILE_TITLE")" ;;
esac
grep -q 'issue list .*--label critical-path' "$GH_CALLS" \
    || fail "(a) the signal search must be narrowed server-side with --label critical-path: $(cat "$GH_CALLS")"
grep -q 'issue view 5555' "$GH_CALLS" \
    || fail "(a) the returned issue's title must be verified via gh issue view: $(cat "$GH_CALLS")"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] \
    || fail "(a) must NOT spawn a worker (skip-list stays), got $spawns"
disps=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
[[ "$disps" == "0" ]] || fail "(a) must NOT add a DISPATCH line, got $disps"
ok "(a) firing >1h + no existing claim: FILED exactly one #5555 with --label critical-path, verified by issue view, no spawn, no DISPATCH"

# --- (b) firing >1h + live claim: LINKS, no file, idempotent across 2nd tick --
# The claim is the REAL shape: the `critical-path` label AND the `[signal]`
# marker in the title. Anything less must not be treated as a claim (cases
# (g)/(h) prove the negative).
reset_log
set_gh_issues "$claim_json"
fire_slowburn "$two_h_ago"; rc=$?
[[ "$rc" == 0 ]] || fail "(b) link dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
links=$(grep -c '\] LINK ' "$PACKET_DIR/actions.log" || true)
[[ "$links" == "1" ]] \
    || fail "(b) must LINK exactly once, got $links: $(cat "$PACKET_DIR/actions.log")"
grep -q "\] LINK .*issue=#${claim_num}" "$PACKET_DIR/actions.log" \
    || fail "(b) LINK line must record issue #${claim_num}: $(cat "$PACKET_DIR/actions.log")"
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
ok "(b) firing >1h + live claim: LINK #${claim_num} + heartbeat, no file; idempotent across 2nd tick"

# --- (d) multi-alert: SlowBurn at index 2 uses ITS start, not index 1's ------
# A non-skip-listed decoy at index 1 fires 10m ago; SlowBurn at index 2 fires
# 2h ago. The skip loop continues past the decoy (not in SKIP_SET), reaches
# SlowBurn, and must use SlowBurn's start (2h -> past threshold -> FILE), NOT
# the decoy's (10m -> skip-short). Proves the index lookup fix.
reset_log
set_gh_issues "[]"
FILE_NUM=5555; export FILE_NUM
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
set_gh_issues "[]"
FILE_NUM=5555; export FILE_NUM
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
set_gh_issues "[]"
FILE_NUM=5555; export FILE_NUM
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

# --- (g) THE LIVE DECOY: the real #4773 meta-issue is never the terminus ------
# THE PRODUCTION SHAPE this issue exists for. `gh issue list --search
# slo/seat-availability-slowburn` really returns #4773 — an open issue whose
# title names the alert but carries no `[signal]` marker and whose only label
# is `agent-in-progress`, not `critical-path`. The old dispatcher accepted it
# as the repair terminus, so it logged LINK instead of ever filing. It must
# now be REJECTED: no LINK, no heartbeat comment on it, and the FILE path must
# still run and land on the genuine #5555. The search must also be narrowed
# server-side with `--label critical-path`.
reset_log
set_gh_issues "$decoy_json"
FILE_NUM=5555; export FILE_NUM
fire_slowburn "$two_h_ago"; rc=$?
[[ "$rc" == 0 ]] || fail "(g) decoy dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
links=$(grep -c '\] LINK ' "$PACKET_DIR/actions.log" || true)
[[ "$links" == "0" ]] \
    || fail "(g) the #4773 decoy must NOT be linked, got $links LINK lines: $(cat "$PACKET_DIR/actions.log")"
comments=$(grep -c 'issue comment' "$GH_CALLS" || true)
[[ "$comments" == "0" ]] \
    || fail "(g) must NOT post a heartbeat comment on the decoy, got $comments: $(cat "$GH_CALLS")"
grep -q 'issue list .*--label critical-path' "$GH_CALLS" \
    || fail "(g) the signal search must carry --label critical-path: $(cat "$GH_CALLS")"
files=$(grep -c 'fleet-issue-file' "$FILE_CALLS" || true)
[[ "$files" == "1" ]] \
    || fail "(g) the decoy must NOT suppress the file path, expected 1 fleet-issue-file call, got $files: $(cat "$FILE_CALLS")"
filed=$(grep -c '\] FILED ' "$PACKET_DIR/actions.log" || true)
[[ "$filed" == "1" ]] \
    || fail "(g) must still FILE exactly one past the decoy, got $filed: $(cat "$PACKET_DIR/actions.log")"
filed5555=$(grep -c '\] FILED .*issue=#5555' "$PACKET_DIR/actions.log" || true)
[[ "$filed5555" == "1" ]] \
    || fail "(g) the FILED terminus must be #5555, not the decoy: $(cat "$PACKET_DIR/actions.log")"
decoy_termini=$(grep -c 'issue=#4773' "$PACKET_DIR/actions.log" || true)
[[ "$decoy_termini" == "0" ]] \
    || fail "(g) the live decoy #4773 must appear in no LINK/FILED/WARN line, got $decoy_termini: $(cat "$PACKET_DIR/actions.log")"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] || fail "(g) must NOT spawn, got $spawns"
disps=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
[[ "$disps" == "0" ]] || fail "(g) must NOT add a DISPATCH line, got $disps"
ok "(g) LIVE DECOY #4773 (agent-in-progress, no [signal] marker) rejected: no link, no comment, file path still ran -> #5555"

# --- (h) THE DEDUPE COLLAPSE: a decoy pointer is never reported as FILED -----
# The other half of the live bug. fleet-issue-file dedupes by token overlap and
# may COMMENT on the decoy instead of creating an issue, printing the DECOY's
# URL (`/issues/4773`, live dup score 1.00) — a pointer, not a filing. The
# dispatcher must read that issue's title back, see no `[signal]` marker, log a
# loud FILED-LINK-MISMATCH, write NO `] FILED ` terminus line, and report
# skip-error. The FILED assertion matches `] FILED ` (trailing space), never a
# bare `FILED`, so the LOUD FILED-LINK-MISMATCH text cannot satisfy it.
reset_log
set_gh_issues "$decoy_json" "${decoy_num}|${decoy_title}"
FILE_NUM="$decoy_num"; export FILE_NUM
# The create deduped onto an existing issue and printed ITS url: nothing new
# was created, so nothing new is registered for that number.
FILE_REGISTER_TITLE=0; export FILE_REGISTER_TITLE
fire_slowburn "$two_h_ago"; rc=$?
unset FILE_REGISTER_TITLE
[[ "$rc" == 0 ]] || fail "(h) dedupe-collapse dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
mismatch=$(grep -c 'FILED-LINK-MISMATCH' "$PACKET_DIR/actions.log" || true)
[[ "$mismatch" == "1" ]] \
    || fail "(h) must log FILED-LINK-MISMATCH exactly once, got $mismatch: $(cat "$PACKET_DIR/actions.log")"
grep -q "FILED-LINK-MISMATCH.*issue=#${decoy_num}" "$PACKET_DIR/actions.log" \
    || fail "(h) the mismatch line must name the refused issue #${decoy_num}: $(cat "$PACKET_DIR/actions.log")"
filed_lines=$(grep -c '\] FILED ' "$PACKET_DIR/actions.log" || true)
[[ "$filed_lines" == "0" ]] \
    || fail "(h) a decoy pointer must NOT be reported as a FILED terminus, got $filed_lines: $(cat "$PACKET_DIR/actions.log")"
links=$(grep -c '\] LINK ' "$PACKET_DIR/actions.log" || true)
[[ "$links" == "0" ]] \
    || fail "(h) a decoy pointer must NOT become a LINK either, got $links: $(cat "$PACKET_DIR/actions.log")"
warns=$(grep -c '\] WARN .*auto-file failed' "$PACKET_DIR/actions.log" || true)
[[ "$warns" == "1" ]] \
    || fail "(h) a refused terminus must be reported as skip-error/WARN, got $warns: $(cat "$PACKET_DIR/actions.log")"
comments=$(grep -c 'issue comment' "$GH_CALLS" || true)
[[ "$comments" == "0" ]] \
    || fail "(h) must NOT heartbeat the decoy, got $comments: $(cat "$GH_CALLS")"
grep -q "issue view ${decoy_num}" "$GH_CALLS" \
    || fail "(h) must verify the returned pointer's title via gh issue view: $(cat "$GH_CALLS")"
files=$(grep -c 'fleet-issue-file' "$FILE_CALLS" || true)
[[ "$files" == "1" ]] \
    || fail "(h) the create WAS attempted once, got $files: $(cat "$FILE_CALLS")"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] || fail "(h) must NOT spawn, got $spawns"
disps=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
[[ "$disps" == "0" ]] || fail "(h) must NOT add a DISPATCH line, got $disps"
ok "(h) DEDUPE COLLAPSE onto decoy #4773: FILED-LINK-MISMATCH logged, no '] FILED ' terminus, reported as skip-error"

# --- (i) UNREADABLE READ-BACK: gh issue view fails -> never FILED -----------
# fleet-ops#4773 finding B. The create returns a number the mock cannot
# resolve, so `gh issue view` exits 1 with NO stdout — exactly like real gh on
# an unknown number. The dispatcher must log FILED-LINK-MISMATCH with
# `title='<unavailable>'`, write NO `] FILED ` terminus line, and report
# skip-error. A mutant that accepts the returned number whenever the view
# failed must fail this case (the `] FILED ` count is the assertion that bites).
reset_log
set_gh_issues "[]"
FILE_NUM=9999; export FILE_NUM      # resolvable by nobody: no registry entry
FILE_REGISTER_TITLE=0; export FILE_REGISTER_TITLE
rc=0; fire_slowburn "$two_h_ago" || rc=$?
unset FILE_REGISTER_TITLE
[[ "$rc" == 0 ]] || fail "(i) unreadable-view dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
grep -q "FILED-LINK-MISMATCH.*issue=#9999 title='<unavailable>'" "$PACKET_DIR/actions.log" \
    || fail "(i) an unreadable view must log FILED-LINK-MISMATCH with title='<unavailable>': $(cat "$PACKET_DIR/actions.log")"
filed_lines=$(grep -c '\] FILED ' "$PACKET_DIR/actions.log" || true)
[[ "$filed_lines" == "0" ]] \
    || fail "(i) an unreadable view must NOT be reported as FILED, got $filed_lines: $(cat "$PACKET_DIR/actions.log")"
warns=$(grep -c '\] WARN .*auto-file failed' "$PACKET_DIR/actions.log" || true)
[[ "$warns" == "1" ]] \
    || fail "(i) a refused terminus must be reported as skip-error/WARN, got $warns: $(cat "$PACKET_DIR/actions.log")"
grep -q 'issue view 9999' "$GH_CALLS" \
    || fail "(i) the read-back of the returned pointer must be attempted: $(cat "$GH_CALLS")"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] || fail "(i) must NOT spawn, got $spawns"
ok "(i) unreadable gh issue view (rc=1, no stdout): FILED-LINK-MISMATCH title='<unavailable>', no FILED, skip-error"

# --- (j) THE FILED BODY IS CLAIMABLE (the admission spec gate accepts it) ---
# fleet-ops#4773 finding A. A terminus is only a terminus if a rung can claim
# it: the auto-filed item carried `--label critical-path` alone, and the real
# admission gate refused its body (`body has no
# termination:/accept:/required:/metric:`), so nothing could ever claim it.
# The gate is run here against the body the dispatcher REALLY passed (the mock
# captured `--body` verbatim), not against a copy or a fixture, and with
# `--repo fleet-ops` so the `moves:` product-metric requirement is enforced.
reset_log
set_gh_issues "[]"
FILE_NUM=5555; export FILE_NUM
rc=0; fire_slowburn "$two_h_ago" || rc=$?
[[ "$rc" == 0 ]] || fail "(j) dispatch must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
filed=$(grep -c '\] FILED ' "$PACKET_DIR/actions.log" || true)
[[ "$filed" == "1" ]] \
    || fail "(j) expected a filing to gate-check, got $filed FILED lines: $(cat "$PACKET_DIR/actions.log")"
spec_gate="$repo_root/lib/agent-ready-spec-gate.py"
[[ -f "$spec_gate" ]] || fail "(j) admission spec gate missing at $spec_gate"
gate_out="$(python3 "$spec_gate" check-body --repo fleet-ops --body "$FILE_BODY" 2>&1)" \
    || fail "(j) the auto-filed body is NOT claimable; admission gate refused it: $gate_out"
[[ "$gate_out" == *"SPEC-GATE: ok"* ]] \
    || fail "(j) admission gate must print SPEC-GATE: ok, got: $gate_out"
grep -q 'moves: no_usable_seat_events' "$FILE_BODY" \
    || fail "(j) the filed body must name the product metric it moves: $(cat "$FILE_BODY")"
# fleet-ops#5272: the filed body must carry a `termination:` clause naming the
# runtime gate — without it the fleet-ops#4540 awaiting-runtime-gate park
# detector can never engage, and a multi-day burn re-claims the open
# critical-path terminus forever (every claim a worker with nothing to fix).
grep -q '^- termination: ' "$FILE_BODY" \
    || fail "(j) the filed body must carry a termination: clause naming the runtime gate: $(cat "$FILE_BODY")"
# The bare `{signal}` trailer must survive the added spec lines byte for byte:
# it is the shipped signal-key file form (same trailer as `issue_body` in
# lib/detector-queue-reconciler.py), not ours to reformat.
grep -qx '`slo/seat-availability-slowburn`' "$FILE_BODY" \
    || fail "(j) the filed body must end with the bare signal trailer: $(cat "$FILE_BODY")"
ok "(j) the body the dispatcher really filed is claimable: SPEC-GATE: ok (repo fleet-ops)"

# --- (k) MALFORMED SEARCH RESPONSE: no traceback, file path survives --------
# fleet-ops#4773 finding D(1). A gh that answers with a JSON OBJECT (not a
# list) must be a failed lookup, never `for it in items` over a dict's keys
# (the old code raised AttributeError and took the whole dispatch down).
# Fail-open, as _slowburn_find_existing's docstring documents: a broken search
# must not block the file path.
reset_log
set_gh_issues '{"message":"Bad credentials"}'
FILE_NUM=5555; export FILE_NUM
rc=0; fire_slowburn "$two_h_ago" || rc=$?
[[ "$rc" == 0 ]] \
    || fail "(k) a non-list gh search response must not take the dispatch down, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
tracebacks=$(grep -c 'Traceback' "$scratch/sb.err" || true)
[[ "$tracebacks" == "0" ]] \
    || fail "(k) a non-list gh search response raised a traceback: $(cat "$scratch/sb.err")"
filed=$(grep -c '\] FILED ' "$PACKET_DIR/actions.log" || true)
[[ "$filed" == "1" ]] \
    || fail "(k) a malformed search must fail-open and still file, got $filed"
ok "(k) non-list gh search response: no traceback, fail-open file path still ran"

# --- (l) FAILED EXEC: a missing gh is skip-error, not a traceback -----------
# fleet-ops#4773 finding D(2). subprocess.run on a missing binary raises
# OSError (a hung one raises TimeoutExpired); both must behave as a failed
# lookup. GH here points at a path that does not exist, so BOTH the search
# and the read-back exec fail: no traceback, and the unreadable terminus is
# refused (skip-error) rather than guessed at.
reset_log
set_gh_issues "[]"
FILE_NUM=5555; export FILE_NUM
sb_gh="/nonexistent/gh-binary"
rc=0; fire_slowburn "$two_h_ago" || rc=$?
sb_gh="$mock_bin2/gh"
[[ "$rc" == 0 ]] \
    || fail "(l) a missing gh binary must not take the dispatch down, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
tracebacks=$(grep -c 'Traceback' "$scratch/sb.err" || true)
[[ "$tracebacks" == "0" ]] \
    || fail "(l) a missing gh binary raised a traceback: $(cat "$scratch/sb.err")"
mismatch=$(grep -c 'FILED-LINK-MISMATCH' "$PACKET_DIR/actions.log" || true)
[[ "$mismatch" == "1" ]] \
    || fail "(l) a failed exec must refuse the terminus (FILED-LINK-MISMATCH), got $mismatch: $(cat "$PACKET_DIR/actions.log")"
filed_lines=$(grep -c '\] FILED ' "$PACKET_DIR/actions.log" || true)
[[ "$filed_lines" == "0" ]] \
    || fail "(l) a failed exec must NOT be reported as FILED, got $filed_lines: $(cat "$PACKET_DIR/actions.log")"
warns=$(grep -c '\] WARN .*auto-file failed' "$PACKET_DIR/actions.log" || true)
[[ "$warns" == "1" ]] \
    || fail "(l) a failed exec must report skip-error, got $warns: $(cat "$PACKET_DIR/actions.log")"
ok "(l) missing gh binary (OSError): no traceback, refused terminus, skip-error"

echo "OK: fleet-ops#4773 slowburn file-or-link both directions + idempotence + live-decoy/dedupe-collapse refusal + claimable-body/unreadable-view robustness pass"

# ============================================================================
# fleet-ops#5272: observe-to-close — the resolved slowburn closes its terminus
# The dispatcher's resolved branch used to return before reading the alert
# group, so the auto-filed terminus lingered OPEN after the burn cleared: an
# open critical-path claim is reclaim-bait, and `_slowburn_find_existing`
# only matches OPEN items, so the stale terminus would LINK the NEXT burn
# forever (no fresh claim) exactly like the #4773 decoy did.
# Proves:
#   (m) resolved slowburn + open terminus -> title read-back, observe-to-close
#       comment, `gh issue close --reason completed`, CLOSED log line.
#   (n) resolved notification for a DIFFERENT alert -> no close, no comment.
#   (o) resolved slowburn + no open terminus -> clean skip, no close.
#   (p) unreadable read-back (view rc=1) -> no close (title verify refused).
#   (q) failed `gh issue close` (rc=1) -> WARN, no CLOSED line, dispatch rc=0.
# The skip-list entry STAYS throughout (no repair worker spawned).
# ============================================================================

fire_resolved() {
    AMX_ALERT_1_LABEL_alertname="${1:-$slowburn}" \
    AMX_ALERT_1_LABEL_severity="warning" \
    AMX_ALERT_1_LABEL_service="fleet" \
    AMX_STATUS="resolved" \
    AMX_RECEIVER="test-receiver" \
    PATH="$mock_bin2:$mock_bin:$PATH" \
    HOME="$scratch" \
    FLEET_ISSUE_FILE="$mock_bin2/fleet-issue-file" \
    GH="$sb_gh" \
    FLEET_SLOWBURN_REPO="Nishfleet/fleet-ops" \
    FLEET_SLOWBURN_SIGNAL="slo/seat-availability-slowburn" \
    "$dispatch_bin" \
        >"$scratch/sb.out" 2>"$scratch/sb.err"
}

# --- (m) resolved slowburn closes the open terminus -------------------------
reset_log
set_gh_issues "$claim_json" "${claim_num}|${claim_title}"
unset GH_CLOSE_RC
rc=0; fire_resolved || rc=$?
[[ "$rc" == 0 ]] \
    || fail "(m) resolved slowburn must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
grep -Eq "^gh issue close ${claim_num} -R Nishfleet/fleet-ops" "$GH_CALLS" \
    || fail "(m) resolved slowburn must close the terminus, gh calls: $(cat "$GH_CALLS")"
grep -q -- '--reason completed' "$GH_CALLS" \
    || fail "(m) the close must carry --reason completed: $(cat "$GH_CALLS")"
grep -Eq "^gh issue comment ${claim_num} -R Nishfleet/fleet-ops --body observe-to-close: " "$GH_CALLS" \
    || fail "(m) the close must be preceded by an observe-to-close comment: $(cat "$GH_CALLS")"
grep -q "CLOSED alertname=$slowburn.*reason=observe-to-close" "$PACKET_DIR/actions.log" \
    || fail "(m) CLOSED line missing from actions.log: $(cat "$PACKET_DIR/actions.log")"
disps=$(grep -c '\] DISPATCH ' "$PACKET_DIR/actions.log" || true)
[[ "$disps" == "0" ]] \
    || fail "(m) resolved path must never DISPATCH, got $disps"
spawns=$(grep -c 'mock-pi-systemd-run args=' "$MOCK_LOG" || true)
[[ "$spawns" == "0" ]] \
    || fail "(m) resolved path must not spawn a worker, got $spawns"
ok "(m) resolved slowburn closes its terminus (comment + close --reason completed)"

# --- (n) resolved OTHER alert never closes ----------------------------------
reset_log
set_gh_issues "$claim_json" "${claim_num}|${claim_title}"
rc=0; fire_resolved "FleetSloMainGreenSlowBurn" || rc=$?
[[ "$rc" == 0 ]] \
    || fail "(n) resolved other-alert must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
closes=$(grep -c '^gh issue close' "$GH_CALLS" || true)
[[ "$closes" == "0" ]] \
    || fail "(n) resolved non-slowburn alert must NOT close anything: $(cat "$GH_CALLS")"
comments=$(grep -c '^gh issue comment' "$GH_CALLS" || true)
[[ "$comments" == "0" ]] \
    || fail "(n) resolved non-slowburn alert must not comment: $(cat "$GH_CALLS")"
ok "(n) resolved non-slowburn alert: no close, no comment"

# --- (o) resolved slowburn with no open terminus is a clean skip ------------
reset_log
set_gh_issues "[]"
rc=0; fire_resolved || rc=$?
[[ "$rc" == 0 ]] \
    || fail "(o) resolved with no terminus must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
closes=$(grep -c '^gh issue close' "$GH_CALLS" || true)
[[ "$closes" == "0" ]] \
    || fail "(o) nothing to close must not call close: $(cat "$GH_CALLS")"
grep -q "observe-to-close: no open terminus" "$PACKET_DIR/actions.log" \
    || fail "(o) actions.log must record the nothing-to-close skip: $(cat "$PACKET_DIR/actions.log")"
ok "(o) resolved slowburn with no open terminus: clean no-op skip"

# --- (p) unreadable read-back refuses the close -----------------------------
reset_log
# List returns the claim, but the view registry is EMPTY: the title read-back
# fails rc=1 (real-gh shape), so the candidate is unverified — never closed.
set_gh_issues "$claim_json"
rc=0; fire_resolved || rc=$?
[[ "$rc" == 0 ]] \
    || fail "(p) unreadable read-back must exit 0, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
closes=$(grep -c '^gh issue close' "$GH_CALLS" || true)
[[ "$closes" == "0" ]] \
    || fail "(p) unverified title must never close: $(cat "$GH_CALLS")"
ok "(p) unreadable title read-back: no close (fleet-ops#4773 discriminator holds)"

# --- (q) failed close is a WARN, dispatch still exits 0 ---------------------
reset_log
set_gh_issues "$claim_json" "${claim_num}|${claim_title}"
GH_CLOSE_RC=1; export GH_CLOSE_RC
rc=0; fire_resolved || rc=$?
GH_CLOSE_RC=""; unset GH_CLOSE_RC
[[ "$rc" == 0 ]] \
    || fail "(q) a failed close must not take the dispatch down, got rc=$rc (stderr: $(cat "$scratch/sb.err"))"
tracebacks=$(grep -c 'Traceback' "$scratch/sb.err" || true)
[[ "$tracebacks" == "0" ]] \
    || fail "(q) a failed close raised a traceback: $(cat "$scratch/sb.err")"
grep -q "close of #${claim_num} failed" "$PACKET_DIR/actions.log" \
    || fail "(q) actions.log must WARN on the failed close: $(cat "$PACKET_DIR/actions.log")"
closed_lines=$(grep -c '\] CLOSED alertname=' "$PACKET_DIR/actions.log" || true)
[[ "$closed_lines" == "0" ]] \
    || fail "(q) a failed close must not log CLOSED, got $closed_lines"
ok "(q) failed gh issue close: WARN, no CLOSED line, dispatch exit 0"

echo "OK: fleet-ops#5272 slowburn observe-to-close pass"