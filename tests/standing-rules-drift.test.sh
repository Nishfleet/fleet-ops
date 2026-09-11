#!/usr/bin/env bash
# tests/standing-rules-drift.test.sh
#
# Proves the standing-rules generator catches drift and rebuilds cleanly.
# Runs in CI without the real CLAUDE.md / AGENTS.md present on the
# hosted runner — it builds two temporary target files from fixtures,
# runs the generator against them, and asserts:
#
#   1. The current state matches the canonical -> exit 0.
#   2. A hand-edit to a generated region -> exit 1.
#   3. --render restores the original and exit returns to 0.
#   4. Templating tokens are applied per target surface.
#   5. Canonical-only sections (no target references them) -> exit 1.
#
# All assertions are byte-exact; no fuzzy matching.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
gen="$repo_root/bin/render-standing-rules.py"
canonical="$repo_root/lib/standing-rules/canonical.md"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Stage 0: precondition checks.
[[ -x "$gen" ]] || fail "generator not executable: $gen"
[[ -f "$canonical" ]] || fail "canonical not found: $canonical"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# Stage 0a: fleet-ops#5536 — the generator's default targets must carry
# ONE identical sol_identity_block. A per-surface split fed Claude
# "Sol still orchestrates" while Codex got "Sol is retired"; the drift
# fixtures pass per-surface Sol text on purpose and therefore cannot
# catch it, so the gate on the defaults themselves is the detector.
RSR_PATH="$repo_root/bin/render-standing-rules.py" python3 - <<'PY' || fail "contradictory default sol_identity_block values"
import importlib.util, os
spec = importlib.util.spec_from_file_location(
    "rsr", os.environ["RSR_PATH"]
)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
blocks = {t["sol_identity_block"] for t in m.DEFAULT_TARGETS}
assert len(blocks) == 1, f"DEFAULT_TARGETS carry {len(blocks)} distinct sol_identity_block values"
PY

work="$(mktemp -d -t standing-rules-drift-XXXXXX)"
trap 'rm -rf "$work"' EXIT

# Fixture 1: a target file with BEGIN/END GENERATED markers for the
# sections now in the canonical, and a hand-written tail. Templating
# tokens are left in place so the generator must substitute them.
target_claude="$work/claude.md"
cat > "$target_claude" <<'CL'
# Claude preamble (hand-written)
<!-- BEGIN GENERATED: idle-fleet-alarm -->
INTENTIONAL PLACEHOLDER FOR idle-fleet-alarm BODY
<!-- END GENERATED: idle-fleet-alarm -->
<!-- BEGIN GENERATED: one-fleet-rule -->
INTENTIONAL PLACEHOLDER FOR one-fleet-rule BODY
<!-- END GENERATED: one-fleet-rule -->
## Bridge
<!-- BEGIN GENERATED: nish-preimplementation-contract -->
INTENTIONAL PLACEHOLDER FOR nish-preimplementation-contract BODY
<!-- END GENERATED: nish-preimplementation-contract -->
## Routing
<!-- BEGIN GENERATED: shared-fleet-routing -->
INTENTIONAL PLACEHOLDER FOR shared-fleet-routing BODY
<!-- END GENERATED: shared-fleet-routing -->
<!-- BEGIN GENERATED: never-relay-finding -->
INTENTIONAL PLACEHOLDER FOR never-relay-finding BODY
<!-- END GENERATED: never-relay-finding -->
<!-- BEGIN GENERATED: shared-memory-loop -->
INTENTIONAL PLACEHOLDER FOR shared-memory-loop BODY
<!-- END GENERATED: shared-memory-loop -->
# Claude tail (hand-written)
CL

target_codex="$work/codex.md"
cat > "$target_codex" <<'CO'
# Codex preamble (hand-written)
<!-- BEGIN GENERATED: idle-fleet-alarm -->
INTENTIONAL PLACEHOLDER FOR idle-fleet-alarm BODY
<!-- END GENERATED: idle-fleet-alarm -->
<!-- BEGIN GENERATED: one-fleet-rule -->
INTENTIONAL PLACEHOLDER FOR one-fleet-rule BODY
<!-- END GENERATED: one-fleet-rule -->
## Operating contract
<!-- BEGIN GENERATED: nish-preimplementation-contract -->
INTENTIONAL PLACEHOLDER FOR nish-preimplementation-contract BODY
<!-- END GENERATED: nish-preimplementation-contract -->
## Routing
<!-- BEGIN GENERATED: shared-fleet-routing -->
INTENTIONAL PLACEHOLDER FOR shared-fleet-routing BODY
<!-- END GENERATED: shared-fleet-routing -->
<!-- BEGIN GENERATED: shared-memory-loop -->
INTENTIONAL PLACEHOLDER FOR shared-memory-loop BODY
<!-- END GENERATED: shared-memory-loop -->
# Codex tail (hand-written)
CO

