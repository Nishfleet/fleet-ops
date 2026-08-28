#!/usr/bin/env bash
# tests/fleet-d1-prod-migration-canary.test.sh
#
# Proves the D1 prod migration senior-process canary (fleet-ops#905) offline:
#   1. Clean repo: one old + one new migration with evidence -> exit 0,
#      D1-PROD-MIGRATION-OK.
#   2. New migration missing evidence dir -> exit 1.
#   3. New migration with empty required artifact -> exit 1.
#   4. Missing required artifact -> exit 1.
#   5. Vacation window expired with a new migration -> exit 1.
#   6. No new migrations (threshold after all) -> exit 0.
#   7. Ledger-line prints the decision.
#   8. Heartbeat-tier1 wires the canary, fail-loud, MANIFEST installs it.
#   9. Matrix row is enforced with mechanism+proof.
#
# Offline: uses scratch git repos.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
bin="$repo_root/bin/fleet-d1-prod-migration-canary"
lib="$repo_root/lib/d1-prod-migration-canary.py"
tier1="$repo_root/bin/fleet-heartbeat-tier1"
matrix="$repo_root/config/rule-enforcement.json"
manifest="$repo_root/MANIFEST"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "OK: $*"; }

[[ -x "$bin" ]] || fail "not executable: $bin"
[[ -f "$lib" ]] || fail "missing $lib"
[[ -f "$tier1" ]] || fail "missing $tier1"
[[ -f "$matrix" ]] || fail "missing $matrix"
[[ -f "$manifest" ]] || fail "missing $manifest"
command -v jq >/dev/null 2>&1 || fail "jq missing"
command -v python3 >/dev/null 2>&1 || fail "python3 missing"
command -v git >/dev/null 2>&1 || fail "git missing"

scratch="$(mktemp -d -t d1-prod-migration-canary.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT INT TERM

init_repo() {
  local r="$1"
  mkdir -p "$r/migrations" "$r/migrations/evidence"
  git -C "$r" init -q
  git -C "$r" config user.email "canary@fleet-ops.test"
  git -C "$r" config user.name "Canary"
}

commit_migration() {
  local r="$1" name="$2" when="$3"
  git -C "$r" add "migrations/$name"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" \
    git -C "$r" commit -q -m "add $name"
}

add_evidence() {
  local r="$1" name="$2"
  local ev="$r/migrations/evidence/$name"
  mkdir -p "$ev"
  printf 'migration plan\n' >"$ev/plan.md"
  printf 'independent senior blind-review and approval\n' >"$ev/review.md"
  printf 'verified backup proof\n' >"$ev/backup.md"
  printf '-- rollback\n' >"$ev/rollback.sql"
  printf 'live verification results\n' >"$ev/verification.md"
  printf 'texted Nish\n' >"$ev/text-nish.md"
}

run_canary() {
  "$bin" --repo "$scratch/repo" --fleet-ops-repo "$repo_root" "$@" 2>&1
}

# --- 1. clean repo with one old and one new migration -----------------------
init_repo "$scratch/repo"
printf 'SELECT 1;\n' >"$scratch/repo/migrations/0001_old.sql"
commit_migration "$scratch/repo" "0001_old.sql" "2026-08-26T12:00:00+00:00"

printf 'ALTER TABLE foo ADD COLUMN bar TEXT;\n' >"$scratch/repo/migrations/0002_new.sql"
commit_migration "$scratch/repo" "0002_new.sql" "2026-08-28T12:00:00+00:00"
add_evidence "$scratch/repo" "0002_new.sql"

set +e
out=$(run_canary --threshold "2026-08-27T00:00:00+00:00" --now "2026-08-28T14:00:00+00:00")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario1: clean repo must exit 0, got $rc ($out)"
grep -q 'D1-PROD-MIGRATION-OK' <<<"$out" || fail "scenario1: must log OK ($out)"
ok "scenario1: new migration with complete evidence passes"

# --- 2. new migration missing evidence dir ----------------------------------
rm -rf "$scratch/repo/migrations/evidence/0002_new.sql"
set +e
out=$(run_canary --threshold "2026-08-27T00:00:00+00:00" --now "2026-08-28T14:00:00+00:00")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario2: missing evidence must exit 1, got $rc ($out)"
grep -q 'D1-PROD-MIGRATION-REJECT' <<<"$out" || fail "scenario2: must REJECT ($out)"
grep -q '0002_new.sql' <<<"$out" || fail "scenario2: must name the migration ($out)"
ok "scenario2: missing evidence dir is fail-loud"

# --- 3. new migration with empty required artifact --------------------------
add_evidence "$scratch/repo" "0002_new.sql"
: >"$scratch/repo/migrations/evidence/0002_new.sql/review.md"
set +e
out=$(run_canary --threshold "2026-08-27T00:00:00+00:00" --now "2026-08-28T14:00:00+00:00")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario3: empty artifact must exit 1, got $rc ($out)"
grep -q 'review.md: empty' <<<"$out" || fail "scenario3: must name empty review.md ($out)"
ok "scenario3: empty required artifact is fail-loud"

