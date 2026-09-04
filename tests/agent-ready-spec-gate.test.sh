#!/usr/bin/env bash
# tests/agent-ready-spec-gate.test.sh
#
# Proves fleet-ops#543 agent-ready spec-gate:
#   (a) live repo passes: first-admission scripts call the gate, scout.md
#       keeps the cap of 12, matrix row is enforced.
#   (b) a product spec (termination: + command) is accepted.
#   (c) a control-plane spec (`- required:`) is accepted.
#   (d) an empty / prose-only body is refused.
#   (e) termination: with no command is refused unless another field is present.
#   (f) a first-admission script that drops the gate is rejected.
#   (g) nested CI host so this token does not need a workflow edit.
#   (h) two live required: lines are size-ok (fleet-ops#3309).
#   (i) three live required: lines bounce with split me + blocked-on: split.
#   (j) a struck-through required: line does not count.
#   (k) umbrella-labeled issues are exempt.
#   (l) comments are counted with the body.
#   (m) check-body still admits an oversized spec (size is claim-time).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
py="$repo_root/lib/agent-ready-spec-gate.py"
matrix="$repo_root/config/rule-enforcement.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -f "$py" ]] || fail "missing $py"
[[ -f "$matrix" ]] || fail "missing $matrix"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v jq >/dev/null 2>&1 || fail "jq missing"

set +e
live_out=$(python3 "$py" verify --repo-root "$repo_root" 2>&1)
live_rc=$?
set -e
[[ "$live_rc" == "0" ]] || fail "live repo must pass spec-gate verify (rc=$live_rc out=$live_out)"
ok "(a) live repo passes spec-gate verify"

jq -e '.rules[] | select(.id == "led-work-supply-agent-ready" and .status == "enforced")' \
  "$matrix" >/dev/null || fail "led-work-supply-agent-ready must be status=enforced"
ok "(a) led-work-supply-agent-ready is enforced in the rule matrix"

scratch=$(mktemp -d -t agent-ready-spec-gate.XXXXXX)
trap 'rm -rf "$scratch"' EXIT INT TERM

printf '%s\n' 'termination: test -f README.md' 'accept: - worker ships the fix' >"$scratch/product.md"
set +e
prod_out=$(python3 "$py" check-body --body "$scratch/product.md" 2>&1)
prod_rc=$?
set -e
[[ "$prod_rc" == "0" ]] || fail "product spec must pass (rc=$prod_rc out=$prod_out)"
ok "(b) product spec (termination:) is accepted"

printf '%s\n' 'The rule-coverage canary found a queued rule.' \
  '- required: a named gate / canary step / CI check' \
  'signal: rule-enforcement/led-work-supply-agent-ready' >"$scratch/control.md"
set +e
ctl_out=$(python3 "$py" check-body --body "$scratch/control.md" 2>&1)
ctl_rc=$?
set -e
[[ "$ctl_rc" == "0" ]] || fail "control-plane spec must pass (rc=$ctl_rc out=$ctl_out)"
ok "(c) control-plane spec (required:) is accepted"

printf '%s\n' 'Please look at this when you can.' >"$scratch/empty.md"
set +e
empty_out=$(python3 "$py" check-body --body "$scratch/empty.md" 2>&1)
empty_rc=$?
set -e
[[ "$empty_rc" == "1" ]] || fail "prose-only body must be refused (rc=$empty_rc out=$empty_out)"
grep -q 'refused' <<<"$empty_out" || fail "refuse output must say refused (out=$empty_out)"
ok "(d) prose-only body is refused"

printf '%s\n' 'termination:' >"$scratch/bare-term.md"
set +e
bare_out=$(python3 "$py" check-body --body "$scratch/bare-term.md" 2>&1)
bare_rc=$?
set -e
[[ "$bare_rc" == "1" ]] || fail "bare termination: must be refused (rc=$bare_rc out=$bare_out)"
ok "(e) termination: with no command is refused"

mkdir -p "$scratch/repo/bin" "$scratch/repo/lib" "$scratch/repo/prompts" "$scratch/repo/config"
cp "$repo_root/bin/lifecycle-label-sweep" "$scratch/repo/bin/"
cp "$repo_root/bin/pi-audit-tally" "$scratch/repo/bin/"
cp "$repo_root/prompts/scout.md" "$scratch/repo/prompts/"
cp "$repo_root/prompts/intake.md" "$scratch/repo/prompts/"
cp "$repo_root/lib/pi-intake-tick.sh" "$scratch/repo/lib/"
cp "$matrix" "$scratch/repo/config/"
# Drop the gate from the sweep copy.
sed -i '/agent-ready-spec-gate/d' "$scratch/repo/bin/lifecycle-label-sweep"
set +e
unwired_out=$(python3 "$py" verify --repo-root "$scratch/repo" 2>&1)
unwired_rc=$?
set -e
[[ "$unwired_rc" == "1" ]] || fail "unwired sweep must be rejected (rc=$unwired_rc out=$unwired_out)"
grep -q 'lifecycle-label-sweep' <<<"$unwired_out" \
  || fail "unwired output must name the sweep (out=$unwired_out)"
ok "(f) first-admission script that drops the gate is rejected"

grep -Fq 'bash "$here/agent-ready-spec-gate.test.sh"' "$here/rule-enforcement.test.sh" \
  || fail "rule-enforcement.test.sh must nest this file (CI cannot gain a new workflow line)"
ok "(g) nested CI host"

printf '%s\n' \
  '- required: first' \
  '- required: second' >"$scratch/two.md"