run_gen() {
  python3 "$gen" \
    --canonical "$canonical" \
    --targets "$target_claude|claude-vps|Claude|Claude and every Claude subagent|SEATCLAUDE||SOLCLAUDE|FAILCLAUDE,$target_codex|codex-vps|Codex|every Codex agent and subagent|SEATCODEX|OLDCODEX|SOLCODEX|" \
    "$@"
}

# --- Assertion 1: initial state drifts (placeholders differ from canonical).
if run_gen --check >/dev/null 2>&1; then
  fail "expected initial drift, but --check returned 0"
fi
echo "OK 1: initial drift detected (exit 1)"

# --- Assertion 2: --render rewrites both files to match the canonical.
run_gen --render >/dev/null
# Placeholder text must be gone from both.
if grep -q "INTENTIONAL PLACEHOLDER" "$target_claude" "$target_codex"; then
  fail "--render did not replace placeholder text"
fi
echo "OK 2: --render replaces placeholders with canonical content"

# --- Assertion 3: post-render, --check returns 0.
run_gen --check >/dev/null
echo "OK 3: post-render --check is clean (exit 0)"

# --- Assertion 4: templating applied per surface. The two targets must
# NOT contain each other's per-surface phrase.
if grep -q "Claude and every Claude subagent" "$target_codex"; then
  fail "codex target leaked Claude templating"
fi
if grep -q "every Codex agent and subagent" "$target_claude"; then
  fail "claude target leaked Codex templating"
fi
# And the right phrase must be present in each.
grep -q "Claude and every Claude subagent" "$target_claude" \
  || fail "claude target missing its templated phrase"
grep -q "every Codex agent and subagent" "$target_codex" \
  || fail "codex target missing its templated phrase"
# Additional shared-fleet-routing tokens must not leak between surfaces.
if grep -q "SEATCLAUDE" "$target_codex"; then
  fail "codex target leaked Claude seat-check phrase"
fi
if grep -q "SEATCODEX" "$target_claude"; then
  fail "claude target leaked Codex seat-check phrase"
fi
if grep -q "SOLCLAUDE" "$target_codex"; then
  fail "codex target leaked Claude Sol block"
fi
if grep -q "SOLCODEX" "$target_claude"; then
  fail "claude target leaked Codex Sol block"
fi
grep -q "SEATCLAUDE" "$target_claude" || fail "claude target missing its seat phrase"
grep -q "SEATCODEX" "$target_codex" || fail "codex target missing its seat phrase"
grep -q "SOLCLAUDE" "$target_claude" || fail "claude target missing its Sol block"
grep -q "SOLCODEX" "$target_codex" || fail "codex target missing its Sol block"
echo "OK 4: templating applied per surface (claude vs codex)"

# --- Assertion 4b: never-relay-finding + shared-memory-loop de-dup (slice 2, #1153).
# The codex surface keeps no never-relay-finding region (it stays hand-written),
# so the section must render into claude only.
if grep -q "BEGIN GENERATED: never-relay-finding" "$target_codex"; then
  fail "codex target got a never-relay-finding region it should not have"
fi
grep -q "BEGIN GENERATED: never-relay-finding" "$target_claude" \
  || fail "claude target missing its never-relay-finding region"
# shared-memory-loop render carries the per-surface --agent token.
grep -q -- "--agent claude-vps" "$target_claude" || fail "claude --agent token not substituted"
grep -q -- "--agent codex-vps" "$target_codex" || fail "codex --agent token not substituted"
if grep -q -- "--agent claude-vps" "$target_codex"; then
  fail "codex target leaked claude --agent token"
fi
if grep -q -- "--agent codex-vps" "$target_claude"; then
  fail "claude target leaked codex --agent token"
fi
# --verified-by uses the same surface token.
grep -q -- '--verified-by "claude-vps"' "$target_claude" \
  || fail "claude --verified-by token not substituted"
grep -q -- '--verified-by "codex-vps"' "$target_codex" \
  || fail "codex --verified-by token not substituted"
# The failure-response block must render into claude only (codex keeps it
# hand-written in its Safety section, so its shared-memory-loop is empty).
grep -q "FAILCLAUDE" "$target_claude" || fail "claude failure-response block missing"
if grep -q "FAILCLAUDE" "$target_codex"; then
  fail "codex target leaked claude failure-response block"
fi
# No undeclared token may survive into either surface.
if grep -q -- '{{' "$target_claude" "$target_codex"; then
  fail "a literal {{token}} survived render into a target"
fi
echo "OK 4b: never-relay/shared-memory-loop de-dup + failure-response bound to claude"

# --- Assertion 5: hand-edit -> drift -> --render restores.
snapshot_claude="$(mktemp)"
snapshot_codex="$(mktemp)"
cp -p "$target_claude" "$snapshot_claude"
cp -p "$target_codex" "$snapshot_codex"

