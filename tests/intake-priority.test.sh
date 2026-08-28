#!/usr/bin/env bash
# tests/intake-priority.test.sh
#
# fleet-ops#379 drill: a critical-path fixture and a plain fixture are both
# open; the next tick claims the critical one. Also locks the claim-ratio
# guard so the tail cannot starve forever, and escalate-senior implying
# critical-path.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/pi-intake-priority"
lib="$repo_root/lib/intake-priority.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing lib: $lib"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT INT TERM
export INTAKE_PRIORITY_LIB="$lib"
export INTAKE_PRIORITY_RATIO_DIR="$scratch/ratio"

issues_both="$scratch/both.json"
cat >"$issues_both" <<'JSON'
[
  {"number": 50, "title": "plain tail", "labels": [{"name": "agent-ready"}], "createdAt": "2026-08-01T00:00:00Z"},
  {"number": 223, "title": "conference-gate", "labels": [{"name": "agent-ready"}, {"name": "critical-path"}], "createdAt": "2026-08-26T12:00:00Z"}
]
JSON

# --- drill: next tick claims the critical fixture ---------------------------
out="$("$bin" order --repo fleet-ops --issues-file "$issues_both" --ratio-file "$scratch/empty.ratio" --pick-one)"
num="${out%%$'\t'*}"
rest="${out#*$'\t'}"
kind="${rest%%$'\t'*}"
[[ "$num" == "223" ]] || fail "drill: expected to claim #223, got: $out"
[[ "$kind" == "critical-path" ]] || fail "drill: expected kind=critical-path, got: $out"
printf '%s\n' "$out" | grep -q 'ratio=' || fail "drill: tick line must log ratio, got: $out"
ok "drill: critical-path fixture is claimed before the plain tail"

# Same drill via stdin, matching the intake prompt's pipe.
out="$(cat "$issues_both" | "$bin" order --repo fleet-ops --ratio-file "$scratch/empty.ratio" --pick-one)"
num="${out%%$'\t'*}"
[[ "$num" == "223" ]] || fail "stdin drill: expected #223, got: $out"
ok "drill via stdin (intake prompt pipe) also claims the critical fixture"

# Full order still lists the tail after the critical issue.
full="$("$bin" order --repo fleet-ops --issues-file "$issues_both" --ratio-file "$scratch/empty.ratio")"
first="$(printf '%s\n' "$full" | head -n1 | cut -f1)"
second="$(printf '%s\n' "$full" | sed -n '2p' | cut -f1)"
[[ "$first" == "223" && "$second" == "50" ]] || fail "full order should be 223 then 50, got: $full"
ok "full order is critical then tail"

# --- claim-ratio guard: two critical in a row then the tail -----------------
printf 'critical\ncritical\n' >"$scratch/owed.ratio"
out="$("$bin" order --repo fleet-ops --issues-file "$issues_both" --ratio-file "$scratch/owed.ratio" --pick-one)"
num="${out%%$'\t'*}"
rest="${out#*$'\t'}"
kind="${rest%%$'\t'*}"
[[ "$num" == "50" ]] || fail "ratio guard: expected tail #50, got: $out"
[[ "$kind" == "tail-ratio" ]] || fail "ratio guard: expected kind=tail-ratio, got: $out"
ok "claim-ratio guard picks the tail after two critical claims"

# Guard must not invent a tail when only critical issues exist.
issues_crit_only="$scratch/crit-only.json"
cat >"$issues_crit_only" <<'JSON'
[
  {"number": 10, "title": "only critical", "labels": [{"name": "critical-path"}, {"name": "agent-ready"}]}
]
JSON
out="$("$bin" order --repo fleet-ops --issues-file "$issues_crit_only" --ratio-file "$scratch/owed.ratio" --pick-one)"
num="${out%%$'\t'*}"
[[ "$num" == "10" ]] || fail "crit-only must still claim #10, got: $out"
ok "ratio guard does not starve when no tail exists"

# --- escalate-senior is senior-panel-owned, excluded from regular claim --
# (fleet-ops#234: intake routes escalate-senior to the pi-audit@ panel, so a
# regular lane must never claim it — that defeats the panel.)
issues_esc="$scratch/esc.json"
cat >"$issues_esc" <<'JSON'
[
  {"number": 5, "title": "plain", "labels": [{"name": "agent-ready"}]},
  {"number": 9, "title": "senior stall", "labels": [{"name": "agent-ready"}, {"name": "escalate-senior"}]}
]
JSON
out="$("$bin" order --repo fleet-ops --issues-file "$issues_esc" --ratio-file "$scratch/empty2.ratio" --pick-one)"
num="${out%%$'\t'*}"
[[ "$num" == "5" ]] || fail "escalate-senior must be excluded from regular claim, got: $out"
ok "escalate-senior is excluded from the regular-worker claim order (senior panel owns it)"

