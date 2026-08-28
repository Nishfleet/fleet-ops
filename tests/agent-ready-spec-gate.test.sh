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

mkdir -p "$scratch/repo/bin" "$scratch/repo/prompts" "$scratch/repo/config"
cp "$repo_root/bin/lifecycle-label-sweep" "$scratch/repo/bin/"
cp "$repo_root/bin/pi-audit-tally" "$scratch/repo/bin/"
cp "$repo_root/prompts/scout.md" "$scratch/repo/prompts/"
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

ok "agent-ready-spec-gate: live verify, product spec, control-plane spec, refuse, unwired"
