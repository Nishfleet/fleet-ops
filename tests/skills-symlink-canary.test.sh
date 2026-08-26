#!/usr/bin/env bash
# tests/skills-symlink-canary.test.sh
#
# Proves the skills-symlink canary (fleet-ops#532) offline:
#   1. Matching claude + codex catalogs -> exit 0, OK line.
#   2. Skill on claude missing from codex -> exit 1, LOUD, auto-files.
#   3. Skill on codex missing from claude -> exit 1, files missing-on-claude.
#   4. Broken skill symlink -> exit 1, files broken-claude.
#   5. House-method skill on claude/codex missing from pi -> exit 1.
#   6. Dedup: an open issue already carrying the marker -> no second create.
#   7. Neither surface present -> SKIP exit 0 (CI without agent homes).
#   8. Heartbeat-tier1 wires the canary and propagates fail-loud.
#   9. MANIFEST installs the binary.
#  10. Live VPS catalogs currently match (FILE=0).

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-skills-symlink-canary"
tier1="$repo_root/bin/fleet-heartbeat-tier1"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$tier1" ]] || fail "missing: $tier1"

scratch="$(mktemp -d -t skills-symlink-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

export HOME="$scratch/home"
mkdir -p "$HOME"
triage="$scratch/triage.md"
: >"$triage"
export FLEET_HEARTBEAT_TRIAGE="$triage"
export FLEET_SKILLS_CANARY_REPO="Nishfleet/fleet-ops"
export FLEET_SKILLS_CANARY_FILE=1

gh_log="$scratch/gh.log"
gh_fake="$scratch/gh"
cat >"$gh_fake" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "$*" in
  *"issue list"*)
    if [[ -f "${GH_OPEN_ISSUES:-/dev/null}" ]]; then
      cat "${GH_OPEN_ISSUES}"
    else
      echo '[]'
    fi
    exit 0
    ;;
  *"issue create"*)
    echo "https://github.com/Nishfleet/fleet-ops/issues/999"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$gh_fake"
export GH="$gh_fake"
export GH_LOG="$gh_log"
export PATH="$scratch:$PATH"

mk_skill() {
  local dir="$1" name="$2"
  mkdir -p "$dir/$name"
  printf '# %s\n' "$name" >"$dir/$name/SKILL.md"
}

run_canary() {
  set +e
  env_out=$(
    FLEET_SKILLS_CLAUDE="$scratch/claude" \
    FLEET_SKILLS_CODEX="$scratch/codex" \
    FLEET_SKILLS_PI="$scratch/pi" \
    FLEET_SKILLS_VAULT="$scratch/vault" \
    "$bin" 2>&1
  )
  env_rc=$?
  set -e
}

reset_catalogs() {
  rm -rf "$scratch/claude" "$scratch/codex" "$scratch/pi" "$scratch/vault"
  mkdir -p "$scratch/claude" "$scratch/codex" "$scratch/pi" "$scratch/vault"
  : >"$gh_log"
  : >"$triage"
}

# --- 1. matching catalogs ---------------------------------------------------
reset_catalogs
mk_skill "$scratch/claude" blast-radius
mk_skill "$scratch/codex" blast-radius
mk_skill "$scratch/pi" blast-radius
mkdir -p "$scratch/vault/blast-radius"
printf '# blast-radius\n' >"$scratch/vault/blast-radius/SKILL.md"
run_canary
[[ "$env_rc" == "0" ]] || fail "scenario1: expected rc=0, got $env_rc ($env_out)"
grep -q 'SKILLS-SYMLINK-OK' "$triage" || fail "scenario1: missing OK line ($env_out)"
! grep -q 'issue create' "$gh_log" || fail "scenario1: must not file on a clean map"
ok "scenario1: matching catalogs are quiet"

# --- 2. claude skill missing from codex -------------------------------------
reset_catalogs
mk_skill "$scratch/claude" blast-radius
mk_skill "$scratch/claude" unslop
mk_skill "$scratch/codex" blast-radius
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario2: expected rc=1, got $env_rc ($env_out)"
grep -q 'SKILLS-SYMLINK-VIOLATION' "$triage" || fail "scenario2: missing VIOLATION"
grep -q 'missing from codex' "$triage" || fail "scenario2: must name the missing-on-codex gap"
grep -q 'unslop' "$triage" || fail "scenario2: must name unslop"
grep -q 'issue create' "$gh_log" || fail "scenario2: must auto-file"
ok "scenario2: claude-only skill screams and auto-files"