# --- 4. missing required artifact -------------------------------------------
rm -f "$scratch/repo/migrations/evidence/0002_new.sql/rollback.sql"
set +e
out=$(run_canary --threshold "2026-08-27T00:00:00+00:00" --now "2026-08-28T14:00:00+00:00")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario4: missing artifact must exit 1, got $rc ($out)"
grep -q 'rollback.sql: missing' <<<"$out" || fail "scenario4: must name missing rollback.sql ($out)"
ok "scenario4: missing rollback.sql is fail-loud"

# --- 5. vacation window expired ---------------------------------------------
add_evidence "$scratch/repo" "0002_new.sql"  # restore clean
cat >"$scratch/repo/migrations/0003_late.sql" <<'SQL'
CREATE INDEX IF NOT EXISTS idx_late ON events(created_at);
SQL
commit_migration "$scratch/repo" "0003_late.sql" "2026-09-09T12:00:00+00:00"
set +e
out=$(run_canary --threshold "2026-08-27T00:00:00+00:00" --now "2026-09-10T00:00:00+00:00")
rc=$?
set -e
[[ "$rc" == "1" ]] || fail "scenario5: post-vacation new migration must exit 1, got $rc ($out)"
grep -q 'vacation grant expired' <<<"$out" || fail "scenario5: must name expired grant ($out)"
ok "scenario5: new migration after 2026-09-08 is fail-loud"

# --- 6. no new migrations to verify -----------------------------------------
# Use a threshold in the future so 0001/0002 are all skipped.
set +e
out=$(run_canary --threshold "2026-12-01T00:00:00+00:00" --now "2026-08-28T14:00:00+00:00")
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario6: no new migrations must exit 0, got $rc ($out)"
grep -q 'D1-PROD-MIGRATION-OK' <<<"$out" || fail "scenario6: must log OK ($out)"
ok "scenario6: no new migrations to verify"

# --- 7. ledger-line ---------------------------------------------------------
set +e
out=$("$bin" --ledger-line 2>&1)
rc=$?
set -e
[[ "$rc" == "0" ]] || fail "scenario7: --ledger-line must exit 0, got $rc ($out)"
grep -q 'D1 prod migrations' <<<"$out" || fail "scenario7: must name the decision ($out)"
grep -q '2026-09-08' <<<"$out" || fail "scenario7: must name the grant end ($out)"
grep -q 'fleet-d1-prod-migration-canary' <<<"$out" || fail "scenario7: must name the canary ($out)"
ok "scenario7: --ledger-line prints the decision"

# --- 8. heartbeat-tier1 wiring + MANIFEST -----------------------------------
grep -F 'fleet-d1-prod-migration-canary' "$tier1" >/dev/null \
  || fail "tier1 must invoke fleet-d1-prod-migration-canary"
grep -F 'd1_prod_migration_canary_rc' "$tier1" >/dev/null \
  || fail "tier1 must capture d1_prod_migration_canary_rc"
grep -F -- 'exit "$d1_prod_migration_canary_rc"' "$tier1" >/dev/null \
  || fail "tier1 must propagate d1_prod_migration_canary_rc"
grep -F 'require_manifest_helper "$D1_PROD_MIGRATION_CANARY_BIN"' "$tier1" >/dev/null \
  || fail "tier1 must call require_manifest_helper for the canary"
grep -F 'HELPER-MISSING' "$tier1" >/dev/null \
  || fail "tier1 must emit HELPER-MISSING"
grep -Fxq 'bin/fleet-d1-prod-migration-canary /home/nish/.local/bin/fleet-d1-prod-migration-canary' "$manifest" \
  || fail "MANIFEST must install bin/fleet-d1-prod-migration-canary"
grep -Fxq 'lib/d1-prod-migration-canary.py /home/nish/.local/lib/pi-packet/d1-prod-migration-canary.py' "$manifest" \
  || fail "MANIFEST must install lib/d1-prod-migration-canary.py"
ok "scenario8: heartbeat-tier1 wires the canary, MANIFEST installs it"

# --- 9. matrix row ----------------------------------------------------------
jq -e '.rules[] | select(.id == "led-2026-08-27-d1-prod-migrations" and .status == "enforced")' \
  "$matrix" >/dev/null \
  || fail "matrix row led-2026-08-27-d1-prod-migrations must be status=enforced"
mech=$(jq -r '.rules[] | select(.id == "led-2026-08-27-d1-prod-migrations") | .mechanism' "$matrix")
printf '%s\n' "$mech" | grep -q 'fleet-d1-prod-migration-canary' \
  || fail "mechanism must name fleet-d1-prod-migration-canary (got: $mech)"
proof=$(jq -r '.rules[] | select(.id == "led-2026-08-27-d1-prod-migrations") | .proof' "$matrix")
printf '%s\n' "$proof" | grep -q 'bin/fleet-d1-prod-migration-canary' \
  || fail "proof must name the canary (got: $proof)"
printf '%s\n' "$proof" | grep -q 'tests/fleet-d1-prod-migration-canary.test.sh' \
  || fail "proof must name this test (got: $proof)"
ok "scenario9: matrix row is enforced with mechanism+proof"

ok "d1-prod-migration-canary: senior-process evidence, vacation window, heartbeat, MANIFEST, matrix"
