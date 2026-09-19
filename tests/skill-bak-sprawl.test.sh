#!/usr/bin/env bash
# tests/skill-bak-sprawl.test.sh
#
# fleet-ops#7842: 199 stale `.bak-*` sibling dirs under ~/.pi/agent/skills
# (98 unslop, 98 why, 3 blast-radius) left by install-links / auditor runs.
# The live cleanup is hash-verify SKILL.md against the vault (or the live
# sibling) then delete duplicates; unique content moves to
# ~/workspaces/agent-state/backups, never stays as a .bak sibling.
#
# This file is the class lock (fleet-ops#366): a hermetic replay of that
# procedure, a writer-grep so a script cannot mint `.bak-install-links-*`
# again, and a live count of 0 when the pi skills dir exists.

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

cleanup_skill_bak() {
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib, os, shutil, sys

skills, vault, backups = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(backups, exist_ok=True)

def skill_hash(path):
    skill = os.path.join(path, "SKILL.md")
    if not os.path.isfile(skill):
        return None
    h = hashlib.sha256()
    with open(skill, "rb") as f:
        h.update(f.read())
    return h.hexdigest()

deleted, moved = [], []
for name in sorted(os.listdir(skills)):
    if ".bak" not in name:
        continue
    path = os.path.join(skills, name)
    if not os.path.isdir(path):
        continue
    stem = name.split(".bak", 1)[0]
    this_hash = skill_hash(path)
    vault_hash = skill_hash(os.path.join(vault, stem))
    live = os.path.join(skills, stem)
    live_hash = skill_hash(live) if os.path.isdir(live) else None
    canonical = vault_hash or live_hash
    if this_hash and canonical and this_hash == canonical:
        shutil.rmtree(path)
        deleted.append(name)
        continue
    dest = os.path.join(backups, name)
    if os.path.exists(dest):
        dest = dest + ".dup"
    shutil.move(path, dest)
    moved.append(name)

print("deleted=" + ",".join(deleted))
print("moved=" + ",".join(moved))
PY
}

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
skills="$scratch/skills"
vault="$scratch/vault"
backups="$scratch/backups"
mkdir -p "$skills/unslop" "$skills/why" "$vault/unslop" "$vault/why" \
  "$skills/unslop.bak-install-links-1234" \
  "$skills/why.bak-auditor-20260905" \
  "$skills/blast-radius.bak-20260905-auditor-skills-drift"

printf 'CANON-UNSLOP\n' >"$vault/unslop/SKILL.md"
printf 'CANON-UNSLOP\n' >"$skills/unslop/SKILL.md"
printf 'CANON-UNSLOP\n' >"$skills/unslop.bak-install-links-1234/SKILL.md"
printf 'CANON-WHY\n' >"$vault/why/SKILL.md"
printf 'CANON-WHY\n' >"$skills/why/SKILL.md"
printf 'CANON-WHY\n' >"$skills/why.bak-auditor-20260905/SKILL.md"
printf 'LOCAL-DELTA\n' >"$skills/blast-radius.bak-20260905-auditor-skills-drift/SKILL.md"

out=$(cleanup_skill_bak "$skills" "$vault" "$backups")
printf '%s\n' "$out"

deleted_line=$(printf '%s\n' "$out" | grep '^deleted=')
moved_line=$(printf '%s\n' "$out" | grep '^moved=')
[[ "$deleted_line" != *blast-radius* ]] \
  || fail "unique bak dir was deleted instead of moved"
[[ "$deleted_line" == *unslop.bak-install-links-1234* ]] \
  || fail "vault-duplicate unslop.bak-install-links-1234 was not deleted"
[[ "$deleted_line" == *why.bak-auditor-20260905* ]] \
  || fail "vault-duplicate why.bak-auditor-20260905 was not deleted"
[[ "$moved_line" == *blast-radius.bak-20260905-auditor-skills-drift* ]] \
  || fail "unique blast-radius bak dir was not moved to backups"

[[ ! -d "$skills/unslop.bak-install-links-1234" ]] \
  || fail "duplicate bak dir still in skills/"
[[ ! -d "$skills/why.bak-auditor-20260905" ]] \
  || fail "duplicate auditor bak dir still in skills/"
[[ ! -d "$skills/blast-radius.bak-20260905-auditor-skills-drift" ]] \
  || fail "unique bak dir left as a skills/ sibling"
[[ -d "$backups/blast-radius.bak-20260905-auditor-skills-drift" ]] \
  || fail "unique bak dir missing from backups/"
[[ -d "$skills/unslop" && -d "$skills/why" ]] \
  || fail "live skill dirs were removed"
ok "hash-verify deletes vault duplicates and moves unique content to backups"

# Writer lock: no tracked script mints the legacy .bak-install-links / auditor
# skills-drift sibling names. Docs and this test may name the class.
if hits=$(git -C "$repo_root" grep -nE 'bak-install-links|bak-auditor-skills-drift|\.bak-auditor-' \
  -- ':!*.md' ':!archive/**' ':!.fleet/**' ":!tests/$(basename "$0")"); then
  fail "script still mints legacy skill .bak siblings:"$'\n'"$hits"
fi
ok "no tracked script mints bak-install-links / bak-auditor skill siblings"

live_skills="${FLEET_SKILLS_PI:-$HOME/.pi/agent/skills}"
if [[ -d "$live_skills" ]]; then
  live_n=$(find "$live_skills" -maxdepth 1 \( -name '*.bak*' -o -name '*bak-*' \) | wc -l)
  [[ "$live_n" -eq 0 ]] \
    || fail "live $live_skills still has $live_n .bak siblings (fleet-ops#7842)"
  ok "live $live_skills has 0 .bak siblings"
else
  echo "SKIP: $live_skills absent — live count not run here"
fi

echo "PASS: skill .bak sprawl class locked (fleet-ops#7842)"