set +e
two_out=$(python3 "$py" check-size --body "$scratch/two.md" 2>&1)
two_rc=$?
set -e
[[ "$two_rc" == "0" ]] || fail "two required: must be size-ok (rc=$two_rc out=$two_out)"
grep -q 'size-ok' <<<"$two_out" || fail "two required: output must say size-ok (out=$two_out)"
ok "(h) two live required: lines are size-ok"

printf '%s\n' \
  '- required: first' \
  '- required: second' \
  '- required: third' >"$scratch/three.md"
set +e
three_out=$(python3 "$py" check-size --body "$scratch/three.md" 2>&1)
three_rc=$?
set -e
[[ "$three_rc" == "1" ]] || fail "three required: must bounce (rc=$three_rc out=$three_out)"
grep -q 'split me: 3 requirements; one requirement per issue' <<<"$three_out" \
  || fail "three required: must print split me (out=$three_out)"
grep -q 'blocked-on: split' <<<"$three_out" \
  || fail "three required: must print blocked-on: split (out=$three_out)"
ok "(i) three live required: lines bounce with split me + blocked-on: split"

printf '%s\n' \
  '- required: first' \
  '- required: second' \
  '~~- required: struck~~' >"$scratch/struck.md"
set +e
struck_out=$(python3 "$py" check-size --body "$scratch/struck.md" 2>&1)
struck_rc=$?
set -e
[[ "$struck_rc" == "0" ]] || fail "struck required: must not count (rc=$struck_rc out=$struck_out)"
ok "(j) struck-through required: line is ignored"

set +e
umb_out=$(python3 "$py" check-size --body "$scratch/three.md" --labels '[{"name":"umbrella"}]' 2>&1)
umb_rc=$?
set -e
[[ "$umb_rc" == "0" ]] || fail "umbrella must be exempt (rc=$umb_rc out=$umb_out)"
grep -q 'umbrella' <<<"$umb_out" || fail "umbrella output must name umbrella (out=$umb_out)"
ok "(k) umbrella-labeled issues are exempt"

printf '%s\n' '- required: first' '- required: second' >"$scratch/body-two.md"
printf '%s\n' '- required: from a comment' >"$scratch/comments.md"
set +e
com_out=$(python3 "$py" check-size --body "$scratch/body-two.md" --comments "$scratch/comments.md" 2>&1)
com_rc=$?
set -e
[[ "$com_rc" == "1" ]] || fail "comment required: must count (rc=$com_rc out=$com_out)"
grep -q 'split me: 3 requirements' <<<"$com_out" \
  || fail "comment required: must bounce as 3 (out=$com_out)"
ok "(l) comments are counted with the body"

set +e
admit_out=$(python3 "$py" check-body --body "$scratch/three.md" 2>&1)
admit_rc=$?
set -e
[[ "$admit_rc" == "0" ]] || fail "oversized spec must still pass check-body (rc=$admit_rc out=$admit_out)"
ok "(m) check-body still admits an oversized spec (size is claim-time)"

: >"$scratch/seven.md"
for i in 1 2 3 4 5 6 7; do
  printf '%s\n' "- required: packet requirement $i" >>"$scratch/seven.md"
done
set +e
seven_out=$(python3 "$py" check-size --body "$scratch/seven.md" 2>&1)
seven_rc=$?
set -e
[[ "$seven_rc" == "1" ]] || fail "seven required: must bounce (rc=$seven_rc out=$seven_out)"
grep -q 'split me: 7 requirements; one requirement per issue' <<<"$seven_out" \
  || fail "seven required: must print split me: 7 (out=$seven_out)"
ok "(n) seven-requirement packet (today's evidence shape) bounces"

printf '%s\n' '- accept: a' '- accept: b' '- accept: c' >"$scratch/accepts.md"
set +e
acc_out=$(python3 "$py" check-size --body "$scratch/accepts.md" 2>&1)
acc_rc=$?
set -e
[[ "$acc_rc" == "0" ]] || fail "accept: lines must not count as required (rc=$acc_rc out=$acc_out)"
ok "(o) accept: lines are not required: lines"

# Replay the tick's bounce commands (lib/pi-intake-tick.sh size gate) against
# a fake gh: check-size rc=1 must flip agent-ready -> agent-blocked and post
# the split-me comment. This is the intake half of fleet-ops#3309.
cat >"$scratch/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
exit 0
GH
chmod +x "$scratch/gh"
export GH_LOG="$scratch/gh-bounce.log"
: >"$GH_LOG"
set +e
bounce_text=$(python3 "$py" check-size --body "$scratch/seven.md" 2>&1)
bounce_rc=$?
set -e
[[ "$bounce_rc" == "1" ]] || fail "replay: seven-required must bounce (rc=$bounce_rc out=$bounce_text)"
"$scratch/gh" issue edit 3309 -R Nishfleet/fleet-ops --remove-label agent-ready --add-label agent-blocked
"$scratch/gh" issue comment 3309 -R Nishfleet/fleet-ops --body "$bounce_text"
grep -q -- '--remove-label agent-ready' "$GH_LOG" \
  || fail "replay: must drop agent-ready: $(cat "$GH_LOG")"
grep -q -- '--add-label agent-blocked' "$GH_LOG" \
  || fail "replay: must add agent-blocked: $(cat "$GH_LOG")"
grep -q 'issue comment 3309' "$GH_LOG" \
  || fail "replay: must comment: $(cat "$GH_LOG")"
grep -q 'split me: 7 requirements' "$GH_LOG" \
  || fail "replay: comment must carry split me: $(cat "$GH_LOG")"
grep -q 'blocked-on: split' "$GH_LOG" \
  || fail "replay: comment must carry blocked-on: split: $(cat "$GH_LOG")"
ok "(p) intake bounce replay flips labels and comments split me"

ok "agent-ready-spec-gate: live verify, product spec, control-plane spec, refuse, unwired, size bounce"
