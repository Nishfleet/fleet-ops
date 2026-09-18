#!/usr/bin/env bash
# tests/reserved-classes-precedence.test.sh
#
# Proves fleet-ops#5586 (rulebook-redteam contradiction) offline:
# Nish's reserved-escalation classes must have ONE canonical list in the
# vault (`global-standing-rules.md` -> "Only the un-fixable reaches Nish"
# -> "Canonical reserved-classes list", the union, precedence-stated) and
# every agent canonical surface must POINT at it rather than restate a
# divergent copy:
#   1. fleet-ops Pi canonical.md points at the vault list (no standalone
#      "money, privacy, security, ... " list left inline).
#   2. fleet-ops standing-rules canonical.md never-relay-finding section
#      points at the vault list (no inline list left).
#   3. Where the vault exists (VPS, not CI), the canonical list includes
#      BOTH privacy AND customer-data deletion — the two items that made
#      the old surface lists non-supersets.
#
# Live rendered targets (~/AGENTS.md, ~/.claude/CLAUDE.md): the render
# machinery (bin/render-standing-rules.py, bin/render-pi-agents-md.py) and
# their drift-check blocks were deleted in the 2026-09-18 glue sweep
# (fleet-ops f8b567588, fleet-ops#5694). The surfaces are now hand-edited
# plain markdown; the text assertions below (not byte-level drift checks)
# are what keep guarding the reserved-classes precedence on the live
# surfaces. Where a live surface is absent (bare CI host) the check SKIPS.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

pi_canonical="$repo_root/docs/pi-agents.md"
sr_canonical="$repo_root/docs/standing-rules.md"
vault_gsr="${FLEET_VAULT_GSR:-/home/nish/workspaces/tooling/nish-vault/_system/shared-memory/global-standing-rules.md}"

[[ -f "$pi_canonical" ]] || fail "missing $pi_canonical"
[[ -f "$sr_canonical" ]] || fail "missing $sr_canonical"

# 1. Pi canonical points at the vault list and names the full union.
grep -q "Canonical reserved" "$pi_canonical" \
  || fail "pi canonical does not name the canonical reserved-classes list"
for klass in "privacy" "customer-data deletion" "product direction" "brand"; do
  grep -q "$klass" "$pi_canonical" || fail "pi canonical lost reserved class: $klass"
done
grep -q "global-standing-rules.md" "$pi_canonical" \
  || fail "pi canonical does not point at the vault source of truth"
# The old shorter inline list (no privacy/customer-data) must be gone.
grep -q "in only for money, privacy, security, legal, product direction, or destructive" "$pi_canonical" \
  && fail "pi canonical still carries the old divergent inline escalation list"

# 1b. fleet-ops#5715: the 'Hard lines' deploy line must NOT contradict the
# enforced 'Agent-authored PRs land themselves' rule — the bare 'Never merge'
# wording is the regression; the precedence carve-out pattern is required.
sed -n '/^## Hard lines/,/^## Where/p' "$pi_canonical" | grep -q "Never merge, never deploy without Nish" \
  && fail "pi canonical hard line still carries the bare 'Never merge' wording that contradicts the self-land rule (fleet-ops#5715)"
sed -n '/^## Hard lines/,/^## Where/p' "$pi_canonical" | grep -q "Never deploy without Nish" \
  || fail "pi canonical hard line lost the 'Never deploy without Nish' clause"
sed -n '/^## Hard lines/,/^## Where/p' "$pi_canonical" | grep -q "self-land" \
  || fail "pi canonical hard line lost the self-land precedence carve-out"

# 2. Claude standing-rules canonical points at the vault list.
grep -q 'Reaches Nish and nothing else' "$sr_canonical" \
  || fail "standing-rules canonical lost the reaches-Nish line"
sed -n '/SECTION: never-relay-finding/,/END SECTION: never-relay-finding/p' "$sr_canonical" \
  | grep -q "global-standing-rules.md" \
  || fail "never-relay-finding section does not point at the vault canonical list"
sed -n '/SECTION: never-relay-finding/,/END SECTION: never-relay-finding/p' "$sr_canonical" \
  | grep -q "Canonical reserved-classes" \
  || fail "never-relay-finding section does not name the canonical list"
# The old shorter inline list (no privacy/security) must be gone.
sed -n '/SECTION: never-relay-finding/,/END SECTION: never-relay-finding/p' "$sr_canonical" \
  | grep -q "^Reaches Nish and nothing else: money, pricing, legal" \
  && fail "never-relay-finding still carries the old divergent inline list"

# 3. Vault canonical list (VPS-only surface; SKIPPED, never a pass lie).
if [[ -f "$vault_gsr" ]]; then
  grep -q "Canonical reserved-classes list" "$vault_gsr" \
    || fail "vault GSR missing the canonical reserved-classes block"
  blk="$(grep -A12 "Canonical reserved-classes list" "$vault_gsr")"
  for klass in "privacy" "security" "customer-data deletion" "brand" "legal" "product direction" "irreversible"; do
    echo "$blk" | grep -q "$klass" || fail "vault canonical list missing reserved class: $klass"
  done
  echo "OK: vault canonical reserved-classes block present"
else
  echo "SKIP: vault GSR not present at $vault_gsr (non-VPS host)"
fi

# 5. Hand-written trailing prose on the live surfaces must not restate a
#    reserved-classes list either (fleet-ops#5719: the CLAUDE.md 'broken
#    means fix it' bullet quoted a 3-class list). A surface that mentions
#    reserved classes must either point at global-standing-rules.md or not
#    enumerate a divergent list. Live-target check: SKIPPED when absent.
for t in /home/nish/.claude/CLAUDE.md /home/nish/.codex/AGENTS.md; do
  [[ -f "$t" ]] || { echo "SKIP: reserved-classes surface-prose check ($t absent)"; continue; }
  if grep -q "Only the reserved classes" "$t"; then
    fail "live surface $t restates the old divergent reserved-classes list — point at global-standing-rules.md instead"
  fi
  # Any 'reserved classes' prose that enumerates without naming the vault source is drift.
  # Wrap-aware (fleet-ops#6031): a mention and its vault pointer may wrap
  # across the bullet's indented continuation lines (the house wrap
  # convention in the live targets), so each mention is judged joined with
  # its wrapped lines — a pointer on the next wrapped line satisfies the
  # check; a mention with no pointer in its own bullet is still drift.
  if ! awk '
    function flush() {
      if (logical != "" \
          && tolower(logical) ~ /reserved classes/ \
          && logical !~ /global-standing-rules\.md/) {
        drift = 1
      }
      logical = ""
    }
    /^[ \t]/ && logical != "" { logical = logical " " $0; next }
    { flush(); logical = $0 }
    END { flush(); exit drift + 0 }
  ' "$t"; then
    fail "live surface $t names reserved classes without pointing at global-standing-rules.md"
  fi
  echo "OK: $t carries no divergent reserved-classes restatement"
done

echo "OK fleet-ops#5586: reserved-classes precedence consolidated (incl. fleet-ops#5719 surface-prose gate)"
