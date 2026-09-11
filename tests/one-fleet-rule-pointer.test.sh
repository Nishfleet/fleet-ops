#!/usr/bin/env bash
# tests/one-fleet-rule-pointer.test.sh
#
# Guards the one-fleet-rule consolidation (fleet-ops#5588): the generated
# one-fleet block in every renderer target must be a TITLE + POINTER to the
# vault archive section, not a separately maintained paraphrase. The vault
# stays the single wording authority; a target that carries its own body (or
# a heading that dropped the 'corrected 2026-08-25' amendment) is the exact
# drift this issue closed.
#
# Runs standalone (not via the standing-rules-drift fixture harness) so it
# additionally proves the real, rendered targets on the host are in sync.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
canonical="$repo_root/lib/standing-rules/canonical.md"
archive="${ONE_FLEET_ARCHIVE:-/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/standing-rules-archive.md}"
heading='## One fleet (Nish, 2026-08-21; machinery superseded 2026-08-23 — corrected 2026-08-25)'

[[ -f "$canonical" ]] || fail "canonical not found: $canonical"

# Extract the one-fleet-rule SECTION body from the canonical.
section="$(sed -n '/<!-- SECTION: one-fleet-rule -->/,/<!-- END SECTION: one-fleet-rule -->/p' "$canonical" \
  | grep -v '^<!-- END SECTION: one-fleet-rule -->' \
  | grep -v '^<!-- SECTION: one-fleet-rule -->')"
[[ -n "$section" ]] || fail "one-fleet-rule section missing from canonical"

echo "$section" | grep -qxF "$heading" \
  || fail "canonical one-fleet heading does not carry the 'corrected 2026-08-25' amendment"

# The body must be heading + exactly one Full text pointer line (title+pointer
# pattern, like global-standing-rules.md itself uses).
nonempty="$(echo "$section" | grep -v '^[[:space:]]*$' | grep -vc '^##')"
[[ "$nonempty" -eq 1 ]] || fail "canonical one-fleet section is not a title + single pointer line ($nonempty content lines)"
echo "$section" | grep -q "^Full text: .*standing-rules-archive.md" \
  || fail "canonical one-fleet section missing the archive Full text pointer"

# The archive target of the pointer must exist and carry the exact heading.
[[ -f "$archive" ]] || fail "archive not found: $archive"
grep -qxF "$heading" "$archive" \
  || fail "archive does not contain the exact one-fleet heading"

# If the real rendered targets exist on this host, they must echo the same
# title + pointer and must NOT carry the old paraphrased body.
for target in /home/nish/.claude/CLAUDE.md /home/nish/.codex/AGENTS.md; do
  [[ -f "$target" ]] || continue
  block="$(sed -n '/<!-- BEGIN GENERATED: one-fleet-rule -->/,/<!-- END GENERATED: one-fleet-rule -->/p' "$target")"
  [[ -n "$block" ]] || fail "$target lost its one-fleet-rule generated region"
  echo "$block" | grep -qxF "$heading" \
    || fail "$target one-fleet heading drifted from the canonical wording"
  echo "$block" | grep -q "Full text: .*standing-rules-archive.md" \
    || fail "$target one-fleet block is not a pointer to the archive"
  if echo "$block" | grep -q "No second dispatcher"; then
    fail "$target one-fleet block still carries the paraphrased body (consolidation regression)"
  fi
done

echo "OK: one-fleet-rule is title + archive pointer in canonical and every rendered target"