# --- fleet-ops#180: gap-audit is critical while the intensive loop is open --
issues_gap="$scratch/gap.json"
cat >"$issues_gap" <<'JSON'
[
  {"number": 50, "title": "plain tail", "labels": [{"name": "agent-ready"}]},
  {"number": 180, "title": "gap finding", "labels": [{"name": "agent-ready"}, {"name": "gap-audit"}]}
]
JSON
printf 'loop\n' >"$scratch/loop.prec"
out="$(GAP_LOOP_PRECEDENCE_FILE="$scratch/loop.prec" "$bin" order --repo fleet-ops --issues-file "$issues_gap" --ratio-file "$scratch/empty-gap.ratio" --pick-one)"
num="${out%%$'\t'*}"
rest="${out#*$'\t'}"
kind="${rest%%$'\t'*}"
[[ "$num" == "180" ]] || fail "loop-open: expected to claim gap-audit #180, got: $out"
[[ "$kind" == "gap-audit" ]] || fail "loop-open: expected kind=gap-audit, got: $out"
ok "loop-open: gap-audit is claimed before the product tail"

printf 'product\n' >"$scratch/product.prec"
out="$(GAP_LOOP_PRECEDENCE_FILE="$scratch/product.prec" "$bin" order --repo fleet-ops --issues-file "$issues_gap" --ratio-file "$scratch/empty-gap2.ratio" --pick-one)"
num="${out%%$'\t'*}"
[[ "$num" == "50" ]] || fail "loop-closed: expected product tail #50 first, got: $out"
ok "loop-closed: gap-audit is tail after unanimous DONE"

# --- record persists for the next tick --------------------------------------
"$bin" record --ratio-file "$scratch/rec.ratio" 223 critical-path
"$bin" record --ratio-file "$scratch/rec.ratio" 224 critical-path
got="$(cat "$scratch/rec.ratio")"
[[ "$got" == $'critical\ncritical' ]] || fail "record should store two critical lines, got: $got"
out="$("$bin" order --repo fleet-ops --issues-file "$issues_both" --ratio-file "$scratch/rec.ratio" --pick-one)"
num="${out%%$'\t'*}"
[[ "$num" == "50" ]] || fail "recorded ratio should force tail on next tick, got: $out"
ok "record feeds the next tick's ratio guard"

# --- promote copies escalate-senior onto critical-path ----------------------
gh_log="$scratch/gh.log"
cat >"$scratch/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$gh_log"
if [[ "\$*" == *"label create"* ]]; then
  exit 0
fi
if [[ "\$*" == *"issue list"* ]]; then
  cat <<'ISSUES'
[{"number": 9, "labels": [{"name": "escalate-senior"}]}, {"number": 11, "labels": [{"name": "escalate-senior"}, {"name": "critical-path"}]}]
ISSUES
  exit 0
fi
if [[ "\$*" == *"issue edit"* ]]; then
  exit 0
fi
echo "unexpected gh: \$*" >&2
exit 1
EOF
chmod +x "$scratch/gh"
GH="$scratch/gh" "$bin" promote --repo fleet-ops
grep -q 'label create critical-path' "$gh_log" || fail "promote must create the label: $(cat "$gh_log")"
grep -q 'issue edit 9 ' "$gh_log" || fail "promote must edit #9 (missing critical-path): $(cat "$gh_log")"
if grep -q 'issue edit 11 ' "$gh_log"; then
  fail "promote must not re-label #11 which already has critical-path: $(cat "$gh_log")"
fi
ok "promote creates critical-path and copies it onto escalate-senior issues"

# --- contracts: prompt + MANIFEST -------------------------------------------
grep -q 'pi-intake-priority' "$repo_root/prompts/intake.md" \
  || fail "intake prompt must call pi-intake-priority"
grep -q 'critical-path' "$repo_root/prompts/intake.md" \
  || fail "intake prompt must name the critical-path tier"
if grep -q 'in ascending issue-number order' "$repo_root/prompts/intake.md"; then
  fail "intake prompt must not still claim in ascending issue-number order"
fi
grep -q 'bin/pi-intake-priority' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/pi-intake-priority"
grep -q 'lib/intake-priority.sh' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install lib/intake-priority.sh"
ok "contracts: prompt uses the orderer, MANIFEST installs it"

echo "all intake-priority cases passed"
