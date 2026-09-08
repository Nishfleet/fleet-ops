#!/usr/bin/env bash
# tests/fleet-judge-block-gate.test.sh
#
# fleet-ops#4557: a judge block on a gate-touch PR must have teeth.
# 0509#2011 merged 90 seconds after the judge's blocking comment because
# withholding the arm has no teeth — the worker lane and the tier1 queue
# pass arm auto-merge independently and no hold label existed.
#
# Replay drill (stubbed gh — no network, no real PRs):
#   1. A PR labeled blocked-by-judge is refused the arm AND its armed
#      auto-merge is disarmed (gh pr merge --disable-auto was called).
#   2. Removing the label re-permits arming (exit 0) — an addressed block
#      is not a dead end.
#   3. A labeled PR with NO armed auto-merge is refused without a disarm
#      call.
#   4. An unreadable label state fails CLOSED (exit 1) — a gh hiccup
#      cannot wave a possibly-blocked PR through the arm.
#   5. --sweep disarms every labeled armed PR across the enrolled repos
#      and survives a failing repo (webhook fast-path actuator).
#   6. The webhook receiver dispatches fleet-judge-block-disarm.service
#      on pull_request/labeled blocked-by-judge and ignores other labels.
#   7. tier1 fetches labels and refuses the arm on the labeled path
#      (source pin — the queue pass is the level-triggered backstop).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
gate="$repo_root/bin/fleet-judge-block-gate"
serve="$repo_root/libexec/gh-webhook-receiver/serve.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$gate" ]] || fail "missing: $gate"
bash -n "$gate" || fail "fleet-judge-block-gate: bash syntax error"
ok "0: helper present + syntax"

# --- stub gh: logs every call to $GH_CALL_LOG, answers per scenario ---
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
GH_CALL_LOG="$STUB/calls.log"
touch "$GH_CALL_LOG"

# Scenario inputs (set per case):
#   STUB_LABELS_JSON   JSON emitted for `gh pr view --jq` label reads
#                      (raw output of the --jq program, or empty = gh fail)
#   STUB_AUTOMERGE     "true" | "null" (pr view autoMergeRequest; null = not armed)
#   STUB_LIST_NUMBERS  numbers emitted for `gh pr list` (sweep mode)
cat > "$STUB/gh" <<STUBEOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_CALL_LOG"
case " \$* " in
  *" pr view "*)
    if [[ "\$*" == *"autoMergeRequest"* ]]; then
      printf '{"autoMergeRequest": %s}' "\${STUB_AUTOMERGE:-null}" | jq -c "\$(expr " \$* " : '.*--jq \\(.*\\)')"
    else
      # label read: run the --jq program against STUB_LABELS_JSON
      printf '%s' "\$STUB_LABELS_JSON" | jq -c "\$(expr " \$* " : '.*--jq \(.*\)')"
      exit \${STUB_VIEW_RC:-0}
    fi
    ;;
  *" pr list "*)
    if [[ "\$*" == *"Nishfleet/broken"* ]]; then
      echo "gh: broken repo (stub)" >&2
      exit 1
    fi
    for n in \${STUB_LIST_NUMBERS:-}; do printf '%s\n' "\$n"; done
    ;;
  *" pr merge "*)
    :  # success; the call itself is the assertion
    ;;
  *) printf '{}' ;;
esac
STUBEOF
chmod +x "$STUB/gh"
export PATH="$STUB:$PATH"
export STUB_LABELS_JSON STUB_AUTOMERGE STUB_VIEW_RC STUB_LIST_NUMBERS
export GH_CALL_LOG

# --- 1. --help exits 0 ---
"$gate" --help >/dev/null 2>&1 || fail "--help must exit 0"
ok "1: --help exits 0"

