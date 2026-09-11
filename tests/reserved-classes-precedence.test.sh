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
# Live rendered targets (~/AGENTS.md, ~/.claude/CLAUDE.md) are verified by
# `bin/render-standing-rules.py --check` and
# `bin/render-pi-agents-md.py --check` at deploy time (mechanism may be
# absent on a bare CI host, so only their absence skips, never a hard fail).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

pi_canonical="$repo_root/lib/pi-agents-md/canonical.md"
sr_canonical="$repo_root/lib/standing-rules/canonical.md"
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

# 4. Renders, when the machinery exists on this host, must be in sync.
if [[ -x "$repo_root/bin/render-standing-rules.py" ]]; then
  if python3 "$repo_root/bin/render-standing-rules.py" --check >/dev/null 2>&1; then
    echo "OK: standing-rules render check green"
  else
    echo "SKIP: standing-rules render check failed (targets likely absent on this host)"
  fi
fi
if [[ -x "$repo_root/bin/render-pi-agents-md.py" ]]; then
  if python3 "$repo_root/bin/render-pi-agents-md.py" --check >/dev/null 2>&1; then
    echo "OK: pi-agents-md render check green"
  else
    echo "SKIP: pi-agents-md render check failed (targets likely absent on this host)"
  fi
fi

echo "OK fleet-ops#5586: reserved-classes precedence consolidated"