sed -i 's/must be EMPTY/must be HAND-EDITED-MARKER/' "$target_claude"
if run_gen --check >/dev/null 2>&1; then
  fail "hand-edit was not detected by --check"
fi
echo "OK 5a: hand-edit caught by --check (exit 1)"

run_gen --render >/dev/null
if grep -q "HAND-EDITED-MARKER" "$target_claude"; then
  fail "--render did not overwrite hand-edit"
fi
if ! cmp -s "$target_claude" "$snapshot_claude"; then
  fail "--render output diverged from pre-edit snapshot"
fi
run_gen --check >/dev/null
echo "OK 5b: --render restored exact pre-edit bytes; --check clean"

# --- Assertion 6: BEGIN/END GENERATED markers persist across renders.
# (We are confirming the markers are re-emitted, not consumed.)
for f in "$target_claude" "$target_codex"; do
  grep -q "<!-- BEGIN GENERATED: idle-fleet-alarm -->" "$f" \
    || fail "$f lost the BEGIN marker after render"
  grep -q "<!-- END GENERATED: idle-fleet-alarm -->" "$f" \
    || fail "$f lost the END marker after render"
done
echo "OK 6: markers persist across renders"

# --- Assertion 7: canonical-only sections (no target reference) -> exit 1.
# Build a target that has NO BEGIN/END markers at all. The canonical
# declares five sections, so unused-sections check must trip.
empty_target="$work/empty.md"
echo "no markers here" > "$empty_target"
set +e
python3 "$gen" \
  --canonical "$canonical" \
  --targets "$empty_target|claude-vps|Claude|Claude and every Claude subagent" \
  --check >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "expected unused-section failure for empty target, got 0"
echo "OK 7: canonical sections with no target reference -> exit 1"

# --- Assertion 8: orphan BEGIN marker (no matching END) -> hard error.
orphan_target="$work/orphan.md"
cat > "$orphan_target" <<'OR'
# preamble
<!-- BEGIN GENERATED: idle-fleet-alarm -->
body with no end
OR
set +e
python3 "$gen" \
  --canonical "$canonical" \
  --targets "$orphan_target|claude-vps|Claude|Claude and every Claude subagent" \
  --check >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "expected orphan-marker error, got 0"
echo "OK 8: orphan BEGIN marker -> hard error (exit nonzero)"
# --- Assertion 9: the Pi example-extension count is pinned to reality (fleet-ops#2577).
# The rulebook-redteam audit found the count contradicting itself across rule bodies
# (74 vs 79): a bare number with no anchor drifted between sections. The fix: every
# rule body that names the count must carry the SAME number pinned with a dated, runnable
# `ls ... | wc -l` check command, so a future edit has to re-verify the count by
# construction. This asserts the canonical (and thus its rendered surfaces) carries that pin,
# and --- when the Pi install is present --- that the pinned number equals the live count.

pi_lines="$(grep -F "shipped example extensions" "$canonical" || true)"
[[ -n "$pi_lines" ]] || fail "canonical missing the Pi example-extension count line"
while IFS= read -r pi_line; do
  [[ -n "${pi_line:-}" ]] || continue
  grep -Fq "shipped example extensions (verified" <<<"$pi_line" \
    || fail "Pi count line must carry the dated check command (fleet-ops#2577): $pi_line"
  grep -Fq "| wc -l" <<<"$pi_line" \
    || fail "Pi count line must pin the count to \`ls ... | wc -l\` (fleet-ops#2577): $pi_line"
done <<<"$pi_lines"
echo "OK 9a: canonical pins the Pi example-extension count with the dated \`ls | wc -l\` check"

EXT_DIR="${FLEET_PI_EXAMPLES_EXT_DIR:-$HOME/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions}"
if [[ -d "$EXT_DIR" ]]; then
  live="$(ls "$EXT_DIR" | wc -l | tr -d ' ')"
  pinned="$(sed -nE 's/.*[^0-9]([0-9]+) shipped example extensions.*/\1/p' "$canonical" | head -n1)"
  [[ -n "$pinned" ]] || fail "could not extract the pinned count from canonical"
  [[ "$pinned" == "$live" ]] || fail \
    "canonical pins $pinned Pi example extensions but the live count is $live (run \`ls ... | wc -l\` and update the pinned number)"
  echo "OK 9b: pinned count $pinned equals the live Pi example-extension count (reality-checked)"
else
  echo "OK 9b: no Pi install present (skipping reality check; structural pin only, CI)"
fi