# --- 2. unlabeled PR: arming permitted (exit 0) ---
STUB_LABELS_JSON='{"labels":[]}'
rc=0
out=$("$gate" --repo Nishfleet/0509 --pr 2011 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "unlabeled PR must exit 0, got $rc: $out"
ok "2: unlabeled PR re-permits arming (exit 0)"

# --- 3. labeled + armed: exit 1 AND disarm call ---
: > "$GH_CALL_LOG"
STUB_LABELS_JSON='{"labels":[{"name":"blocked-by-judge"}]}'
STUB_AUTOMERGE='true'
"$gate" --repo Nishfleet/0509 --pr 2011 >/dev/null 2>&1 && fail "labeled PR must exit 1"
grep -q "pr merge 2011.*--disable-auto" "$GH_CALL_LOG" \
  || fail "labeled+armed PR: expected gh pr merge --disable-auto call"
ok "3: labeled+armed PR refused the arm and auto-merge DISARMED"

# --- 4. labeled + NOT armed: exit 1, no disarm call ---
: > "$GH_CALL_LOG"
STUB_AUTOMERGE='null'
"$gate" --repo Nishfleet/0509 --pr 2011 >/dev/null 2>&1 && fail "labeled PR must exit 1"
if grep -q -- "--disable-auto" "$GH_CALL_LOG"; then
  fail "labeled+unarmed PR: disarm must not be attempted"
fi
ok "4: labeled+unarmed PR refused without a disarm call"

# --- 5. unreadable label state: fail-CLOSED (exit 1) ---
STUB_VIEW_RC=1
STUB_LABELS_JSON=''
"$gate" --repo Nishfleet/0509 --pr 2011 >/dev/null 2>&1 && \
  fail "unreadable label state must fail closed (exit 1)"
ok "5: unreadable label state fails closed"

# --- 6. usage error ---
rc=0
"$gate" --repo Nishfleet/0509 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "missing --pr must exit 2, got $rc"
ok "6: usage error exits 2"

# --- 7. sweep: disarms labeled armed PRs across repos, survives repo failure ---
: > "$GH_CALL_LOG"
STUB_VIEW_RC=0
STUB_AUTOMERGE='true'
STUB_LIST_NUMBERS='2011 2013'
# First repo fails its pr list (empty output + rc preserved by the stub is
# fine — the sweep must simply move on), second repo has two labeled PRs.
FLEET_JUDGE_BLOCK_REPOS="Nishfleet/broken Nishfleet/0509" "$gate" --sweep >/dev/null 2>&1 \
  || fail "--sweep must exit 0"
n=$(grep -c -- "--disable-auto" "$GH_CALL_LOG" || true)
[ "$n" -eq 2 ] || fail "sweep: expected 2 disarm calls, got $n"
ok "7: sweep disarms labeled armed PRs and survives a failing repo"

# --- 8. webhook dispatch: blocked-by-judge label event fires the disarm unit ---
python3 - "$serve" <<'PYEOF' || fail "dispatch checks failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("serve", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

units = mod.dispatch("pull_request", "labeled", "blocked-by-judge", "0509",
                     "", False, {"0509"}, "false")
fireable = [u for u, _ in units if u]
assert fireable == ["fleet-judge-block-disarm.service"], fireable

# other labels stay ignored (the arm is unaffected)
units = mod.dispatch("pull_request", "labeled", "stale-unarmed", "0509",
                     "", False, {"0509"}, "false")
assert all(not u for u, _ in units), units

# label absent ("" as issues events used to see) still ignored
units = mod.dispatch("pull_request", "opened", "", "0509",
                     "", False, {"0509"}, "false")
assert all(not u for u, _ in units), units
PYEOF
ok "8: webhook dispatch fires fleet-judge-block-disarm on the judge-block label"

# --- 9. tier1 source pin: labels fetched + refusal before the arm ---
grep -q 'number,headRefName,isDraft,mergeable,title,labels' \
  "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "tier1 queue pass must fetch labels"
grep -q 'BLOCKED-BY-JUDGE' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "tier1 queue pass must refuse the arm on blocked-by-judge"
grep -q 'fleet-judge-block-gate' "$repo_root/bin/fleet-heartbeat-tier1" \
  || fail "tier1 must call the judge-block gate (disarm on the labeled path)"
ok "9: tier1 queue pass honours the judge-block label (source pin)"

echo "ALL PASS: fleet-judge-block-gate replay drill"
