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

echo ""
echo "ALL OK: 8/8 assertions passed (drift, render, templating, markers, orphans)"