# --- Assertion 10 (fleet-ops#5537): governed-run status is reality-anchored.
# The rulebook-redteam audit found the canonical claiming "`governed-run` and
# `~/.local/share/implementation-worker-routing/` are gone with them" while
# /home/nish/.local/bin/governed-run still exists and ~/.codex/AGENTS.md still
# sanctions it for non-Pi ad-hoc commands. The canonical must never claim a
# deletion that reality contradicts: file-existence claims are pinned to a
# dated, runnable check command, and the surviving non-Pi sanction is stated.

canonical_routing="$(sed -n '/SECTION: shared-fleet-routing/,/END SECTION: shared-fleet-routing/p' "$canonical")"
[[ -n "$canonical_routing" ]] || fail "canonical has no shared-fleet-routing section (gate cannot run)"

if grep -Fq "are gone with them" <<<"$canonical_routing"; then
  fail "canonical claims governed-run is 'gone with them' (fleet-ops#5537) - verify reality first: test -x ~/.local/bin/governed-run; ls ~/.local/share/implementation-worker-routing/; if retired-but-alive, say 'retired for Pi dispatch' with a dated check command instead of claiming deletion"
fi

grep -Fq "retired for Pi dispatch" <<<"$canonical_routing" \
  || fail "canonical shared-fleet-routing must state how governed-run was retired ('retired for Pi dispatch') rather than silently omitting it (fleet-ops#5537)"

grep -Fq "sanctioned for non-Pi ad-hoc commands" <<<"$canonical_routing" \
  || fail "canonical must state the surviving non-Pi sanction for governed-run (fleet-ops#5537)"

# Reality check: if the wrapper is present on this host, the canonical must NOT
# claim its deletion and must name the surviving sanction.
if [[ -x "$HOME/.local/bin/governed-run" ]] && ! grep -Fq "NOT deleted" <<<"$canonical_routing"; then
  fail "~/.local/bin/governed-run exists but canonical does not pin 'NOT deleted' for it (fleet-ops#5537)"
fi

grep -Fq "test -x ~/.local/bin/governed-run" <<<"$canonical_routing" \
  || fail "canonical governed-run status must carry the dated test -x check command (fleet-ops#5537)"
echo "OK 10: governed-run status is reality-anchored (fleet-ops#5537)"

# Retired-identity contradiction gate (fleet-ops#5642) and its fixture
# drill. A generated region states "Sol is retired"; a hand-written tail
# that still assigns Sol live work (handoff inspection, final integration
# and verification) is a live contradiction the generator cannot see —
# it never edits hand-written prose, so this grep gate is the detector.
retired_identity_clauses=(
  "Sol inspects every handoff"
  "Sol still orchestrates"
  "Sol owns final integration"
)
# Returns non-zero (silent) when the surface carries the retirement note
# and still assigns Sol live work.
retired_identity_contradiction() {
  local f="$1" clause
  grep -Fq "Sol is retired" "$f" || return 1
  for clause in "${retired_identity_clauses[@]}"; do
    grep -Fq "$clause" "$f" && return 0
  done
  return 1
}
# Fixture drill (runs on every host, including bare CI): the check must
# catch the stale clause on a surface that carries the retirement note,
# and pass the fixed reassignment.
fixt="$work/retired-identity-fixture.md"
printf '# Tail\n\nSol is retired (Nish 2026-09-07, fleet-ops#4148).\n\n- Sol inspects every handoff and owns final integration and verification.\n' >"$fixt"
if retired_identity_contradiction "$fixt"; then
  :
else
  fail "retired-identity gate missed the stale clause on the fixture (fleet-ops#5642)"
fi
printf '# Tail\n\nSol is retired (Nish 2026-09-07, fleet-ops#4148).\n\n- Pi stock reviewer subagent inspects every handoff and owns final integration and verification.\n' >"$fixt"
if retired_identity_contradiction "$fixt"; then
  fail "retired-identity gate false-positive on the fixed fixture (fleet-ops#5642)"
fi
echo "OK 11a: retired-identity gate catches the stale clause and passes the fixed text (fixture drill)"
# Live render targets, when present on this host (bare CI hosts SKIP).
live_targets_missing=0
for t in /home/nish/.claude/CLAUDE.md /home/nish/.codex/AGENTS.md; do
  [[ -f "$t" ]] || live_targets_missing=1
done
if [[ "$live_targets_missing" == 1 ]]; then
  echo "OK 11b: live render targets absent on this host (SKIP live gate)"
elif retired_identity_contradiction /home/nish/.claude/CLAUDE.md \|\| retired_identity_contradiction /home/nish/.codex/AGENTS.md; then
  fail "a live rendered surface assigns retired Sol live verification work (fleet-ops#5642) - reassign it to Pi's stock reviewer subagent"
else
  echo "OK 11b: live CLAUDE.md/.codex AGENTS.md carry no retired-identity contradiction (fleet-ops#5642)"
fi

echo ""
echo "ALL OK: 11/11 assertions passed (drift, render, templating, markers, orphans, pi-count pin, governed-run pin, retired-identity)" | head