# --- 3. codex skill missing from claude -------------------------------------
reset_catalogs
mk_skill "$scratch/claude" blast-radius
mk_skill "$scratch/codex" blast-radius
mk_skill "$scratch/codex" why
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario3: expected rc=1, got $env_rc ($env_out)"
grep -q 'missing from claude' "$triage" || fail "scenario3: must name the missing-on-claude gap"
grep -q 'why' "$triage" || fail "scenario3: must name why"
grep -q 'issue create' "$gh_log" || fail "scenario3: must auto-file"
ok "scenario3: codex-only skill screams and auto-files"

# --- 4. broken symlink ------------------------------------------------------
reset_catalogs
mk_skill "$scratch/claude" blast-radius
mk_skill "$scratch/codex" blast-radius
ln -s "$scratch/does-not-exist" "$scratch/claude/ghost"
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario4: expected rc=1, got $env_rc ($env_out)"
grep -q 'broken skill symlink' "$triage" || fail "scenario4: must name the broken symlink"
grep -q 'ghost' "$triage" || fail "scenario4: must name ghost"
grep -q 'issue create' "$gh_log" || fail "scenario4: must auto-file"
ok "scenario4: broken skill symlink screams and files"

# --- 5. house skill missing from pi -----------------------------------------
reset_catalogs
mk_skill "$scratch/claude" unslop
mk_skill "$scratch/codex" unslop
mkdir -p "$scratch/vault/unslop"
printf '# unslop\n' >"$scratch/vault/unslop/SKILL.md"
# pi dir exists but does not have unslop
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario5: expected rc=1, got $env_rc ($env_out)"
grep -q 'house-method skill' "$triage" || fail "scenario5: must name the house-skill gap"
grep -q 'unslop' "$triage" || fail "scenario5: must name unslop"
grep -q 'pi' "$triage" || fail "scenario5: must name the missing pi surface"
ok "scenario5: house skill missing from pi screams"

# --- 6. dedup ---------------------------------------------------------------
reset_catalogs
export GH_OPEN_ISSUES="$scratch/open.json"
jq -n --arg b $'body\nskills-symlink-canary: missing-on-codex\n' \
  '[{number: 42, body: $b}]' >"$GH_OPEN_ISSUES"
mk_skill "$scratch/claude" blast-radius
mk_skill "$scratch/claude" unslop
mk_skill "$scratch/codex" blast-radius
run_canary
[[ "$env_rc" == "1" ]] || fail "scenario6: expected rc=1, got $env_rc ($env_out)"
grep -q 'issue create' "$gh_log" && fail "scenario6: must not file a duplicate"
ok "scenario6: open issue with marker dedupes"
unset GH_OPEN_ISSUES

# --- 7. neither surface present -> SKIP -------------------------------------
: >"$gh_log"
: >"$triage"
empty_home="$scratch/empty-home"
mkdir -p "$empty_home"
set +e
skip_out=$(
  HOME="$empty_home" \
  FLEET_SKILLS_CLAUDE="" \
  FLEET_SKILLS_CODEX="" \
  FLEET_SKILLS_PI="" \
  FLEET_SKILLS_VAULT="" \
  env -u FLEET_SKILLS_CLAUDE -u FLEET_SKILLS_CODEX -u FLEET_SKILLS_PI \
    "$bin" 2>&1
)
skip_rc=$?
set -e
[[ "$skip_rc" == "0" ]] || fail "scenario7: expected rc=0 SKIP, got $skip_rc ($skip_out)"
grep -q 'SKILLS-SYMLINK-SKIP' "$triage" || fail "scenario7: must log SKIP ($skip_out)"
! grep -q 'issue create' "$gh_log" || fail "scenario7: must not file on SKIP"
ok "scenario7: neither surface present is SKIP"

# --- 8. heartbeat wiring ----------------------------------------------------
grep -F 'fleet-skills-symlink-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-skills-symlink-canary"
grep -F 'skills_symlink_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture skills_symlink_canary_rc"
grep -F -- 'exit "$skills_symlink_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must exit non-zero when the skills-symlink canary fails loud"
ok "scenario8: heartbeat-tier1 wires the canary and propagates fail-loud"

# --- 9. MANIFEST ------------------------------------------------------------
grep -q 'bin/fleet-skills-symlink-canary' "$repo_root/MANIFEST" \
  || fail "MANIFEST must install bin/fleet-skills-symlink-canary"
ok "scenario9: MANIFEST installs the canary"

# --- 10. live VPS catalogs currently match ----------------------------------
: >"$gh_log"
: >"$triage"
set +e
live_out=$(
  FLEET_SKILLS_CANARY_FILE=0 \
  HOME=/home/nish \
  "$bin" 2>&1
)
live_rc=$?
set -e
[[ "$live_rc" == "0" ]] || fail "scenario10: live VPS catalogs must currently match, got rc=$live_rc ($live_out)"
ok "scenario10: live VPS claude/codex catalogs match"

ok "skills-symlink-canary: missing names, broken links, house gap, dedup, skip, live clean"
